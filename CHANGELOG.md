# Changelog

## 0.3.2 — 2026-10-17

- Enable App Sandbox with only outgoing networking, Bluetooth, and user-selected file access, plus Hardened Runtime.
- Bound JPEG dimensions and pixel count before full decoding; decode off the main thread and coalesce frame floods with backpressure.
- Invalidate pending callbacks synchronously on Stop/restart.
- Reject ambiguous IPv4 addresses with leading zeros.
- Initialize Bluetooth only on Scan, suppress duplicate advertisements, and cap discovery results.
- Confirm Wi-Fi provisioning recipients, recheck the connected device before sending, validate inputs at the Bluetooth boundary, and redact raw setup responses.
- Preserve the useful setup-acknowledgement status across disconnects.
- Build and package from fresh staging directories; reject duplicate/oversized ZIP entries and verify runtime/sandbox entitlements. Verification stays active with Python optimization enabled.
- Add deterministic malformed-input, image-limit, frame-flood, credential, and queued-callback tests under AddressSanitizer.
- Prepare pinned GitHub Actions for macOS 26 build/tests/package checks and ClamAV scans (not yet active), plus weekly Actions dependency configuration and security/contribution documentation.

Apple Developer ID signing and notarization remain unavailable. Camera transport encryption and device authentication are not added by this release; see the security review.

## 0.3.1 — 2026-10-17

- Prepare a separate public preview with Swift source and repeatable build, test, and packaging scripts.
- Remove the original machine's seeded Bluetooth identifier and camera hotspot name.
- Replace the personalized compatibility footer with a firmware-dependent support statement.
- Explicitly target Apple Silicon and macOS 26; match the bundle's minimum OS to the compiled binary.
- Extend tests with independent handshake byte fixtures, every packet split boundary, parser recovery, JPEG limits, legacy video flags, additional address validation, authentication rejection, H.264 rejection, malformed network packets, disconnects, video timeout, and cancellation.
- Include checksum verification and a synthetic local GUI test server.

The camera protocol and Bluetooth provisioning behavior otherwise remain the recovered 0.3.0 implementation. No new physical-camera compatibility is claimed.
