# Physical-device acceptance checklist

GitHub Actions proves that both app targets and unit tests compile under Xcode 26. It cannot prove end-to-end ReplayKit, PiP, Bonjour privacy, or hardware codec behavior. Run this checklist before submitting the bounty.

## Required devices

- One jailbroken iPhone on each sender OS/device combination being claimed.
- One stock receiving iPhone on the oldest and newest viewer OS being claimed.
- A normal Wi-Fi network, a congested Wi-Fi network, and (if promised) Personal Hotspot.

## Installation and first launch

- Install the CI sender IPA directly with TrollStore and verify TrollStore reports the shared App Group entitlement on both embedded executables.
- Verify the nested `ScreenShareBroadcast.appex` is present.
- Open sender and accept Local Network once.
- Install/resign receiver with the intended third-party certificate service.
- Open receiver and accept Local Network once.
- Kill and reopen both apps; verify neither asks again.

## Pairing and security

- Receiver appears in sender discovery within five seconds.
- Correct code connects.
- One-character-wrong code never displays a frame.
- Rotating the receiver code disconnects the existing sender.
- Old code cannot reconnect; new code can.
- A second unpaired client cannot replace an authenticated live sender.

## Capture and rendering

- Full-resolution sender capture starts without ReplayKit error `-5808` or an extension memory termination.
- Home Screen, Settings, Safari, scrolling text, keyboard, and animations render.
- Portrait → landscape-left → portrait → landscape-right does not stretch or retain the previous orientation.
- The receiver window itself changes to the remote display aspect, including while the receiver phone remains physically still, with no portrait-canvas side bars around landscape games.
- Dynamic resolution change produces a new SPS/PPS and keyframe.
- Screen lock and unlock recover according to the tested jailbreak/ReplayKit version.
- Protected/FairPlay surfaces are documented if black.

## Recovery

- Toggle Wi-Fi off for 10 seconds and on again.
- Move between access points on the same LAN.
- Background and reopen the sender app while the system broadcast continues.
- Background and reopen receiver with PiP active.
- Background and reopen receiver with PiP disabled within 60 seconds; verify the native session stayed warm and no floating window appeared.
- Leave receiver backgrounded past 60 seconds; verify clean socket shutdown and automatic reconnection on reopen.
- Respring the sender: confirm that the system broadcast ends and can be restarted without re-pairing.

## Performance

Measure on balanced quality for at least 20 minutes:

- Glass-to-glass latency with a high-frame-rate timer.
- Delivered FPS during scrolling.
- Delivered FPS during a 60 FPS game; distinguish ReplayKit capture rate, encoded rate, and receiver display rate.
- Sender/receiver thermal state and battery drain.
- Memory use of the Broadcast Upload Extension; verify ReplayKit does not jetsam it.
- Queue behavior under 5–10% packet loss or high Wi-Fi contention.

If the extension is terminated under memory pressure, lower the sharp preset bitrate or use data-saver mode. Keep the outstanding-frame and in-flight-send limits bounded; removing them creates unbounded latency and extension memory use.

## Viewer UX and recording

- No app watermark, banner, spinner, or control remains after 2.5 seconds.
- Status bar/system chrome is hidden while foreground viewing.
- A tap reveals PiP and status controls.
- PiP starts only from the user control; leaving without tapping PiP does not create a floating nested mirror.
- Reopening during the bounded non-PiP background grace returns to the live session without a prompt.
- Reopening the receiver returns to the same renderer without a startup animation.
- Control Center screen recording records normal mirrored content and orientation changes.
- Document the iOS recording indicator and any protected black surfaces.

## Browser mode

- Select Browser, save, and verify the QR and copied URL contain the sender's current Wi-Fi IPv4 address, port `49373`, and a random access key.
- Open the link before starting the broadcast; verify it shows the black waiting page and automatically changes to live video after the extension starts.
- Verify Safari never reports **cannot parse response** when loading the waiting page, manifest, icon, health endpoint, or live MJPEG stream.
- Add the waiting or live page to the Home Screen; verify it is named **Screen Share**, uses the neutral Screen Share icon, reopens with the private key, and still hands over to the next broadcast.
- Start the broadcast and open the URL from Safari and at least one other browser on the same LAN.
- Verify a URL with a missing or one-character-wrong key returns HTTP 403.
- Verify portrait and both landscape directions render upright and preserve aspect ratio.
- Verify the page contains no controls or watermark after entering browser fullscreen.
- Open two simultaneous viewers and verify slow-client backpressure does not build an unbounded JPEG queue.
- Generate a new private link and verify the old URL fails on the next broadcast.
