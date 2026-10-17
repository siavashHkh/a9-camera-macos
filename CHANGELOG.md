# Changelog

## 0.3.1 — 2026-10-17

- Prepare a separate public preview with Swift source and repeatable build, test, and packaging scripts.
- Remove the original machine's seeded Bluetooth identifier and camera hotspot name.
- Replace the personalized compatibility footer with a firmware-dependent support statement.
- Explicitly target Apple Silicon and macOS 26; match the bundle's minimum OS to the compiled binary.
- Extend tests with independent handshake byte fixtures, every packet split boundary, parser recovery, JPEG limits, legacy video flags, additional address validation, authentication rejection, H.264 rejection, malformed network packets, disconnects, video timeout, and cancellation.
- Include checksum verification and a synthetic local GUI test server.

The camera protocol and Bluetooth provisioning behavior otherwise remain the recovered 0.3.0 implementation. No new physical-camera compatibility is claimed.
