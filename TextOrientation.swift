//
//  TextOrientation.swift
//  Audience Wonderland Text Orientation
//
//  Detect the angle a person wrote at on an impression pad (any angle, not just
//  0/90/180/270), and return the strokes rotated upright, ready to feed a recognizer
//  such as MyScript iink. Single geometric pass, no recognition search.
//
//  Method:
//   - Baseline angle from a PCA of the per-stroke CENTROIDS (immune to tall/narrow letters).
//   - Pick the correct rotation of that baseline by scoring each for how much it reads like
//     text: horizontal lines, reading left-to-right in time, lines stacked top-to-bottom in
//     time. Resolves upright-vs-upside-down and multi-line in one step.
//   - A "start is up" prior (people begin a glyph near its top) breaks ties and, for a lone
//     digit/letter with no baseline to work from, drives a dedicated single-glyph path.
//   - Confidence is the winning margin, so ambiguous input reports low confidence for a
//     recognizer-side verify pass. Underlines / box edges are dropped before fitting.
//
//  MIT licensed. Contributions welcome.
//

import Foundation

// MARK: - Types

public struct StrokePoint {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public typealias Stroke = [StrokePoint]

public struct OrientationResult {
    /// Rotation (radians) to apply so the writing reads upright, left-to-right.
    public let radians: Double
    /// Same rotation in degrees, 0..<360.
    public let degrees: Double
    /// 0...1. High = the upright orientation clearly beat the alternatives. Low = ambiguous
    /// (lone digit, messy overlap) -> verify with the recognizer or context.
    public let confidence: Double
    /// Number of text lines detected (1 = single line or single glyph).
    public let lineCount: Int
}

// MARK: - Detection

public enum TextOrientation {

    public static func detect(_ strokes: [Stroke]) -> OrientationResult {
        // Drop underlines / box edges before fitting.
        let filtered = strokes.filter { !isUnderline($0) }
        let core = filtered.isEmpty ? strokes : filtered

        let centroids = core.compactMap { centroid($0) }
        let heights = core.map { s -> Double in
            let ys = s.map { $0.y }; return (ys.max() ?? 0) - (ys.min() ?? 0)
        }
        let allPoints = core.flatMap { $0 }
        guard allPoints.count >= 3, !centroids.isEmpty, let firstPt = core.first?.first else {
            return OrientationResult(radians: 0, degrees: 0, confidence: 0, lineCount: 1)
        }

        let (baseAxis, aniso) = pca(centroids.count >= 3 ? centroids : allPoints)
        let hmed = { () -> Double in let m = median(heights) ?? 1; return m == 0 ? 1 : m }()
        let strokeTime = Array(0..<core.count)
        let gcx = allPoints.reduce(0) { $0 + $1.x } / Double(allPoints.count)
        let gcy = allPoints.reduce(0) { $0 + $1.y } / Double(allPoints.count)
        let cands = [baseAxis, baseAxis + .pi/2, baseAxis + .pi, baseAxis + 3 * .pi/2]

        // SINGLE-GLYPH path (<=2 strokes, e.g. a lone digit): no text baseline applies.
        // Keep the glyph TALL (its own major axis vertical) with the START point at the TOP.
        if core.count <= 2 {
            func gscore(_ rot: Double) -> Double {
                let c = cos(rot), s = sin(rot)
                let pts = allPoints.map { StrokePoint(x: $0.x * c - $0.y * s, y: $0.x * s + $0.y * c) }
                let xs = pts.map { $0.x }, ys = pts.map { $0.y }
                let xr = max(1, (xs.max()! - xs.min()!)), yr = max(1, (ys.max()! - ys.min()!))
                let tall = yr / (xr + yr)
                let fy = firstPt.x * s + firstPt.y * c, cy = gcx * s + gcy * c
                let startUp = fy < cy ? 1.0 : 0.0
                return 0.5 * tall + 0.5 * startUp
            }
            let g = cands.map { (gscore(-$0), -$0) }.sorted { $0.0 > $1.0 }
            let rot = g[0].1, margin = g[0].0 - g[1].0
            let conf = max(0, min(1, margin * 2 + 0.1))
            var deg = (rot * 180 / .pi).truncatingRemainder(dividingBy: 360); if deg < 0 { deg += 360 }
            return OrientationResult(radians: rot, degrees: deg, confidence: conf, lineCount: 1)
        }

        // TEXT path: score each rotation for "reads like text".
        func score(_ rot: Double) -> (Double, Int) {
            let c = cos(rot), s = sin(rot)
            let rc = centroids.map { StrokePoint(x: $0.x * c - $0.y * s, y: $0.x * s + $0.y * c) }
            let xs = rc.map { $0.x }, ys = rc.map { $0.y }
            let W = (xs.max()! - xs.min()!) == 0 ? 1 : (xs.max()! - xs.min()!)

            let order = (0..<rc.count).sorted { ys[$0] < ys[$1] }
            var lines: [[Int]] = []; var cur: [Int] = [order[0]]
            for (a, b) in zip(order, order.dropFirst()) {
                if ys[b] - ys[a] > 1.1 * hmed { lines.append(cur); cur = [] }
                cur.append(b)
            }
            lines.append(cur)
            let good = lines.filter { ln in
                guard ln.count >= 2 else { return false }
                let lx = ln.map { xs[$0] }; return (lx.max()! - lx.min()!) > 0.25 * W
            }

            var rd = 0.0, nrd = 0
            for ln in good {
                let t = ln.sorted { strokeTime[$0] < strokeTime[$1] }
                let inc = zip(t, t.dropFirst()).reduce(0) { xs[$1.1] >= xs[$1.0] ? $0 + 1 : $0 }
                rd += Double(inc) / Double(t.count - 1); nrd += 1
            }
            let readScore = nrd > 0 ? rd / Double(nrd) : 0.5

            var stackScore = 0.5
            if good.count >= 2 {
                let lt = good.map { ln in ln.reduce(0.0) { $0 + Double(strokeTime[$1]) } / Double(ln.count) }
                let ly = good.map { ln in ln.reduce(0.0) { $0 + ys[$1] } / Double(ln.count) }
                let pr = zip(lt, ly).sorted { $0.0 < $1.0 }
                let inc = zip(pr, pr.dropFirst()).reduce(0) { $1.1.1 > $1.0.1 ? $0 + 1 : $0 }
                stackScore = Double(inc) / Double(pr.count - 1)
            }

            let xr = (xs.max()! - xs.min()!) == 0 ? 1 : (xs.max()! - xs.min()!)
            let yr = (ys.max()! - ys.min()!) == 0 ? 1 : (ys.max()! - ys.min()!)
            let horiz = xr / (xr + yr)
            let segPen = 0.15 * Double(max(0, lines.count - max(1, good.count)))
            let fy = firstPt.x * s + firstPt.y * c, cy = gcx * s + gcy * c
            let startUp = fy < cy ? 1.0 : 0.0
            let wSU = good.isEmpty ? 0.40 : 0.12
            return (0.42 * readScore + 0.22 * stackScore + 0.24 * horiz + wSU * startUp - segPen,
                    max(1, good.count))
        }

        let results = cands.map { c -> (Double, Double, Int) in
            let (sc, n) = score(-c); return (sc, -c, n)
        }.sorted { $0.0 > $1.0 }
        let (bestScore, rot, nLines) = results[0]
        let conf = max(0, min(1, (bestScore - results[1].0) * 3 + aniso * 0.3))
        var deg = (rot * 180 / .pi).truncatingRemainder(dividingBy: 360); if deg < 0 { deg += 360 }
        return OrientationResult(radians: rot, degrees: deg, confidence: conf, lineCount: nLines)
    }

    public static func normalize(_ strokes: [Stroke]) -> [Stroke] {
        apply(strokes, rotation: detect(strokes).radians)
    }

    public static func apply(_ strokes: [Stroke], rotation rot: Double) -> [Stroke] {
        let c = cos(rot), s = sin(rot)
        return strokes.map { $0.map { StrokePoint(x: $0.x * c - $0.y * s, y: $0.x * s + $0.y * c) } }
    }

    // MARK: - Helpers

    private static func centroid(_ s: Stroke) -> StrokePoint? {
        guard !s.isEmpty else { return nil }
        return StrokePoint(x: s.reduce(0) { $0 + $1.x } / Double(s.count),
                           y: s.reduce(0) { $0 + $1.y } / Double(s.count))
    }

    private static func isUnderline(_ s: Stroke) -> Bool {
        guard s.count > 8 else { return false }
        let xs = s.map { $0.x }, ys = s.map { $0.y }
        let w = xs.max()! - xs.min()!, h = ys.max()! - ys.min()!
        let span = max(w, h), thin = min(w, h)
        return span > 0 && thin / span < 0.08
    }

    private static func median(_ a: [Double]) -> Double? {
        a.isEmpty ? nil : a.sorted()[a.count / 2]
    }

    private static func pca(_ pts: [StrokePoint]) -> (Double, Double) {
        let n = Double(pts.count); guard n > 0 else { return (0, 0) }
        let mx = pts.reduce(0) { $0 + $1.x } / n, my = pts.reduce(0) { $0 + $1.y } / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in pts { let dx = p.x - mx, dy = p.y - my; sxx += dx*dx; syy += dy*dy; sxy += dx*dy }
        sxx /= n; syy /= n; sxy /= n
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        let root = (((sxx - syy)/2)*((sxx - syy)/2) + sxy*sxy).squareRoot()
        let l1 = (sxx + syy)/2 + root, l2 = (sxx + syy)/2 - root
        return (theta, (l1 - l2) / (l1 + l2 + 1e-9))
    }
}

// MARK: - MyScript hand-off
//
// MyScript iink ingests pointer events (x, y, t). The pad has no per-point timestamp, but
// stroke/point ORDER is enough: synthesize a monotonic clock. Feed the NORMALIZED strokes.

public struct PointerEvent {
    public let x: Float
    public let y: Float
    public let t: Int64
    public let phase: Phase
    public enum Phase { case down, move, up }
}

public extension TextOrientation {
    static func myScriptPointerEvents(_ strokes: [Stroke], msPerPoint: Int64 = 8) -> [PointerEvent] {
        let upright = normalize(strokes)
        var events: [PointerEvent] = []
        var t: Int64 = 0
        for stroke in upright where !stroke.isEmpty {
            for (i, p) in stroke.enumerated() {
                let phase: PointerEvent.Phase = i == 0 ? .down : (i == stroke.count - 1 ? .up : .move)
                events.append(PointerEvent(x: Float(p.x), y: Float(p.y), t: t, phase: phase))
                t += msPerPoint
            }
            t += msPerPoint * 4
        }
        return events
    }
}
