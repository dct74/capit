import AppKit
import CoreGraphics

/// Apple "continuous"/squircle corner path generator.
/// Each corner is a sampled quarter superellipse arc (|x/a|^n + |y/b|^n = 1).
/// Exponent n: 2 = circle; n≈3–5 approximates macOS continuous corners.
enum SquirclePath {

    /// Returns a CGPath enclosing the rounded-rectangle interior.
    static func cgPath(in rect: CGRect, radius: CGFloat, exponent: CGFloat,
                       samplesPerCorner: Int = 64) -> CGPath {
        let w = Double(rect.width), h = Double(rect.height)
        let r = Double(max(0, min(radius, CGFloat(min(rect.width, rect.height)) / 2)))
        guard r > 0, w > 0, h > 0 else { return CGPath(rect: rect, transform: nil) }
        let n = Double(max(0.1, exponent))
        let steps = max(4, samplesPerCorner)

        let corners: [(Double, Double, Double, Double, Double, Double)] = [
            (rect.minX, rect.minY, 1, 0, 0, 1),   // bottom-left
            (rect.minX, rect.maxY, 0, -1, 1, 0),  // top-left
            (rect.maxX, rect.maxY, -1, 0, 0, -1), // top-right
            (rect.maxX, rect.minY, 0, 1, -1, 0),  // bottom-right
        ]

        let path = CGMutablePath()
        var first = true
        func emit(_ x: Double, _ y: Double) {
            if first { path.move(to: CGPoint(x: x, y: y)); first = false }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }

        let recip = 1.0 / n
        for corner in corners {
            let (cx, cy, dux, duy, dvx, dvy) = corner
            for i in 0...steps {
                let k = Double(i) / Double(steps)
                let u = r * (1 - k)
                let v = r * (1 - pow(1 - pow(k, n), recip))
                let x = cx + dux * u + dvx * v
                let y = cy + duy * u + dvy * v
                emit(x, y)
            }
        }
        path.closeSubpath()
        return path
    }

    /// NSBezierPath variant (for AppKit drawing).
    static func path(in rect: CGRect, radius: CGFloat, exponent: CGFloat,
                     samplesPerCorner: Int = 64) -> NSBezierPath {
        let cg = cgPath(in: rect, radius: radius, exponent: exponent,
                        samplesPerCorner: samplesPerCorner)
        let bp = NSBezierPath()
        cg.applyWithBlock { element in
            let pts = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint: bp.move(to: pts[0])
            case .addLineToPoint: bp.line(to: pts[0])
            case .addQuadCurveToPoint: bp.curve(to: pts[1], controlPoint1: pts[0], controlPoint2: pts[0])
            case .addCurveToPoint: bp.curve(to: pts[2], controlPoint1: pts[0], controlPoint2: pts[1])
            case .closeSubpath: bp.close()
            @unknown default: break
            }
        }
        return bp
    }
}
