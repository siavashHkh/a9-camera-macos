# A9 Camera 0.3.2 — security hardening preview

A separate native Apple Silicon viewer for A9 / V720 cameras. Requires macOS 26 or later.

This release adds macOS App Sandbox and Hardened Runtime, bounded image decoding and frame delivery, immediate cancellation of stale UI callbacks, canonical local IPv4 validation, explicit Wi-Fi provisioning confirmation, and redaction of raw camera setup replies. Bluetooth starts only when Scan is pressed.

**Validation:** both V720 MJPEG loopback handshakes and failure/timeout tests; AddressSanitizer checks for 20,000 malformed-input iterations, a 100,000-frame flood, JPEG image limits, credential handling, and stale callbacks; package-tampering regressions; and sandboxed GUI rendering and byte-identical snapshot saving. See the attached scan report for the completed local ClamAV check of the exact published release package. The [first GitHub CI run passed](https://github.com/siavashHkh/a9-camera-macos/actions/runs/39066601959), including core tests on macOS 26.6.2, package verification, and a ClamAV scan with zero detections. Its build artifacts are separate from this locally built release ZIP; see [CI results](https://github.com/siavashHkh/a9-camera-macos/blob/main/docs/CI-RESULTS.md) for hashes and scope. Passing tests and a clean signature scan do not guarantee safety.

**Limits:** physical-camera streaming was not revalidated for this release. The supplied 0.3.0 guide reports a historical camera test, which is not new validation. Bluetooth provisioning and router streaming remain experimental. H.264, audio, recording, AI detection, motion alerts, and SD-card management are not implemented.

**Signing:** sandboxed and Hardened Runtime enabled, but ad hoc signed and not Apple notarized. This Mac has no valid Developer ID signing identity, so Apple's warning remains. Local GUI tests ran on macOS 27.0; automated core tests also passed on macOS 26.6.2. GUI behavior on macOS 26 remains unverified.

**Remaining protocol risks:** V720 TCP video is unencrypted, camera identity is not cryptographically verified, and Bluetooth link encryption was not verified. Prefer a dedicated camera network. Read the [security review](https://github.com/siavashHkh/a9-camera-macos/blob/main/docs/SECURITY-REVIEW.md).

Download the ZIP and `SHA256SUMS.txt` into the same folder and verify with `shasum -a 256 -c SHA256SUMS.txt`. Read the included `START HERE.txt`, `TEST-RESULTS.md`, and `SECURITY-REVIEW.md` before connecting a camera.

No camera media, saved device identities, Wi-Fi credentials, vendor firmware, or vendor mobile app is bundled. See [full test results](https://github.com/siavashHkh/a9-camera-macos/blob/main/docs/TEST-RESULTS.md).
