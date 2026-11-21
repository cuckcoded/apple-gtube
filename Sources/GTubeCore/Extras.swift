import CryptoKit
import Foundation

// Return YouTube Dislike and SponsorBlock.

public struct Votes: Decodable, Sendable {
    public var likes: Int?
    public var dislikes: Int?
}

public enum Extras {
    public static func dislikes(_ videoId: String) async throws -> Votes {
        let (data, resp) = try await Client.shared.get("https://returnyoutubedislikeapi.com/votes?videoId=\(videoId)")
        if !(200..<300).contains(resp.statusCode) { throw HTTPStatusError(status: resp.statusCode) }
        return try JSONDecoder().decode(Votes.self, from: data)
    }

    public static let sbCategories: [(id: String, label: String, color: String)] = [
        ("sponsor", "Sponsor", "#00d400"),
        ("selfpromo", "Unpaid/Self promotion", "#ffff00"),
        ("interaction", "Interaction reminder", "#cc00ff"),
        ("intro", "Intermission/Intro", "#00ffff"),
        ("outro", "Endcards/Credits", "#0202ed"),
        ("preview", "Preview/Recap", "#008fd6"),
        ("hook", "Hook/Greetings", "#395699"),
        ("music_offtopic", "Non-music section", "#ff9900"),
        ("filler", "Filler tangent", "#7300ff"),
        ("poi_highlight", "Highlight", "#ff1684"),
        ("exclusive_access", "Exclusive access", "#008a5c"),
    ]

    public static func sbLabel(_ cat: String) -> String {
        sbCategories.first { $0.id == cat }?.label ?? "Segment"
    }

    public static func sbColor(_ cat: String) -> String {
        sbCategories.first { $0.id == cat }?.color ?? "#888888"
    }

    /// SponsorBlock's server; `GTUBE_SPONSORBLOCK_API` points GTube at another one.
    public static var sbAPI: String {
        var s = ProcessInfo.processInfo.environment["GTUBE_SPONSORBLOCK_API"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if s.isEmpty { s = "https://sponsor.ajay.app" }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    struct SbVideo: Decodable {
        var videoID: String
        var segments: [SbSegment]
    }

    struct SbSegment: Decodable {
        var segment: [Double]
        var category: String
        var actionType: String
    }

    /// Uses the k-anonymity endpoint: only the first 4 hex characters of the
    /// video id's SHA-256 are sent, so SponsorBlock never learns what you watch.
    public static func segments(_ videoId: String) async throws -> [Segment] {
        let hash = SHA256.hash(data: Data(videoId.utf8)).map { String(format: "%02x", $0) }.joined()
        let cats = "[" + sbCategories.map { "\"\($0.id)\"" }.joined(separator: ",") + "]"
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        let url = "\(sbAPI)/api/skipSegments/\(hash.prefix(4))?categories=\(enc(cats))&actionTypes=\(enc(#"["skip","mute","full","poi"]"#))"
        let (data, resp) = try await Client.shared.get(url)
        if resp.statusCode == 404 { return [] }
        if !(200..<300).contains(resp.statusCode) { throw HTTPStatusError(status: resp.statusCode) }
        let videos = try JSONDecoder().decode([SbVideo].self, from: data)
        return videos.filter { $0.videoID == videoId }.flatMap(\.segments).compactMap { s in
            guard s.segment.count >= 2 else { return nil }
            return Segment(start: s.segment[0], end: s.segment[1], category: s.category, action: s.actionType)
        }.sorted { $0.start < $1.start }
    }

    /// Submits a segment the user marked. `userId` is the private, random ID
    /// SponsorBlock credits submissions to.
    public static func submit(videoId: String, userId: String, duration: Double, segment seg: Segment, api: String = sbAPI) async throws {
        let body: [String: Any] = [
            "videoID": videoId,
            "userID": userId,
            "userAgent": "GTube/\(gtubeVersion)",
            "service": "YouTube",
            "videoDuration": duration,
            "segments": [["segment": [seg.start, seg.end], "category": seg.category, "actionType": seg.action]],
        ]
        var req = URLRequest(url: URL(string: "\(api)/api/skipSegments")!)
        req.httpMethod = "POST"
        req.httpBody = JSONBody.data(body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await Client.shared.http.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) { return }
        throw APIError(submissionError(status: status, body: String(decoding: data, as: UTF8.self)))
    }

    public static func submissionError(status: Int, body: String) -> String {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let why: String
        switch status {
        case 400: why = "SponsorBlock found the segment invalid"
        case 403: why = "SponsorBlock's moderation rejected the segment"
        case 409: why = "This segment has already been submitted"
        case 429: why = "Too many submissions, try again later"
        default: why = "SponsorBlock couldn't take the segment"
        }
        if text.isEmpty || text.hasPrefix("<") { return "\(why) (\(status))" }
        return "\(why): \(text.prefix(300))"
    }

    /// The private ID SponsorBlock credits submissions to; made once.
    public static func userId() -> String {
        let id = Config.settings.sbUserId
        if id.count >= 32 { return id }
        var bytes = [UInt8](repeating: 0, count: 24)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let new = bytes.map { String(format: "%02x", $0) }.joined()
        Config.update { $0.sbUserId = new }
        return new
    }
}

public struct Segment: Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var category: String
    public var action: String
    public init(start: Double, end: Double, category: String, action: String) {
        self.start = start
        self.end = end
        self.category = category
        self.action = action
    }
}

public enum Format {
    /// "12K", "1.2M"…
    public static func count(_ n: Int) -> String {
        let f = Double(n)
        func one(_ v: Double, _ suffix: String) -> String {
            let s = String(format: "%.1f", v)
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + suffix
        }
        if n >= 1_000_000_000 { return one(f / 1e9, "B") }
        if n >= 1_000_000 { return one(f / 1e6, "M") }
        if n >= 10_000 { return String(format: "%.0fK", f / 1e3) }
        if n >= 1_000 { return one(f / 1e3, "K") }
        return String(n)
    }

    /// "3:05", "1:02:03".
    public static func time(_ t: Double) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "1:23.4" (or "1:02:03.4").
    public static func preciseTime(_ t: Double) -> String {
        let tenths = Int((max(t, 0) * 10).rounded())
        let (s, tenth) = (tenths / 10, tenths % 10)
        if s >= 3600 { return String(format: "%d:%02d:%02d.%d", s / 3600, s / 60 % 60, s % 60, tenth) }
        return String(format: "%d:%02d.%d", s / 60, s % 60, tenth)
    }

    /// "1:23.4", "83.4", "1:02:03" → seconds.
    public static func parseTime(_ text: String) -> Double? {
        var total = 0.0
        for part in text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false) {
            guard let v = Double(part.trimmingCharacters(in: .whitespaces)), !v.isNaN, v >= 0 else { return nil }
            total = total * 60 + v
        }
        return total
    }

    /// "3:45" / "1:02:03" in seconds (nil for 0 or garbage).
    public static func parseLength(_ s: String) -> Double? {
        var acc = 0.0
        for p in s.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false) {
            guard let n = Double(p) else { return nil }
            acc = acc * 60 + n
        }
        return acc > 0 ? acc : nil
    }
}
