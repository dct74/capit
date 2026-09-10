import Cocoa
import CoreGraphics

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

    /// Encodes `image` as PNG at `url`.
    static func write(image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CaptureError.imageCreationFailed
        }
        try data.write(to: url)
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
