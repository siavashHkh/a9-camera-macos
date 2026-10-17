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
info = plistlib.loads((root / "Info.plist").read_bytes())
version = info["CFBundleShortVersionString"]
archive = root / "dist" / f"A9-Camera-{version}-macOS-Apple-Silicon.zip"
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
assert (root / "dist/SHA256SUMS.txt").read_text().strip() == f"{digest}  {archive.name}", "checksum mismatch"
prefix = "A9 Camera/A9 Camera.app/Contents/"
with zipfile.ZipFile(archive) as bundle:
    assert bundle.testzip() is None, "ZIP integrity failure"
    for item in bundle.infolist():
        path = PurePosixPath(item.filename)
        assert not path.is_absolute() and ".." not in path.parts, "unsafe archive path"
        assert path.parts[0] == "A9 Camera", "unexpected top-level path"
        assert "__MACOSX" not in path.parts and not any(p.startswith("._") for p in path.parts), "resource fork metadata"
        assert not stat.S_ISLNK(item.external_attr >> 16), "unexpected symbolic link"
        if item.is_dir():
            continue
        data = bundle.read(item)
        assert not re.search(rb"Nax_[0-9a-fA-F]{8,}", data), "personal camera hotspot name"
        assert b"/Users/" not in data, "local user path"
        allowed = {
            prefix + "Info.plist",
            prefix + "MacOS/A9Camera",
            prefix + "_CodeSignature/CodeResources",
            "A9 Camera/START HERE.txt",
            "A9 Camera/TEST-RESULTS.md",
        }
        assert item.filename in allowed, f"unexpected packaged file: {item.filename}"
    packaged_info = plistlib.loads(bundle.read(prefix + "Info.plist"))
    assert packaged_info == info, "bundle metadata differs from source"
    assert "A9InitialPeripheralIdentifier" not in packaged_info, "seeded Bluetooth identity"
    assert not any("Location" in key for key in packaged_info), "Location usage declaration"
    executable = bundle.getinfo(prefix + "MacOS/A9Camera")
    assert executable.external_attr >> 16 & stat.S_IXUSR, "executable permission missing"

with tempfile.TemporaryDirectory(prefix="verify-release-", dir=root / "build") as temporary:
    subprocess.run(["ditto", "-x", "-k", str(archive), temporary], check=True)
    app = Path(temporary) / "A9 Camera/A9 Camera.app"
    binary = app / "Contents/MacOS/A9Camera"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    architecture = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip()
    assert architecture == "arm64", f"unexpected architectures: {architecture}"
    commands = subprocess.check_output(["otool", "-l", str(binary)], text=True)
    assert re.search(r"minos\s+" + re.escape(info["LSMinimumSystemVersion"]) + r"\s", commands), "minimum OS mismatch"
    libraries = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    assert "CoreLocation" not in libraries and "CoreWLAN" not in libraries, "unexpected Location/Wi-Fi scanner dependency"
    attributes = subprocess.check_output(["xattr", "-r", str(app)], text=True)
    assert "com.apple.quarantine" not in attributes, "quarantine metadata in package"

print(f"PASS: ZIP integrity, contents, executable permissions, privacy checks, arm64/macOS metadata, code signature, and SHA-256 ({digest})")
