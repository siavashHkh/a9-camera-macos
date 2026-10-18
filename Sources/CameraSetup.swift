import Foundation

enum CameraSetup {
    enum ValidationError: Error { case ssid, password }
    static func payload(ssid: String, password: String) throws -> Data {
        guard !ssid.isEmpty, ssid.utf8.count <= 32 else { throw ValidationError.ssid }
        let hexKey = password.utf8.count == 64 && password.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
        guard password.isEmpty || (8...63).contains(password.utf8.count) || hexKey else {
            throw ValidationError.password
        }
        return try JSONSerialization.data(withJSONObject: ["s": ssid, "p": password, "u": ""], options: [.sortedKeys])
    }
    static func responseStatus(_ data: Data) -> String {
        if data == Data([0]) { return "Camera acknowledged Wi-Fi setup. Locate its IP address to view video." }
        // A peer could echo the credentials. Never display or log raw replies.
        return "Unrecognized camera setup response (\(data.count) bytes). Waiting for confirmation…"
    }

    static func hotspotPayload(ssid: String, password: String) throws -> Data {
        _ = try payload(ssid: ssid, password: password)
        return try JSONSerialization.data(withJSONObject: ["code": 502, "content": [
            "code": 204, "devTarget": "deadbeef", "s": ssid, "p": password
        ]], options: [.sortedKeys])
    }
}

// Tracks delivery separately from acknowledgement. A disconnect after a write
// is not proof of either a successful Wi-Fi join or a failed join.
struct CameraSetupAttempt {
    enum Phase { case idle, pending, acknowledged, unconfirmed, failed }
    private(set) var phase = Phase.idle
    private(set) var generation = UUID()
    private(set) var delivered = false
    private(set) var disconnected = false
    var isPending: Bool { phase == .pending }
    mutating func begin() -> UUID {
        generation = UUID(); phase = .pending; delivered = false; disconnected = false
        return generation
    }
    mutating func reset() { self = CameraSetupAttempt() }
    @discardableResult mutating func wrote(success: Bool, generation current: UUID) -> Bool {
        guard generation == current, isPending else { return false }
        if success { delivered = true } else { phase = .failed }
        return true
    }
    @discardableResult mutating func didDisconnect() -> Bool {
        guard isPending else { return false }
        disconnected = true
        return true
    }
    @discardableResult mutating func acknowledge(_ data: Data) -> Bool {
        guard isPending, data == Data([0]) else { return false }
        phase = .acknowledged
        return true
    }
    @discardableResult mutating func timeOut(generation current: UUID) -> Bool {
        guard generation == current, isPending else { return false }
        phase = .unconfirmed
        return true
    }
    var status: String {
        switch phase {
        case .idle: return "Connect Bluetooth to configure Wi-Fi."
        case .acknowledged: return "Camera acknowledged the settings. Verify its connection in your router; its Wi-Fi join is not yet verified."
        case .failed: return "Bluetooth could not deliver the Wi-Fi settings. Reconnect and try again."
        case .pending, .unconfirmed:
            let delivery = delivered ? "Bluetooth write completed." : "Bluetooth delivery was not confirmed."
            let link = disconnected ? " Camera disconnected or restarted." : ""
            return "\(delivery)\(link) \(isPending ? "Waiting for camera acknowledgement…" : "No camera acknowledgement; Wi-Fi join remains unverified. Check your router before sending again.")"
        }
    }
}
