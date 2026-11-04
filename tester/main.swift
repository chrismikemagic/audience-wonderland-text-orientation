// LumenTest: hands-on test bench for the text orientation engines.
//
// Connects to a Lumen pad (Trilogy, Stage, Clipboard, Mini) over Bluetooth.
// Every time the writer pauses, the impression is closed and run through:
//   1. the geometric engine (TextOrientation.detect)
//   2. the hybrid engine (VisionTextOrientation.detectHybrid), the recommended one
//   3. Apple's on-device text recognition on the upright ink (free, offline)
//   4. optionally Claude reading the upright ink (needs ANTHROPIC_API_KEY)
// and prints the angle, the confidence, the time each step took, and what was read.
// A before/after picture opens for every impression, and everything is saved to
// a results folder (pictures, stroke JSON, a CSV of every number, the raw log).
//
// Usage: tester/run.sh [options]   (see tester/README.md)

import Foundation
import CoreBluetooth
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

setvbuf(stdout, nil, Int32(_IONBF), 0)

// MARK: - Options

struct Config {
    var gap: TimeInterval = 1.0
    var nameFilter: String? = nil
    var outRoot: String = NSHomeDirectory() + "/Desktop/Lumen Test Results"
    var replayPath: String? = nil
    var useClaude = false
    var model = "claude-fable-5-1"
    var openImages = true
}

func usage() -> Never {
    print("""
    LumenTest: live orientation + recognition test for Lumen pads

      tester/run.sh                     connect to the first Lumen pad found and start testing
      tester/run.sh --replay FILE       re-run a saved raw.log (no pad needed)
      tester/run.sh --replay sample     run the bundled sample session (checks the install)

    Options:
      --gap SECONDS     pen silence that ends an impression (default 1.0)
      --name TEXT       only connect to a pad whose name contains TEXT (e.g. Stage)
      --out DIR         where results go (default ~/Desktop/Lumen Test Results)
      --claude          also have Claude read each impression (needs ANTHROPIC_API_KEY)
      --model ID        Claude model for --claude (default claude-fable-5-1)
      --no-open         don't pop open the before/after picture for each impression
    """)
    exit(0)
}

var cfg = Config()
do {
    var args = Array(CommandLine.arguments.dropFirst())
    func next(_ flag: String) -> String {
        guard !args.isEmpty else { print("\(flag) needs a value"); exit(2) }
        return args.removeFirst()
    }
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--gap": cfg.gap = Double(next(a)) ?? 1.0
        case "--name": cfg.nameFilter = next(a).lowercased()
        case "--out": cfg.outRoot = (next(a) as NSString).expandingTildeInPath
        case "--replay": cfg.replayPath = next(a)
        case "--claude": cfg.useClaude = true
        case "--model": cfg.model = next(a)
        case "--no-open": cfg.openImages = false
        case "-h", "--help": usage()
        default: print("Unknown option \(a)\n"); usage()
        }
    }
}

let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
if cfg.useClaude && apiKey.isEmpty {
    print("--claude needs ANTHROPIC_API_KEY set in this terminal. Running without Claude.")
    cfg.useClaude = false
}

// MARK: - Session folder

func clock() -> String { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date()) }
let stamp: String = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"; return f.string(from: Date()) }()
let sessionDir = cfg.outRoot + "/session-\(stamp)"
try? FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)

let csvPath = sessionDir + "/results.csv"
FileManager.default.createFile(atPath: csvPath, contents: (
    "impression,strokes,points,geometric_deg,geometric_conf,geometric_ms,hybrid_deg,hybrid_conf,hybrid_path,hybrid_abstain,hybrid_ms,apple_read,apple_conf,apple_ms,claude_read,claude_ms,image\n"
).data(using: .utf8))

let rawLogPath = sessionDir + "/raw.log"
FileManager.default.createFile(atPath: rawLogPath, contents: nil)
let rawLog = FileHandle(forWritingAtPath: rawLogPath)!

func appendLine(_ path: String, _ line: String) {
    guard let fh = FileHandle(forWritingAtPath: path) else { return }
    fh.seekToEndOfFile()
    fh.write((line + "\n").data(using: .utf8)!)
    try? fh.close()
}

func csv(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

// MARK: - Timing helpers

func timed<T>(_ body: () -> T) -> (T, Double) {
    let t0 = DispatchTime.now()
    let r = body()
    return (r, Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6)
}

func median(_ v: [Double]) -> Double {
    guard !v.isEmpty else { return 0 }
    let s = v.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

// MARK: - Claude reader (optional)

func pngData(_ img: CGImage) -> Data {
    let d = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(d, UTType.png.identifier as CFString, 1, nil) else { return Data() }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    return d as Data
}

func savePNG(_ img: CGImage, _ path: String) {
    try? pngData(img).write(to: URL(fileURLWithPath: path))
}

let readerPrompt = """
This is handwriting captured from a drawing pad and already rotated upright. It may be sloppy. \
First find the letters you can read with high confidence, especially distinctive letterforms and word endings, \
and treat those as anchors. Never override a clearly formed letter just because a more common word would fit. \
Reply with ONLY the text, nothing else. Use / between lines. It is likely a name, word, number or short phrase. \
Always commit to a best guess.
"""

func claudeRead(_ image: CGImage) -> String {
    let body: [String: Any] = [
        "model": cfg.model,
        "max_tokens": 4000,                       // room for any thinking before the answer
        "output_config": ["effort": "low"],      // a quick read, not a deliberation
        "messages": [[
            "role": "user",
            "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/png",
                                             "data": pngData(image).base64EncodedString()]],
                ["type": "text", "text": readerPrompt],
            ],
        ]],
    ]
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    req.timeoutInterval = 60
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)

    var out = "(request failed)"
    for attempt in 1...3 {
        var retry = false
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, error in
            defer { sem.signal() }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let error { out = "(network error: \(error.localizedDescription))"; retry = true; return }
            let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                out = "(http \(status): \(raw.prefix(120)))"; retry = status == 429 || status >= 500; return
            }
            if let content = json["content"] as? [[String: Any]],
               let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String {
                out = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
                out = "(api error \(status): \(msg))"; retry = status == 429 || status >= 500
            } else {
                out = "(unexpected reply: \(raw.prefix(120)))"
            }
        }.resume()
        sem.wait()
        if !retry || attempt == 3 { break }
        Thread.sleep(forTimeInterval: Double(attempt))
    }
    return out
}

// MARK: - Before/after picture

func composite(_ left: CGImage, _ right: CGImage, caption: [String]) -> CGImage? {
    let lineH = 32
    let capH = lineH * caption.count + 20
    let labelH = 34
    let h = max(left.height, right.height) + capH + labelH
    let w = left.width + right.width + 24
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(gray: 0.93, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: capH))
    ctx.setFillColor(gray: 0.75, alpha: 1); ctx.fill(CGRect(x: left.width + 10, y: capH, width: 4, height: h - capH))
    let imgH = h - capH - labelH
    ctx.draw(left, in: CGRect(x: 0, y: capH + (imgH - left.height) / 2, width: left.width, height: left.height))
    ctx.draw(right, in: CGRect(x: left.width + 24, y: capH + (imgH - right.height) / 2, width: right.width, height: right.height))

    func text(_ s: String, size: CGFloat, x: Int, y: Int, gray: CGFloat = 0.05) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
        ]
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs)), ctx)
    }
    text("AS WRITTEN", size: 16, x: 14, y: h - 24, gray: 0.45)
    text("AFTER AUTO ORIENTATION", size: 16, x: left.width + 38, y: h - 24, gray: 0.45)
    for (i, line) in caption.enumerated() {
        text(line, size: i == 0 ? 20 : 15, x: 14, y: capH - (i + 1) * lineH + 6)
    }
    return ctx.makeImage()
}

// MARK: - Per-impression pipeline

struct Row { var geoMs: Double; var hybMs: Double; var appleMs: Double; var claudeMs: Double? }
var rows: [Row] = []
var impressionCount = 0
let work = DispatchQueue(label: "lumen.test.work")

func strokesJSON(_ s: [Stroke]) -> [[[Double]]] {
    s.map { $0.map { [($0.x * 100).rounded() / 100, ($0.y * 100).rounded() / 100] } }
}

func process(_ strokes: [Stroke]) {
    impressionCount += 1
    let n = impressionCount
    let pts = strokes.reduce(0) { $0 + $1.count }

    // 1. Geometric engine alone (sub-millisecond path).
    let (geo, geoMs) = timed { TextOrientation.detect(strokes) }
    // 2. Hybrid: geometry first, Apple Vision referees and refines tilt. The recommended call.
    let (hyb, hybMs) = timed { VisionTextOrientation.detectHybrid(strokes) }
    let upright = TextOrientation.apply(strokes, rotation: hyb.radians)
    // 3. Apple on-device recognition on the upright ink.
    let (apple, appleMs) = timed { VisionTextOrientation.readback(upright) }
    let appleText = apple.text.replacingOccurrences(of: "\n", with: " / ")

    let uprightImg = VisionTextOrientation.debugRasterize(upright, longSide: 900)
    let base = String(format: "imp%02d", n)
    if let uprightImg { savePNG(uprightImg, sessionDir + "/\(base)-upright.png") }

    // 4. Claude, optional.
    var claudeText: String? = nil
    var claudeMs: Double? = nil
    if cfg.useClaude, let uprightImg {
        let (t, ms) = timed { claudeRead(uprightImg) }
        claudeText = t; claudeMs = ms
    }

    rows.append(Row(geoMs: geoMs, hybMs: hybMs, appleMs: appleMs, claudeMs: claudeMs))

    // Terminal report.
    print("\n=== IMPRESSION #\(n)  (\(strokes.count) strokes, \(pts) points) ===")
    print(String(format: "  Orientation (hybrid, recommended): %6.1f deg  confidence %.2f  %@  %.0f ms",
                 hyb.degrees, hyb.confidence, hyb.abstain ? "UNSURE" : "sure", hybMs))
    print(String(format: "  Orientation (geometry only):       %6.1f deg  confidence %.2f  %@  %.2f ms",
                 geo.degrees, geo.confidence, geo.abstain ? "UNSURE" : "sure", geoMs))
    print("  Apple reads (on-device):  \"\(appleText)\"" + String(format: "  conf %.2f  %.0f ms", apple.confidence, appleMs))
    if let claudeText, let claudeMs {
        print("  Claude reads (\(cfg.model)): \"\(claudeText)\"" + String(format: "  %.0f ms", claudeMs))
    }
    let wait = cfg.replayPath == nil ? String(format: "%.1f s pen-pause wait + ", cfg.gap) : ""
    print(String(format: "  Time to upright ink after the pen stopped: %@%.0f ms", wait, hybMs))
    print("  Upright image for AI reading: \(sessionDir)/\(base)-upright.png")

    // Picture.
    var caption = [String(format: "TURNED %.0f deg in %.0f ms  (geometry alone %.2f ms)", hyb.degrees, hybMs, geoMs),
                   "Apple reads: \(appleText.isEmpty ? "(nothing)" : appleText)" + String(format: "  [%.0f ms]", appleMs)]
    if let claudeText, let claudeMs { caption.append("Claude reads: \(claudeText)" + String(format: "  [%.0f ms]", claudeMs)) }
    if let before = VisionTextOrientation.debugRasterize(strokes, longSide: 480),
       let after = VisionTextOrientation.debugRasterize(upright, longSide: 480),
       let combo = composite(before, after, caption: caption) {
        let p = sessionDir + "/\(base).png"
        savePNG(combo, p)
        if cfg.openImages {
            let t = Process(); t.launchPath = "/usr/bin/open"; t.arguments = [p]; try? t.run()
        }
    }

    // Data files.
    var record: [String: Any] = [
        "impression": n, "stroke_count": strokes.count, "point_count": pts,
        "geometric": ["degrees": geo.degrees, "confidence": geo.confidence, "abstain": geo.abstain, "path": geo.path, "ms": geoMs],
        "hybrid": ["degrees": hyb.degrees, "confidence": hyb.confidence, "abstain": hyb.abstain, "path": hyb.path, "ms": hybMs],
        "apple_read": ["text": apple.text, "confidence": apple.confidence, "ms": appleMs],
        "strokes_as_written": strokesJSON(strokes),
        "strokes_upright": strokesJSON(upright),
    ]
    if let claudeText, let claudeMs { record["claude_read"] = ["model": cfg.model, "text": claudeText, "ms": claudeMs] }
    if let d = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
        try? d.write(to: URL(fileURLWithPath: sessionDir + "/\(base).json"))
    }
    appendLine(csvPath, [
        "\(n)", "\(strokes.count)", "\(pts)",
        String(format: "%.1f", geo.degrees), String(format: "%.2f", geo.confidence), String(format: "%.3f", geoMs),
        String(format: "%.1f", hyb.degrees), String(format: "%.2f", hyb.confidence), csv(hyb.path), hyb.abstain ? "yes" : "no",
        String(format: "%.1f", hybMs),
        csv(apple.text.replacingOccurrences(of: "\n", with: " / ")), String(format: "%.2f", apple.confidence), String(format: "%.1f", appleMs),
        csv(claudeText ?? ""), claudeMs.map { String(format: "%.0f", $0) } ?? "",
        csv("\(base).png"),
    ].joined(separator: ","))
}

func printSummary() {
    print("\n================ SESSION SUMMARY ================")
    print("Impressions tested: \(rows.count)")
    if !rows.isEmpty {
        let g = rows.map(\.geoMs), h = rows.map(\.hybMs), a = rows.map(\.appleMs)
        print(String(format: "Orientation, hybrid (recommended):  median %.0f ms, slowest %.0f ms", median(h), h.max()!))
        print(String(format: "Orientation, geometry only:         median %.2f ms, slowest %.2f ms", median(g), g.max()!))
        print(String(format: "Apple recognition:                  median %.0f ms", median(a)))
        let c = rows.compactMap(\.claudeMs)
        if !c.isEmpty { print(String(format: "Claude recognition:                 median %.0f ms", median(c))) }
    }
    print("Everything is saved in: \(sessionDir)")
    print("  results.csv (every number), impNN.png (before/after), impNN-upright.png, impNN.json (strokes), raw.log")
}

// MARK: - Pen packet decoding (shared by live and replay)

final class Decoder {
    var curStroke: Stroke = []
    var curImpression: [Stroke] = []

    /// Pen packets on 1B7E8262: [0x11][len] then 6-byte points (x u16LE, y u16LE, pressure u16LE). Pressure 0 = pen up.
    func feed(_ d: [UInt8]) {
        guard d.count >= 2, d[0] == 0x11 else { return }
        let pay = Array(d.dropFirst(2).prefix(Int(d[1])))
        var i = 0
        while i + 5 < pay.count {
            let x = Double(UInt16(pay[i]) | (UInt16(pay[i + 1]) << 8))
            let y = Double(UInt16(pay[i + 2]) | (UInt16(pay[i + 3]) << 8))
            let pr = UInt16(pay[i + 4]) | (UInt16(pay[i + 5]) << 8)
            i += 6
            if pr == 0 {
                if !curStroke.isEmpty { curImpression.append(curStroke); curStroke = [] }
            } else {
                curStroke.append(StrokePoint(x: x, y: y))
            }
        }
    }

    func close() -> [Stroke]? {
        if !curStroke.isEmpty { curImpression.append(curStroke); curStroke = [] }
        guard !curImpression.isEmpty else { return nil }
        defer { curImpression = [] }
        return curImpression
    }
}

let PEN_UUID = "1B7E8262-2877-41C3-B46E-CF057C562023"

// MARK: - Replay mode

func replay(_ pathArg: String) {
    var path = pathArg
    if pathArg == "sample" {
        let here = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
        path = here.appendingPathComponent("sample/raw.log").path
    }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("Could not read \(path)"); exit(1)
    }
    print("Replaying \(path)  (impressions split on \(cfg.gap) s pen pauses)")
    func seconds(_ hms: Substring) -> Double? {
        let p = hms.split(separator: ":"); guard p.count == 3, let h = Double(p[0]), let m = Double(p[1]), let s = Double(p[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }
    let dec = Decoder()
    var last: Double? = nil
    for line in text.split(separator: "\n") where line.contains("NOTIFY \(PEN_UUID)") {
        let parts = line.split(separator: " ", maxSplits: 1)
        guard let t = seconds(parts[0]),
              let lb = line.firstIndex(of: "]"), let bar = line.range(of: "  |") else { continue }
        if let last, t - last >= cfg.gap, let imp = dec.close() { process(imp) }
        last = t
        let bytes = line[line.index(after: lb)..<bar.lowerBound].split(separator: " ").compactMap { UInt8($0, radix: 16) }
        dec.feed(bytes)
    }
    if let imp = dec.close() { process(imp) }
    printSummary()
}

// MARK: - Live mode (Bluetooth)

final class Live: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let WRITE = CBUUID(string: "1B7E8272-2877-41C3-B46E-CF057C562023")
    let PEN = CBUUID(string: PEN_UUID)
    var central: CBCentralManager!
    var pad: CBPeripheral?
    var activated = false
    let dec = Decoder()
    var gapTimer: Timer?
    var announced = false

    override init() { super.init(); central = CBCentralManager(delegate: self, queue: nil) }

    func centralManagerDidUpdateState(_ cm: CBCentralManager) {
        switch cm.state {
        case .poweredOn:
            print("\(clock()) Looking for a Lumen pad. Turn it on, and make sure IMPRA is closed on your phone and iPad")
            print("             (the pad only talks to one device at a time).")
            cm.scanForPeripherals(withServices: nil, options: nil)
        case .unauthorized:
            print("Bluetooth permission is off for this app. Open System Settings > Privacy & Security > Bluetooth,")
            print("switch on the app you ran this from (Terminal, iTerm, Claude, Codex...), then run it again.")
            exit(1)
        case .poweredOff:
            print("Bluetooth is off on this Mac. Turn it on and run again."); exit(1)
        default:
            print("\(clock()) Bluetooth state \(cm.state.rawValue), waiting...")
        }
    }

    func centralManager(_ cm: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        guard pad == nil else { return }
        let name = p.name ?? (ad[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard name.lowercased().contains("lumen") else { return }
        if let f = cfg.nameFilter, !name.lowercased().contains(f) { return }
        print("\(clock()) Found \(name), connecting...")
        pad = p; p.delegate = self; cm.stopScan(); cm.connect(p, options: nil)
    }

    func centralManager(_ cm: CBCentralManager, didConnect p: CBPeripheral) {
        print("\(clock()) Connected to \(p.name ?? "pad").")
        p.discoverServices(nil)
    }
    func centralManager(_ cm: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        print("\(clock()) Connect failed (\(error?.localizedDescription ?? "unknown")). Trying again...")
        pad = nil; activated = false; cm.scanForPeripherals(withServices: nil, options: nil)
    }
    func centralManager(_ cm: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        print("\(clock()) Pad disconnected. Looking for it again...")
        pad = nil; activated = false; cm.scanForPeripherals(withServices: nil, options: nil)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.properties.contains(.notify) || ch.properties.contains(.indicate) { p.setNotifyValue(true, for: ch) }
            if ch.uuid == WRITE && !activated {
                activated = true
                p.writeValue(Data([0x21, 0x01, 0x00]), for: ch, type: .withResponse)
                print("\n\(clock()) READY. Write on the pad at any angle. Pause for \(cfg.gap) s and it gets processed.")
                print("             Press Ctrl-C when you're done to see the summary.\n")
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value else { return }
        let hex = d.map { String(format: "%02x", $0) }.joined(separator: " ")
        rawLog.write("\(clock()) NOTIFY \(ch.uuid.uuidString): [\(d.count)] \(hex)  |\n".data(using: .utf8)!)
        guard ch.uuid == PEN else { return }
        dec.feed([UInt8](d))
        gapTimer?.invalidate()
        gapTimer = Timer.scheduledTimer(withTimeInterval: cfg.gap, repeats: false) { [weak self] _ in
            guard let self, let imp = self.dec.close() else { return }
            work.async {
                process(imp)
                print("\nReady for the next one.")
            }
        }
    }
}

// MARK: - Main

print("LumenTest  |  results folder: \(sessionDir)")
if cfg.useClaude { print("Claude reading is ON (\(cfg.model)).") }

// Load Apple's recognizer once up front, so its one-time start-up cost (seconds on
// the very first launch) never lands inside a measured impression.
print("Warming up Apple's on-device recognizer...", terminator: "")
let (_, warmMs) = timed {
    let zig: Stroke = (0..<40).map { StrokePoint(x: Double($0) * 10, y: $0 % 2 == 0 ? 0 : 60) }
    _ = VisionTextOrientation.detectHybrid([zig])
    _ = VisionTextOrientation.readback([zig])
}
print(String(format: " done (%.1f s, not counted in any timing).", warmMs / 1000))

if let r = cfg.replayPath {
    replay(r)
    exit(0)
}

signal(SIGINT, SIG_IGN)
let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigSrc.setEventHandler {
    work.sync {}           // let an impression in progress finish
    printSummary()
    exit(0)
}
sigSrc.resume()

let live = Live()
RunLoop.main.run()
