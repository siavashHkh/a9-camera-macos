# A9 Camera for macOS

A native Apple Silicon viewer and local gateway for some A9 / V720 cameras. **0.4.0 is an experimental backend rewrite.** It separates direct hotspot viewing from station-mode home-network video, uses typed protocol states, and includes Bluetooth and classic-hotspot Wi-Fi provisioning.

Requires **Apple Silicon and macOS 26+**. A9 is a product name shared by different devices; firmware compatibility varies. The app supports MJPEG and JPEG snapshots. H.264, audio playback, recording and SD-card management are not implemented.

## Download

Download `A9-Camera-0.4.0-macOS-Apple-Silicon.zip` and its reports from [Releases](https://github.com/siavashHkh/a9-camera-macos/releases). Verify the archive with:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

The app and included relay are ad hoc signed with Hardened Runtime, **not Apple notarized**. macOS may block a downloaded copy; approve this particular app in Privacy & Security only if you trust it. Bluetooth and Local Network permission are used for their respective features. Location access and a vendor account are not required by the Mac software.

## Direct camera Wi-Fi

1. Power the camera and join its hotspot in macOS Wi-Fi settings. Names often resemble `Nax_…`, A9 or V720.
2. In **Camera Wi-Fi**, choose **I joined camera Wi-Fi — connect**. The usual address is `192.168.169.1`, TCP 6123.
3. Automatic mode tries classic V720 first, then the newer handshake for protocol/stream failures before a frame. Authentication, unreachable-network and codec failures stay explicit. Both protocols can be selected manually.
4. **Stop** cancels delivery immediately. **Save snapshot** saves the current decoded JPEG through a macOS save dialog.

Joining the hotspot may interrupt internet access. Direct viewing requires a listening service on the camera; entering a station-mode camera's router IP does not create one.

## Give the camera home Wi-Fi settings

In **Wi-Fi setup**, choose Bluetooth or **Camera Wi-Fi (classic V720)**.

- Bluetooth uses a fresh nearby advertisement, then discovers the supported service and notification characteristic. Each connection permits one setup attempt. Completion, timeout, cancellation or disconnect closes it before another attempt.
- Classic hotspot setup requires the Mac to be on the camera hotspot. It shares the viewer's handshake machine, sends command 204 and requests restart 299 only after acceptance.

Enter the 2.4 GHz SSID and password, check the recipient/network confirmation, then send. The visible password is cleared only after the transport accepts the attempt. Passwords are not persisted or logged. Bluetooth sends an empty vendor user ID; firmware acceptance varies. Unknown replies are redacted.

A write acknowledgement, settings acceptance and Wi-Fi association are separate events. A disconnect without an acknowledgement is immediately **unconfirmed**. Check the router before resending. No automatic credential retry is performed.

## Home-network video

Station-mode V720 firmware can connect outward to a server instead of accepting direct video connections. **Home video** implements a local version of that path: HTTP bootstrap, camera registration/control, MQTT keepalive/subscriptions, UDP negotiation, fragment reordering, retransmission acknowledgements and bounded MJPEG delivery. The implementation follows the [provided V720 protocol research](https://github.com/intx82/a9-v720/blob/master/fake_server.md); vendor binaries and Python server code are not bundled.

This mode requires network configuration:

1. Keep the Mac and camera on the same trusted network. Select the Mac's current IPv4 address; enter the camera's router IP and UID from its label or hotspot. A pasted `Nax_` prefix is removed. Stable DHCP reservations help keep these addresses valid.
2. Configure the camera's DNS so `v720.naxclow.com` and `v720.p2p.naxclow.com` resolve to the selected Mac IP. Router host overrides or a camera-specific DNS assignment can do this. **Changing only the Mac's resolver does not configure the camera.** Routers without suitable DNS controls need a different camera network/DNS arrangement.
3. Start the gateway. The sandboxed app listens for camera control/media/MQTT only on the selected local address and accepts the configured camera IP and UID/session token. Bootstrap HTTP uses loopback port 8080; optional camera DNS uses loopback 1053.
4. macOS reserves the camera's legacy HTTP port 80 and DNS port 53. Choose **Copy relay command**, review it and run it in Terminal. The included small relay binds those ports, clears supplementary groups and drops to the invoking user's real/effective UID/GID **before receiving camera data**. It then forwards only that camera's bootstrap/DNS traffic to the app's loopback ports. This is a temporary foreground process; stop it with Control-C. It installs no service. Never send an administrator password in a chat.
5. Restart the camera. The UI reports bootstrap, registration, media negotiation and streaming separately. Keep the Mac awake and on the selected network.

The optional DNS responder answers only the two camera service names, returns no IPv6 address, and rejects unrelated DNS names. Use it only when the router assigns this Mac as DNS directly to this camera; it is not a general household resolver. The app and relay do not edit router settings, change DNS automatically, disable security protections or open public-router ports.

The physical home-network path still requires validation on the target firmware and router. Passing a simulation is not a physical-camera compatibility claim.

## Backend and security

- A shared direct-protocol state machine drives hotspot video and provisioning. Automatic fallback uses typed failures rather than matching visible status text.
- CoreBluetooth operations share one serial owner and explicit phases. Obsolete callbacks/deadlines are invalidated, fresh discovery expires, reconnect waits for cancellation and late setup replies cannot finish a later connection's attempt.
- Gateway Stop/restart drains old listeners and connections before reusing their ports. Invalid source IPs, UIDs and session tokens are rejected. HTTP, MQTT, DNS and UDP parsers have bounded inputs and buffers.
- UDP JPEG fragments are reordered within a bounded window; frames with missing fragments expire. One pending JPEG, one decoder job and one UI delivery prevent a frame flood from accumulating work.
- ImageIO decoding accepts 8-bit JPEGs up to 4 MiB compressed, 4096 pixels per edge and 8,847,360 pixels total. Decoding runs off the UI thread.
- The app uses App Sandbox and Hardened Runtime. Its exact entitlements are outgoing networking, incoming networking for the explicitly started gateway, Bluetooth and user-selected files. The relay is a separately hardened command-line program; it runs as the user after binding and does not inherit the app's sandbox. It performs no filesystem or shell operations.

The firmware protocols are plaintext and do not cryptographically prove camera identity. IP/UID/token checks limit admission but cannot prevent a local attacker from spoofing the device. Bluetooth encryption is controlled by the peripheral and has not been verified. The camera's own firmware may contact vendor services independently. See [security review](docs/SECURITY-REVIEW.md), [test results](docs/TEST-RESULTS.md) and [security policy](SECURITY.md).

## Build and test

Requires an Xcode toolchain with macOS 26 SDK or later:

```sh
bash test.sh
bash build.sh
bash scripts/package.sh
python3 scripts/verify_release.py
```

Tests use simulated cameras, fictitious identities/credentials and loopback sockets. They cover both direct handshakes; setup ordering, rejection and cancellation; malformed inputs; image/flood limits; gateway bootstrap, MQTT, UDP media, peer/identity rejection, occupied ports, active restart and temporary relay forwarding. AddressSanitizer instruments the security suites and relay tests. Tests never need administrator privileges; relay tests use high ports. Production port binding/privilege drop and physical-camera streaming need a separate explicit hardware/admin test.

The [GitHub workflow](.github/workflows/ci.yml) runs on macOS 26, verifies the archive/signatures/entitlements and scans source plus package with ClamAV. Scan results and CI package hashes apply to their recorded commit/build; a clean scan does not guarantee safety or provide Apple notarization.

## Provenance

This separate macOS project started from the supplied 0.3.0 Swift source, with public-release cleanup in 0.3.1, security hardening in 0.3.2 and connection changes in 0.3.3. Version 0.4.0 replaces backend state/transport handling and adds a native station gateway and temporary port relay. The original source/binary consistency investigation remains in the historical test report.

Protocol research is credited to [intx82/a9-v720](https://github.com/intx82/a9-v720). This is an independent implementation, not affiliated with that project or the camera vendor. No vendor APKs, firmware images, personal camera identities or Wi-Fi secrets are shipped. No software license has been specified for this repository.
