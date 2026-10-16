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

    /// Encodes `image` as PNG at `url`, tagging it as already rounded+shadowed.
    static func write(image: CGImage, to url: URL) throws {
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

    /// Lands a fully-rendered pending PNG at its final destination. This is a file move, not a
    /// re-encode: the pixels (and the processed marker) are already final on disk.
    static func landPending(from tmpURL: URL, to finalURL: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: finalURL)
        do {
            try fm.moveItem(at: tmpURL, to: finalURL)
        } catch {
            // e.g. across volumes: fall back to a copy, then drop the pending file.
            try fm.copyItem(at: tmpURL, to: finalURL)
            try? fm.removeItem(at: tmpURL)
        }
    }
}

/// Puts captures on the general pasteboard.
///
/// Two call sites, which together give the documented behaviour: right after a capture, so the
/// un-annotated screenshot is on the clipboard even if the preview is never opened; and when an
/// annotated image is saved, so the clipboard ends up holding what the user actually made.
enum CaptureClipboard {

    private static let defaultsKey = "CapitCopyToClipboard"

    /// Whether captures go on the pasteboard at all. On by default — the whole point is that the
    /// clipboard is already correct without the user having to think about it — and the menu
    /// checkbox only exists to turn it off.
    ///
    /// Note the `object(forKey:)`: `bool(forKey:)` reports false for a key that has never been
    /// written, which would make a default-on preference impossible to express.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Copies `image` as PNG and TIFF — between them the two flavours apps actually ask for.
    ///
    /// The encodes run off the main thread (a 4K PNG is ~100 ms, which would be a visible hitch
    /// on capture) and only the pasteboard write hops back, because NSPasteboard is main-thread
    /// only. Encoding runs off-main rather than using NSBitmapImageRep, so nothing here needs
    /// AppKit off the main thread. `pasteboard` is injectable so tests can use a private one
    /// instead of clobbering the user's clipboard.
    static func copy(_ image: CGImage, into pasteboard: NSPasteboard = .general) {
        guard isEnabled else { return }
        // NSPasteboard is main-thread only, so it is never touched outside `MainActor.run` below;
        // this states that to the compiler rather than leaving a Sendable warning in the build.
        nonisolated(unsafe) let board = pasteboard
        Task.detached(priority: .utility) {
            func encode(_ type: CFString) -> Data? {
                let data = NSMutableData()
                guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
                CGImageDestinationAddImage(dest, image, nil)
                guard CGImageDestinationFinalize(dest) else { return nil }
                return data as Data
            }
            let png = encode(UTType.png.identifier as CFString)
            let tiff = encode(UTType.tiff.identifier as CFString)
            guard png != nil || tiff != nil else { return }
            await MainActor.run {
                let pb = board
                pb.clearContents()
                let item = NSPasteboardItem()
                if let png { item.setData(png, forType: .png) }
                if let tiff { item.setData(tiff, forType: .tiff) }
                pb.writeObjects([item])
            }
        }
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
