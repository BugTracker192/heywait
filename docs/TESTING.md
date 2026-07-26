# Physical-device acceptance checklist

GitHub Actions proves that both app targets and unit tests compile under Xcode 26. It cannot prove end-to-end ReplayKit, PiP, Bonjour privacy, or hardware codec behavior. Run this checklist before submitting the bounty.

## Required devices

- One jailbroken iPhone on each sender OS/device combination being claimed.
- One stock receiving iPhone on the oldest and newest viewer OS being claimed.
- A normal Wi-Fi network, a congested Wi-Fi network, and (if promised) Personal Hotspot.

## Installation and first launch

- Install the unsigned sender IPA with TrollStore.
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

- Home Screen, Settings, Safari, scrolling text, keyboard, and animations render.
- Portrait → landscape-left → portrait → landscape-right does not stretch or retain the previous orientation.
- Dynamic resolution change produces a new SPS/PPS and keyframe.
- Screen lock and unlock recover according to the tested jailbreak/ReplayKit version.
- Protected/FairPlay surfaces are documented if black.

## Recovery

- Toggle Wi-Fi off for 10 seconds and on again.
- Move between access points on the same LAN.
- Background and reopen the sender app while the system broadcast continues.
- Background and reopen receiver with PiP active.
- Background and reopen receiver with PiP disabled; verify automatic reconnection and retained last frame.
- Respring the sender: confirm that the system broadcast ends and can be restarted without re-pairing.

## Performance

Measure on balanced quality for at least 20 minutes:

- Glass-to-glass latency with a high-frame-rate timer.
- Delivered FPS during scrolling.
- Sender/receiver thermal state and battery drain.
- Memory use of the Broadcast Upload Extension; verify ReplayKit does not jetsam it.
- Queue behavior under 5–10% packet loss or high Wi-Fi contention.

If the extension is terminated under memory pressure, lower the sharp preset bitrate or use data-saver mode. Do not increase the outgoing frame queue; that increases latency and extension memory use.

## Viewer UX and recording

- No app watermark, banner, spinner, or control remains after 2.5 seconds.
- Status bar/system chrome is hidden while foreground viewing.
- A tap reveals PiP and status controls.
- PiP starts from the user control and automatic PiP follows the device setting.
- Reopening the receiver returns to the same renderer without a startup animation.
- Control Center screen recording records normal mirrored content and orientation changes.
- Document the iOS recording indicator and any protected black surfaces.

