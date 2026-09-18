import Cocoa
import ScreenCaptureKit

/// Represents what an interactive session ultimately wants to capture.
enum CaptureRequest {
    case region(pixels: CGRect)   // physical-pixel rectangle, CG top-left origin
    case window(CGWindowID)
}

/// A window chosen in window-pick mode.
struct PickedWindow {
    let id: CGWindowID
    let name: String
    let localRect: CGRect
}

/// Everything the overlay view needs to draw a frame.
struct OverlayModel {
    var isWindowMode = false
    var isDragging = false
    var selection: CGRect = .zero
    var hoverRect: CGRect?
    var hoverName: String? = nil
}

/// Runs the interactive overlay for region / window selection.
final class InteractiveCaptureController: NSObject {

    private var window: OverlayWindow?
    private weak var view: OverlayView?
    let screen: NSScreen
    private let windows: [SCWindow]

    var windowRef: NSWindow? { window }

    private var anchor: CGPoint?
    private var current: CGPoint = .zero
    private var hovered: PickedWindow?
    private var isWindowMode = false
    private var didFinish = false

    private var isRegionDragging = false
    private var movingSelection = false
    private var lastMovePoint = CGPoint.zero

    private var clickMonitor: Any?
    private var watchdog: Timer?

    var onComplete: ((Result<CaptureRequest, Error>) -> Void)?

    init(screen: NSScreen, windows: [SCWindow] = []) {
        self.screen = screen
        self.windows = windows
        super.init()
    }

    func run() {
        assert(Thread.isMainThread)
        let content = OverlayView()
        content.controller = self
        view = content

        let w = OverlayWindow(contentRect: screen.frame)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.acceptsMouseMovedEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = content
        w.becomesKeyOnlyIfNeeded = false
        window = w

        // Present WITHOUT activating this app, so the frontmost app keeps its active state
        // (its menu bar / open menus / popovers stay put and remain capturable) — like the
        // native screenshot UI. `.nonactivatingPanel` still lets the overlay become key so
        // ESC / space are received.
        w.orderFrontRegardless()
        installKeyMonitor()

        watchdog = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            self?.cancel()
        }
        pushModel()
    }

    // MARK: - Key fallback

    private var keyMonitor: Any?
    private var keyUpMonitor: Any?

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKey(event) == true {
                return nil
            }
            return event
        }
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            if event.keyCode == 49 {
                self?.movingSelection = false
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let keyUpMonitor {
            NSEvent.removeMonitor(keyUpMonitor)
            self.keyUpMonitor = nil
        }
    }

    func cancel() {
        finish(.failure(CaptureError.cancelled))
    }

    private func finish(_ result: Result<CaptureRequest, Error>) {
        guard !didFinish else { return }
        didFinish = true

        watchdog?.invalidate()
        watchdog = nil
        removeKeyMonitor()
        stopWindowClickMonitor()
        window?.orderOut(nil)
        window = nil

        let cb = onComplete
        onComplete = nil
        cb?(result)
    }

    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:                       // esc
            cancel()
            return true
        case 49:                       // space
            if !isWindowMode && isRegionDragging {
                movingSelection = true
                lastMovePoint = current
            } else {
                toggleMode()
            }
            return true
        case 36:                       // return
            if isWindowMode {
                if let h = hovered ?? window(at: current) {
                    finish(.success(.window(h.id)))
                } else {
                    finish(.failure(CaptureError.cancelled))
                }
            }
            return true
        default:
            return false
        }
    }

    private func toggleMode() {
        isWindowMode.toggle()
        if isWindowMode {
            anchor = nil
            installWindowClickMonitor()
            let p = NSEvent.mouseLocation
            let local = CGPoint(x: p.x - screen.frame.origin.x, y: p.y - screen.frame.origin.y)
            hovered = window(at: local)
            current = local
        } else {
            hovered = nil
            stopWindowClickMonitor()
        }
        pushModel()
        if let v = view { window?.invalidateCursorRects(for: v) }
        let mode = isWindowMode
        DispatchQueue.main.async { [weak self] in
            self?.view?.model.isWindowMode = mode
            self?.view?.applyModeCursor()
        }
    }

    private func installWindowClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isWindowMode, !self.didFinish else { return }
                self.handleWindowClick()
            }
        }
    }

    private func stopWindowClickMonitor() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    private func handleWindowClick() {
        let p = NSEvent.mouseLocation
        let local = CGPoint(x: p.x - screen.frame.origin.x, y: p.y - screen.frame.origin.y)
        if let w = window(at: local) {
            finish(.success(.window(w.id)))
        } else {
            finish(.failure(CaptureError.cancelled))
        }
    }

    // MARK: - Mouse

    func mouseDown(at point: CGPoint) {
        current = point
        if !isWindowMode {
            anchor = point
            isRegionDragging = true
        }
        pushModel()
    }

    func mouseDragged(to point: CGPoint) {
        if movingSelection {
            let dx = point.x - lastMovePoint.x
            let dy = point.y - lastMovePoint.y
            if let a = anchor {
                anchor = CGPoint(x: a.x + dx, y: a.y + dy)
            }
            lastMovePoint = point
            current = point
        } else {
            current = point
        }
        pushModel()
    }

    func mouseUp(at point: CGPoint) {
        isRegionDragging = false
        movingSelection = false
        current = point
        if isWindowMode {
            if let h = hovered ?? window(at: point) {
                finish(.success(.window(h.id)))
            } else {
                pushModel()
            }
        } else {
            let rect = selectionRect(from: anchor, to: point)
            guard let rect, rect.width >= 1, rect.height >= 1 else { return }
            finish(.success(.region(pixels: Self.pixelRect(rect, screen: screen))))
        }
    }

    func mouseMoved(to point: CGPoint) {
        guard isWindowMode else { return }
        current = point
        let h = window(at: point)
        if h?.id != hovered?.id {
            ovlog("hover -> \(h.map { "\($0.id):\(Int($0.localRect.width))x\(Int($0.localRect.height))" } ?? "none")")
        }
        hovered = h
        pushModel()
    }

    // MARK: - Model / view updates

    private func currentSelection() -> CGRect? {
        guard let a = anchor, !isWindowMode else { return nil }
        return selectionRect(from: a, to: current)
    }

    private func pushModel() {
        var m = OverlayModel()
        m.isWindowMode = isWindowMode
        m.isDragging = (anchor != nil)
        m.selection = currentSelection() ?? .zero
        if let h = hovered {
            m.hoverRect = h.localRect
            m.hoverName = h.name
        }
        view?.model = m
        view?.needsDisplay = true
        view?.applyModeCursor()
    }

    // MARK: - Geometry

    private func selectionRect(from a: CGPoint?, to b: CGPoint) -> CGRect? {
        guard let a else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Picks the front-most normal window under a point using the true Z-order via
    /// CGWindowListCopyWindowInfo (topmost-first), matching the system behaviour.
    private func window(at point: CGPoint) -> PickedWindow? {
        let ourPid = ProcessInfo.processInfo.processIdentifier
        let d = Self.displayBounds(screen)
        let sf = screen.frame
        let global = CGPoint(x: sf.minX + point.x, y: d.maxY - point.y)
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] {
            for info in list {
                guard let owner = info[kCGWindowOwnerPID as String] as? Int, owner != ourPid else { continue }
                guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
                guard let num = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
                guard let b = info[kCGWindowBounds as String] as? [String: Any],
                      let x = (b["X"] as? NSNumber)?.doubleValue,
                      let y = (b["Y"] as? NSNumber)?.doubleValue,
                      let w = (b["Width"] as? NSNumber)?.doubleValue,
                      let h = (b["Height"] as? NSNumber)?.doubleValue,
                      w >= 80, h >= 60 else { continue }
                guard CGRect(x: x, y: y, width: w, height: h).contains(global) else { continue }
                if let sc = windows.first(where: { $0.windowID == num }) {
                    let local = Self.localRect(sc.frame, screen: screen)
                    let title = sc.title ?? ""
                    let ownerName = sc.owningApplication?.applicationName ?? ""
                    return PickedWindow(id: num,
                                        name: title.isEmpty ? ownerName : title,
                                        localRect: local)
                }
            }
        }
        // Fallback: scan the SC window list in order.
        for w in windows {
            guard w.windowLayer == 0 else { continue }
            guard let owner = w.owningApplication, owner.processID != ourPid else { continue }
            guard w.isOnScreen else { continue }
            let local = Self.localRect(w.frame, screen: screen)
            guard local.width >= 80, local.height >= 60, local.contains(point) else { continue }
            let title = w.title ?? ""
            let ownerName = owner.applicationName
            return PickedWindow(id: w.windowID,
                                name: title.isEmpty ? ownerName : title,
                                localRect: local)
        }
        return nil
    }

    // MARK: - Static conversions

    /// SCWindow.frame uses a global top-left-anchored CG space → screen-local bottom-left points.
    static func localRect(_ cgRect: CGRect, screen: NSScreen) -> CGRect {
        let d = displayBounds(screen)
        let sf = screen.frame
        let x = sf.minX + (cgRect.minX - d.minX)
        let bottom = sf.minY + (d.maxY - cgRect.maxY)
        return CGRect(x: x, y: bottom, width: cgRect.width, height: cgRect.height)
    }

    /// screen-local region → physical-pixel CGRect in CG (top-left) space.
    static func pixelRect(_ rect: CGRect, screen: NSScreen) -> CGRect {
        let scale = screen.backingScaleFactor
        let sf = screen.frame
        let yFromTop = (sf.maxY - rect.maxY) * scale
        return CGRect(x: rect.minX * scale,
                      y: yFromTop,
                      width: rect.width * scale,
                      height: rect.height * scale)
    }

    private static func displayBounds(_ screen: NSScreen) -> CGRect {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        if let id {
            return CGDisplayBounds(CGDirectDisplayID(id.uint32Value))
        }
        return screen.frame
    }
}

// MARK: - Overlay window (borderless, key-capable, non-activating)

private final class OverlayWindow: NSPanel {
    convenience init(contentRect: CGRect) {
        self.init(contentRect: contentRect,
                  styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                  backing: .buffered,
                  defer: false)
        // Chrome-less titled panel: the standard recipe that lets a panel become key
        // WITHOUT activating the host app.
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isMovableByWindowBackground = false
        isFloatingPanel = true
        hidesOnDeactivate = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Overlay view

func ovlog(_ message: String) {
#if DEBUG
    let line = "[overlay] \(message)\n"
    let url = URL(fileURLWithPath: "/tmp/capit_overlay.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.close()
    } else {
        try? line.data(using: .utf8)?.write(to: url)
    }
#endif
    NSLog("[Capit] %@", message)
}

enum OverlayCursor {
    static let windowCursor: NSCursor = {
        let size = NSSize(width: 28, height: 28)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.clear.set(); NSRect(origin: .zero, size: size).fill()

        let body = NSRect(x: 5, y: 8, width: 18, height: 12)
        let top = NSRect(x: 8, y: 16, width: 6, height: 3)
        let lens = NSRect(x: 11, y: 11, width: 6, height: 6)

        NSColor.white.set()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 26, height: 26)).fill()

        NSColor.black.set()
        NSBezierPath(roundedRect: body, xRadius: 2, yRadius: 2).fill()
        NSBezierPath(roundedRect: top, xRadius: 1, yRadius: 1).fill()
        NSColor.white.set()
        NSBezierPath(ovalIn: lens).fill()
        NSColor.black.set()
        NSBezierPath(ovalIn: lens.insetBy(dx: 2, dy: 2)).fill()

        img.unlockFocus()
        return NSCursor(image: img, hotSpot: NSPoint(x: 14, y: 14))
    }()
}

final class OverlayView: NSView {
    weak var controller: InteractiveCaptureController?
    var model = OverlayModel()
    override var acceptsFirstResponder: Bool { true }

    private var dashPhase: CGFloat = 0
    private var animTimer: Timer?

    private func syncAnimation() {
        let want = model.isWindowMode
        if want && animTimer == nil {
            let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.dashPhase += 3
                self.needsDisplay = true
            }
            RunLoop.main.add(t, forMode: .common)
            animTimer = t
        } else if !want, let t = animTimer {
            t.invalidate()
            animTimer = nil
        }
    }

    override func keyDown(with event: NSEvent) {
        if controller?.handleKey(event) == true {
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        controller?.mouseDown(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseDragged(with event: NSEvent) {
        controller?.mouseDragged(to: convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        controller?.mouseUp(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseMoved(with event: NSEvent) {
        controller?.mouseMoved(to: convert(event.locationInWindow, from: nil))
        applyModeCursor()
    }

    func applyModeCursor() {
        if model.isWindowMode {
            OverlayCursor.windowCursor.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    override func resetCursorRects() {
        if model.isWindowMode {
            addCursorRect(bounds, cursor: OverlayCursor.windowCursor)
        } else {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        syncAnimation()

        let hole: CGRect? = model.isWindowMode ? model.hoverRect
            : (model.isDragging && model.selection.width > 0 ? model.selection : nil)

        let path = NSBezierPath(rect: bounds)
        if let hole, hole.width > 0, hole.height > 0, bounds.intersects(hole) {
            path.append(NSBezierPath(rect: hole))
            path.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.22).setFill()
        path.fill()

        if let hole, hole.width > 0, hole.height > 0 {
            NSColor.systemGreen.setStroke()
            if model.isWindowMode {
                let border = NSBezierPath(rect: hole.insetBy(dx: 2, dy: 2))
                border.lineWidth = 2
                border.setLineDash([9, 6], count: 2, phase: dashPhase)
                border.stroke()
            } else {
                let border = NSBezierPath(rect: hole.insetBy(dx: 1, dy: 1))
                border.lineWidth = 2
                border.setLineDash([6, 5], count: 2, phase: 0)
                border.stroke()
            }
            drawSizeLabel(for: hole)
        } else if model.isWindowMode, let name = model.hoverName {
            drawWindowName(name)
        }
        drawModeHint()
    }

    private func drawModeHint() {
        let text: String
        if model.isWindowMode {
            text = "点按 / 回车 截取窗口  ·  ESC 取消"
        } else {
            text = "拖拽选择区域  ·  空格切换窗口  ·  ESC 取消"
        }
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7)
        ]
        let s = NSAttributedString(string: text, attributes: attr)
        let size = s.size()
        let x = bounds.midX - size.width / 2
        let y: CGFloat = bounds.height - size.height - 48
        s.draw(at: NSPoint(x: x, y: y))
    }

    private func drawSizeLabel(for rect: CGRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.6)
        ]
        let s = NSAttributedString(string: text, attributes: attr)
        let size = s.size()
        var x = rect.midX - size.width / 2
        var y = rect.midY + 6
        x = min(max(x, 4), bounds.width - size.width - 4)
        y = min(max(y, 4), bounds.height - size.height - 4)
        s.draw(at: NSPoint(x: x, y: y))
    }

    private func drawWindowName(_ name: String) {
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.6)
        ]
        let s = NSAttributedString(string: name, attributes: attr)
        let size = s.size()
        let x = bounds.midX - size.width / 2
        let y = bounds.height - size.height - 30
        s.draw(at: NSPoint(x: x, y: y))
    }
}
