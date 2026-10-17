# A9 Camera 0.3.1 — experimental macOS preview

A separate native Apple Silicon viewer for A9 / V720 cameras. Requires macOS 26 or later.

This release includes the app, Swift source, repeatable build/test scripts, and a SHA-256 checksum. It removes the original machine's saved camera identifiers, replaces personalized compatibility wording, and makes the minimum macOS version consistent between the executable and bundle metadata.

**Validation:** original archive and code-signature checks; passing classic/newer MJPEG loopback tests; parser and address checks; rejection, H.264, malformed-packet, disconnect, timeout and cancellation tests; and GUI stream/Stop/snapshot checks. The saved synthetic snapshot matched the test frame byte for byte. The packaged archive passed `scripts/verify_release.py`.

**Limits:** physical-camera streaming was not revalidated for this release. The supplied 0.3.0 guide reports a historical camera test, which is not new validation. Bluetooth provisioning and router streaming remain experimental. H.264, audio, recording, AI detection, motion alerts, and SD-card management are not implemented.

**Signing:** ad hoc signed, not Apple notarized. macOS may block downloaded copies pending per-app approval in Privacy & Security. Tested on macOS 27.0; macOS 26 runtime testing remains outstanding.

Download the ZIP and `SHA256SUMS.txt`, extract both into the same folder, and verify with `shasum -a 256 -c SHA256SUMS.txt`. Read the included `START HERE.txt` and `TEST-RESULTS.md` before connecting a camera.

No camera media, saved device identities, Wi-Fi credentials, vendor firmware, or vendor mobile app is bundled. See [full test results](https://github.com/siavashHkh/a9-camera-macos/blob/main/docs/TEST-RESULTS.md).
