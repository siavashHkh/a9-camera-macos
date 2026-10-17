# Contributing

Build on Apple Silicon with macOS 26+ and an Xcode toolchain supporting that target. Run `bash test.sh`, `bash scripts/package.sh`, and `python3 scripts/verify_release.py` before proposing changes. The tests include localhost-only simulated cameras and AddressSanitizer checks.

Keep image decoding off the UI thread, preserve the image/packet limits and backpressure, and never log credentials or raw camera setup replies. Changes to permissions or entitlements need a concrete feature justification and package-verifier coverage. Pin workflow actions to reviewed commit hashes.

Use synthetic camera fixtures in tests. Exclude real camera media, saved identifiers, network credentials, vendor APKs, and firmware dumps from contributions. Report vulnerabilities privately as described in SECURITY.md.

The repository has no software license selected yet. Its public availability does not establish permission to reuse third-party research artifacts; those artifacts are excluded from this project.
