#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/security-unit build/security-callback build/setup-selection build/module-cache
sources=(Sources/CameraProtocol.swift Sources/CameraState.swift Sources/CameraFrame.swift Sources/CameraFrameDelivery.swift Sources/CameraVideo.swift Sources/CameraSetup.swift)
cp Tests/SecurityChecks.swift build/security-unit/main.swift
swiftc -g -sanitize=address -target arm64-apple-macos26.0 -module-cache-path build/module-cache "${sources[@]}" build/security-unit/main.swift -framework AppKit -framework ImageIO -framework Network -o build/SecurityChecks
build/SecurityChecks
cp Tests/CallbackChecks.swift build/security-callback/main.swift
swiftc -g -sanitize=address -target arm64-apple-macos26.0 -module-cache-path build/module-cache "${sources[@]}" build/security-callback/main.swift -framework AppKit -framework ImageIO -framework Network -o build/CallbackChecks
build/CallbackChecks
cp Tests/SetupAndSelectionChecks.swift build/setup-selection/main.swift
swiftc -g -sanitize=address -target arm64-apple-macos26.0 -module-cache-path build/module-cache "${sources[@]}" Sources/CameraAPSetup.swift Sources/CameraVideoController.swift build/setup-selection/main.swift -framework AppKit -framework ImageIO -framework Network -o build/SetupAndSelectionChecks
build/SetupAndSelectionChecks
mkdir -p build/gateway-unit build/gateway-network
swiftc -g -sanitize=address -target arm64-apple-macos26.0 -module-cache-path build/module-cache Relay/SocketRelay.swift -o build/A9CameraRelay
cp Tests/GatewayProtocolChecks.swift build/gateway-unit/main.swift
swiftc -g -sanitize=address -target arm64-apple-macos26.0 -module-cache-path build/module-cache "${sources[@]}" Sources/CameraGatewayProtocol.swift Sources/CameraRelayCommand.swift build/gateway-unit/main.swift -framework AppKit -framework ImageIO -framework Network -o build/GatewayProtocolChecks
build/GatewayProtocolChecks
cp Tests/GatewayIntegrationChecks.swift build/gateway-network/main.swift
swiftc -g -sanitize=address -target arm64-apple-macos26.0 -module-cache-path build/module-cache "${sources[@]}" Sources/CameraGatewayProtocol.swift Sources/CameraGateway.swift build/gateway-network/main.swift -framework AppKit -framework ImageIO -framework Network -o build/GatewayIntegrationChecks
build/GatewayIntegrationChecks
python3 Tests/verify_release_checks.py
