# Security policy

## Reporting

Please report security issues privately to the repository owner instead of opening a public issue. Include the sender and receiver iOS versions, jailbreak/bootstrap, app build commit, network topology, and reproduction steps.

## Design boundaries

Screen Share is an explicitly user-started, local-network mirroring tool. It uses Apple's screen-broadcast confirmation and does not suppress capture indicators or attempt hidden capture.

Every application payload is authenticated and encrypted with ChaCha20-Poly1305. The pairing code is an 80-bit generated shared secret. A fresh 256-bit receiver challenge binds authentication to each connection and prevents replaying a recorded session. Rotate the code after disclosing it to anyone who should no longer connect.

This version does not implement identity certificates, multi-user authorization, a cloud relay, or safe direct exposure to the public internet. Use a trusted VPN for routed remote access; do not port-forward the receiver listener.
