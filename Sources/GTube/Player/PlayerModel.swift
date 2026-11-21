import AppKit
import GTubeCore
import SwiftUI

/// Where the player is on screen.
enum PlayerMode: Equatable {
    case hidden
    /// In a page: the watch page, or Music's "Now playing"/immersive view.
    case docked
    /// The small player in a corner while browsing.
    case mini
    case fullscreen
    /// The whole (small) window is the player.
    case compact
}

/// Places that show the video while they are on screen, by priority (the
/// last one shown wins, like the original's docks).
enum Dock: Int, Comparable {
    case watch = 0, nowPlaying = 1, immersive = 2
    static func < (a: Dock, b: Dock) -> Bool { a.rawValue < b.rawValue }
}

/// Where the video view is put.
enum VideoSlot: Equatable {
    case dock(Dock)
    /// The window-wide overlay: miniplayer, fullscreen, compact player.
    case overlay
}

struct SegState {
    var seg: Segment
    var mode: SbMode
    var ignored = false
}

struct BarSegment: Identifiable {
    let id = UUID()
    var start: Double
    var end: Double
    var color: Color
    var label: String
    var point: Bool
}

/// Turns mpv / yt-dlp messages into something a person can act on.
func describePlaybackError(_ raw: String) -> String {
    var msg = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if msg.hasPrefix("ERROR: ") { msg.removeFirst(7) }
    if msg.hasPrefix("[youtube] ") { msg.removeFirst(10) }
    let urls = try! NSRegularExpression(pattern: #"https?://\S+"#)
    func stripURLs(_ s: String) -> String { urls.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "…") }
    if msg.contains("Sign in to confirm") || msg.contains("not a bot") {
        return "YouTube wants a signed-in session before it serves this video.\nSign in from the account menu, then retry."
    }
    if msg.contains("HTTP error 403") {
        return "YouTube refused the video stream (HTTP 403).\nThis is usually temporary: retry, and if it keeps happening update yt-dlp."
    }
    if msg.contains("HTTP error 429") {
        return "YouTube is rate-limiting this connection (HTTP 429).\nWait a little or sign in, then retry."
    }
    if msg.contains("Private video") || msg.contains("members-only") || (msg.contains("age") && msg.contains("confirm")) {
        return "\(stripURLs(msg))\nSigning in may give access."
    }
    let s = stripURLs(msg)
    return s.count > 300 ? String(s.prefix(300)) + "…" : s
}

@MainActor @Observable
final class PlayerModel {
    static let minSpeed = 0.25
    static let maxSpeed = 3.0

    @ObservationIgnored private(set) var mpv: MPV!
    let videoView = VideoView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))

    // What is playing.
    private(set) var current: VideoItem?
    private(set) var mode: PlayerMode = .hidden
    private(set) var fullscreen = false
    private(set) var compact = false
    private(set) var immersive = false
    private var forceMini = false
    /// How many views of each dock are on screen (one can appear before
    /// another disappears).
    private var docks: [Dock: Int] = [:]
    /// Music mode is showing: no miniplayer; the player shows only docked on
    /// "Now playing" (or fullscreen) and otherwise plays in the background.
    private(set) var music = false
    /// Music mode's "Video" (rather than "Song") choice.
    private(set) var musicVideo = Config.settings.musicVideo
    /// The current item was started from Music mode.
    private(set) var musicOwned = false
    private var loadedWithVideo = false
    private var fileReady = false

    // Playback state.
    private(set) var position = 0.0
    private(set) var duration = 0.0
    private(set) var buffered = 0.0
    private(set) var paused = false
    private(set) var muted = false
    private(set) var volume = Config.settings.volume
    private(set) var speed = 1.0
    private(set) var loading = false
    /// "Starting in N s": YouTube holds the streams back for a blocked ad.
    private(set) var waitLeft: Int?
    private(set) var errorText: String?
    private(set) var quality = Config.settings.maxQuality
    private(set) var heights: [Int] = []
    private(set) var playingHeight: Int?
    private(set) var theater = Config.settings.theater
    private(set) var audioOnlySetting = Config.settings.audioOnly

    // Subtitles.
    private(set) var captions = Captions()
    /// What to show; nil until known for a new item.
    private(set) var subChoice: SubtitleChoice?
    @ObservationIgnored private var subTracks: [(url: String, id: Int, choice: SubtitleChoice)] = []
    @ObservationIgnored private var subGen = 0

    // SponsorBlock.
    @ObservationIgnored private var segments: [SegState] = []
    private(set) var barSegments: [BarSegment] = []
    private(set) var highlight: Double?
    private(set) var highlightVisible = false
    private(set) var sbDraft: (Double, Double?)?
    private(set) var notice: String?
    @ObservationIgnored private var undoTarget: Int?
    @ObservationIgnored private var sbSeeking = false
    @ObservationIgnored private var sbMuted = false
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    // Controls.
    private(set) var controlsVisible = true
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    var wantPrev = false
    var wantNext = false

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadGen = 0
    @ObservationIgnored private var report: Report?
    @ObservationIgnored private var resumeAt: Double?
    @ObservationIgnored private var itemStarted = false
    @ObservationIgnored private var pending: (String, Double)?
    @ObservationIgnored private var lastError = ""
    @ObservationIgnored private var errorImportant = false
    @ObservationIgnored private var eofHandled = false
    @ObservationIgnored private var volumeSave: Task<Void, Never>?
    @ObservationIgnored private var audioFilter = ""
    @ObservationIgnored private(set) var glFailed = false

    // Hooks (set up by the app, like the original's callbacks).
    @ObservationIgnored var onEnded: (() -> Void)?
    @ObservationIgnored var onExpand: (() -> Void)?
    @ObservationIgnored var onMinimize: (() -> Void)?
    @ObservationIgnored var onState: (() -> Void)?
    @ObservationIgnored var onError: ((String) -> Void)?
    @ObservationIgnored var onMusicVideo: ((Bool) -> Void)?
    @ObservationIgnored var onSeeked: ((Double) -> Void)?
    @ObservationIgnored var onSegments: (([Segment]) -> Void)?

    init() {
        let s = Config.settings
        var opts: [(String, String)] = [
            ("vo", "libmpv"),
            ("hwdec", s.hwdec ? "auto-safe" : "no"),
            // Extraction is done by GTube (yt-dlp), not by ytdl_hook.
            ("ytdl", "no"),
            ("keep-open", "yes"),
            ("idle", "yes"),
            ("osc", "no"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("terminal", "no"),
            ("cache", "yes"),
            ("demuxer-max-bytes", "150MiB"),
            ("demuxer-max-back-bytes", "50MiB"),
            ("audio-client-name", "GTube"),
            ("volume", "\(s.volume)"),
            ("sub-auto", "no"),
            ("sub-scale", "\(s.subtitleScale)"),
            ("sub-font", "Helvetica Neue"),
            // GTube waits for `available_at`; this only covers clock skew and
            // short network hiccups.
            ("stream-lavf-o", "reconnect_on_http_error=403,reconnect_on_network_error=1"),
        ]
        if let ao = ProcessInfo.processInfo.environment["GTUBE_MPV_AO"] { opts.append(("ao", ao)) }
        do {
            mpv = try MPV(options: opts)
        } catch {
            Log.error("could not start mpv: \(error.localizedDescription)")
            fatalError("could not start mpv: \(error.localizedDescription)")
        }
        for (name, f) in [("time-pos", MPV.Format.double), ("duration", .double), ("pause", .flag), ("paused-for-cache", .flag),
                          ("seeking", .flag), ("demuxer-cache-time", .double), ("volume", .double), ("mute", .flag),
                          ("eof-reached", .flag), ("speed", .double)] {
            mpv.observe(name, f)
        }
        mpv.onWakeup = { [weak self] in
            MainActor.assumeIsolated { self?.drainEvents() }
        }
        let layer = videoView.videoLayer
        layer.mpv = mpv
        mpv.onRedraw = { @Sendable in
            DispatchQueue.main.async { layer.setNeedsDisplay() }
        }
        if let ctx = VideoLayer.context {
            CGLSetCurrentContext(ctx)
            do {
                try mpv.createRenderContext()
            } catch {
                glFailed = true
                Log.error("video output unavailable: \(error.localizedDescription)")
                after(1) { toast("Video output unavailable (\(error.localizedDescription)); playing audio only") }
            }
            CGLSetCurrentContext(nil)
        } else {
            glFailed = true
            Log.error("video output unavailable: no OpenGL context")
        }
        videoView.onClick = { [weak self] n in self?.videoClicked(n) }
        videoView.onMouseMove = { [weak self] in self?.showControls() }
        if Tools.ytdlp == nil {
            after(1) { toast("yt-dlp was not found — playback and downloads will not work. Install it with: brew install yt-dlp") }
        }
    }

    // MARK: Layout

    /// A place that shows the video came on screen (or went away).
    func setDock(_ d: Dock, visible: Bool) {
        if visible {
            docks[d, default: 0] += 1
            forceMini = false
        } else {
            docks[d] = max((docks[d] ?? 0) - 1, 0)
            if docks[d] == 0 { docks[d] = nil }
        }
        updateMode()
        applyVideo()
    }

    private var dock: Dock? { docks.keys.max() }

    /// Where the video view goes now.
    var slot: VideoSlot? {
        switch mode {
        case .hidden: return nil
        case .docked: return dock.map { .dock($0) }
        case .mini, .fullscreen, .compact: return .overlay
        }
    }

    private func computeMode() -> PlayerMode {
        if current == nil { return .hidden }
        if fullscreen && !immersive { return .fullscreen }
        if compact && !immersive { return .compact }
        if music { return dock != nil && musicVideo ? .docked : .hidden }
        if dock != nil && !forceMini { return .docked }
        return .mini
    }

    private func updateMode() {
        let new = computeMode()
        if new == mode { return }
        mode = new
        videoView.dragMovesWindow = new == .compact
        showControls()
    }

    /// Docked on the watch page (Music docks it on "Now playing").
    var onWatchPage: Bool { mode == .docked && !music && dock == .watch }

    func toggleTheater() {
        theater.toggle()
        Config.update { $0.theater = theater }
    }

    func setCompact(_ on: Bool) {
        compact = on
        updateMode()
    }

    /// Music's immersive view hosts the video (and covers the window).
    func setImmersive(_ on: Bool) {
        immersive = on
        updateMode()
        applyVideo()
    }

    func setFullscreen(_ on: Bool) {
        fullscreen = on
        if on { forceMini = false }
        updateMode()
    }

    /// Music mode is shown (or hidden).
    func setMusicPresentation(_ on: Bool) {
        if music == on { return }
        music = on
        forceMini = false
        updateMode()
        applyVideo()
    }

    /// Music mode's Song / Video switch.
    func setMusicVideo(_ on: Bool) {
        Config.update { $0.musicVideo = on }
        if musicVideo == on { return }
        musicVideo = on
        updateMode()
        applyVideo()
        onMusicVideo?(on)
    }

    // MARK: Loading

    var currentId: String? { current?.id }
    var isMusicOwned: Bool { current != nil && musicOwned }
    var isAudioOnly: Bool { isMusicOwned ? !musicVideo : audioOnlySetting }
    var hasFailed: Bool { errorText != nil }
    var isLoading: Bool { loading || waitLeft != nil }

    func load(_ v: VideoItem, start: Double = 0) { load(v, start: start, music: false) }

    /// Plays a track started from Music mode.
    func loadMusic(_ v: VideoItem, start: Double = 0) { load(v, start: start, music: true) }

    private func load(_ v: VideoItem, start: Double, music: Bool) {
        // The previous view ends.
        finishReport()
        musicOwned = music
        generation += 1
        resumeAt = nil
        itemStarted = false
        current = v
        duration = 0
        position = 0
        buffered = 0
        eofHandled = false
        segments = []
        barSegments = []
        highlight = nil
        highlightVisible = false
        sbDraft = nil
        notice = nil
        errorText = nil
        loading = true
        setCaptions(Captions(), newItem: true)
        updateMode()
        let url = v.url
        if mpv.render != nil || glFailed || !wantsVideo || mode == .hidden {
            doLoad(url, start: start)
        } else {
            pending = (url, start)
            doLoad(url, start: start)
        }
        fetchSegments(v.id)
        startReport(v, resume: start <= 0 && !music && !v.isLive)
        notify()
    }

    /// Starts reporting the new view to YouTube and, for `resume`, asks YouTube
    /// where the video was left.
    private func startReport(_ v: VideoItem, resume: Bool) {
        let s = Config.settings
        let client = Client.shared
        let account = client.isLoggedIn || ProcessInfo.processInfo.environment["GTUBE_STATS_DRY_RUN"] != nil
        let reporting = account && s.markWatched
        var resume = resume && s.resumePlayback
        if reporting {
            let ses = client.session
            report = Report(video: v.id, live: v.isLive, clientVersion: ses.clientVersion, hl: ses.hl, gl: ses.gl)
        }
        // A video reported during this run continues from there right away.
        if resume, let p = WatchPositions.position(v.id) {
            if p > 0 { applyResume(p) }
            resume = false
        }
        if !account || !(reporting || resume) { return }
        let gen = generation
        let id = v.id
        Task {
            let t: Tracking
            do {
                t = try await Client.shared.tracking(id)
            } catch {
                Log.warn("watch history: \(error.localizedDescription)")
                return
            }
            guard generation == gen else { return }
            if resume, let at = t.resume, t.length.map({ at < $0 - 10 }) ?? true {
                Log.info("\(id): YouTube continues at \(Int(at)) s")
                applyResume(at)
            }
            if let r = report { sendReports(r.setTracking(t, now: steadyClock())) }
        }
    }

    /// Continues the current item at `at`: from there when it hasn't started
    /// yet, or by seeking if it only just did.
    private func applyResume(_ at: Double) {
        let at = max(at - 3, 0)
        if at < 5 { return }
        if !itemStarted {
            resumeAt = at
        } else if position < 10 {
            seek(to: at)
            resumeToast(at)
        }
    }

    private func resumeToast(_ at: Double) {
        guard let id = currentId else { return }
        toast("Continuing from \(Format.time(at))", button: "Start over") { [weak self] in
            if self?.currentId == id { self?.seek(to: 0) }
        }
    }

    private func withReport(_ f: (Report, Double) -> [String]) {
        guard let r = report else { return }
        sendReports(f(r, steadyClock()))
    }

    private func finishReport() {
        if let r = report {
            report = nil
            sendReports(r.finish(now: steadyClock()))
        }
    }

    /// Like `finishReport`, but waits (briefly) for it to be sent; for quitting.
    func finishReportBlocking() {
        guard let r = report else { return }
        report = nil
        let urls = r.finish(now: steadyClock())
        if urls.isEmpty { return }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            for u in urls { try? await Client.shared.ping(u) }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 2) == .timedOut { Log.warn("watch history: last report timed out") }
    }

    private func sendReports(_ urls: [String]) {
        for url in urls {
            Task.detached {
                do {
                    try await Client.shared.ping(url)
                } catch {
                    Log.warn("watch history: \(url.contains("/watchtime") ? "watch time" : "playback") report failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Whether the current item should be opened with its video track.
    private var wantsVideo: Bool {
        !glFailed && (musicOwned ? musicVideo : !audioOnlySetting)
    }

    /// Whether video is on screen right now (and worth decoding).
    var showsVideo: Bool { wantsVideo && mode != .hidden }

    /// Turns video decoding on or off to match what is on screen, reopening
    /// the stream with video when it was opened audio-only.
    private func applyVideo() {
        guard current != nil else { return }
        if !showsVideo {
            mpv.set("vid", "no")
        } else if hasVideoTrack {
            mpv.set("vid", "auto")
        } else if !loadedWithVideo {
            reloadCurrent()
        }
    }

    private var hasVideoTrack: Bool {
        let n = Int(mpv.string("track-list/count") ?? "") ?? 0
        return (0..<n).contains { mpv.string("track-list/\($0)/type") == "video" }
    }

    private func notify() { onState?() }

    private func doLoad(_ url: String, start: Double) {
        pending = nil
        loadGen += 1
        let load = loadGen
        let audioOnly = !wantsVideo
        loadedWithVideo = !audioOnly
        guard Tools.ytdlp != nil else {
            showError("yt-dlp was not found. Install it (brew install yt-dlp) to play videos.")
            return
        }
        // Stop the previous video right away, like youtube.com does.
        mpv.command(["stop"])
        errorText = nil
        loading = true
        let format = Extract.formatString(audioOnly: audioOnly, quality: quality)
        let cookies = Client.shared.isLoggedIn ? Config.cookiesPath : nil
        Task {
            do {
                let streams = try await Extract.extract(url: url, format: format, cookies: cookies)
                guard loadGen == load else { return }
                startStreams(load, streams, start: start)
            } catch {
                guard loadGen == load else { return }
                showError(error.localizedDescription)
            }
        }
    }

    /// Plays extracted streams, first waiting out YouTube's ad delay.
    private func startStreams(_ load: Int, _ streams: Streams, start: Double) {
        func now() -> Double { Date().timeIntervalSince1970 }
        guard let at = streams.availableAt, at - now() > 0.2 else {
            playStreams(streams, start: start)
            return
        }
        Task {
            while loadGen == load {
                let left = at - now()
                if left <= 0 { break }
                waitLeft = Int(left.rounded(.up))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            waitLeft = nil
            if loadGen == load { playStreams(streams, start: start) }
        }
    }

    /// Adds the spectrum analysis to Music playback (when it is on) and
    /// removes it for everything else.
    func updateAudioFilter() {
        let want = musicOwned && Config.settings.musicVisualizer ? (Spectrum.audioFilter ?? "") : ""
        if audioFilter != want {
            mpv.set("af", want)
            audioFilter = want
        }
    }

    /// The position of the audio being heard.
    var audioPts: Double? {
        current == nil ? nil : mpv.double("audio-pts")
    }

    private func playStreams(_ streams: Streams, start: Double) {
        var start = start
        if !itemStarted {
            itemStarted = true
            if start <= 0.5, let at = resumeAt {
                resumeAt = nil
                start = at
                resumeToast(at)
            }
        }
        updateAudioFilter()
        setCaptions(streams.captions, newItem: false)
        heights = streams.heights
        if let h = streams.height { playingHeight = h }
        mpv.set("vid", showsVideo && mpv.render != nil ? "auto" : "no")
        var opts: [String] = []
        if start > 0.5 { opts.append("start=\(start)") }
        if let ua = streams.userAgent {
            // Length-prefixed so commas in the value survive.
            opts.append("user-agent=%\(ua.utf8.count)%\(ua)")
        }
        if let e = mpv.command(["loadfile", streams.url, "replace", "-1", opts.joined(separator: ",")]) {
            showError("Could not start playback: \(e)")
        }
        mpv.set("pause", false)
    }

    // MARK: Subtitles

    /// The subtitles of what is about to play. For a new item they aren't
    /// known yet; once they are, what to show comes from the settings. A
    /// reload of the same item keeps what was shown.
    private func setCaptions(_ c: Captions, newItem: Bool) {
        subTracks = []
        subGen += 1
        if newItem {
            subChoice = nil
        } else if subChoice == nil {
            subChoice = wantedSubtitles(c)
        }
        captions = c
    }

    private func wantedSubtitles(_ c: Captions) -> SubtitleChoice {
        let s = Config.settings
        // Music has lyrics instead.
        if !s.subtitles || musicOwned { return .off }
        return Subtitles.preferred(c, lang: s.subtitleLanguage, translate: s.subtitleTranslate)
    }

    var suggestedTranslations: [Translation] {
        let s = Config.settings
        return Subtitles.suggested(captions, [s.subtitleLang, s.language])
    }

    /// A pick from the subtitles menu, remembered for the next videos.
    func pickSubtitles(_ key: String) {
        guard let choice = SubtitleChoice.from(key: key, captions: captions, current: subChoice ?? .off) else { return }
        switch choice {
        case .off: Config.update { $0.subtitles = false }
        case .track(let i):
            let lang = captions.tracks[i].lang
            Config.update { s in
                s.subtitles = true
                s.subtitleLang = lang
            }
        case .translate(_, let to):
            Config.update { s in
                s.subtitles = true
                s.subtitleLang = to
                s.subtitleTranslate = true
            }
        }
        showSubtitles(choice)
    }

    private func showSubtitles(_ c: SubtitleChoice) {
        subChoice = c
        applySubtitles()
    }

    /// Turns subtitles on or off (C), and remembers that.
    func toggleSubtitles() {
        guard current != nil else { return }
        switch subChoice {
        case .none:
            let on = !Config.settings.subtitles
            Config.update { $0.subtitles = on }
            toast(on ? "Subtitles on" : "Subtitles off")
        case .some(.off):
            if captions.tracks.isEmpty {
                toast("This video has no subtitles")
                return
            }
            Config.update { $0.subtitles = true }
            let s = Config.settings
            showSubtitles(Subtitles.preferred(captions, lang: s.subtitleLanguage, translate: s.subtitleTranslate))
        case .some:
            Config.update { $0.subtitles = false }
            showSubtitles(.off)
        }
    }

    /// The subtitle settings changed: applies them to what is playing.
    func subtitleSettingsChanged() {
        guard let cur = subChoice else { return }
        let wanted = wantedSubtitles(captions)
        if wanted != cur { showSubtitles(wanted) }
    }

    func setSubtitleScale(_ s: Double) { mpv.set("sub-scale", s) }

    /// Shows the chosen subtitles in the open file, downloading them first.
    private func applySubtitles() {
        guard fileReady else { return }
        subGen += 1
        let gen = subGen
        let choice = subChoice ?? .off
        guard loadedWithVideo, let src = choice.source(captions) else {
            mpv.set("sid", "no")
            return
        }
        if let t = subTracks.first(where: { $0.url == src.url }) {
            mpv.set("sid", "\(t.id)")
            return
        }
        let load = loadGen
        Task {
            do {
                let text = try await Client.shared.timedtext(src.url)
                guard subGen == gen, loadGen == load, fileReady else { return }
                addSubtitles(src, text, choice)
            } catch {
                guard subGen == gen, loadGen == load, fileReady else { return }
                subtitlesFailed(choice, error)
            }
        }
    }

    private func addSubtitles(_ src: SubtitleChoice.Source, _ text: String, _ choice: SubtitleChoice) {
        let data = "memory://" + text.replacingOccurrences(of: "\0", with: "")
        if let e = mpv.command(["sub-add", data, "select", src.title, src.lang]) {
            Log.warn("could not add subtitles (\(src.lang)): \(e)")
            toast("Couldn't show the subtitles")
            return
        }
        if let id = mpv.string("sid").flatMap({ Int($0) }) {
            subTracks.append((src.url, id, choice))
        }
    }

    private func subtitlesFailed(_ choice: SubtitleChoice, _ e: Error) {
        Log.warn("subtitles: \(e.localizedDescription)")
        let shownId = mpv.string("sid").flatMap { Int($0) }
        let shown = shownId.flatMap { id in subTracks.first { $0.id == id }?.choice }
        // A translation that didn't come: the subtitles it translates instead.
        var original: SubtitleChoice?
        if case .translate(let from, _) = choice, shown == nil { original = .track(from) }
        var msg: String
        if case .translate = choice, (e as? HTTPStatusError)?.status == 429 {
            msg = "YouTube is refusing auto-translated subtitles right now (HTTP 429)"
        } else {
            msg = "Couldn't load the subtitles (\(e.localizedDescription))"
        }
        if let c = original?.source(captions) { msg += "; showing \(c.title)" }
        toast(msg)
        if let o = original {
            showSubtitles(o)
        } else {
            subChoice = shown ?? .off
        }
    }

    /// Keeps subtitles clear of the controls while those are shown.
    func updateSubMargin(bar: Double, height: Double) {
        let margin = 22 + (height > 0 ? Int(bar * 720 / height) : 0)
        mpv.set("sub-margin-y", "\(margin)")
    }

    // MARK: Controls

    func setQuality(_ q: Int) {
        quality = q
        playingHeight = q
        reloadCurrent()
    }

    func reloadCurrent() {
        guard let v = current else { return }
        errorText = nil
        loading = true
        doLoad(v.url, start: position)
    }

    func stop() {
        finishReport()
        generation += 1
        loadGen += 1
        waitLeft = nil
        mpv.command(["stop"])
        current = nil
        musicOwned = false
        segments = []
        forceMini = false
        if fullscreen { toggleFullscreen() }
        updateMode()
        notify()
    }

    func minimize() {
        if fullscreen { toggleFullscreen() }
        onMinimize?()
        if mode == .docked {
            forceMini = true
            updateMode()
        }
    }

    func expand() {
        forceMini = false
        onExpand?()
        updateMode()
    }

    func togglePause() {
        guard current != nil else { return }
        if paused && duration > 0 && position >= duration - 0.5 { mpv.command(["seek", "0", "absolute"]) }
        mpv.set("pause", !paused)
    }

    func play() { if paused { togglePause() } }
    func pause() { if !paused { togglePause() } }

    /// Starts the current item again from the beginning (repeat one).
    func replay() {
        guard current != nil else { return }
        mpv.command(["seek", "0", "absolute+exact"])
        mpv.set("pause", false)
    }

    func toggleMute() { mpv.set("mute", !muted) }

    func setVolume(_ v: Double) {
        let v = min(max(v, 0), 130)
        mpv.set("volume", v)
        volume = v
        volumeSave?.cancel()
        volumeSave = after(0.6) { Config.update { $0.volume = v } }
    }

    func changeVolume(_ d: Double) { setVolume(volume + d) }

    func setSpeed(_ r: Double) {
        mpv.set("speed", min(max(r, Self.minSpeed), Self.maxSpeed))
    }

    private func markUserSeek(_ t: Double) {
        for i in segments.indices where t >= segments[i].seg.start && t < segments[i].seg.end {
            segments[i].ignored = true
        }
    }

    func seek(to t: Double, exact: Bool = true) {
        guard current != nil else { return }
        markUserSeek(t)
        mpv.command(["seek", "\(t)", exact ? "absolute+exact" : "absolute+keyframes"])
    }

    func seekRelative(_ dt: Double) {
        markUserSeek(max(position + dt, 0))
        mpv.command(["seek", "\(dt)", "relative+exact"])
        showControls()
    }

    func toggleFullscreen() {
        guard let w = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        if current == nil && !w.styleMask.contains(.fullScreen) { return }
        w.toggleFullScreen(nil)
    }

    func setAudioOnly(_ on: Bool) {
        if isMusicOwned {
            // A track from Music mode follows its Song / Video switch.
            setMusicVideo(!on)
        } else {
            audioOnlySetting = on
            Config.update { $0.audioOnly = on }
            applyVideo()
        }
        if on && current != nil { toast("Audio only: video is hidden") }
    }

    func setSbDraft(_ d: (Double, Double?)?) { sbDraft = d }

    func refreshSegments() {
        if let id = currentId { fetchSegments(id) }
    }

    func jumpToHighlight() {
        if let t = highlight { seek(to: t) }
    }

    func undoSkip() {
        if let i = undoTarget, i < segments.count {
            undoTarget = nil
            segments[i].ignored = true
            mpv.command(["seek", "\(segments[i].seg.start)", "absolute+exact"])
        }
        notice = nil
    }

    private func videoClicked(_ n: Int) {
        togglePause()
        if n == 2 && mode != .mini { toggleFullscreen() }
    }

    func showControls() {
        if !controlsVisible { controlsVisible = true }
        NSCursor.setHiddenUntilMouseMoves(false)
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let self, !Task.isCancelled else { return }
                // Keeps checking while paused or loading.
                if self.mode != .hidden && (self.paused || self.current == nil) { continue }
                self.controlsVisible = false
                if self.mode == .fullscreen { NSCursor.setHiddenUntilMouseMoves(true) }
                return
            }
        }
    }

    /// The video's details arrived: its full title and channel.
    func setDetails(id: String, title: String, channel: String) {
        guard var v = current, v.id == id else { return }
        if !title.isEmpty { v.title = title }
        if v.channelName == nil && !channel.isEmpty { v.channelName = channel }
        current = v
        notify()
    }

    // MARK: SponsorBlock

    private func fetchSegments(_ id: String) {
        guard Config.settings.sponsorblock else {
            onSegments?([])
            return
        }
        let gen = generation
        Task {
            do {
                let segs = try await Extras.segments(id)
                guard generation == gen else { return }
                setSegments(segs)
            } catch {
                Log.warn("SponsorBlock request failed: \(error.localizedDescription)")
            }
        }
    }

    private func setSegments(_ segs: [Segment]) {
        let s = Config.settings
        segments = segs.map { SegState(seg: $0, mode: s.sbMode($0.category)) }.filter { $0.mode != .off }
        barSegments = segments.filter { ["skip", "mute", "poi"].contains($0.seg.action) }.map {
            BarSegment(start: $0.seg.start, end: $0.seg.end, color: Color(hex: Extras.sbColor($0.seg.category)),
                       label: Extras.sbLabel($0.seg.category), point: $0.seg.action == "poi")
        }
        highlight = segments.first { $0.seg.action == "poi" }?.seg.start
        onSegments?(segments.map(\.seg))
        notify()
    }

    private func checkSegments(_ t: Double) {
        if sbSeeking { return }
        for (i, st) in segments.enumerated() where st.mode == .skip && !st.ignored && st.seg.action == "skip" {
            if t >= st.seg.start && t < st.seg.end - 0.3 {
                sbSeeking = true
                mpv.command(["seek", "\(st.seg.end)", "absolute+exact"])
                undoTarget = i
                showNotice("Skipped: \(Extras.sbLabel(st.seg.category))")
                break
            }
        }
        let inMute = segments.contains { $0.mode == .skip && $0.seg.action == "mute" && !$0.ignored && t >= $0.seg.start && t < $0.seg.end }
        if inMute != sbMuted {
            sbMuted = inMute
            mpv.set("mute", inMute)
        }
        let hv = highlight.map { t < $0 - 2 } ?? false
        if hv != highlightVisible { highlightVisible = hv }
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = after(5) { [weak self] in self?.notice = nil }
    }

    // MARK: mpv events

    private func drainEvents() {
        while let ev = mpv.poll() {
            switch ev {
            case .startFile:
                fileReady = false
                lastError = ""
                errorImportant = false
                errorText = nil
                loading = true
            case .fileLoaded:
                loading = false
                fileReady = true
                applySubtitles()
                notify()
            case .playbackRestart:
                sbSeeking = false
                loading = false
                notify()
                onSeeked?(mpv.double("time-pos") ?? position)
            case .endFile(let reason, let error):
                fileReady = false
                if reason == MPV.endFileError && current != nil {
                    showError(!lastError.isEmpty ? lastError : !error.isEmpty ? error : "Playback failed")
                }
            case .property(let name, let value):
                onProperty(name, value)
            case .log(let prefix, let level, let text):
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let line = "mpv[\(prefix)] \(t)"
                if level == "warn" { Log.warn(line) } else { Log.error(line) }
                let http = t.contains("HTTP error")
                if level == "error" || level == "fatal" || http {
                    // HTTP errors explain more than the generic follow-ups.
                    if lastError.isEmpty || (http && !errorImportant) {
                        lastError = t
                        errorImportant = http
                    }
                }
            case .shutdown:
                break
            }
        }
    }

    private func showError(_ msg: String) {
        Log.error("playback of \(currentId ?? "") failed: \(msg)")
        loading = false
        let text = describePlaybackError(msg)
        errorText = text
        notify()
        onError?(text)
    }

    private func onProperty(_ name: String, _ value: MPV.Value) {
        switch name {
        case "time-pos":
            guard let t = value.double else { return }
            position = t
            if !paused {
                let rate = speed
                withReport { r, now in r.time(t, rate: rate, now: now) }
            }
            checkSegments(t)
            notify()
        case "duration":
            duration = value.double ?? 0
            let d = duration
            withReport { r, _ in r.setLength(d); return [] }
            notify()
        case "demuxer-cache-time":
            buffered = value.double ?? 0
        case "pause":
            let p = value.bool ?? false
            paused = p
            if p { withReport { r, now in r.pause(now: now) } }
            showControls()
            notify()
        case "paused-for-cache", "seeking":
            if value.bool == true {
                loading = true
            } else if duration > 0 {
                loading = false
            }
            notify()
        case "volume":
            if let v = value.double {
                volume = v
                notify()
            }
        case "mute":
            muted = value.bool ?? false
            notify()
        case "speed":
            if let s = value.double {
                speed = s
                notify()
            }
        case "eof-reached":
            if value.bool == true && current != nil && !eofHandled {
                eofHandled = true
                onEnded?()
            } else if value.bool == false {
                eofHandled = false
            }
        default:
            break
        }
    }

    var timeText: String {
        if current?.isLive == true && duration <= 0 { return "\(Format.time(position)) • LIVE" }
        return "\(Format.time(position)) / \(Format.time(duration))"
    }

    func shutdown() {
        finishReportBlocking()
        mpv.destroy()
    }
}
