import Foundation
import Network

final class CameraVideo {
    var onStatus: ((String) -> Void)?
    var onFrame: ((CameraFrame) -> Void)?
    var onStopped: (() -> Void)?
    var onFailure: ((CameraFailure) -> Void)?
    var onState: ((CameraVideoState) -> Void)?
    private let queue = DispatchQueue(label: "local.a9.video")
    private var connection: NWConnection?
    private var decoder = PacketDecoder()
    private var jpeg = JPEGDecoder()
    private var heartbeat: DispatchSourceTimer?
    private let frames = CameraFrameDelivery()
    private let callbacks = CameraCallbackGate()
    private var modern = false
    private var stage = 0
    private var session = UUID()
    private var lastFrame = Date()
    private var hasFrame = false
    private var handshake = CameraDirectProtocol(.classicVideo)

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
            self.decoder = PacketDecoder(); self.jpeg = JPEGDecoder()
            self.handshake = CameraDirectProtocol(modern ? .newerVideo : .classicVideo)
            self.emitState(.connecting)
            self.lastFrame = Date()
            self.frames.start { [weak self] frame in
                guard let self = self, self.callbacks.isCurrent(current) else { return }
                self.onFrame?(frame)
                self.queue.async {
                    guard self.callbacks.isCurrent(current), self.session == current else { return }
                    self.lastFrame = Date()
                    if !self.hasFrame { self.hasFrame = true; self.emitState(.streaming); self.status("Live • connected directly to camera") }
                }
            }
            let c = NWConnection(host: NWEndpoint.Host(host), port: 6123, using: .tcp)
            self.connection = c
            self.status("Connecting to camera at \(host)…")
            c.stateUpdateHandler = { [weak self] state in
                guard let self = self, self.session == current, self.callbacks.isCurrent(current) else { return }
                switch state {
                case .ready:
                    self.status("Connected over Wi-Fi. Requesting video…")
                    self.stage = 1
                    self.emitState(.handshaking)
                    for data in self.handshake.start() { self.sendBytes(data) }
                    self.receive(c, session: current)
                    let timer = DispatchSource.makeTimerSource(queue: self.queue)
                    timer.schedule(deadline: .now() + 5, repeating: 5)
                    timer.setEventHandler { [weak self] in
                        guard let self = self, self.session == current, self.callbacks.isCurrent(current) else { return }
                        self.send(command: modern ? 9 : 100)
                        if Date().timeIntervalSince(self.lastFrame) > 18 {
                            self.fail(self.hasFrame ? .stalled : .noVideo)
                        }
                    }
                    self.heartbeat = timer; timer.resume()
                case .failed: self.fail(.network)
                case .waiting(let error): self.status("Waiting for the camera network: \(error.localizedDescription)")
                default: break
                }
            }
            c.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + 12) {
                guard self.session == current, self.callbacks.isCurrent(current), self.stage == 0 else { return }
                self.fail(.unreachable)
            }
        }
    }
    func stop() {
        let current = callbacks.advance(); frames.stop()
        queue.async {
            guard self.callbacks.isCurrent(current) else { return }
            self.close()
            self.status("Video stopped.", generation: current)
            self.emitState(.stopped, generation: current)
        }
    }
    private func close() {
        session = UUID(); heartbeat?.cancel(); heartbeat = nil
        frames.stop()
        connection?.cancel(); connection = nil
    }
    private func emitState(_ state: CameraVideoState, generation: UUID? = nil) {
        let current = generation ?? session
        DispatchQueue.main.async { guard self.callbacks.isCurrent(current) else { return }; self.onState?(state) }
    }
    private func fail(_ error: CameraFailure) {
        let current = session
        close()
        DispatchQueue.main.async {
            guard self.callbacks.isCurrent(current) else { return }
            self.onStatus?(error.message)
            self.onState?(.failed(error)); self.onFailure?(error)
            self.onStopped?()
        }
    }
    private func sendBytes(_ data: Data) {
        let current = session
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self = self, self.session == current, self.callbacks.isCurrent(current) else { return }
            if error != nil { self.fail(.network) }
        })
    }
    private func send(command: UInt32) { sendBytes(CameraWire.packet(command:command,modern:modern)) }
    private func receive(_ c: NWConnection, session current: UUID) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self = self, self.session == current else { return }
            if let data = data, !data.isEmpty {
                do {
                    for packet in try self.decoder.feed(data) {
                        guard self.session == current, self.callbacks.isCurrent(current) else { break }
                        self.process(packet)
                    }
                } catch { self.fail(.malformed); return }
            }
            guard self.session == current, self.callbacks.isCurrent(current) else { return }
            if error != nil { self.fail(.network) }
            else if done { self.fail(.disconnected) }
            else { self.receive(c, session: current) }
        }
    }
    private func process(_ packet: CameraPacket) {
        let command = modern ? packet.command : packet.command & 0xffff
        if command == (modern ? 1003 : 1) {
            for frame in jpeg.feed(packet.payload) { frames.submit(frame) }
            return
        }
        let action = handshake.receive(packet, now: Int(Date().timeIntervalSince1970))
        if let failure = action.failure { fail(failure); return }
        for data in action.writes { sendBytes(data) }
        if handshake.stage == .waitingForFrames { emitState(.waitingForFrames) }
    }
}
