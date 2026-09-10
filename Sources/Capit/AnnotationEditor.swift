import Cocoa

private var toolKindKey: UInt8 = 0

/// Result of an off-main PNG save (encode/write).
private enum SaveOutcome {
    case success
    case failure(String)
}

/// Tools whose annotations carry a stroke width (and show the width popup).
private let strokeWidthKinds: Set<AnnotationShape.Kind> =
    [.rect, .ellipse, .arrow, .line, .highlighter]

/// Auto continuous-corner radius for a rounded rectangle (a fraction of its shorter side).
private func continuousRadius(for r: CGRect) -> CGFloat {
    max(4, min(r.width, r.height) * 0.2)
}

/// Draws one annotation into the *current* NSGraphicsContext, in document (view)
/// coordinates. Shared by the live canvas and the export renderer.
private func renderShape(_ shape: AnnotationShape) {
    let color = shape.color.withAlphaComponent(shape.color.alphaComponent * shape.opacity)
    switch shape.kind {
    case .rect:
        let r = shape.rect
        let path = SquirclePath.path(in: r, radius: continuousRadius(for: r), exponent: 3.5)
        path.lineWidth = shape.strokeWidth
        color.setStroke()
        if shape.dashed { path.setLineDash([8, 6], count: 2, phase: 0) }
        path.stroke()
    case .ellipse:
        let path = NSBezierPath(ovalIn: shape.rect)
        path.lineWidth = shape.strokeWidth
        color.setStroke()
        if shape.dashed { path.setLineDash([8, 6], count: 2, phase: 0) }
        path.stroke()
    case .line, .arrow:
        let path = NSBezierPath()
        path.move(to: shape.start)
        path.line(to: shape.end)
        path.lineWidth = shape.strokeWidth
        path.lineCapStyle = .round
        color.setStroke()
        if shape.dashed { path.setLineDash([8, 6], count: 2, phase: 0) }
        path.stroke()
        if shape.kind == .arrow {
            drawArrowHead(from: shape.start, to: shape.end,
                          width: shape.strokeWidth, color: color, dashed: shape.dashed)
        }
    case .highlighter:
        let path = NSBezierPath()
        path.move(to: shape.start)
        path.line(to: shape.end)
        path.lineWidth = shape.strokeWidth
        path.lineCapStyle = .butt
        color.setStroke()
        path.stroke()
    case .text:
        if !shape.text.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: shape.fontSize),
                .foregroundColor: color]
            NSAttributedString(string: shape.text, attributes: attrs).draw(at: shape.start)
        }
    case .number:
        drawNumberBadge(shape)
    case .mosaic:
        // Mosaic is an opaque solid fill in the chosen color (default black).
        shape.color.withAlphaComponent(1).setFill()
        NSBezierPath(rect: shape.rect).fill()
    }
}

/// Arrowhead: two non-filled arms from the tip sweeping back at 45° each (90° total); each
/// arm's length (tip → arm end) = 2/5 of the shaft. Round caps; dashed follows the arrow.
private func drawArrowHead(from a: CGPoint, to b: CGPoint, width: CGFloat, color: NSColor,
                           dashed: Bool) {
    let len = max(4, hypot(b.x - a.x, b.y - a.y) * 0.4)   // 2/5 of the shaft
    let base = atan2(a.y - b.y, a.x - b.x)
    for ang in [base + CGFloat.pi / 4, base - CGFloat.pi / 4] {   // ±45° → 90° total
        let end = CGPoint(x: b.x + len * cos(ang), y: b.y + len * sin(ang))
        let p = NSBezierPath(); p.move(to: b); p.line(to: end)
        p.lineWidth = width; p.lineCapStyle = .round
        if dashed { p.setLineDash([8, 6], count: 2, phase: 0) }
        color.setStroke(); p.stroke()
    }
}

/// Solid opaque number badge (circle + white number), on screen and when exported.
private func drawNumberBadge(_ shape: AnnotationShape) {
    let size = shape.fontSize * 1.4
    let radius = size / 2
    let center = shape.start
    let rect = NSRect(x: center.x - radius, y: center.y - radius,
                      width: size, height: size)
    shape.color.setFill()
    NSBezierPath(ovalIn: rect).fill()
    let text = "\(shape.number)"
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: shape.fontSize * 0.7),
        .foregroundColor: NSColor.white]
    let str = NSAttributedString(string: text, attributes: attrs)
    let sz = str.size()
    str.draw(at: NSPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2))
}

/// Retains the active annotation editor so it isn't released while its window is open.
final class AnnotationHolder {
    static let shared = AnnotationHolder()
    private init() {}
    var active: AnnotationEditorController?
}

/// A vector annotation shape drawn on the canvas.
struct AnnotationShape {    enum Kind: String, CaseIterable {
        case rect, ellipse, arrow, line, highlighter, text, number, mosaic
    }
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var color: NSColor = .yellow
    var strokeWidth: CGFloat = 12
    var opacity: CGFloat = 0.45
    var fontSize: CGFloat = 18
    var text: String = ""
    var dashed = false
    var number: Int = 1

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}

/// The annotation editor: toolbar (top) + scrollable canvas (bottom).
final class AnnotationEditorController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let canvas: AnnotationCanvasView
    private let toolbar: ToolbarView
    private let image: CGImage
    private let fileURL: URL?
    private let docSize: CGSize
    private var didSave = false
    private var isSaving = false
    private var rawLandingQueued = false
    private var exportScale: CGFloat { CGFloat(image.width) / docSize.width }
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private weak var scrollView: NSScrollView?

    private func relayoutImage() {
        guard let sv = scrollView else { return }
        let cs = sv.contentSize
        guard cs.width > 1, cs.height > 1 else { return }
        let fit = min(cs.width / docSize.width, cs.height / docSize.height)
        sv.magnification = fit
    }

    init?(image: CGImage, fileURL: URL?) {
        self.image = image
        self.fileURL = fileURL
        docSize = CGSize(width: CGFloat(image.width) / 2,
                         height: CGFloat(image.height) / 2)

        canvas = AnnotationCanvasView(image: image, docSize: docSize)
        toolbar = ToolbarView()

        let screenSize = NSScreen.main?.frame.size ?? NSSize(width: 1440, height: 900)
        let contentRect = NSRect(x: 0, y: 0,
                                 width: max(400, screenSize.width * 2 / 3),
                                 height: max(300, screenSize.height * 2 / 3))
        window = NSWindow(contentRect: contentRect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "标注编辑"
        window.minSize = NSSize(width: 400, height: 300)
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        toolbar.detachColorPanelTarget()
        // If the user closed without ever saving, land the (un-annotated) capture.
        if !didSave && !isSaving && !rawLandingQueued, let url = fileURL {
            rawLandingQueued = true
            let img = image
            CaptureWriter.schedule { try? CapturePipeline.write(image: img, to: url) }
        }
        NSApp.setActivationPolicy(.accessory)
        AnnotationHolder.shared.active = nil
    }

    /// Called just before the app quits: queues the capture so a quit during editing
    /// doesn't lose it, and the app can wait for the write via `CaptureWriter`.
    func ensureCapturedBeforeQuit() {
        if !didSave && !isSaving && !rawLandingQueued, let url = fileURL {
            rawLandingQueued = true
            let img = image
            CaptureWriter.schedule { try? CapturePipeline.write(image: img, to: url) }
        }
    }

    func present() {
        AnnotationHolder.shared.active = self
        IdleAutoQuit.shared.reset()
        let content = NSView()
        content.addSubview(toolbar)

        let scroll = NSScrollView()
        let clip = CenteringClipView()
        scroll.contentView = clip
        clip.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        content.addSubview(scroll)

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        toolbar.onSelectTool = { [weak self] tool in
            guard let self else { return }
            self.canvas.commitTextEditor()
            self.canvas.selectTool(tool)
        }
        toolbar.onColor = { [weak self] color in self?.canvas.setCurrentColor(color) }
        toolbar.onPanelColorSeed = { [weak self] in self?.canvas.strokeColor ?? NSColor.black }
        toolbar.onWidth = { [weak self] w in self?.canvas.setCurrentWidth(w) }
        toolbar.onFontSize = { [weak self] s in self?.canvas.setLiveTextSize(s) }
        toolbar.onLineStyle = { [weak self] dashed in self?.canvas.setLineDashed(dashed) }
        toolbar.onSave = { [weak self] in self?.save() }
        canvas.onCurrentWidthChanged = { [weak self] width in self?.toolbar.setWidthDisplay(width) }
        canvas.onActiveTool = { [weak self] kind in
            guard let self else { return }
            self.toolbar.setActiveTool(kind,
                                       lineDashed: self.canvas.effectiveLineDashed)
        }

        window.contentView = content
        window.center()
        // Open with NO tool selected — a stray click must not drop an annotation.
        toolbar.setNoTool()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let cmd = event.modifierFlags.contains(.command)
            let shift = event.modifierFlags.contains(.shift)
            let editingText = NSApp.keyWindow?.firstResponder is NSText
            switch event.keyCode {
            case 1 where cmd:            // Cmd+S
                self.save(); return nil
            case 6 where cmd && !editingText:
                if shift { self.canvas.requestRedo() } else { self.canvas.requestUndo() }
                return nil
            case 51, 117:
                if !editingText { self.canvas.requestDelete(); return nil }
                return event
            case 123, 124, 125, 126:      // ← → ↓ ↑ move the selected annotation
                guard !editingText, self.canvas.hasSelection else { return event }
                let step: CGFloat = shift ? 10 : 1
                let dx: CGFloat = (event.keyCode == 123) ? -step : (event.keyCode == 124 ? step : 0)
                let dy: CGFloat = (event.keyCode == 125) ? step : (event.keyCode == 126 ? -step : 0)
                self.canvas.nudgeSelected(dx: dx, dy: dy)
                return nil
            default:
                return event
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let scroll = content.subviews.compactMap({ $0 as? NSScrollView }).first else { return }
            self.scrollView = scroll
            scroll.allowsMagnification = true
            scroll.minMagnification = 0.1
            scroll.maxMagnification = 8
            self.relayoutImage()
        }

        let c = NotificationCenter.default
        let q = OperationQueue.main
        observers.append(c.addObserver(forName: NSWindow.didResizeNotification,
                                       object: window, queue: q) { [weak self] _ in
            self?.relayoutImage()
        })
        observers.append(c.addObserver(forName: NSWindow.didEndLiveResizeNotification,
                                       object: window, queue: q) { [weak self] _ in
            self?.relayoutImage()
        })
    }

    /// Overlays the shapes and writes a new PNG.
    private func save() {
        guard !isSaving else { return }
        canvas.commitTextEditor()
        let w = image.width, h = image.height
        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        NSGraphicsContext.saveGraphicsState()
        let g = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.current = g
        let s = exportScale
        g.cgContext.saveGState()
        g.cgContext.translateBy(x: 0, y: CGFloat(h))
        g.cgContext.scaleBy(x: s, y: -s)
        for shape in canvas.shapes {
            renderShape(shape)
        }
        g.cgContext.restoreGState()
        g.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let out = ctx.makeImage() else { return }
        let url: URL
        if let fileURL {
            url = fileURL
        } else {
            url = CapturePipeline.desktopURL()
        }
        isSaving = true
        let snapshot = out
        Task.detached(priority: .userInitiated) {
            let outcome: SaveOutcome
            if let data = NSBitmapImageRep(cgImage: snapshot)
                .representation(using: .png, properties: [:]) {
                do {
                    try data.write(to: url)
                    outcome = .success
                } catch {
                    outcome = .failure("无法写入文件：\n\(error.localizedDescription)")
                }
            } else {
                outcome = .failure("无法编码 PNG 图像。")
            }
            DispatchQueue.main.async { [self] in
                self.finishSave(outcome)
            }
        }
    }

    private func finishSave(_ outcome: SaveOutcome) {
        isSaving = false
        switch outcome {
        case .success:
            didSave = true
            window.close()
        case .failure(let message):
            presentSaveFailure(message: message)
            // If the window was closed while the save was in flight and it failed, don't let
            // the capture vanish — land the original image best-effort.
            if !didSave, !window.isVisible {
                let url = fileURL ?? CapturePipeline.desktopURL()
                let img = image
                CaptureWriter.schedule { try? CapturePipeline.write(image: img, to: url) }
            }
        }
    }

    private func presentSaveFailure(message: String) {
        let a = NSAlert()
        a.messageText = "保存失败"
        a.informativeText = message
        a.alertStyle = .warning
        a.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

/// NSClipView that keeps the document centered whenever it's smaller than the visible area.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        if doc.frame.width < r.width {
            r.origin.x = (doc.frame.width - r.width) / 2
        }
        if doc.frame.height < r.height {
            r.origin.y = (doc.frame.height - r.height) / 2
        }
        return r
    }
}

final class AnnotationCanvasView: NSView, NSTextFieldDelegate {
    var shapes: [AnnotationShape] = []
    var currentKind: AnnotationShape.Kind = .rect
    /// True once the user has picked a tool (button) or selected an existing shape.
    private(set) var hasActiveTool = false
    var lineDashed = false
    var textFontSize: CGFloat = 20

    private var selectedIndex: Int?
    private var history: [[AnnotationShape]] = []
    private var redoHistory: [[AnnotationShape]] = []

    private var moveIndex: Int?
    private var moveDown: CGPoint?
    private var moveStart0: CGPoint = .zero
    private var moveEnd0: CGPoint = .zero
    private var movePushed = false
    private let moveKinds: Set<AnnotationShape.Kind> =
        [.rect, .ellipse, .line, .arrow, .number, .text, .highlighter, .mosaic]

    func pushState() { history.append(shapes); if history.count > 60 { history.removeFirst() }; redoHistory.removeAll() }

    func undo() {
        guard let s = history.popLast() else { return }
        redoHistory.append(shapes)
        shapes = s
        selectedIndex = nil
        selectionChanged()
        needsDisplay = true
    }
    func redo() {
        guard let s = redoHistory.popLast() else { return }
        history.append(shapes)
        shapes = s
        selectedIndex = nil
        selectionChanged()
        needsDisplay = true
    }

    func deleteSelected() {
        guard let i = selectedIndex, i < shapes.count else { return }
        pushState()
        shapes.remove(at: i)
        selectedIndex = nil
        renumberNumbers()
        selectionChanged()
        needsDisplay = true
    }
    func requestDelete() { if selectedIndex != nil { deleteSelected() } }
    func requestUndo() { undo() }
    func requestRedo() { redo() }

    var hasSelection: Bool { selectedIndex != nil }

    /// Moves the selected annotation by (dx, dy) — used by the arrow keys. One undo step
    /// per press.
    func nudgeSelected(dx: CGFloat, dy: CGFloat) {
        guard let i = selectedIndex, i < shapes.count else { return }
        pushState()
        shapes[i].start.x += dx
        shapes[i].start.y += dy
        shapes[i].end.x += dx
        shapes[i].end.y += dy
        needsDisplay = true
    }

    // MARK: Inline text editing

    private var textField: NSTextField?
    private var editingTextIndex: Int?
    private var pendingTextStart: CGPoint = .zero
    private var pendingTextColor: NSColor = .black
    private var swallowCommitClick = false

    var isEditingText: Bool { textField != nil }

    func beginText(at p: CGPoint, editingIndex: Int?) {
        commitTextEditor()
        let size = editingIndex.map { shapes[$0].fontSize } ?? textFontSize
        let color = editingIndex.map { shapes[$0].color } ?? strokeColor
        pendingTextStart = p
        pendingTextColor = color
        editingTextIndex = editingIndex
        if let i = editingIndex, i < shapes.count {
            shapes[i].opacity = 0
        }

        let field = NSTextField(string: editingIndex.map { shapes[$0].text } ?? "")
        field.font = NSFont.systemFont(ofSize: size)
        field.textColor = color
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.isSelectable = true
        field.focusRingType = .none
        field.delegate = self
        field.target = self
        field.action = #selector(commitAction(_:))
        field.frame = NSRect(x: p.x, y: p.y, width: 200, height: size + 8)
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    @objc private func commitAction(_ sender: Any?) { commitTextEditor() }

    func commitTextEditor() {
        guard let field = textField else { return }
        textField = nil
        let editing = editingTextIndex
        editingTextIndex = nil
        field.delegate = nil
        field.target = nil
        field.action = nil

        let text = field.stringValue
        if editing == nil {
            if !text.isEmpty {
                pushState()
                shapes.append(AnnotationShape(kind: .text, start: pendingTextStart, end: pendingTextStart,
                                              color: pendingTextColor, opacity: 1,
                                              fontSize: textFontSize, text: text))
            }
        } else if let i = editing, i < shapes.count {
            if text.isEmpty {
                pushState()
                shapes.remove(at: i)
            } else {
                pushState()
                shapes[i].text = text
                shapes[i].color = pendingTextColor
                shapes[i].opacity = 1
            }
        }
        field.removeFromSuperview()
        needsDisplay = true
    }

    func setLiveTextSize(_ size: CGFloat) {
        textFontSize = size
        if let field = textField {
            field.font = NSFont.systemFont(ofSize: size)
            var r = field.frame
            r.size.height = size + 8
            field.frame = r
            if let i = editingTextIndex, i < shapes.count {
                shapes[i].fontSize = size
            }
            controlTextDidChange(Notification(name: NSText.didChangeNotification, object: field))
            needsDisplay = true
            return
        }
        if let i = selectedIndex, i < shapes.count,
           (shapes[i].kind == .text || shapes[i].kind == .number) {
            pushState()
            shapes[i].fontSize = size
        }
        needsDisplay = true
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = textField else { return }
        let size = (field.stringValue as NSString)
            .size(withAttributes: [.font: field.font ?? NSFont.systemFont(ofSize: 18)])
        var r = field.frame
        r.size.width = max(140, size.width + 8)
        field.frame = r
        needsDisplay = true
    }

    private func renumberNumbers() {
        var k = 1
        for i in shapes.indices where shapes[i].kind == .number {
            shapes[i].number = k
            k += 1
        }
    }
    var strokeColor: NSColor = .red
    var strokeWidth: CGFloat = 3
    private var colorEditHistoryPushed = false

    private var colorByKind: [AnnotationShape.Kind: NSColor] = [
        .highlighter: NSColor(calibratedRed: 0.90, green: 0.68, blue: 0.0, alpha: 0.5),
        .mosaic: NSColor.black
    ]
    private static let defaultColor: NSColor = .red
    private static let outlineKinds: Set<AnnotationShape.Kind> = [.rect, .ellipse, .arrow, .line]

    private func colorFor(_ kind: AnnotationShape.Kind) -> NSColor {
        colorByKind[kind] ?? Self.defaultColor
    }

    func selectTool(_ kind: AnnotationShape.Kind) {
        hasActiveTool = true
        currentKind = kind
        strokeColor = colorFor(kind)
        strokeWidth = defaultWidth(for: kind)
        notifyWidthDisplay()
        onActiveTool?(kind)
        refreshCursorRects()
    }

    private func defaultWidth(for kind: AnnotationShape.Kind) -> CGFloat {
        kind == .highlighter ? 16 : Self.defaultStrokeWidth
    }

    func setCurrentColor(_ color: NSColor) {
        // The highlighter is always a 50% translucent marker: whatever color is chosen gets
        // its alpha pinned to 0.5 (per-kind).
        func sized(_ c: NSColor, for kind: AnnotationShape.Kind) -> NSColor {
            kind == .highlighter ? c.withAlphaComponent(0.5) : c
        }
        let active = sized(color, for: currentKind)
        colorByKind[currentKind] = active
        strokeColor = active
        if let i = selectedIndex, i < shapes.count {
            let sc = sized(color, for: shapes[i].kind)
            colorByKind[shapes[i].kind] = sc
            if !colorEditHistoryPushed { pushState(); colorEditHistoryPushed = true }
            shapes[i].color = sc
        }
        if let field = textField {
            pendingTextColor = color
            field.textColor = color
        }
        needsDisplay = true
    }

    static let defaultStrokeWidth: CGFloat = 3

    var onCurrentWidthChanged: ((CGFloat) -> Void)?
    var onActiveTool: ((AnnotationShape.Kind) -> Void)?

    private func notifyWidthDisplay() {
        let w: CGFloat
        if let i = selectedIndex, i < shapes.count,
           strokeWidthKinds.contains(shapes[i].kind) {
            w = shapes[i].strokeWidth
        } else {
            w = defaultWidth(for: currentKind)
        }
        onCurrentWidthChanged?(w)
    }

    private func selectionChanged() {
        colorEditHistoryPushed = false
        if let i = selectedIndex, i < shapes.count,
           strokeWidthKinds.contains(shapes[i].kind) {
            strokeWidth = shapes[i].strokeWidth
        } else {
            strokeWidth = defaultWidth(for: currentKind)
        }
        // Reflect the current selection (a shape's own style) or, once deselected, the tool's
        // remembered defaults — viewing only, never adopted into the defaults.
        onActiveTool?(currentKind)
        notifyWidthDisplay()
        refreshCursorRects()
    }

    /// Sets the dashed flag for the tool; if an outline shape is selected, applies in place.
    func setLineDashed(_ dashed: Bool) {
        lineDashed = dashed
        if let i = selectedIndex, i < shapes.count,
           Self.outlineKinds.contains(shapes[i].kind) {
            pushState()
            shapes[i].dashed = dashed
            needsDisplay = true
        }
    }

    /// The outline-style value to show follows a selected shape when one exists.
    var effectiveLineDashed: Bool {
        if let i = selectedIndex, i < shapes.count,
           Self.outlineKinds.contains(shapes[i].kind) {
            return shapes[i].dashed
        }
        return lineDashed
    }

    func setCurrentWidth(_ width: CGFloat) {
        strokeWidth = width
        if let i = selectedIndex, i < shapes.count,
           strokeWidthKinds.contains(shapes[i].kind) {
            pushState()
            shapes[i].strokeWidth = width
            notifyWidthDisplay()
            needsDisplay = true
        }
        refreshCursorRects()
    }

    private let baseDraw: NSImage
    private var dragStart: CGPoint?
    private var inProgress: AnnotationShape?

    init(image: CGImage, docSize: CGSize) {
        self.baseDraw = NSImage(cgImage: image,
                                size: NSSize(width: docSize.width, height: docSize.height))
        super.init(frame: NSRect(origin: .zero, size: docSize))
        self.frame = NSRect(origin: .zero, size: docSize)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: Tool cursors

    private static var caretCache: [CGFloat: NSCursor] = [:]

    private func currentCursor() -> NSCursor {
        switch currentKind {
        case .mosaic: return NSCursor.crosshair
        case .highlighter: return Self.highlighterCaret(width: strokeWidth)
        default: return NSCursor.arrow
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: currentCursor())
    }

    private func refreshCursorRects() {
        window?.invalidateCursorRects(for: self)
    }

    private static func highlighterCaret(width: CGFloat) -> NSCursor {
        if let c = caretCache[width] { return c }
        let span = max(6, width)
        let stemW: CGFloat = 2
        let capL: CGFloat = 5
        let halo: CGFloat = 1
        let W = capL + halo * 2 + 6
        let H = span + (2 + halo * 2)
        let midX = W / 2
        let img = NSImage(size: NSSize(width: W, height: H))
        img.lockFocus()
        NSColor.clear.set()
        NSRect(origin: .zero, size: img.size).fill()
        func paint(_ stem: CGFloat, _ cap: CGFloat, _ color: NSColor) {
            color.setFill()
            NSBezierPath(rect: NSRect(x: midX - stem / 2, y: halo + 1, width: stem, height: H - (halo + 1) * 2)).fill()
            NSBezierPath(rect: NSRect(x: midX - cap / 2, y: halo, width: cap, height: 2)).fill()
            NSBezierPath(rect: NSRect(x: midX - cap / 2, y: H - halo - 2, width: cap, height: 2)).fill()
        }
        paint(stemW + halo * 2, capL + halo * 2, NSColor.white)
        paint(stemW, capL, NSColor.black)
        img.unlockFocus()
        let cursor = NSCursor(image: img, hotSpot: NSPoint(x: midX, y: H / 2))
        caretCache[width] = cursor
        return cursor
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        baseDraw.draw(in: bounds)
        for (i, shape) in shapes.enumerated() {
            renderShape(shape)
            if i == selectedIndex {
                drawSelectionIndicator(for: shape)
            }
        }
        if let p = inProgress { renderShape(p) }

        if let field = textField {
            let rect = field.frame.insetBy(dx: 1, dy: 1)
            NSColor.controlAccentColor.setStroke()
            let dashed = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            dashed.lineWidth = 1.5
            dashed.setLineDash([4, 3], count: 2, phase: 0)
            dashed.stroke()
        }
    }

    private func drawSelectionIndicator(for shape: AnnotationShape) {
        let rect: CGRect
        if shape.kind == .number {
            let d = shape.fontSize * 1.4 + 8
            rect = CGRect(x: shape.start.x - d / 2, y: shape.start.y - d / 2,
                          width: d, height: d)
        } else if shape.kind == .text {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: shape.fontSize)]
            let sz = NSAttributedString(string: shape.text, attributes: attrs).size()
            rect = CGRect(x: shape.start.x - 4, y: shape.start.y - 4,
                          width: max(sz.width + 8, 20), height: max(sz.height + 8, shape.fontSize + 6))
        } else {
            rect = shape.rect.insetBy(dx: -6, dy: -6)
        }
        NSColor.controlAccentColor.setStroke()
        let dashed = NSBezierPath(rect: rect)
        dashed.lineWidth = 1.5
        dashed.setLineDash([4, 3], count: 2, phase: 0)
        dashed.stroke()
    }

    private func hitShape(at p: CGPoint) -> Int? {
        for i in shapes.indices.reversed() {
            let s = shapes[i]
            let hit: Bool
            switch s.kind {
            case .rect, .ellipse, .mosaic:
                hit = s.rect.insetBy(dx: -4, dy: -4).contains(p)
            case .line, .arrow, .highlighter:
                hit = dist(p, to: s.start, s.end) <= max(6, s.strokeWidth / 2 + 3)
            case .text:
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: s.fontSize)]
                let sz = NSAttributedString(string: s.text, attributes: attrs).size()
                hit = CGRect(x: s.start.x - 4, y: s.start.y - 4,
                             width: max(sz.width + 8, 20), height: s.fontSize + 8).contains(p)
            case .number:
                hit = hypot(p.x - s.start.x, p.y - s.start.y) <= s.fontSize * 1.1
            }
            if hit { return i }
        }
        return nil
    }

    private func dist(_ p: CGPoint, to a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private func textShapeIndex(at p: CGPoint) -> Int? {
        for i in shapes.indices.reversed() where shapes[i].kind == .text {
            let s = shapes[i]
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: s.fontSize)]
            let size = NSAttributedString(string: s.text, attributes: attrs).size()
            let w = max(size.width + 8, 20), h = max(size.height + 8, s.fontSize + 6)
            if CGRect(x: s.start.x - 4, y: s.start.y - 4, width: w + 8, height: h + 8).contains(p) {
                return i
            }
        }
        return nil
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        if textField != nil {
            commitTextEditor()
            swallowCommitClick = true
        }
        if swallowCommitClick {
            swallowCommitClick = false
            needsDisplay = true
            return
        }

        if event.clickCount == 2, let idx = textShapeIndex(at: p) {
            beginText(at: shapes[idx].start, editingIndex: idx)
            return
        }
        if event.clickCount == 1, let idx = hitShape(at: p) {
            selectedIndex = idx
            selectTool(shapes[idx].kind)
            selectionChanged()
            needsDisplay = true
            if moveKinds.contains(shapes[idx].kind) {
                moveIndex = idx
                moveDown = p
                moveStart0 = shapes[idx].start
                moveEnd0 = shapes[idx].end
                movePushed = false
            }
            return
        }
        // Single-click on empty space clears the selection. For drag-drawn tools, keep going
        // so the same drag that deselected can start drawing. Text/number need a fresh click.
        if event.clickCount == 1, selectedIndex != nil {
            selectedIndex = nil
            selectionChanged()
            needsDisplay = true
            if currentKind == .text || currentKind == .number {
                return
            }
        }

        guard event.clickCount == 1 else {
            needsDisplay = true
            return
        }
        guard hasActiveTool else {
            needsDisplay = true
            return
        }

        let color = strokeColor
        switch currentKind {
        case .text:
            beginText(at: p, editingIndex: nil)
        case .number:
            pushState()
            let n = (shapes.filter { $0.kind == .number }.count) + 1
            shapes.append(AnnotationShape(kind: .number, start: p, end: p,
                                          color: color, fontSize: textFontSize, number: n))
            needsDisplay = true
        default:
            var shape = AnnotationShape(kind: currentKind, start: p, end: p,
                                        color: color, strokeWidth: strokeWidth, opacity: 1)
            if Self.outlineKinds.contains(currentKind) { shape.dashed = lineDashed }
            inProgress = shape
            dragStart = p
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let mi = moveIndex, let md = moveDown {
            if !movePushed { pushState(); movePushed = true }
            let dx = p.x - md.x, dy = p.y - md.y
            shapes[mi].start = CGPoint(x: moveStart0.x + dx, y: moveStart0.y + dy)
            shapes[mi].end = CGPoint(x: moveEnd0.x + dx, y: moveEnd0.y + dy)
            needsDisplay = true
            return
        }

        guard let start = dragStart, var shape = inProgress else { return }
        var q = p
        if event.modifierFlags.contains(.shift) {
            switch shape.kind {
            case .ellipse: q = constrainingCircle(start, to: q)
            case .line, .arrow: q = constrainingAngle(start, to: q)
            default: break
            }
        }
        if shape.kind == .highlighter {
            q.y = start.y
        }
        shape.start = start
        shape.end = q
        inProgress = shape
        needsDisplay = true
    }

    private func constrainingCircle(_ anchor: CGPoint, to p: CGPoint) -> CGPoint {
        let side = max(abs(p.x - anchor.x), abs(p.y - anchor.y))
        let sx: CGFloat = (p.x - anchor.x) >= 0 ? 1 : -1
        let sy: CGFloat = (p.y - anchor.y) >= 0 ? 1 : -1
        return CGPoint(x: anchor.x + sx * side, y: anchor.y + sy * side)
    }

    private func constrainingAngle(_ anchor: CGPoint, to p: CGPoint) -> CGPoint {
        let dx = p.x - anchor.x, dy = p.y - anchor.y
        let len = hypot(dx, dy)
        guard len > 0 else { return p }
        var angle = atan2(dy, dx)
        let degrees = round(angle * 180 / .pi / 45) * 45
        angle = degrees * .pi / 180
        return CGPoint(x: anchor.x + len * cos(angle), y: anchor.y + len * sin(angle))
    }

    override func mouseUp(with event: NSEvent) {
        if moveIndex != nil {
            moveIndex = nil
            moveDown = nil
        }
        if var shape = inProgress {
            if shape.kind == .highlighter { shape.end.y = shape.start.y }
            if shape.rect.width < 1 && shape.rect.height < 1 {
                inProgress = nil; needsDisplay = true; dragStart = nil; return
            }
            pushState()
            shapes.append(shape)
            inProgress = nil
            dragStart = nil
            needsDisplay = true
        }
    }
}

/// Top toolbar.
final class ToolbarView: NSView {
    var onSelectTool: ((AnnotationShape.Kind) -> Void)?
    var onColor: ((NSColor) -> Void)?
    var onWidth: ((CGFloat) -> Void)?
    var onFontSize: ((CGFloat) -> Void)?
    var onLineStyle: ((Bool) -> Void)?
    var onSave: (() -> Void)?
    var onPanelColorSeed: (() -> NSColor)?

    private var fontPop: NSPopUpButton?
    private var fontLabel: NSTextField?
    private var linePop: NSPopUpButton?
    private var widthPop: NSPopUpButton?
    private var colorButton: NSButton?

    private static let outlineKinds: Set<AnnotationShape.Kind> = [.rect, .ellipse, .arrow, .line]

    func setFontControlsVisible(_ visible: Bool) {
        fontPop?.isHidden = !visible
        fontLabel?.isHidden = !visible
    }

    func setWidthDisplay(_ value: CGFloat) {
        widthPop?.selectItem(withTitle: String(Int(value.rounded())))
    }

    func setActiveTool(_ kind: AnnotationShape.Kind, lineDashed: Bool) {
        activeKind = kind
        configureStyleControls(tool: kind, lineDashed: lineDashed)
        setFontControlsVisible(kind == .text || kind == .number)
    }

    func setNoTool() {
        activeKind = nil
        widthPop?.isHidden = true
        linePop?.isHidden = true
        colorButton?.isHidden = true
        fontPop?.isHidden = true
        fontLabel?.isHidden = true
    }

    func configureStyleControls(tool: AnnotationShape.Kind, lineDashed: Bool) {
        let showLine = Self.outlineKinds.contains(tool)
        let showWidth = strokeWidthKinds.contains(tool)
        linePop?.isHidden = !showLine
        widthPop?.isHidden = !showWidth
        colorButton?.isHidden = false
        if showLine { linePop?.selectItem(at: lineDashed ? 1 : 0) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        for (kind, btn) in toolButtons where kind == activeKind {
            let r = btn.convert(btn.bounds, to: self).insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            (NSColor.controlColor.blended(withFraction: 0.55, of: .black) ?? NSColor.systemGray).setFill()
            path.fill()
        }
        super.draw(dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        refreshSelection()
    }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let items: [(AnnotationShape.Kind, String)] = [
            (.rect, "rectangle"), (.ellipse, "circle"), (.arrow, "arrow.right"),
            (.line, "line.diagonal"), (.highlighter, "highlighter"),
            (.text, "textformat"), (.number, "number"), (.mosaic, "square.grid.3x3")
        ]
        for (kind, sym) in items {
            let b = NSButton(title: "", target: nil, action: nil)
            b.bezelStyle = .texturedRounded
            b.isBordered = false
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
            b.refusesFirstResponder = true
            b.focusRingType = .none
            b.target = self
            b.action = #selector(toolClicked(_:))
            objc_setAssociatedObject(b, &toolKindKey, kind, .OBJC_ASSOCIATION_RETAIN)
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: 32),
                b.heightAnchor.constraint(equalToConstant: 28)
            ])
            stack.addArrangedSubview(b)
            toolButtons.append((kind, b))
        }

        let colorBtn = NSButton(title: "", target: self, action: #selector(colorClicked))
        colorBtn.bezelStyle = .texturedRounded
        colorBtn.isBordered = false
        colorBtn.focusRingType = .none
        colorBtn.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
        colorBtn.contentTintColor = .labelColor
        NSLayoutConstraint.activate([
            colorBtn.widthAnchor.constraint(equalToConstant: 32),
            colorBtn.heightAnchor.constraint(equalToConstant: 28)
        ])
        stack.addArrangedSubview(colorBtn)
        colorButton = colorBtn

        let widthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        widthPopup.addItems(withTitles: ["1", "2", "3", "5", "8", "12", "16", "18", "24", "36", "48", "72"])
        widthPopup.selectItem(withTitle: "3")
        widthPopup.target = self
        widthPopup.action = #selector(widthChanged(_:))
        widthPopup.widthAnchor.constraint(equalToConstant: 64).isActive = true
        stack.addArrangedSubview(widthPopup)
        self.widthPop = widthPopup

        let lpop = NSPopUpButton(frame: .zero, pullsDown: false)
        lpop.addItems(withTitles: ["实线", "虚线"])
        lpop.selectItem(at: 0)
        lpop.target = self
        lpop.action = #selector(lineStyleChanged(_:))
        lpop.isHidden = true
        lpop.widthAnchor.constraint(equalToConstant: 76).isActive = true
        stack.addArrangedSubview(lpop)
        self.linePop = lpop

        let sizeLabel = NSTextField(labelWithString: "字号")
        sizeLabel.font = NSFont.systemFont(ofSize: 12)
        sizeLabel.isHidden = true
        stack.addArrangedSubview(sizeLabel)
        self.fontLabel = sizeLabel

        let fpop = NSPopUpButton(frame: .zero, pullsDown: false)
        fpop.addItems(withTitles: ["12", "16", "20", "24", "32", "40", "48", "60"])
        fpop.selectItem(withTitle: "20")
        fpop.target = self
        fpop.action = #selector(fontSizeChanged(_:))
        fpop.isHidden = true
        fpop.widthAnchor.constraint(equalToConstant: 60).isActive = true
        stack.addArrangedSubview(fpop)
        self.fontPop = fpop

        let save = NSButton(title: "保存", target: self, action: #selector(saveClicked))
        save.bezelStyle = .rounded
        save.refusesFirstResponder = true
        save.translatesAutoresizingMaskIntoConstraints = false
        addSubview(save)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: save.leadingAnchor, constant: -12),
            save.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            save.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private var toolButtons: [(AnnotationShape.Kind, NSButton)] = []
    private var colorPanelTargetActive = false

    @objc private func toolClicked(_ sender: NSButton) {
        guard let k = objc_getAssociatedObject(sender, &toolKindKey) as? AnnotationShape.Kind else { return }
        onSelectTool?(k)
    }

    private var activeKind: AnnotationShape.Kind? = nil {
        didSet { refreshSelection() }
    }

    private func refreshSelection() {
        for (kind, btn) in toolButtons {
            let on = kind == activeKind
            btn.contentTintColor = on ? NSColor.labelColor : NSColor.secondaryLabelColor
        }
        needsDisplay = true
    }

    @objc private func colorClicked() {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        colorPanelTargetActive = true
        panel.showsAlpha = true
        if activeKind == .highlighter {
            let base = onPanelColorSeed?() ?? NSColor.black
            panel.color = base.withAlphaComponent(0.5)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func detachColorPanelTarget() {
        guard colorPanelTargetActive else { return }
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        colorPanelTargetActive = false
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onColor?(sender.color)
        // Keep the highlighter's panel opacity slider pinned at 50% after each pick.
        if activeKind == .highlighter {
            let centered = sender.color.withAlphaComponent(0.5)
            DispatchQueue.main.async {
                if abs(sender.color.alphaComponent - 0.5) > 0.001 {
                    sender.color = centered
                }
            }
        }
    }

    @objc private func widthChanged(_ sender: NSPopUpButton) {
        onWidth?(CGFloat(sender.titleOfSelectedItem.flatMap(Double.init) ?? 3))
    }
    @objc private func fontSizeChanged(_ sender: NSPopUpButton) {
        onFontSize?(CGFloat(sender.titleOfSelectedItem.flatMap(Double.init) ?? 20))
    }
    @objc private func lineStyleChanged(_ sender: NSPopUpButton) {
        onLineStyle?(sender.indexOfSelectedItem == 1)
    }
    @objc private func saveClicked() { onSave?() }
}
