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

    /// Strong reference to the currently presented overlay so it is not deallocated
    /// mid-session (a weak ref here caused the overlay window to be torn down early).
    private var activeOverlay: InteractiveCaptureController?

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

    private func performInteractiveCapture() async {
        guard ensurePermission() else { return }
        do {
            let content = try await CaptureKit.shareableContent()
            guard let screen = activeScreen() else { throw CaptureError.noDisplay }

            let request = try await runOverlay(screen: screen, windows: content.windows)

            let image: CGImage
            switch request {
            case .region(let pixelRect):
                let display = try display(for: screen, in: content)
                try await Task.sleep(for: .milliseconds(150))
                let full = try await CaptureKit.capture(display: display)
                guard let cropped = full.cropping(to: pixelRect) else {
                    throw CaptureError.imageCreationFailed
                }
                image = cropped
            case .window(let id):
                if #available(macOS 14.0, *),
                   let scw = content.windows.first(where: { $0.windowID == id }),
                   let img = try? await CaptureKit.captureWindow(scWindow: scw,
                                                                 scale: windowScale(for: scw, in: content)) {
                    image = img
                } else {
                    image = try await CaptureKit.captureWindowNative(id: id)
                }
            }

            let processed = await postProcess(image)
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

    /// Opens the annotation editor on a user-imported image (jpg/png), after applying the
    /// same rounded-corner + soft-shadow treatment used for captures. Saved as PNG.
    func openImportedImage(_ image: CGImage) {
        IdleAutoQuit.shared.reset()
        Task { @MainActor in
            let processed = await postProcess(image)
            if let editor = AnnotationEditorController(image: processed, fileURL: nil) {
                editor.present()
            }
        }
    }

    // MARK: - Overlay

    func cancelActiveOverlay() {
        activeOverlay?.cancel()
    }

    private func runOverlay(screen: NSScreen,
                            windows: [SCWindow]) async throws -> CaptureRequest {
        try await withCheckedThrowingContinuation { continuation in
            let controller = InteractiveCaptureController(screen: screen, windows: windows)
            controller.onComplete = { [weak self] result in
                self?.activeOverlay = nil
                continuation.resume(with: result)
            }
            activeOverlay = controller
            controller.run()
        }
    }

    // MARK: - Display / screen selection helpers

    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    }

    private func display(for screen: NSScreen?, in content: SCShareableContent) throws -> SCDisplay {
        guard let display = pickDisplay(screen: screen, content: content) else {
            throw CaptureError.noDisplay
        }
        return display
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

    private func windowScale(for window: SCWindow, in content: SCShareableContent) -> CGFloat {
        let c = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let display = content.displays.first { $0.frame.contains(c) }
        guard let display else { return 2.0 }
        let scale = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }?.backingScaleFactor
        return scale ?? 2.0
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
