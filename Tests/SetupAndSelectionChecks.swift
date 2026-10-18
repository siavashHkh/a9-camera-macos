import Foundation
import Network
import Darwin

setbuf(stdout, nil)
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { print("FAIL: \(message)"); exit(1) }
}
// Response frames are constructed independently of CameraWire.packet.
func fixture(_ command: UInt32, _ payload: Data = Data(), modern: Bool = false) -> Data {
    func word(_ n: UInt32) -> [UInt8] { [UInt8(truncatingIfNeeded: n), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 24)] }
    return Data(word(UInt32(payload.count)) + word(command) + Array(repeating: modern ? UInt8(0) : UInt8(48), count: 8) + [0, 0, 0, 0]) + payload
}
enum Trial: String, CaseIterable {
    case apSuccess, apAuthReject, apSettingsReject, apDisconnect, apTimeout, apOversize, apCancel, apInvalidThenValid
    case autoFallback, autoAuthReject, explicitNewer, autoCancel, frameThenDisconnect
    var isAP: Bool { rawValue.hasPrefix("ap") }
}
let serverQueue = DispatchQueue(label: "a9.setup-tests.server")
let parameters = NWParameters.tcp
parameters.allowLocalEndpointReuse = true
parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 6123)
let listener = try NWListener(using: parameters)
let jpeg = try Data(contentsOf: URL(fileURLWithPath: "build/TestFrame.jpg"))
final class Peer {
    let connection: NWConnection
    let trial: Trial
    let number: Int
    var decoder = PacketDecoder()
    var modern = false
    var setCount = 0
    var rebootCount = 0
    init(_ connection: NWConnection, trial: Trial, number: Int) {
        self.connection = connection; self.trial = trial; self.number = number
    }
    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
    func json(_ object: [String: Any]) {
        send(fixture(modern ? 8 : 0, try! JSONSerialization.data(withJSONObject: object), modern: modern))
    }
    func eof() { connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in }) }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            if let data = data {
                do { for packet in try self.decoder.feed(data) { self.handle(packet) } }
                catch { check(false, "malformed client packet") }
            }
            if !done && error == nil { self.receive() }
        }
    }
    func handle(_ packet: CameraPacket) {
        if !trial.isAP {
            if trial == .autoFallback && number == 1 { check(packet.command == 115, "automatic must start classic"); eof(); return }
            modern = trial == .explicitNewer || (trial == .autoFallback && number == 2)
            if trial == .explicitNewer { check(packet.command == 8, "explicit newer ignored"); eof(); return }
            if trial == .autoCancel { return }
        }
        if packet.command == 115 {
            check(!modern && packet.payload.isEmpty, "classic hello layout")
            if trial == .apOversize { send(Data([1, 0, 64, 0]) + Data(repeating: 0, count: 16)) }
            else { send(fixture(115)) }
            return
        }
        guard packet.command == (modern ? 8 : 0),
              let object = try? JSONSerialization.jsonObject(with: packet.payload) as? [String: Any],
              let code = object["code"] as? Int else { check(false, "unexpected request"); return }
        if modern {
            if code == 115 { json(["code": 115]) }
            else if code == 214 { json(["code": 214]) }
            else if code == 213 { check(object["avSwitch"] as? Int == 2, "newer video request"); send(fixture(1003, jpeg, modern: true)) }
            return
        }
        if code == 501 {
            check(object["target"] as? String == "deadbeef" && object["token"] as? String == "This is TEST token", "classic auth fields")
            json(["code": 501, "status": trial == .apAuthReject || trial == .autoAuthReject ? 1 : 0])
            return
        }
        guard code == 502, let content = object["content"] as? [String: Any], let inner = content["code"] as? Int else { check(false, "forwarded request shape"); return }
        if trial.isAP {
            if inner == 204 {
                setCount += 1
                check(setCount == 1 && content["s"] as? String == "Lab Camera" && content["p"] as? String == "fixture-key" && content["devTarget"] as? String == "deadbeef", "setup command or credentials")
                if trial == .apDisconnect { eof() }
                else if trial == .apTimeout || trial == .apCancel { return }
                else {
                    let reply = fixture(0, Data("{\"code\":502,\"content\":{\"code\":204,\"status\":\(trial == .apSettingsReject ? 400 : 0)}}".utf8))
                    send(Data(reply.prefix(7))); send(Data(reply.dropFirst(7)) + reply)
                }
            } else if inner == 299 { rebootCount += 1 }
            else { check(false, "unexpected setup command") }
        } else {
            if inner == 4 { json(["code": 502, "content": ["code": 4]]) }
            else if inner == 2 {
                send(fixture(1, jpeg))
                serverQueue.asyncAfter(deadline: .now() + 0.3) { self.eof() }
            }
        }
    }
}
var serverTrial = Trial.apSuccess // Server queue only.
var peers: [Peer] = [] // Server queue only.
listener.newConnectionHandler = { connection in
    let peer = Peer(connection, trial: serverTrial, number: peers.count + 1)
    peers.append(peer)
    connection.start(queue: serverQueue); peer.receive()
}
let ap = CameraAPSetup(timeout: 1.0)
let video = CameraVideoController()
var index = 0 // Main queue only.
var receivedFrame = false
var lastStatus = ""
var ending = false
var cancelRequested = false
func completeTrial() {
    guard !ending else { return }; ending = true
    ap.cancel(); video.stop()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        let trial = Trial.allCases[index]
        serverQueue.sync {
            let count = peers.count
            check(count == (trial == .autoFallback ? 2 : 1), "unexpected connection count in \(trial): \(count)")
            if trial == .apSuccess || trial == .apInvalidThenValid {
                check(peers[0].setCount == 1 && peers[0].rebootCount == 1, "accepted settings must request exactly one reboot")
            }
            if trial == .apAuthReject { check(peers[0].setCount == 0, "settings sent after authentication rejection") }
            if trial == .apSettingsReject { check(peers[0].rebootCount == 0, "reboot sent after settings rejection") }
            for peer in peers { peer.connection.cancel() }
            peers.removeAll()
        }
        print("PASS: \(trial.rawValue)")
        index += 1
        if index == Trial.allCases.count { listener.cancel(); print("All hotspot setup and protocol-selection integration checks passed (simulated cameras)."); exit(0) }
        startTrial()
    }
}
func startTrial() {
    let trial = Trial.allCases[index]
    ending = false; cancelRequested = false; receivedFrame = false; lastStatus = ""
    serverQueue.async {
        serverTrial = trial
        DispatchQueue.main.async {
            if trial.isAP {
                if trial == .apInvalidThenValid { ap.start(host: "8.8.8.8", ssid: "Lab Camera", password: "fixture-key") }
                ap.start(host: "127.0.0.1", ssid: "Lab Camera", password: "fixture-key")
            } else { video.start(host: "127.0.0.1", mode: trial == .explicitNewer ? .newer : .automatic) }
        }
    }
}
ap.onStatus = { text in
    check(!text.contains("fixture-key"), "password leaked into setup status")
    lastStatus = text
    if Trial.allCases[index] == .apCancel, text.hasPrefix("Sending Wi-Fi"), !cancelRequested {
        cancelRequested = true; ap.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { completeTrial() }
    }
}
ap.onFinished = { outcome in
    let trial = Trial.allCases[index]
    check(trial != .apCancel, "cancelled setup emitted completion")
    let expected: CameraAPSetup.Outcome
    switch trial {
    case .apSuccess, .apInvalidThenValid: expected = .accepted
    case .apDisconnect, .apTimeout: expected = .unconfirmed
    default: expected = .failed
    }
    check(outcome == expected, "wrong setup outcome in \(trial): \(outcome) / \(lastStatus)")
    if outcome == .accepted || outcome == .unconfirmed { check(lastStatus.contains("unverified") || lastStatus.contains("not yet verified"), "settings accepted claimed association") }
    completeTrial()
}
video.onStatus = { text in
    lastStatus = text
    if Trial.allCases[index] == .autoCancel, text.hasPrefix("Connected over Wi-Fi"), !cancelRequested {
        cancelRequested = true; video.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { completeTrial() }
    }
}
video.onFrame = { frame in
    check(frame.jpeg == jpeg, "wrong decoded frame")
    receivedFrame = true
    if Trial.allCases[index] == .autoFallback { completeTrial() }
}
video.onStopped = {
    let trial = Trial.allCases[index]
    check(!ending && trial != .autoCancel && trial != .autoFallback, "unexpected stop/fallback callback")
    if trial == .autoAuthReject { check(lastStatus.contains("status 1"), "authentication error hidden") }
    if trial == .frameThenDisconnect { check(receivedFrame, "stream closed before test frame") }
    completeTrial()
}
listener.stateUpdateHandler = { state in
    if case .ready = state { DispatchQueue.main.async { startTrial() } }
    if case .failed(let error) = state { print("FAIL: listener \(error)"); exit(1) }
}
listener.start(queue: serverQueue)
DispatchQueue.global().asyncAfter(deadline: .now() + 30) { print("FAIL: setup/selection watchdog"); exit(1) }
dispatchMain()
