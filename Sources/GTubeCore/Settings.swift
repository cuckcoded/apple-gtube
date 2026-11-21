import Foundation

public enum SbMode: String, Codable, Sendable, CaseIterable {
    case skip, show, off
}

public struct SavedAccount: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// Learned from YouTube after signing in ("" until then).
    public var name: String = ""
    public var channelId: String?

    enum CodingKeys: String, CodingKey { case id, name, channelId = "channel_id" }

    public init(id: String) { self.id = id }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        channelId = try c.decodeIfPresent(String.self, forKey: .channelId)
    }

    /// Whether this is the account YouTube named (by channel, else by name).
    func isSame(name: String, channelId: String?) -> Bool {
        switch (self.channelId, channelId) {
        case (_, .some(let c)): return self.channelId == c
        case (.none, .none): return !name.isEmpty && self.name == name
        case (.some, .none): return false
        }
    }
}

/// GTube's settings, kept in `settings.json` (same names as GTube for Linux).
public struct Settings: Codable, Sendable, Equatable {
    public var maxQuality = 1080
    public var autoplay = true
    public var hwdec = true
    public var markWatched = true
    public var hideShorts = true
    public var volume = 100.0
    public var audioOnly = false
    public var sponsorblock = true
    public var sbModes: [String: SbMode] = Settings.defaultSbModes
    public var dislikes = true
    public var downloadDir: String = Settings.defaultDownloadDir
    public var downloadSbRemove = false
    public var downloadEmbedMetadata = true
    public var audioFormat = "mp3"
    public var language: String = Settings.systemLocale.0
    public var region: String = Settings.systemLocale.1
    /// "video" (YouTube) or "music" (YouTube Music).
    public var uiMode = "video"
    /// Music mode plays the video instead of just the song.
    public var musicVideo = false
    public var musicShuffle = false
    /// "off", "all" or "one".
    public var musicRepeat = "off"
    public var musicAmbient = true
    public var musicVisualizer = true
    public var resumePlayback = true
    /// Private SponsorBlock user ID for submissions (made on first use).
    public var sbUserId = ""
    public var compactWidth = 480
    public var compactHeight = 270
    public var windowWidth = 1440
    public var windowHeight = 900
    public var windowMaximized = false
    /// What the immersive view shows beside the artwork: "lyrics", "queue" or "".
    public var immersivePanel = "lyrics"
    public var lyricsLrclib = true
    public var subtitles = false
    /// The subtitle language wanted (the last one picked); "" for `language`.
    public var subtitleLang = ""
    public var subtitleTranslate = false
    public var subtitleScale = 1.0
    public var theater = false
    public var accounts: [SavedAccount] = []
    /// The account in use; "" browses without one.
    public var activeAccount = ""

    public init() {}

    public static let defaultSbModes: [String: SbMode] = {
        var m: [String: SbMode] = [:]
        for c in ["sponsor", "selfpromo", "interaction"] { m[c] = .skip }
        for c in ["intro", "outro", "preview", "hook", "music_offtopic", "filler", "poi_highlight", "exclusive_access"] { m[c] = .show }
        return m
    }()

    public static var defaultDownloadDir: String {
        let fm = FileManager.default
        let base = fm.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
        return base.appendingPathComponent("GTube").path
    }

    public static var systemLocale: (String, String) {
        let loc = Locale.current
        let hl = (loc.language.languageCode?.identifier ?? "en").lowercased()
        let gl = (loc.region?.identifier ?? "US").uppercased()
        return (hl.count == 2 ? hl : "en", gl.count == 2 ? gl : "US")
    }

    public func sbMode(_ cat: String) -> SbMode { sbModes[cat] ?? .show }

    /// The subtitle language wanted.
    public var subtitleLanguage: String { subtitleLang.isEmpty ? language : subtitleLang }

    enum CodingKeys: String, CodingKey {
        case maxQuality = "max_quality", autoplay, hwdec, markWatched = "mark_watched", hideShorts = "hide_shorts", volume
        case audioOnly = "audio_only", sponsorblock, sbModes = "sb_modes", dislikes, downloadDir = "download_dir"
        case downloadSbRemove = "download_sb_remove", downloadEmbedMetadata = "download_embed_metadata", audioFormat = "audio_format"
        case language, region, uiMode = "ui_mode", musicVideo = "music_video", musicShuffle = "music_shuffle"
        case musicRepeat = "music_repeat", musicAmbient = "music_ambient", musicVisualizer = "music_visualizer"
        case resumePlayback = "resume_playback", sbUserId = "sb_user_id", compactWidth = "compact_width", compactHeight = "compact_height"
        case windowWidth = "window_width", windowHeight = "window_height", windowMaximized = "window_maximized"
        case immersivePanel = "immersive_panel", lyricsLrclib = "lyrics_lrclib", subtitles, subtitleLang = "subtitle_lang"
        case subtitleTranslate = "subtitle_translate", subtitleScale = "subtitle_scale", theater, accounts, activeAccount = "active_account"
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ cur: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? cur }
        maxQuality = v(.maxQuality, maxQuality)
        autoplay = v(.autoplay, autoplay)
        hwdec = v(.hwdec, hwdec)
        markWatched = v(.markWatched, markWatched)
        hideShorts = v(.hideShorts, hideShorts)
        volume = v(.volume, volume)
        audioOnly = v(.audioOnly, audioOnly)
        sponsorblock = v(.sponsorblock, sponsorblock)
        sbModes = v(.sbModes, sbModes)
        dislikes = v(.dislikes, dislikes)
        downloadDir = v(.downloadDir, downloadDir)
        downloadSbRemove = v(.downloadSbRemove, downloadSbRemove)
        downloadEmbedMetadata = v(.downloadEmbedMetadata, downloadEmbedMetadata)
        audioFormat = v(.audioFormat, audioFormat)
        language = v(.language, language)
        region = v(.region, region)
        uiMode = v(.uiMode, uiMode)
        musicVideo = v(.musicVideo, musicVideo)
        musicShuffle = v(.musicShuffle, musicShuffle)
        musicRepeat = v(.musicRepeat, musicRepeat)
        musicAmbient = v(.musicAmbient, musicAmbient)
        musicVisualizer = v(.musicVisualizer, musicVisualizer)
        resumePlayback = v(.resumePlayback, resumePlayback)
        sbUserId = v(.sbUserId, sbUserId)
        compactWidth = v(.compactWidth, compactWidth)
        compactHeight = v(.compactHeight, compactHeight)
        windowWidth = v(.windowWidth, windowWidth)
        windowHeight = v(.windowHeight, windowHeight)
        windowMaximized = v(.windowMaximized, windowMaximized)
        immersivePanel = v(.immersivePanel, immersivePanel)
        lyricsLrclib = v(.lyricsLrclib, lyricsLrclib)
        subtitles = v(.subtitles, subtitles)
        subtitleLang = v(.subtitleLang, subtitleLang)
        subtitleTranslate = v(.subtitleTranslate, subtitleTranslate)
        subtitleScale = v(.subtitleScale, subtitleScale)
        theater = v(.theater, theater)
        accounts = v(.accounts, accounts)
        activeAccount = v(.activeAccount, activeAccount)
    }
}

/// The settings file and the saved accounts.
public enum Config {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Settings?

    static var settingsURL: URL { Paths.config.appendingPathComponent("settings.json") }
    static var accountsDir: URL {
        let d = Paths.config.appendingPathComponent("accounts")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return d
    }

    public static var settings: Settings {
        lock.lock()
        defer { lock.unlock() }
        if let s = cached { return s }
        let s = (try? Data(contentsOf: settingsURL)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        cached = s
        return s
    }

    public static func update(_ f: (inout Settings) -> Void) {
        var s = settings
        f(&s)
        lock.lock()
        cached = s
        lock.unlock()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(s) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }

    static func accountURL(_ id: String) -> URL { accountsDir.appendingPathComponent("\(id).txt") }

    /// The active account's cookies.txt (for yt-dlp), if one is in use.
    public static var cookiesPath: URL? {
        let id = settings.activeAccount
        guard !id.isEmpty else { return nil }
        let u = accountURL(id)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    public static func loadCookies() -> CookieJar {
        guard let p = cookiesPath, let t = try? String(contentsOf: p, encoding: .utf8) else { return CookieJar() }
        return CookieJar.parseNetscape(t)
    }

    /// Saves a new session and makes it the active account.
    public static func addAccount(_ jar: CookieJar) throws {
        let id = String(Int64(Date().timeIntervalSince1970 * 1000))
        let url = accountURL(id)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(jar.toNetscape().utf8), attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "GTube", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not write \(url.path)"])
        }
        update { s in
            s.accounts.append(SavedAccount(id: id))
            s.activeAccount = id
        }
    }

    /// Forgets a saved account; removing the active one leaves no account in use.
    public static func removeAccount(_ id: String) {
        try? FileManager.default.removeItem(at: accountURL(id))
        update { s in
            s.accounts.removeAll { $0.id == id }
            if s.activeAccount == id { s.activeAccount = "" }
        }
    }

    /// Names the active account once YouTube says who it is. Signing in to an
    /// account that was already saved replaces the old copy.
    public static func rememberAccount(name: String, channelId: String?) {
        var dupes: [String] = []
        update { s in
            let active = s.activeAccount
            s.accounts.removeAll { a in
                let same = a.id != active && a.isSame(name: name, channelId: channelId)
                if same { dupes.append(a.id) }
                return same
            }
            if let i = s.accounts.firstIndex(where: { $0.id == active }) {
                s.accounts[i].name = name
                s.accounts[i].channelId = channelId
            }
        }
        for id in dupes { try? FileManager.default.removeItem(at: accountURL(id)) }
    }
}
