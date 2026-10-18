import Foundation

struct CameraGatewayConfiguration {
    let localAddress: String
    let cameraAddress: String
    let deviceID: String
    var httpPort: UInt16 = 80
    var controlPort: UInt16 = 6123
    var mediaPort: UInt16 = 6123
    var mqttPort: UInt16 = 1883
    var dnsPort: UInt16? = nil
    let usesPortRelay: Bool
    init(localAddress: String, cameraAddress: String, deviceID: String, httpPort: UInt16 = 80, controlPort: UInt16 = 6123, mediaPort: UInt16 = 6123, mqttPort: UInt16 = 1883, dnsPort: UInt16? = nil, usesPortRelay: Bool = false) {
        self.localAddress = localAddress; self.cameraAddress = cameraAddress
        let uid = deviceID.trimmingCharacters(in:.whitespacesAndNewlines)
        self.deviceID = uid.lowercased().hasPrefix("nax_") ? String(uid.dropFirst(4)) : uid
        self.usesPortRelay = usesPortRelay
        self.httpPort = httpPort; self.controlPort = controlPort; self.mediaPort = mediaPort; self.mqttPort = mqttPort; self.dnsPort = dnsPort
    }
    func validate() throws {
        guard CameraVideo.validLocalAddress(localAddress), CameraVideo.validLocalAddress(cameraAddress),
              deviceID.range(of: "^[A-Za-z0-9_-]{8,32}$", options:.regularExpression) != nil,
              [httpPort,controlPort,mediaPort,mqttPort].allSatisfy({$0 > 0}),
              Set([httpPort,controlPort,mqttPort]).count == 3,
              dnsPort == nil || dnsPort! > 0 else { throw CameraGatewayError.configuration }
    }
    func matches(_ uid: String) -> Bool { uid.caseInsensitiveCompare(deviceID) == .orderedSame }
}
enum CameraGatewayError: Error { case configuration, malformed, oversized }
enum CameraGatewayPhase: Equatable {
    case stopped, starting, waitingForCamera, bootstrap, registered, negotiating, waitingForVideo, streaming, failed(String)
}

// No general web server, account API, media URL or external proxy is exposed.
struct CameraBootstrap {
    let config: CameraGatewayConfiguration
    let token: String
    func response(_ request: Data, now: Int) throws -> Data? {
        guard request.count <= 12288 else { throw CameraGatewayError.oversized }
        guard let range = request.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard range.upperBound <= 8192, let header = String(data:request.prefix(range.lowerBound),encoding:.utf8) else { throw CameraGatewayError.malformed }
        let lines = header.components(separatedBy:"\r\n")
        let first = lines[0].split(separator:" ",omittingEmptySubsequences:false)
        guard first.count == 3, first[0] == "POST", first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else { throw CameraGatewayError.malformed }
        var length: Int?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of:":") else { throw CameraGatewayError.malformed }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)
            if key == "transfer-encoding" { throw CameraGatewayError.malformed }
            if key == "content-length" {
                guard length == nil, !value.isEmpty, value.utf8.allSatisfy({(48...57).contains($0)}), let n = Int(value), n <= 4096 else { throw CameraGatewayError.malformed }
                length = n
            }
        }
        guard request.count >= range.upperBound + (length ?? 0) else { return nil }
        guard let url = URLComponents(string:"http://camera.local" + first[1]), url.fragment == nil else { throw CameraGatewayError.malformed }
        let uidValues = (url.queryItems ?? []).filter{$0.name == "devicesCode"}.compactMap{$0.value}
        guard uidValues.count <= 1, uidValues.allSatisfy(config.matches) else { return Self.http(403,["code":403,"message":"Device not allowed"]) }
        let result: [String:Any]
        switch url.path {
        case "/app/api/ApiSysDevicesBatch/registerDevices": result = ["code":200,"message":"OK","data":config.deviceID]
        case "/app/api/ApiSysDevicesBatch/confirm", "/app/api/ApiSysDevices/a9bindingAppDevice": result = ["code":200,"message":"OK","data":NSNull()]
        case "/app/api/ApiSysDevices/getDevInfo": result = ["code":200,"message":"OK","data":["userInfo_state":1]]
        case "/app/api/ApiServer/getA9ConfCheck":
            guard uidValues.count == 1 else { return Self.http(400,["code":400,"message":"Device ID required"]) }
            result = ["code":200,"message":"OK","data":["tcpPort":Int(config.controlPort),"uid":config.deviceID,"isBind":"8","domain":"v720.naxclow.com","updateUrl":NSNull(),"host":config.localAddress,"currTime":String(now),"pwd":token,"version":NSNull()]]
        default: return Self.http(404,["code":404,"message":"Not found"])
        }
        return Self.http(200,result)
    }
    static func http(_ status: Int, _ object: [String:Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])) ?? Data()
        return Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8) + body
    }
}

// Camera-only authoritative answers. Never forwards DNS or queries external hosts.
enum CameraGatewayDNS {
    static let names: Set<String> = ["v720.naxclow.com","v720.p2p.naxclow.com"]
    static func response(_ query: Data, address: String) throws -> Data {
        let b = Array(query)
        func word(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i+1]) }
        guard b.count >= 17, b.count <= 512, b[2] & 0xfe == 0, word(4) == 1, word(6) == 0, word(8) == 0, word(10) <= 1 else { throw CameraGatewayError.malformed }
        var offset = 12; var labels: [String] = []
        while true {
            guard offset < b.count else { throw CameraGatewayError.malformed }
            let n = Int(b[offset]); offset += 1
            if n == 0 { break }
            guard n <= 63, offset + n <= b.count,
                  let label = String(bytes:b[offset..<offset+n],encoding:.ascii), label.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { throw CameraGatewayError.malformed }
            labels.append(label.lowercased()); offset += n
            guard offset - 12 <= 254 else { throw CameraGatewayError.malformed }
        }
        guard offset + 4 <= b.count, word(offset+2) == 1 else { throw CameraGatewayError.malformed }
        let questionEnd = offset + 4
        if word(10) == 0 {
            guard questionEnd == b.count else { throw CameraGatewayError.malformed }
        } else {
            guard questionEnd + 11 <= b.count, b[questionEnd] == 0, word(questionEnd+1) == 41,
                  questionEnd + 11 + word(questionEnd+9) == b.count else { throw CameraGatewayError.malformed }
        }
        let type = word(offset)
        let known = names.contains(labels.joined(separator:"."))
        let a = address.split(separator:".").compactMap{UInt8($0)}
        guard a.count == 4 else { throw CameraGatewayError.configuration }
        let answer = known && type == 1
        var data = Data([b[0],b[1],0x84 | (b[2] & 1),known ? 0 : 3,0,1,0,answer ? 1 : 0,0,0,0,0])
        data.append(contentsOf:b[12..<questionEnd])
        if answer { data.append(contentsOf:[0xc0,0x0c,0,1,0,1,0,0,0,30,0,4] + a) }
        return data
    }
}

struct CameraMQTTPacket { let header: UInt8; let payload: Data }
struct CameraMQTTDecoder {
    private var buffer = Data()
    mutating func feed(_ data: Data) throws -> [CameraMQTTPacket] {
        guard buffer.count + data.count <= 65541 else { throw CameraGatewayError.oversized }
        buffer.append(data); var out: [CameraMQTTPacket] = []
        while buffer.count >= 2 {
            let b = Array(buffer.prefix(5)); var remaining = 0; var multiplier = 1; var offset = 1; var done = false
            while offset < b.count {
                let byte = b[offset]; remaining += Int(byte & 127) * multiplier; offset += 1
                guard remaining <= 65536 else { throw CameraGatewayError.oversized }
                if byte & 128 == 0 { done = true; break }
                guard offset < 5 else { throw CameraGatewayError.malformed }
                multiplier *= 128
            }
            guard done else { break }
            guard remaining + offset <= buffer.count else { break }
            guard out.count < 256 else { throw CameraGatewayError.oversized }
            out.append(CameraMQTTPacket(header:buffer[buffer.startIndex],payload:Data(buffer.dropFirst(offset).prefix(remaining))))
            buffer.removeFirst(offset+remaining)
        }
        return out
    }
}
struct CameraMQTTSession {
    let deviceID: String
    private(set) var connected = false
    mutating func receive(_ packet: CameraMQTTPacket) throws -> Data? {
        let b = Array(packet.payload); var p = 0
        func string() throws -> String {
            guard p+2 <= b.count else { throw CameraGatewayError.malformed }
            let n = Int(b[p]) << 8 | Int(b[p+1]); p += 2
            guard n <= 1024, p+n <= b.count, let s = String(bytes:b[p..<p+n],encoding:.utf8), !s.contains("\0") else { throw CameraGatewayError.malformed }
            p += n; return s
        }
        if packet.header == 0x10 && !connected {
            guard try string() == "MQTT", p+4 <= b.count, b[p] == 4 else { throw CameraGatewayError.malformed }
            p += 1; let flags = b[p]; p += 3
            guard flags & 1 == 0, (flags >> 3) & 3 != 3, (try string()).caseInsensitiveCompare(deviceID) == .orderedSame else { throw CameraGatewayError.malformed }
            if flags & 4 != 0 { _ = try string(); _ = try string() }
            if flags & 128 != 0 { _ = try string() }
            if flags & 64 != 0 { _ = try string() }
            guard p == b.count else { throw CameraGatewayError.malformed }
            connected = true; return Data([0x20,2,0,0])
        }
        guard connected else { throw CameraGatewayError.malformed }
        if packet.header == 0xc0 && b.isEmpty { return Data([0xd0,0]) }
        if packet.header == 0x82 {
            guard b.count >= 2, b[0] != 0 || b[1] != 0 else { throw CameraGatewayError.malformed }
            p = 2; var codes: [UInt8] = []
            while p < b.count {
                let topic = try string(); guard p < b.count, b[p] <= 1 else { throw CameraGatewayError.malformed }; p += 1
                guard topic.hasPrefix("Naxclow/P2P/Users/Device/sub/"), String(topic.dropFirst("Naxclow/P2P/Users/Device/sub/".count)).caseInsensitiveCompare(deviceID) == .orderedSame else { throw CameraGatewayError.malformed }
                codes.append(0)
            }
            guard !codes.isEmpty, codes.count <= 8 else { throw CameraGatewayError.malformed }
            return Data([0x90,UInt8(codes.count+2),b[0],b[1]] + codes)
        }
        if packet.header >> 4 == 3 {
            let qos = (packet.header >> 1) & 3
            guard qos <= 1 else { throw CameraGatewayError.malformed }
            let topic = try string()
            guard topic == "Naxclow/P2P/Users/Device/Status" || topic == "Naxclow/P2P/Users/Device/Info" else { throw CameraGatewayError.malformed }
            if qos == 1 {
                guard p+2 <= b.count, b[p] != 0 || b[p+1] != 0 else { throw CameraGatewayError.malformed }
                return Data([0x40,2,b[p],b[p+1]])
            }
            return nil
        }
        if packet.header == 0xe0 && b.isEmpty { connected = false; return nil }
        throw CameraGatewayError.malformed
    }
}

// Reorder a bounded JPEG access unit. Frames with holes never reach ImageIO.
struct CameraStationJPEG {
    private var parts: [UInt32:CameraPacket] = [:]
    private var start: UInt32?
    private var end: UInt32?
    private var bytes = 0
    private var since: TimeInterval = 0
    mutating func reset() { self = CameraStationJPEG() }
    mutating func feed(_ packet: CameraPacket, now: TimeInterval) -> Data? {
        guard packet.opcode == 1 else { return nil }
        if now - since > 1 { reset(); since = now }
        if packet.flag == 255 {
            reset(); since = now
            return packet.payload.count <= CameraWire.maxPayload ? packet.payload : nil
        }
        guard [UInt8(250),251,252].contains(packet.flag) else { return nil }
        if let old = parts[packet.sequence] { if old.payload != packet.payload || old.flag != packet.flag { reset() }; return nil }
        if packet.flag == 250 {
            if start != nil { reset(); since = now }
            start = packet.sequence
        }
        if packet.flag == 252 { end = packet.sequence }
        guard parts.count < 512, bytes + packet.payload.count <= CameraWire.maxPayload + 5 else { reset(); return nil }
        parts[packet.sequence] = packet; bytes += packet.payload.count
        guard let first = start, let last = end else { return nil }
        let distance = last &- first
        guard distance < 512 else { reset(); return nil }
        var data = Data()
        for n in 0...distance {
            guard let part = parts[first &+ n] else { return nil }
            if n == distance {
                guard part.flag == 252, part.payload.count >= 5 else { reset(); return nil }
                data.append(part.payload.dropLast(5))
            } else { data.append(part.payload) }
        }
        guard let tail = parts[last], CameraWire.read32(tail.payload,tail.payload.count-4) <= UInt32(CameraWire.maxPayload) else { reset(); return nil }
        reset(); since = now
        return data
    }
}
