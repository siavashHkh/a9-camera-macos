import Foundation

enum CameraRelayCommand {
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of:"'",with:#"'\''"#) + "'" }
    static func make(executable: String, local: String, camera: String, dns: Bool) -> String {
        var command = "sudo -- " + quote(executable) + " --listen " + quote(local) + " --camera " + quote(camera) + " --http-target 8080"
        if dns { command += " --dns-target 1053" }
        return command
    }
}
