import Foundation
import Network
import Darwin

setbuf(stdout, nil)
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { print("FAIL: \(message)"); exit(1) }
}

struct Scenario {
    let name: String
    let modern: Bool
    let expected: String
}
let scenarios = [
    Scenario(name: "authentication rejection", modern: false, expected: "Camera rejected the request (status 403)"),
    Scenario(name: "illegal user rejection", modern: false, expected: "Camera rejected the request (status 1)"),
    Scenario(name: "unsupported H.264", modern: true, expected: "This camera is sending H.264"),
    Scenario(name: "oversized network packet", modern: true, expected: "Unrecognized camera data"),
    Scenario(name: "peer disconnect", modern: false, expected: "Camera closed the video connection"),
    Scenario(name: "silent camera timeout", modern: true, expected: "No video received"),
    Scenario(name: "cancel", modern: false, expected: "Video stopped.")
]
let serverQueue = DispatchQueue(label: "a9.failure.server")
let parameters = NWParameters.tcp
parameters.allowLocalEndpointReuse = true
parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 6123)
let listener = try NWListener(using: parameters)

final class Peer {
    let connection: NWConnection
    let scenario: Scenario
    var decoder = PacketDecoder()
    var handled = false
    init(_ connection: NWConnection, scenario: Scenario) {
        self.connection = connection; self.scenario = scenario
    }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            if let data = data {
                do {
                    for packet in try self.decoder.feed(data) { self.handle(packet) }
                } catch { check(false, "client emitted malformed packet") }
            }
            if error == nil && !complete { self.receive() }
        }
    }
    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error { print("FAIL: simulated camera send: \(error)"); exit(1) }
        })
    }
    func handle(_ packet: CameraPacket) {
        guard !handled else { return }
        handled = true
        switch scenario.name {
        case "authentication rejection":
            send(CameraWire.packet(command: 115))
            send(CameraWire.packet(command: 0, payload: Data("{\"code\":501,\"status\":403}".utf8)))
        case "illegal user rejection":
            send(CameraWire.packet(command: 115))
            send(CameraWire.packet(command: 0, payload: Data("{\"code\":501,\"status\":1}".utf8)))
        case "unsupported H.264":
            send(CameraWire.packet(command: 1001, payload: Data([0, 0, 0, 1]), modern: true))
        case "oversized network packet":
            send(CameraWire.little32(UInt32(CameraWire.maxPayload + 1)) + Data(repeating: 0, count: 16))
        case "peer disconnect":
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        case "silent camera timeout", "cancel": break
        default: check(false, "unknown scenario")
        }
    }
}
var peers: [Peer] = [] // Accessed only on serverQueue.
listener.newConnectionHandler = { connection in
    check(peers.count < scenarios.count, "unexpected extra connection")
    let peer = Peer(connection, scenario: scenarios[peers.count])
    peers.append(peer)
    connection.start(queue: serverQueue)
    peer.receive()
}
let video = CameraVideo()
var phase = 0 // Callbacks run on the main queue.
var status = ""
var cancelRequested = false
func next() {
    print("PASS: \(scenarios[phase].name)")
    phase += 1
    if phase == scenarios.count {
        listener.cancel()
        print("All failure, timeout, and cancellation checks passed using a simulated camera.")
        exit(0)
    }
    status = ""
    video.start(host: "127.0.0.1", modern: scenarios[phase].modern)
}
video.onFrame = { _ in check(false, "unexpected frame in failure scenario") }
video.onStatus = { text in
    status = text
    print("CLIENT: \(text)")
    if scenarios[phase].name == "cancel", text.hasPrefix("Connected over Wi-Fi"), !cancelRequested {
        cancelRequested = true
        video.stop()
    } else if scenarios[phase].name == "cancel", text == "Video stopped." {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { next() }
    }
}
video.onStopped = {
    check(scenarios[phase].name != "cancel", "explicit cancellation triggered an error callback")
    check(status.contains(scenarios[phase].expected), "wrong failure status: \(status)")
    next()
}
listener.stateUpdateHandler = { state in
    switch state {
    case .ready:
        DispatchQueue.main.async { video.start(host: "127.0.0.1", modern: scenarios[0].modern) }
    case .failed(let error): print("FAIL: listener: \(error)"); exit(1)
    default: break
    }
}
listener.start(queue: serverQueue)
DispatchQueue.global().asyncAfter(deadline: .now() + 45) { print("FAIL: failure checks timed out"); exit(1) }
dispatchMain()
