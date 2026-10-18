import Foundation
import Network

// A private, explicitly started server for a single configured camera. All
// listeners bind the chosen local IPv4; peers at other addresses are rejected.
final class CameraGateway {
    var onPhase: ((CameraGatewayPhase) -> Void)?
    var onStatus: ((String) -> Void)?
    var onFrame: ((CameraFrame) -> Void)?
    private let queue = DispatchQueue(label:"local.a9.gateway")
    private let gate = CameraCallbackGate()
    private let shutdownGroup = DispatchGroup()
    private let frames = CameraFrameDelivery()
    private let mediaGate = CameraCallbackGate()
    private var generation = UUID()
    private var configuration: CameraGatewayConfiguration?
    private var token = ""
    private var clientTarget = ""
    private var clientToken = ""
    private var listeners: [NWListener] = []
    private var peers: [UUID:NWConnection] = [:]
    private var services: [UUID:String] = [:]
    private var mqttConnected = Set<UUID>()
    private var peerActivity: [UUID:Date] = [:]
    private var control: NWConnection?
    private var controlID: UUID?
    private var registered = false
    private var probed = false
    private var initialized = false
    private var media: NWConnection?
    private var jpeg = CameraStationJPEG()
    private var acknowledgements = Set<UInt32>()
    private var timer: DispatchSourceTimer?
    private var lastSeen = Date()
    private var requestedVideo: Date?
    private var negotiationDeadline: Date?
    private var deliveredFrame = false
    private var sentFirstConfirmation = false
    private var phase = CameraGatewayPhase.stopped
    private var readyListeners = Set<String>()

    private func publish(_ next: CameraGatewayPhase, _ text: String) {
        phase = next; let current = generation
        DispatchQueue.main.async {
            guard self.gate.isCurrent(current) else { return }
            self.onPhase?(next); self.onStatus?(text)
        }
    }
    func start(_ config: CameraGatewayConfiguration) {
        let current = gate.advance(); _ = mediaGate.advance(); frames.stop()
        queue.async { [self] in
            guard gate.isCurrent(current) else { return }
            close()
            shutdownGroup.notify(queue:queue) { [self] in
            guard gate.isCurrent(current) else { return }
            generation = current
            do { try config.validate() } catch { publish(.failed("configuration"),"Enter the Mac’s local IP, camera IP and camera UID. Ports must be distinct and available."); return }
            configuration = config
            token = String(UUID().uuidString.replacingOccurrences(of:"-",with:"").prefix(8)).lowercased()
            clientTarget = UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
            clientToken = String(UUID().uuidString.replacingOccurrences(of:"-",with:"").prefix(8)).lowercased()
            publish(.starting,"Starting local camera gateway…")
            do {
                try listen("HTTP bootstrap",config.httpPort,udp:false,current:current)
                try listen("camera control",config.controlPort,udp:false,current:current)
                try listen("camera media",config.mediaPort,udp:true,current:current)
                try listen("camera MQTT",config.mqttPort,udp:false,current:current)
                if let port = config.dnsPort { try listen("camera DNS",port,udp:true,current:current) }
            } catch { fail("Could not open gateway listeners. Check that the configured ports are free."); return }
            let timer = DispatchSource.makeTimerSource(queue:queue)
            timer.schedule(deadline:.now()+0.1,repeating:0.1)
            timer.setEventHandler { [weak self] in self?.tick(current) }
            self.timer = timer; timer.resume()
            }
        }
    }
    func stop() {
        let current = gate.advance(); _ = mediaGate.advance(); frames.stop()
        queue.async {
            guard self.gate.isCurrent(current) else { return }
            self.close()
            self.shutdownGroup.notify(queue:self.queue) {
                guard self.gate.isCurrent(current) else { return }
                self.generation = current; self.publish(.stopped,"Local gateway stopped.")
            }
        }
    }
    private func close() {
        timer?.cancel(); timer = nil
        for listener in listeners { drain(listener) }; listeners.removeAll()
        for connection in peers.values { drain(connection) }; peers.removeAll()
        services.removeAll(); peerActivity.removeAll(); mqttConnected.removeAll()
        _ = mediaGate.advance(); frames.stop()
        control = nil; controlID = nil; media = nil
        registered = false; probed = false; initialized = false; deliveredFrame = false; sentFirstConfirmation = false
        jpeg.reset(); acknowledgements.removeAll(); readyListeners.removeAll(); requestedVideo = nil; negotiationDeadline = nil
        configuration = nil; token = ""; clientTarget = ""; clientToken = ""
    }
    private func drain(_ listener: NWListener) {
        if case .cancelled = listener.state { return }
        let group = shutdownGroup; group.enter(); var finished = false
        listener.stateUpdateHandler = { [listener] state in
            if case .cancelled = state, !finished { finished = true; listener.stateUpdateHandler = nil; group.leave() }
        }
        listener.cancel()
    }
    private func drain(_ connection: NWConnection) {
        if case .cancelled = connection.state { return }
        let group = shutdownGroup; group.enter(); var finished = false
        connection.stateUpdateHandler = { [connection] state in
            if case .cancelled = state, !finished { finished = true; connection.stateUpdateHandler = nil; group.leave() }
        }
        connection.cancel()
    }
    private func fail(_ message: String) {
        close(); frames.stop(); publish(.failed(message),message)
    }
    private func listen(_ service: String, _ port: UInt16, udp: Bool, current: UUID) throws {
        guard let config = configuration, let p = NWEndpoint.Port(rawValue:port) else { throw CameraGatewayError.configuration }
        let parameters = udp ? NWParameters.udp : NWParameters.tcp
        let relayService = config.usesPortRelay && (service == "HTTP bootstrap" || service == "camera DNS")
        let bindAddress = relayService ? "127.0.0.1" : config.localAddress
        let allowedAddress = relayService ? "127.0.0.1" : config.cameraAddress
        parameters.requiredLocalEndpoint = .hostPort(host:NWEndpoint.Host(bindAddress),port:p)
        let listener = try NWListener(using:parameters)
        listeners.append(listener)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self, self.gate.isCurrent(current), self.configuration != nil else { return }
            switch state {
            case .ready:
                self.readyListeners.insert(service)
                let expected = config.dnsPort == nil ? 4 : 5
                if self.readyListeners.count == expected {
                    self.publish(.waitingForCamera,config.usesPortRelay
                        ? "Receiver ready. Start the camera-port relay, route the two camera service names to \(config.localAddress), then restart the camera. Waiting for bootstrap…"
                        : "Gateway ready. Route the two camera service names to \(config.localAddress), then restart the camera. Waiting for its bootstrap request…")
                }
            case .waiting:
                self.fail("Gateway network access is unavailable. Check the Mac’s selected IP and Local Network permission, then retry.")
            case .failed:
                self.fail("Cannot listen for \(service) on \(config.localAddress):\(port). Check the IP, port availability and Local Network permission.")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self, self.gate.isCurrent(current), self.configuration != nil,
                  case .hostPort(let host,_) = connection.endpoint,
                  String(describing:host).replacingOccurrences(of:"::ffff:",with:"") == allowedAddress,
                  self.peers.count < 12 else { connection.cancel(); return }
            let id = UUID(); self.peers[id] = connection; self.services[id] = service; self.peerActivity[id] = Date()
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self = self, let connection = connection, self.gate.isCurrent(current), self.peers[id] != nil else { return }
                if case .failed = state { self.remove(id,connection) }
            }
            connection.start(queue:self.queue)
            switch service {
            case "HTTP bootstrap": self.readHTTP(connection,id:id,current:current,buffer:Data())
            case "camera control":
                guard self.control == nil else { self.remove(id,connection); return }
                self.control = connection; self.controlID = id; self.lastSeen = Date()
                self.readControl(connection,id:id,current:current,decoder:PacketDecoder())
            case "camera media": self.readDatagram(connection,id:id,current:current,dns:false)
            case "camera DNS": self.readDatagram(connection,id:id,current:current,dns:true)
            default: self.readMQTT(connection,id:id,current:current,decoder:CameraMQTTDecoder(),session:CameraMQTTSession(deviceID:config.deviceID))
            }
            self.queue.asyncAfter(deadline:.now()+10) {
                guard self.gate.isCurrent(current), self.peers[id] === connection else { return }
                if service == "HTTP bootstrap" || service == "camera DNS" || (service == "camera control" && !self.registered) || (service == "camera MQTT" && !self.mqttConnected.contains(id)) { self.remove(id,connection) }
            }
        }
        listener.start(queue:queue)
    }
    private func remove(_ id: UUID, _ connection: NWConnection) {
        peers.removeValue(forKey:id); services.removeValue(forKey:id); peerActivity.removeValue(forKey:id); mqttConnected.remove(id); drain(connection)
        if controlID == id {
            control = nil; controlID = nil; registered = false; initialized = false; probed = false
            media = nil; jpeg.reset(); acknowledgements.removeAll(); requestedVideo = nil; negotiationDeadline = nil; deliveredFrame = false; sentFirstConfirmation = false
            _ = mediaGate.advance(); frames.stop()
            for peerID in services.keys.filter({services[$0] == "camera media"}) {
                if let peer = peers[peerID] { remove(peerID,peer) }
            }
            if configuration != nil { publish(.waitingForCamera,"Camera disconnected. Gateway is waiting for it to reconnect.") }
        }
        if media === connection { media = nil }
    }
    private func send(_ data: Data, _ connection: NWConnection) {
        connection.send(content:data,completion:.contentProcessed { _ in })
    }
    private func json(_ object: [String:Any], _ connection: NWConnection) {
        guard let payload = try? JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]) else { return }
        send(CameraWire.packet(command:0,payload:payload),connection)
    }
    private func forward(_ code: Int, extra: [String:Any] = [:]) {
        guard let control = control else { return }
        var content = extra; content["code"] = code
        json(["code":301,"target":clientTarget,"content":content],control)
    }
    private func readHTTP(_ connection: NWConnection, id: UUID, current: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:4096) { [weak self] data,_,done,error in
            guard let self = self, self.gate.isCurrent(current), self.peers[id] != nil, let config = self.configuration else { return }
            let incoming = buffer + (data ?? Data())
            do {
                if let response = try CameraBootstrap(config:config,token:self.token).response(incoming,now:Int(Date().timeIntervalSince1970)) {
                    if !self.registered {
                        if response.starts(with:Data("HTTP/1.1 200 ".utf8)) { self.publish(.bootstrap,"Camera reached the local bootstrap service. Waiting for camera registration…") }
                        else if response.starts(with:Data("HTTP/1.1 403 ".utf8)) { self.publish(.waitingForCamera,"Camera reached the gateway, but its UID did not match. Check the UID from its label or hotspot.") }
                        else { self.publish(.waitingForCamera,"Camera reached the gateway with an unsupported bootstrap request. This firmware may need a different protocol.") }
                    }
                    connection.send(content:response,completion:.contentProcessed { [weak self] _ in
                        guard let self = self, self.gate.isCurrent(current) else { return }; self.remove(id,connection)
                    }); return
                }
            } catch { self.remove(id,connection); return }
            if done || error != nil { self.remove(id,connection) }
            else { self.readHTTP(connection,id:id,current:current,buffer:incoming) }
        }
    }
    private func readControl(_ connection: NWConnection, id: UUID, current: UUID, decoder: PacketDecoder) {
        connection.receive(minimumIncompleteLength:1,maximumLength:65536) { [weak self] data,_,done,error in
            guard let self = self, self.gate.isCurrent(current), self.peers[id] != nil else { return }
            var parser = decoder
            do {
                for packet in try parser.feed(data ?? Data()) {
                    guard self.peers[id] != nil else { return }
                    self.controlPacket(packet,connection,id:id)
                }
            } catch { self.remove(id,connection); return }
            if done || error != nil { self.remove(id,connection) }
            else if self.peers[id] != nil { self.readControl(connection,id:id,current:current,decoder:parser) }
        }
    }
    private func controlPacket(_ packet: CameraPacket, _ connection: NWConnection, id: UUID) {
        guard let config = configuration else { return }
        if let id = controlID { peerActivity[id] = Date() }
        if packet.opcode == 100 && registered { lastSeen = Date(); send(CameraWire.packet(command:100),connection); return }
        guard packet.opcode == 0, let object = (try? JSONSerialization.jsonObject(with:packet.payload)) as? [String:Any], let code = object["code"] as? Int else { return }
        if code == 100 {
            guard let uid = object["uid"] as? String, config.matches(uid), object["token"] as? String == token else { remove(id,connection); return }
            if registered { json(["code":101,"status":200],connection); return }
            registered = true; lastSeen = Date(); negotiationDeadline = Date().addingTimeInterval(15)
            startFrames()
            json(["code":101,"status":200],connection)
            publish(.registered,"Camera registered with the local gateway. Opening its video channel…")
            json(["code":11,"cliTarget":clientTarget,"cliToken":clientToken,"cliIp":config.localAddress,"cliPort":Int(config.mediaPort),"cliNatIp":config.localAddress,"cliNatPort":Int(config.mediaPort)],connection)
            publish(.negotiating,"Camera registered. Waiting for its UDP media handshake…")
        } else if registered {
            lastSeen = Date()
            if code == 12, let status = object["status"] as? Int, status != 200 && status != 0 {
                publish(.registered,"Camera rejected the media negotiation. Check that camera and Mac can communicate on the local network.")
            }
            if code == 301, let content = object["content"] as? [String:Any], content["code"] as? Int == 4, initialized {
                if let status = content["status"] as? Int, status != 0 && status != 200 {
                    publish(.registered,"Camera rejected the video-information request."); return
                }
                forward(2); requestedVideo = Date()
                publish(.waitingForVideo,"Camera media channel is ready. Waiting for the first valid JPEG…")
            }
        }
    }
    private func readDatagram(_ connection: NWConnection, id: UUID, current: UUID, dns: Bool) {
        connection.receiveMessage { [weak self] data,_,_,error in
            guard let self = self, self.gate.isCurrent(current), self.peers[id] != nil, let config = self.configuration else { return }
            if let data = data {
                self.peerActivity[id] = Date()
                do {
                    if dns { self.send(try CameraGatewayDNS.response(data,address:config.localAddress),connection) }
                    else { self.mediaPacket(try CameraPacket.datagram(data),connection) }
                } catch { self.remove(id,connection); return }
            }
            if error != nil { self.remove(id,connection) }
            else { self.readDatagram(connection,id:id,current:current,dns:dns) }
        }
    }
    private func mediaPacket(_ packet: CameraPacket, _ connection: NWConnection) {
        guard registered, let config = configuration else { return }
        lastSeen = Date()
        if packet.opcode == 100 { send(CameraWire.packet(command:100),connection); return }
        if packet.opcode == 0, let object = (try? JSONSerialization.jsonObject(with:packet.payload)) as? [String:Any], let code = object["code"] as? Int {
            if code == 20 { json(["code":21,"ip":config.localAddress,"port":Int(config.mediaPort)],connection) }
            if code == 51 {
                guard let uid = object["devTarget"] as? String, config.matches(uid) else { return }
                if let value = object["cliToken"] as? String, value != clientToken { return }
                media = connection
                if !probed { probed = true; json(["code":50],connection) }
                else if !initialized {
                    initialized = true; negotiationDeadline = nil
                    if let control = control { json(["code":53,"status":1],control) }
                    forward(298); forward(4,extra:["unixTimer":Int(Date().timeIntervalSince1970)])
                }
            }
            return
        }
        guard initialized, media === connection else { return }
        if packet.opcode == 1 || packet.opcode == 4 {
            if acknowledgements.count < 1024 { acknowledgements.insert(packet.sequence) }
        }
        if packet.opcode == 1, let data = jpeg.feed(packet,now:Date().timeIntervalSince1970) {
            if !sentFirstConfirmation { sentFirstConfirmation = true; send(CameraWire.packet(command:605),connection) }
            frames.submit(data)
        }
    }
    private func readMQTT(_ connection: NWConnection, id: UUID, current: UUID, decoder: CameraMQTTDecoder, session: CameraMQTTSession) {
        connection.receive(minimumIncompleteLength:1,maximumLength:16384) { [weak self] data,_,done,error in
            guard let self = self, self.gate.isCurrent(current), self.peers[id] != nil else { return }
            var parser = decoder; var state = session
            self.peerActivity[id] = Date()
            do {
                for packet in try parser.feed(data ?? Data()) {
                    if let response = try state.receive(packet) { self.send(response,connection) }
                    if state.connected { self.mqttConnected.insert(id) }
                    else { self.remove(id,connection); return }
                }
            }
            catch { self.remove(id,connection); return }
            if done || error != nil { self.remove(id,connection) }
            else { self.readMQTT(connection,id:id,current:current,decoder:parser,session:state) }
        }
    }
    private func startFrames() {
        let current = generation; let stream = mediaGate.advance()
        frames.start { [weak self] frame in
            guard let self = self, self.gate.isCurrent(current), self.mediaGate.isCurrent(stream) else { return }
            self.onFrame?(frame)
            self.queue.async {
                guard self.gate.isCurrent(current), self.mediaGate.isCurrent(stream), self.registered else { return }
                self.lastSeen = Date()
                if !self.deliveredFrame { self.deliveredFrame = true; self.publish(.streaming,"Live • camera connected through the local gateway") }
            }
        }
    }
    private func tick(_ current: UUID) {
        guard gate.isCurrent(current), configuration != nil else { return }
        for id in peerActivity.keys.filter({ $0 != controlID && Date().timeIntervalSince(peerActivity[$0]!) > 30 }) {
            if let peer = peers[id] { remove(id,peer) }
        }
        if let deadline = negotiationDeadline, Date() >= deadline {
            negotiationDeadline = nil
            publish(.waitingForVideo,"Camera registered, but its UDP media handshake did not complete. Check local-network isolation and firewall access.")
        }
        if let media = media, !acknowledgements.isEmpty {
            let payload = acknowledgements.sorted().reduce(into:Data()){$0.append(CameraWire.little32($1))}
            acknowledgements.removeAll(); send(CameraWire.packet(command:605,payload:payload),media)
        }
        if let requested = requestedVideo, !deliveredFrame, Date().timeIntervalSince(requested) > 20 {
            requestedVideo = nil
            publish(.waitingForVideo,"The camera negotiated a media channel but has not delivered a valid JPEG. The firmware or codec may be unsupported.")
        }
        if registered && Date().timeIntervalSince(lastSeen) > 35, let control = control, let id = controlID { remove(id,control) }
    }
}
