import Cocoa
import ScreenCaptureKit

/// Auto-quits the app after `interval` with no screenshot activity (any new capture or the
/// annotation editor being opened resets the countdown). Only used on the main thread.
final class IdleAutoQuit {
    static let shared = IdleAutoQuit()
    private init() {}

    static let interval: TimeInterval = 10 * 60
    /// Effective interval — overridable for testing via CAPIT_IDLE_SECONDS.
    static var effectiveInterval: TimeInterval {
        if let s = ProcessInfo.processInfo.environment["CAPIT_IDLE_SECONDS"],
           let v = Double(s), v > 0 {
            return v
        }
        return interval
    }
    private var timer: Timer?
    private var enabled = false

    func start() {
        enabled = true
        reset()
    }

    func stop() {
        enabled = false
        timer?.invalidate()
        timer = nil
    }

    /// Restarts the countdown (called on any screenshot activity).
    func reset() {
        guard enabled else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.effectiveInterval,
                                     repeats: false) { _ in
            NSApp.terminate(nil)
        }
    }
}

/// Top-level orchestrator for the three capture modes.
@MainActor
final class CaptureController {

    static let shared = CaptureController()
    private init() {}

    private var busy = false

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

    private func postProcess(_ image: CGImage,
                             radiusRatio: CGFloat = ImageProcessor.cornerRadiusRatio) async -> CGImage {
        await Task.detached(priority: .userInitiated) { () -> CGImage in
            let rounded = ImageProcessor.applyingRoundedCorners(to: image, radiusRatio: radiusRatio) ?? image
            return ImageProcessor.windowWithShadow(content: rounded) ?? rounded
        }.value
    }

    private func performFullScreenCapture() async {
        guard ensurePermission() else { return }
        do {
            let content = try await CaptureKit.shareableContent()
            let display = try activeDisplay(from: content)
            let image = try await CaptureKit.capture(display: display)
            let processed = await postProcess(image, radiusRatio: 0.03)
            playSystemScreenshotSound()
            let tmp = pendingTempURL()
            try CapturePipeline.saveTemp(image: processed, url: tmp)
            let target = activeScreen() ?? NSScreen.main
            guard let target else { return }
            presentPending(processed, screen: target,
                           finalURL: CapturePipeline.desktopURL(), tmpURL: tmp)
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
            // A native window capture already has rounded corners (+ shadow) — don't redo it.
            let processed = ImageProcessor.alreadyRoundedOrShadowed(image)
                ? image : await postProcess(image)
            playSystemScreenshotSound()
            let tmp = pendingTempURL()
            try CapturePipeline.saveTemp(image: processed, url: tmp)
            presentPending(processed, screen: screen, finalURL: CapturePipeline.desktopURL(),
                           tmpURL: tmp)
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
            proc.terminationHandler = { p in
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                if p.terminationStatus == 0 && size > 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: CaptureError.cancelled)
                }
            }
            do {
                try proc.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
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
            let result = alreadyProcessed ? image : await postProcess(image)
            if let editor = AnnotationEditorController(image: result, fileURL: sourceURL, isImported: true) {
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
        let id = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let target = id?.uint32Value ?? 0
        return content.displays.first(where: { $0.displayID == target }) ?? content.displays.first
    }

    // MARK: - UI feedback

    private func pendingTempURL() -> URL {
        CapturePipeline.tempDir
            .appendingPathComponent("capit-pending-\(UUID().uuidString).png")
    }

    private func presentPending(_ image: CGImage, screen: NSScreen, finalURL: URL, tmpURL: URL) {
        PreviewPresenter.shared.present(image: image, fileURL: finalURL, screen: screen,
            onExpire: { [weak self] _, _ in
                let img = image
                let url = finalURL
                CaptureWriter.schedule {
                    do {
                        try CapturePipeline.write(image: img, to: url)
                        NSLog("[Capit] 已保存到桌面: \(url.path)")
                    } catch {
                        await MainActor.run { self?.presentError(error) }
                    }
                }
                try? FileManager.default.removeItem(at: tmpURL)
            },
            onOpen: { [weak self] img, url in
                self?.openAnnotationWindow(img, fileURL: url)
                try? FileManager.default.removeItem(at: tmpURL)
            })
    }

    private func openAnnotationWindow(_ image: CGImage, fileURL: URL?) {
        if let editor = AnnotationEditorController(image: image, fileURL: fileURL) {
            editor.present()
        }
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
        let alert = NSAlert()
        alert.messageText = "Capit"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func presentPermissionGuidance() {
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "Capit 需要「屏幕录制」权限才能截图。\n\n"
            + "请前往：系统设置 → 隐私与安全性 → 屏幕录制，勾选 Capit。\n"
            + "如果列表中没有 Capit，点击右下角 + 手动添加。\n\n"
            + "开启后请完全退出并重新打开 Capit 才会生效。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
