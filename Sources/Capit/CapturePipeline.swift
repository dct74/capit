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
        uniqueDestination(desktopDir.appendingPathComponent(fileName(date)))
    }

    /// Picks a destination nobody has claimed *and* that does not already exist on disk.
    ///
    /// Checking the filesystem matters: the name is second-granular, so a capture taken in the same
    /// second as one from an earlier run would otherwise reuse the name — and landing replaces the
    /// existing file, silently destroying it.
    static func uniqueDestination(_ url: URL) -> URL {
        let picked = firstFree(from: url) {
            usedFinalURLs.contains($0.path) || FileManager.default.fileExists(atPath: $0.path)
        }
        usedFinalURLs.insert(picked.path)
        return picked
    }

    /// Filesystem only — the late check made right before a file is moved into place.
    static func uniqueOnDisk(_ url: URL) -> URL {
        firstFree(from: url) { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// `capit-…-120406.png` → `capit-…-120406-2.png`. The suffix is appended to the whole stem so a
    /// timestamp in the name is never mistaken for a counter.
    private static func firstFree(from url: URL, isTaken: (URL) -> Bool) -> URL {
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var candidate = url
        var n = 2
        while isTaken(candidate) {
            candidate = folder.appendingPathComponent("\(stem)-\(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    private static var usedFinalURLs: Set<String> = []

    /// Marker written into every PNG Capit exports, so re-importing our own output doesn't
    /// get rounded/shadowed a second time.
    static let processedMarker = "CapitProcessed"

    /// Encodes `image` as PNG at `url`, tagging it as already rounded+shadowed.
    ///
    /// `sourceProperties` are metadata dictionaries copied from a file being re-saved through the
    /// editor (EXIF, GPS, IPTC, …). Without them, annotating an imported photo silently stripped all
    /// of its metadata.
    ///
    /// The write itself goes to a sibling temp file and is then moved into place, so an interrupted
    /// write cannot leave a truncated PNG at the destination.
    @discardableResult
    static func write(image: CGImage, to url: URL,
                      sourceProperties: [CFString: Any] = [:]) throws -> Data {
        let png = try encodePNG(image, sourceProperties: sourceProperties)
        try writePNG(png, to: url)
        return png
    }

    /// Writes already-encoded PNG bytes atomically (sibling temp file, then replace).
    static func writePNG(_ png: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try png.write(to: temp, options: .atomic)
        try atomicReplace(temp, url)
    }

    /// The PNG bytes for `image`, tagged as already rounded+shadowed.
    ///
    /// Encoded in memory so a caller can use the same bytes twice: the file and the clipboard used to
    /// encode this image separately, which cost an extra full-size PNG encode (~128 ms at 4K) on
    /// every capture and save.
    static func encodePNG(_ image: CGImage,
                          sourceProperties: [CFString: Any] = [:]) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString,
                                                         1, nil) else {
            throw CaptureError.imageWriteFailed
        }
        var props = sourceProperties
        // Merge rather than overwrite the PNG dictionary, so the marker sits alongside anything else.
        var pngDict = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
        pngDict[kCGImagePropertyPNGDescription] = processedMarker
        props[kCGImagePropertyPNGDictionary] = pngDict
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw CaptureError.imageWriteFailed
        }
        return data as Data
    }

    /// Moves a finished temp file onto the destination without ever leaving a half-written file.
    static func atomicReplace(_ temp: URL, _ destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: destination)
        }
    }

    /// Metadata worth carrying from a file being re-saved: the general dictionaries, minus anything
    /// that describes the old container or an orientation the pixels no longer need.
    static func metadata(from url: URL,
                         forOutputType type: CFString = UTType.png.identifier as CFString) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return [:]
        }
        let outputIsPNG = type == (UTType.png.identifier as CFString)
        var out: [CFString: Any] = [:]
        for (key, value) in props {
            if key == kCGImagePropertyOrientation { continue }
            if outputIsPNG,
               key == kCGImagePropertyJFIFDictionary || key == kCGImagePropertyHEICSDictionary
               || key == kCGImagePropertyPNGDictionary {
                continue                       // container-specific to the source
            }
            out[key] = value
        }
        return out
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
    /// Puts already-encoded PNG bytes on the pasteboard.
    ///
    /// PNG only, deliberately: the previous version also encoded an uncompressed TIFF, which sat on
    /// the pasteboard (47 MB at 4K, 80 MB at 5K) until the next copy and cost another encode. Every
    /// macOS app that accepts a pasted image accepts PNG.
    static func copy(png: Data, into pasteboard: NSPasteboard = .general) {
        guard isEnabled else { return }
        // NSPasteboard is main-thread only; this states that to the compiler.
        nonisolated(unsafe) let board = pasteboard
        Task { @MainActor in
            board.clearContents()
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            board.writeObjects([item])
        }
    }

    /// Convenience for callers that only have an image: encodes once and hands the bytes over.
    static func copy(_ image: CGImage, into pasteboard: NSPasteboard = .general) {
        guard isEnabled else { return }
        nonisolated(unsafe) let board = pasteboard
        Task.detached(priority: .utility) {
            guard let png = try? CapturePipeline.encodePNG(image) else { return }
            copy(png: png, into: board)
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
