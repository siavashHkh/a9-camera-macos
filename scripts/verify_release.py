#!/usr/bin/env python3
"""Verify the distributable archive without launching the app."""
import hashlib
import plistlib
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
def require(condition, message):
    if not condition:
        raise RuntimeError(message)

info = plistlib.loads((root / "Info.plist").read_bytes())
expected_entitlements = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.network.client": True,
    "com.apple.security.network.server": True,
    "com.apple.security.device.bluetooth": True,
    "com.apple.security.files.user-selected.read-write": True,
}
version = info["CFBundleShortVersionString"]
archive = root / "dist" / f"A9-Camera-{version}-macOS-Apple-Silicon.zip"
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
require((root / "dist/SHA256SUMS.txt").read_text().strip() == f"{digest}  {archive.name}", "checksum mismatch")
prefix = "A9 Camera/A9 Camera.app/Contents/"
with zipfile.ZipFile(archive) as bundle:
    entries = bundle.infolist()
    require(len(entries) <= 32, "too many archive entries")
    require(len({entry.filename for entry in entries}) == len(entries), "duplicate archive entry")
    require(sum(entry.file_size for entry in entries) <= 8 * 1024 * 1024, "archive expansion limit exceeded")
    require(bundle.testzip() is None, "ZIP integrity failure")
    for item in bundle.infolist():
        path = PurePosixPath(item.filename)
        require(not path.is_absolute() and ".." not in path.parts, "unsafe archive path")
        require(path.parts and path.parts[0] == "A9 Camera", "unexpected top-level path")
        require("__MACOSX" not in path.parts and not any(p.startswith("._") for p in path.parts), "resource fork metadata")
        require(not stat.S_ISLNK(item.external_attr >> 16), "unexpected symbolic link")
        require(item.external_attr >> 16 & (stat.S_ISUID | stat.S_ISGID | stat.S_ISVTX) == 0, "unexpected privileged file mode")
        if item.is_dir():
            continue
        data = bundle.read(item)
        require(not re.search(rb"Nax_[0-9a-fA-F]{8,}", data), "personal camera hotspot name")
        # The protocol's literal MQTT topic contains /Users/; it is not a
        # macOS home directory. Exempt that exact prefix, retaining the check
        # for every other occurrence in binaries and documentation.
        privacy_data = data.replace(b"Naxclow/P2P/Users/Device/", b"CAMERA_MQTT_TOPIC/")
        require(b"/Users/" not in privacy_data, "local user path")
        allowed = {
            prefix + "Info.plist",
            prefix + "MacOS/A9Camera",
            prefix + "Helpers/A9CameraRelay",
            prefix + "_CodeSignature/CodeResources",
            "A9 Camera/START HERE.txt",
            "A9 Camera/TEST-RESULTS.md",
            "A9 Camera/SECURITY-REVIEW.md",
        }
        require(item.filename in allowed, f"unexpected packaged file: {item.filename}")
    packaged_info = plistlib.loads(bundle.read(prefix + "Info.plist"))
    require(packaged_info == info, "bundle metadata differs from source")
    require("A9InitialPeripheralIdentifier" not in packaged_info, "seeded Bluetooth identity")
    require(not any("Location" in key for key in packaged_info), "Location usage declaration")
    for name in ("MacOS/A9Camera", "Helpers/A9CameraRelay"):
        executable = bundle.getinfo(prefix + name)
        require(executable.external_attr >> 16 & stat.S_IXUSR, f"executable permission missing: {name}")

with tempfile.TemporaryDirectory(prefix="verify-release-", dir=root / "build") as temporary:
    subprocess.run(["ditto", "-x", "-k", str(archive), temporary], check=True)
    app = Path(temporary) / "A9 Camera/A9 Camera.app"
    binary = app / "Contents/MacOS/A9Camera"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    relay = app / "Contents/Helpers/A9CameraRelay"
    subprocess.run(["codesign", "--verify", "--strict", str(relay)], check=True)
    require(subprocess.check_output(["lipo", "-archs", str(relay)], text=True).strip() == "arm64", "unexpected relay architecture")
    relay_signing = subprocess.check_output(["codesign", "-dv", "--verbose=4", str(relay)], stderr=subprocess.STDOUT, text=True)
    require(re.search(r"flags=0x[0-9a-f]+\([^\n]*\bruntime\b", relay_signing), "relay hardened runtime disabled")
    relay_entitlements = subprocess.check_output(["codesign", "-d", "--entitlements", ":-", str(relay)], stderr=subprocess.DEVNULL)
    require(not relay_entitlements.strip() or plistlib.loads(relay_entitlements) == {}, "unexpected relay entitlements")
    relay_commands = subprocess.check_output(["otool", "-l", str(relay)], text=True)
    require(re.search(r"minos\s+" + re.escape(info["LSMinimumSystemVersion"]) + r"\s", relay_commands), "relay minimum OS mismatch")
    signing = subprocess.check_output(["codesign", "-dv", "--verbose=4", str(app)], stderr=subprocess.STDOUT, text=True)
    require(re.search(r"flags=0x[0-9a-f]+\([^\n]*\bruntime\b", signing), "hardened runtime disabled")
    entitlements = subprocess.check_output(["codesign", "-d", "--entitlements", ":-", str(app)], stderr=subprocess.DEVNULL)
    require(plistlib.loads((root / "Entitlements.plist").read_bytes()) == expected_entitlements, "source sandbox entitlements exceed the reviewed allowlist")
    require(plistlib.loads(entitlements) == expected_entitlements, "unexpected sandbox entitlements")
    architecture = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip()
    require(architecture == "arm64", f"unexpected architectures: {architecture}")
    commands = subprocess.check_output(["otool", "-l", str(binary)], text=True)
    require(re.search(r"minos\s+" + re.escape(info["LSMinimumSystemVersion"]) + r"\s", commands), "minimum OS mismatch")
    libraries = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    require("CoreLocation" not in libraries and "CoreWLAN" not in libraries, "unexpected Location/Wi-Fi scanner dependency")
    attributes = subprocess.check_output(["xattr", "-r", str(app)], text=True)
    require("com.apple.quarantine" not in attributes, "quarantine metadata in package")

print(f"PASS: ZIP integrity, contents, executable permissions, privacy checks, arm64/macOS metadata, sandbox/hardened signing, and SHA-256 ({digest})")
