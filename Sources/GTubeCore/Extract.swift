import Foundation

// Stream extraction with yt-dlp.
//
// GTube runs yt-dlp itself (rather than through mpv's ytdl_hook) so it can
// honour `available_at`: when YouTube's player response holds a pre-roll ad,
// the stream URLs return 403 until that ad could have been skipped. Waiting
// exactly that long starts playback as early as YouTube allows.

/// Finding the command-line tools GTube uses (yt-dlp, deno, ffmpeg).
public enum Tools {
    /// Where tools may live: Homebrew, MacPorts, ~/.local/bin, the system's,
    /// then the copies inside GTube.app (system ones are usually newer).
    public static var searchPath: [String] {
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for d in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "\(home)/.local/bin", "\(home)/.deno/bin", "/usr/bin", "/bin"] where !dirs.contains(d) {
            dirs.append(d)
        }
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent().path, !dirs.contains(exe) {
            dirs.append(exe)
        }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("bin").path, !dirs.contains(res) {
            dirs.append(res)
        }
        return dirs
    }

    public static func find(_ name: String) -> String? {
        for d in searchPath {
            let p = (d as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    public static var ytdlp: String? { find("yt-dlp") }
    public static var ffmpeg: String? { find("ffmpeg") }

    /// The environment child processes get: yt-dlp finds deno and ffmpeg through PATH.
    public static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath.joined(separator: ":")
        return env
    }

    public struct Output: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: Data
    }

    /// Runs a tool to completion. Cancelling the task terminates it.
    public static func run(_ path: String, _ args: [String]) async throws -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        final class Box: @unchecked Sendable {
            var out = Data()
            var err = Data()
        }
        let box = Box()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Output, Error>) in
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    box.out = out.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    box.err = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                p.terminationHandler = { proc in
                    let status = proc.terminationStatus
                    group.notify(queue: .global()) {
                        cont.resume(returning: Output(status: status, stdout: box.out, stderr: box.err))
                    }
                }
                do {
                    try p.run()
                } catch {
                    p.terminationHandler = nil
                    try? out.fileHandleForWriting.close()
                    try? err.fileHandleForWriting.close()
                    cont.resume(throwing: APIError("Could not run \((path as NSString).lastPathComponent): \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
    }
}

public struct Streams: Sendable {
    /// What mpv should load: a plain URL, or an `edl://` joining separate video
    /// and audio streams into one file.
    public var url: String
    public var userAgent: String?
    /// Unix time (seconds) before which the stream URLs are refused.
    public var availableAt: Double?
    public var captions: Captions
    /// The video heights there are formats for, tallest first.
    public var heights: [Int]
    /// The height of the video picked.
    public var height: Int?
}

/// A video's subtitles, as yt-dlp lists them.
public struct Captions: Equatable, Sendable {
    /// Uploaded tracks (by name), then auto-generated ones.
    public var tracks: [CaptionTrack] = []
    /// Languages YouTube can translate into: (code, name), by name.
    public var translations: [SubtitleTranslation] = []
    public init(tracks: [CaptionTrack] = [], translations: [SubtitleTranslation] = []) {
        self.tracks = tracks
        self.translations = translations
    }
}

public struct SubtitleTranslation: Equatable, Hashable, Sendable {
    public var code: String
    public var name: String
    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }
}

public struct CaptionTrack: Equatable, Hashable, Sendable {
    /// Language code, e.g. "en" or "pt-BR".
    public var lang: String
    /// e.g. "English" or "English (auto-generated)".
    public var name: String
    /// Made by YouTube's speech recognition.
    public var auto: Bool
    /// The track's timedtext URL, without a format or translation.
    public var url: String

    public init(lang: String, name: String, auto: Bool, url: String) {
        self.lang = lang
        self.name = name
        self.auto = auto
        self.url = url
    }

    /// This track as WebVTT, translated into `tlang` if given.
    public func vttURL(_ tlang: String?) -> String {
        var url = self.url + "&fmt=vtt"
        if let t = tlang { url += "&tlang=" + (t.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? t) }
        return url
    }
}

public enum Extract {
    public static func formatString(audioOnly: Bool, quality q: Int) -> String {
        audioOnly ? "bestaudio/best" : "bestvideo[height<=?\(q)]+bestaudio/best[height<=?\(q)]/best"
    }

    public static func extract(url: String, format: String, cookies: URL?) async throws -> Streams {
        guard let ytdlp = Tools.ytdlp else { throw APIError("yt-dlp was not found. Install it (brew install yt-dlp) to play videos.") }
        var args = ["-J", "--no-playlist", "--no-progress", "-f", format]
        if let c = cookies { args += ["--cookies", c.path] }
        args += ["--", url]
        let out = try await Tools.run(ytdlp, args)
        if out.status != 0 {
            let err = String(decoding: out.stderr, as: UTF8.self)
            let lines = err.components(separatedBy: "\n")
            let line = lines.last { $0.hasPrefix("ERROR") } ?? lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "yt-dlp failed"
            throw APIError(line.trimmingCharacters(in: .whitespaces))
        }
        guard let v = try? JSON(data: out.stdout) else { throw APIError("Unexpected yt-dlp output") }
        return try parse(v)
    }

    /// EDL's length-prefixed quoting, so URLs may contain any character.
    static func edlQuote(_ s: String) -> String { "%\(s.utf8.count)%\(s)" }

    public static func parse(_ v: JSON) throws -> Streams {
        var formats: [JSON] = v["requested_formats"]?.array ?? []
        if formats.isEmpty { formats = [v] }
        var urls: [String] = []
        for f in formats {
            guard let u = f["url"]?.string else { throw APIError("yt-dlp returned no stream URL") }
            urls.append(u)
        }
        let url = urls.count == 1
            ? urls[0]
            : "edl://" + urls.map { "!no_clip;!no_chapters;\(edlQuote($0))" }.joined(separator: ";!new_stream;")
        let all = formats + [v]
        let ua = all.lazy.compactMap { $0.pointer("/http_headers/User-Agent")?.string }.first
        let available = all.compactMap { $0["available_at"]?.double }.max()
        func height(_ f: JSON) -> Int? {
            // Storyboards (thumbnail sheets) have a height too.
            let video = (f["vcodec"]?.string.map { $0 != "none" } ?? true) && f["ext"]?.string != "mhtml"
            return video ? f["height"]?.uint : nil
        }
        var heights = Array(Set((v["formats"]?.array ?? []).compactMap(height)))
        heights.sort(by: >)
        return Streams(url: url, userAgent: ua, availableAt: available, captions: captions(v), heights: heights,
                       height: formats.lazy.compactMap(height).first)
    }

    /// A subtitle format's URL, if it is one of YouTube's timedtext URLs.
    static func timedtextURL(_ f: JSON) -> URLComponents? {
        guard let s = f["url"]?.string, let u = URLComponents(string: s), u.path == "/api/timedtext" else { return nil }
        return u
    }

    static func query(_ u: URLComponents, _ key: String) -> String? {
        u.queryItems?.first { $0.name == key }?.value
    }

    /// `u` without its format and translation, so either can be added.
    static func baseURL(_ u: URLComponents) -> String {
        var c = u
        c.queryItems = (u.queryItems ?? []).filter { $0.name != "fmt" && $0.name != "tlang" }
        return c.url?.absoluteString ?? (c.string ?? "")
    }

    public static func captions(_ v: JSON) -> Captions {
        var c = Captions()
        func first(_ formats: JSON) -> (URLComponents, String?)? {
            for f in formats.array ?? [] {
                if let u = timedtextURL(f) {
                    let name = f["name"]?.string.flatMap { $0.isEmpty ? nil : $0 }
                    return (u, name)
                }
            }
            return nil
        }
        var auto: [CaptionTrack] = []
        for (key, formats) in v["subtitles"]?.sortedEntries ?? [] {
            guard let fu = first(formats) else { continue }
            let (u, name) = fu
            let url = baseURL(u)
            if !c.tracks.contains(where: { $0.url == url }) {
                c.tracks.append(CaptionTrack(lang: query(u, "lang") ?? key, name: name ?? key, auto: false, url: url))
            }
        }
        // Automatic captions: the speech recognition track ("en-orig"), and
        // every language YouTube offers to translate into.
        for (key, formats) in v["automatic_captions"]?.sortedEntries ?? [] {
            guard let fu = first(formats) else { continue }
            let (u, name) = fu
            if let t = query(u, "tlang") {
                if !c.translations.contains(where: { $0.code == t }) {
                    c.translations.append(SubtitleTranslation(code: t, name: name ?? key))
                }
            } else if query(u, "kind") == "asr" {
                var trimmed = key
                if trimmed.hasSuffix("-orig") { trimmed.removeLast(5) }
                let lang = query(u, "lang") ?? trimmed
                if !auto.contains(where: { $0.lang == lang }) {
                    var n = name ?? lang
                    if n.hasSuffix(" (Original)") { n.removeLast(" (Original)".count) }
                    auto.append(CaptionTrack(lang: lang, name: "\(n) (auto-generated)", auto: true, url: baseURL(u)))
                }
            }
        }
        // Videos dubbed by YouTube have auto-generated subtitles for each dub;
        // only those in the language spoken go with the audio played.
        if let spoken = v["language"]?.string.map(Subtitles.primary), auto.contains(where: { Subtitles.primary($0.lang) == spoken }) {
            auto = auto.filter { Subtitles.primary($0.lang) == spoken }
        }
        let byName = { (a: String, b: String) in a.lowercased() < b.lowercased() }
        c.tracks.sort { byName($0.name, $1.name) }
        auto.sort { byName($0.name, $1.name) }
        c.tracks += auto
        c.translations.sort { byName($0.name, $1.name) }
        return c
    }
}

/// Subtitles in the player: which track to show.
public enum SubtitleChoice: Hashable, Sendable {
    case off
    case track(Int)
    /// YouTube's automatic translation of a track.
    case translate(from: Int, to: String)

    /// The menu's key for this choice.
    public var key: String {
        switch self {
        case .off: return "off"
        case .track(let i): return "t\(i)"
        case .translate(_, let to): return "x:\(to)"
        }
    }

    /// The choice a menu key stands for. Translations are of the track being
    /// shown, or else of the one YouTube would translate.
    public static func from(key: String, captions c: Captions, current: SubtitleChoice) -> SubtitleChoice? {
        if key == "off" { return .off }
        if key.hasPrefix("x:") {
            let to = String(key.dropFirst(2))
            var shown: Int?
            switch current {
            case .track(let i), .translate(let i, _): shown = i
            case .off: shown = nil
            }
            guard let from = shown.flatMap({ $0 < c.tracks.count ? $0 : nil }) ?? Subtitles.translationSource(c) else { return nil }
            return c.translations.contains { $0.code == to } ? .translate(from: from, to: to) : nil
        }
        guard key.hasPrefix("t"), let i = Int(key.dropFirst()), i < c.tracks.count else { return nil }
        return .track(i)
    }

    public struct Source: Sendable {
        public var url: String
        /// mpv's name for the track.
        public var title: String
        public var lang: String
    }

    public func source(_ c: Captions) -> Source? {
        switch self {
        case .off: return nil
        case .track(let i):
            guard i < c.tracks.count else { return nil }
            let t = c.tracks[i]
            return Source(url: t.vttURL(nil), title: t.name, lang: t.lang)
        case .translate(let from, let to):
            guard from < c.tracks.count else { return nil }
            let t = c.tracks[from]
            let name = c.translations.first { $0.code == to }?.name ?? to
            return Source(url: t.vttURL(to), title: "\(name) (auto-translated)", lang: to)
        }
    }
}

public enum Subtitles {
    /// The primary language subtag, in lowercase ("pt-BR" → "pt").
    public static func primary(_ code: String) -> String {
        (code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code).lowercased()
    }

    /// The video's own subtitles, also what gets translated: uploaded ones in
    /// the language spoken (that of the auto-generated track), else English,
    /// else any, else the auto-generated ones.
    public static func translationSource(_ c: Captions) -> Int? {
        func uploaded(_ lang: String) -> Int? { c.tracks.firstIndex { !$0.auto && primary($0.lang) == lang } }
        let asr = c.tracks.firstIndex { $0.auto }
        return asr.flatMap { uploaded(primary(c.tracks[$0].lang)) }
            ?? uploaded("en")
            ?? c.tracks.firstIndex { !$0.auto }
            ?? asr
    }

    /// What to show someone who wants subtitles in `lang`: a track in that
    /// language (uploaded first), else its translation if `translate`, else
    /// the video's own subtitles, as YouTube does.
    public static func preferred(_ c: Captions, lang: String, translate: Bool) -> SubtitleChoice {
        guard let def = translationSource(c) else { return .off }
        let want = primary(lang)
        func exact(_ auto: Bool) -> Int? { c.tracks.firstIndex { $0.auto == auto && $0.lang.lowercased() == lang.lowercased() } }
        func close(_ auto: Bool) -> Int? { c.tracks.firstIndex { $0.auto == auto && primary($0.lang) == want } }
        if let i = exact(false) ?? close(false) ?? exact(true) ?? close(true) { return .track(i) }
        if translate {
            let code = c.translations.first { $0.code.lowercased() == lang.lowercased() } ?? c.translations.first { primary($0.code) == want }
            if let code { return .translate(from: def, to: code.code) }
        }
        return .track(def)
    }

    /// The translations into `langs` (the languages you use), in that order.
    public static func suggested(_ c: Captions, _ langs: [String]) -> [SubtitleTranslation] {
        var out: [SubtitleTranslation] = []
        for lang in langs where !lang.isEmpty {
            let found = c.translations.first { $0.code.lowercased() == lang.lowercased() } ?? c.translations.first { primary($0.code) == primary(lang) }
            if let t = found, !out.contains(t) { out.append(t) }
        }
        return out
    }
}
