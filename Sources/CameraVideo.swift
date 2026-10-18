import Foundation
import Network

final class CameraVideo {
    var onStatus: ((String) -> Void)?
    var onFrame: ((CameraFrame) -> Void)?
    var onStopped: (() -> Void)?
    private let queue = DispatchQueue(label: "local.a9.video")
    private var connection: NWConnection?
    private var decoder = PacketDecoder()
    private var jpeg = JPEGDecoder()
    private var heartbeat: DispatchSourceTimer?
    private var displayTimer: DispatchSourceTimer?
    private var pendingJPEG: Data?
    private var frameDeliveryPending = false
    private let callbacks = CameraCallbackGate()
    private var modern = false
    private var stage = 0
    private var session = UUID()
    private var lastFrame = Date()
    private var hasFrame = false
    private var target = "deadbeef"

    static func validLocalAddress(_ host: String) -> Bool {
        guard (7...15).contains(host.utf8.count) else { return false }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({
            guard let value = UInt($0), value <= 255 else { return false }
            return String(value) == $0
        }) else { return false }
        let p = parts.map { Int($0)! }
        return p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 169 && p[1] == 254) || p[0] == 127
    }
    private func status(_ message: String, generation: UUID? = nil) {
        let current = generation ?? session
        DispatchQueue.main.async {
            guard self.callbacks.isCurrent(current) else { return }
            self.onStatus?(message)
        }
    }
    func start(host: String, modern: Bool) {
        guard Self.validLocalAddress(host) else {
            status("Enter a local IPv4 camera address, such as 192.168.169.1.", generation: callbacks.current()); return
        }
        let current = callbacks.advance()
        queue.async { [self] in
            guard self.callbacks.isCurrent(current) else { return }
            self.close()
            self.session = current
            self.modern = modern; self.stage = 0; self.hasFrame = false
            self.decoder = PacketDecoder(); self.jpeg = JPEGDecoder(); self.target = "deadbeef"
            self.lastFrame = Date()
            let c = NWConnection(host: NWEndpoint.Host(host), port: 6123, using: .tcp)
            self.connection = c
            self.status("Connecting to camera at \(host)…")
            c.stateUpdateHandler = { [weak self] state in
                guard let self = self, self.session == current, self.callbacks.isCurrent(current) else { return }
                switch state {
                case .ready:
                    self.status("Connected over Wi-Fi. Requesting video…")
                    self.stage = 1
                    if modern { self.sendJSON(["code": 115]) } else { self.send(command: 115) }
                    self.receive(c, session: current)
                    let timer = DispatchSource.makeTimerSource(queue: self.queue)
                    timer.schedule(deadline: .now() + 5, repeating: 5)
                    timer.setEventHandler { [weak self] in
                        guard let self = self, self.session == current, self.callbacks.isCurrent(current) else { return }
                        self.send(command: modern ? 9 : 100)
                        if Date().timeIntervalSince(self.lastFrame) > 18 {
                            self.fail(self.hasFrame ? "Video stopped arriving. Check camera power and reconnect." : "No video received. Try the other camera protocol; this firmware may require additional setup.")
                        }
                    }
                    self.heartbeat = timer; timer.resume()
                    let display = DispatchSource.makeTimerSource(queue: self.queue)
                    display.schedule(deadline: .now(), repeating: .milliseconds(33))
                    display.setEventHandler { [weak self] in self?.deliverFrame(generation: current) }
                    self.displayTimer = display; display.resume()
                case .failed(let error): self.fail("Camera connection failed: \(error.localizedDescription)")
                case .waiting(let error): self.status("Waiting for the camera network: \(error.localizedDescription)")
                default: break
                }
            }
            c.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + 12) {
                guard self.session == current, self.callbacks.isCurrent(current), self.stage == 0 else { return }
                self.fail("Camera is unreachable. Connect the Mac to its Wi-Fi network, or use its router-assigned IP address.")
            }
        }
    }
    func stop() {
        let current = callbacks.advance()
        queue.async {
            guard self.callbacks.isCurrent(current) else { return }
            self.close()
            self.status("Video stopped.", generation: current)
        }
    }
    private func close() {
        session = UUID(); heartbeat?.cancel(); heartbeat = nil
        displayTimer?.cancel(); displayTimer = nil
        pendingJPEG = nil; frameDeliveryPending = false
        connection?.cancel(); connection = nil
    }
    private func fail(_ text: String) {
        let current = session
        close()
        DispatchQueue.main.async {
            guard self.callbacks.isCurrent(current) else { return }
            self.onStatus?(text)
            self.onStopped?()
        }
    }
    private func deliverFrame(generation current: UUID) {
        guard session == current, callbacks.isCurrent(current), !frameDeliveryPending,
              let data = pendingJPEG else { return }
        pendingJPEG = nil
        guard let frame = CameraFrame.decode(data) else { return }
        let first = !hasFrame
        hasFrame = true; lastFrame = Date(); frameDeliveryPending = true
        DispatchQueue.main.async {
            if self.callbacks.isCurrent(current) {
                if first { self.onStatus?("Live • connected directly to camera") }
                self.onFrame?(frame)
            }
            self.queue.async {
                guard self.session == current else { return }
                self.frameDeliveryPending = false
            }
        }
    }
    private func send(command: UInt32, payload: Data = Data()) {
        let current = session
        connection?.send(content: CameraWire.packet(command: command, payload: payload, modern: modern), completion: .contentProcessed { [weak self] error in
            guard let self = self, self.session == current, self.callbacks.isCurrent(current) else { return }
            if let error = error { self.fail("Could not send to camera: \(error.localizedDescription)") }
        })
    }
    private func sendJSON(_ object: [String: Any]) {
        guard let payload = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        send(command: modern ? 8 : 0, payload: payload)
    }
    private func command(_ code: Int) { sendJSON(["code": 502, "content": ["code": code, "devTarget": target]]) }
    private func receive(_ c: NWConnection, session current: UUID) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self = self, self.session == current else { return }
            if let data = data, !data.isEmpty {
                do {
                    for packet in try self.decoder.feed(data) {
                        guard self.session == current, self.callbacks.isCurrent(current) else { break }
                        self.process(packet)
                    }
                } catch { self.fail("Unrecognized camera data. Try the other protocol."); return }
            }
            guard self.session == current, self.callbacks.isCurrent(current) else { return }
            if let error = error { self.fail("Video connection lost: \(error.localizedDescription)") }
            else if done { self.fail("Camera closed the video connection.") }
            else { self.receive(c, session: current) }
        }
    }
    private func process(_ packet: CameraPacket) {
        // Legacy packets pack flags into the upper 16 bits of this word.
        let cmd = modern ? packet.command : packet.command & 0xffff
        if cmd == (modern ? 1003 : 1) {
            for frame in jpeg.feed(packet.payload) {
                pendingJPEG = frame
            }
        } else if modern && cmd == 1001 {
            fail("This camera is sending H.264. This app supports MJPEG; H.264 decoding is not implemented.")
        } else if (!modern && cmd == 101) || (modern && cmd == 9) {
            send(command: modern ? 10 : 102)
        } else if !modern && cmd == 115 && stage == 1 {
            stage = 2
            sendJSON(["code": 501, "target": target, "token": "This is TEST token", "unixTimer": Int(Date().timeIntervalSince1970)])
        } else if cmd == (modern ? 8 : 0) {
            guard let object = (try? JSONSerialization.jsonObject(with: packet.payload)) as? [String: Any] else { return }
            let code = (object["code"] as? NSNumber)?.intValue ?? -1
            if let result = (object["status"] as? NSNumber)?.intValue, result != 0 && result != 200 {
                fail("Camera rejected the request (status \(result)). This firmware may require authentication."); return
            }
            if modern {
                if code == 115 && stage == 1 { stage = 2; sendJSON(["code": 214]) }
                else if code == 214 && stage == 2 { stage = 3; sendJSON(["code": 213, "avSwitch": 2]) }
            } else {
                if code == 501 && stage == 2 { stage = 3; command(4) }
                else if code == 502, let content = object["content"] as? [String: Any], (content["code"] as? Int) == 4, stage == 3 {
                    stage = 4; command(2)
                }
            }
        }
    }
}
