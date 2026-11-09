import Cocoa
import Carbon
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var autoQuitItem: NSMenuItem?
    private var copyToClipboardItem: NSMenuItem?
    private var hideMenuBarItem: NSMenuItem?
    /// The two capture items, kept so a hot key the system already owns can be dropped from the menu
    /// instead of being advertised as working.
    private var fullScreenItem: NSMenuItem?
    private var regionItem: NSMenuItem?
    #if DEBUG
    private var selftestController: InteractiveCaptureController?
    #endif
    private let hotKeys = GlobalHotKeyManager()

    // Carbon hot-key IDs (arbitrary) + virtual key codes.
    private let fullID9: UInt32 = 1, regionID0: UInt32 = 2
    private let fullID3: UInt32 = 3, regionID4: UInt32 = 4
    private let editorID: UInt32 = 5
    private let menuBarID: UInt32 = 6

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        registerGlobalHotKeys()
        IdleAutoQuit.shared.refresh()
#if DEBUG
        runSelfTestIfRequested()
        runRealPathSelfTestIfRequested()
        runSampleRenderIfRequested()
        runMenuBarSelfTestIfRequested()
#endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A selection still on screen must not outlive us: the child process would keep its
        // crosshair over the desktop.
        CaptureController.shared.cancelInteractiveCapture()
        hotKeys.unregister(id: fullID9)
        hotKeys.unregister(id: regionID0)
        hotKeys.unregister(id: fullID3)
        hotKeys.unregister(id: regionID4)
        hotKeys.unregister(id: editorID)
        hotKeys.unregister(id: menuBarID)
        hotKeys.removeHandler()
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
                case self.editorID: self.openEditor()
                case self.menuBarID: self.toggleMenuBarIcon()
                default: break
                }
            }
        }
        let cmdShift = UInt32(cmdKey) | UInt32(shiftKey)
        _ = hotKeys.register(id: fullID9, keyCode: 25, modifiers: cmdShift)    // '9'
        _ = hotKeys.register(id: regionID0, keyCode: 29, modifiers: cmdShift)  // '0'
        _ = hotKeys.register(id: editorID, keyCode: 14, modifiers: UInt32(cmdKey))  // ⌘E
        _ = hotKeys.register(id: menuBarID, keyCode: 46, modifiers: cmdShift)       // ⇧⌘M
        // ⇧⌘3 / ⇧⌘4 are macOS's own screenshot shortcuts, so these registrations often fail. The menu
        // must then stop showing them as if they worked; the ⇧⌘9 / ⇧⌘0 pair above does.
        let full3 = hotKeys.register(id: fullID3, keyCode: 20, modifiers: cmdShift)     // '3'
        let region4 = hotKeys.register(id: regionID4, keyCode: 21, modifiers: cmdShift) // '4'
        if !full3 { fullScreenItem?.keyEquivalent = ""; fullScreenItem?.keyEquivalentModifierMask = [] }
        if !region4 { regionItem?.keyEquivalent = ""; regionItem?.keyEquivalentModifierMask = [] }
    }

#if DEBUG
    /// Prints the menu bar glyph as ASCII, so "is the camera actually there?" can be answered from a
    /// script rather than by squinting at the bar.
    private static func dumpASCII(_ image: NSImage) {
        // Keep the glyph square: drawing 17x17 into a wide rect stretched it and made the preview
        // look far heavier than the menu bar does.
        let W = 18, H = 18
        var buf = [UInt8](repeating: 0, count: W * H * 4)
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8,
                                      bytesPerRow: W * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)))
            NSGraphicsContext.restoreGraphicsState()
        }
        print("[menubar] glyph ('#'=stroke, ' '=empty):")
        for y in 0..<H {
            var line = "    |"
            for x in 0..<W {
                let o = (y * W + x) * 4
                line += buf[o + 3] < 60 ? " " : "#"
            }
            print(line + "|")
        }
    }

    /// `CAPIT_MENUBAR_TEST=1`: prints the visible/persisted state around a toggle, so the behaviour
    /// can be checked from a script instead of by clicking.
    private func runMenuBarSelfTestIfRequested() {
        guard ProcessInfo.processInfo.environment["CAPIT_MENUBAR_TEST"] == "1" else { return }
        func report(_ step: String) {
            if let img = statusItem?.button?.image {
                print("[menubar] icon: \(Int(img.size.width))x\(Int(img.size.height)) pt "
                      + "isTemplate=\(img.isTemplate) reps=\(img.representations.count)")
                Self.dumpASCII(img)
                fflush(stdout)
            }
            let check = (hideMenuBarItem?.state == .on) == Self.menuBarIconHidden
            print("[menubar] \(step): isVisible=\(statusItem?.isVisible ?? false) "
                  + "persistedHidden=\(Self.menuBarIconHidden) menuItemInSync=\(check)")
            fflush(stdout)
        }
        // Report the hot key's own registration result: a taken key would silently leave the user
        // with no way to bring the icon back.
        hotKeys.unregister(id: menuBarID)
        let keyOK = hotKeys.register(id: menuBarID, keyCode: 46,
                                     modifiers: UInt32(cmdKey) | UInt32(shiftKey))
        print("[menubar] ⇧⌘M register: \(keyOK)"); fflush(stdout)
        report("launch")
        toggleMenuBarIcon(); report("after 1st toggle")
        toggleMenuBarIcon(); report("after 2nd toggle")
        let pref = ProcessInfo.processInfo.environment["CAPIT_MENUBAR_TEST_PERSIST"] == "1"
        Self.menuBarIconHidden = pref          // show what a relaunch would apply
        statusItem?.isVisible = !pref
        report("after simulating the persisted value")
        exit(0)
    }

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
        selftestLog("before-overlay active=\(NSApp.isActive) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        ctl.run()
        selftestLog("overlay presented")

        for (i, delay) in [0.2, 0.5, 1.0, 1.5].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.selftestLog("poll\(i): active=\(NSApp.isActive) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") "
                    + "keyWindow=\(NSApp.keyWindow != nil) selfKey=\(ctl.windowRef?.isKeyWindow ?? false)")
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

    /// Menu-bar icon size, in points.
    ///
    /// This is the *only* thing that changes the drawn size. Measured on a real status item: the
    /// item draws the image at its natural ink size (the button even grows to fit it), so
    /// `pointSize` maps to a drawn glyph of about 0.955x that — 14 -> 13.5 pt, 18 -> 17.5,
    /// 20 -> 19.0, 22 -> 21.0 — while the symbol's own blank margin is neither scaled away from
    /// the glyph nor counted against it. Cropping that margin out, and padding it further, were
    /// both tried and measure identically (42 px drawn either way), so both are gone.
    private static let statusIconPointSize: CGFloat = 17

    /// The menu bar glyph is the app icon (`resources/AppIcon.icns`), not an SF Symbol, so changing
    /// the icon changes the status item too. The icon is trimmed to its ink before scaling: it ships
    /// with padding, and scaling the padded square made the glyph look a couple of points smaller
    /// than every neighbour in the bar. The badge's light face is dropped so that only its ring and the
    /// camera remain, which is what makes it work as a monochrome menu bar glyph.
    private static func statusBarIcon() -> NSImage? {
        // A lens: the circle, plus the shutter-blade seams that the app icon already draws inside it.
        // The seams are *extracted from the icon* (gradient inside the lens) rather than invented —
        // they are the one part of the artwork worth carrying over, and at 17 pt only they survive.
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let source = NSImage(contentsOf: url),
              var rect = Optional(CGRect(origin: .zero, size: source.size)),
              let cg = source.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        let side = statusIconPointSize
        let scale: CGFloat = 2
        let T = Int(side * scale)                       // 34 px
        let radius = Double(T) / 2 - 1.3                // the circle, inset by half its stroke
        let c = Double(T) / 2

        var buf = [UInt8](repeating: 0, count: T * T * 4)
        // The circle, rasterised by distance so it stays symmetric.
        for y in 0..<T {
            for x in 0..<T {
                let d = (pow(Double(x) + 0.5 - c, 2) + pow(Double(y) + 0.5 - c, 2)).squareRoot()
                if abs(d - radius) <= 1.3 {
                    let o = (y * T + x) * 4
                    buf[o] = 255; buf[o + 1] = 255; buf[o + 2] = 255; buf[o + 3] = 255
                }
            }
        }
        // The seams, sampled from the icon's lens. Cells whose centre falls outside the circle are
        // dropped: the lens square has corners the circle does not.
        for (tx, ty) in bladeSeams(of: cg, resolution: T) {
            let d = (pow(Double(tx) + 0.5 - c, 2) + pow(Double(ty) + 0.5 - c, 2)).squareRoot()
            guard d <= radius - 0.6 else { continue }
            let o = (ty * T + tx) * 4
            buf[o] = 255; buf[o + 1] = 255; buf[o + 2] = 255; buf[o + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(buf) as CFData),
              let out = CGImage(width: T, height: T, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: T * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: side, height: side))
    }

    /// The shutter-blade seams inside the icon's lens, as a `resolution` x `resolution` grid.
    /// The lens is found from the icon's ink box (its radius is 0.44 of it), the seams are the strong
    /// gradients inside the glass, and the outer rim is skipped because the glyph draws its own circle.
    /// A target cell lights up if *any* source pixel under it has an edge, so the thin lines survive
    /// the reduction to menu bar size.
    private static func bladeSeams(of image: CGImage, resolution: Int) -> [(Int, Int)] {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where px[(y * w + x) * 4 + 3] > 128 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX > minX, maxY > minY else { return [] }
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        let lensR = Int(Double(min(maxX - minX, maxY - minY)) * 0.44)
        func lum(_ x: Int, _ y: Int) -> Int {
            let o = (y * w + x) * 4
            return (Int(px[o]) * 3 + Int(px[o + 1]) * 4 + Int(px[o + 2])) / 8
        }
        let cell = Double(2 * lensR) / Double(resolution)
        var hits: [(Int, Int)] = []
        for ty in 0..<resolution {
            for tx in 0..<resolution {
                var found = false
                var sy = 0
                while !found, sy < Int(cell) {
                    var sx = 0
                    while !found, sx < Int(cell) {
                        let x = cx - lensR + Int(Double(tx) * cell) + sx
                        let y = cy - lensR + Int(Double(ty) * cell) + sy
                        sx += 2
                        guard x > 2, x < w - 3, y > 2, y < h - 3 else { continue }
                        let d = (pow(Double(x - cx), 2) + pow(Double(y - cy), 2)).squareRoot() / Double(lensR)
                        guard d < 0.86, d > 0.10 else { continue }
                        let g = abs(lum(x + 2, y) - lum(x - 2, y)) + abs(lum(x, y + 2) - lum(x, y - 2))
                        if g > 90 { found = true }
                    }
                    sy += 2
                }
                if found { hits.append((tx, ty)) }
            }
        }
        return hits
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.statusBarIcon()
            // Not a template: the strokes are white by design. A template would be repainted black on
            // a light menu bar, which is the one place this glyph is meant to stay white.
            button.image?.isTemplate = false
            button.image?.accessibilityDescription = "Capit"
        }

        let menu = NSMenu()
        let full = NSMenuItem(title: "全屏截图",
                              action: #selector(captureFullScreen),
                              keyEquivalent: "3")
        full.keyEquivalentModifierMask = [.command, .shift]
        fullScreenItem = full
        menu.addItem(full)
        let region = NSMenuItem(title: "区域 / 窗口截图",
                                action: #selector(captureInteractive),
                                keyEquivalent: "4")
        region.keyEquivalentModifierMask = [.command, .shift]
        regionItem = region
        menu.addItem(region)
        menu.addItem(.separator())
        let editor = NSMenuItem(title: "编辑器",
                                action: #selector(openEditor),
                                keyEquivalent: "e")
        editor.keyEquivalentModifierMask = [.command]
        menu.addItem(editor)
        let copyToClipboard = NSMenuItem(title: "拷贝到剪切板",
                                         action: #selector(toggleCopyToClipboard), keyEquivalent: "")
        copyToClipboard.target = self
        copyToClipboard.state = CaptureClipboard.isEnabled ? .on : .off
        copyToClipboardItem = copyToClipboard
        menu.addItem(copyToClipboard)
        let autoQuit = NSMenuItem(title: "空闲 10 分钟后自动退出",
                                  action: #selector(toggleAutoQuit), keyEquivalent: "")
        autoQuit.target = self
        autoQuit.state = IdleAutoQuit.isEnabled ? .on : .off
        autoQuitItem = autoQuit
        menu.addItem(autoQuit)
        // The title says how to get the icon back: once hidden, this menu is unreachable, so the
        // key equivalent is the only way in (plus the documented `defaults` fallback).
        let hideMenuBar = NSMenuItem(title: "隐藏菜单栏图标（⇧⌘M 恢复）",
                                     action: #selector(toggleMenuBarIcon), keyEquivalent: "")
        hideMenuBar.target = self
        hideMenuBar.state = Self.menuBarIconHidden ? .on : .off
        hideMenuBarItem = hideMenuBar
        menu.addItem(hideMenuBar)
        menu.addItem(withTitle: "关于", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Capit", action: #selector(quit), keyEquivalent: "q")

        item.menu = menu
        item.isVisible = !Self.menuBarIconHidden
        statusItem = item
    }

    // MARK: - Actions

    @objc private func captureFullScreen() {
        CaptureController.shared.captureFullScreen()
    }

    @objc private func captureInteractive() {
        CaptureController.shared.startInteractive()
    }

    /// Menu → 编辑器: pick a local jpg/png, add the shadow treatment, and open the editor.
    @objc private func openEditor() {
        // Never open a second editor: bring the existing one forward instead.
        if let existing = AnnotationHolder.shared.active {
            existing.bringToFront()
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg]
        panel.prompt = "导入并标注"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let nsImage = NSImage(contentsOf: url),
              let cg = Self.normalizedCGImage(from: nsImage) else { return }
        CaptureController.shared.openImportedImage(cg, sourceURL: url)
    }

    /// Bakes any EXIF orientation into the pixels so a rotated JPEG doesn't come in sideways.
    private static func normalizedCGImage(from image: NSImage) -> CGImage? {
        let px = image.representations.first?.pixelsWide ?? Int(image.size.width)
        let py = image.representations.first?.pixelsHigh ?? Int(image.size.height)
        guard px > 0, py > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: py,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        gc.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: py))
        gc.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// Menu → 关于: show the current version.
    @objc private func showAbout() {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let alert = NSAlert()
        alert.messageText = "关于 Capit"
        // No literal fallback: a hard-coded number goes stale silently, and reporting a wrong version
        // is worse than reporting none.
        alert.informativeText = (short.map { "版本 v\($0)\n\n" } ?? "") + "菜单栏截图标注工具。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// Menu → 拷贝到剪切板: turn the automatic clipboard copy on or off. It is on by default; the
    /// screenshot is copied as soon as it is taken and an annotated image replaces it on save.
    @objc private func toggleCopyToClipboard() {
        let enabled = !CaptureClipboard.isEnabled
        CaptureClipboard.isEnabled = enabled
        copyToClipboardItem?.state = enabled ? .on : .off
    }

    /// Whether the menu bar icon is hidden. Persisted, so the choice survives a relaunch; ⇧⌘M (and
    /// `defaults write com.capit.Capit hideMenuBarIcon -bool false` for a lost hot key) restores it.
    private static var menuBarIconHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "hideMenuBarIcon") }
        set { UserDefaults.standard.set(newValue, forKey: "hideMenuBarIcon") }
    }

    /// Menu → 隐藏菜单栏图标 / ⇧⌘M: toggle the status item. Capturing keeps working while it is
    /// hidden — the global hot keys and the idle timer do not depend on the icon.
    @objc private func toggleMenuBarIcon() {
        let hidden = !Self.menuBarIconHidden
        Self.menuBarIconHidden = hidden
        statusItem?.isVisible = !hidden
        hideMenuBarItem?.state = hidden ? .on : .off
    }

    /// Menu → 空闲自动退出: opt in/out of quitting after 10 minutes of inactivity.
    @objc private func toggleAutoQuit() {
        let enabled = !IdleAutoQuit.isEnabled
        IdleAutoQuit.isEnabled = enabled
        autoQuitItem?.state = enabled ? .on : .off
    }
}
