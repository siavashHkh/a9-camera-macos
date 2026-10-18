#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/module-cache
swiftc -target arm64-apple-macos26.0 -module-cache-path build/module-cache Sources/CameraProtocol.swift Sources/CameraState.swift Sources/CameraFrame.swift Sources/CameraFrameDelivery.swift Sources/CameraVideo.swift Tests/main.swift -framework AppKit -framework Network -framework ImageIO -o build/CameraChecks
build/CameraChecks
mkdir -p build/failure-checks
cp Tests/FailureChecks.swift build/failure-checks/main.swift
swiftc -target arm64-apple-macos26.0 -module-cache-path build/module-cache Sources/CameraProtocol.swift Sources/CameraState.swift Sources/CameraFrame.swift Sources/CameraFrameDelivery.swift Sources/CameraVideo.swift build/failure-checks/main.swift -framework Network -framework ImageIO -o build/FailureChecks
build/FailureChecks
bash scripts/security_checks.sh
