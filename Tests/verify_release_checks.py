"""Ensure malformed packages fail closed, including under Python -O."""
import hashlib
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
info = plistlib.loads((root / "Info.plist").read_bytes())
name = f"A9-Camera-{info['CFBundleShortVersionString']}-macOS-Apple-Silicon.zip"
cases = [
    ("checksum", [("A9 Camera/START HERE.txt", b"test", None)], "checksum mismatch"),
    ("duplicate", [("A9 Camera/START HERE.txt", b"one", None), ("A9 Camera/START HERE.txt", b"two", None)], "duplicate archive entry"),
    ("traversal", [("A9 Camera/../../outside", b"test", None)], "unsafe archive path"),
    ("absolute", [("/outside", b"test", None)], "unsafe archive path"),
    ("symlink", [("A9 Camera/link", b"outside", stat.S_IFLNK | 0o777)], "unexpected symbolic link"),
    ("extra executable", [("A9 Camera/unexpected", b"test", None)], "unexpected packaged file"),
    ("expansion", [("A9 Camera/START HERE.txt", bytes(8 * 1024 * 1024 + 1), None)], "archive expansion limit"),
    ("entry count", [(f"A9 Camera/{i}/", b"", None) for i in range(33)], "too many archive entries"),
]
for title, entries, expected in cases:
    with tempfile.TemporaryDirectory(prefix="verifier-test-", dir=root / "build") as folder:
        fixture = Path(folder)
        (fixture / "scripts").mkdir()
        (fixture / "dist").mkdir()
        shutil.copyfile(root / "scripts/verify_release.py", fixture / "scripts/verify_release.py")
        shutil.copyfile(root / "Info.plist", fixture / "Info.plist")
        archive = fixture / "dist" / name
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
            for path, content, mode in entries:
                entry = zipfile.ZipInfo(path)
                entry.create_system = 3
                entry.compress_type = zipfile.ZIP_DEFLATED
                entry.external_attr = (mode if mode is not None else stat.S_IFREG | 0o644) << 16
                bundle.writestr(entry, content)
        digest = "0" * 64 if title == "checksum" else hashlib.sha256(archive.read_bytes()).hexdigest()
        (fixture / "dist/SHA256SUMS.txt").write_text(f"{digest}  {name}\n")
        result = subprocess.run([sys.executable, "-O", str(fixture / "scripts/verify_release.py")], capture_output=True, text=True)
        if result.returncode == 0 or expected not in result.stderr:
            raise RuntimeError(f"{title} was not rejected as expected: {result.stdout} {result.stderr}")
        print(f"PASS: verifier rejects {title} under Python -O")
