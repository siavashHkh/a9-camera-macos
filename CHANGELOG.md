# Changelog

## 0.3.3 — 2026-10-18

- Require fresh Bluetooth discovery, wait for disconnect before reconnecting, and preserve connection timeout messages. Cancel the connection timeout when setup becomes ready.
- Track Bluetooth delivery, camera acknowledgement, and disconnect separately; report missing acknowledgement as unverified. Lock setup targets and fields while sending, and suppress obsolete callbacks.
- Add classic V720 hotspot Wi-Fi provisioning (command 204, followed by restart request 299 only after acceptance). Show the target and SSID before sending and redact raw peer replies.
- Default video to automatic classic/newer selection before a first frame, with explicit protocol choices retained. Do not retry authentication or H.264 errors. Reject illegal-user status 1.
- Clear the default hotspot address after acknowledged/unconfirmed setup and explain home-network gateway limitations. Add scrollable setup guidance and a visible version in the title.
- Add simulated-camera integration and AddressSanitizer regressions for setup, rejection, disconnect, timeout, cancellation, stale generations, and protocol selection.

Physical-camera video and a successful home Wi-Fi association remain unverified. The app remains ad hoc signed and not Apple notarized.

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
