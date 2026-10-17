# A9 Camera for macOS

A native Apple Silicon Mac viewer for some A9 / V720 cameras. It connects over the local network, displays MJPEG video, saves JPEG snapshots, and includes experimental Bluetooth Wi-Fi provisioning. The Mac app requires no vendor login or Location Services.

**Version 0.3.1 is an experimental public preview.** A9 is a name used by several different cameras; compatibility depends on hardware and firmware. Automated checks use simulated cameras. See [test results](docs/TEST-RESULTS.md) for the limits of validation.

## Download and open

Download `A9-Camera-0.3.1-macOS-Apple-Silicon.zip` from [Releases](https://github.com/siavashHkh/a9-camera-macos/releases). Requires an **Apple Silicon Mac and macOS 26 or later**. Intel Macs, Windows, and Linux are not supported by this build.

Extract the ZIP and open `A9 Camera.app`. This is an **ad hoc signed development build, not Apple notarized**. macOS may block a downloaded copy; approve this specific app in System Settings → Privacy & Security only if you trust the download. Bluetooth and Local Network permissions are needed for the corresponding features.

Verify the downloaded archive with the supplied `SHA256SUMS.txt`:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

## Direct camera Wi-Fi

1. Power on the camera and join its Wi-Fi hotspot using macOS Wi-Fi settings. Names often resemble `Nax_…`, A9, or V720; the app does not scan Wi-Fi names.
2. In **Camera Wi-Fi**, click **I joined camera Wi-Fi — connect**. The default camera address is `192.168.169.1`, TCP port 6123.
3. If necessary, enter a different local IPv4 address or try the other V720 protocol.
4. Use **Save snapshot** to save the current JPEG frame. **Stop** ends the stream.

Joining the camera hotspot can interrupt internet access. The Wi-Fi buttons open macOS settings; you choose the network yourself. The app accepts private, link-local, and loopback IPv4 addresses, rather than public internet addresses.

## Experimental home Wi-Fi setup

Under **Home Wi-Fi setup**, scan for the camera and connect Bluetooth. Enter its 2.4 GHz network name and password, then choose **Send Wi-Fi setup**. The app sends the details directly over Bluetooth and does not persist or log the password. It remembers the last Bluetooth device locally after a connection.

An empty vendor user ID is sent. Some firmware may reject account-free provisioning or need additional services. Finding the camera's router IP does not guarantee that local streaming will work. This app does not implement the local server or router DNS setup described in the [related V720 protocol research](https://github.com/intx82/a9-v720).

## Limits

- Physical-camera video, Bluetooth provisioning, and streaming through a home router were not revalidated for this release.
- The supplied 0.3.0 package guide reports a successful physical-camera stream on 2026-10-11. That is historical information from the supplied guide, not a result of this release's tests.
- H.264, audio, video recording, AI detection, motion alerts, and SD-card management are not implemented.
- The Mac app contains no firmware updater, vendor cloud client, or telemetry. The camera's own firmware may contact vendor services after joining a network.
- No saved camera identity, camera media, Wi-Fi credentials, vendor firmware, or vendor mobile app is included in the release.

## Build and test

Requires macOS 26+, Apple Silicon, and an Xcode toolchain with the macOS 26 SDK or later.

```sh
bash test.sh
bash build.sh
bash scripts/package.sh
python3 scripts/verify_release.py
```

Tests bind **only 127.0.0.1:6123**, which must be free. They validate packet framing, JPEG assembly, both handshakes, error reporting, timeout, and cancellation. They do not connect to physical cameras or send Wi-Fi credentials.

For optional GUI checks after running the tests:

```sh
python3 Tests/mock_camera.py
```

Enter `127.0.0.1` in the app and start video. The solid blue 2×2 image is a **synthetic test fixture**, not a camera feed. Stop the fixture with Ctrl-C. Re-enter your camera's actual IP afterward.

## Project and attribution

This is a separate macOS project, independent of the firmware recovery repository. It packages the supplied 0.3.0 app's recovered local Swift source, with public-release cleanup in 0.3.1. The archived binary was inspected separately; the recovered project was not shown to reproduce it byte for byte.

The recovered source cites [intx82/a9-v720](https://github.com/intx82/a9-v720) as protocol research. No files from that repository or its archived mobile app are bundled here. This project is not affiliated with the camera vendor or that research project. No software license has yet been specified for this repository.
