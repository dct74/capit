import AppKit
import CoreGraphics

/// Post-processing applied to captured images before saving.
/// Uses AppKit (NSBitmapImageRep + NSImage) so orientation matches the code path
/// that already produces correctly-oriented PNGs — avoiding CGContext flip bugs.
enum ImageProcessor {

    /// Visual calibration knobs.
    static let cornerRadiusRatio: CGFloat = 0.042    // region/window screenshots
    static let cornerExponent: CGFloat = 3.0          // ~Apple continuous curve feel
    static let minCornerRadiusPx: CGFloat = 14

    /// Continuous-corner (squircle) rounding, in the image's own orientation.
    static func applyingRoundedCorners(to image: CGImage,
                                       radiusRatio: CGFloat = cornerRadiusRatio,
                                       exponent: CGFloat = cornerExponent) -> CGImage? {
        let w = image.width, h = image.height
        let shorter = CGFloat(min(w, h))
        let radius = max(minCornerRadiusPx, shorter * radiusRatio)

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        gc.imageInterpolation = .high
        gc.shouldAntialias = true

        let rect = NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        let clip = SquirclePath.path(in: rect, radius: radius, exponent: exponent)
        clip.addClip()

        let nsImage = NSImage(cgImage: image, size: rect.size)
        nsImage.draw(in: rect)

        gc.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// Heuristic: true when `image` already looks like a rounded-corner + shadowed "card"
    /// (our own output, or a native macOS window screenshot), so it should not be processed
    /// again. Requires an alpha channel, fully transparent image corners, an opaque centre,
    /// content that fills most of the frame, and transparent *content* corners (rounded).
    static func alreadyRoundedOrShadowed(_ image: CGImage) -> Bool {
        let ai = image.alphaInfo
        guard ai != .none, ai != .noneSkipLast, ai != .noneSkipFirst else { return false }

        let maxSide = 256
        let scale = min(1.0, CGFloat(maxSide) / CGFloat(max(image.width, image.height)))
        let w = max(8, Int(CGFloat(image.width) * scale))
        let h = max(8, Int(CGFloat(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let raw = ctx.data else { return false }
        let p = raw.assumingMemoryBound(to: UInt8.self)
        func a(_ x: Int, _ y: Int) -> Int { Int(p[(y * w + x) * 4 + 3]) }

        // Image corners must be transparent.
        let opaque = 40
        guard a(0, 0) < opaque, a(w - 1, 0) < opaque, a(0, h - 1) < opaque, a(w - 1, h - 1) < opaque else { return false }
        // ...and there must be actual content in the middle.
        guard a(w / 2, h / 2) >= opaque else { return false }

        // Content bounding box (first opaque pixel from each side).
        func rowHasOpaque(_ y: Int) -> Bool { (0..<w).contains { a($0, y) >= opaque } }
        func colHasOpaque(_ x: Int) -> Bool { (0..<h).contains { a(x, $0) >= opaque } }
        guard let bx0 = (0..<w).first(where: colHasOpaque),
              let bx1 = (0..<w).reversed().first(where: colHasOpaque),
              let by0 = (0..<h).first(where: rowHasOpaque),
              let by1 = (0..<h).reversed().first(where: rowHasOpaque) else { return false }

        let coverW = CGFloat(bx1 - bx0 + 1) / CGFloat(w)
        let coverH = CGFloat(by1 - by0 + 1) / CGFloat(h)
        guard coverW >= 0.70, coverH >= 0.50 else { return false }

        // The content's own corners must be transparent → it is a rounded rectangle
        // (not, say, a square image with a transparent border).
        guard a(bx0, by0) < opaque, a(bx1, by0) < opaque,
              a(bx0, by1) < opaque, a(bx1, by1) < opaque else { return false }
        return true
    }

    /// Adds a native-style drop shadow around an already-rounded image on a padded
    /// transparent canvas.
    static func windowWithShadow(content: CGImage,
                                 multiplier: CGFloat = 1.0) -> CGImage? {
        let cw = content.width, ch = content.height
        let W = CGFloat(cw)
        let blur = max(34.0, min(170.0, W * 0.038 * multiplier))
        let opacity: CGFloat = 0.56
        let sidePad = Int(blur * 1.5)
        let topPad = Int(blur * 2.0)
        let bottomPad = Int(blur * 3.0)
        let outW = cw + sidePad * 2
        let outH = ch + topPad + bottomPad

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: outW, pixelsHigh: outH,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        gc.imageInterpolation = .high

        let contentRect = NSRect(x: CGFloat(sidePad), y: CGFloat(bottomPad),
                                 width: CGFloat(cw), height: CGFloat(ch))

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(opacity)
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = NSSize(width: 0, height: -blur * 0.55)
        shadow.set()

        let nsImage = NSImage(cgImage: content, size: contentRect.size)
        nsImage.draw(in: contentRect)

        gc.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}
