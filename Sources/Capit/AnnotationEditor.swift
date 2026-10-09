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

/// Fluorescent-marker ink strength. Kept this high because the highlighter is drawn with a
/// multiply blend: dark content stays dark and legible instead of being washed out, so the
/// ink can be vivid without destroying whatever is underneath it. With source-over this
/// value would have to stay near 0.5 to keep text readable (see the ink comment in renderShape).
private let highlighterAlpha: CGFloat = 0.85

// MARK: - Highlighter marker tuning

/// The marker's edge is a real blur, produced by stroking the core and letting Core Graphics
/// blur its shadow to fill the nib footprint (see drawHighlighter). `coreRatio` is the fraction
/// of the stroke width drawn at full density; the rest is the wet edge the blur grows into.
///
/// This replaced eight nested strokes of decreasing width, which approximated the falloff as a
/// staircase: at 8 steps the alpha jumped 0.105 between bands, and because the bands were
/// fractions of the half-width those steps spread further apart the thicker the stroke got —
/// so thick strokes showed visible concentric bands again. A blurred shadow makes the falloff
/// continuous and identical at every width, and costs one pass instead of eight.
private let highlighterCoreRatio: CGFloat = 0.62
/// Blur radius as a fraction of the stroke width, with an absolute floor: ink wicks over a
/// fibre-scale distance, not a proportional one, so thin strokes still need a soft edge.
private let highlighterEdgeBlurRatio: CGFloat = 0.32
private let highlighterEdgeBlurMin: CGFloat = 2.0

/// How far the ink boundary wanders sideways, as a fraction of the stroke width, and over what
/// distance. A geometrically perfect edge is the clearest giveaway that a stroke is synthetic —
/// ink follows the paper's fibres, so the boundary should be slightly uneven. The wobble is
/// low-frequency (period ~10 px) so it reads as wicking rather than as raggedness.
private let highlighterCombAmplitude: CGFloat = 0.02
private let highlighterCombPeriod: CGFloat = 10

/// Peak strength of the paper grain, i.e. how much of the ink the roughest speckle may thin
/// out (0 = flat ink, 1 = grain can erase the ink completely).
///
/// Capped by the density budget rather than by taste: the grain is applied by removing ink, so
/// it drags the mean density down by roughly half this value, and the passes that build the
/// cross-section cannot exceed alpha 1 to compensate. At 0.42 the mean loss (~0.22) exceeded
/// `highlighterAlpha`'s remaining headroom (0.15), so the profile saturated and the marker
/// silently plateaued at ~0.78 no matter what the knob said.
private let highlighterGrainStrength: CGFloat = 0.26
/// Exponential smoothing applied to the incoming pointer while drawing freehand. Most of the
/// visible smoothing actually comes from rendering the samples as a Catmull-Rom curve rather
/// than a polyline: over the same samples, edge jaggedness measures ~7 px as a polyline, ~1.3 px
/// through the spline, and ~1.0 px through the spline over these smoothed samples. Set to 1 to
/// disable the filter entirely if the slight trailing lag is unwelcome.
private let highlighterSmoothing: CGFloat = 0.4

/// Deterministic RNG so the grain tile is identical on every run — the live canvas, the
/// exported PNG and the verification harness all see exactly the same texture.
private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
}

/// Seamless value noise. The lattice indices wrap, so the tile can be drawn with
/// `byTiling: true` without visible seams where one copy meets the next.
private func periodicValueNoise(size: Int, lattice: Int, seed: UInt64) -> [Double] {
    var rng = SplitMix64(state: seed)
    let l = max(2, lattice)
    var grid = [Double](repeating: 1, count: l * l)
    for i in grid.indices { grid[i] = rng.unit() }
    @inline(__always) func g(_ x: Int, _ y: Int) -> Double {
        grid[((y % l) + l) % l * l + (((x % l) + l) % l)]
    }

    var out = [Double](repeating: 1, count: size * size)
    let cells = Double(l)
    let n = Double(size)
    for y in 0..<size {
        let fy = Double(y) / n * cells
        let y0 = Int(fy), ty = fy - Double(y0)
        let sy = ty * ty * (3 - 2 * ty)             // smoothstep, so no lattice creases
        for x in 0..<size {
            let fx = Double(x) / n * cells
            let x0 = Int(fx), tx = fx - Double(x0)
            let sx = tx * tx * (3 - 2 * tx)
            let a = g(x0, y0) + (g(x0 + 1, y0) - g(x0, y0)) * sx
            let b = g(x0, y0 + 1) + (g(x0 + 1, y0 + 1) - g(x0, y0 + 1)) * sx
            out[y * size + x] = a + (b - a) * sy
        }
    }
    return out
}

/// Rescales to 0…1 so octaves with different variance (a box blur shrinks it) mix evenly.
private func normalized(_ a: [Double]) -> [Double] {
    guard let lo = a.min(), let hi = a.max(), hi > lo else { return a.map { _ in 0.5 } }
    return a.map { ($0 - lo) / (hi - lo) }
}

/// Box blur over a torus, so the tile still seams correctly after blurring.
private func torusBlur(_ src: [Double], size: Int) -> [Double] {
    var out = [Double](repeating: 0, count: size * size)
    for y in 0..<size {
        for x in 0..<size {
            var sum = 0.0
            for dy in -1...1 {
                for dx in -1...1 {
                    sum += src[((y + dy + size) % size) * size + ((x + dx + size) % size)]
                }
            }
            out[y * size + x] = sum / 9
        }
    }
    return out
}

/// The paper grain used to thin the highlighter's ink unevenly. Three octaves, because real
/// paper does not have a single feature size: per-pixel speckle, ~3 px fibre clumps, and a
/// slow ~16 px mottle. Only the alpha channel is meaningful — drawn with `.destinationOut`.
///
/// Note the fine octave is plain white noise and the mottle uses a deliberately coarse lattice:
/// value noise whose lattice is close to the pixel pitch aliases into visible streaks.
private struct GrainTile {
    let image: CGImage
    /// Mean of the tile's alpha. The grain only ever *removes* ink, so the core has to be
    /// drawn denser to compensate or the marker would come out weaker than `highlighterAlpha`.
    let meanAlpha: CGFloat
}

private func makeHighlighterGrainTile(size: Int) -> GrainTile? {
    let count = size * size
    var rng = SplitMix64(state: 0xC0FF_EE01_5EED)
    let speckle = (0..<count).map { _ in rng.unit() }
    let fibre = normalized(torusBlur(speckle, size: size))
    let mottle = normalized(periodicValueNoise(size: size, lattice: max(4, size / 16),
                                               seed: 0xB29F_1E33))
    let fine = normalized(speckle)

    var pixels = [UInt8](repeating: 0, count: count * 4)
    var alphaSum = 0.0
    for i in 0..<count {
        var v = fine[i] * 0.25 + fibre[i] * 0.35 + mottle[i] * 0.40
        v = min(max((v - 0.5) * 1.7 + 0.5, 0), 1)     // push contrast around mid-grey
        let a = v * highlighterGrainStrength
        alphaSum += a
        let byte = UInt8((a * 255).rounded())
        let o = i * 4
        // Premultiplied white: R=G=B=A keeps the bitmap valid. Only alpha is consumed, so
        // the tile works as a per-pixel knockout mask for the ink drawn into the layer.
        pixels[o] = byte; pixels[o + 1] = byte; pixels[o + 2] = byte; pixels[o + 3] = byte
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                              provider: provider, decode: nil,
                              shouldInterpolate: true, intent: .defaultIntent) else { return nil }
    return GrainTile(image: image, meanAlpha: CGFloat(alphaSum / Double(count)))
}

/// Built once, on first use.
private let highlighterGrain: GrainTile? = makeHighlighterGrainTile(size: 256)

/// Adds `pts` to `path` as a smooth curve through every sample (Catmull-Rom converted to
/// cubic Béziers). A two-point stroke stays an exact straight line, so the default
/// horizontal swipe renders byte-identically to before freehand existed.
private func addSmoothStroke(_ pts: [CGPoint], to path: CGMutablePath) {
    guard pts.count >= 2 else { return }
    path.move(to: pts[0])
    guard pts.count > 2 else { path.addLine(to: pts[1]); return }
    for i in 0..<(pts.count - 1) {
        let p0 = pts[max(i - 1, 0)], p1 = pts[i]
        let p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
        path.addCurve(to: p2,
                      control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                      control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
    }
}

/// Resamples a polyline to evenly spaced points. The stroker's cost is driven by the number of
/// curve segments it has to flatten, and each band pass pays that cost again — freehand capture
/// records a sample every ~3 screen points, which is far denser than a smooth highlight needs
/// (a long drag reached 2300 segments and made an 11-pass render 5× slower than it had to be).
/// Spacing is tied to the stroke width, and capped so a very long drag cannot blow the budget.
private func resampledStroke(_ pts: [CGPoint], spacing: CGFloat) -> [CGPoint] {
    guard pts.count >= 2 else { return pts }
    var arc: [CGFloat] = [0]
    for i in 1..<pts.count {
        arc.append(arc[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y))
    }
    let total = arc[arc.count - 1]
    guard total > spacing else { return pts }
    let step = max(spacing, total / 500)
    var out: [CGPoint] = [pts[0]]
    var target = step
    var seg = 1
    while target < total && seg < arc.count {
        while seg < arc.count - 1 && arc[seg] < target { seg += 1 }
        let len = arc[seg] - arc[seg - 1]
        let t = len > 0 ? (target - arc[seg - 1]) / len : 0
        out.append(CGPoint(x: pts[seg - 1].x + (pts[seg].x - pts[seg - 1].x) * t,
                           y: pts[seg - 1].y + (pts[seg].y - pts[seg - 1].y) * t))
        target += step
    }
    out.append(pts[pts.count - 1])
    return out
}

/// Drops a stalled run of samples from the end of a freehand path, keeping the point that got
/// furthest instead of the last sample. When the pointer pauses the samples bunch up and wander
/// inside a few pixels; stroking that tangle with a wide nib sweeps a round blob out past where
/// the drag really ended. Detail that small is far below the nib's width, so the stalled samples
/// carry no information — but the *reach* does, which is why the furthest point is kept.
private func prunedTail(_ pts: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
    guard pts.count >= 4, tolerance > 0.01 else { return pts }
    let last = pts[pts.count - 1]
    var cut = pts.count - 1
    while cut > 1, hypot(pts[cut - 1].x - last.x, pts[cut - 1].y - last.y) < tolerance { cut -= 1 }
    guard cut < pts.count - 1 else { return pts }          // nothing stalled
    // Where the drag actually reached: the furthest sample of the stalled run.
    let start = pts[0]
    var reach = pts[pts.count - 1]
    var bestDistance = -1.0
    for i in cut..<pts.count {
        let d = hypot(pts[i].x - start.x, pts[i].y - start.y)
        if d > bestDistance { bestDistance = d; reach = pts[i] }
    }
    // Keep the path up to the stall, then run straight to the reach. The tangled samples in
    // between are dropped rather than kept: stroking them would round-join half a nib-width out
    // past the reach, which is exactly the blob being removed.
    var out = Array(pts[0..<cut])
    out.append(reach)
    return out.count >= 2 ? out : pts
}

/// Prunes both ends: a pause at the start bunches samples the same way.
private func prunedEnds(_ pts: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
    let tail = prunedTail(pts, tolerance: tolerance)
    return prunedTail(tail.reversed(), tolerance: tolerance).reversed()
}

/// Nudges each sample sideways by a small, smooth pseudo-random amount so the ink boundary is
/// slightly uneven instead of a perfect offset curve. Deterministic (an integer hash, not
/// randomness), so the live canvas and the export agree exactly.
private func combedStroke(_ pts: [CGPoint], amplitude: CGFloat, period: CGFloat) -> [CGPoint] {
    guard amplitude > 0.01, pts.count >= 3 else { return pts }
    // smooth 1-D value noise from a cheap integer hash
    func noise(_ t: Double) -> Double {
        let i = Int(t.rounded(.down)), f = t - Double(i)
        func hash(_ n: Int) -> Double {
            var h = UInt64(bitPattern: Int64(n)) &* 0x9E37_79B9_7F4A_7C15
            h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
            h ^= h >> 27
            return Double(h & 0xFFFF) / 65535.0
        }
        let a = hash(i), b = hash(i + 1)
        let u = f * f * (3 - 2 * f)
        return a + (b - a) * u
    }
    var out = pts
    var arc: CGFloat = 0
    for i in 1..<(pts.count - 1) {
        arc += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
        let dx = pts[i + 1].x - pts[i - 1].x, dy = pts[i + 1].y - pts[i - 1].y
        let len = hypot(dx, dy)
        guard len > 0 else { continue }
        // perpendicular to the local tangent
        let nx = -dy / len, ny = dx / len
        let s = (noise(Double(arc / period)) + noise(Double(arc / period) + 7.3) - 1.0) * Double(amplitude)
        out[i] = CGPoint(x: pts[i].x + nx * CGFloat(s), y: pts[i].y + ny * CGFloat(s))
    }
    return out
}

/// Extends a polyline by `pad` past both ends along its end tangents.
private func extendedStroke(_ pts: [CGPoint], by pad: CGFloat) -> [CGPoint] {
    guard pad > 0.01, pts.count >= 2 else { return pts }
    func unit(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
        let dx = to.x - from.x, dy = to.y - from.y
        let len = hypot(dx, dy)
        return len > 0 ? CGPoint(x: dx / len, y: dy / len) : .zero
    }
    let head = pts[0], next = pts[1]
    let tail = pts[pts.count - 1], prev = pts[pts.count - 2]
    let hd = unit(next, head), td = unit(prev, tail)
    var out = [CGPoint(x: head.x + hd.x * pad, y: head.y + hd.y * pad)]
    out += pts
    out.append(CGPoint(x: tail.x + td.x * pad, y: tail.y + td.y * pad))
    return out
}

/// Tiles `image` at its natural pixel size, anchored to the document origin so overlapping
/// strokes share one sheet of paper.
///
/// `CGContext.draw(_:in:byTiling:)` cannot be used here: it scales the image to fill the
/// rectangle before tiling, and because that rectangle is the stroke's bounding box (long and
/// thin) it stretched the grain ~4.5× along the stroke, which showed up as horizontal combing
/// through the ink. Placing the tiles by hand fixes the aspect and keeps the grain square.
private func drawTiled(_ image: CGImage, in bounds: CGRect, into cg: CGContext) {
    let side = CGFloat(image.width)
    guard side > 0 else { return }
    var y = (bounds.minY / side).rounded(.down) * side
    while y < bounds.maxY {
        var x = (bounds.minX / side).rounded(.down) * side
        while x < bounds.maxX {
            cg.draw(image, in: CGRect(x: x, y: y, width: side, height: side))
            x += side
        }
        y += side
    }
}

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
        drawHighlighter(shape, color: color)
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

/// Draws the highlighter as marker ink rather than as a translucent bar: a core at full
/// density whose blurred shadow supplies a continuous wet edge inside the nib's footprint, with
/// paper grain thinning the ink unevenly. One multiply composite onto the paper, so dark content
/// underneath stays dark and legible. Both the live canvas and the export renderer call this, so
/// the saved PNG matches the screen exactly.
private func drawHighlighter(_ shape: AnnotationShape, color: NSColor) {
    guard let cg = NSGraphicsContext.current?.cgContext else {
        // No CG context (not expected): fall back to a plain polyline stroke.
        let fallback = shape.strokePoints
        let path = NSBezierPath()
        path.move(to: fallback[0])
        for p in fallback.dropFirst() { path.line(to: p) }
        path.lineWidth = shape.strokeWidth
        path.lineCapStyle = .butt
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
        return
    }

    let stalled = max(1, shape.strokeWidth * 0.35)
    let pts = resampledStroke(prunedEnds(shape.strokePoints, tolerance: stalled),
                              spacing: max(4, shape.strokeWidth * 0.25))
    let path = CGMutablePath()
    addSmoothStroke(pts, to: path)

    let width = shape.strokeWidth
    let blur = max(highlighterEdgeBlurMin, width * highlighterEdgeBlurRatio)
    // The core is stroked past both ends so the blur has already reached full strength where the
    // footprint clips it. Without that the blur would fade the ends round instead of cutting
    // them off square, which is the one place a marker is abrupt.
    let combed = combedStroke(pts, amplitude: max(0.35, width * highlighterCombAmplitude),
                              period: highlighterCombPeriod)
    let corePath = CGMutablePath()
    addSmoothStroke(extendedStroke(combed, by: blur * 2), to: corePath)

    // The grain only ever removes ink, so ask for slightly more density than the caller wants
    // and let the grain take it back down to the target on average.
    let grainMean = highlighterGrain?.meanAlpha ?? 0
    let density = min(color.alphaComponent / max(1 - grainMean, 0.01), 1)

    // Bounds the transparency layer's buffer (and the tiled grain draw) to the stroke.
    let bounds = shape.rect.insetBy(dx: -width, dy: -width)

    cg.saveGState()
    cg.setBlendMode(.multiply)          // governs how the finished layer meets the paper
    cg.setAlpha(density)                // the layer's overall strength is the density knob
    cg.clip(to: bounds)
    // Clip to the nib's footprint: the shadow's falloff has already decayed to nothing by the
    // time it reaches this boundary, so the clip only decides how far the ink may reach.
    cg.addPath(path.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .round, miterLimit: 10))
    cg.clip()
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    cg.setShadow(offset: .zero, blur: blur, color: color.withAlphaComponent(1).cgColor)
    cg.setStrokeColor(color.withAlphaComponent(1).cgColor)
    cg.setLineWidth(max(1, width * highlighterCoreRatio))
    cg.setLineCap(.butt)
    cg.setLineJoin(.round)
    cg.addPath(corePath)
    cg.strokePath()
    // The shadow must not cast onto the grain pass.
    cg.setShadow(offset: .zero, blur: 0, color: nil)
    // The grain has to be knocked into the ink as a whole, which is exactly why the ink is
    // built in a layer: once alpha has been composited onto the paper there is no way to thin
    // just part of it.
    if let grain = highlighterGrain {
        cg.setBlendMode(.destinationOut)
        drawTiled(grain.image, in: bounds, into: cg)
    }
    cg.endTransparencyLayer()
    cg.restoreGState()
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
    /// Captured freehand path for the highlighter. Empty means "no path": the renderer and the
    /// hit test then fall back to the straight start→end chord. That is what every other kind
    /// relies on, and what a highlighter reduced to a single click ends up with.
    var points: [CGPoint] = []

    /// The polyline the stroke tools draw: the freehand path when one was captured,
    /// otherwise the start→end chord. Always has at least two entries.
    var strokePoints: [CGPoint] {
        points.count >= 2 ? points : [start, end]
    }

    /// Bounding box in document coordinates. A freehand stroke can bow away from the
    /// start→end chord, so every captured point contributes.
    var rect: CGRect {
        var minX = min(start.x, end.x), maxX = max(start.x, end.x)
        var minY = min(start.y, end.y), maxY = max(start.y, end.y)
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// The annotation editor: toolbar (top) + scrollable canvas (bottom).
final class AnnotationEditorController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let canvas: AnnotationCanvasView
    private let toolbar: ToolbarView
    private let image: CGImage
    private let fileURL: URL?
    /// Imported images: saving overwrites the source file, and closing without saving must
    /// NOT overwrite it with the un-annotated capture.
    private let isImported: Bool
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

    init?(image: CGImage, fileURL: URL?, isImported: Bool = false) {
        self.image = image
        self.fileURL = fileURL
        self.isImported = isImported
        docSize = CGSize(width: CGFloat(image.width) / 2,
                         height: CGFloat(image.height) / 2)

        canvas = AnnotationCanvasView(image: image, docSize: docSize)
        toolbar = ToolbarView()

        let screenUnderMouse = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        let screenSize = (screenUnderMouse ?? NSScreen.main)?.frame.size ?? NSSize(width: 1440, height: 900)
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

    /// Brings an already-open editor to the front (used instead of opening a second one).
    func bringToFront() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        toolbar.detachColorPanelTarget()
        // If the user closed without ever saving, land the (un-annotated) capture.
        if !isImported, !didSave && !isSaving && !rawLandingQueued, let url = fileURL {
            rawLandingQueued = true
            let img = image
            CaptureWriter.schedule { try? CapturePipeline.write(image: img, to: url) }
        }
        NSApp.setActivationPolicy(.accessory)
        AnnotationHolder.shared.active = nil
        // Resume the idle auto-quit countdown now that no editor is open.
        IdleAutoQuit.shared.resume()
    }

    /// Called just before the app quits: queues the capture so a quit during editing
    /// doesn't lose it, and the app can wait for the write via `CaptureWriter`.
    func ensureCapturedBeforeQuit() {
        if !isImported, !didSave && !isSaving && !rawLandingQueued, let url = fileURL {
            rawLandingQueued = true
            let img = image
            CaptureWriter.schedule { try? CapturePipeline.write(image: img, to: url) }
        }
    }

    func present() {
        AnnotationHolder.shared.active = self
        // Pause the idle auto-quit while the editor is open so a long annotation session is
        // never terminated mid-edit (which would land only the raw image).
        IdleAutoQuit.shared.pause()
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
                guard !editingText, NSApp.keyWindow === self.window,
                      self.canvas.hasSelection else { return event }
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
        let bytesPerRow = ((w * 4) + 63) & ~63
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        // Back the context with a manually-managed buffer so the finished pixels can be handed
        // to a CGImage without `makeImage()`'s full-size copy (half the memory at save peak).
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * h, alignment: 64)
        guard let ctx = CGContext(data: buffer, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            buffer.deallocate()
            presentSaveFailure(message: "无法创建图像缓冲区。")
            return
        }
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

        guard let out = Self.makeImage(owning: buffer, width: w, height: h,
                                       bytesPerRow: bytesPerRow, colorSpace: colorSpace) else {
            buffer.deallocate()
            presentSaveFailure(message: "无法生成图像。")
            return
        }
        let url: URL
        if let fileURL {
            // Imported JPG/JPEG converts to a PNG next to the source; everything else
            // overwrites its source file.
            let ext = fileURL.pathExtension.lowercased()
            if isImported && (ext == "jpg" || ext == "jpeg") {
                url = fileURL.deletingPathExtension().appendingPathExtension("png")
            } else {
                url = fileURL
            }
        } else {
            url = CapturePipeline.desktopURL()
        }
        isSaving = true
        let snapshot = out
        // Route the encode+write through CaptureWriter so quitting waits for it too.
        CaptureWriter.schedule {
            let outcome: SaveOutcome
            do {
                try CapturePipeline.write(image: snapshot, to: url)
                outcome = .success
            } catch {
                outcome = .failure("无法保存：\(error.localizedDescription)")
            }
            DispatchQueue.main.async { self.finishSave(outcome) }
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
            // Never lose the capture: if nothing was written, land the original image.
            if !didSave {
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

    /// Wraps a manually-managed bitmap buffer in a CGImage without copying. The provider owns
    /// the buffer and frees it when the image (and any encode using it) is released.
    private static func makeImage(owning buffer: UnsafeMutableRawPointer,
                                  width: Int, height: Int, bytesPerRow: Int,
                                  colorSpace: CGColorSpace) -> CGImage? {
        let release: CGDataProviderReleaseDataCallback = { _, data, _ in
            UnsafeMutableRawPointer(mutating: data).deallocate()
        }
        guard let provider = CGDataProvider(dataInfo: nil, data: buffer,
                                            size: bytesPerRow * height,
                                            releaseData: release) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
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
    private var movePoints0: [CGPoint] = []
    private var movePushed = false
    private let moveKinds: Set<AnnotationShape.Kind> =
        [.rect, .ellipse, .line, .arrow, .number, .text, .highlighter, .mosaic]
    /// Upper bound on captured freehand samples; past this the path is decimated
    /// instead of dropping the stroke.
    private static let highlighterMaxPoints = 4096

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
        shapes[i].points = shapes[i].points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
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
                selectedIndex = nil   // the removed index may now point at the wrong shape
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
        .highlighter: NSColor(calibratedRed: 0.90, green: 0.68, blue: 0.0, alpha: highlighterAlpha),
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
        lineDashed = false   // line style falls back to solid when switching tools/shapes
        notifyWidthDisplay()
        onActiveTool?(kind)
        refreshCursorRects()
    }

    private func defaultWidth(for kind: AnnotationShape.Kind) -> CGFloat {
        kind == .highlighter ? 16 : Self.defaultStrokeWidth
    }

    func setCurrentColor(_ color: NSColor) {
        // The highlighter is always the same translucent marker: whatever color is chosen
        // gets its alpha pinned to `highlighterAlpha` (per-kind).
        func sized(_ c: NSColor, for kind: AnnotationShape.Kind) -> NSColor {
            kind == .highlighter ? c.withAlphaComponent(highlighterAlpha) : c
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
        // Selecting only *shows* a shape's width (view only) — it never changes the tool
        // default. Deselecting resets the active width back to the tool default (3 / 16).
        if selectedIndex == nil {
            strokeWidth = defaultWidth(for: currentKind)
        }
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
        guard hasActiveTool else { return .arrow }
        switch currentKind {
        case .highlighter: return Self.highlighterCaret(width: strokeWidth)
        default: return NSCursor.crosshair   // rect/ellipse/arrow/line/text/number/mosaic
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
                hit = dist(p, to: s) <= max(6, s.strokeWidth / 2 + 3)
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

    /// Shortest distance from `p` to a shape's stroke polyline.
    private func dist(_ p: CGPoint, to shape: AnnotationShape) -> CGFloat {
        let pts = shape.strokePoints
        var best = CGFloat.greatestFiniteMagnitude
        for i in 0..<(pts.count - 1) {
            best = min(best, dist(p, to: pts[i], pts[i + 1]))
        }
        return best
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
                movePoints0 = shapes[idx].points
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
            if currentKind == .highlighter {
                // Freehand by default. The samples are spline-smoothed, so the stroke reads as
                // a marker rather than as pointer input; ⇧ constrains it to the straight
                // horizontal bar that used to be the only option (see mouseDragged).
                shape.points = [p]
            }
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
            if !movePoints0.isEmpty {
                shapes[mi].points = movePoints0.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            }
            needsDisplay = true
            return
        }

        guard let start = dragStart, var shape = inProgress else { return }
        var q = p
        if event.modifierFlags.contains(.shift) {
            switch shape.kind {
            case .ellipse: q = constrainingCircle(start, to: q)
            case .line, .arrow: q = constrainingAngle(start, to: q)
            // Shift on a freehand highlighter keeps the stroke horizontal.
            case .highlighter: q.y = start.y
            default: break
            }
        }
        if shape.kind == .highlighter {
            appendHighlighterPoint(q, to: &shape)
        } else {
            shape.start = start
            shape.end = q
        }
        inProgress = shape
        needsDisplay = true
    }

    /// Appends a sampled point to a freehand highlighter stroke (⌥-started strokes only).
    /// Samples are spaced about 3 *screen* points apart (so density follows the zoom level),
    /// low-passed so pointer jitter reads as a marker stroke, and an over-long path is
    /// decimated rather than truncated so the stroke is never lost.
    private func appendHighlighterPoint(_ p: CGPoint, to shape: inout AnnotationShape) {
        guard let last = shape.points.last else { return }
        let zoom = max(enclosingScrollView?.magnification ?? 1, 0.01)
        if hypot(p.x - last.x, p.y - last.y) < 3.0 / zoom { return }
        let k = highlighterSmoothing
        let smoothed = CGPoint(x: last.x + (p.x - last.x) * k, y: last.y + (p.y - last.y) * k)
        if shape.points.count >= Self.highlighterMaxPoints {
            shape.points = shape.points.enumerated()
                .compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
        }
        shape.points.append(smoothed)
        shape.start = shape.points[0]
        shape.end = shape.points[shape.points.count - 1]
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
        if let shape = inProgress {
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
            panel.color = base.withAlphaComponent(highlighterAlpha)
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
        // Keep the highlighter's panel opacity slider pinned after each pick.
        if activeKind == .highlighter {
            let centered = sender.color.withAlphaComponent(highlighterAlpha)
            DispatchQueue.main.async {
                if abs(sender.color.alphaComponent - highlighterAlpha) > 0.001 {
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
