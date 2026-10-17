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
}
