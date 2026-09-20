import Cocoa
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Persists captured images. Holds desktop/temp path helpers and tracks off-main writes so
/// the app can wait for the last one before quitting.
enum CapturePipeline {

    static let desktopDir = FileManager.default.urls(for: .desktopDirectory,
                                                     in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser

    /// Transient cache dir for the screenshot while its thumbnail preview is showing.
    static let tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapitPending", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// The base file name for a capture.
    static func fileName(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "capit-\(f.string(from: date)).png"
    }

    /// The eventual on-disk destination on the Desktop. If another pending capture in this
    /// run already claimed the same second-granularity name, a numeric suffix is appended.
    static func desktopURL(date: Date = Date()) -> URL {
        let stem = fileName(date)
        var candidate = desktopDir.appendingPathComponent(stem)
        var n = 2
        while !usedFinalURLs.insert(candidate.path).inserted {
            candidate = desktopDir.appendingPathComponent("\(stem)-\(n)")
            n += 1
        }
        return candidate
    }
    private static var usedFinalURLs: Set<String> = []

    /// Writes a pending (preview) copy into the temp cache dir.
    @discardableResult
    static func saveTemp(image: CGImage, url: URL) throws -> URL {
        try write(image: image, to: url)
        return url
    }

    /// Marker written into every PNG Capit exports, so re-importing our own output doesn't
    /// get rounded/shadowed a second time.
    static let processedMarker = "CapitProcessed"

    /// Encodes `image` as PNG (default; tagged as already rounded+shadowed) or JPEG when the
    /// destination extension is .jpg/.jpeg. JPEG has no alpha, so it is flattened over white.
    static func write(image: CGImage, to url: URL) throws {
        let ext = url.pathExtension.lowercased()
        if ext == "jpg" || ext == "jpeg" {
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw CaptureError.imageWriteFailed
            }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let flat = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                             UTType.jpeg.identifier as CFString,
                                                             1, nil) else {
                throw CaptureError.imageWriteFailed
            }
            let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
            CGImageDestinationAddImage(dest, flat, opts as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw CaptureError.imageWriteFailed }
            return
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.png.identifier as CFString,
                                                         1, nil) else {
            throw CaptureError.imageWriteFailed
        }
        let props: [CFString: Any] = [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: processedMarker]
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw CaptureError.imageWriteFailed
        }
    }

    /// True if the PNG at `url` was written by Capit (carries the processed marker).
    static func isCapitProcessed(url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any],
              let desc = png[kCGImagePropertyPNGDescription] as? String else { return false }
        return desc == processedMarker
    }
}

/// Tracks the app's off-main PNG writes so the app can wait for the last in-flight write
/// to finish before it terminates — so a capture that is just landing isn't dropped on quit.
enum CaptureWriter {
    private struct Entry {
        let id: UUID
        let task: Task<Void, Never>
    }
    private static let lock = NSLock()
    private static var entries: [Entry] = []

    /// Runs `body` off the main thread and remembers it for `waitForPending()`.
    static func schedule(_ body: @escaping () async -> Void) {
        let t = Task.detached(priority: .utility) { await body() }
        let e = Entry(id: UUID(), task: t)
        lock.lock(); entries.append(e); lock.unlock()
        Task { await t.value; remove(e.id) }
    }

    private static func remove(_ id: UUID) {
        lock.lock(); entries.removeAll { $0.id == id }; lock.unlock()
    }

    private static func snapshot() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    /// Awaits every write that is in flight (and any started meanwhile) — used before quitting.
    /// Bounded by `timeout` so a stuck write can't hang the quit indefinitely.
    static func waitForPending(timeout: TimeInterval = 8) async {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let list = snapshot()
            if list.isEmpty { return }
            for e in list {
                if Date() >= deadline { return }
                await e.task.value
            }
            for e in list { remove(e.id) }
        }
    }
}
