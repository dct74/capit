import Cocoa
import ScreenCaptureKit

/// Auto-quits the app after `interval` with no screenshot activity (any new capture or the
/// annotation editor being opened resets the countdown). Only used on the main thread.
///
/// This is opt-in: the user enables it from the menu, and the choice is persisted. By default
/// the app never auto-quits on idle.
final class IdleAutoQuit {
    static let shared = IdleAutoQuit()
    private init() {}

    static let interval: TimeInterval = 10 * 60
    private static let defaultsKey = "CapitAutoQuitOnIdle"

    /// User preference: whether to auto-quit after the idle interval. Defaults to false.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            shared.refresh()
        }
    }

    /// Effective interval — overridable for testing via CAPIT_IDLE_SECONDS.
    static var effectiveInterval: TimeInterval {
        if let s = ProcessInfo.processInfo.environment["CAPIT_IDLE_SECONDS"],
           let v = Double(s), v > 0 {
            return v
        }
        return interval
    }
    private var timer: Timer?
    private var paused = false

    /// (Re)applies the user preference and pause state. Call once at launch.
    func refresh() {
        timer?.invalidate()
        timer = nil
        guard Self.isEnabled, !paused else { return }
        reset()
    }

    /// Pauses the countdown (used while the annotation editor is open).
    func pause() {
        paused = true
        refresh()
    }

    /// Resumes after a pause, respecting the user preference.
    func resume() {
        paused = false
        refresh()
    }

    /// Restarts the countdown (called on any screenshot activity).
    func reset() {
        guard Self.isEnabled, !paused else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.effectiveInterval,
                                     repeats: false) { _ in
            NSApp.terminate(nil)
        }
    }
}

/// Lets a pending capture's background work know the user opened the editor, so the product copy it
/// was about to write is not left behind as an orphan temp file.
private final class PendingCapture {
    private let lock = NSLock()
    private var done = false
    private var productFinished = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return done
    }
    func cancel() {
        lock.lock(); done = true; lock.unlock()
    }
    /// Marks the decorating write as finished (successfully or not), so landing knows it may look at
    /// the temp file instead of racing the writer.
    func markProductFinished() {
        lock.lock(); productFinished = true; lock.unlock()
    }
    /// Waits for the decorating write, bounded: landing must not block forever on a writer that died.
    func waitForProduct(deadline: Date) async {
        while !productFinished {
            guard Date() < deadline else { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// Top-level orchestrator for the three capture modes.
@MainActor
final class CaptureController {

    static let shared = CaptureController()
    private init() {}

    private var busy = false
    /// The `screencapture -i` process while a selection is on screen, so quitting can end it.
    private var interactiveProcess: Process?

    // MARK: - Entry points (menu)

    func captureFullScreen() {
        beginCapture { [self] in await performFullScreenCapture() }
    }

    func startInteractive() {
        beginCapture { [self] in await performInteractiveCapture() }
    }

    /// Returns true if Screen Recording is granted; otherwise shows guidance and returns false.
    private func ensurePermission() -> Bool {
        if CaptureKit.isAuthorized { return true }
        presentPermissionGuidance()
        return false
    }

    private func beginCapture(_ body: @escaping () async -> Void) {
        IdleAutoQuit.shared.reset()   // a screenshot counts as activity
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            await body()
            busy = false
        }
    }

    // MARK: - Full screen

    private func performFullScreenCapture() async {
        guard ensurePermission() else { return }
        do {
            let content = try await CaptureKit.shareableContent()
            let display = try activeDisplay(from: content)
            let image = try await CaptureKit.capture(display: display)
            playSystemScreenshotSound()
            let target = activeScreen() ?? NSScreen.main
            guard let target else { return }
            await presentPending(image, screen: target,
                                 finalURL: CapturePipeline.desktopURL(),
                                 needsFinishing: true, radiusRatio: 0.027)
        } catch {
            presentError(error)
        }
    }

    // MARK: - Interactive (region / window)

    /// Region / window selection is delegated to the system's own interactive capture UI
    /// (`screencapture -i`), which — unlike a custom overlay — does NOT activate this app and
    /// therefore doesn't close the frontmost app's menus / popovers. `-x` suppresses its own
    /// shutter sound (we play ours).
    private func performInteractiveCapture() async {
        guard ensurePermission() else { return }
        do {
            guard let screen = activeScreen() else { throw CaptureError.noDisplay }
            let shotURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("capit_shot_\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: shotURL) }

            try await runSystemInteractiveSelection(to: shotURL)

            guard let ns = NSImage(contentsOf: shotURL),
                  let image = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw CaptureError.imageCreationFailed
            }
            playSystemScreenshotSound()
            // A native window capture already carries corners and shadow; it is left alone and the
            // flag tells the editor not to decorate it again on save.
            let decorated = await Task.detached(priority: .userInitiated) {
                ImageProcessor.alreadyRoundedOrShadowed(image)
            }.value
            await presentPending(image, screen: screen, finalURL: CapturePipeline.desktopURL(),
                                 needsFinishing: !decorated)
        } catch {
            if case CaptureError.cancelled = error { return }
            presentError(error)
        }
    }

    /// Runs `/usr/sbin/screencapture -i -x <url>` asynchronously; throws `.cancelled` if the
    /// user aborted (no output file).
    private func runSystemInteractiveSelection(to url: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            proc.arguments = ["-i", "-x", url.path]
            proc.terminationHandler = { [weak self] p in
                // The handler runs on a non-main thread; the property is main-actor isolated.
                Task { @MainActor in self?.interactiveProcess = nil }
                // A cancelled selection leaves no file and exits non-zero — that is the normal way
                // out. Anything else that keeps us from reading the file is a real failure and must
                // not be reported as "the user cancelled", which the caller swallows silently.
                let size: Int
                do {
                    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                    size = (attrs[.size] as? NSNumber)?.intValue ?? 0
                } catch {
                    cont.resume(throwing: p.terminationStatus == 0 ? error : CaptureError.cancelled)
                    return
                }
                if p.terminationStatus == 0 && size > 0 {
                    cont.resume()
                } else if size > 0 {
                    // It wrote something but failed: a full disk or an unwritable temp dir. Reporting
                    // this as "cancelled" is what made the failure silent.
                    cont.resume(throwing: CaptureError.imageWriteFailed)
                } else {
                    cont.resume(throwing: CaptureError.cancelled)
                }
            }
            interactiveProcess = proc
            do {
                try proc.run()
            } catch {
                interactiveProcess = nil
                cont.resume(throwing: error)
            }
        }
    }

    /// Terminates a selection that is still on screen. Called when the app is about to quit: the
    /// child would otherwise outlive us and leave its crosshair over the desktop.
    func cancelInteractiveCapture() {
        interactiveProcess?.terminate()   // the termination handler resumes the continuation
        interactiveProcess = nil
    }

    /// Opens the annotation editor on a user-imported image (jpg/png). Images that are
    /// already rounded+shadowed — Capit's own PNGs (marker) or a native window screenshot
    /// (geometric heuristic) — are opened as-is; everything else gets the treatment.
    func openImportedImage(_ image: CGImage, sourceURL: URL?) {
        IdleAutoQuit.shared.reset()
        // Marker check is a cheap file read; the geometric heuristic (which downscales the
        // image) runs off the main thread.
        let tagged = sourceURL.map { CapturePipeline.isCapitProcessed(url: $0) } ?? false
        Task { @MainActor in
            let alreadyProcessed: Bool
            if tagged {
                alreadyProcessed = true
            } else {
                alreadyProcessed = await Task.detached(priority: .userInitiated) {
                    ImageProcessor.alreadyRoundedOrShadowed(image)
                }.value
            }
            // The heuristic above can take a while on a large image; an editor may have opened in the
            // meantime, and `present()` would replace the only strong reference to it.
            if let existing = AnnotationHolder.shared.active {
                existing.bringToFront()
                return
            }
            // Decoration is deferred to save, like a capture; only an image that already has it
            // is flagged so it is not decorated twice.
            if let editor = AnnotationEditorController(image: image, fileURL: sourceURL,
                                                       isImported: true,
                                                       needsFinishing: !alreadyProcessed) {
                editor.present()
            }
        }
    }

    // MARK: - Display / screen selection helpers

    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    }

    private func activeDisplay(from content: SCShareableContent) throws -> SCDisplay {
        guard let display = pickDisplay(screen: activeScreen(), content: content) else {
            throw CaptureError.noDisplay
        }
        return display
    }

    private func pickDisplay(screen: NSScreen?, content: SCShareableContent) -> SCDisplay? {
        let target = screen?.displayID ?? 0
        return content.displays.first(where: { $0.displayID == target }) ?? content.displays.first
    }

    // MARK: - UI feedback

    private func pendingTempURL() -> URL {
        CapturePipeline.tempDir
            .appendingPathComponent("capit-pending-\(UUID().uuidString).png")
    }

    private func presentPending(_ image: CGImage, screen: NSScreen, finalURL: URL,
                               needsFinishing: Bool = true,
                               radiusRatio: CGFloat = ImageProcessor.cornerRadiusRatio) async {
        // The product — corners and shadow applied — is made once, now, and serves both the
        // clipboard and the file. That keeps the clipboard correct the moment the screenshot is
        // taken instead of several seconds later when the preview expires, and it means landing the
        // file is a move rather than another decode/decorate/encode.
        //
        // The editor works on the raw picture (annotations must not be drawn into the shadow's
        // transparent padding). It gets the in-memory image rather than a temp file, which avoids
        // encoding a full-size PNG on the main thread just before showing the preview.
        let productURL = pendingTempURL()
        let pending = PendingCapture()
        // Downscaling a 5K capture is tens of milliseconds of sampling; it must not hold up the main
        // thread at the exact moment the screenshot lands.
        let thumb = await Task.detached(priority: .userInitiated) {
            ImageProcessor.thumbnail(from: image)
        }.value ?? image

        /// Puts the capture on the desktop: waits for the decorating write rather than racing it,
        /// decorates the raw capture itself only if that write produced nothing, then moves the
        /// result to a name that is still free.
        func land() {
            CaptureWriter.schedule { [weak self] in
                defer { try? FileManager.default.removeItem(at: productURL) }   // no leftovers on failure
                await pending.waitForProduct(deadline: Date().addingTimeInterval(6))
                do {
                    if !FileManager.default.fileExists(atPath: productURL.path) {
                        let product = needsFinishing
                            ? (ImageProcessor.finished(image, radiusRatio: radiusRatio) ?? image) : image
                        try CapturePipeline.write(image: product, to: productURL)
                    }
                    // The destination was made unique at capture time, but a file could have
                    // appeared since; never replace one blindly.
                    let destination = CapturePipeline.uniqueOnDisk(finalURL)
                    try CapturePipeline.atomicReplace(productURL, destination)
                    // The clipboard already holds this image from capture time; rewriting it here
                    // would silently clobber whatever the user copied in the meantime.
                    // File name only: the full path carries the account name and is readable from the
                    // unified log by any process.
                    NSLog("[Capit] 已保存到桌面: \(destination.lastPathComponent)")
                } catch {
                    await MainActor.run { self?.presentError(error) }
                }
            }
        }

        PreviewPresenter.shared.present(image: thumb, screen: screen,
            onExpire: { land() },
            onOpen: { [weak self] in
                if let existing = AnnotationHolder.shared.active {
                    // Never open a second editor: `present()` replaces the only strong reference to
                    // the first, whose window would then outlive its delegate and skip
                    // `windowWillClose`. Land this capture like an expired preview instead.
                    existing.bringToFront()
                    land()
                    return
                }
                // The editor works from the raw capture; the product this capture was preparing is
                // no longer needed, and its writer is told to stand down.
                pending.cancel()
                try? FileManager.default.removeItem(at: productURL)
                self?.openAnnotationWindow(image, fileURL: finalURL,
                                           needsFinishing: needsFinishing,
                                           radiusRatio: radiusRatio)
            })

        // Decorate and copy off the main thread, so the preview above is not held up by it.
        CaptureWriter.schedule {
            defer { pending.markProductFinished() }
            guard !pending.isCancelled else { return }
            let product = needsFinishing ? (ImageProcessor.finished(image, radiusRatio: radiusRatio) ?? image) : image
            // One PNG encode serves the clipboard and the file (two encodes used to run here).
            let png = try? CapturePipeline.encodePNG(product)
            if let png { CaptureClipboard.copy(png: png) }
            guard !pending.isCancelled else { return }   // opened while decorating
            do {
                if let png { try CapturePipeline.writePNG(png, to: productURL) }
                else { try CapturePipeline.write(image: product, to: productURL) }
                // The editor can open while this write is in flight; it deleted the path already, so
                // finish by removing what we just produced rather than leaving an orphan temp file.
                if pending.isCancelled { try? FileManager.default.removeItem(at: productURL) }
            } catch {
                await MainActor.run { self.presentError(error) }
            }
        }
    }

    /// Opens the editor on the capture the preview is showing.
    private func openAnnotationWindow(_ image: CGImage, fileURL: URL,
                                      needsFinishing: Bool, radiusRatio: CGFloat) {
        guard let editor = AnnotationEditorController(image: image, fileURL: fileURL,
                                                      needsFinishing: needsFinishing,
                                                      radiusRatio: radiusRatio) else { return }
        editor.present()
    }

    private func playSystemScreenshotSound() {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        if let s = NSSound(contentsOfFile: path, byReference: true) {
            s.play()
        } else {
            NSSound.beep()
        }
    }

    private func presentError(_ error: Error) {
        if case CaptureError.cancelled = error { return }
        presentAlert("Capit", error.localizedDescription)
    }

    private func presentPermissionGuidance() {
        let response = presentAlert("需要屏幕录制权限",
                     "Capit 需要「屏幕录制」权限才能截图。\n\n"
                     + "请前往：系统设置 → 隐私与安全性 → 屏幕录制，勾选 Capit。\n"
                     + "如果列表中没有 Capit，点击右下角 + 手动添加。\n\n"
                     + "开启后请完全退出并重新打开 Capit 才会生效。",
                     buttons: ["打开系统设置", "好"])
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
