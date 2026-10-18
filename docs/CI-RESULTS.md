# GitHub CI results

## 0.4.0 backend rewrite — 2026-10-18

[Run 39125369577](https://github.com/siavashHkh/a9-camera-macos/actions/runs/39125369577) passed both jobs for source commit `8615cd3b89592134a7d69386e5a77a7bbaaa42c5`.

- Apple Silicon/macOS 26.6.2 (25G83), Swift 6.3.3: direct-video, failure/timeout, setup/protocol-selection and AddressSanitizer checks passed, including the new gateway parsers and ten outward-camera integration scenarios.
- The archive passed privacy/content checks, both executable permissions, strict signatures, exact main-app sandbox entitlements, Hardened Runtime and minimum-OS checks. The separately signed relay has no entitlements and runs outside the main app sandbox.
- Ubuntu ClamAV 1.5.4 with daily 28157 scanned 41 files including source, relay and the CI archive: zero detections. FreshClam validated main 63, daily 28157 and bytecode 339. Its absent-clamd notification error was nonfatal; standalone scanning passed.

CI archive SHA-256: `bb26637aa92770f90e9d5e088a6626264ca2acd170a1af8e704f2b31ba3f56ea`.

The separately built public local ZIP has SHA-256 `4ab562092cff330f1a75166c8852dff5395922879a0f5ac35523bf0c5831e5cc`. Its exact local scan report is attached to the release. These are separate builds; bit-for-bit reproducibility is not claimed.

Local GUI validation displayed synthetic gateway video and restored controls after Stop. The rewritten app freshly discovered a physical A9, connected its setup service and enabled notifications; the ready state remained stable beyond the connection deadline. No credentials were sent in that check. Physical video, Wi-Fi provisioning/association, the production sudo bind/drop relay path and router DNS setup remain unverified. Neither CI nor local checks provide Apple notarization or a guarantee of safety.

## 0.3.3 — 2026-10-18

[Run 39082690324](https://github.com/siavashHkh/a9-camera-macos/actions/runs/39082690324) passed both jobs for source commit `7a33cda0f03a02e7c6d63abd0241b786100a1fcd`.

- Apple Silicon/macOS 26.6.2 (25G83), Swift 6.3.3: all core/failure, AddressSanitizer, new setup/protocol-selection integration and package-verifier regression checks passed.
- The sandboxed arm64 archive passed contents, privacy, strict code-signature, Hardened Runtime, exact entitlements, minimum OS and checksum checks.
- Ubuntu ClamAV 1.5.4 with daily 28156 scanned 31 files, including source and the CI archive: zero detections. FreshClam logged the same nonfatal absent-clamd notification error described below; standalone scanning passed.

CI archive SHA-256: `1b951d73bc62bfd9bfa6205c7c9d183e73aea07b4d056e981cf3da27aee58e17`.

The separately built and locally scanned public release ZIP has SHA-256 `b222d939825012411e7f36c9dc709e93cfeb0043214fd267f5a4a4a37cc8cf78`. The release attaches its exact local scan report plus CI evidence. Different build environments/metadata produce different hashes; bit-for-bit reproducibility is not claimed.

All automated camera traffic is simulated on localhost with fictitious credentials. These results do not establish physical-camera video or a successful Wi-Fi association, and do not provide Apple notarization or guarantee safety.

## Historical first run — 0.3.2

[Run 39066601959](https://github.com/siavashHkh/a9-camera-macos/actions/runs/39066601959) completed successfully on 2026-10-17, Europe/Helsinki. Both jobs passed for commit `b406f4f4d2c5750e7c2cdee97f729a3d2fc44704`. Production source, tests, build scripts, and entitlements are unchanged from release commit `1288797bd0fe2e750209468d97fb671f36c76462`; the later commit enables CI and updates documentation.

| Check | Result |
| --- | --- |
| Core integration and failure tests | Passed on Apple Silicon/macOS 26.6.2, build 25G83, Swift 6.3.3 |
| AddressSanitizer security regressions | Passed: image limits, 100,000-frame flood, credentials/redaction, 20,000 malformed inputs, and stale-callback cancellation |
| Package-tampering regressions | Passed under Python optimization |
| Sandboxed arm64 package | Built; contents, signature, Hardened Runtime, exact entitlements, minimum OS, and SHA-256 verified |
| ClamAV scan of source and CI ZIP | Passed on Ubuntu 24.04.5; engine 1.5.4, daily database 28156; 27 files, zero detections |

FreshClam validated and updated the main, daily, and bytecode databases. It logged a nonfatal notification error for the absent `clamd` daemon; this workflow uses standalone `clamscan`, which then completed successfully without scan warnings or detections.

The CI-created ZIP has SHA-256:

```text
91af269859c4901434af237cb654b6699b486c9620d60cd2f12f2f08ea8bde5a
```

The existing public v0.3.2 ZIP was built and scanned locally and remains unchanged, with SHA-256:

```text
1a74c403c890f941142de3be97dc1959a5c177369823dcc9162e238540cbcb81
```

These are separate builds with different documentation and build environments. Bit-for-bit reproducibility is not claimed. CI artifacts and the raw scan report are available from the linked run for 30 days; the published release retains its separate local scan report.

CI uses simulated cameras. This result does not validate physical-camera compatibility, Bluetooth provisioning, GUI operation on macOS 26, or macOS 26.0 specifically. It does not provide Apple notarization or guarantee absence of malware.

Future main-branch pushes and pull requests run this workflow automatically. To start it manually, open **Actions → Build and security checks → Run workflow**.
