import Foundation

enum CameraWire {
    static let maxPayload = 4 * 1024 * 1024
    static func little32(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)])
    }
    static func read32(_ bytes: Data, _ offset: Int) -> UInt32 {
        let i = bytes.startIndex + offset
        return UInt32(bytes[i]) | UInt32(bytes[i+1]) << 8 | UInt32(bytes[i+2]) << 16 | UInt32(bytes[i+3]) << 24
    }
    static func packet(command: UInt32, payload: Data = Data(), modern: Bool = false) -> Data {
        var data = little32(UInt32(payload.count))
        data.append(little32(command))
        data.append(modern ? Data(repeating: 0, count: 12) : Data("00000000".utf8) + Data(repeating: 0, count: 4))
        data.append(payload)
        return data
    }
}

struct CameraPacket { let command: UInt32; let payload: Data }
enum CameraParseError: Error { case oversized }
struct PacketDecoder {
    var buffer = Data()
    mutating func feed(_ bytes: Data) throws -> [CameraPacket] {
        buffer.append(bytes)
        var packets: [CameraPacket] = []
        while buffer.count >= 20 {
            let length = Int(CameraWire.read32(buffer, 0))
            guard length <= CameraWire.maxPayload else { buffer.removeAll(); throw CameraParseError.oversized }
            guard buffer.count >= length + 20 else { break }
            packets.append(CameraPacket(command: CameraWire.read32(buffer, 4), payload: Data(buffer.dropFirst(20).prefix(length))))
            buffer.removeFirst(length + 20)
        }
        return packets
    }
}
struct JPEGDecoder {
    var buffer = Data()
    mutating func feed(_ bytes: Data) -> [Data] {
        buffer.append(bytes)
        if buffer.count > CameraWire.maxPayload { buffer.removeAll(); return [] }
        var images: [Data] = []
        while true {
            guard let start = buffer.range(of: Data([0xff, 0xd8])) else {
                buffer = Data(buffer.suffix(1)); break
            }
            if start.lowerBound > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start.lowerBound) }
            guard let end = buffer.range(of: Data([0xff, 0xd9]), in: (buffer.startIndex + 2)..<buffer.endIndex) else { break }
            images.append(Data(buffer[buffer.startIndex..<end.upperBound]))
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
        }
        return images
    }
}
