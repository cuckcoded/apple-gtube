import Foundation

// Song lyrics, timed line by line when possible. YouTube Music's own come
// first: its Android app gets them with each line's time, which the web
// client doesn't. When those aren't timed (or there are none), LRCLIB
// (lrclib.net, an open database of synced lyrics) is asked; untimed text from
// either is the last resort.

let androidMusicVersion = "7.21.50"
let lrclibAPI = "https://lrclib.net/api"

/// One line of timed lyrics.
public struct LyricLine: Equatable, Sendable {
    /// Seconds into the song.
    public var start: Double
    public var text: String
}

public struct Lyrics: Equatable, Sendable {
    /// The whole text, one line per line.
    public var text = ""
    /// The lines with their times; empty when the lyrics aren't timed.
    public var lines: [LyricLine] = []
    /// Who provides them ("Source: Musixmatch", "LRCLIB").
    public var source: String?
    /// LRCLIB knows the song has no words.
    public var instrumental = false

    public static func plain(_ text: String, source: String?) -> Lyrics {
        Lyrics(text: text, lines: [], source: source)
    }

    public static func timed(_ lines: [LyricLine], source: String?) -> Lyrics {
        let sorted = lines.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
        return Lyrics(text: sorted.map(\.text).joined(separator: "\n"), lines: sorted, source: source)
    }

    public var isTimed: Bool { !lines.isEmpty }

    /// The line being sung at `t` seconds (nil before the first one).
    public func lineAt(_ t: Double) -> Int? {
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].start <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }
}

/// The song LRCLIB is asked about.
public struct Song: Equatable, Sendable {
    public var title: String
    public var artists: [String]
    /// Seconds.
    public var duration: Double?
    public init(title: String, artists: [String], duration: Double?) {
        self.title = title
        self.artists = artists
        self.duration = duration
    }
}

public enum LyricsParse {
    /// The Android app's lyrics (`timedLyricsModel`): timed when the lines
    /// carry cue ranges, plain when YouTube only has static lyrics.
    public static func timed(_ v: JSON) -> Lyrics? {
        guard let data = v.findFirst("timedLyricsModel")?["lyricsData"], let list = data["timedLyricsData"]?.array else { return nil }
        let source = data["sourceMessage"]?.string?.trimmingCharacters(in: .whitespaces)
        var lines: [LyricLine] = []
        var timed = true
        for e in list {
            let text = (e["lyricLine"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let start = e.pointer("/cueRange/startTimeMilliseconds")?.numeric
            if start == nil { timed = false }
            lines.append(LyricLine(start: (start ?? 0) / 1000, text: text))
        }
        if lines.allSatisfy({ $0.text.isEmpty }) { return nil }
        let src = (source?.isEmpty ?? true) ? nil : source
        return timed ? Lyrics.timed(lines, source: src) : Lyrics.plain(lines.map(\.text).joined(separator: "\n"), source: src)
    }

    /// `mm:ss.xx` (also `mm:ss`, `mm:ss:xx`, `hh:mm:ss.xx`) in seconds.
    static func lrcTime(_ tag: String) -> Double? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") } }) else { return nil }
        func num(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".")) }
        if parts.count == 3 {
            let (a, b, c) = (parts[0], parts[1], parts[2])
            // mm:ss:xx (hundredths after a colon) or hh:mm:ss.xx
            if !c.contains(".") && c.count <= 2 && !b.contains(".") {
                guard let x = num(a), let y = num(b), let z = num(c) else { return nil }
                return x * 60 + y + z / 100
            }
            guard let h = num(a), let m = num(b), let s = num(c) else { return nil }
            return h * 3600 + m * 60 + s
        }
        guard let m = num(parts[0]), let s = num(parts[1]) else { return nil }
        return m * 60 + s
    }

    /// Drops enhanced LRC's per-word times (`<00:12.34>`).
    static func stripWordTimes(_ s: String) -> String {
        var out = ""
        var rest = Substring(s)
        while let i = rest.firstIndex(of: "<") {
            let after = rest[rest.index(after: i)...]
            if let j = after.firstIndex(of: ">"), lrcTime(String(after[..<j])) != nil {
                out += rest[..<i]
                rest = after[after.index(after: j)...]
            } else {
                out += rest[...i]
                rest = after
            }
        }
        out += rest
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Synced lyrics in the LRC format: `[mm:ss.xx]text` lines, possibly with
    /// several times per line, ID tags and an `[offset:±ms]`.
    public static func lrc(_ s: String) -> [LyricLine] {
        var offset = 0.0
        var lines: [LyricLine] = []
        for raw in s.components(separatedBy: "\n") {
            var rest = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            var times: [Double] = []
            while rest.hasPrefix("[") {
                let r = rest.dropFirst()
                guard let end = r.firstIndex(of: "]") else { break }
                let tag = String(r[..<end])
                if let t = lrcTime(tag) {
                    times.append(t)
                } else if tag.hasPrefix("offset:") {
                    // Positive: the lyrics come sooner.
                    var o = tag.dropFirst("offset:".count).trimmingCharacters(in: .whitespaces)
                    if o.hasPrefix("+") { o.removeFirst() }
                    offset = (Double(o) ?? 0) / 1000
                }
                rest = r[r.index(after: end)...]
                while rest.first?.isWhitespace == true { rest = rest.dropFirst() }
            }
            let text = stripWordTimes(String(rest))
            lines += times.map { LyricLine(start: $0, text: text) }
        }
        for i in lines.indices { lines[i].start = max(lines[i].start - offset, 0) }
        return lines.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
    }

    static func norm(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// "Song (Official Video)" → "Song": what music video titles add.
    public static func cleanTitle(_ t: String) -> String {
        let noise: Set<String> = ["official", "video", "audio", "lyric", "lyrics", "visualizer", "visualiser", "remaster", "remastered", "hd", "4k", "mv", "clip", "explicit"]
        var out = ""
        var rest = Substring(t)
        while let i = rest.firstIndex(where: { $0 == "(" || $0 == "[" }) {
            let close: Character = rest[i] == "(" ? ")" : "]"
            guard let j = rest[i...].firstIndex(of: close) else { break }
            out += rest[..<i]
            let inner = rest[rest.index(after: i)..<j].lowercased()
            let words = inner.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
            if !words.contains(where: noise.contains) {
                out += rest[i...j]
            }
            rest = rest[rest.index(after: j)...]
        }
        out += rest
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public struct LrclibRecord: Decodable, Sendable {
    public var trackName = ""
    public var artistName = ""
    public var duration: Double?
    public var instrumental = false
    public var plainLyrics: String?
    public var syncedLyrics: String?

    public init(trackName: String, artistName: String, duration: Double?, instrumental: Bool = false, plainLyrics: String?, syncedLyrics: String?) {
        self.trackName = trackName
        self.artistName = artistName
        self.duration = duration
        self.instrumental = instrumental
        self.plainLyrics = plainLyrics
        self.syncedLyrics = syncedLyrics
    }

    enum CodingKeys: String, CodingKey { case trackName, artistName, duration, instrumental, plainLyrics, syncedLyrics }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        trackName = (try? c.decodeIfPresent(String.self, forKey: .trackName)) ?? ""
        artistName = (try? c.decodeIfPresent(String.self, forKey: .artistName)) ?? ""
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        instrumental = ((try? c.decodeIfPresent(Bool.self, forKey: .instrumental)) ?? nil) ?? false
        plainLyrics = try? c.decodeIfPresent(String.self, forKey: .plainLyrics)
        syncedLyrics = try? c.decodeIfPresent(String.self, forKey: .syncedLyrics)
    }

    func synced() -> [LyricLine]? {
        guard let s = syncedLyrics else { return nil }
        let lines = LyricsParse.lrc(s)
        return lines.contains { !$0.text.isEmpty } ? lines : nil
    }

    func plain() -> String? {
        guard let p = plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return nil }
        return p
    }

    /// Lyrics for the song, when this is the song: the same artist, and (for
    /// timing) the same length.
    func lyrics(for song: Song, timedOnly: Bool) -> Lyrics? {
        let artist = song.artists.first.map(LyricsParse.norm) ?? ""
        let theirs = LyricsParse.norm(artistName)
        if !artist.isEmpty && !theirs.contains(artist) && !artist.contains(theirs) { return nil }
        var sameLength = true
        if let a = song.duration, let b = duration { sameLength = abs(a - b) <= 3 }
        let source = "LRCLIB"
        if sameLength, let lines = synced() { return Lyrics.timed(lines, source: source) }
        if timedOnly { return nil }
        if instrumental { return Lyrics(source: source, instrumental: true) }
        return plain().map { Lyrics.plain($0, source: source) }
    }
}

/// The best of LRCLIB's search results: timed lyrics of the same length first,
/// else the first plain ones.
public func pickLrclib(_ records: [LrclibRecord], _ song: Song) -> Lyrics? {
    let title = LyricsParse.norm(song.title)
    func titled(_ r: LrclibRecord) -> Bool { title.isEmpty || LyricsParse.norm(r.trackName) == title }
    let ordered = records.filter(titled) + records.filter { !titled($0) }
    return ordered.lazy.compactMap { $0.lyrics(for: song, timedOnly: true) }.first
        ?? ordered.lazy.compactMap { $0.lyrics(for: song, timedOnly: false) }.first
}

extension Client {
    /// YouTube Music's lyrics for a song's lyrics tab (`MPLY…`), asked as the
    /// Android app so they come timed. Sent without the session.
    func androidLyrics(_ browseId: String) async throws -> Lyrics? {
        let s = session
        let body: [String: Any] = [
            "browseId": browseId,
            "context": ["client": ["clientName": "ANDROID_MUSIC", "clientVersion": androidMusicVersion, "androidSdkVersion": 34, "hl": s.hl, "gl": s.gl]],
        ]
        var req = URLRequest(url: URL(string: "\(musicOrigin)/youtubei/v1/browse?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.httpBody = JSONBody.data(body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("com.google.android.apps.youtube.music/\(androidMusicVersion) (Linux; U; Android 14) gzip", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await http.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) { throw HTTPStatusError(status: status) }
        let v = try JSON(data: data)
        return LyricsParse.timed(v) ?? Music.lyrics(v)
    }

    public func musicLyrics(_ browseId: String) async throws -> Lyrics? {
        do {
            if let l = try await androidLyrics(browseId) { return l }
        } catch {
            Log.warn("lyrics as the Android app: \(error.localizedDescription)")
        }
        return Music.lyrics(try await musicBrowse(browseId))
    }

    func lrclibGet(_ path: String, _ query: [(String, String)]) async throws -> Data? {
        var comps = URLComponents(string: "\(lrclibAPI)/\(path)")!
        comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        var req = URLRequest(url: comps.url!)
        req.setValue("GTube/\(gtubeVersion)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await http.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        if !(200..<300).contains(status) { throw HTTPStatusError(status: status) }
        return data
    }

    /// LRCLIB's lyrics for the song: its exact match (same title, artist and
    /// length) when that is timed, else the best search result.
    public func lrclib(_ song: Song) async throws -> Lyrics? {
        let title = LyricsParse.cleanTitle(song.title)
        if title.isEmpty || song.artists.isEmpty { return nil }
        let song = Song(title: title, artists: song.artists, duration: song.duration)
        var exact: Lyrics?
        if let d = song.duration {
            // (No album: YouTube Music's album names often differ.)
            let q = [("track_name", song.title), ("artist_name", song.artists.joined(separator: ", ")), ("duration", String(Int(d.rounded())))]
            if let data = try await lrclibGet("get", q) {
                if let r = try? JSONDecoder().decode(LrclibRecord.self, from: data) {
                    exact = r.lyrics(for: song, timedOnly: false)
                    if let e = exact, e.isTimed || e.instrumental { return e }
                }
            }
        }
        var found: Lyrics?
        if let data = try await lrclibGet("search", [("track_name", song.title), ("artist_name", song.artists[0])]) {
            found = pickLrclib((try? JSONDecoder().decode([LrclibRecord].self, from: data)) ?? [], song)
        }
        if let f = found, f.isTimed { return f }
        return exact ?? found
    }
}

/// The best lyrics there are for a song: YouTube Music's when timed, else
/// LRCLIB's when timed, else whichever has the text (YouTube's first).
public func findLyrics(_ client: Client, lyricsId: String?, song: Song, useLrclib: Bool) async -> Lyrics? {
    var plain: Lyrics?
    if let id = lyricsId {
        do {
            let l = try await client.musicLyrics(id)
            if let l, l.isTimed { return l }
            plain = l
        } catch {
            Log.warn("lyrics: \(error.localizedDescription)")
        }
    }
    if useLrclib {
        do {
            if let l = try await client.lrclib(song) {
                if l.isTimed { return l }
                if plain == nil { plain = l }
            }
        } catch {
            Log.warn("LRCLIB: \(error.localizedDescription)")
        }
    }
    return plain
}

public let gtubeVersion = "1.0.0"
