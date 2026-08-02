# Screen Share

Screen Share is a local-network screen mirroring system with native-app and browser viewing:

- **Screen Share Sender** runs on the jailbroken iPhone (iOS 15.0–16.5.1). It contains a ReplayKit Broadcast Upload Extension, so it can capture the full display after the user starts one system broadcast.
- **Screen Share** runs on the viewing iPhone (iOS 18–26, with a deployment target of iOS 15). It discovers the sender over Bonjour, decrypts the live H.264 stream, and renders it edge-to-edge with no app watermark or persistent app controls.
- **Browser mode** needs no receiver installation. The broadcast extension hosts a token-protected local URL that uses hardware H.264 with WebCodecs on current browsers and retains MJPEG as a compatibility fallback.

The repository has no runtime binary dependencies. XcodeGen creates the project and the GitHub Actions workflow builds both IPAs on a `macos-26` runner with Xcode 26. The sender is fake-signed with `ldid` so TrollStore can preserve the App Group shared with its ReplayKit extension; the receiver remains unsigned for certificate-based sideloading.

## What is implemented

- Full-display ReplayKit capture from the sender, including other apps, orientation changes, and app/game audio.
- Hardware H.264 encoding through VideoToolbox with 60 FPS targets for Sharp, Balanced, and Fast; Fast lowers resolution instead of frame rate to keep motion responsive within ReplayKit's extension budget.
- Hardware-backed low-delay display with `AVSampleBufferDisplayLayer`.
- Bonjour discovery, automatic reconnect, TCP no-delay, keepalive, and bounded pre-encode backpressure that skips uncoded capture samples without breaking H.264 reference frames.
- 16-character local pairing code and ChaCha20-Poly1305 authenticated encryption for every control, video, and app-audio payload.
- Low-latency game/app-audio playback in the native receiver and browser viewer, with bounded queues that discard stale audio rather than accumulating delay. Microphone audio is intentionally not captured.
- Clean full-screen viewer. Controls appear only after a tap and automatically disappear.
- Session persistence across transient Wi-Fi loss and app reopening.
- Native receiver background continuation while genuine captured audio is playing, with a finite UIKit fallback for silent streams and no automatic floating PiP window.
- Manual Picture in Picture for users who explicitly request visible background viewing.
- Optional receiver-free browser viewing through a private same-LAN link and QR code.
- Normal iOS screen recording of the unprotected viewer surface.
- Selectable **Automatic**, **Landscape**, and **Portrait** output policies with left/right quarter-turn control and no stretching.
- GitHub Actions tests, TrollStore entitlement signing, IPA packaging, checksums, artifacts, and tagged releases.

System-protected or FairPlay video may be blank in a capture. iOS itself decides that behavior.

## Architecture

```text
Jailbroken iPhone (iOS 15–16.5.1)            Viewing iPhone (iOS 18–26)

┌──────────────────────────────┐             ┌──────────────────────────────┐
│ Screen Share Sender          │             │ Screen Share                 │
│ • receiver discovery         │             │ • Bonjour listener           │
│ • pairing + quality settings │             │ • pairing code               │
└──────────────┬───────────────┘             │ • full-screen renderer       │
               │ App Group                   │ • Picture in Picture         │
┌──────────────▼───────────────┐             └──────────────▲───────────────┘
│ ReplayKit Broadcast Extension│  encrypted H.264 / TCP     │
│ • full-display sample buffers├─────────────────────────────┘
│ • VideoToolbox encoder       │        local Wi-Fi / peer-to-peer
│ • automatic reconnect        │
└──────────────────────────────┘
```

The receiver advertises `_screenshare._tcp`. The sender remembers the receiver's stable Bonjour service name and pairing code in its shared App Group. The broadcast extension finds that receiver, authenticates, and forces a new H.264 keyframe after every successful connection.

The ReplayKit extension always exposes the private browser viewer while a broadcast is live, even when the native Receiver App is the selected viewing method. The QR uses TCP port `49373`, the path proven reachable by the original browser viewer on the target devices. The upload extension has a fresh `v11` bundle identity so iOS and TrollStore cannot relaunch a cached extension from an older IPA. Current browsers receive the real-time VideoToolbox H.264 path through a bounded chunked HTTP stream and decode with WebCodecs. Browsers without WebCodecs automatically fall back to bounded MJPEG. App audio uses a separate bounded PCM stream. Current iOS 26 Safari takes the live canvas stage fullscreen directly; older iPhones retain a native-video fallback. After foregrounding, the page rebuilds its live canvas/image layers before requesting a fresh keyframe connection, preventing Safari from reusing a frozen fullscreen compositor surface. A restored tab stays visually quiet until its live frame returns.

Browser responses, chunk boundaries, and MJPEG parts are serialized with explicit RFC-style `CRLF` delimiters. This avoids Safari rejecting a response when a Swift multiline string omits its final line feed.

The neutral icon endpoints are intentionally readable without the private stream key because iOS may fetch an Apple touch icon without preserving its query string. The manifest, setup page, health check, and both video transports remain key-protected.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for packet framing, encryption, reconnection, and latency details.

## Install

### 1. Build from GitHub Actions

1. Create a GitHub repository and push this source.
2. Open **Actions → Build iOS IPAs → Run workflow**.
3. Download the `ScreenShare-<commit>` artifact. If the repository's Actions
   artifact quota is unavailable, use the rolling `ci-<branch>` prerelease
   created by the branch's push workflow instead.
4. The artifact or CI prerelease contains:
   - `ScreenShare-Sender-unsigned.ipa`
   - `ScreenShare-Receiver-unsigned.ipa`
   - `SHA256SUMS.txt`

Pushing a tag such as `v1.0.0` also creates a GitHub Release with the same files.

The receiver IPA is deliberately unsigned. The sender filename is retained for compatibility, but its two executables are fake-signed with their App Group entitlements using `ldid`; TrollStore preserves those entitlements while installing it. No Apple certificate or provisioning profile is stored in GitHub.

### 2. Install the sender

Recommended for the iOS 15.0–16.5.1 jailbroken phone:

1. Install `ScreenShare-Sender-unsigned.ipa` with TrollStore.
2. Open **Screen Share Sender** once.
3. Allow **Local Network** access.

The sender includes a nested Broadcast Upload Extension and an App Group. Install it directly with TrollStore; do not pass the sender IPA through another signing service first, because that service may remove the shared App Group entitlement.

If using a paid Apple development profile instead, replace these three identifiers before generating the project:

- `dev.screenshare.sender`
- `dev.screenshare.sender.broadcast.v11`
- `group.dev.screenshare.sender`

Update them consistently in `project.yml`, `Config/*.entitlements`, and `Sources/Shared/AppConstants.swift`.

### 3. Install the receiver

Resign and install `ScreenShare-Receiver-unsigned.ipa` with the certificate provider or sideloading tool used by the iOS 18–26 device. The receiver has no App Group or private entitlement.

Open **Screen Share** once and allow **Local Network** access. Keep the pairing-code screen visible for initial setup.

### 4. Native Receiver mode

1. Put both iPhones on the same Wi-Fi network. Personal Hotspot or peer-to-peer Bonjour can also work when the network permits discovery.
2. Select **Receiver App** as the viewing method.
3. On the sender, choose the receiver shown under **Choose receiver**.
4. Enter the 16-character code shown on the receiver.
5. Choose quality and tap **Save receiver**.
6. Tap the round iOS broadcast button.
7. In the system sheet, choose/start **Screen Share**.

After that, the receiver switches to the live screen automatically. A tap reveals the connection and Picture in Picture controls for 2.5 seconds.

### 5. Browser mode

1. Put the sender and viewing device on the same Wi-Fi network.
2. In Sender, select **Browser**.
3. Choose quality and output orientation. Use **Landscape** to quarter-turn portrait sender frames, **Portrait** to quarter-turn landscape sender frames, or **Auto** to follow the sender. Pick **Turn left/right** if the receiving phone is held on the opposite side, then tap **Save browser mode**.
4. Start the Screen Share broadcast and wait for the iOS countdown to finish.
5. Now scan the QR. The Camera app first opens a preview browser; tap its bottom-right compass icon to open the page in the real Safari app. The live extension must already be running.
6. In Safari, wait until a live frame is visible, then use the viewer's top-left expand button. Current iOS 26 takes the live stage fullscreen without copying it through a second video surface. Keep Rotation Lock off. The viewer starts in edge-to-edge fill mode; double-tap to switch between fill/fit, or pinch to zoom up to 3×.

Browser mode is access-controlled but uses plain HTTP on the trusted local network; it is not the end-to-end encrypted native protocol. Anyone on the reachable LAN who gets the full URL can view that broadcast. Generate a new private link after sharing it with an untrusted person. The browser may record normal history, network, and battery usage like any other visited page.

Each Sender installation generates an independent 80-bit random access key. The link intentionally remains stable across broadcasts so a Home Screen shortcut keeps working; **Generate a new private link** rotates the key and invalidates the previous URL. One Sender supports up to four simultaneous browser viewers.

## Background behavior

On stock iOS 18–26, a normal app or Safari page can be suspended after entering the background. There is no public entitlement that lets a sideloaded viewer or web page keep arbitrary hidden decoding alive forever.

The native Receiver declares audio playback background mode. When the mirrored app is genuinely producing audio, the receiver keeps that audio and its live session active without the former artificial 60-second cutoff. A silent stream receives only UIKit's finite completion window; iOS controls its duration, and Receiver reconnects when reopened if the system expires it.

Safari cannot continuously run the WebCodecs decoder after the user goes Home. Browser mode therefore disconnects cleanly while hidden and forces a fresh H.264/keyframe connection on `visibilitychange`, `pageshow`, focus, or network restoration. It rebuilds the fullscreen drawing surface on return and suppresses reconnect text after the first successful frame; depending on what state WebKit preserved, the viewer shows the previous frame or a plain black surface until live video resumes.

For explicitly visible background viewing:

1. While a stream is active, tap the viewer once.
2. Tap the Picture in Picture button once before leaving the app.
3. The same decoder and network session stay active in PiP.
4. Reopen Screen Share; PiP closes and the existing full-screen renderer is immediately visible.

The PiP controller is created lazily only after that explicit button tap. Returning to Home without tapping it therefore cannot create an unexpected nested mirror. PiP is a system-owned floating window and its controls cannot be hidden by a stock iOS app.

## Screen recording

Use Control Center → Screen Recording on the viewing iPhone while Screen Share is open. The viewer does not mark its layer as protected, so normal unprotected mirrored content can be recorded. iOS may show its own recording indicator, and protected/FairPlay content can remain black. Those system privacy and DRM behaviors are not removed.

## Honest platform limits

The app removes its own watermarks, banners, loading animations, reconnect sheets, and persistent controls. It does **not** bypass iOS privacy UI:

- Starting a full-display broadcast uses Apple's system confirmation sheet.
- iOS shows its capture/recording indicator while a screen is captured.
- Local Network permission appears once per installation (and again if Settings are reset).
- PiP is system UI when the user explicitly starts PiP; the app does not create it on an ordinary Home transition.
- Force-quitting either app ends its process. The sender extension automatically recovers network loss, but it cannot survive the user explicitly stopping the system broadcast.

Suppressing those system indicators would require brittle SpringBoard hooks that bypass user-visible privacy controls. This repository intentionally does not include such hooks.

## Local development

Requirements:

- macOS 26
- Xcode 26
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```sh
brew install xcodegen
make project
open ScreenShare.xcodeproj
```

Use an iPhone simulator for protocol/UI tests. ReplayKit full-display broadcasting, Bonjour behavior, VideoToolbox latency, screen recording, and PiP must be validated on physical iPhones.

```sh
make test
make build
```

## Current compatibility research

This design was checked against current documentation on 2026-07-27:

- Apple lists Xcode 26 with Swift 6.2 and the iOS 26 SDK: [Xcode 26 release notes](https://developer.apple.com/documentation/Xcode-Release-Notes/xcode-26-release-notes).
- GitHub's `macos-26` hosted image includes Xcode 26 and iOS 26 SDKs: [runner image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md).
- ReplayKit's Broadcast Upload Extension receives full-display video sample buffers through `RPBroadcastSampleHandler`: [Apple ReplayKit handler documentation](https://developer.apple.com/documentation/replaykit/rpbroadcastsamplehandler). ReplayKit is deprecated in the newest SDK documentation but remains the applicable API for the iOS 15–16.5.1 sender; ScreenCaptureKit's iOS replacement requires iOS 27.
- ReplayKit identifies captured app audio separately as `RPSampleBufferType.audioApp`; Screen Share forwards that stream but deliberately ignores microphone buffers: [ReplayKit sample-buffer types](https://developer.apple.com/documentation/replaykit/rpsamplebuffertype).
- The native receiver schedules PCM buffers through `AVAudioPlayerNode`; the browser uses Web Audio after the viewer's first tap because browsers gate audio playback behind a user gesture: [AVAudioPlayerNode `scheduleBuffer`](https://developer.apple.com/documentation/avfaudio/avaudioplayernode/schedulebuffer(_:at:options:completionhandler:)), [Web Audio API](https://www.w3.org/TR/webaudio-1.0/).
- Apple's iOS ScreenCaptureKit sample requires iOS 27 and introduces the `screen-capture` background mode there: [Capturing screen content on iOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios).
- Apple documents that an ordinary iOS app is normally suspended shortly after entering the background: [Extending background execution time](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time).
- UIKit documents `beginBackgroundTask` as a finite request that can expire and must always be ended; the receiver uses it only as the fallback for streams without active audio: [`beginBackgroundTask`](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(expirationhandler:)).
- Apple supports `AVSampleBufferDisplayLayer` as a Picture in Picture content source and requires media background configuration: [Adopting Picture in Picture in a custom player](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-custom-player).
- Apple documents that `canStartPictureInPictureAutomaticallyFromInline` starts PiP when an inline player enters the background; Screen Share deliberately leaves it disabled and requires an explicit PiP tap: [`canStartPictureInPictureAutomaticallyFromInline`](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/canstartpictureinpictureautomaticallyfrominline).
- Core Media defines `DisplayImmediately` as a per-sample attachment; the receiver also supplies valid timing and sync/dependency metadata for every H.264 frame: [`kCMSampleAttachmentKey_DisplayImmediately`](https://developer.apple.com/documentation/coremedia/kcmsampleattachmentkey_displayimmediately).
- The H.264 NAL length field may be 1, 2, or 4 bytes and must match the encoder's format description, so the sender transmits the actual value instead of making the receiver assume one: [`CMVideoFormatDescriptionCreateFromH264ParameterSets`](https://developer.apple.com/documentation/coremedia/cmvideoformatdescriptioncreatefromh264parametersets%28allocator%3Aparametersetcount%3Aparametersetpointers%3Aparametersetsizes%3Analunitheaderlength%3Aformatdescriptionout%3A%29).
- A failed sample-buffer display layer cannot be reused; the receiver observes real decode readiness/errors and replaces the layer (and its PiP content source) when required: [`AVSampleBufferDisplayLayer.status`](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/status).
- Apple exposes `AVSampleBufferDisplayLayer.preventsCapture` to distinguish protected from recordable display layers; the viewer explicitly leaves protection off: [AVSampleBufferDisplayLayer](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer).
- Bonjour requires Local Network privacy declarations and real-device testing: [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).
- Apple recommends VideoToolbox real-time and low-latency encoder configuration for conferencing: [Encoding video for low-latency conferencing](https://developer.apple.com/documentation/videotoolbox/encoding-video-for-low-latency-conferencing).
- Network.framework's `contentProcessed` completion reports when the networking stack has processed a send. The sender pipelines a bounded number of ordered sends instead of serializing the capture loop on each completion: [`NWConnection.send`](https://developer.apple.com/documentation/network/nwconnection/send(content:contentcontext:iscomplete:completion:)).
- Network.framework supports a fixed-port local listener for the receiver-free browser endpoint: [`NWListener`](https://developer.apple.com/documentation/network/nwlistener).
- Core Image renders a bounded image and Image I/O encodes the compatibility JPEG fallback: [`CIContext.createCGImage`](https://developer.apple.com/documentation/coreimage/cicontext/creategcimage(_:from:format:colorspace:)).
- Safari 16.4 and later exposes video WebCodecs for low-level real-time decoding; Browser mode uses it for the hardware H.264 path and keeps MJPEG for browsers without the API: [WebKit features in Safari 16.4](https://webkit.org/blog/13966/webkit-features-in-safari-16-4/).
- A manifest with fullscreen display mode removes browser chrome and requests an edge-to-edge Home Screen web app, while iOS remains responsible for protected system privacy indicators: [Web Push for Web Apps on iOS and iPadOS](https://webkit.org/blog/13878/web-push-for-web-apps-on-ios-and-ipados/).
- Apple provides `UIWindowScene.requestGeometryUpdate` to request landscape/portrait scene geometry; the receiver uses the remote video's intended display aspect so it fills the matching screen orientation: [`requestGeometryUpdate`](https://developer.apple.com/documentation/uikit/uiwindowscene/requestgeometryupdate(_:errorhandler:)).
- VideoToolbox's expected-frame-rate property is an encoder hint, not a guarantee; delivered FPS still depends on ReplayKit sample delivery, device hardware, thermals, and network capacity: [`kVTCompressionPropertyKey_ExpectedFrameRate`](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_expectedframerate).
- TrollStore currently documents support through iOS 16.6.1, the 16.7 RC build, and iOS 17.0: [TrollStore compatibility](https://github.com/opa334/TrollStore).
- Dopamine documents iOS 15.0–16.5.1 support on arm64e and wider ranges on arm64: [Dopamine](https://github.com/opa334/Dopamine).
- palera1n documents A8–A11 support on iOS 15 and later, with an iOS 16 passcode caveat on A11: [palera1n](https://github.com/palera1n/palera1n).

## License

MIT. See [LICENSE](LICENSE).
