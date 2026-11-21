import AppKit
import GTubeCore
import SwiftUI

/// "Ambient color": the dominant color of the album art that is playing,
/// like music.youtube.com tints its pages.
enum Ambient {
    static func rgbToHSL(_ c: (Double, Double, Double)) -> (Double, Double, Double) {
        let (r, g, b) = c
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        if mx - mn < 1e-6 { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h *= 60
        return (h, s, l)
    }

    static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        if s == 0 { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hue(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let hh = h / 360
        return (hue(hh + 1 / 3), hue(hh), hue(hh - 1 / 3))
    }

    /// The most prominent color of an image: the strongest hue (by area and
    /// saturation), with its lightness evened out so text stays readable.
    /// Black and white artwork gives a neutral grey.
    static func dominantColor(_ image: NSImage) -> Color? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let n = 64
        var buf = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &buf, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        let bins = 24
        var weight = [Double](repeating: 0, count: bins)
        var sum = [(Double, Double, Double)](repeating: (0, 0, 0), count: bins)
        var total = 0.0, count = 0.0
        var avg = (0.0, 0.0, 0.0)
        for i in stride(from: 0, to: buf.count, by: 4) {
            let a = Double(buf[i + 3]) / 255
            if a < 0.5 { continue }
            let rgb = (Double(buf[i]) / 255 / a, Double(buf[i + 1]) / 255 / a, Double(buf[i + 2]) / 255 / a)
            let (h, s, l) = rgbToHSL(rgb)
            avg = (avg.0 + rgb.0, avg.1 + rgb.1, avg.2 + rgb.2)
            count += 1
            // Ignore near-black (letterboxing), near-white and grey pixels.
            if !(0.12...0.92).contains(l) || s < 0.18 { continue }
            let w = s * s * max(1 - abs(l - 0.5) * 1.4, 0.05)
            let b = Int(h / 360 * Double(bins)) % bins
            weight[b] += w
            sum[b] = (sum[b].0 + rgb.0 * w, sum[b].1 + rgb.1 * w, sum[b].2 + rgb.2 * w)
            total += w
        }
        if count == 0 { return nil }
        // Colorful pixels must cover a meaningful part of the image.
        if total / count < 0.02 {
            let (h, s, _) = rgbToHSL((avg.0 / count, avg.1 / count, avg.2 / count))
            let c = hslToRGB(h, min(s, 0.12), 0.5)
            return Color(red: c.0, green: c.1, blue: c.2)
        }
        func around(_ i: Int) -> Double { weight[(i + bins - 1) % bins] * 0.5 + weight[i] + weight[(i + 1) % bins] * 0.5 }
        let best = (0..<bins).max { around($0) < around($1) } ?? 0
        var c = (0.0, 0.0, 0.0)
        var ws = 0.0
        for i in [(best + bins - 1) % bins, best, (best + 1) % bins] {
            c = (c.0 + sum[i].0, c.1 + sum[i].1, c.2 + sum[i].2)
            ws += weight[i]
        }
        guard ws > 0 else { return nil }
        let (h, s, _) = rgbToHSL((c.0 / ws, c.1 / ws, c.2 / ws))
        let out = hslToRGB(h, min(max(s, 0.3), 0.8), 0.5)
        return Color(red: out.0, green: out.1, blue: out.2)
    }
}

/// The spectrum visualizer behind the Music player bar.
///
/// The levels come from mpv itself: an audio filter on a side branch (the
/// sound you hear passes through untouched) downmixes to mono at 11 kHz,
/// splits it into log-spaced bands with an FFT filter bank and measures each
/// band's mean magnitude for every 23 ms window. `ametadata` prints those
/// values with the window's timestamp into a FIFO that a reader thread
/// parses. The view shows the window that matches `audio-pts` (what is being
/// heard right now), so the bars stay in sync.
enum Spectrum {
    static let bands = 16
    static let rate = 11025
    static let lowHz = 45.0
    static let highHz = 4600.0
    /// The FFT filter bank delays the levels by about this much.
    static let filterDelay = 0.03

    nonisolated(unsafe) private static var status = 0 // 0 unchecked, 1 checking, 2 usable, 3 unavailable
    nonisolated(unsafe) private static var fifo: String?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var frames: [(Double, [Float])] = []

    static func graph(_ out: String) -> String {
        let ratio = pow(highHz / lowHz, 1 / Double(bands - 1))
        let pan = (0..<bands).map { "c\($0)=c0" }.joined(separator: "|")
        let r = String(format: "%.6f", ratio)
        return "asplit[ao][a];"
            + "[a]aformat=channel_layouts=mono,aresample=\(rate),pan=\(bands) channels|\(pan),"
            + "firequalizer=gain='if(between(f,\(lowHz)*pow(\(r),ch-0.5),\(lowHz)*pow(\(r),ch+0.5)),0,-80)':multi=1:delay=0.02,"
            + "aspectralstats=win_size=256:overlap=0:measure=mean,"
            + "ametadata=mode=print:direct=1:file='\(out)',anullsink;"
            + "[ao]anull"
    }

    /// The value for mpv's `af` property, once the filter is known to work.
    static var audioFilter: String? {
        guard status == 2, let f = fifo else { return nil }
        let g = graph(f)
        return "@gtubeviz:lavfi=graph=%\(g.utf8.count)%\(g)"
    }

    /// Checks (once) that this system's FFmpeg can run the graph.
    @MainActor static func initialize() {
        if status != 0 { return }
        status = 1
        guard let ff = Tools.ffmpeg else {
            Log.warn("spectrum visualizer unavailable: ffmpeg not found")
            status = 3
            return
        }
        Task {
            let out = try? await Tools.run(ff, ["-nostdin", "-hide_banner", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-t", "0.3",
                                                 "-af", graph("/dev/null"), "-f", "null", "-"])
            guard let out, out.status == 0 else {
                Log.warn("spectrum visualizer unavailable: \(out.map { String(decoding: $0.stderr, as: UTF8.self).components(separatedBy: "\n").first ?? "" } ?? "ffmpeg failed")")
                status = 3
                return
            }
            guard openFifo() else {
                status = 3
                return
            }
            status = 2
            AppModel.shared.player.updateAudioFilter()
        }
    }

    private static func openFifo() -> Bool {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("gtube-spectrum-\(getpid())")
        // Anything ffmpeg's filter syntax would read as syntax rules this out.
        if path.contains(where: { "'\\:,;[]".contains($0) }) { return false }
        unlink(path)
        if mkfifo(path, 0o600) != 0 {
            Log.warn("spectrum: could not create \(path)")
            return false
        }
        // Opened read *and* write, so the reader never sees end-of-file and
        // FFmpeg's open() for writing never waits for a reader.
        let fd = open(path, O_RDWR)
        if fd < 0 {
            Log.warn("spectrum: could not open \(path)")
            return false
        }
        fifo = path
        let t = Thread { readLevels(fd) }
        t.name = "spectrum"
        t.start()
        return true
    }

    /// Parses `ametadata` output: a "frame:N pts:P pts_time:T" line, then one
    /// "lavfi.aspectralstats.<band>.mean=<value>" line per band.
    private static func readLevels(_ fd: Int32) {
        guard let f = fdopen(fd, "r") else { return }
        var line = [CChar](repeating: 0, count: 512)
        var cur: (Double, [Float])?
        while fgets(&line, Int32(line.count), f) != nil {
            let l = String(cString: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if let r = l.range(of: "pts_time:") {
                cur = Double(l[r.upperBound...].trimmingCharacters(in: .whitespaces)).map { ($0, [Float](repeating: 0, count: bands)) }
                continue
            }
            guard l.hasPrefix("lavfi.aspectralstats."), let eq = l.range(of: ".mean=") else { continue }
            let bandStr = l[l.index(l.startIndex, offsetBy: "lavfi.aspectralstats.".count)..<eq.lowerBound]
            guard let band = Int(bandStr), let value = Float(l[eq.upperBound...]), cur != nil else { continue }
            if (1...bands).contains(band) { cur!.1[band - 1] = value }
            if band == bands, let frame = cur {
                cur = nil
                lock.lock()
                // Time went backwards: a seek, or the next track.
                if let last = frames.last, frame.0 < last.0 - 0.05 { frames.removeAll() }
                frames.append(frame)
                if frames.count > 600 { frames.removeFirst(frames.count - 600) }
                lock.unlock()
            }
        }
    }

    /// The band magnitudes of the window being heard at `pts`.
    static func levels(at pts: Double) -> [Float]? {
        let pts = pts - filterDelay
        lock.lock()
        defer { lock.unlock() }
        var drop = 0
        while frames.count - drop > 1 && frames[drop + 1].0 <= pts { drop += 1 }
        if drop > 0 { frames.removeFirst(drop) }
        guard let f = frames.first, f.0 <= pts + 0.03, pts - f.0 < 0.25 else { return nil }
        return f.1
    }

    static func cleanup() {
        if let f = fifo { unlink(f) }
    }
}

/// Per-band corrections (dB): the lowest bands are narrower than the filter
/// bank's resolution and read low.
private let tilt: [Float] = [6.0, 3.5, 2.0, 1.0, 0.5, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 0.5, 1.0, 1.5, 2.5]
/// The range shown, below the loudest band of the last few seconds.
private let rangeDB: Float = 36

/// The animated bars: bass in the middle, treble towards both edges.
@MainActor
final class SpectrumState {
    var levels = [Float](repeating: 0, count: Spectrum.bands)
    /// Loudest recent band (dB), falling slowly: an automatic gain.
    var reference: Float = -200
    var last: Date?

    func step(playing: Bool, pts: Double?, now: Date) {
        let dt = Float(min(max(now.timeIntervalSince(last ?? now.addingTimeInterval(-1 / 60)), 0), 0.1))
        last = now
        let target = playing ? pts.flatMap(Spectrum.levels).map { normalize($0, dt) } : nil
        for k in 0..<levels.count {
            let t = target?[k] ?? 0
            if t > levels[k] {
                levels[k] += (t - levels[k]) * min(dt * 28, 1)
            } else {
                // Falls at a constant speed, like a meter.
                levels[k] = max(levels[k] - dt * 1.4, t)
            }
        }
    }

    func normalize(_ m: [Float], _ dt: Float) -> [Float] {
        var db = [Float](repeating: 0, count: m.count)
        for k in 0..<m.count { db[k] = 20 * log10(max(m[k], 1e-9)) + tilt[k] }
        let loudest = db.max() ?? -200
        reference = max(reference - 5 * dt, loudest)
        // Near-silence shows nothing.
        if reference < -115 { return [Float](repeating: 0, count: m.count) }
        return db.map { v in
            let x = min(max((v - (reference - rangeDB)) / rangeDB, 0), 1)
            return x * x
        }
    }

    /// Catmull-Rom interpolation between band levels.
    func sample(_ x: Float) -> Float {
        let n = levels.count
        let i = min(max(Int(x.rounded(.down)), 0), n - 1)
        let t = x - Float(i)
        func at(_ j: Int) -> Float { levels[min(max(j, 0), n - 1)] }
        let (p0, p1, p2, p3) = (at(i - 1), at(i), at(i + 1), at(i + 2))
        let v = 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t)
        return min(max(v, 0), 1)
    }
}

struct SpectrumView: View {
    var color: Color = .primary
    var heightFactor: CGFloat = 0.78
    @State private var state = SpectrumState()
    @State private var app = AppModel.shared

    var body: some View {
        let p = app.player
        let live = Config.settings.musicVisualizer && p.isMusicOwned && !p.paused
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !live && state.levels.allSatisfy { $0 < 0.004 })) { tl in
            Canvas { ctx, size in
                state.step(playing: live, pts: live ? p.audioPts : nil, now: tl.date)
                let barW: CGFloat = 4, gap: CGFloat = 3
                let step = barW + gap
                let half = Int((size.width / 2 / step).rounded(.down))
                guard half >= 2 else { return }
                let cx = size.width / 2
                for i in 0..<half {
                    let pos = Float(i) / Float(half - 1)
                    let v = state.sample(pos * Float(Spectrum.bands - 1))
                    let bh = (CGFloat(v) * size.height * heightFactor).rounded()
                    if bh < 1 { continue }
                    let fade = 1 - 0.65 * Double(pos * pos)
                    let grad = Gradient(colors: [color.opacity(0.34 * fade), color.opacity(0.04 * fade)])
                    let off = gap / 2 + CGFloat(i) * step
                    for x in [cx + off, cx - off - barW] {
                        let r = CGRect(x: x, y: size.height - bh, width: barW, height: bh)
                        ctx.fill(Path(r), with: .linearGradient(grad, startPoint: CGPoint(x: 0, y: size.height), endPoint: CGPoint(x: 0, y: 0)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
