import AppKit
import GTubeCore
import SwiftUI

enum MusicSource: Hashable {
    case browse(id: String, params: String?)
    case search(query: String, params: String?)

    static func browseTo(_ id: String) -> MusicSource { .browse(id: id, params: nil) }

    static func from(_ t: Target) -> MusicSource? {
        switch t {
        case .browse(let id, let params): return .browse(id: id, params: params)
        case .search(let q, let params): return .search(query: q, params: params)
        case .watch: return nil
        }
    }

    var endpoint: String {
        if case .search = self { return "search" }
        return "browse"
    }

    var browseId: String? {
        if case .browse(let id, _) = self { return id }
        return nil
    }
}

enum MusicSection: String, Hashable { case home, explore, library }

/// A Music page: any browse or search result as a header, chips, a top result
/// and shelves, loading more as it is scrolled.
@MainActor @Observable
final class MusicPageModel {
    private(set) var source: MusicSource?
    /// What clicking the selected chip goes back to.
    private var base: MusicSource?
    private(set) var page: MPage?
    private(set) var status: FeedStatus = .idle
    var needsLogin = false
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var pageCont: String?
    /// The shelf (index) whose rows continue, and its token.
    @ObservationIgnored private var listCont: (Int, String)?

    init(_ s: MusicSource? = nil) {
        source = s
        base = s
    }

    var title: String? { page?.title }

    /// Sets what the page shows (loaded on the next `ensureLoaded`/`load`).
    func setSource(_ s: MusicSource) {
        source = s
        base = s
        loaded = false
    }

    /// Shows `s` (a filter of the base source) on the next load.
    func setCurrent(_ s: MusicSource) {
        source = s
        loaded = false
    }

    func ensureLoaded() { if !loaded { load() } }

    /// Forgets the content (session changed); reloaded when next shown.
    func invalidate() {
        loaded = false
        generation += 1
        page = nil
    }

    func load() {
        guard let src = source else { return }
        loaded = true
        generation += 1
        let gen = generation
        if needsLogin && !Client.shared.isLoggedIn {
            page = nil
            status = .needsLogin
            return
        }
        status = .loading
        page = nil
        pageCont = nil
        listCont = nil
        busy = false
        Task {
            do {
                let v: JSON
                switch src {
                case .browse(let id, let params): v = try await Client.shared.musicBrowse(id, params: params)
                case .search(let q, let params): v = try await Client.shared.musicSearch(q, params: params)
                }
                guard gen == generation else { return }
                render(Music.page(v))
            } catch {
                guard gen == generation else { return }
                status = .error(error.localizedDescription)
            }
        }
    }

    private func render(_ p: MPage) {
        page = p
        pageCont = p.continuation
        listCont = p.shelves.indices.last.flatMap { i in p.shelves[i].continuation.map { (i, $0) } }
        let empty = p.shelves.isEmpty && p.top == nil && p.header == nil
        status = empty ? .empty : .idle
        AppModel.shared.music.pageLoaded(self)
    }

    /// Picking a chip (filter); picking the selected one goes back.
    func selectChip(_ c: MChip) {
        if c.selected, let b = base {
            source = b
        } else if let s = MusicSource.from(c.target) {
            source = s
        }
        load()
    }

    var hasMore: Bool { listCont != nil || pageCont != nil }

    /// Loads more once the end of the page is near.
    func loadMore() {
        guard !busy, let src = source, page != nil else { return }
        let endpoint = src.endpoint
        let gen = generation
        if let lc = listCont {
            let (shelf, token) = lc
            busy = true
            Task {
                let more = (try? await Client.shared.musicContinuation(endpoint, token)).map(Music.more)
                busy = false
                guard gen == generation, var p = page, shelf < p.shelves.count else { return }
                guard let more else { listCont = nil; return }
                p.shelves[shelf].entries += more.entries
                page = p
                listCont = more.continuation.map { (shelf, $0) }
            }
        } else if let token = pageCont {
            busy = true
            Task {
                let more = (try? await Client.shared.musicContinuation(endpoint, token)).map(Music.more)
                busy = false
                guard gen == generation, var p = page else { return }
                guard let more else { pageCont = nil; return }
                p.shelves += more.shelves
                page = p
                pageCont = more.continuation
                if let i = p.shelves.indices.last, let c = p.shelves[i].continuation, listCont == nil, more.shelves.count > 0 {
                    listCont = (i, c)
                }
            }
        }
    }

    func setSaved(_ saved: Bool) {
        guard var p = page, p.header != nil else { return }
        p.header!.saved = saved
        page = p
    }

    func setSubscribed(_ on: Bool) {
        guard var p = page, p.header != nil else { return }
        p.header!.subscribed = on
        page = p
    }
}

enum LyricsState: Equatable {
    case missing, loading
    case ready(Lyrics)
}

/// YouTube Music mode: its own sidebar (Home, Explore, Library and your
/// playlists), search, pages, play queue, player bar and "Now playing",
/// sharing the window's player.
@MainActor @Observable
final class MusicModel {
    let queue = MusicQueue()
    let home = MusicPageModel(.browseTo("FEmusic_home"))
    let explore = MusicPageModel(.browseTo("FEmusic_explore"))
    let library: MusicPageModel = {
        let m = MusicPageModel(.browseTo("FEmusic_library_landing"))
        m.needsLogin = true
        return m
    }()
    let searchPage = MusicPageModel()
    var section: MusicSection = .home
    var path: [MusicRoute] = []
    private(set) var nowVisible = false
    private(set) var immersive = false
    var nowTab: NowTab = .upNext
    var immersivePanel = Config.settings.immersivePanel
    var searchText = ""
    private(set) var suggestions: [Suggestion] = []
    @ObservationIgnored private var suggestGen = 0
    private(set) var playlists: [(String, String, Target)] = []
    private(set) var lyrics: LyricsState = .missing
    @ObservationIgnored private var lyricsKey = ""
    @ObservationIgnored private var lyricsGen = 0
    private(set) var related: MusicPageModel?
    @ObservationIgnored private var relatedId: String?
    private(set) var ambient: Color?
    private(set) var ambientArt: String?
    private(set) var active = false
    /// Pushed page models, by route.
    @ObservationIgnored var pages: [MusicRoute: MusicPageModel] = [:]

    var player: PlayerModel { AppModel.shared.player }

    func model(for r: MusicRoute) -> MusicPageModel {
        if let m = pages[r] { return m }
        let m: MusicPageModel
        switch r {
        case .page(let s, _): m = MusicPageModel(s)
        case .search: m = searchPage
        }
        pages[r] = m
        return m
    }

    /// Music mode was shown or hidden.
    func setActive(_ on: Bool) {
        active = on
        if on {
            if path.isEmpty { currentRoot.ensureLoaded() }
            updateAmbient()
        }
    }

    var currentRoot: MusicPageModel {
        switch section {
        case .home: return home
        case .explore: return explore
        case .library: return library
        }
    }

    /// The page on screen (for refreshing).
    var visiblePage: MusicPageModel {
        if let r = path.last { return model(for: r) }
        return currentRoot
    }

    func refresh() { visiblePage.load() }

    /// Switches to a top-level section.
    func go(_ s: MusicSection) {
        showNow(false)
        section = s
        path = []
        currentRoot.ensureLoaded()
    }

    func back() {
        if nowVisible { return showNow(false) }
        if !path.isEmpty { path.removeLast() }
    }

    func open(_ t: Target) {
        switch t {
        case .browse(let id, let params):
            switch id {
            case "FEmusic_home" where params == nil: go(.home)
            case "FEmusic_explore": go(.explore)
            case "FEmusic_library_landing": go(.library)
            default: push(.browse(id: id, params: params))
            }
        case .watch: queue.play(t)
        case .search(let q, let params): searchWith(q, params: params)
        }
    }

    /// Plays a target (an album's, a playlist's, a song's radio).
    func play(_ t: Target) { queue.play(t) }

    private func push(_ s: MusicSource) {
        showNow(false)
        let r = MusicRoute.page(s, UUID())
        let m = model(for: r)
        path.append(r)
        m.load()
    }

    /// Searches, or opens the link if the text is a YouTube (Music) link.
    func search(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        if let t = Music.musicURL(text) { return open(t) }
        if let r = Parse.youtubeURL(text) {
            switch r {
            case .video(let id, let pl, _): return queue.play(.watch(videoId: id, playlistId: pl, params: nil, index: nil))
            case .playlist(let id): return open(.browseTo("VL\(id)"))
            case .channel(let id) where id.hasPrefix("UC"): return open(.browseTo(id))
            default: break
            }
        }
        searchWith(text, params: nil)
    }

    private func searchWith(_ query: String, params: String?) {
        searchText = query
        suggestGen += 1
        suggestions = []
        showNow(false)
        // Unfiltered search is what clicking the selected filter returns to.
        searchPage.setSource(.search(query: query, params: nil))
        if params != nil { searchPage.setCurrent(.search(query: query, params: params)) }
        searchPage.load()
        if path.last != .search {
            if let i = path.lastIndex(of: .search) { path.removeSubrange((i + 1)...) } else { path.append(.search) }
        }
    }

    func updateSuggestions(_ text: String) {
        suggestGen += 1
        let gen = suggestGen
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.contains("://") || t.hasPrefix("music.youtube.com") {
            suggestions = []
            return
        }
        Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard gen == suggestGen else { return }
            let list = (try? await Client.shared.musicSuggestions(t)) ?? []
            guard gen == suggestGen else { return }
            suggestions = Array(list.prefix(12))
        }
    }

    // MARK: Now playing and immersive

    func showNow(_ on: Bool) {
        if on && player.currentId == nil { return }
        if nowVisible == on { return }
        nowVisible = on
        if on { loadTab() }
    }

    func toggleNow() { showNow(!nowVisible) }

    /// The immersive view: the playing track across the whole screen.
    func setImmersive(_ on: Bool) {
        if on && player.currentId == nil { return }
        if immersive == on { return }
        immersive = on
        player.setImmersive(on)
        let win = AppModel.shared.window
        let fs = win?.styleMask.contains(.fullScreen) ?? false
        if on && !fs { win?.toggleFullScreen(nil) }
        if !on && fs && player.mode != .fullscreen { win?.toggleFullScreen(nil) }
        if on { updateLyrics() }
    }

    func setImmersivePanel(_ p: String) {
        immersivePanel = immersivePanel == p ? "" : p
        Config.update { $0.immersivePanel = immersivePanel }
        updateLyrics()
    }

    var lyricsShown: Bool {
        (nowVisible && nowTab == .lyrics) || (immersive && immersivePanel == "lyrics")
    }

    // MARK: Tracks

    /// The track that plays changed.
    func trackChanged() {
        relatedId = nil
        related = nil
        updateLyrics()
        loadTab()
        updateAmbient()
    }

    /// Like status, lyrics or related of the current track arrived.
    func infoChanged() {
        updateLyrics()
        loadTab()
    }

    /// The player's position, pause, loading or volume changed.
    func onPlayerState() {
        if player.isMusicOwned && !player.hasFailed && player.position > 1 { queue.playingOK() }
        updateAmbient()
    }

    /// Loads the related tab for the current track when shown.
    func loadTab() {
        guard nowVisible && nowTab == .related else {
            if nowVisible && nowTab == .lyrics { updateLyrics() }
            return
        }
        let info = queue.info
        guard info.ready, let id = info.relatedId else { return }
        if relatedId == id { return }
        relatedId = id
        let m = MusicPageModel(.browseTo(id))
        related = m
        m.load()
    }

    func setNowTab(_ t: NowTab) {
        nowTab = t
        loadTab()
        updateLyrics()
    }

    /// Loads the lyrics of the track that is playing, when they are on screen.
    func updateLyrics() {
        guard lyricsShown else { return }
        guard let track = queue.current, player.isMusicOwned else {
            if !lyricsKey.isEmpty || lyrics != .missing {
                lyricsKey = ""
                lyricsGen += 1
                lyrics = .missing
            }
            return
        }
        let info = queue.info
        if info.videoId != track.videoId || !info.ready {
            // Waiting for the lyrics tab (the queue's info) to arrive.
            let key = "\(track.videoId)|pending"
            if lyricsKey != key {
                lyricsKey = key
                lyricsGen += 1
                lyrics = .loading
            }
            return
        }
        let useLrclib = Config.settings.lyricsLrclib
        let key = "\(track.videoId)|\(info.lyricsId ?? "")|\(useLrclib)"
        if lyricsKey == key { return }
        lyricsKey = key
        lyricsGen += 1
        let gen = lyricsGen
        lyrics = .loading
        let duration = track.duration.flatMap(Format.parseLength) ?? (player.duration > 0 ? player.duration : nil)
        let song = Song(title: track.title, artists: track.artists.map(\.text), duration: duration)
        let lid = info.lyricsId
        Task {
            let found = await findLyrics(Client.shared, lyricsId: lid, song: song, useLrclib: useLrclib)
            guard gen == lyricsGen else { return }
            lyrics = found.map { .ready($0) } ?? .missing
        }
    }

    /// The lyrics settings changed: look again.
    func lyricsSourceChanged() {
        lyricsKey = ""
        updateLyrics()
    }

    /// "Ambient color": the dominant color of the art that is playing.
    func updateAmbient() {
        let art: String?
        if let v = player.current {
            if player.isMusicOwned, let t = queue.current, t.videoId == v.id {
                art = t.thumbnailURL(226)
            } else {
                art = v.thumbnail ?? "https://i.ytimg.com/vi/\(v.id)/mqdefault.jpg"
            }
        } else {
            art = nil
        }
        if art == ambientArt { return }
        ambientArt = art
        guard let art, Config.settings.musicAmbient else {
            ambient = nil
            return
        }
        ImageLoader.shared.load(art) { [weak self] img in
            guard let self, self.ambientArt == art else { return }
            withAnimation(.easeInOut(duration: 0.8)) { self.ambient = Ambient.dominantColor(img) }
        }
    }

    /// The "Ambient color" / "Spectrum visualizer" settings changed.
    func appearanceChanged() {
        ambientArt = nil
        if !Config.settings.musicAmbient { ambient = nil }
        updateAmbient()
        player.updateAudioFilter()
    }

    /// The player's Song / Video choice changed elsewhere ("A").
    func setVideo(_ on: Bool) { player.setMusicVideo(on) }

    // MARK: Session

    func pageLoaded(_ m: MusicPageModel) {}

    /// Signed in or out: reload what depends on the session.
    func startSession() {
        for v in [home, explore, library, searchPage] { v.invalidate() }
        pages = pages.filter { $0.key == .search }
        if active { visiblePage.load() }
    }

    /// Your playlists in the sidebar.
    func loadPlaylists() {
        playlists = []
        guard Client.shared.isLoggedIn else { return }
        Task {
            var items: [(String, String, Target)] = []
            if let v = try? await Client.shared.musicBrowse("FEmusic_liked_playlists") {
                for e in Music.page(v).shelves.flatMap(\.entries) {
                    if case .card(let c) = e, let t = c.target, case .browse = t {
                        items.append((c.title, c.subtitleText, t))
                    }
                }
            }
            if !items.contains(where: { $0.2 == .browseTo("VLLM") }) {
                items.insert(("Liked music", "Auto playlist", .browseTo("VLLM")), at: 0)
            }
            playlists = items
        }
    }
}

enum MusicRoute: Hashable {
    case page(MusicSource, UUID)
    case search
}

enum NowTab: String, CaseIterable, Identifiable {
    case upNext = "Up next", lyrics = "Lyrics", related = "Related"
    var id: String { rawValue }
}
