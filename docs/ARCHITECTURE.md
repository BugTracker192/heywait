# Architecture

## Components

### Sender app

The sender app is a SwiftUI configuration surface. It stores the selected delivery mode and quality preset in `group.dev.screenshare.sender`, explicitly synchronizes that cross-process domain, then presents Apple's `RPSystemBroadcastPickerView`. Native mode also stores the selected Bonjour receiver and pairing code. Browser mode stores a random access key and shows a QR/local URL derived from the sender's Wi-Fi address.

The private QR points directly to the fresh v2 ReplayKit extension on port `49373`, the browser path proven reachable on the target devices. The viewer is available whenever the broadcast is live, including when the native Receiver App is selected. No foreground-app bootstrap listener is used because iOS may suspend the Sender app during the broadcast sheet or immediately after switching to the streamed app. A current App Group browser key is accepted even if the user saved or rotated the link after the extension launched.

The live server exposes the neutral `Screen Share` web-app manifest and PNG icon. The manifest preserves the access key in its installed start URL. Only the neutral icon routes are public so iOS can fetch an Add-to-Home-Screen icon after dropping the URL query; readiness, viewer, and stream routes remain key-protected. Keys are generated independently per Sender installation and remain stable until the user explicitly rotates the private link.

### Broadcast Upload Extension

ReplayKit starts `SampleHandler` outside the sender app. In native mode, the handler:

1. Loads the paired receiver from the App Group.
2. Browses only `_screenshare._tcp`.
3. Connects to the exact saved Bonjour service name.
4. Authenticates with the saved pairing code.
5. passes ReplayKit video buffers to a real-time VideoToolbox H.264 encoder and app-audio buffers to the bounded PCM transport.
6. Sends configuration/keyframe data and subsequent frames.

The extension remains the capture owner when the sender app is no longer frontmost.

The handler starts a fixed `NWListener` on live port `49373` for every broadcast, alongside native receiver discovery when native mode is selected. Authorized current browsers receive a bounded hardware-H.264 stream decoded with WebCodecs and a separate bounded PCM app-audio stream decoded with Web Audio after one user tap. A client-side compatibility path falls back to multipart MJPEG when WebCodecs or the H.264 decoder is unavailable. JPEG encoding runs on a serial worker, drops incoming capture samples while that worker is busy, and each browser keeps at most one network send outstanding. The server also monitors streaming sockets for disconnects so a failed H.264 attempt cannot remain counted and starve its MJPEG fallback. These bounds prevent a slow browser from growing the ReplayKit extension's memory.

### Receiver app

The receiver creates an `NWListener`, advertises a stable Bonjour service name, accepts one authenticated sender, and feeds AVCC H.264 access units to an `AVSampleBufferDisplayLayer`. It derives the intended display aspect from the encoded dimensions plus ReplayKit orientation metadata and requests matching portrait or landscape `UIWindowScene` geometry. A new connection replaces the old connection only after it has successfully decrypted and decoded a valid `hello` packet.

The receiver does not construct an `AVPictureInPictureController` during normal playback. It creates one only after an explicit user PiP tap, eliminating automatic nested playback on Home. A finite UIKit background task keeps the native connection warm for at most 60 seconds without visible playback; expiration stops the listener until the app becomes active again.

## Wire format

Each packet has a 20-byte big-endian header:

| Bytes | Field |
| --- | --- |
| 0–3 | ASCII magic `SSV1` |
| 4 | protocol version |
| 5 | packet kind |
| 6–7 | flags |
| 8–15 | monotonically increasing connection sequence |
| 16–19 | encrypted payload length |

The payload is a CryptoKit ChaCha20-Poly1305 combined sealed box (nonce, ciphertext, and tag). The first 16 header bytes are authenticated as additional data. The pairing key is SHA-256 over a domain-separated normalized 16-character code. The code alphabet has 32 symbols, giving 80 bits of generated entropy.

The header exposes packet type, sequence, and ciphertext length to the local network, but video/configuration contents are confidential and authenticated.

## Packet kinds

- `challenge`: a fresh 256-bit receiver nonce used to prevent replayed sessions.
- `hello`: protocol version, session UUID, sender name, timestamp, and the receiver's fresh challenge.
- `helloAcknowledgement`: proves the receiver has the same pairing key.
- `videoConfiguration`: H.264 SPS/PPS, encoded dimensions, and ReplayKit orientation.
- `videoFrame`: AVCC-formatted H.264 access unit; keyframes carry a flag.
- `audioPCM`: versioned app-audio metadata plus interleaved or planar linear PCM samples.
- `orientation`: new ReplayKit image-orientation value.
- `heartbeat`: keeps an idle connection observable.
- `streamError`: reserved for a future sender error surface.

## Latency controls

- VideoToolbox uses real-time mode, no B-frame reordering, maximum frame delay zero, a one-second keyframe interval, and H.264 Baseline.
- Sharp, Balanced, and Fast target 60 FPS. Fast reduces encoded dimensions and bitrate rather than motion cadence. VideoToolbox treats the configured rate as a hint and actual capture/delivery can be lower.
- TCP uses `noDelay` and keepalive.
- Up to sixteen encoded video frames may be outstanding, covering a quarter-second completion-delay burst at the 60 FPS target without stalling capture. ReplayKit samples are skipped before encoding only when that bounded window is full.
- Up to eight encrypted sends are submitted to Network.framework in one ordered pipeline. Completion callbacks release frame-window capacity; they no longer serialize every send.
- Every encoded frame is delivered to the receiver in TCP order. The receiver never coalesces or discards H.264 access units because later delta frames may depend on them.
- Control/configuration packets are not discarded.
- The sender forces a keyframe after authentication, resume, size change, and orientation change.
- The receiver marks every display sample `DisplayImmediately`.

The strategy applies bounded congestion control before encoding, preserves a complete decodable H.264 stream, and absorbs short networking-stack completion bursts without turning them into visible freezes. Sustained congestion still causes pre-encode capture skipping instead of unbounded latency or extension memory growth.

## Recovery

The receiver sends a new encrypted challenge on every TCP connection. The sender must return that challenge in its authenticated hello before the receiver accepts it, so a recorded hello or frame stream cannot be replayed into a later connection. The receiver listener remains advertised. The sender retries Bonjour discovery one second after disconnect and authenticates again. Video encoding is skipped while disconnected, reducing battery use. The first post-reconnect frame is forced to be independently decodable.

The receiver retains its last rendered image during transient disconnects and does not present a loading screen or reconnect prompt. A new authenticated session resets the decoder before accepting its next configuration.

## Trust model

- Designed for a trusted local network.
- No cloud service, analytics SDK, or internet relay.
- The pairing code is a shared secret; anyone who obtains it while on the reachable LAN can connect.
- Generate a new code from the receiver if it is exposed. This disconnects the sender immediately.
- Bonjour service metadata contains only a random receiver identifier and protocol version.
- Browser mode is local HTTP protected by an unguessable URL key, not the native end-to-end encrypted transport. Treat the complete URL as a secret and use it only on a trusted LAN.

For internet/WAN operation, add an authenticated relay or VPN instead of forwarding the raw listener port. Bonjour is local-link discovery and this implementation intentionally does not expose a public listener.
