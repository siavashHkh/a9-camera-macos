import Foundation
import Network
import Darwin

setbuf(stdout,nil)
func check(_ ok: @autoclosure () -> Bool, _ text: String) { if !ok() { print("FAIL: \(text)"); exit(1) } }
let io = DispatchQueue(label:"a9.gateway.fixture")
let jpeg = try Data(contentsOf:URL(fileURLWithPath:"build/TestFrame.jpg"))
func word(_ n: UInt32) -> Data { Data([UInt8(truncatingIfNeeded:n),UInt8(truncatingIfNeeded:n>>8),UInt8(truncatingIfNeeded:n>>16),UInt8(truncatingIfNeeded:n>>24)]) }
func wire(_ command: UInt32, _ payload: Data = Data(), flag: UInt8 = 0, sequence: UInt32 = 0) -> Data {
    word(UInt32(payload.count)) + Data([UInt8(truncatingIfNeeded:command),UInt8(truncatingIfNeeded:command>>8),flag,0]) + Data(repeating:48,count:8) + word(sequence) + payload
}
enum Trial: String, CaseIterable { case streaming, wrongUID, wrongToken, wrongPeer, portCollision, restart, reconnect, relay, relayWrongPeer, relayMalformedThenValid }
let gateway = CameraGateway()
var index = 0 // main queue
var started = false
var finishing = false
var gotFrame = false
var gotAck = false
var reconnected = false
var extraListener: NWListener?
var fixture: CameraFixture?
var relayProcess: Process?
var relayErrors: Pipe?
let base = CameraGatewayConfiguration(localAddress:"127.0.0.1",cameraAddress:"127.0.0.1",deviceID:"testcam0001",httpPort:18080,controlPort:16123,mediaPort:16124,mqttPort:11883,dnsPort:11553)

func success() {
    if Trial.allCases[index] == .reconnect && !reconnected {
        reconnected = true; started = false; gotFrame = false; gotAck = false
        fixture?.cancel(); fixture = nil; gateway.start(base)
    } else { finish() }
}
func finish() {
    guard !finishing else { return }; finishing = true
    gateway.stop()
}
func next() {
    let trial = Trial.allCases[index]
    fixture?.cancel(); fixture = nil; extraListener?.cancel(); extraListener = nil
    if let process = relayProcess {
        process.terminate(); process.waitUntilExit()
        let errors = relayErrors?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        check(!String(decoding:errors,as:UTF8.self).contains("ERROR: AddressSanitizer"),"relay AddressSanitizer error")
    }
    relayProcess = nil; relayErrors = nil
    print("PASS: gateway \(trial.rawValue)")
    index += 1
    if index == Trial.allCases.count { print("All gateway integration checks passed using a camera that connects outward to the app."); exit(0) }
    DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { start() }
}
final class CameraFixture {
    let trial: Trial
    var connections: [NWConnection] = []
    var parser = PacketDecoder()
    var token = ""
    var clientToken = ""
    var udp: NWConnection?
    var initialized = false
    var sentFrame = false
    var emptyAck = false
    var cancelled = false
    init(_ trial: Trial) { self.trial = trial }
    func cancel() { io.async { self.cancelled = true; for c in self.connections { c.cancel() }; self.connections.removeAll() } }
    func connection(_ port: UInt16, udp: Bool = false, ready: @escaping (NWConnection)->Void) -> NWConnection {
        let c = NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!,using:udp ? .udp : .tcp)
        connections.append(c)
        c.stateUpdateHandler = { state in
            guard !self.cancelled else { return }
            if case .ready = state { ready(c) }
            if case .failed(let error) = state {
                if self.trial == .wrongPeer || self.trial == .wrongUID || self.trial == .wrongToken || self.trial == .relayWrongPeer { return }
                check(false,"fixture connection: \(error)")
            }
        }
        c.start(queue:io); return c
    }
    func send(_ data: Data, _ c: NWConnection) { c.send(content:data,completion:.contentProcessed{_ in}) }
    func json(_ object: [String:Any], _ c: NWConnection) { send(wire(0,try! JSONSerialization.data(withJSONObject:object)),c) }
    func begin() {
        io.async {
            if self.trial == .wrongPeer || self.trial == .relayWrongPeer { self.http(); return }
            if self.trial == .relayMalformedThenValid { self.malformed(); return }
            self.dns()
        }
    }
    func dns() {
            _ = self.connection(self.trial.rawValue.hasPrefix("relay") ? 11552 : base.dnsPort!,udp:true) { c in
                var query = Data([0x12,0x34,1,0,0,1,0,0,0,0,0,0])
                for label in ["v720","naxclow","com"] { query.append(UInt8(label.utf8.count)); query.append(contentsOf:label.utf8) }
                query.append(contentsOf:[0,0,1,0,1]); self.send(query,c)
                c.receiveMessage { data,_,_,error in
                    guard !self.cancelled else { return }
                    check(error == nil && data?.suffix(4) == Data([127,0,0,1]),"DNS network mapping")
                    c.cancel(); self.mqtt()
                }
            }
    }
    func malformed() {
        _ = connection(18079) { c in
            self.send(Data("POST /app/api/test HTTP/1.1\r\nContent-Length: 999999\r\n\r\n".utf8),c)
            c.receive(minimumIncompleteLength:1,maximumLength:512) { data,_,done,error in
                check(data?.isEmpty != false && (done || error != nil),"relay forwarded oversized request")
                c.cancel(); self.dns()
            }
        }
    }
    func mqtt() {
        _ = connection(base.mqttPort) { c in
            let id = Data("testcam0001".utf8)
            self.send(Data([0x10,UInt8(id.count+12),0,4,77,81,84,84,4,2,0,10,0,UInt8(id.count)])+id,c)
            self.mqttRead(c,buffer:Data())
        }
    }
    func mqttRead(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength:1,maximumLength:1024) { data,_,done,error in
            guard !self.cancelled else { return }
            let all = buffer + (data ?? Data())
            if all.count >= 4 { check(all.prefix(4) == Data([0x20,2,0,0]),"MQTT network CONNACK"); c.cancel(); self.http() }
            else { check(!done && error == nil,"MQTT closed before CONNACK"); self.mqttRead(c,buffer:all) }
        }
    }
    func http() {
        _ = connection(trial.rawValue.hasPrefix("relay") ? 18079 : base.httpPort) { c in
            let request = Data("POST /app/api/ApiServer/getA9ConfCheck?devicesCode=testcam0001 HTTP/1.1\r\nHost: v720.naxclow.com\r\nContent-Length: 0\r\n\r\n".utf8)
            self.send(Data(request.prefix(31)),c); self.send(Data(request.dropFirst(31)),c)
            self.httpRead(c,buffer:Data())
        }
    }
    func httpRead(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength:1,maximumLength:4096) { data,_,done,error in
            guard !self.cancelled else { return }
            let all = buffer + (data ?? Data())
            if done || error != nil {
                if self.trial == .wrongPeer || self.trial == .relayWrongPeer { check(all.isEmpty,"unrelated source IP received bootstrap data"); DispatchQueue.main.async { finish() }; return }
                guard let split = all.range(of:Data("\r\n\r\n".utf8)), let object = try? JSONSerialization.jsonObject(with:all.suffix(from:split.upperBound)) as? [String:Any], let info = object["data"] as? [String:Any], let pwd = info["pwd"] as? String else { check(false,"invalid bootstrap response"); return }
                check(info["host"] as? String == "127.0.0.1" && info["tcpPort"] as? Int == Int(base.controlPort),"bootstrap endpoint")
                self.token = pwd; c.cancel(); self.control()
            } else { self.httpRead(c,buffer:all) }
        }
    }
    func control() {
        _ = connection(base.controlPort) { c in
            self.json(["code":100,"uid":self.trial == .wrongUID ? "othercam01" : "testcam0001","token":self.trial == .wrongToken ? "wrong000" : self.token,"domain":"v720.naxclow.com"],c)
            self.controlRead(c)
        }
    }
    func controlRead(_ c: NWConnection) {
        c.receive(minimumIncompleteLength:1,maximumLength:65536) { data,_,done,error in
            guard !self.cancelled else { return }
            if self.trial == .wrongUID || self.trial == .wrongToken {
                check(data?.isEmpty != false,"unapproved registration received a response")
                if done || error != nil { DispatchQueue.main.async { finish() } } else { self.controlRead(c) }
                return
            }
            if let data = data {
                do { for packet in try self.parser.feed(data) { self.handle(packet,c) } }
                catch { check(false,"gateway emitted malformed control framing") }
            }
            if !done && error == nil { self.controlRead(c) }
        }
    }
    func handle(_ packet: CameraPacket, _ c: NWConnection) {
        guard let obj = try? JSONSerialization.jsonObject(with:packet.payload) as? [String:Any], let code = obj["code"] as? Int else { return }
        if code == 101 { check(obj["status"] as? Int == 200,"registration status") }
        if code == 11 {
            check(obj["cliIp"] as? String == "127.0.0.1" && obj["cliPort"] as? Int == Int(base.mediaPort),"NAT target escaped selected interface")
            clientToken = obj["cliToken"] as? String ?? ""
            udp = connection(base.mediaPort,udp:true) { u in self.json(["code":20],u); self.udpRead(u) }
        }
        if code == 301, let content = obj["content"] as? [String:Any], let inner = content["code"] as? Int {
            if inner == 298 { initialized = true }
            if inner == 4 { check(initialized,"base info preceded retransmission setup"); json(["code":301,"content":["code":4,"status":200]],c) }
            if inner == 2, !sentFrame { sentFrame = true; video() }
        }
    }
    func udpRead(_ c: NWConnection) {
        c.receiveMessage { data,_,_,error in
            guard !self.cancelled else { return }
            if let data = data, let packet = try? CameraPacket.datagram(data) {
                if packet.opcode == 0, let obj = try? JSONSerialization.jsonObject(with:packet.payload) as? [String:Any], let code = obj["code"] as? Int {
                    if code == 21 || code == 50 { self.json(["code":51,"devTarget":"testcam0001","cliToken":self.clientToken],c) }
                }
                if packet.opcode == 605 {
                    if packet.payload.isEmpty { self.emptyAck = true }
                    else {
                        check(self.emptyAck,"initial retransmission confirmation missing")
                        var seq = Set<UInt32>()
                        for i in stride(from:0,to:packet.payload.count,by:4) { check(i+4 <= packet.payload.count,"partial retransmission ID"); seq.insert(CameraWire.read32(packet.payload,i)) }
                        if seq.isSuperset(of:[100,101,102]) { DispatchQueue.main.async { gotAck = true; if gotFrame { success() } } }
                    }
                }
            }
            if error == nil { self.udpRead(c) }
        }
    }
    func video() {
        guard let c = udp else { check(false,"no media connection"); return }
        let n = jpeg.count/2
        let first = wire(1,Data(jpeg.prefix(n)),flag:250,sequence:100)
        let middle = wire(1,Data(jpeg.dropFirst(n).dropLast()),flag:251,sequence:101)
        let last = wire(1,Data(jpeg.suffix(1))+Data([0])+word(UInt32(jpeg.count)),flag:252,sequence:102)
        send(last,c); send(first,c); send(middle,c); send(middle,c)
    }
}
func start() {
    started = false; finishing = false; gotFrame = false; gotAck = false
    let trial = Trial.allCases[index]
    var config = base
    if trial == .wrongPeer || trial == .relayWrongPeer { config = CameraGatewayConfiguration(localAddress:base.localAddress,cameraAddress:"127.0.0.2",deviceID:base.deviceID,httpPort:base.httpPort,controlPort:base.controlPort,mediaPort:base.mediaPort,mqttPort:base.mqttPort,dnsPort:base.dnsPort) }
    if trial.rawValue.hasPrefix("relay") {
        config = CameraGatewayConfiguration(localAddress:base.localAddress,cameraAddress:config.cameraAddress,deviceID:base.deviceID,httpPort:base.httpPort,controlPort:base.controlPort,mediaPort:base.mediaPort,mqttPort:base.mqttPort,dnsPort:base.dnsPort,usesPortRelay:true)
        let process = Process(); process.executableURL = URL(fileURLWithPath:"build/A9CameraRelay")
        process.arguments = ["--listen","127.0.0.1","--camera",config.cameraAddress,"--http-target",String(base.httpPort),"--dns-target",String(base.dnsPort!),"--http-listen","18079","--dns-listen","11552"]
        let output = Pipe(); let errors = Pipe(); process.standardOutput = output; process.standardError = errors
        relayProcess = process; relayErrors = errors
        try! process.run()
        DispatchQueue.global().async {
            let ready = output.fileHandleForReading.readData(ofLength:6)
            check(ready == Data("READY\n".utf8),"relay did not start")
            gateway.start(config)
        }
    } else if trial == .portCollision {
        var collisionConfig = config; collisionConfig.httpPort = 18499
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:18499)
        extraListener = try! NWListener(using:parameters)
        extraListener!.newConnectionHandler = { $0.cancel() }
        extraListener!.stateUpdateHandler = { state in
            if case .ready = state { gateway.start(collisionConfig) }
            if case .failed(let error) = state { check(false,"collision fixture could not bind: \(error)") }
            if case .waiting(let error) = state { check(false,"collision fixture waiting: \(error)") }
        }
        extraListener!.start(queue:io)
    } else {
        if trial == .restart { gateway.start(base); gateway.stop() }
        gateway.start(config)
    }
}
gateway.onStatus = { print("GATEWAY: \($0)") }
gateway.onPhase = { phase in
    let trial = Trial.allCases[index]
    if phase == .waitingForCamera && !started && !finishing {
        started = true; fixture = CameraFixture(trial); fixture!.begin()
    }
    if case .failed = phase { check(trial == .portCollision,"unexpected gateway listener failure"); finish() }
    if phase == .stopped && finishing { DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { next() } }
}
gateway.onFrame = { frame in
    check(!finishing,"frame delivered after Stop")
    check(frame.jpeg == jpeg && frame.image.width == 2 && frame.image.height == 2,"bad decoded gateway frame")
    gotFrame = true; if gotAck { success() }
}
start()
DispatchQueue.global().asyncAfter(deadline:.now()+35) { print("FAIL: gateway integration watchdog"); exit(1) }
dispatchMain()
