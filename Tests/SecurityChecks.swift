import Foundation
import AppKit
import Darwin

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { print("FAIL: \(message)"); exit(1) }
}
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
    samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
memset(bitmap.bitmapData!, 0, bitmap.bytesPerRow * 2)
let validJPEG = bitmap.representation(using: .jpeg, properties: [:])!
try validJPEG.write(to: URL(fileURLWithPath: "build/SecurityFrame.jpg"))
check(CameraFrame.decode(validJPEG)?.image.width == 2, "valid JPEG rejected")
check(CameraFrame.decode(Data([0xff, 0xd8, 0, 0xff, 0xd9])) == nil, "marker-only data accepted as an image")
check(CameraFrame.decode(Data()) == nil, "empty image accepted")

func changedDimensions(width: Int, height: Int) -> Data {
    var bytes = Array(validJPEG)
    var offset = 2
    while offset + 8 < bytes.count {
        check(bytes[offset] == 0xff, "fixture JPEG segment structure")
        let marker = bytes[offset + 1]
        if [UInt8(0xc0), 0xc1, 0xc2].contains(marker) {
            bytes[offset + 5] = UInt8(truncatingIfNeeded: height >> 8)
            bytes[offset + 6] = UInt8(truncatingIfNeeded: height)
            bytes[offset + 7] = UInt8(truncatingIfNeeded: width >> 8)
            bytes[offset + 8] = UInt8(truncatingIfNeeded: width)
            return Data(bytes)
        }
        let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        check(length >= 2, "fixture JPEG segment length")
        offset += length + 2
    }
    check(false, "fixture JPEG has no start-of-frame segment")
    return Data()
}
for (width, height) in [(65535, 65535), (4096, 4096), (5000, 2), (2, 5000), (0, 2)] {
    check(CameraFrame.decode(changedDimensions(width: width, height: height)) == nil, "oversized/zero dimensions accepted")
}
print("PASS: valid JPEG decode; malformed, excessive dimensions and pixel count rejected before full decode")

var flood = Data()
let tiny = Data([0xff, 0xd8, 0, 0xff, 0xd9])
for _ in 0..<100_000 { flood.append(tiny) }
var jpeg = JPEGDecoder()
check(jpeg.feed(flood).count == 1, "frame flood generated an unbounded result array")
print("PASS: 100,000-frame marker flood coalesced into one frame")

let payload = try CameraSetup.payload(ssid: "Test\"\\Network", password: "test-secret")
let object = try JSONSerialization.jsonObject(with: payload) as! [String: String]
check(object == ["s": "Test\"\\Network", "p": "test-secret", "u": ""], "Wi-Fi JSON escaping or keys changed")
for (name, secret) in [("", "test-secret"), (String(repeating: "é", count: 17), "test-secret"), ("test", "short"), ("test", String(repeating: "g", count: 64))] {
    do { _ = try CameraSetup.payload(ssid: name, password: secret); check(false, "invalid Wi-Fi details accepted") }
    catch CameraSetup.ValidationError.ssid {} catch CameraSetup.ValidationError.password {}
}
_ = try CameraSetup.payload(ssid: "test", password: "")
_ = try CameraSetup.payload(ssid: String(repeating: "a", count: 32), password: String(repeating: "a", count: 63))
_ = try CameraSetup.payload(ssid: "test", password: String(repeating: "a", count: 64))
let echo = Data("test-secret".utf8)
let status = CameraSetup.responseStatus(echo)
check(!status.contains("test-secret") && !status.contains("74657374"), "camera reply disclosed an echoed credential")
print("PASS: Wi-Fi credential validation/escaping and response redaction")

var seed: UInt64 = 0xa9c0_0320_2610_1701
func random() -> UInt64 {
    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
    return seed
}
var packetParser = PacketDecoder()
var imageParser = JPEGDecoder()
for _ in 0..<20_000 {
    let count = Int(random() % 257)
    let bytes = Data((0..<count).map { _ in UInt8(truncatingIfNeeded: random()) })
    do {
        let packets = try packetParser.feed(bytes)
        check(packets.allSatisfy { $0.payload.count <= CameraWire.maxPayload }, "packet size limit bypass")
    } catch CameraParseError.oversized {} catch { check(false, "unexpected packet error") }
    check(packetParser.buffer.count <= CameraWire.maxPayload + 20, "packet buffer limit bypass")
    check(imageParser.feed(bytes).count <= 1, "JPEG parser result count limit bypass")
    check(imageParser.buffer.count <= CameraWire.maxPayload, "JPEG buffer limit bypass")
}
print("PASS: 20,000 deterministic malformed-input iterations (seed 0xa9c0032026101701) under AddressSanitizer")

// Delivery, acknowledgement and Wi-Fi association are distinct events.
var attempt = CameraSetupAttempt()
let firstAttempt = attempt.begin()
check(attempt.wrote(success: true, generation: firstAttempt), "write completion lost")
check(attempt.didDisconnect() && attempt.isPending, "disconnect falsely completed setup")
check(attempt.status.contains("write completed") && attempt.status.contains("disconnected"), "delivery evidence lost")
check(!attempt.acknowledge(Data([0, 0])) && !attempt.acknowledge(echo), "non-exact acknowledgement accepted")
check(attempt.timeOut(generation: firstAttempt) && attempt.phase == .unconfirmed, "missing acknowledgement falsely succeeded")
check(attempt.status.contains("unverified"), "timeout claimed a verified Wi-Fi join")
let secondAttempt = attempt.begin()
check(!attempt.timeOut(generation: firstAttempt) && !attempt.wrote(success: false, generation: firstAttempt), "stale attempt changed current state")
check(attempt.acknowledge(Data([0])) && !attempt.acknowledge(Data([0])), "duplicate acknowledgement changed state")
check(!attempt.wrote(success: false, generation: secondAttempt) && !attempt.timeOut(generation: secondAttempt), "late error overwrote acknowledgement")
check(attempt.phase == .acknowledged && attempt.status.contains("not yet verified"), "acknowledgement claimed network association")
let thirdAttempt = attempt.begin()
check(attempt.wrote(success: false, generation: thirdAttempt), "write failure lost")
check(!attempt.didDisconnect() && !attempt.timeOut(generation: thirdAttempt) && attempt.phase == .failed, "terminal write failure overwritten")
attempt.reset()
check(!attempt.acknowledge(Data([0])) && attempt.phase == .idle, "unsolicited acknowledgement accepted")
let ap = try JSONSerialization.jsonObject(with: CameraSetup.hotspotPayload(ssid: "Test\"\\Network", password: "test-secret")) as! [String: Any]
let content = ap["content"] as! [String: Any]
check(ap["code"] as? Int == 502 && content["code"] as? Int == 204 && content["devTarget"] as? String == "deadbeef", "hotspot command layout")
check(content["s"] as? String == "Test\"\\Network" && content["p"] as? String == "test-secret", "hotspot credential escaping")
print("PASS: setup delivery/acknowledgement/disconnect ordering, stale generations, terminal errors, and hotspot payload")
