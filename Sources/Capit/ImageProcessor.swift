import CoreGraphics

/// Post-processing applied to captured images before saving.
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
        // CoreGraphics only, deliberately: this runs on a background task (the capture path) and
        // AppKit drawing is not safe there. Verified byte-identical to the NSImage/NSBitmapImageRep
        // version it replaced, anti-aliased corner edges included.
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        let rect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        ctx.clear(rect)
        ctx.interpolationQuality = .high
        ctx.addPath(SquirclePath.cgPath(in: rect, radius: radius, exponent: exponent))
        ctx.clip()
        ctx.draw(image, in: rect)
        return ctx.makeImage()
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
    /// The decoration applied to a capture on its way to disk: continuous corners, then the native
    /// looking drop shadow.
    ///
    /// Deliberately a *write-time* step rather than something done at capture. Applying it at
    /// capture puts the shadow's transparent padding inside the document the editor works on,
    /// which means annotations can be drawn into the padding, and every full-document effect has
    /// to special-case "the picture but not its shadow". Applying it last keeps the editor's
    /// coordinate space equal to the picture, and the shadow then wraps the finished result —
    /// annotations included — instead of the picture as it looked before being annotated.
    static func finished(_ image: CGImage, radiusRatio: CGFloat = cornerRadiusRatio) -> CGImage {
        let rounded = applyingRoundedCorners(to: image, radiusRatio: radiusRatio) ?? image
        return windowWithShadow(content: rounded) ?? rounded
    }

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

        // CoreGraphics only (see applyingRoundedCorners). The clear matters: the far corners of the
        // shadow padding are never painted, so they must start transparent rather than hold whatever
        // the buffer happened to contain.
        guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: content.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.clear(CGRect(x: 0, y: 0, width: outW, height: outH))
        ctx.interpolationQuality = .high

        let contentRect = CGRect(x: CGFloat(sidePad), y: CGFloat(bottomPad),
                                 width: CGFloat(cw), height: CGFloat(ch))
        ctx.saveGState()
        // Same numbers as the NSShadow it replaced: blurred shadow, offset down, 56% black.
        ctx.setShadow(offset: CGSize(width: 0, height: -blur * 0.55), blur: blur,
                      color: CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     components: [0, 0, 0, opacity])!)
        ctx.draw(content, in: contentRect)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// Small preview thumbnail (never upscales). The full-resolution PNG already lives on disk,
    /// so the on-screen preview uses this instead of retaining a full-size screenshot.
    /// 2048 px covers the preview size (1/8 screen) even on 6K/8K Retina displays.
    static func thumbnail(from image: CGImage, maxPixel: Int = 2048) -> CGImage? {
        let w = image.width, h = image.height
        let longest = max(w, h)
        guard longest > 0 else { return nil }
        let scale = min(1.0, CGFloat(maxPixel) / CGFloat(longest))
        let tw = max(1, Int((CGFloat(w) * scale).rounded()))
        let th = max(1, Int((CGFloat(h) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: tw, height: th,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage()
    }
}
