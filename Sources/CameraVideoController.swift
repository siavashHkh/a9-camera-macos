import Foundation

// Fall back only before a frame and only for protocol/stream failures.
// Authentication and unsupported-codec errors remain visible to the user.
final class CameraVideoController {
    enum Mode: String { case automatic, classic, newer }
    var onStatus: ((String) -> Void)?
    var onFrame: ((CameraFrame) -> Void)?
    var onStopped: (() -> Void)?
    var onState: ((CameraVideoState) -> Void)?
    private var client: CameraVideo?
    private var generation = UUID()
    private var attempt = UUID()
    private var host = ""
    private var protocols: [Bool] = []
    private var receivedFrame = false
    private var failure: CameraFailure?

    func start(host: String, mode: Mode) {
        client?.stop(); generation = UUID()
        self.host = host
        protocols = mode == .automatic ? [false, true] : [mode == .newer]
        beginAttempt()
    }
    func stop() {
        generation = UUID(); attempt = UUID(); protocols = []
        client?.stop(); client = nil
        onStatus?("Video stopped."); onState?(.stopped)
    }
    private func beginAttempt() {
        guard !protocols.isEmpty else { return }
        let modern = protocols.removeFirst()
        let current = generation; let trial = UUID(); attempt = trial
        receivedFrame = false; failure = nil
        let video = CameraVideo(); client = video
        video.onStatus = { [weak self] text in
            guard let self = self, self.generation == current, self.attempt == trial else { return }
            self.onStatus?(text)
        }
        video.onFrame = { [weak self] frame in
            guard let self = self, self.generation == current, self.attempt == trial else { return }
            self.receivedFrame = true; self.onFrame?(frame)
        }
        video.onState = { [weak self] state in
            guard let self = self, self.generation == current, self.attempt == trial else { return }
            if case .failed = state { return }; self.onState?(state)
        }
        video.onFailure = { [weak self] failure in
            guard let self = self, self.generation == current, self.attempt == trial else { return }
            self.failure = failure
        }
        video.onStopped = { [weak self, weak video] in
            guard let self = self, self.generation == current, self.attempt == trial else { return }
            let retry = self.failure?.canTryAnotherProtocol == true
            if !self.receivedFrame, !self.protocols.isEmpty, retry {
                video?.stop()
                self.onStatus?("Classic protocol did not return video. Trying newer V720 firmware…")
                self.beginAttempt()
            } else { self.onState?(.failed(self.failure ?? .network)); self.onStopped?() }
        }
        video.start(host: host, modern: modern)
    }
}
