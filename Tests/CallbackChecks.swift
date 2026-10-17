import Foundation
import Network
import Darwin

setbuf(stdout, nil)
let frame = try Data(contentsOf: URL(fileURLWithPath: "build/SecurityFrame.jpg"))
let queue = DispatchQueue(label: "a9.callback.server")
let parameters = NWParameters.tcp
parameters.allowLocalEndpointReuse = true
parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 6123)
let listener = try NWListener(using: parameters)
var peer: NWConnection?
var sent = false // server queue only
listener.newConnectionHandler = { connection in
    peer = connection
    connection.stateUpdateHandler = { state in
        if case .ready = state {
            connection.send(content: CameraWire.packet(command: 1, payload: frame), completion: .contentProcessed { error in
                if let error = error { print("FAIL: fixture send: \(error)"); exit(1) }
                sent = true
            })
        }
    }
    connection.start(queue: queue)
}
let video = CameraVideo()
video.onFrame = { _ in print("FAIL: a queued frame was delivered after Stop"); exit(1) }
video.onStopped = { print("FAIL: unexpected connection failure"); exit(1) }
video.onStatus = { status in
    if status.hasPrefix("Connected over Wi-Fi") {
        // Let a frame queue up while the UI is occupied, then stop from
        // another queue before the pending UI work has a chance to run.
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { video.stop(); stopped.signal() }
        if stopped.wait(timeout: .now() + 3) != .success { print("FAIL: stop timed out"); exit(1) }
    } else if status == "Video stopped." {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard queue.sync(execute: { sent }) else { print("FAIL: fixture was not sent"); exit(1) }
            listener.cancel()
            print("PASS: Stop suppresses an old frame queued behind a busy UI")
            exit(0)
        }
    }
}
listener.stateUpdateHandler = { state in
    if case .ready = state { DispatchQueue.main.async { video.start(host: "127.0.0.1", modern: false) } }
    if case .failed(let error) = state { print("FAIL: listener: \(error)"); exit(1) }
}
listener.start(queue: queue)
DispatchQueue.global().asyncAfter(deadline: .now() + 8) { print("FAIL: callback test timed out"); exit(1) }
dispatchMain()
