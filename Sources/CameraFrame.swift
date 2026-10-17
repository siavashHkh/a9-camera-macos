import Foundation
import ImageIO
import CoreGraphics

struct CameraFrame {
    let jpeg: Data
    let image: CGImage
    static let maxDimension = 4096
    static let maxPixels = 4096 * 2160

    // Inspect dimensions without caching decoded pixels, then decode on the
    // video queue. Compressed byte limits alone do not bound image allocation.
    static func decode(_ data: Data) -> CameraFrame? {
        guard !data.isEmpty, data.count <= CameraWire.maxPayload,
              let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0,
                [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              width <= maxDimension, height <= maxDimension,
              width <= maxPixels / height,
              (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue == 8,
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true,
                 kCGImageSourceShouldAllowFloat: false] as CFDictionary),
              image.width == width, image.height == height else { return nil }
        return CameraFrame(jpeg: data, image: image)
    }
}

// Network state lives on the video queue. This small gate also lets Stop
// invalidate UI work synchronously, before previously queued callbacks run.
final class CameraCallbackGate {
    private let lock = NSLock()
    private var generation = UUID()
    func advance() -> UUID {
        lock.lock(); defer { lock.unlock() }
        generation = UUID()
        return generation
    }
    func isCurrent(_ value: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == value
    }
    func current() -> UUID {
        lock.lock(); defer { lock.unlock() }
        return generation
    }
}
