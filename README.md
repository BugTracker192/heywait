# Screen Share

Screen Share is a two-app, local-network screen mirroring system:

- **Screen Share Sender** runs on the jailbroken iPhone (iOS 15.0–16.5.1). It contains a ReplayKit Broadcast Upload Extension, so it can capture the full display after the user starts one system broadcast.
- **Screen Share** runs on the viewing iPhone (iOS 18–26, with a deployment target of iOS 15). It discovers the sender over Bonjour, decrypts the live H.264 stream, and renders it edge-to-edge with no app watermark or persistent app controls.

The repository has no runtime binary dependencies. XcodeGen creates the project and the GitHub Actions workflow builds both IPAs on a `macos-26` runner with Xcode 26. The sender is fake-signed with `ldid` so TrollStore can preserve the App Group shared with its ReplayKit extension; the receiver remains unsigned for certificate-based sideloading.

## What is implemented

- Full-display ReplayKit capture from the sender, including other apps and orientation changes.
- Hardware H.264 encoding through VideoToolbox at 20 or 30 FPS, with quality-specific resolution bounds to stay within ReplayKit's extension memory budget.
- Hardware-backed low-delay display with `AVSampleBufferDisplayLayer`.
- Bonjour discovery, automatic reconnect, TCP no-delay, keepalive, and a bounded frame queue that drops stale frames instead of accumulating latency.
- 16-character local pairing code and ChaCha20-Poly1305 authenticated encryption for every control and video payload.
- Clean full-screen viewer. Controls appear only after a tap and automatically disappear.
- Session persistence across transient Wi-Fi loss and app reopening.
- Picture in Picture for supported background viewing.
- Normal iOS screen recording of the unprotected viewer surface.
- Portrait and landscape handling.
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
- `dev.screenshare.sender.broadcast`
- `group.dev.screenshare.sender`

Update them consistently in `project.yml`, `Config/*.entitlements`, and `Sources/Shared/AppConstants.swift`.

### 3. Install the receiver

Resign and install `ScreenShare-Receiver-unsigned.ipa` with the certificate provider or sideloading tool used by the iOS 18–26 device. The receiver has no App Group or private entitlement.

Open **Screen Share** once and allow **Local Network** access. Keep the pairing-code screen visible for initial setup.

### 4. Pair and share

1. Put both iPhones on the same Wi-Fi network. Personal Hotspot or peer-to-peer Bonjour can also work when the network permits discovery.
2. On the sender, choose the receiver shown under **Choose receiver**.
3. Enter the 16-character code shown on the receiver.
4. Choose quality and tap **Save receiver**.
5. Tap the round iOS broadcast button.
6. In the system sheet, choose/start **Screen Share**.

After that, the receiver switches to the live screen automatically. A tap reveals the connection and Picture in Picture controls for 2.5 seconds.

## Background behavior

On stock iOS 18–26, a normal app is suspended shortly after it enters the background. There is no public entitlement that lets a sideloaded viewer keep an arbitrary hidden TCP session alive forever.

This project uses Apple's supported live-video path:

1. While a stream is active, tap the viewer once.
2. Tap the Picture in Picture button once, or enable **Settings → General → Picture in Picture → Start PiP Automatically** and leave the app while the video is active.
3. The same decoder and network session stay active in PiP.
4. Reopen Screen Share; PiP closes and the existing full-screen renderer is immediately visible.

PiP is a system-owned floating window while the viewer is minimized. Its controls cannot be hidden by a stock iOS app. If PiP is disabled by the user or unavailable, iOS may suspend the receiver; it will reconnect automatically without a prompt when reopened and keeps the last decoded frame visible during the reconnect.

## Screen recording

Use Control Center → Screen Recording on the viewing iPhone while Screen Share is open. The viewer does not mark its layer as protected, so normal unprotected mirrored content can be recorded. iOS may show its own recording indicator, and protected/FairPlay content can remain black. Those system privacy and DRM behaviors are not removed.

## Honest platform limits

The app removes its own watermarks, banners, loading animations, reconnect sheets, and persistent controls. It does **not** bypass iOS privacy UI:

- Starting a full-display broadcast uses Apple's system confirmation sheet.
- iOS shows its capture/recording indicator while a screen is captured.
- Local Network permission appears once per installation (and again if Settings are reset).
- PiP is system UI when the receiver is backgrounded.
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

This design was checked against current documentation on 2026-07-26:

- Apple lists Xcode 26 with Swift 6.2 and the iOS 26 SDK: [Xcode 26 release notes](https://developer.apple.com/documentation/Xcode-Release-Notes/xcode-26-release-notes).
- GitHub's `macos-26` hosted image includes Xcode 26 and iOS 26 SDKs: [runner image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md).
- ReplayKit's Broadcast Upload Extension receives full-display video sample buffers through `RPBroadcastSampleHandler`: [Apple ReplayKit handler documentation](https://developer.apple.com/documentation/replaykit/rpbroadcastsamplehandler). ReplayKit is deprecated in the newest SDK documentation but remains the applicable API for the iOS 15–16.5.1 sender; ScreenCaptureKit's iOS replacement requires iOS 27.
- Apple's iOS ScreenCaptureKit sample requires iOS 27 and introduces the `screen-capture` background mode there: [Capturing screen content on iOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios).
- Apple documents that an ordinary iOS app is normally suspended shortly after entering the background: [Extending background execution time](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time).
- Apple supports `AVSampleBufferDisplayLayer` as a Picture in Picture content source and requires media background configuration: [Adopting Picture in Picture in a custom player](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-custom-player).
- Apple exposes `AVSampleBufferDisplayLayer.preventsCapture` to distinguish protected from recordable display layers; the viewer explicitly leaves protection off: [AVSampleBufferDisplayLayer](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer).
- Bonjour requires Local Network privacy declarations and real-device testing: [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).
- Apple recommends VideoToolbox real-time and low-latency encoder configuration for conferencing: [Encoding video for low-latency conferencing](https://developer.apple.com/documentation/videotoolbox/encoding-video-for-low-latency-conferencing).
- TrollStore currently documents support through iOS 16.6.1, the 16.7 RC build, and iOS 17.0: [TrollStore compatibility](https://github.com/opa334/TrollStore).
- Dopamine documents iOS 15.0–16.5.1 support on arm64e and wider ranges on arm64: [Dopamine](https://github.com/opa334/Dopamine).
- palera1n documents A8–A11 support on iOS 15 and later, with an iOS 16 passcode caveat on A11: [palera1n](https://github.com/palera1n/palera1n).

## License

MIT. See [LICENSE](LICENSE).
