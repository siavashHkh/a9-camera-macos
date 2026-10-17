# Security review — A9 Camera 0.3.2

Review date: 2026-10-17. This is a source review and targeted hardening effort, with adversarial-input and functional tests. It is not an independent certification or a guarantee that the app is safe.

## Scope and provenance

Reviewed the production Swift source, build/packaging/test scripts, bundle permissions, code signing, and GitHub workflow. The complete source-and-research archive's 25 file sizes and SHA-256 hashes match its supplied manifest. Its original five Swift files and build/test scripts match the recovered project used for 0.3.1. The retained and originally shipped 0.3.0 executables are identical outside the code-signature region. These comparisons establish consistency; a supplied manifest does not authenticate an author's identity, and a bit-for-bit source rebuild of the historical executable was not established.

No intentional shell execution, downloaded-code execution, login-item installation, browser/keychain reading, vendor cloud client, or telemetry was found in the production app source. Preferences store the camera IP, protocol choice, and last connected Bluetooth identifier. Snapshot writes use a user-selected save location. Provisioning credentials are held in memory to send to the selected camera, then the visible password field is cleared. Swift/OS memory may retain copies; secure erasure is not claimed.

The third-party APKs, decompiled reference sources, and three firmware candidates in the complete research archive are not dependencies of the Swift app and are excluded from this repository and release. They were not executed, flashed, or certified malware-free.

## Findings and changes

| Area | Evidence and mitigation in 0.3.2 |
| --- | --- |
| Frame queue exhaustion | The pre-fix parser returned 100,000 frames from 500,000 crafted bytes; the old video path queued one UI callback per frame. The parser now returns only the newest complete frame, the stream retains one pending JPEG, and only one decoded frame delivery is queued at a time. Display scheduling runs at about 30 Hz. This bounds queued image work rather than guaranteeing a fixed process RSS or CPU usage. |
| Image allocation limits | Compressed-byte limits did not impose a decoded-image size policy. ImageIO metadata is inspected with decoding cache disabled; images exceeding either 4096-pixel edge, 8,847,360 total pixels, 8-bit depth, or 4 MiB compressed are rejected. Full decoding then occurs off the UI thread. Crafted JPEGs with excessive declared dimensions are regression fixtures; an actual pre-fix system-wide memory exhaustion was not demonstrated. |
| Stale callbacks | Stop/restart now invalidates an independently locked generation immediately. A regression test blocks the UI while a frame arrives, stops the stream from another queue, and verifies that the old frame is suppressed. |
| Ambiguous network addresses | The original numeric check accepted leading-zero octets, which different parsers can interpret differently. Only canonical dotted decimal local IPv4 is accepted now. Private address validation is not camera identity verification or a network firewall. |
| Credential echo exposure | Unknown Bluetooth notification bytes were formatted into visible status text. A peer could echo submitted credentials. Replies now display only a generic status and byte count; tests inject an echoed test secret and check that neither its text nor its hex encoding is displayed. |
| Provisioning recipient | The UI asks for confirmation, and the Bluetooth write rechecks that the connected peripheral is the exact device selected for that operation. Input validation also runs at the write boundary. Expected service/characteristic checks are retained and callbacks must refer to the expected characteristic. These checks do not provide cryptographic authentication. |
| Bluetooth discovery | Bluetooth initialization starts on an explicit Scan action, duplicate advertisements are disabled, and retained results are capped at 128 devices. Provisioning cannot be interrupted by a new scan. |
| Host access | App Sandbox is enabled. Entitlements allow outgoing network clients, Bluetooth, and user-selected read/write files. There is no network-server entitlement, broad file-access exception, debug entitlement, disabled library validation, or executable-memory exception. Hardened Runtime is enabled. This provides containment if the app is compromised; it does not make the camera protocol secure. |
| Packaging | Fresh staging prevents stale bundle files from being carried into a release. The verifier checks allowed files, duplicate paths, an archive expansion limit, executable permissions, signature, exact entitlement set, minimum OS, and checksums. Verification uses explicit checks that remain enabled under `python3 -O`. |

## Tests and evidence

`bash test.sh` runs both V720 handshakes, decoded synthetic JPEGs, parser boundaries, rejection/H.264/malformed-packet/disconnect/timeout/cancellation cases, and the security regression suites. Security suites compile with AddressSanitizer and exercise 20,000 deterministic malformed-input iterations with seed `0xa9c0032026101701`, a 100,000-frame flood, JPEG dimension/pixel limits, credential validation/redaction, and queued-callback cancellation. Local tests passed on Apple Silicon/macOS 27.0.

The [prepared workflow](automation/ci.yml) would run the suites on macOS 26, build the distributable, and check its sandbox/runtime signature and checksum. A dependent Ubuntu job installs ClamAV, updates official signatures with FreshClam, and scans source plus the packaged ZIP. Scanner errors or detections fail that job. CI is not active yet; the configuration is published for review and is not a completed check. The release scan report identifies any completed local scan, including the exact package hash and engine/database used. A clean signature scan cannot rule out new or undetected malware. AddressSanitizer does not instrument Apple's prebuilt system frameworks and is not exhaustive fuzzing.

GUI checks use a clearly identified synthetic localhost camera and verify rendering, Stop, and saving the supplied JPEG. Bluetooth provisioning and a fresh physical-camera stream remain unverified. See TEST-RESULTS.md and the release's workflow/scan report for the completed checks on a particular build.

## Remaining risks and Apple warning

- V720 TCP video/control is plaintext and does not cryptographically authenticate the camera. The legacy `This is TEST token` value is a protocol placeholder, not a secret credential or secure authentication mechanism. Local peers or a compromised camera remain in the threat model. Use a dedicated, trusted camera network; avoid public/guest networks with untrusted peers.
- The app sends Wi-Fi setup JSON over Bluetooth. It does not implement an application encryption/authentication layer, and the peripheral's Bluetooth link encryption/pairing behavior has not been verified. A matching name and service UUID can be imitated. Prefer a dedicated camera SSID rather than disclosing your primary network credentials.
- Camera firmware may independently contact vendor services. That firmware is outside this Mac app's control. No firmware update or camera/router configuration changes were performed during this review.
- An attacker can still deny service by closing connections, withholding frames, or continuously consuming the allowed processing budget. The image caps may reduce compatibility with some cameras. ImageIO and macOS remain trusted native dependencies; keep macOS updated.
- The app is ad hoc signed. This Mac has no valid code-signing identities, so there is no Developer ID signature or Apple notarization. Gatekeeper's inability to verify this developer is expected. Runtime/sandbox signatures and checksums do not substitute for notarization. The review did not disable Gatekeeper or remove download quarantine to make the app open.

## References

- [Apple: App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
- [Apple: image decoding cache control](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcache)
- [Apple: safely opening Mac apps and notarization](https://support.apple.com/en-us/102445)
- [GitHub: hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [ClamAV: scanning and scan limitations](https://docs.clamav.net/manual/Usage/Scanning.html)
