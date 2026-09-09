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
