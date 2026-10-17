# First GitHub CI result

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
