import Foundation

// One pending JPEG, one decoder job, one UI delivery. Producer floods cannot
// enqueue one closure per frame or retain an unbounded collection of images.
final class CameraFrameDelivery {
    private let lock = NSLock()
    private let queue = DispatchQueue(label:"local.a9.frame-delivery")
    private var generation = UUID()
    private var latest: Data?
    private var pending = false
    private var callback: ((CameraFrame) -> Void)?
    func start(_ callback: @escaping (CameraFrame) -> Void) {
        lock.lock(); generation = UUID(); latest = nil; pending = false; self.callback = callback; lock.unlock()
    }
    func stop() {
        lock.lock(); generation = UUID(); latest = nil; pending = false; callback = nil; lock.unlock()
    }
    func submit(_ jpeg: Data) {
        guard !jpeg.isEmpty, jpeg.count <= CameraWire.maxPayload else { return }
        lock.lock()
        guard callback != nil else { lock.unlock(); return }
        latest = jpeg
        let schedule = !pending; pending = true; let current = generation
        lock.unlock()
        if schedule { decodeLater(current) }
    }
    private func decodeLater(_ current: UUID) {
        queue.asyncAfter(deadline:.now() + .milliseconds(33)) {
            self.lock.lock()
            guard self.generation == current else { self.lock.unlock(); return }
            let data = self.latest; self.latest = nil; self.lock.unlock()
            let frame = data.flatMap(CameraFrame.decode)
            DispatchQueue.main.async {
                self.lock.lock()
                let cb = self.generation == current ? self.callback : nil
                self.lock.unlock()
                if let frame = frame { cb?(frame) }
                self.lock.lock()
                guard self.generation == current else { self.lock.unlock(); return }
                let again = self.latest != nil
                if !again { self.pending = false }
                self.lock.unlock()
                if again { self.decodeLater(current) }
            }
        }
    }
}
