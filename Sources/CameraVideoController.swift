import Foundation

// Fall back only before a frame and only for protocol/stream failures.
// Authentication and unsupported-codec errors remain visible to the user.
final class CameraVideoController {
    enum Mode: String { case automatic, classic, newer }
    var onStatus: ((String) -> Void)?
    var onFrame: ((CameraFrame) -> Void)?
    var onStopped: (() -> Void)?
    private var client: CameraVideo?
    private var generation = UUID()
    private var attempt = UUID()
    private var host = ""
    private var protocols: [Bool] = []
    private var receivedFrame = false
    private var lastStatus = ""

    func start(host: String, mode: Mode) {
        client?.stop(); generation = UUID()
        self.host = host
        protocols = mode == .automatic ? [false, true] : [mode == .newer]
        beginAttempt()
    }
    func stop() {
        generation = UUID(); attempt = UUID(); protocols = []
        client?.stop(); client = nil
        onStatus?("Video stopped.")
    }
    private func beginAttempt() {
        guard !protocols.isEmpty else { return }
        let modern = protocols.removeFirst()
        let current = generation; let trial = UUID(); attempt = trial
        receivedFrame = false; lastStatus = ""
        let video = CameraVideo(); client = video
        video.onStatus = { [weak self] text in
            guard let self = self, self.generation == current, self.attempt == trial else { return }
            self.lastStatus = text
            self.onStatus?(text)
        }
        video.onFrame = { [weak self] frame in
            guard let self = self, self.generation == current, self.attempt == trial else { return }
            self.receivedFrame = true; self.onFrame?(frame)
        }
        video.onStopped = { [weak self, weak video] in
            guard let self = self, self.generation == current, self.attempt == trial else { return }
            let retry = self.lastStatus.hasPrefix("Camera closed the video connection") || self.lastStatus.hasPrefix("No video received") || self.lastStatus.hasPrefix("Unrecognized camera data")
            if !self.receivedFrame, !self.protocols.isEmpty, retry {
                video?.stop()
                self.onStatus?("Classic protocol did not return video. Trying newer V720 firmware…")
                self.beginAttempt()
            } else { self.onStopped?() }
        }
        video.start(host: host, modern: modern)
    }
}
