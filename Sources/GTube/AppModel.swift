import AppKit
import GTubeCore
import SwiftUI

/// The top-level sections of YouTube mode.
enum NavSection: String, Hashable, CaseIterable {
    case home, subs, trending, you, history, playlists, later, liked, channels, downloads

    var title: String {
        switch self {
        case .home: return "Home"
        case .subs: return "Subscriptions"
        case .trending: return "Trending"
        case .you: return "You"
        case .history: return "History"
        case .playlists: return "Playlists"
        case .later: return "Watch later"
        case .liked: return "Liked videos"
        case .channels: return "Channels"
        case .downloads: return "Downloads"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .subs: return "play.square.stack"
        case .trending: return "flame"
        case .you: return "person.crop.circle"
        case .history: return "clock.arrow.circlepath"
        case .playlists: return "list.bullet.rectangle"
        case .later: return "clock"
        case .liked: return "hand.thumbsup"
        case .channels: return "person.2"
        case .downloads: return "arrow.down.circle"
        }
    }
}

/// Pages pushed over a section.
enum Route: Hashable {
    case watch
    case search
    case channel(String)
    case playlist(String)
}

/// Dialogs (sheets) the window shows.
enum Sheet: Identifiable {
    case download(VideoItem)
    case downloadPlaylist(PlaylistItem)
    case saveToPlaylist(String)
    case newPlaylist(String)
    case editPlaylist(PlaylistViewModel)
    case submitSegment
    case signIn
    case browserImport
    case googleSignIn

    var id: String {
        switch self {
        case .download(let v): return "dl:\(v.id)"
        case .downloadPlaylist(let p): return "dlp:\(p.id)"
        case .saveToPlaylist(let v): return "save:\(v)"
        case .newPlaylist(let v): return "new:\(v)"
        case .editPlaylist(let p): return "edit:\(p.id)"
        case .submitSegment: return "sb"
        case .signIn: return "signin"
        case .browserImport: return "browser"
        case .googleSignIn: return "google"
        }
    }
}

/// YouTube's Explore pages, which replaced its Trending page.
let trendingCategories: [(String, String)] = [
    ("Music", "UC-9-kyTW8ZkZNDHQJ6FgpwQ"),
    ("Gaming", "UCOpNcN46UbXVtpKMrmU4Abg"),
    ("News", "UCYfdidRxbB8Qhf0Nx7ioOYw"),
    ("Sports", "UCEgdi0XIXXZ-qJOFPf4JSKw"),
    ("Live", "UC4R8DWoMoI7CAwX8_LjQHig"),
    ("Fashion & Beauty", "UCrpQ4p1Ql_hG8rKXIKM1MOQ"),
]

let searchFilters: [(String, String?)] = [("All", nil), ("Videos", "EgIQAQ%3D%3D"), ("Channels", "EgIQAg%3D%3D"), ("Playlists", "EgIQAw%3D%3D")]

/// Application-wide state, only touched on the main thread.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let player = PlayerModel()
    let watch = WatchModel()
    let downloads = DownloadsModel()
    let music = MusicModel()

    // YouTube mode.
    var section: NavSection = .home
    var path: [Route] = []
    let home = FeedModel(.browse(id: "FEwhat_to_watch", params: nil))
    let subs = FeedModel(.browse(id: "FEsubscriptions", params: nil), needsLogin: true)
    let trending = FeedModel(.browse(id: trendingCategories[0].1, params: nil))
    var trendingIndex = 0
    let library = LibraryModel()
    let searchFeed = FeedModel(.empty)
    var searchQuery = ""
    var searchFilter: String?
    var searchText = ""
    var suggestions: [String] = []
    @ObservationIgnored private var suggestGen = 0

    /// "video" (YouTube) or "music" (YouTube Music).
    private(set) var isMusic = false
    var sheet: Sheet?
    var showSidebar = true
    private(set) var account: Account?
    private(set) var accounts: [SavedAccount] = Config.settings.accounts
    private(set) var activeAccount = Config.settings.activeAccount
    private(set) var loggedIn = false

    @ObservationIgnored weak var window: NSWindow?
    /// While compact: the window's frame and style to go back to.
    @ObservationIgnored private var compactSaved: (NSRect, Bool)?
    private(set) var isCompact = false
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var started = false

    init() {}

    /// Wires the parts together and starts (once, when the window appears).
    func start() {
        if started { return }
        started = true
        Log.info("window shown; yt-dlp: \(Tools.ytdlp ?? "not found"), ffmpeg: \(Tools.ffmpeg ?? "not found")")
        Client.shared.setCookies(Config.loadCookies())
        loggedIn = Client.shared.isLoggedIn

        // The player is shared: what it does next depends on which mode
        // started the current item.
        player.onEnded = { [self] in
            if player.isMusicOwned { music.queue.onEnded() } else { watch.playNext() }
        }
        player.onExpand = { [self] in
            if player.isMusicOwned {
                setMode(music: true)
                music.showNow(true)
            } else {
                if isMusic { setMode(music: false) }
                showWatch()
            }
        }
        player.onState = { [self] in
            music.onPlayerState()
            NowPlaying.shared.update()
        }
        player.onSeeked = { _ in NowPlaying.shared.seeked() }
        player.onError = { [self] _ in
            if player.isMusicOwned { music.queue.onError() }
        }
        player.onMusicVideo = { [self] video in
            music.queue.videoSwitched(video)
        }
        player.onMinimize = { [self] in
            if path.last == .watch { path.removeLast() }
        }
        player.onSegments = { [self] segs in watch.setSegments(segs) }

        NowPlaying.shared.start()
        Spectrum.initialize()
        installKeyMonitor()
        startSession()
        setMode(music: Config.settings.uiMode == "music")
        if !isMusic { go(.home) }
    }

    // MARK: Navigation

    /// Switches to a top-level section.
    func go(_ s: NavSection) {
        switch s {
        case .home: home.ensureLoaded()
        case .subs: subs.ensureLoaded()
        case .trending: trending.ensureLoaded()
        case .you, .history, .playlists, .later, .liked, .channels:
            library.show(tab: s == .you ? .history : LibraryTab(rawValue: s.rawValue) ?? .history)
        case .downloads: break
        }
        section = s
        path = []
    }

    /// Brings a page to the front: back to it when it is in the stack, else pushed.
    func show(_ r: Route) {
        if path.last == r { return }
        if let i = path.lastIndex(of: r) {
            path.removeSubrange((i + 1)...)
        } else {
            path.append(r)
        }
    }

    func showWatch() { show(.watch) }

    func back() {
        if isMusic {
            music.back()
        } else if !path.isEmpty {
            path.removeLast()
        }
    }

    var canRefresh: Bool {
        if isMusic { return true }
        if let last = path.last { return last == .search }
        return section != .downloads
    }

    func refresh() {
        if isMusic {
            music.refresh()
            return
        }
        if path.last == .search { return searchFeed.refresh() }
        if !path.isEmpty { return }
        switch section {
        case .home: home.refresh()
        case .subs: subs.refresh()
        case .trending: trending.refresh()
        case .you, .history, .playlists, .later, .liked, .channels: library.reset()
        case .downloads: break
        }
    }

    func setTrending(_ i: Int) {
        trendingIndex = i
        trending.setSource(.browse(id: trendingCategories[i].1, params: nil))
    }

    /// Switches between YouTube and YouTube Music.
    func setMode(music on: Bool) {
        let changed = on != isMusic
        isMusic = on
        window?.title = on ? "GTube Music" : "GTube"
        if Config.settings.uiMode != (on ? "music" : "video") {
            Config.update { $0.uiMode = on ? "music" : "video" }
        }
        player.setMusicPresentation(on)
        music.setActive(on)
        if changed {
            suggestions = []
        }
    }

    func toggleMode() { setMode(music: !isMusic) }

    // MARK: Searching and links

    /// Searches (or opens a link) in the mode that is showing; a YouTube Music
    /// link switches to Music mode.
    func search(_ q: String) {
        if Music.musicURL(q) != nil {
            setMode(music: true)
            music.search(q)
        } else if isMusic {
            music.search(q)
        } else {
            videoSearch(q)
        }
    }

    /// Searches YouTube, or opens the link if the text is a YouTube URL.
    func videoSearch(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        if let r = Parse.youtubeURL(text) {
            openResolved(r)
            return
        }
        searchText = text
        suggestGen += 1
        suggestions = []
        searchQuery = text
        searchFeed.setSource(.search(query: text, params: searchFilter))
        show(.search)
    }

    func setSearchFilter(_ f: String?) {
        searchFilter = f
        if !searchQuery.isEmpty { searchFeed.setSource(.search(query: searchQuery, params: f)) }
    }

    func updateSuggestions(_ text: String) {
        suggestGen += 1
        let gen = suggestGen
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || Parse.youtubeURL(t) != nil {
            suggestions = []
            return
        }
        Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard gen == suggestGen else { return }
            let list = (try? await Client.shared.suggestions(t)) ?? []
            guard gen == suggestGen else { return }
            suggestions = Array(list.prefix(10))
        }
    }

    func openVideo(_ v: VideoItem) {
        if isMusic { setMode(music: false) }
        watch.open(v, queue: nil, start: 0)
    }

    func openChannel(_ id: String) {
        if isMusic { setMode(music: false) }
        if id.hasPrefix("UC") {
            show(.channel(id))
        } else {
            // @handles and custom URLs need resolving first.
            openResolved(.search(id.hasPrefix("http") ? id : "https://www.youtube.com/\(id)"))
        }
    }

    func openPlaylist(_ id: String) {
        if isMix(id) { return QueueLoader.openMix(video: nil, list: id, start: 0) }
        if isMusic { setMode(music: false) }
        show(.playlist(id))
    }

    func activate(_ item: Item) {
        switch item {
        case .video(let v): openVideo(v)
        case .channel(let c): openChannel(c.id)
        case .playlist(let p) where p.isMix: QueueLoader.openMix(video: p.videoId, list: p.id, start: 0)
        case .playlist(let p): openPlaylist(p.id)
        }
    }

    func openResolved(_ r: Resolved) {
        switch r {
        case .video(let id, .some(let list), let start):
            // Like youtube.com, a watch link with &list= plays the list as the queue.
            if isMusic { setMode(music: false) }
            QueueLoader.openPlaylist(video: id, list: list, start: start ?? 0, shuffle: false)
        case .video(let id, nil, let start):
            if isMusic { setMode(music: false) }
            watch.open(VideoItem(id: id), queue: nil, start: start ?? 0)
        case .channel(let id): openChannel(id)
        case .playlist(let id): openPlaylist(id)
        case .search(let url):
            Task {
                do {
                    let r = try await Client.shared.resolveURL(url)
                    if case .search = r { toast("Could not open \(url)") } else { openResolved(r) }
                } catch {
                    toast("Could not open \(url)")
                }
            }
        }
    }

    /// A link in a description or comment. Returns whether the app handled it.
    func handleLink(_ url: URL) -> Bool {
        switch url.scheme {
        case "seek":
            if let t = Double(url.absoluteString.dropFirst(5)) { player.seek(to: t) }
            return true
        case "search":
            let q = String(url.absoluteString.dropFirst(7)).removingPercentEncoding ?? ""
            search(q)
            return true
        case "gtube-music":
            music.open(.browseTo(String(url.absoluteString.dropFirst("gtube-music:".count))))
            return true
        default:
            if let t = Music.musicURL(url.absoluteString) {
                setMode(music: true)
                music.open(t)
                return true
            }
            if let r = Parse.youtubeURL(url.absoluteString) {
                if case .search = r { return false }
                openResolved(r)
                return true
            }
            return false
        }
    }

    /// The handler for links in text views.
    var linkAction: OpenURLAction {
        OpenURLAction { url in
            MainActor.assumeIsolated { AppModel.shared.handleLink(url) } ? .handled : .systemAction
        }
    }

    // MARK: Playing

    func next() {
        if player.isMusicOwned { music.queue.next() } else if player.currentId != nil { watch.next() }
    }

    func previous() {
        if player.isMusicOwned { music.queue.previous() } else if player.currentId != nil { watch.previous() }
    }

    func showDownload(_ v: VideoItem) { sheet = .download(v) }

    // MARK: Accounts

    /// (Re)loads everything that depends on the session: at startup and after
    /// signing in or out.
    func startSession() {
        home.invalidate()
        subs.invalidate()
        trending.invalidate()
        library.reset()
        setAccount(nil)
        music.startSession()
        Task {
            do {
                try await Client.shared.bootstrap()
                let acc = try await Client.shared.account()
                loggedIn = Client.shared.isLoggedIn
                setAccount(acc)
            } catch {
                Log.error("session start failed: \(error.localizedDescription)")
                toast("Could not reach YouTube: \(error.localizedDescription)")
            }
            loggedIn = Client.shared.isLoggedIn
            if path.isEmpty && section == .home && !loggedIn && !isMusic {
                // Without an account YouTube's home feed is empty.
                go(.trending)
            } else if path.isEmpty {
                switch section {
                case .home: home.ensureLoaded()
                case .subs: subs.ensureLoaded()
                case .trending: trending.ensureLoaded()
                case .you, .history, .playlists, .later, .liked, .channels: library.reset()
                case .downloads: break
                }
            }
        }
    }

    private func setAccount(_ a: Account?) {
        loggedIn = Client.shared.isLoggedIn
        if let a { Config.rememberAccount(name: a.name, channelId: a.channelId) }
        account = a
        library.account = a
        music.loadPlaylists()
        refreshAccounts()
    }

    private func refreshAccounts() {
        accounts = Config.settings.accounts
        activeAccount = Config.settings.activeAccount
    }

    /// Saves a new session as an account and switches to it.
    func addAccount(_ jar: CookieJar) {
        let jar = jar.onlyYouTube()
        guard jar.hasLogin else {
            toast("No signed-in YouTube session found in those cookies")
            return
        }
        do {
            try Config.addAccount(jar)
            useActiveAccount("Signed in")
        } catch {
            toast("Could not save session: \(error.localizedDescription)")
        }
    }

    /// Switches to a saved account ("" browses without one).
    func switchAccount(_ id: String) {
        if Config.settings.activeAccount == id { return }
        Config.update { $0.activeAccount = id }
        useActiveAccount(id.isEmpty ? "Browsing without an account" : "Switched account")
    }

    func signOut() {
        Log.info("signing out")
        Config.removeAccount(Config.settings.activeAccount)
        useActiveAccount("Signed out")
    }

    func useActiveAccount(_ msg: String) {
        Client.shared.setCookies(Config.loadCookies())
        loggedIn = Client.shared.isLoggedIn
        refreshAccounts()
        toast(msg)
        startSession()
    }

    func applyLocale() {
        let s = Config.settings
        Client.shared.setLocale(hl: s.language, gl: s.region)
        startSession()
    }

    // MARK: Window

    func toggleCompact() { setCompact(!isCompact) }

    /// Shrinks the window to a small player only (or restores it). On macOS
    /// the compact player stays on top of other windows.
    func setCompact(_ on: Bool) {
        guard let win = window, on != isCompact, !(on && player.currentId == nil) else { return }
        if on {
            if win.styleMask.contains(.fullScreen) { win.toggleFullScreen(nil) }
            music.setImmersive(false)
            compactSaved = (win.frame, win.isZoomed)
            isCompact = true
            player.setCompact(true)
            let s = Config.settings
            win.minSize = NSSize(width: 200, height: 112)
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            win.standardWindowButton(.closeButton)?.isHidden = true
            win.standardWindowButton(.miniaturizeButton)?.isHidden = true
            win.standardWindowButton(.zoomButton)?.isHidden = true
            win.level = .floating
            win.isMovableByWindowBackground = true
            let size = NSSize(width: max(s.compactWidth, 200), height: max(s.compactHeight, 112))
            let screen = win.screen?.visibleFrame ?? win.frame
            win.setFrame(NSRect(x: screen.maxX - size.width - 24, y: screen.minY + 24, width: size.width, height: size.height), display: true, animate: true)
        } else {
            guard let saved = compactSaved else { return }
            let frame = saved.0
            compactSaved = nil
            if !win.styleMask.contains(.fullScreen) {
                let f = win.frame
                Config.update { s in
                    s.compactWidth = Int(f.width)
                    s.compactHeight = Int(f.height)
                }
            }
            isCompact = false
            player.setCompact(false)
            win.level = .normal
            win.isMovableByWindowBackground = false
            win.titleVisibility = .visible
            win.titlebarAppearsTransparent = false
            win.standardWindowButton(.closeButton)?.isHidden = false
            win.standardWindowButton(.miniaturizeButton)?.isHidden = false
            win.standardWindowButton(.zoomButton)?.isHidden = false
            win.minSize = NSSize(width: 480, height: 400)
            win.setFrame(frame, display: true, animate: true)
        }
    }

    func windowFullscreenChanged(_ fs: Bool) {
        player.setFullscreen(fs)
        // Leaving fullscreen (also from the system) leaves the immersive view.
        if !fs { music.setImmersive(false) }
    }

    /// Remembers the window's size for the next start.
    func saveWindowState() {
        guard let w = window, !w.styleMask.contains(.fullScreen) else { return }
        let f = compactSaved?.0 ?? w.frame
        Config.update { s in
            s.windowWidth = Int(f.width)
            s.windowHeight = Int(f.height)
            s.windowMaximized = w.isZoomed
        }
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            MainActor.assumeIsolated { AppModel.shared.onKey(ev) } ? nil : ev
        }
    }

    /// The window's keyboard shortcuts. Returns whether the key was handled.
    func onKey(_ ev: NSEvent) -> Bool {
        let flags = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let typing = (NSApp.keyWindow?.firstResponder is NSText) || (NSApp.keyWindow?.firstResponder is NSTextView)
        let chars = ev.charactersIgnoringModifiers ?? ""
        let key = chars.lowercased()
        let cmd = flags.contains(.command)
        let ctrl = flags.contains(.control)
        let shift = flags.contains(.shift)
        let opt = flags.contains(.option)
        if NSApp.keyWindow !== window && NSApp.keyWindow != nil { return false }

        // Control-key shortcuts of the original (Control is free on macOS).
        if ctrl && !cmd {
            if key == "m" && shift { toggleCompact(); return true }
            if key == "m" { toggleMode(); return true }
            if key == "l" || key == "f" { focusSearch(); return true }
            if key == "r" { refresh(); return true }
        }
        if opt && !cmd && ev.keyCode == 123 { back(); return true }
        if opt && !cmd, let n = Int(key), (1...4).contains(n) {
            goNumber(n)
            return true
        }
        if !typing && !cmd && !ctrl && !opt && key == "/" {
            focusSearch()
            return true
        }
        if typing || cmd || ctrl || opt { return false }
        let p = player
        // Shift+N / Shift+P work without anything playing too.
        if shift && key == "n" { next(); return true }
        if shift && key == "p" { previous(); return true }
        guard p.currentId != nil else { return false }
        let space = ev.keyCode == 49
        let esc = ev.keyCode == 53
        let left = ev.keyCode == 123, right = ev.keyCode == 124, up = ev.keyCode == 126, down = ev.keyCode == 125
        if isMusic {
            let docked = p.mode == .docked || p.mode == .fullscreen
            switch true {
            case space || key == "k": p.togglePause()
            case key == "m": p.toggleMute()
            case key == "j": p.seekRelative(-10)
            case key == "l": p.seekRelative(10)
            case left && music.nowVisible: p.seekRelative(-5)
            case right && music.nowVisible: p.seekRelative(5)
            case key == "f" && !isCompact: music.setImmersive(!music.immersive)
            case key == "f" && docked: p.toggleFullscreen()
            case esc && music.immersive: music.setImmersive(false)
            case esc && p.fullscreen: p.toggleFullscreen()
            case esc && isCompact: setCompact(false)
            case esc && music.nowVisible: music.showNow(false)
            case key == "a": p.setAudioOnly(!p.isAudioOnly)
            case chars == "+" || chars == "=": p.changeVolume(5)
            case chars == "-": p.changeVolume(-5)
            default: return false
            }
            return true
        }
        let big = p.mode == .docked || p.mode == .fullscreen
        switch true {
        case space || key == "k": p.togglePause()
        case key == "m": p.toggleMute()
        case key == "f" && big: p.toggleFullscreen()
        case key == "i": if p.mode == .mini { p.expand() } else { p.minimize() }
        case esc && p.fullscreen: p.toggleFullscreen()
        case esc && isCompact: setCompact(false)
        case chars == ";": SponsorBlockMarker.mark()
        case key == "c": p.toggleSubtitles()
        case key == "t" && p.onWatchPage: p.toggleTheater()
        case key == "j": p.seekRelative(-10)
        case key == "l": p.seekRelative(10)
        case left && big: p.seekRelative(-5)
        case right && big: p.seekRelative(5)
        case up && p.fullscreen: p.changeVolume(5)
        case down && p.fullscreen: p.changeVolume(-5)
        case key == "a": p.setAudioOnly(!p.isAudioOnly)
        default: return false
        }
        return true
    }

    func goNumber(_ n: Int) {
        let s: NavSection = [.home, .subs, .you, .downloads][n - 1]
        if isMusic {
            if s == .home { return music.go(.home) }
            setMode(music: false)
        }
        go(s)
    }

    /// Puts the cursor in the toolbar's search field.
    func focusSearch() {
        if isMusic { music.showNow(false) }
        after(0.05) { [weak self] in
            for item in self?.window?.toolbar?.items ?? [] {
                if let s = item as? NSSearchToolbarItem {
                    s.beginSearchInteraction()
                    return
                }
            }
        }
    }
}
