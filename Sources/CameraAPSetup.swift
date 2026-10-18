import Foundation
import Network

// Uses the same handshake machine as the viewer. Acceptance of command 204
// precedes the reboot request and remains distinct from Wi-Fi association.
final class CameraAPSetup {
    enum Outcome: Equatable { case accepted, acceptedWithoutReboot, unconfirmed, failed }
    var onStatus: ((String) -> Void)?
    var onSetupStarted: (() -> Void)?
    var onFinished: ((Outcome) -> Void)?
    private let queue = DispatchQueue(label:"local.a9.hotspot-setup")
    private let gate = CameraCallbackGate()
    private let timeout: TimeInterval
    private var generation = UUID()
    private var connection: NWConnection?
    private var parser = PacketDecoder()
    private var protocolState = CameraDirectProtocol(.classicVideo)
    init(timeout: TimeInterval = 15) { self.timeout = timeout }
    func start(host: String, ssid: String, password: String) {
        let current = gate.advance()
        let payload = try? CameraSetup.hotspotPayload(ssid:ssid,password:password)
        queue.async { [self] in
            guard gate.isCurrent(current) else { return }
            close(); generation = current; parser = PacketDecoder()
            guard CameraVideo.validLocalAddress(host), let payload = payload else { finish(.failed,"Enter a local camera IP and valid Wi-Fi details."); return }
            DispatchQueue.main.async { guard self.gate.isCurrent(current) else { return }; self.onSetupStarted?() }
            protocolState = CameraDirectProtocol(.wifi(payload))
            let c = NWConnection(host:NWEndpoint.Host(host),port:6123,using:.tcp); connection = c
            status("Connecting to the camera hotspot for Wi-Fi setup…")
            c.stateUpdateHandler = { [weak self] state in
                guard let self = self, self.gate.isCurrent(current), self.generation == current else { return }
                switch state {
                case .ready: for data in self.protocolState.start() { self.send(data) }; self.receive(c,current:current)
                case .failed: self.endWithoutReply("Camera hotspot is unreachable. Join its Wi-Fi first.")
                default: break
                }
            }
            c.start(queue:queue)
            queue.asyncAfter(deadline:.now()+timeout) {
                guard self.gate.isCurrent(current), self.generation == current else { return }
                self.endWithoutReply("Classic V720 setup handshake timed out.")
            }
        }
    }
    func cancel() {
        let current = gate.advance()
        queue.async { guard self.gate.isCurrent(current) else { return }; self.close() }
    }
    private func close() { generation = UUID(); connection?.cancel(); connection = nil; protocolState = CameraDirectProtocol(.classicVideo) }
    private func status(_ message: String) {
        let current = generation
        DispatchQueue.main.async { guard self.gate.isCurrent(current) else { return }; self.onStatus?(message) }
    }
    private func finish(_ outcome: Outcome, _ message: String) {
        let current = generation; close()
        DispatchQueue.main.async { guard self.gate.isCurrent(current) else { return }; self.onStatus?(message); self.onFinished?(outcome) }
    }
    private func endWithoutReply(_ failure: String) {
        switch protocolState.stage {
        case .accepted: finish(.acceptedWithoutReboot,"Camera accepted settings, but restart delivery is unconfirmed. Verify the Wi-Fi join in your router.")
        case .sendingSettings: finish(.unconfirmed,"Settings sent without camera acknowledgement. Wi-Fi join remains unverified; check your router before resending.")
        default: finish(.failed,failure)
        }
    }
    private func send(_ data: Data, accepted: Bool = false) {
        let current = generation
        connection?.send(content:data,completion:.contentProcessed { [weak self] error in
            guard let self = self, self.gate.isCurrent(current), self.generation == current else { return }
            if accepted {
                self.finish(error == nil ? .accepted : .acceptedWithoutReboot,"Camera accepted the settings. Restart \(error == nil ? "requested" : "delivery unconfirmed"); Wi-Fi join is not yet verified. Check your router.")
            } else if error != nil { self.endWithoutReply("Could not complete the setup handshake.") }
        })
    }
    private func receive(_ c: NWConnection, current: UUID) {
        c.receive(minimumIncompleteLength:1,maximumLength:65536) { [weak self] data,_,done,error in
            guard let self = self, self.gate.isCurrent(current), self.generation == current else { return }
            do {
                for packet in try self.parser.feed(data ?? Data()) {
                    guard self.generation == current else { return }
                    let action = self.protocolState.receive(packet,now:Int(Date().timeIntervalSince1970))
                    if let failure = action.failure { self.finish(.failed,failure.message); return }
                    if self.protocolState.stage == .sendingSettings { self.status("Sending Wi-Fi details over the camera hotspot…") }
                    for bytes in action.writes { self.send(bytes,accepted:action.acceptedSettings) }
                }
            } catch { self.finish(.failed,"Camera returned malformed setup data."); return }
            guard self.generation == current else { return }
            if done || error != nil { self.endWithoutReply("Camera disconnected before setup completed.") }
            else { self.receive(c,current:current) }
        }
    }
}
