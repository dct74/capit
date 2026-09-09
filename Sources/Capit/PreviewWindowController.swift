import Cocoa

/// The bottom-right preview thumbnail shown after a screenshot: fades in near the bottom-right
/// corner, draggable, fades away after a few seconds, and a click opens the annotation editor.
final class PreviewWindowController: NSObject {
    private var panel: NSPanel?
    private let image: CGImage
    private let fileURL: URL?
    private let screen: NSScreen

    private var downPoint: CGPoint?
    private var moved = false
    private var dismissed = false
    private var dismissTimer: Timer?

    var onOpen: ((CGImage, URL?) -> Void)?
    var onExpire: ((CGImage, URL?) -> Void)?
    static let displayDuration: TimeInterval = 4.0

    init(image: CGImage, fileURL: URL?, screen: NSScreen) {
        self.image = image
        self.fileURL = fileURL
        self.screen = screen
        super.init()
    }

    func show() {
        let sf = screen.frame
        let size = NSSize(width: sf.width / 8, height: sf.height / 8)

        let margin: CGFloat = 0
        let x = sf.maxX - margin - size.width
        let y = sf.minY + margin
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)

        let p = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.animationBehavior = .none
        p.alphaValue = 0
        p.isMovableByWindowBackground = false

        let view = PreviewView(image: image)
        view.controller = self
        p.contentView = view
        panel = p

        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 1
        }

        dismissTimer = Timer.scheduledTimer(withTimeInterval: Self.displayDuration,
                                            repeats: false) { [weak self] _ in
            self?.timeout()
        }
    }

    private func timeout() {
        guard !dismissed else { return }
        onExpire?(image, fileURL)
        dismiss()
    }

    /// Lands a still-pending (unclicked) preview's capture and hides it. Called when a newer
    /// capture replaces this preview so the older capture isn't lost and only one preview is
    /// ever on screen.
    func finalizePending() {
        guard !dismissed else { return }
        onExpire?(image, fileURL)
        dismiss()
    }

    private func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        dismissTimer?.invalidate()
        dismissTimer = nil
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            self.panel?.animator().alphaValue = 0
        } completionHandler: {
            self.panel?.orderOut(nil)
            self.panel = nil
            if PreviewPresenter.shared.active === self {
                PreviewPresenter.shared.active = nil
            }
        }
    }

    func mouseDown(_ point: CGPoint) {
        downPoint = point
        moved = false
    }

    func mouseDragged(_ point: CGPoint) {
        guard let down = downPoint, let p = panel else { return }
        var origin = p.frame.origin
        origin.x += point.x - down.x
        origin.y += point.y - down.y
        p.setFrameOrigin(origin)
        moved = true
    }

    func mouseUp(_ point: CGPoint) {
        if !moved {
            dismiss()
            onOpen?(image, fileURL)
        }
        downPoint = nil
    }
}

/// Keeps the active preview alive until it is dismissed.
final class PreviewPresenter {
    static let shared = PreviewPresenter()
    private init() {}
    var active: PreviewWindowController?

    func present(image: CGImage, fileURL: URL?, screen: NSScreen,
                 onExpire: ((CGImage, URL?) -> Void)? = nil,
                 onOpen: @escaping (CGImage, URL?) -> Void) {
        // Only one preview at a time: land + dismiss any still-pending one first.
        if let prev = active {
            prev.finalizePending()
        }
        let c = PreviewWindowController(image: image, fileURL: fileURL, screen: screen)
        c.onExpire = onExpire
        c.onOpen = onOpen
        active = c
        c.show()
    }
}

/// Draws the rounded, softly-shadowed thumbnail and forwards mouse events.
private final class PreviewView: NSView {
    weak var controller: PreviewWindowController?
    private let image: CGImage

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds

        let img = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width),
                                                       height: CGFloat(image.height)))
        let iw = img.size.width, ih = img.size.height
        guard iw > 0, ih > 0 else { return }
        let scale = min(rect.width / iw, rect.height / ih)
        let dw = iw * scale, dh = ih * scale
        let drawRect = NSRect(x: rect.midX - dw / 2, y: rect.midY - dh / 2,
                              width: dw, height: dh)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()

        NSBezierPath(roundedRect: drawRect, xRadius: 10, yRadius: 10).addClip()
        img.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1)
    }

    override func mouseDown(with event: NSEvent) {
        controller?.mouseDown(convert(event.locationInWindow, from: nil))
    }
    override func mouseDragged(with event: NSEvent) {
        controller?.mouseDragged(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        controller?.mouseUp(convert(event.locationInWindow, from: nil))
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
