import Foundation
import Network

// Classic V720 hotspot command 204, followed by reboot command 299.
// Uses the documented local protocol; no vendor account or cloud calls.
final class CameraAPSetup {
    enum Outcome: Equatable { case accepted, acceptedWithoutReboot, unconfirmed, failed }
    var onStatus: ((String) -> Void)?
    var onFinished: ((Outcome) -> Void)?
    private let queue = DispatchQueue(label: "local.a9.hotspot-setup")
    private let callbacks = CameraCallbackGate()
    private let timeout: TimeInterval
    private var connection: NWConnection?
    private var session = UUID()
    private var decoder = PacketDecoder()
    private var stage = 0
    private var settings: Data?

    init(timeout: TimeInterval = 15) { self.timeout = timeout }
    private func status(_ text: String) {
        let current = session
        DispatchQueue.main.async {
            guard self.callbacks.isCurrent(current) else { return }
            self.onStatus?(text)
        }
    }
    func start(host: String, ssid: String, password: String) {
        let current = callbacks.advance()
        // Validate before opening a socket. Never put credentials in a status.
        guard CameraVideo.validLocalAddress(host),
              let payload = try? CameraSetup.hotspotPayload(ssid: ssid, password: password) else {
            queue.async {
                guard self.callbacks.isCurrent(current) else { return }
                self.close(); self.session = current
                self.finish(.failed, "Enter a local camera IP and valid Wi-Fi details.")
            }
            return
        }
        queue.async { [self] in
            guard self.callbacks.isCurrent(current) else { return }
            self.close(); self.session = current; self.decoder = PacketDecoder()
            self.stage = 0; self.settings = payload
            let connection = NWConnection(host: NWEndpoint.Host(host), port: 6123, using: .tcp)
            self.connection = connection
            self.status("Connecting to the camera hotspot for Wi-Fi setup…")
            connection.stateUpdateHandler = { [weak self] state in
                guard let self = self, self.session == current, self.callbacks.isCurrent(current) else { return }
                switch state {
                case .ready:
                    self.stage = 1
                    self.send(command: 115)
                    self.receive(connection, generation: current)
                case .failed:
                    self.endWithoutReply("Camera hotspot is unreachable. Join its Wi-Fi network first, then retry setup.")
                default: break
                }
            }
            connection.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + self.timeout) {
                guard self.session == current, self.callbacks.isCurrent(current) else { return }
                self.endWithoutReply("Camera setup handshake timed out. This fallback requires classic V720 hotspot firmware.")
            }
        }
    }
    func cancel() {
        let current = callbacks.advance()
        queue.async {
            guard self.callbacks.isCurrent(current) else { return }
            self.close()
        }
    }
    private func close() {
        session = UUID(); settings = nil
        connection?.cancel(); connection = nil
    }
    private func finish(_ outcome: Outcome, _ text: String) {
        let current = session
        close()
        DispatchQueue.main.async {
            guard self.callbacks.isCurrent(current) else { return }
            self.onStatus?(text); self.onFinished?(outcome)
        }
    }
    private func endWithoutReply(_ handshakeFailure: String) {
        if stage == 4 {
            finish(.acceptedWithoutReboot, "Camera accepted the settings, but restart delivery was not confirmed. Rejoin home Wi-Fi and check your router; Wi-Fi join remains unverified.")
        } else if stage == 3 {
            finish(.unconfirmed, "No settings acknowledgement; Wi-Fi join remains unverified. Check your router before sending again.")
        } else { finish(.failed, handshakeFailure) }
    }
    private func send(command: UInt32, payload: Data = Data()) {
        let current = session
        connection?.send(content: CameraWire.packet(command: command, payload: payload), completion: .contentProcessed { [weak self] error in
            guard let self = self, self.session == current, self.callbacks.isCurrent(current), error != nil else { return }
            self.endWithoutReply("Could not complete the camera setup handshake.")
        })
    }
    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        send(command: 0, payload: data)
    }
    private func receive(_ connection: NWConnection, generation current: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self = self, self.session == current, self.callbacks.isCurrent(current) else { return }
            if let data = data {
                do {
                    for packet in try self.decoder.feed(data) {
                        guard self.session == current else { break }
                        self.process(packet)
                    }
                } catch {
                    self.finish(.failed, "Camera returned invalid setup data. Settings were not confirmed."); return
                }
            }
            guard self.session == current, self.callbacks.isCurrent(current) else { return }
            if complete || error != nil {
                if self.stage == 4 {
                    self.finish(.acceptedWithoutReboot, "Camera accepted the settings. Rejoin home Wi-Fi and verify its router entry; a camera restart may be needed.")
                } else {
                    self.finish(self.stage >= 3 ? .unconfirmed : .failed, "Camera disconnected without confirming settings. Wi-Fi join remains unverified.")
                }
            } else { self.receive(connection, generation: current) }
        }
    }
    private func process(_ packet: CameraPacket) {
        let command = packet.command & 0xffff
        if command == 115, stage == 1 {
            stage = 2
            sendJSON(["code": 501, "target": "deadbeef", "token": "This is TEST token", "unixTimer": Int(Date().timeIntervalSince1970)])
            return
        }
        guard command == 0,
              let object = (try? JSONSerialization.jsonObject(with: packet.payload)) as? [String: Any],
              let code = object["code"] as? Int else { return }
        if let result = (object["status"] as? NSNumber)?.intValue, result != 0 && result != 200 {
            finish(.failed, "Camera rejected Wi-Fi setup (status \(result)). Settings were not confirmed."); return
        }
        if code == 501, stage == 2, let data = settings {
            stage = 3; settings = nil
            status("Sending Wi-Fi details over the camera hotspot…")
            send(command: 0, payload: data)
        } else if code == 502, stage == 3,
                  let content = object["content"] as? [String: Any], content["code"] as? Int == 204 {
            if let result = (content["status"] as? NSNumber)?.intValue, result != 0 && result != 200 {
                finish(.failed, "Camera rejected the Wi-Fi settings (status \(result))."); return
            }
            stage = 4
            let reboot: [String: Any] = ["code": 502, "content": ["code": 299, "devTarget": "deadbeef"]]
            guard let data = try? JSONSerialization.data(withJSONObject: reboot, options: [.sortedKeys]) else {
                endWithoutReply("Could not encode restart request."); return
            }
            let current = session
            connection?.send(content: CameraWire.packet(command: 0, payload: data), completion: .contentProcessed { [weak self] error in
                guard let self = self, self.session == current, self.callbacks.isCurrent(current) else { return }
                self.finish(error == nil ? .accepted : .acceptedWithoutReboot,
                    error == nil ? "Camera accepted the settings; restart requested. Rejoin home Wi-Fi and verify its router entry. Wi-Fi join is not yet verified." : "Camera accepted settings, but restart delivery was not confirmed. Rejoin home Wi-Fi and check your router.")
            })
        }
    }
}
