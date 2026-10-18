# A9 Camera 0.4.0 — backend rewrite preview

This version replaces the connection backend and adds a local gateway for V720 station-mode firmware that connects outward to a server. The Home video panel receives bootstrap HTTP, restricted MQTT, camera control and fragmented UDP MJPEG. Direct camera-hotspot viewing remains available through a shared, typed protocol state machine.

Bluetooth setup now has explicit connection/attempt states, fresh discovery requirements, cancellation guards and bounded deadlines. Settings delivery is reported separately from a confirmed camera acknowledgement. Video decoding uses one bounded delivery queue; stale sessions cannot deliver frames after Stop or replacement.

**Validation:** direct-video and failure/timeout regressions; AddressSanitizer parser, image, provisioning and cancellation checks; 10 outward-camera gateway integration scenarios, including reconnection, peer/UID/token rejection and temporary relay HTTP/DNS forwarding; and a sandboxed GUI displaying a synthetic 2×2 MJPEG stream. Package verification checks both executables, exact sandbox permissions, signatures, privacy and checksums. The release validation and scan reports record the exact published ZIP and GitHub CI results.

**Hardware status:** no live physical-camera image or successful home Wi-Fi association has been independently confirmed. Bluetooth radio/delegate behavior in this rewrite still needs hardware validation. This is an experimental prerelease, not a verified fix for every A9 variant.

**Home-network requirements:** the camera must resolve `v720.naxclow.com` and `v720.p2p.naxclow.com` to the selected Mac IP. Its IP and UID must match the gateway configuration. On this Mac, legacy ports 80/53 require administrator access. The included temporary relay binds those ports, drops privileges to the invoking user before handling camera traffic, and stops with Control-C. It is separately signed, runs outside App Sandbox and installs no service. Only its unprivileged/high-port path has been exercised so far; its sudo bind/drop path is not hardware validated. The app copies a reviewable command and never executes sudo itself. No router configuration is changed automatically.

Requires Apple Silicon and macOS 26+. The main app has App Sandbox and Hardened Runtime; both executables are ad hoc signed and **not Apple notarized**, so Apple's developer-verification warning remains. Passing tests and a clean malware scan do not guarantee safety. Camera traffic is plaintext and camera identity is not cryptographically authenticated. H.264, audio, recording and SD-card management remain unsupported.

Verify the download with `shasum -a 256 -c SHA256SUMS.txt` and read the included START HERE, TEST-RESULTS and SECURITY-REVIEW files. Version 0.3.3 remains available separately.
