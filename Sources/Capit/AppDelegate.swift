import Cocoa
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    #if DEBUG
    private var selftestController: InteractiveCaptureController?
    #endif
    private let hotKeys = GlobalHotKeyManager()

    // Carbon hot-key IDs (arbitrary) + virtual key codes.
    private let fullID9: UInt32 = 1, regionID0: UInt32 = 2
    private let fullID3: UInt32 = 3, regionID4: UInt32 = 4

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        registerGlobalHotKeys()
        IdleAutoQuit.shared.start()
#if DEBUG
        runSelfTestIfRequested()
        runRealPathSelfTestIfRequested()
        runSampleRenderIfRequested()
#endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys.unregister(id: fullID9)
        hotKeys.unregister(id: regionID0)
        hotKeys.unregister(id: fullID3)
        hotKeys.unregister(id: regionID4)
    }

    /// Lets any in-flight capture write finish before the app quits, so a just-landed
    /// capture isn't dropped when the user exits right after a screenshot.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        PreviewPresenter.shared.active?.finalizePending()
        AnnotationHolder.shared.active?.ensureCapturedBeforeQuit()
        Task {
            await CaptureWriter.waitForPending()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// ⇧⌘9 / ⇧⌘3 = full screen; ⇧⌘0 / ⇧⌘4 = region/window.
    private func registerGlobalHotKeys() {
        hotKeys.onPress = { [weak self] id in
            Task { @MainActor in
                guard let self else { return }
                switch id {
                case self.fullID9, self.fullID3: CaptureController.shared.captureFullScreen()
                case self.regionID0, self.regionID4: CaptureController.shared.startInteractive()
                default: break
                }
            }
        }
        let cmdShift = UInt32(cmdKey) | UInt32(shiftKey)
        _ = hotKeys.register(id: fullID9, keyCode: 25, modifiers: cmdShift)    // '9'
        _ = hotKeys.register(id: regionID0, keyCode: 29, modifiers: cmdShift)  // '0'
        _ = hotKeys.register(id: fullID3, keyCode: 20, modifiers: cmdShift)    // '3'
        _ = hotKeys.register(id: regionID4, keyCode: 21, modifiers: cmdShift)  // '4'
    }

#if DEBUG
    private func runSampleRenderIfRequested() {
        let enabled = ProcessInfo.processInfo.environment["CAPIT_SAMPLE"] == "1"
            || CommandLine.arguments.contains("-sample")
        guard enabled else { return }
        let w = 400, h = 300
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(NSColor.red.cgColor); ctx.fill(CGRect(x: 0, y: h/2, width: w/2, height: h/2))
        ctx.setFillColor(NSColor.green.cgColor); ctx.fill(CGRect(x: w/2, y: h/2, width: w/2, height: h/2))
        ctx.setFillColor(NSColor.blue.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w/2, height: h/2))
        ctx.setFillColor(NSColor.yellow.cgColor); ctx.fill(CGRect(x: w/2, y: 0, width: w/2, height: h/2))
        let source = ctx.makeImage()!

        let rounded = ImageProcessor.applyingRoundedCorners(to: source)
        if let rounded { saveSample(rounded, path: "/tmp/capit_sample_round.png") }
        let shadowed = ImageProcessor.windowWithShadow(content: source)
        if let shadowed { saveSample(shadowed, path: "/tmp/capit_sample_window.png") }

        // Shape-only squircle map (fill the path opaque on transparent) to debug geometry.
        if let sctx = CGContext(data: nil, width: w, height: h,
                                bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            let rect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
            let sp = SquirclePath.cgPath(in: rect, radius: 80, exponent: 4)
            sctx.setFillColor(NSColor.white.cgColor)
            sctx.addPath(sp)
            sctx.fillPath()
            if let s = sctx.makeImage() { saveSample(s, path: "/tmp/capit_sample_shape.png") }
        }

        // Orientation probe: fill a rect near (0,0) of a rep and save, to verify how
        // NSGraphicsContext(bitmapImageRep:) maps to PNG coordinates.
        let pw = 100, ph = 60
        if let pre = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0),
           let pgc = NSGraphicsContext(bitmapImageRep: pre) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = pgc
            NSColor.red.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 40, height: 30)).fill()
            pgc.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            if let im = pre.cgImage { saveSample(im, path: "/tmp/orient_probe.png") }
        }
        selftestLog("sample rendered to /tmp/capit_sample_{round,window,shape}.png")
    }

    private func saveSample(_ image: CGImage, path: String) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private func runRealPathSelfTestIfRequested() {
        let enabled = ProcessInfo.processInfo.environment["CAPIT_SELFTEST_REAL"] == "1"
            || CommandLine.arguments.contains("-selftest-real")
        guard enabled else { return }
        selftestLog("real-path: invoking CaptureController.startInteractive")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            CaptureController.shared.startInteractive()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            CaptureController.shared.cancelActiveOverlay()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
            self.selftestLog("real-path: app alive after cancel")
        }
    }

    private func runSelfTestIfRequested() {
        let enabled = ProcessInfo.processInfo.environment["CAPIT_SELFTEST"] == "1"
            || CommandLine.arguments.contains("-selftest")
        guard enabled, let screen = NSScreen.main else { return }

        let ctl = InteractiveCaptureController(screen: screen)
        selftestController = ctl
        ctl.onComplete = { result in
            self.selftestLog("onComplete \(result)")
        }
        ctl.run()
        selftestLog("overlay presented")

        for (i, delay) in [0.2, 0.5, 1.0, 1.5].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.selftestLog("poll\(i): active=\(NSApp.isActive) keyWindow=\(NSApp.keyWindow != nil) "
                    + "selfKey=\(ctl.windowRef?.isKeyWindow ?? false)")
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if let kw = NSApp.keyWindow,
               let ev = NSEvent.keyEvent(with: .keyDown,
                                         location: .zero,
                                         modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: kw.windowNumber,
                                         context: nil,
                                         characters: "\u{1B}",
                                         charactersIgnoringModifiers: "\u{1B}",
                                         isARepeat: false,
                                         keyCode: 53) {
                kw.sendEvent(ev)
            } else {
                ctl.cancel()
            }
        }
    }

    private func selftestLog(_ message: String) {
        NSLog("[Capit] selftest: %@", message)
    }
#endif

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder",
                                   accessibilityDescription: "Capit")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        let full = NSMenuItem(title: "全屏截图",
                              action: #selector(captureFullScreen),
                              keyEquivalent: "3")
        full.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(full)
        let region = NSMenuItem(title: "区域 / 窗口截图",
                                action: #selector(captureInteractive),
                                keyEquivalent: "4")
        region.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(region)
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Capit", action: #selector(quit), keyEquivalent: "q")

        item.menu = menu
        statusItem = item
    }

    // MARK: - Actions

    @objc private func captureFullScreen() {
        CaptureController.shared.captureFullScreen()
    }

    @objc private func captureInteractive() {
        CaptureController.shared.startInteractive()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
