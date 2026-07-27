# Architecture

## Components

### Sender app

The sender app is a SwiftUI configuration surface. It browses Bonjour receivers, stores the selected receiver service name, pairing code, and quality preset in `group.dev.screenshare.sender`, then presents Apple's `RPSystemBroadcastPickerView`.

### Broadcast Upload Extension

ReplayKit starts `SampleHandler` outside the sender app. The handler:

1. Loads the paired receiver from the App Group.
2. Browses only `_screenshare._tcp`.
3. Connects to the exact saved Bonjour service name.
4. Authenticates with the saved pairing code.
5. passes ReplayKit video buffers to a real-time VideoToolbox H.264 encoder.
6. Sends configuration/keyframe data and subsequent frames.

The extension remains the capture owner when the sender app is no longer frontmost.

### Receiver app

The receiver creates an `NWListener`, advertises a stable Bonjour service name, accepts one authenticated sender, and feeds AVCC H.264 access units to an `AVSampleBufferDisplayLayer`. It derives the intended display aspect from the encoded dimensions plus ReplayKit orientation metadata and requests matching portrait or landscape `UIWindowScene` geometry. A new connection replaces the old connection only after it has successfully decrypted and decoded a valid `hello` packet.

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
- `orientation`: new ReplayKit image-orientation value.
- `heartbeat`: keeps an idle connection observable.
- `streamError`: reserved for a future sender error surface.

## Latency controls

- VideoToolbox uses real-time mode, no B-frame reordering, maximum frame delay zero, a one-second keyframe interval, and H.264 Baseline.
- Balanced and Sharp target 60 FPS; Data Saver targets 30 FPS. VideoToolbox treats the configured rate as a hint and actual capture/delivery can be lower.
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

For internet/WAN operation, add an authenticated relay or VPN instead of forwarding the raw listener port. Bonjour is local-link discovery and this implementation intentionally does not expose a public listener.
