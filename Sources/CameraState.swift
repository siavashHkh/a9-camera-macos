import Foundation

// Transport decisions use these values, never the text shown in the UI.
enum CameraFailure: Error, Equatable {
    case unreachable, network, disconnected, malformed, noVideo, stalled, authentication(Int), unsupportedCodec
    var canTryAnotherProtocol: Bool { self == .disconnected || self == .malformed || self == .noVideo }
    var message: String {
        switch self {
        case .unreachable: return "Camera is unreachable. Join its hotspot, or use Home network gateway for station-mode firmware."
        case .network: return "Camera connection failed. Check the selected network and camera power."
        case .disconnected: return "Camera closed the video connection."
        case .malformed: return "Unrecognized camera data. The peer returned invalid framing."
        case .noVideo: return "No video received. Check the camera mode and protocol."
        case .stalled: return "Video stopped arriving. Check camera power and reconnect."
        case .authentication(let code): return "Camera rejected the request (status \(code)). This firmware may require authentication."
        case .unsupportedCodec: return "This camera is sending H.264. The current decoder supports MJPEG."
        }
    }
}
enum CameraVideoState: Equatable {
    case idle, connecting, handshaking, waitingForFrames, streaming, stopped, failed(CameraFailure)
}

struct CameraDirectProtocol {
    enum Purpose { case classicVideo, newerVideo, wifi(Data) }
    enum Stage { case idle, hello, authorization, information, waitingForFrames, sendingSettings, accepted }
    struct Action {
        var writes: [Data] = []
        var failure: CameraFailure?
        var acceptedSettings = false
    }
    let purpose: Purpose
    private(set) var stage = Stage.idle
    private var settings: Data?
    init(_ purpose: Purpose) {
        self.purpose = purpose
        if case .wifi(let payload) = purpose { settings = payload }
    }
    var modern: Bool { if case .newerVideo = purpose { return true }; return false }
    private func json(_ object: [String: Any]) -> Data {
        CameraWire.packet(command: modern ? 8 : 0, payload: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), modern: modern)
    }
    private func forward(_ code: Int) -> Data { json(["code": 502, "content": ["code": code, "devTarget": "deadbeef"]]) }
    mutating func start() -> [Data] {
        stage = .hello
        return [modern ? json(["code": 115]) : CameraWire.packet(command: 115)]
    }
    mutating func receive(_ packet: CameraPacket, now: Int) -> Action {
        let cmd = modern ? packet.command : packet.command & 0xffff
        if modern && cmd == 1001 { return Action(failure: .unsupportedCodec) }
        if (!modern && cmd == 101) || (modern && cmd == 9) {
            return Action(writes: [CameraWire.packet(command: modern ? 10 : 102, modern: modern)])
        }
        if !modern && cmd == 115 && stage == .hello {
            stage = .authorization
            return Action(writes: [json(["code":501,"target":"deadbeef","token":"This is TEST token","unixTimer":now])])
        }
        guard cmd == (modern ? 8 : 0),
              let object = (try? JSONSerialization.jsonObject(with: packet.payload)) as? [String:Any],
              let code = object["code"] as? Int else { return Action() }
        if let result = object["status"] as? Int, result != 0 && result != 200 { return Action(failure:.authentication(result)) }
        if modern {
            if code == 115 && stage == .hello { stage = .authorization; return Action(writes:[json(["code":214])]) }
            if code == 214 && stage == .authorization { stage = .waitingForFrames; return Action(writes:[json(["code":213,"avSwitch":2])]) }
        } else if code == 501 && stage == .authorization {
            if let payload = settings {
                settings = nil; stage = .sendingSettings
                return Action(writes:[CameraWire.packet(command:0,payload:payload)])
            }
            stage = .information; return Action(writes:[forward(4)])
        } else if code == 502, let content = object["content"] as? [String:Any] {
            if let result = content["status"] as? Int, result != 0 && result != 200 { return Action(failure:.authentication(result)) }
            if stage == .information && content["code"] as? Int == 4 { stage = .waitingForFrames; return Action(writes:[forward(2)]) }
            if stage == .sendingSettings && content["code"] as? Int == 204 {
                stage = .accepted; return Action(writes:[forward(299)],acceptedSettings:true)
            }
        }
        return Action()
    }
}
