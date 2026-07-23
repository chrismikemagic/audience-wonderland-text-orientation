//
//  VisionTextOrientation.swift
//  Audience Wonderland Text Orientation
//
//  Apple Vision engine (2026-07-23). An alternative to the geometric detector in
//  TextOrientation.swift, built on VNRecognizeTextRequest: render the strokes to
//  an offscreen image, let Apple's on-device recognizer READ the ink, then recover
//  the writing angle from WHERE the characters it read actually sit. No network,
//  no training, nothing leaves the device.
//
//  The key discovery (measured, not assumed): Vision's recognizer is largely
//  rotation-invariant. It will happily read upside-down ink at full confidence,
//  so "try 4 rotations and keep the most confident" does NOT work. What does work:
//  ask Vision for the per-character boxes of what it read. The character centers
//  advance along the true reading direction, upside down or diagonal or not, so
//  one read yields the continuous text angle directly. Reads from several probe
//  rotations are folded into one circular-mean estimate with agreement-based
//  confidence.
//
//  Why it exists: the geometric detector is sub-millisecond but has a known weak
//  envelope (two lines written close together, cursive, diagonal writing). Vision
//  reads whole words and segments lines itself, so those cases stop depending on
//  our own line clustering. The trade is speed: recognizer passes cost hundreds of
//  milliseconds, fine for a one-shot impression capture, not for per-point
//  streaming.
//
//  Usage (drop BOTH Swift files into the target; this one reuses the shared types):
//
//      let result = VisionTextOrientation.detect(strokes)          // blocking, call off main
//      if !result.abstain {
//          let upright = TextOrientation.apply(strokes, rotation: result.radians)
//          // feed `upright` to MyScript / MLKit as usual
//      }
//
//  Or let the hybrid pick for you (geometry first, Vision as the referee):
//
//      let result = VisionTextOrientation.detectHybrid(strokes)
//
//  MIT licensed.
//

import Foundation
import CoreGraphics
import Vision

public enum VisionTextOrientation {

    public struct Options {
        /// Probe rotations for the first round. The cardinals cover all of
        /// Vision's readable range for most writing.
        public var coarseProbes: [Double] = [0, 90, 180, 270]
        /// Added only if the first round found too little text (weight below
        /// `escalateWeight`), which happens on strongly diagonal writing.
        public var extraProbes: [Double] = [45, 135, 225, 315]
        public var escalateWeight: Double = 0.9
        /// .accurate reads cursive and sloppy writing far better than .fast.
        public var recognitionLevel: VNRequestTextRecognitionLevel = .accurate
        /// Language correction OFF by default: spectators write names and digits,
        /// and correction biases toward dictionary words.
        public var usesLanguageCorrection: Bool = false
        public var recognitionLanguages: [String] = ["en-US"]
        /// Abstain when the total read weight lands below this (Vision could not
        /// really read the ink at any probe).
        public var abstainWeight: Double = 0.35
        /// Abstain when probe estimates disagree (circular concentration 0..1).
        public var abstainAgreement: Double = 0.60
        /// Long side of the rendered image in pixels.
        public var rasterLongSide: Int = 640
        public init() {}
    }

    // MARK: - Public API

    /// Blocking; runs Vision on the calling thread. Call off main.
    public static func detect(_ strokes: [Stroke], options: Options = Options()) -> OrientationResult {
        let clean = strokes.filter { !$0.isEmpty }
        guard !clean.isEmpty else {
            return OrientationResult(radians: 0, degrees: 0, confidence: 0,
                                     abstain: true, lineCount: 0, path: "vision-degenerate")
        }

        var estimates = probe(clean, angles: options.coarseProbes, options: options)
        var weight = estimates.reduce(0) { $0 + $1.weight }
        if weight < options.escalateWeight {
            estimates += probe(clean, angles: options.extraProbes, options: options)
            weight = estimates.reduce(0) { $0 + $1.weight }
        }

        guard weight > 0 else {
            return OrientationResult(radians: 0, degrees: 0, confidence: 0,
                                     abstain: true, lineCount: 0, path: "vision")
        }

        // Garbage reads happen (sideways strokes hallucinate as "Ill"), so do not
        // demand that every probe agree. Cluster the estimates by angle and let
        // the heaviest cluster win; its weight share is the agreement score.
        var clusters: [(sx: Double, sy: Double, w: Double)] = []
        for e in estimates.sorted(by: { $0.weight > $1.weight }) {
            let r = e.correctionDeg * .pi / 180
            var placed = false
            for i in clusters.indices {
                let mean = atan2(clusters[i].sy, clusters[i].sx) * 180 / .pi
                if angularDistance(e.correctionDeg, mean < 0 ? mean + 360 : mean) <= 35 {
                    clusters[i].sx += cos(r) * e.weight
                    clusters[i].sy += sin(r) * e.weight
                    clusters[i].w += e.weight
                    placed = true
                    break
                }
            }
            if !placed { clusters.append((cos(r) * e.weight, sin(r) * e.weight, e.weight)) }
        }
        guard let best = clusters.max(by: { $0.w < $1.w }) else {
            return OrientationResult(radians: 0, degrees: 0, confidence: 0,
                                     abstain: true, lineCount: 0, path: "vision")
        }
        var deg = atan2(best.sy, best.sx) * 180 / .pi
        if deg < 0 { deg += 360 }
        let agreement = best.w / weight
        let confidence = agreement * min(1.0, best.w)
        let abstain = best.w < options.abstainWeight || agreement < options.abstainAgreement
        let lines = estimates.map(\.lineCount).max() ?? 0

        return OrientationResult(radians: deg * .pi / 180,
                                 degrees: deg,
                                 confidence: confidence,
                                 abstain: abstain,
                                 lineCount: max(1, lines),
                                 path: "vision")
    }

    /// Geometry first (microseconds); Vision referees when geometry is unsure OR
    /// the two engines are cheap to cross-check and disagree. Best default for
    /// the app: fast on the easy cases, robust on close lines, cursive, and
    /// diagonals.
    ///
    /// `refineTilt` (default on) spends ONE extra Vision pass after a confident
    /// geometric answer to flatten residual tilt: rotate by the coarse answer,
    /// read once, and the leftover angle of the text Vision sees is subtracted
    /// out. Live pad testing showed geometry regularly lands the right quadrant
    /// but 15-30 degrees tilted on cursive, which is exactly the range where
    /// MyScript starts to struggle; one refinement pass takes the output to
    /// near-flat. Turn it off if you need the pure sub-millisecond path.
    public static func detectHybrid(_ strokes: [Stroke],
                                    geometryConfidenceFloor: Double = 0.70,
                                    refineTilt: Bool = true,
                                    options: Options = Options()) -> OrientationResult {
        let geo = TextOrientation.detect(strokes)
        if !geo.abstain && geo.confidence >= geometryConfidenceFloor {
            return refineTilt ? refined(geo, strokes: strokes, options: options) : geo
        }

        let vis = detect(strokes, options: options)
        if !vis.abstain { return vis }
        if !geo.abstain {
            return refineTilt ? refined(geo, strokes: strokes, options: options) : geo
        }
        // Both unsure; surface whichever was less lost, keep the abstain flag up.
        return vis.confidence >= geo.confidence ? vis : geo
    }

    /// One Vision pass on the coarse-rotated ink; snaps the answer to what the
    /// recognizer actually sees when they agree on the quadrant (<= 40 deg apart).
    private static func refined(_ coarse: OrientationResult, strokes: [Stroke], options: Options) -> OrientationResult {
        let estimates = probe(strokes, angles: [coarse.degrees], options: options)
        var sx = 0.0, sy = 0.0, w = 0.0
        for e in estimates where angularDistance(e.correctionDeg, coarse.degrees) <= 40 {
            let r = e.correctionDeg * .pi / 180
            sx += cos(r) * e.weight; sy += sin(r) * e.weight; w += e.weight
        }
        guard w >= 0.3 else { return coarse }   // nothing readable: keep geometry
        var deg = atan2(sy, sx) * 180 / .pi
        if deg < 0 { deg += 360 }
        return OrientationResult(radians: deg * .pi / 180,
                                 degrees: deg,
                                 confidence: max(coarse.confidence, min(1.0, w)),
                                 abstain: false,
                                 lineCount: max(coarse.lineCount, estimates.map(\.lineCount).max() ?? 0),
                                 path: coarse.path + "+refine")
    }

    // MARK: - Recognition readback

    /// What the on-device recognizer can read in the ink AS GIVEN, plus how
    /// confidently. Rotate first, then call this, and you have a direct measure
    /// of how recognizable the writing is at that orientation. Vision is not
    /// MyScript, but on handwriting they struggle with the same things, so this
    /// is an honest proxy for "will recognition work", and it runs offline.
    public struct Readback {
        public let text: String          // lines joined top to bottom with newlines
        public let confidence: Double    // 0..1 weighted mean of per-line confidence
        public let lineCount: Int
    }

    public static func readback(_ strokes: [Stroke], options: Options = Options()) -> Readback {
        let clean = strokes.filter { !$0.isEmpty }
        guard !clean.isEmpty, let image = rasterize(clean, longSide: options.rasterLongSide) else {
            return Readback(text: "", confidence: 0, lineCount: 0)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = options.recognitionLevel
        request.usesLanguageCorrection = options.usesLanguageCorrection
        request.recognitionLanguages = options.recognitionLanguages
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return Readback(text: "", confidence: 0, lineCount: 0) }

        var lines: [(y: Double, text: String, conf: Double, len: Int)] = []
        for obs in request.results ?? [] {
            guard let top = obs.topCandidates(1).first else { continue }
            let t = top.string.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            let midY = (Double(obs.topLeft.y) + Double(obs.bottomRight.y)) / 2
            lines.append((midY, t, Double(top.confidence), t.count))
        }
        guard !lines.isEmpty else { return Readback(text: "", confidence: 0, lineCount: 0) }
        lines.sort { $0.y > $1.y }   // normalized y is up; top of image first
        let totalLen = lines.reduce(0) { $0 + $1.len }
        let conf = lines.reduce(0.0) { $0 + $1.conf * Double($1.len) } / Double(max(1, totalLen))
        return Readback(text: lines.map(\.text).joined(separator: "\n"),
                        confidence: conf,
                        lineCount: lines.count)
    }

    // MARK: - Probing

    private struct Estimate {
        let correctionDeg: Double   // global rotation that makes the ink read upright
        let weight: Double
        let lineCount: Int
    }

    private static func probe(_ strokes: [Stroke], angles: [Double], options: Options) -> [Estimate] {
        var out: [Estimate] = []
        for angle in angles {
            let rotated = rotate(strokes, degrees: angle)
            guard let image = rasterize(rotated, longSide: options.rasterLongSide) else { continue }
            out += reads(in: image, probeDeg: angle, options: options)
        }
        return out
    }

    /// Run one recognition pass and convert every read line into a correction
    /// estimate from its per-character geometry.
    private static func reads(in image: CGImage, probeDeg: Double, options: Options) -> [Estimate] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = options.recognitionLevel
        request.usesLanguageCorrection = options.usesLanguageCorrection
        request.recognitionLanguages = options.recognitionLanguages

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return [] }

        let observations = request.results ?? []
        var estimates: [Estimate] = []
        let aspect = Double(image.width) / Double(image.height)

        for obs in observations {
            guard let top = obs.topCandidates(1).first else { continue }
            let trimmed = top.string.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2 else { continue }   // one char has no direction

            // The observation quad is oriented AND directed: Vision places
            // topLeft at the start of the text it read, wherever that lands in
            // the image. For upside-down ink, topLeft sits on the visual right
            // and the top edge points left, which encodes the 180 case per read.
            // (Per-character boxes are useless here: for handwriting Vision
            // returns the whole-line box for every character, measured.)
            let dx = (Double(obs.topRight.x) - Double(obs.topLeft.x)) * aspect
                   + (Double(obs.bottomRight.x) - Double(obs.bottomLeft.x)) * aspect
            let dyUp = (Double(obs.topRight.y) - Double(obs.topLeft.y))
                     + (Double(obs.bottomRight.y) - Double(obs.bottomLeft.y))
            guard dx * dx + dyUp * dyUp > 1e-9 else { continue }
            // Image visual frame is y-down (pad convention): flip the sign.
            let phi = atan2(-dyUp, dx) * 180 / .pi   // reading direction in the probe frame
            // The probe already rotated the ink by probeDeg; the leftover error
            // is phi, so the total correction is probeDeg - phi.
            var correction = (probeDeg - phi).truncatingRemainder(dividingBy: 360)
            if correction < 0 { correction += 360 }

            let lengthWeight = min(1.0, Double(trimmed.count) / 4.0)
            let w = Double(top.confidence) * (0.5 + 0.5 * lengthWeight)
            estimates.append(Estimate(correctionDeg: correction, weight: w, lineCount: observations.count))
        }
        return estimates
    }

    // MARK: - Geometry helpers

    private static func angularDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    private static func rotate(_ strokes: [Stroke], degrees: Double) -> [Stroke] {
        let r = degrees * .pi / 180
        let c = cos(r), s = sin(r)
        return strokes.map { st in
            st.map { p in StrokePoint(x: p.x * c - p.y * s, y: p.x * s + p.y * c) }
        }
    }

    /// Exposed for tooling and debugging: the exact image the engine hands to Vision.
    public static func debugRasterize(_ strokes: [Stroke], longSide: Int) -> CGImage? {
        rasterize(strokes, longSide: longSide)
    }

    /// Render strokes as dark ink on a white canvas. Pure CoreGraphics, so it
    /// works on iOS, iPadOS, and macOS with no UIKit/AppKit dependency.
    private static func rasterize(_ strokes: [Stroke], longSide: Int) -> CGImage? {
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for st in strokes { for p in st {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        } }
        var w = maxX - minX, h = maxY - minY
        if w < 1 { w = 1 }
        if h < 1 { h = 1 }

        let long = Double(max(64, longSide))
        let scale = long / max(w, h)
        let margin = long * 0.12
        let pxW = Int(w * scale + 2 * margin)
        let pxH = Int(h * scale + 2 * margin)

        guard let ctx = CGContext(data: nil, width: pxW, height: pxH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }

        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))

        // Pad y grows downward; CoreGraphics y grows upward. Flip so the image
        // matches what a person would see looking at the pad.
        ctx.translateBy(x: 0, y: CGFloat(pxH))
        ctx.scaleBy(x: 1, y: -1)

        ctx.setStrokeColor(gray: 0.0, alpha: 1.0)
        ctx.setLineWidth(max(2.0, long / 160.0))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        for st in strokes {
            guard let first = st.first else { continue }
            let fx = CGFloat((first.x - minX) * scale + margin)
            let fy = CGFloat((first.y - minY) * scale + margin)
            if st.count == 1 {
                // Lone point: draw a dot so i-dots and periods survive.
                let r = max(1.5, CGFloat(long) / 220.0)
                ctx.setFillColor(gray: 0.0, alpha: 1.0)
                ctx.fillEllipse(in: CGRect(x: fx - r, y: fy - r, width: 2 * r, height: 2 * r))
                continue
            }
            ctx.beginPath()
            ctx.move(to: CGPoint(x: fx, y: fy))
            for p in st.dropFirst() {
                ctx.addLine(to: CGPoint(x: CGFloat((p.x - minX) * scale + margin),
                                        y: CGFloat((p.y - minY) * scale + margin)))
            }
            ctx.strokePath()
        }
        return ctx.makeImage()
    }
}
