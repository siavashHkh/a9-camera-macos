import Foundation
import Darwin

func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { print("FAIL: \(message)"); exit(1) } }
func rejects(_ message: String, _ work: () throws -> Void) { do { try work(); check(false,message) } catch {} }
let config = CameraGatewayConfiguration(localAddress:"127.0.0.1",cameraAddress:"127.0.0.1",deviceID:"testcam0001",httpPort:18080,controlPort:16123,mediaPort:16124,mqttPort:11883,dnsPort:11553)
try config.validate()
let normalized = CameraGatewayConfiguration(localAddress:"127.0.0.1",cameraAddress:"127.0.0.1",deviceID:"Nax_0800c0000001")
check(normalized.deviceID == "0800c0000001","hotspot prefix not normalized")
for ip in ["0.0.0.0","8.8.8.8","192.168.001.1","::1"] {
    let bad = CameraGatewayConfiguration(localAddress:ip,cameraAddress:"127.0.0.1",deviceID:"testcam0001")
    rejects("gateway accepted unsafe bind address") { try bad.validate() }
}
let bootstrap = CameraBootstrap(config:config,token:"test1234")
let request = Data("POST /app/api/ApiServer/getA9ConfCheck?devicesCode=testcam0001 HTTP/1.1\r\nHost: v720.naxclow.com\r\nContent-Length: 0\r\n\r\n".utf8)
for n in 0..<request.count { let partial = try bootstrap.response(Data(request.prefix(n)),now:1); check(partial == nil,"partial HTTP request completed") }
let response = try bootstrap.response(request,now:123)!
let split = response.range(of:Data("\r\n\r\n".utf8))!
let object = try JSONSerialization.jsonObject(with:response.suffix(from:split.upperBound)) as! [String:Any]
let data = object["data"] as! [String:Any]
check(data["host"] as? String == "127.0.0.1" && data["tcpPort"] as? Int == 16123 && data["uid"] as? String == "testcam0001" && data["pwd"] as? String == "test1234","bootstrap routing fields")
let forbidden = try bootstrap.response(Data(String(decoding:request,as:UTF8.self).replacingOccurrences(of:"testcam0001",with:"othercam01").utf8),now:1)!; check(String(data:forbidden,encoding:.utf8)!.hasPrefix("HTTP/1.1 403"),"bootstrap accepted unrelated UID")
for extra in ["Content-Length: 0\r\nContent-Length: 0", "Content-Length: -1", "Content-Length: 4097", "Transfer-Encoding: chunked"] {
    let malicious = Data("POST / HTTP/1.1\r\n\(extra)\r\n\r\n".utf8)
    rejects("unsafe HTTP framing accepted") { _ = try bootstrap.response(malicious,now:1) }
}
rejects("oversized HTTP accepted") { _ = try bootstrap.response(Data(repeating:65,count:12289),now:1) }
print("PASS: gateway configuration, fragmented HTTP bootstrap, UID admission and HTTP framing limits")

func dnsQuery(_ name: String, type: UInt8 = 1) -> Data {
    var q = Data([0x12,0x34,1,0,0,1,0,0,0,0,0,0])
    for label in name.split(separator:".") { q.append(UInt8(label.utf8.count)); q.append(contentsOf:label.utf8) }
    q.append(contentsOf:[0,0,type,0,1]); return q
}
let dns = try CameraGatewayDNS.response(dnsQuery("v720.naxclow.com"),address:"192.168.1.20")
check(Array(dns.prefix(2)) == [0x12,0x34] && dns[dns.startIndex+7] == 1 && dns.suffix(4) == Data([192,168,1,20]),"DNS A mapping or transaction ID")
let noAAAA = try CameraGatewayDNS.response(dnsQuery("v720.p2p.naxclow.com",type:28),address:"192.168.1.20")
check(noAAAA[noAAAA.startIndex+7] == 0,"DNS returned a bogus IPv6 address")
let unknown = try CameraGatewayDNS.response(dnsQuery("unrelated.example"),address:"192.168.1.20")
check(unknown[unknown.startIndex+3] & 15 == 3,"DNS became a general resolver")
rejects("DNS compression loop accepted") { _ = try CameraGatewayDNS.response(Data([0,0,1,0,0,1,0,0,0,0,0,0,0xc0,0x0c,0,1,0,1]),address:"127.0.0.1") }
var edns = dnsQuery("v720.naxclow.com"); edns[edns.startIndex+11] = 1
edns.append(contentsOf:[0,0,41,4,208,0,0,0,0,0,0])
let ednsReply = try CameraGatewayDNS.response(edns,address:"127.0.0.1")
check(ednsReply.suffix(4) == Data([127,0,0,1]) && ednsReply[ednsReply.startIndex+3] & 128 == 0,"bounded EDNS handling or recursion claim")
print("PASS: camera-only DNS, IPv4/IPv6 responses, bounded labels and compressed-query rejection")

func mqttString(_ s: String) -> Data { Data([UInt8(s.utf8.count >> 8),UInt8(s.utf8.count & 255)]) + Data(s.utf8) }
func connect(_ id: String) -> CameraMQTTPacket { CameraMQTTPacket(header:0x10,payload:mqttString("MQTT") + Data([4,2,0,10]) + mqttString(id)) }
var mqtt = CameraMQTTSession(deviceID:"testcam0001")
let connected = try mqtt.receive(connect("testcam0001")); check(connected == Data([0x20,2,0,0]),"MQTT CONNECT acknowledgement")
let pong = try mqtt.receive(CameraMQTTPacket(header:0xc0,payload:Data())); check(pong == Data([0xd0,0]),"MQTT keepalive")
let suback = try mqtt.receive(CameraMQTTPacket(header:0x82,payload:Data([0,7])+mqttString("Naxclow/P2P/Users/Device/sub/testcam0001")+Data([0]))); check(suback == Data([0x90,3,0,7,0]),"MQTT own-device subscription")
rejects("wildcard MQTT subscription accepted") { _ = try mqtt.receive(CameraMQTTPacket(header:0x82,payload:Data([0,7])+mqttString("#")+Data([0]))) }
var stranger = CameraMQTTSession(deviceID:"testcam0001")
rejects("unrelated MQTT identity accepted") { _ = try stranger.receive(connect("othercam01")) }
var parser = CameraMQTTDecoder(); var packets: [CameraMQTTPacket] = []
for b in Data([0xc0,0,0xe0,0]) { packets += try parser.feed(Data([b])) }
check(packets.count == 2 && packets[0].header == 0xc0 && packets[1].header == 0xe0,"fragmented/coalesced MQTT framing")
rejects("oversized MQTT retained") { _ = try parser.feed(Data([0x30,0xff,0xff,0x7f])) }
print("PASS: bounded MQTT framing, own-camera identity/topics, keepalive and subscription acknowledgements")

let jpeg = try Data(contentsOf:URL(fileURLWithPath:"build/TestFrame.jpg"))
let cut = jpeg.count/2
func fragment(_ flag: UInt8, _ seq: UInt32, _ payload: Data) -> CameraPacket { CameraPacket(command:1 | UInt32(flag)<<16,payload:payload,sequence:seq) }
let first = fragment(250,UInt32.max-1,Data(jpeg.prefix(cut)))
let middle = fragment(251,UInt32.max,Data(jpeg.dropFirst(cut).dropLast(1)))
let last = fragment(252,0,Data(jpeg.suffix(1))+Data([0])+CameraWire.little32(UInt32(jpeg.count)))
var assembly = CameraStationJPEG()
check(assembly.feed(last,now:10) == nil && assembly.feed(first,now:10) == nil && assembly.feed(middle,now:10) == jpeg,"out-of-order JPEG or sequence wrap failed")
check(assembly.feed(fragment(255,1,jpeg),now:10) == jpeg,"single-datagram JPEG")
_ = assembly.feed(first,now:20); _ = assembly.feed(last,now:20)
check(assembly.feed(middle,now:22) == nil,"expired fragment assembly delivered a frame")
assembly.reset(); _ = assembly.feed(first,now:30); _ = assembly.feed(last,now:30)
check(assembly.feed(fragment(251,UInt32.max,Data([0])),now:30) != jpeg,"corrupt fragment reconstructed original frame")
rejects("short datagram accepted") { _ = try CameraPacket.datagram(Data([0,0])) }
rejects("trailing datagram data accepted") { _ = try CameraPacket.datagram(CameraWire.packet(command:1,payload:jpeg)+Data([0])) }
print("PASS: UDP datagram limits, reordered JPEG fragments, missing/expired frames and sequence wrap")

var machine = CameraDirectProtocol(.classicVideo)
check(machine.start() == [CameraWire.packet(command:115)],"typed handshake hello")
_ = machine.receive(CameraPacket(command:115,payload:Data()),now:1)
_ = machine.receive(CameraPacket(command:0,payload:Data("{\"code\":501,\"status\":200}".utf8)),now:1)
let rejected = machine.receive(CameraPacket(command:0,payload:Data("{\"code\":502,\"content\":{\"code\":4,\"status\":403}}".utf8)),now:1)
check(rejected.failure == .authentication(403) && rejected.writes.isEmpty,"nested rejection ignored")
check(!CameraFailure.authentication(1).canTryAnotherProtocol && !CameraFailure.unsupportedCodec.canTryAnotherProtocol && CameraFailure.malformed.canTryAnotherProtocol,"typed fallback policy")
print("PASS: shared direct handshake and typed fallback/error policy")

var seed: UInt64 = 0xa940_2026_1018
for _ in 0..<10000 {
    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
    let length = Int(seed % 513)
    let bytes = Data((0..<length).map { _ -> UInt8 in seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return UInt8(truncatingIfNeeded:seed) })
    _ = try? CameraGatewayDNS.response(bytes,address:"127.0.0.1")
    _ = try? bootstrap.response(bytes,now:1)
    var decoder = CameraMQTTDecoder(); _ = try? decoder.feed(bytes)
    _ = try? CameraPacket.datagram(bytes)
}
print("PASS: 10,000 deterministic malformed gateway/DNS/MQTT/datagram inputs under AddressSanitizer")

let pathFixture = "/tmp/camera's app $(printf injected); `printf injected`"
let process = Process(); process.executableURL = URL(fileURLWithPath:"/bin/sh")
process.arguments = ["-c","printf '%s' " + CameraRelayCommand.quote(pathFixture)]
let pipe = Pipe(); process.standardOutput = pipe
try process.run(); let roundtrip = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
check(process.terminationStatus == 0 && String(data:roundtrip,encoding:.utf8) == pathFixture,"relay command shell injection or argument corruption")
print("PASS: relay command preserves apostrophes, spaces, command substitutions and shell metacharacters")
