import Foundation
import AppKit
import Network
import Darwin

setbuf(stdout, nil)
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { print("FAIL: \(message)"); exit(1) }
}
let samplePayload = Data("camera payload".utf8)
let classicHello = Data([0, 0, 0, 0, 115, 0, 0, 0, 48, 48, 48, 48, 48, 48, 48, 48, 0, 0, 0, 0])
check(CameraWire.packet(command: 115) == classicHello, "classic handshake wire bytes")
let modernHello = Data([12, 0, 0, 0, 8, 0, 0, 0] + Array(repeating: UInt8(0), count: 12)) + Data("{\"code\":115}".utf8)
check(CameraWire.packet(command: 8, payload: Data("{\"code\":115}".utf8), modern: true) == modernHello, "modern handshake wire bytes")
var fragmented = PacketDecoder()
var decoded: [CameraPacket] = []
for byte in CameraWire.packet(command: 115, payload: samplePayload) {
    decoded.append(contentsOf: try fragmented.feed(Data([byte])))
}
check(decoded.count == 1 && decoded[0].command == 115 && decoded[0].payload == samplePayload, "fragmented packet")
var coalesced = PacketDecoder()
let combined = try coalesced.feed(CameraWire.packet(command: 1) + CameraWire.packet(command: 8, payload: samplePayload, modern: true))
check(combined.count == 2 && combined[1].payload == samplePayload, "coalesced packets")
var oversized = PacketDecoder()
do {
    _ = try oversized.feed(CameraWire.little32(UInt32(CameraWire.maxPayload + 1)) + Data(repeating: 0, count: 16))
    check(false, "oversized payload accepted")
} catch CameraParseError.oversized {} catch { check(false, "unexpected parser error") }
let recovered = try oversized.feed(classicHello)
check(recovered.count == 1, "parser recovery after oversized packet")
for modern in [false, true] {
    let fixture = CameraWire.packet(command: 1, payload: samplePayload, modern: modern)
    for split in 0...fixture.count {
        var parser = PacketDecoder()
        let first = try parser.feed(Data(fixture.prefix(split)))
        let second = try parser.feed(Data(fixture.dropFirst(split)))
        let packets = first + second
        check(packets.count == 1 && packets[0].payload == samplePayload, "every packet split boundary")
    }
}
var sliced = PacketDecoder()
let slicedData = Data([9, 9, 9]) + classicHello + classicHello
let slicedPackets = try sliced.feed(slicedData.dropFirst(3))
check(slicedPackets.count == 2, "nonzero Data start index")
var jpegParser = JPEGDecoder()
check(jpegParser.feed(Data([0, 0xff])).isEmpty, "split JPEG start")
check(jpegParser.feed(Data([0xd8, 1, 0xff])).isEmpty, "split JPEG end")
check(jpegParser.feed(Data([0xd9])) == [Data([0xff, 0xd8, 1, 0xff, 0xd9])], "JPEG assembly")
let tinyJPEG = Data([0xff, 0xd8, 1, 0xff, 0xd9])
check(jpegParser.feed(tinyJPEG + tinyJPEG) == [tinyJPEG, tinyJPEG], "multiple JPEG frames")
check(jpegParser.feed(Data([0xff, 0xd8]) + Data(repeating: 0, count: CameraWire.maxPayload)).isEmpty, "oversized JPEG discarded")
check(jpegParser.feed(tinyJPEG) == [tinyJPEG], "JPEG recovery after oversized frame")
for address in ["127.0.0.1", "192.168.169.1", "10.0.0.1", "172.16.0.1", "172.31.255.255", "169.254.1.2"] {
    check(CameraVideo.validLocalAddress(address), "local address rejected")
}
for address in ["8.8.8.8", "", "192.168..1", "256.1.1.1", "camera.example", "172.15.0.1", "172.32.0.1", "::1", "192.168.1.1:6123", "192.168.1.1\n", "١٩٢.١٦٨.١.١", "-1.0.0.1"] {
    check(!CameraVideo.validLocalAddress(address), "invalid/public address accepted")
}
print("PASS: packet/JPEG parsing and local-address validation")

// A locally generated JPEG verifies the actual image path without displaying
// a fake camera feed in the user's app or connecting to external devices.
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
    samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
for x in 0..<2 { for y in 0..<2 {
    let offset = y * bitmap.bytesPerRow + x * 3
    bitmap.bitmapData![offset] = 0
    bitmap.bitmapData![offset + 1] = 0
    bitmap.bitmapData![offset + 2] = 255
} }
let testJPEG = bitmap.representation(using: .jpeg, properties: [:])!
try testJPEG.write(to: URL(fileURLWithPath: "build/TestFrame.jpg"))
let serverQueue = DispatchQueue(label: "a9.test.server")
let parameters = NWParameters.tcp
parameters.allowLocalEndpointReuse = true
parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 6123)
let listener = try NWListener(using: parameters)

final class Peer {
    let connection: NWConnection
    var decoder = PacketDecoder()
    var modern: Bool?
    init(_ connection: NWConnection) { self.connection = connection }
    func send(_ command: UInt32, _ payload: Data = Data()) {
        connection.send(content: CameraWire.packet(command: command, payload: payload, modern: modern == true), completion: .contentProcessed { error in
            if let error = error { print("Server send error: \(error)") }
        })
    }
    func json(_ object: [String: Any]) {
        send(modern == true ? 8 : 0, try! JSONSerialization.data(withJSONObject: object))
    }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            if let data = data {
                do { for packet in try self.decoder.feed(data) { self.handle(packet) } }
                catch { check(false, "client sent malformed packets") }
            }
            if error == nil && !complete { self.receive() }
        }
    }
    func handle(_ packet: CameraPacket) {
        if modern == nil { modern = packet.command == 8 }
        if modern == false && packet.command == 115 { send(115); return }
        guard packet.command == (modern == true ? 8 : 0),
              let object = try? JSONSerialization.jsonObject(with: packet.payload) as? [String: Any],
              let code = object["code"] as? Int else { return }
        if modern == true {
            switch code {
            case 115: json(["code": 115])
            case 214: json(["code": 214])
            case 213:
                check(object["avSwitch"] as? Int == 2, "modern video request")
                frames()
            default: check(false, "unexpected modern request \(code)")
            }
        } else {
            if code == 501 { json(["code": 501]) }
            else if code == 502, let content = object["content"] as? [String: Any], let inner = content["code"] as? Int {
                if inner == 4 { json(["code": 502, "content": ["code": 4]]) }
                else if inner == 2 { frames() }
                else { check(false, "unexpected classic request") }
            } else { check(false, "unexpected classic command") }
        }
    }
    func frames() {
        let command: UInt32 = modern == true ? 1003 : 0x0001_0001
        send(command, Data(testJPEG.prefix(1)))
        send(command, Data(testJPEG.dropFirst().dropLast()))
        send(command, Data(testJPEG.suffix(1)))
    }
}
var peers: [Peer] = []
listener.newConnectionHandler = { connection in
    let peer = Peer(connection); peers.append(peer)
    connection.start(queue: serverQueue); peer.receive()
}
let video = CameraVideo()
var phase = 0
video.onStatus = { print("CLIENT: \($0)") }
video.onStopped = { check(false, "video stopped before receiving a test frame") }
video.onFrame = { data in
    check(data == testJPEG && NSImage(data: data) != nil, "invalid reconstructed JPEG")
    print("PASS: \(phase == 0 ? "classic" : "modern") loopback handshake and decoded JPEG")
    video.stop()
    if phase == 0 {
        phase = 1
        video.start(host: "127.0.0.1", modern: true)
    } else {
        listener.cancel()
        print("All checks passed. These use a simulated camera, not physical hardware.")
        exit(0)
    }
}
listener.stateUpdateHandler = { state in
    switch state {
    case .ready: video.start(host: "127.0.0.1", modern: false)
    case .failed(let error): print("FAIL: loopback listener: \(error)"); exit(1)
    default: break
    }
}
listener.start(queue: serverQueue)
DispatchQueue.global().asyncAfter(deadline: .now() + 20) { print("FAIL: loopback checks timed out"); exit(1) }
dispatchMain()
