import Foundation

// Telling YouTube what was watched, the way its web player does, so videos
// land in the watch history with how far they got and YouTube can offer to
// pick them up (here, on youtube.com or on any other device).
//
// The InnerTube `player` response carries the reporting URLs
// (`playbackTracking`) and, for a video watched part of the way, where to
// continue. A view then sends one `api/stats/playback` request when playback
// starts and `api/stats/watchtime` requests with the stretches that played:
// after 10, 20 and 30 seconds, every 40 seconds after that, on pause, and a
// final one when the video is left.

/// What the `player` endpoint says about a video for reporting and resuming.
public struct Tracking: Sendable {
    public var playbackURL: String?
    public var watchtimeURL: String?
    /// Where YouTube would continue the video (seconds).
    public var resume: Double?
    public var length: Double?
}

public func parseTracking(_ v: JSON) -> Tracking {
    func url(_ key: String) -> String? {
        v.pointer("/playbackTracking/\(key)/baseUrl")?.string.flatMap { $0.hasPrefix("https://") ? $0 : nil }
    }
    return Tracking(
        playbackURL: url("videostatsPlaybackUrl"),
        watchtimeURL: url("videostatsWatchtimeUrl"),
        resume: v.pointer("/playerConfig/playbackStartConfig/startSeconds")?.numeric.flatMap { $0 > 0 ? $0 : nil },
        length: v.pointer("/videoDetails/lengthSeconds")?.numeric.flatMap { $0 > 0 ? $0 : nil }
    )
}

extension Client {
    /// Asks the `player` endpoint (as youtube.com does when a video opens) for
    /// the reporting URLs and resume position. Streams still come from yt-dlp.
    public func tracking(_ videoId: String) async throws -> Tracking {
        var ctx: [String: Any] = ["html5Preference": "HTML5_PREF_WANTS"]
        if let sts = await signatureTimestamp() { ctx["signatureTimestamp"] = sts }
        let v = try await post(as: .web, "player", [
            "videoId": videoId, "racyCheckOk": true, "contentCheckOk": true,
            "playbackContext": ["contentPlaybackContext": ctx],
        ])
        let t = parseTracking(v)
        if t.watchtimeURL == nil {
            let status = v.pointer("/playabilityStatus/status")?.string ?? "?"
            let reason = v.pointer("/playabilityStatus/reason")?.string ?? ""
            throw APIError("no playback tracking for \(videoId) (\(status) \(reason))")
        }
        return t
    }

    nonisolated(unsafe) private static var stsTried = false

    /// The player script version the `player` endpoint wants to hear about.
    func signatureTimestamp() async -> Int? {
        if let s = session.sts { return s }
        if Self.stsTried { return nil }
        Self.stsTried = true
        guard let api = try? await getText("https://www.youtube.com/iframe_api"),
              let id = firstMatch(#"player\\?/([0-9a-fA-F]{8})\\?/"#, api),
              let js = try? await getText("https://www.youtube.com/s/player/\(id)/player_ias.vflset/en_US/base.js"),
              let sts = firstMatch(#"(?:signatureTimestamp|sts)\s*:\s*(\d{5})"#, js).flatMap({ Int($0) }) else { return nil }
        Log.info("player script \(id): signature timestamp \(sts)")
        setSTS(sts)
        return sts
    }

    /// Sends one report.
    public func ping(_ url: String) async throws {
        if ProcessInfo.processInfo.environment["GTUBE_STATS_DRY_RUN"] != nil {
            let q = URLComponents(string: url)?.queryItems ?? []
            let fields = ["docid", "cmt", "st", "et", "state", "rt", "len", "rate", "final"].compactMap { k in
                q.first { $0.name == k }?.value.map { "\(k)=\($0)" }
            }
            let kind = URL(string: url)?.lastPathComponent ?? ""
            Log.info("stats (dry run) \(kind): \(fields.joined(separator: " "))")
            return
        }
        let s = session
        var headers = ["Referer": "https://www.youtube.com/", "Origin": "https://www.youtube.com", "Cookie": s.cookies.header(for: "s.youtube.com")]
        if let v = s.visitorData { headers["X-Goog-Visitor-Id"] = v }
        let (_, resp) = try await get(url, headers: headers)
        if !(200..<300).contains(resp.statusCode) { throw HTTPStatusError(status: resp.statusCode) }
    }
}

func firstMatch(_ pattern: String, _ s: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
          let r = Range(m.range(at: 1), in: s) else { return nil }
    return String(s[r])
}

/// Seconds as the web player writes them: at most 3 decimals, no trailing zeros.
func secs(_ t: Double) -> String {
    var s = String(format: "%.3f", max(t, 0))
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}

/// A random client playback nonce, the id of one view.
func nonce() -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    return String((0..<16).map { _ in alphabet[Int.random(in: 0..<64)] })
}

/// One view of one video: collects what played and says which reports are
/// due. Times are in seconds on any steady clock (`now`).
public final class Report {
    struct Segment: Equatable {
        var start: Double
        var end: Double
        var rate: Double
    }

    /// Seconds between watch-time reports while playing (the last one repeats).
    static let schedule: [Double] = [10, 10, 10, 40]

    public let video: String
    let cpn = nonce()
    var tracking: Tracking?
    let live: Bool
    let clientVersion: String
    let hl: String
    let gl: String
    var started: Double?
    var playbackSent = false
    var done: [Segment] = []
    var open: Segment?
    var lastNow = 0.0
    var position = 0.0
    var length = 0.0
    var nextAt: Double?
    var step = 0
    var finished = false

    public init(video: String, live: Bool, clientVersion: String, hl: String, gl: String) {
        self.video = video
        self.live = live
        self.clientVersion = clientVersion
        self.hl = hl
        self.gl = gl
    }

    /// The reporting URLs arrived; returns reports that were already due.
    public func setTracking(_ t: Tracking, now: Double) -> [String] {
        if length <= 0 { length = t.length ?? 0 }
        tracking = t
        var out: [String] = []
        if started != nil {
            if let p = playback() { out.append(p) }
            if let at = nextAt, now >= at {
                out += watchtime("playing", last: false, now: now)
                scheduleNext(now)
            }
        }
        return out
    }

    public func setLength(_ len: Double) {
        if len > 0 { length = len }
    }

    /// Playback is at `t` (playing at `rate`); returns the reports now due.
    public func time(_ t: Double, rate: Double, now: Double) -> [String] {
        if finished || !t.isFinite { return [] }
        let rate = rate > 0 ? rate : 1
        // Another speed: a new stretch, so each one has a single rate.
        if let s = open, abs(s.rate - rate) > 0.01 {
            close()
            open = Segment(start: s.end, end: s.end, rate: rate)
        }
        let expected = max(now - lastNow, 0) * rate
        if var s = open {
            if t >= s.end - 0.25 && t <= s.end + expected + 2 {
                // Moving on normally: the stretch grows.
                s.end = max(s.end, t)
                open = s
            } else {
                // A jump (seek, skipped segment): the stretch ends, a new one begins.
                close()
                open = Segment(start: t, end: t, rate: rate)
            }
        } else {
            open = Segment(start: t, end: t, rate: rate)
        }
        lastNow = now
        position = t
        var out: [String] = []
        if started == nil { started = now }
        // Starting, or playing again after a pause: reports follow the schedule.
        if nextAt == nil { scheduleNext(now) }
        if let p = playback() { out.append(p) }
        if tracking != nil, let at = nextAt, now >= at {
            out += watchtime("playing", last: false, now: now)
            scheduleNext(now)
        }
        return out
    }

    /// Playback paused.
    public func pause(now: Double) -> [String] {
        close()
        if started == nil || done.isEmpty { return [] }
        let out = watchtime("paused", last: false, now: now)
        // Reports continue on the usual schedule once playing again.
        nextAt = nil
        return out
    }

    /// The view ends (another video, closing the player, quitting).
    public func finish(now: Double) -> [String] {
        if finished { return [] }
        close()
        let out = started != nil ? watchtime("paused", last: true, now: now) : []
        finished = true
        return out
    }

    func close() {
        if let s = open, s.end > s.start { done.append(s) }
        open = nil
    }

    func scheduleNext(_ now: Double) {
        let gap = Self.schedule[min(step, Self.schedule.count - 1)]
        step += 1
        nextAt = now + gap
    }

    func common(_ now: Double) -> [(String, String)] {
        let rt = secs(started.map { now - $0 } ?? 0)
        var q: [(String, String)] = [
            ("ver", "2"), ("cpn", cpn), ("el", "detailpage"), ("ns", "yt"), ("cmt", secs(position)), ("fs", "0"),
            ("rt", rt), ("rtn", rt), ("lact", "0"), ("c", "WEB"), ("cver", clientVersion), ("cplayer", "UNIPLAYER"),
            ("cplatform", "DESKTOP"), ("hl", hl), ("cr", gl),
        ]
        if length > 0 { q.append(("len", secs(length))) }
        return q
    }

    /// The one "a view started" report (adds the video to the history).
    func playback() -> String? {
        if playbackSent { return nil }
        guard let base = tracking?.playbackURL else { return nil }
        playbackSent = true
        return withParams(base, common(started ?? 0))
    }

    /// A watch-time report with what played since the last one.
    func watchtime(_ state: String, last: Bool, now: Double) -> [String] {
        // Live streams count views, but there's no position to keep.
        if live {
            done.removeAll()
            return []
        }
        guard let base = tracking?.watchtimeURL else { return [] }
        var segs = done
        done.removeAll()
        if var s = open {
            // Report the stretch still playing up to now; it carries on from
            // here in the next report.
            if s.end > s.start { segs.append(s) }
            s.start = s.end
            open = s
        }
        if segs.isEmpty {
            if !last { return [] }
            segs.append(Segment(start: position, end: position, rate: 1))
        }
        func list(_ f: (Segment) -> String) -> String { segs.map(f).joined(separator: ",") }
        var q = common(now)
        q.append(("state", state))
        q.append(("st", list { secs($0.start) }))
        q.append(("et", list { secs($0.end) }))
        q.append(("volume", list { _ in "100" }))
        q.append(("muted", list { _ in "0" }))
        if segs.contains(where: { abs($0.rate - 1) > 0.01 }) {
            q.append(("rate", list { secs($0.rate) }))
        }
        if last { q.append(("final", "1")) }
        WatchPositions.record(video, position, length)
        return [withParams(base, q)]
    }
}

/// `base` with `params` set (replacing any it already has).
func withParams(_ base: String, _ params: [(String, String)]) -> String {
    guard var comps = URLComponents(string: base) else { return base }
    let names = Set(params.map(\.0))
    var items = (comps.queryItems ?? []).filter { !names.contains($0.name) }
    items += params.map { URLQueryItem(name: $0.0, value: $0.1) }
    comps.queryItems = items
    // URLComponents leaves "+" alone; the web player escapes it.
    comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    return comps.url?.absoluteString ?? base
}

/// Positions reported during this run, so a video opened again right away
/// continues even before YouTube's own record catches up. Memory only.
public enum WatchPositions {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reported: [String: (Double, Double)] = [:]

    static func finished(_ pos: Double, _ len: Double) -> Bool {
        len - pos < min(max(len * 0.05, 20), 90)
    }

    static func record(_ video: String, _ pos: Double, _ len: Double) {
        if len > 0 && pos.isFinite {
            lock.withLock { reported[video] = (pos, len) }
        }
    }

    /// Where to continue `video` from what was reported this run: 0 means
    /// from the start (watched to the end, or barely started).
    public static func position(_ video: String) -> Double? {
        guard let r = lock.withLock({ reported[video] }) else { return nil }
        let (pos, len) = r
        return finished(pos, len) || pos < 15 ? 0 : pos
    }

    /// How much of `video` was watched according to this run's reports (0...1).
    public static func progress(_ video: String) -> Double? {
        guard let r = lock.withLock({ reported[video] }) else { return nil }
        let (pos, len) = r
        return finished(pos, len) ? 1 : min(max(pos / len, 0), 1)
    }
}
