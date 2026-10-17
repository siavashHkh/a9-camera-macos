# A9 Camera validation

## Current release: 0.3.2

The full integration/failure suite passed again after security hardening on Apple Silicon/macOS 27.0. Additional AddressSanitizer checks passed for valid/invalid image decoding, dimension and pixel limits, a 100,000-frame flood, credential validation/escaping and response redaction, 20,000 deterministic malformed-input iterations, and cancellation of a queued frame while the UI is busy. Package-verifier regressions also reject checksum changes, duplicate entries, traversal, absolute paths, symlinks, unexpected files, expansion limits, and excess entry counts under Python optimization.

The current app enables App Sandbox and Hardened Runtime. A local sandboxed build opened successfully and displayed a synthetic 2×2 localhost stream. Its Save dialog wrote a snapshot that exactly matched the supplied JPEG (SHA-256 `7a0817ea620dca22254a38c56df45cd4d5cadf8dbc6e6066bc495613368e0969`). The [security review](SECURITY-REVIEW.md) describes exact limits and remaining risks. The [first GitHub CI run](https://github.com/siavashHkh/a9-camera-macos/actions/runs/39066601959) passed the integration, failure, AddressSanitizer, and package checks on Apple Silicon/macOS 26.6.2, followed by a successful ClamAV scan with zero detections. See [CI results](https://github.com/siavashHkh/a9-camera-macos/blob/main/docs/CI-RESULTS.md) for the tested commit and CI package hash. The release's scan report records the separate local antivirus check of the published ZIP. Historical GUI results below apply to 0.3.1.

## Historical baseline: 0.3.1

Test date: **2026-10-17**, Europe/Helsinki. Host: Apple Silicon, macOS 27.0 build 26A428; macOS 27 SDK. The release explicitly targets arm64 and macOS 26.0. At this baseline stage, runtime testing on macOS 26 itself had not yet been performed; the later 0.3.2 CI results above cover automated checks on macOS 26.6.2.

## Supplied 0.3.0 archive

The original `A9-Camera-0.3.0-macOS-Apple-Silicon.zip` was inspected without modifying it. Its SHA-256 is `e521a69b8a238fd99df9d536e6254b5c0cf51b8d62b6965bc2d631be604a699b`.

- ZIP contents enumerated and extracted successfully.
- The executable is arm64 and its Mach-O minimum OS is macOS 26.0.
- `codesign --verify --deep --strict` passed. The signature is ad hoc, with no Apple developer team identity.
- Gatekeeper assessment rejected the original app. This is not a notarized distribution.
- Linked libraries are Apple system frameworks/libraries; no external runtime is bundled.
- The guide and bundle contain personal camera identifiers. Those identifiers are absent from the 0.3.1 public source and package.
- The guide reports a successful physical-camera stream on 2026-10-11. This historical claim was not independently reproduced during this release work.

The recovered Swift project identifies itself as 0.3.0, but its old plist said macOS 13 while the supplied executable requires macOS 26. Its source and archived binary have not been proven identical. The new release is rebuilt from the recovered source, with the changes listed in the changelog.

## Automated source checks — passed

The existing tests passed before release cleanup. The expanded tests also passed after cleanup. Tests use only a simulated camera at **127.0.0.1:6123** and synthetic images.

| Check | Result |
| --- | --- |
| Independent classic and modern handshake wire fixtures | Passed |
| Byte-at-a-time and every split boundary packet delivery | Passed |
| Coalesced packets and Data with a nonzero start index | Passed |
| Oversized packet rejection and parser recovery | Passed |
| Split JPEG markers, multiple frames, size limit, recovery | Passed |
| Private/link-local/loopback address acceptance; malformed/public address rejection | Passed |
| Classic handshake and decoded 2×2 JPEG, including upper command flag bits | Passed |
| Newer firmware handshake and decoded 2×2 JPEG | Passed |
| Camera authentication rejection (status 403) | Passed |
| Unsupported H.264 reports an explicit error | Passed |
| Oversized packet received over TCP reports an error | Passed |
| Peer disconnect reports a stopped connection | Passed |
| Silent camera reaches the no-video timeout | Passed |
| Explicit Stop cancels without an error callback | Passed |

Run with `bash test.sh`. The suites have watchdogs and exit nonzero on failure. The failure suite exercises the production timeout, so it normally takes about 20 seconds.

## GUI checks — passed

The rebuilt 0.3.1 app was opened on the test host.

- Startup shows the generalized camera hotspot guidance and updated footer. Start is enabled; Stop and Save snapshot are disabled before any stream.
- Entering public IP `8.8.8.8` and pressing Start is rejected without starting video.
- With `Tests/mock_camera.py`, classic and newer protocols both display a synthetic 2×2 blue image. Start becomes disabled; Stop and Save snapshot become enabled.
- Saving a JPEG through the macOS save dialog succeeds. Its SHA-256 matches the supplied synthetic frame byte for byte: `7a0817ea620dca22254a38c56df45cd4d5cadf8dbc6e6066bc495613368e0969`.
- Stop returns to the last-frame/stopped state and re-enables Start.
- Trying the physical camera's default IP, `192.168.169.1`, reaches the unreachable-camera error and re-enables Start; no physical video was received.
- The Home Wi-Fi setup tab opens. Connect Bluetooth and Send Wi-Fi setup remain disabled without a discovered/connected camera. No Wi-Fi credentials were entered or transmitted.

The GUI's synthetic stream is test evidence for rendering and snapshot behavior, not physical-camera compatibility. The synthetic images are not included in the downloadable app.

## Package checks

`python3 scripts/verify_release.py` passed. It checks ZIP integrity and allowed contents; excludes resource forks, personal hotspot names, local user paths and a seeded Bluetooth ID; validates executable permissions, code signature, arm64 architecture and matching minimum OS; and checks SHA-256 against the included checksum file.

## Still unverified

- A fresh physical A9-camera stream: the test host had no direct route to the camera hotspot during this session.
- Bluetooth discovery, connection, notifications, and Wi-Fi provisioning against hardware.
- Account-free setup or video streaming through a home router.
- Other camera models/firmware, GUI operation on macOS 26, and runtime behavior on macOS 26.0 specifically. Automated core tests passed on macOS 26.6.2.
- Launch of a fresh internet-downloaded copy after per-app Gatekeeper approval.

The release remains an **experimental public preview**. The tests do not establish universal A9 compatibility or a complete security audit.
