//
//  TextOrientation.swift
//  Audience Wonderland Text Orientation
//
//  v3 (2026-07-22). Detect the angle a person wrote at on an impression pad (any
//  angle, not just 0/90/180/270), and return the strokes rotated upright, ready to
//  feed a recognizer such as MyScript iink. Single geometric pass, no recognition
//  search. Every weight below was tuned and adversarially verified on a
//  rotate-and-score benchmark: 20 real Trilogy pad impressions plus 600 DeepWriting
//  single words / lone characters, each swept through 56 rotations.
//
//  Method:
//   - Candidate rotations: 4 cardinals of a PCA axis fit to the per-stroke
//     CENTROIDS (immune to tall/narrow letters).
//   - TEXT path (3+ strokes): each candidate scored by a weighted blend of
//       read      strokes advance left-to-right in time within a line
//       horiz     ink wider than tall
//       start-up  first written point sits above the ink centroid
//       seg-pen   penalty for spurious line over-segmentation
//       dirhist   two-peak pen-direction histogram (pen-down strokes travel
//                 down the glyph axis; pen-up jumps advance along the reading
//                 direction) after Nakagawa/Onuma
//       proj      sharpness of the rotated-y projection profile (capped Postl)
//     Line clustering uses a robust character-size estimate (Onuma) plus
//     temporal pen-up jump breaks, instead of a fragile median-height gap.
//   - LONE-GLYPH path (1-2 strokes, e.g. a single digit): tall + start-up +
//     dirhist blend, then a fine nudge from the histogram's down peak. Resolves
//     the natural-writing 6-vs-9 case (98.5% on lone digits in the benchmark).
//   - Confidence is the calibrated winning margin. abstain == true means the
//     geometry genuinely cannot tell; fire your recognizer-side 180/4-way retry
//     (rank-based: MyScript JIIX and MLKit expose no text confidence scores).
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
    /// Rotation (radians) to apply so the writing reads upright, left-to-right:
    /// (x', y') = (x cos r - y sin r, x sin r + y cos r). y increases downward.
    public let radians: Double
    /// Same rotation in degrees, 0..<360.
    public let degrees: Double
    /// 0...1, calibrated winning margin.
    public let confidence: Double
    /// The detector cannot tell. Fire the recognizer-side 180/4-way retry
    /// instead of trusting `radians`.
    public let abstain: Bool
    /// Number of well-formed text lines detected (1 = single line or lone glyph).
    public let lineCount: Int
    /// Which internal path decided: "text", "glyph", or "degenerate".
    public let path: String
}

// MARK: - Tuning (benchmark winners; keep in sync with lab orient3.py)

private enum K {
    // Text-path blend
    static let wRead = 0.42
    static let wHoriz = 0.24
    static let wStartUp = 0.12
    static let wStartUpNoLine = 0.40
    static let wSegPen = 0.15
    static let wDirHist = 0.20
    static let wProj = 0.40
    static let wNom = wRead + wHoriz + wStartUp + wDirHist + wProj
    static let confGain = 3.0
    static let anisoW = 0.3
    static let abstainConf = 0.35

    // Lone-glyph blend
    static let gTall = 0.35
    static let gStartUp = 0.05
    static let gDirHist = 0.60
    static let gConfGain = 2.5
    static let gAbstainConf = 0.10
    static let gUseRefine = true

    // Underline filter
    static let underThin = 0.08
    static let underMinPts = 9

    // Line clustering
    static let gapFactor = 0.7
    static let temporalGapFactor = 0.4
    static let longRatio = 2.0
    static let longAbsMult = 1.2

    // Direction histogram
    static let dhBins = 72
    static let dhSectorHalf = 45.0
    static let dhWC2 = 0.33
    static let dhWC3 = 0.18
    static let dhWC4 = 0.46
    static let dhWC5 = 0.17
    static let dhNorm = 0.7
    static let dhRelDeltas = 30.0
    static let dhRelJumps = 5.0
    static let dhRelWDown = 0.8
    static let dhSmoothSigma = 12.0
    static let dhRefineMax = 25.0
    static let dhRefineShrink = 0.5
    static let dhRefineMinRel = 0.5

    // Projection profile
    static let ppHFrac = 0.5
    static let ppCap = 4.0
    static let ppMaxBins = 512
    static let ppSquashK = 0.08
    static let ppMinPoints = 4

    static let binW = 360.0 / Double(dhBins)
    static let binCos: [Double] = (0..<dhBins).map { cos((Double($0) + 0.5) * binW * .pi / 180) }
    static let binSin: [Double] = (0..<dhBins).map { sin((Double($0) + 0.5) * binW * .pi / 180) }
    static let kHalf = max(1, Int(ceil(3.0 * dhSmoothSigma / binW)))
    static let kernel: [Double] = {
        let raw = (-kHalf...kHalf).map { exp(-0.5 * pow(Double($0) * binW / dhSmoothSigma, 2)) }
        let s = raw.reduce(0, +)
        return raw.map { $0 / s }
    }()
}

/// Python-style modulo: result always in [0, m).
@inline(__always) private func pymod(_ v: Double, _ m: Double) -> Double {
    let r = v.truncatingRemainder(dividingBy: m)
    return r < 0 ? r + m : r
}

// MARK: - Detection

public enum TextOrientation {

    public static func detect(_ strokes: [Stroke]) -> OrientationResult {
        let allCount = strokes.reduce(0) { $0 + $1.count }
        guard allCount >= 3 else {
            return OrientationResult(radians: 0, degrees: 0, confidence: 0,
                                     abstain: true, lineCount: 1, path: "degenerate")
        }

        let filtered = strokes.filter { !isUnderline($0) }
        let core = filtered.isEmpty ? strokes : filtered
        let centroids = core.map { s in
            StrokePoint(x: s.reduce(0) { $0 + $1.x } / Double(s.count),
                        y: s.reduce(0) { $0 + $1.y } / Double(s.count))
        }
        let corePts = core.flatMap { $0 }
        let gcx = corePts.reduce(0) { $0 + $1.x } / Double(corePts.count)
        let gcy = corePts.reduce(0) { $0 + $1.y } / Double(corePts.count)
        let firstPt = core[0][0]
        let (baseAxis, aniso) = pca(centroids.count >= 3 ? centroids : corePts)
        let cands = (0..<4).map { -(baseAxis + Double($0) * .pi / 2) }
        let dh = DirHist(strokes)

        // ---------------- lone-glyph path (1-2 core strokes)
        if core.count <= 2 {
            var ranked: [(Double, Double)] = []
            for rot in cands {
                let c = cos(rot), s = sin(rot)
                var minX = Double.infinity, maxX = -Double.infinity
                var minY = Double.infinity, maxY = -Double.infinity
                for p in corePts {
                    let rx = p.x * c - p.y * s, ry = p.x * s + p.y * c
                    minX = min(minX, rx); maxX = max(maxX, rx)
                    minY = min(minY, ry); maxY = max(maxY, ry)
                }
                let xr = (maxX - minX) == 0 ? 1.0 : (maxX - minX)
                let yr = (maxY - minY) == 0 ? 1.0 : (maxY - minY)
                let tall = yr / (xr + yr)
                let su = (firstPt.x * s + firstPt.y * c) < (gcx * s + gcy * c) ? 1.0 : 0.0
                ranked.append((K.gTall * tall + K.gStartUp * su + K.gDirHist * dh.score(rot), rot))
            }
            ranked.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 > $1.1 }
            var rot = ranked[0].1
            let margin = ranked[0].0 - ranked[1].0
            if K.gUseRefine { rot += dh.refineDelta(rot) }
            let conf = max(0.0, min(1.0, K.gConfGain * margin))
            return OrientationResult(radians: rot, degrees: pymod(rot * 180 / .pi, 360),
                                     confidence: conf, abstain: conf < K.gAbstainConf,
                                     lineCount: 1, path: "glyph")
        }

        // ---------------- text path
        let cs = charSize(core)
        let segId = segmentIds(core, size: cs)
        let n = centroids.count
        var ranked: [(Double, Double, Int)] = []
        for rot in cands {
            let c = cos(rot), s = sin(rot)
            let xs = centroids.map { $0.x * c - $0.y * s }
            let ys = centroids.map { $0.x * s + $0.y * c }
            let xspan = xs.max()! - xs.min()!
            let W = xspan == 0 ? 1.0 : xspan

            // line clustering: char-size gap OR reduced gap across a temporal break
            let order = (0..<n).sorted { ys[$0] != ys[$1] ? ys[$0] < ys[$1] : $0 < $1 }
            var lines: [[Int]] = []
            var cur: [Int] = [order[0]]
            for (a, b) in zip(order, order.dropFirst()) {
                let gap = ys[b] - ys[a]
                if gap > K.gapFactor * cs ||
                   (gap > K.temporalGapFactor * cs && segId[a] != segId[b]) {
                    lines.append(cur); cur = []
                }
                cur.append(b)
            }
            lines.append(cur)
            let good = lines.filter { ln in
                guard ln.count >= 2 else { return false }
                let lx = ln.map { xs[$0] }
                return (lx.max()! - lx.min()!) > 0.25 * W
            }

            var rd = 0.0, nrd = 0
            for ln in good {
                let t = ln.sorted()   // stroke index == time order
                let inc = zip(t, t.dropFirst()).reduce(0) { xs[$1.1] >= xs[$1.0] ? $0 + 1 : $0 }
                rd += Double(inc) / Double(t.count - 1); nrd += 1
            }
            let read = nrd > 0 ? rd / Double(nrd) : 0.5

            let yspan = ys.max()! - ys.min()!
            let xr = xspan == 0 ? 1.0 : xspan
            let yr = yspan == 0 ? 1.0 : yspan
            let horiz = xr / (xr + yr)
            let segExcess = Double(max(0, lines.count - max(1, good.count)))
            let su = (firstPt.x * s + firstPt.y * c) < (gcx * s + gcy * c) ? 1.0 : 0.0
            let suW = good.isEmpty ? K.wStartUpNoLine : K.wStartUp
            let sc = K.wRead * read + K.wHoriz * horiz + suW * su
                   - K.wSegPen * segExcess
                   + K.wDirHist * dh.score(rot) + K.wProj * projScore(strokes, rot)
            ranked.append((sc, rot, max(1, good.count)))
        }
        ranked.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 > $1.1 }
        let (sc0, rot, nLines) = ranked[0]
        let margin = sc0 - ranked[1].0
        let conf = max(0.0, min(1.0, K.confGain * margin / K.wNom + K.anisoW * aniso))
        return OrientationResult(radians: rot, degrees: pymod(rot * 180 / .pi, 360),
                                 confidence: conf, abstain: conf < K.abstainConf,
                                 lineCount: nLines, path: "text")
    }

    public static func normalize(_ strokes: [Stroke]) -> [Stroke] {
        apply(strokes, rotation: detect(strokes).radians)
    }

    public static func apply(_ strokes: [Stroke], rotation rot: Double) -> [Stroke] {
        let c = cos(rot), s = sin(rot)
        return strokes.map { $0.map { StrokePoint(x: $0.x * c - $0.y * s, y: $0.x * s + $0.y * c) } }
    }

    // MARK: - Geometry helpers

    private static func pca(_ pts: [StrokePoint]) -> (Double, Double) {
        let n = Double(pts.count)
        guard n > 0 else { return (0, 0) }
        let mx = pts.reduce(0) { $0 + $1.x } / n, my = pts.reduce(0) { $0 + $1.y } / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in pts { let dx = p.x - mx, dy = p.y - my; sxx += dx*dx; syy += dy*dy; sxy += dx*dy }
        sxx /= n; syy /= n; sxy /= n
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        let root = (((sxx - syy)/2)*((sxx - syy)/2) + sxy*sxy).squareRoot()
        let l1 = (sxx + syy)/2 + root, l2 = (sxx + syy)/2 - root
        return (theta, (l1 - l2) / (l1 + l2 + 1e-9))
    }

    /// Long, nearly straight, thin, axis-aligned stroke = underline / box edge.
    /// Known limit (measured): only fires near-cardinal presentation. The
    /// rotation-invariant PCA variant was benchmarked and REJECTED: it
    /// over-fires on legitimate long strokes (pad 0.985 -> 0.936).
    private static func isUnderline(_ s: Stroke) -> Bool {
        guard s.count >= K.underMinPts else { return false }
        let xs = s.map { $0.x }, ys = s.map { $0.y }
        let w = xs.max()! - xs.min()!, h = ys.max()! - ys.min()!
        let span = max(w, h), thin = min(w, h)
        return span > 0 && thin / span < K.underThin
    }

    /// Onuma robust character size: sort stroke-bbox longer sides, average the larger half.
    private static func charSize(_ strokes: [Stroke]) -> Double {
        var sides: [Double] = []
        for st in strokes {
            let xs = st.map { $0.x }, ys = st.map { $0.y }
            sides.append(max(xs.max()! - xs.min()!, ys.max()! - ys.min()!))
        }
        guard !sides.isEmpty else { return 1.0 }
        sides.sort()
        let upper = sides[(sides.count / 2)...]
        let m = upper.reduce(0, +) / Double(upper.count)
        return m == 0 ? 1.0 : m
    }

    /// Tiny 1-D 2-means over pen-up jump lengths; accepted long jumps split
    /// temporal segments (writer moved to a new line/word).
    private static func segmentIds(_ strokes: [Stroke], size: Double) -> [Int] {
        let n = strokes.count
        var segId = [Int](repeating: 0, count: n)
        guard n >= 3 else { return segId }
        let jumps = (0..<(n - 1)).map { i -> Double in
            let dx = strokes[i + 1][0].x - strokes[i].last!.x
            let dy = strokes[i + 1][0].y - strokes[i].last!.y
            return (dx * dx + dy * dy).squareRoot()
        }
        let lo = jumps.min()!, hi = jumps.max()!
        var mLo = lo, mHi = hi
        var labels = [Int](repeating: 0, count: jumps.count)
        if hi <= lo {
            return segId
        }
        var c0 = lo, c1 = hi
        for _ in 0..<20 {
            let new = jumps.map { abs($0 - c1) < abs($0 - c0) ? 1 : 0 }
            let g0 = zip(jumps, new).filter { $0.1 == 0 }.map { $0.0 }
            let g1 = zip(jumps, new).filter { $0.1 == 1 }.map { $0.0 }
            if g0.isEmpty || g1.isEmpty {
                mLo = lo; mHi = hi; labels = [Int](repeating: 0, count: jumps.count)
                break
            }
            let n0 = g0.reduce(0, +) / Double(g0.count)
            let n1 = g1.reduce(0, +) / Double(g1.count)
            if new == labels && n0 == c0 && n1 == c1 { mLo = c0; mHi = c1; break }
            labels = new; c0 = n0; c1 = n1
            mLo = c0; mHi = c1
        }
        guard mHi > K.longRatio * max(mLo, 1e-9), mHi > K.longAbsMult * size else { return segId }
        var sid = 0
        for i in 1..<n {
            if labels[i - 1] == 1 { sid += 1 }
            segId[i] = sid
        }
        return segId
    }

    /// Capped squared-histogram sharpness of the rotated-y projection profile,
    /// squashed to ~0..1. The per-bin mass cap removes the delta-spike reward
    /// of long straight strokes while keeping genuine text-line bands.
    private static func projScore(_ strokes: [Stroke], _ rot: Double) -> Double {
        let s = sin(rot), c = cos(rot)
        var ys: [Double] = []
        var heights: [Double] = []
        for st in strokes {
            guard !st.isEmpty else { continue }
            let yy = st.map { $0.x * s + $0.y * c }
            ys.append(contentsOf: yy)
            heights.append(yy.max()! - yy.min()!)
        }
        let n = ys.count
        guard n >= K.ppMinPoints else { return 0.0 }
        let lo = ys.min()!
        let extent = ys.max()! - lo
        var raw: Double
        if extent <= 1e-9 {
            raw = 1.0
        } else {
            heights.sort()
            var size = heights[heights.count / 2]
            if size == 0 { size = extent }
            let binw = max(K.ppHFrac * size, extent / Double(K.ppMaxBins), 1e-12)
            let nbins = Int(extent / binw) + 1
            var h = [Int](repeating: 0, count: nbins)
            for yv in ys {
                let i = Int((yv - lo) / binw)
                h[i < nbins ? i : nbins - 1] += 1
            }
            let cap = K.ppCap * Double(n) / Double(nbins)
            raw = h.reduce(0.0) { acc, v in
                let m = Double(v) < cap ? Double(v) : cap
                return acc + m * m
            } / (Double(n) * Double(n))
        }
        return raw / (raw + K.ppSquashK)
    }

    // MARK: - Direction histogram (Nakagawa/Onuma two-peak)

    /// Built once per ink; rotation applied analytically at score time.
    private final class DirHist {
        let f: [Double]?          // pen-down direction histogram (length-weighted)
        let u: [Double]?          // pen-up jump direction histogram
        let fm: (Double, Double)  // circular moments of f
        let um: (Double, Double)
        let relDown: Double
        let rel: Double

        init(_ strokes: [Stroke]) {
            let filtered = strokes.filter { !TextOrientation.isUnderline($0) }
            let core = filtered.isEmpty ? strokes : filtered
            var fh = [Double](repeating: 0, count: K.dhBins)
            var nDown = 0
            for st in core {
                for i in 1..<max(1, st.count) {
                    let dx = st[i].x - st[i - 1].x
                    let dy = st[i].y - st[i - 1].y
                    let ln = (dx * dx + dy * dy).squareRoot()
                    if ln <= 1e-9 { continue }
                    let deg = pymod(atan2(dy, dx) * 180 / .pi, 360)
                    fh[Int(deg / K.binW) % K.dhBins] += ln
                    nDown += 1
                }
            }
            var uh = [Double](repeating: 0, count: K.dhBins)
            var nUp = 0
            for i in 1..<max(1, core.count) {
                let dx = core[i][0].x - core[i - 1].last!.x
                let dy = core[i][0].y - core[i - 1].last!.y
                if (dx * dx + dy * dy).squareRoot() <= 1e-9 { continue }
                let deg = pymod(atan2(dy, dx) * 180 / .pi, 360)
                uh[Int(deg / K.binW) % K.dhBins] += 1.0
                nUp += 1
            }
            let tf = fh.reduce(0, +), tu = uh.reduce(0, +)
            f = tf > 0 ? fh.map { $0 / tf } : nil
            u = tu > 0 ? uh.map { $0 / tu } : nil
            fm = f.map(DirHist.moments) ?? (0, 0)
            um = u.map(DirHist.moments) ?? (0, 0)
            relDown = f != nil ? min(1.0, Double(nDown) / K.dhRelDeltas) : 0.0
            let relUp = u != nil ? min(1.0, Double(nUp) / K.dhRelJumps) : 0.0
            rel = K.dhRelWDown * relDown + (1.0 - K.dhRelWDown) * relUp
        }

        private static func moments(_ hist: [Double]) -> (Double, Double) {
            var mx = 0.0, my = 0.0
            for b in 0..<K.dhBins { mx += hist[b] * K.binCos[b]; my += hist[b] * K.binSin[b] }
            return (mx, my)
        }

        /// ~0..1 uprightness of the ink rotated by rot, reliability-shrunk
        /// toward the uninformative 0.5 on sparse ink.
        func score(_ rot: Double) -> Double {
            guard let f = f else { return 0.5 }
            let rdeg = rot * 180 / .pi
            let c = cos(rot), s = sin(rot)
            let c2 = fm.0 * c - fm.1 * s                 // pen-down mean-right
            var sect = [Double]()
            for target in [0.0, 90.0, 180.0, -90.0] {    // right, down, left, up
                let t = target - rdeg
                var m = 0.0
                for b in 0..<K.dhBins {
                    let d = abs(pymod((Double(b) + 0.5) * K.binW - t + 180.0, 360.0) - 180.0)
                    if d < K.dhSectorHalf { m += f[b] }
                }
                sect.append(m)
            }
            let rt = sect[0], dn = sect[1], lf = sect[2], up = sect[3]
            let a0 = dn * rt
            let tot = a0 + rt * up + up * lf + lf * dn
            let c3 = tot > 0 ? (a0 / tot - 0.25) : 0.0   // two-peak product placement
            let c4 = dn - up                             // strokes travel downward
            var c5 = 0.0
            if u != nil { c5 = um.0 * c - um.1 * s }     // pen-up jump mean-right
            var v = (K.dhWC2 * c2 + K.dhWC3 * c3 + K.dhWC4 * c4 + K.dhWC5 * c5) / K.dhNorm
            v = max(-1.0, min(1.0, v))
            return rel * (0.5 + 0.5 * v) + (1.0 - rel) * 0.5
        }

        /// Extra rotation (radians) sliding the smoothed two-peak product's
        /// local peak onto the down axis. 0 when unreliable.
        func refineDelta(_ rot: Double) -> Double {
            guard let f = f, relDown >= K.dhRefineMinRel else { return 0.0 }
            var sm = [Double](repeating: 0, count: K.dhBins)
            for i in 0..<K.dhBins {
                let v = f[i]
                if v == 0 { continue }
                for k in -K.kHalf...K.kHalf {
                    var idx = (i + k) % K.dhBins
                    if idx < 0 { idx += K.dhBins }
                    sm[idx] += v * K.kernel[k + K.kHalf]
                }
            }
            func ev(_ deg: Double) -> Double {
                let x = pymod(deg, 360.0) / K.binW
                let i0 = Int(x) % K.dhBins
                let fr = x - x.rounded(.down)
                return sm[i0] * (1.0 - fr) + sm[(i0 + 1) % K.dhBins] * fr
            }
            let rdeg = rot * 180 / .pi
            var bestDt = 0.0, bestV = -1.0
            var dt = -K.dhRefineMax
            while dt <= K.dhRefineMax + 1e-9 {
                let downT = 90.0 - (rdeg + dt)
                let v = ev(downT) * ev(downT - 90.0)     // f(down) * f(right)
                if v > bestV { bestV = v; bestDt = dt }
                dt += 1.0
            }
            return bestDt * K.dhRefineShrink * .pi / 180
        }
    }
}

// MARK: - MyScript hand-off
//
// MyScript iink ingests pointer events (x, y, t). The pad has no per-point timestamp, but
// stroke/point ORDER is enough: synthesize a monotonic clock. Feed the NORMALIZED strokes.
// When detect() abstains, run recognition as-is plus at 180 (or all 4 cardinals) and pick
// the winner by candidate RANKS and lexicon hits: neither MyScript JIIX text export nor
// MLKit Digital Ink exposes numeric text confidence scores.

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
