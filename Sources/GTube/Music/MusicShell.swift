import GTubeCore
import SwiftUI

/// A Music page: header, chips, top result and shelves.
struct MusicPageView: View {
    let model: MusicPageModel
    var showTitle = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                switch model.status {
                case .loading:
                    HStack { Spacer(); ProgressView().controlSize(.large); Spacer() }.padding(80)
                case .needsLogin:
                    StatusBox(icon: "person.crop.circle.badge.questionmark", title: "Sign in to see your library",
                              description: "Your playlists, songs, albums and artists from YouTube Music.", buttonTitle: "Sign in") { AppModel.shared.sheet = .signIn }
                case .error(let e):
                    StatusBox(icon: "exclamationmark.triangle", title: "Could not load this page", description: e, buttonTitle: "Retry") { model.load() }
                case .empty:
                    StatusBox(icon: "music.note", title: "Nothing here")
                case .idle:
                    if let p = model.page {
                        if let h = p.header {
                            MusicHeaderView(header: h, page: model)
                        } else if showTitle, let t = p.title {
                            Text(t).font(.largeTitle.weight(.bold))
                        }
                        if !p.chips.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(Array(p.chips.enumerated()), id: \.offset) { _, c in
                                        Button(c.title) { model.selectChip(c) }.buttonStyle(ChipStyle(selected: c.selected))
                                    }
                                }
                            }
                        }
                        if let top = p.top { TopResultView(top: top) }
                        let numbered = p.header?.kind == .collection && (p.header?.playlistId.map { $0.hasPrefix("OLAK") } ?? false || model.source?.browseId?.hasPrefix("MPRE") == true)
                        ForEach(p.shelves) { s in ShelfView(shelf: s, numbered: numbered) }
                        if model.hasMore {
                            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                                .id(p.shelves.count * 1000 + p.shelves.map(\.entries.count).reduce(0, +))
                                .onAppear { model.loadMore() }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
        .environment(\.openURL, AppModel.shared.linkAction)
    }
}

/// YouTube Music mode: sidebar, search, pages, Now playing and the player bar.
struct MusicShell: View {
    @State private var app = AppModel.shared
    @State private var columns: NavigationSplitViewVisibility = .all
    var music: MusicModel { app.music }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columns) {
                List(selection: Binding<MusicSection?>(get: { music.path.isEmpty && !music.nowVisible ? music.section : nil }, set: { if let s = $0 { music.go(s) } })) {
                    ModeSwitch().padding(.vertical, 4)
                    Label("Home", systemImage: "house").tag(MusicSection.home)
                    Label("Explore", systemImage: "safari").tag(MusicSection.explore)
                    Label("Library", systemImage: "music.note.list").tag(MusicSection.library)
                    SwiftUI.Section("Playlists") {
                        if !app.loggedIn {
                            Text("Sign in to see your playlists").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(Array(music.playlists.enumerated()), id: \.offset) { _, p in
                            Button { music.open(p.2) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.0).lineLimit(1)
                                    if !p.1.isEmpty { Text(p.1).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
                .safeAreaInset(edge: .bottom) { SidebarFooter() }
            } detail: {
                ZStack {
                    if let c = music.ambient {
                        LinearGradient(colors: [c.opacity(0.35), c.opacity(0.08), .clear], startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }
                    if music.nowVisible {
                        NowPlayingView()
                    } else {
                        NavigationStack(path: Binding(get: { music.path }, set: { music.path = $0 })) {
                            root
                                .navigationDestination(for: MusicRoute.self) { r in
                                    MusicPageView(model: music.model(for: r), showTitle: true)
                                        .navigationTitle(r == .search ? "“\(music.searchText)”" : (music.model(for: r).title ?? "Music"))
                                }
                        }
                    }
                }
            }
            .searchable(text: Binding(get: { music.searchText }, set: { music.searchText = $0 }), placement: .toolbar, prompt: "Search songs, albums, artists, podcasts")
            .searchSuggestions {
                ForEach(Array(music.suggestions.enumerated()), id: \.offset) { _, s in
                    switch s {
                    case .query(let q): Label(q, systemImage: "magnifyingglass").searchCompletion(q)
                    case .entry(let e): SuggestionEntry(entry: e)
                    }
                }
            }
            .onSubmit(of: .search) { music.search(music.searchText) }
            .onChange(of: music.searchText) { _, t in music.updateSuggestions(t) }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { app.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh (Ctrl+R)")
                    AccountMenu()
                }
            }
            if app.player.currentId != nil {
                MusicPlayerBar()
            }
        }
        .onChange(of: app.player.fullscreen) { _, fs in columns = fs ? .detailOnly : .all }
    }

    @ViewBuilder
    var root: some View {
        switch music.section {
        case .home: MusicPageView(model: music.home).navigationTitle("Home").onAppear { music.home.ensureLoaded() }
        case .explore: MusicPageView(model: music.explore).navigationTitle("Explore").onAppear { music.explore.ensureLoaded() }
        case .library: MusicPageView(model: music.library).navigationTitle("Library").onAppear { music.library.ensureLoaded() }
        }
    }
}

/// A song, album or artist in the search suggestions.
struct SuggestionEntry: View {
    let entry: Entry

    var body: some View {
        Button { activateEntry(entry) } label: {
            switch entry {
            case .track(let t):
                HStack {
                    MusicArt(url: t.thumbnail, size: 28)
                    VStack(alignment: .leading) {
                        Text(t.title)
                        Text(t.artistNames).font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .card(let c):
                HStack {
                    MusicArt(url: c.thumbnail, size: 28, shape: c.shape == .round ? .round : .square)
                    VStack(alignment: .leading) {
                        Text(c.title)
                        Text(c.subtitleText).font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .mood(let m): Text(m.title)
            }
        }
        .buttonStyle(.plain)
    }
}

/// The player bar along the bottom of Music mode: the track and its rating,
/// transport controls, volume, repeat / shuffle and "Now playing", over the
/// spectrum visualizer.
struct MusicPlayerBar: View {
    @State private var app = AppModel.shared
    var player: PlayerModel { app.player }
    var queue: MusicQueue { app.music.queue }

    var body: some View {
        let track = player.isMusicOwned ? queue.current : nil
        let item = player.current
        VStack(spacing: 0) {
            SeekBar(player: player, tint: .primary)
                .padding(.horizontal, 8)
                .padding(.top, -10)
            ZStack {
                if Config.settings.musicVisualizer {
                    SpectrumView(color: app.music.ambient ?? .primary)
                }
                HStack(spacing: 16) {
                    // The track.
                    HStack(spacing: 10) {
                        MusicArt(url: track.map { $0.thumbnailURL(120) } ?? item?.thumbnailURL, size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track?.title ?? item?.title ?? "").font(.headline).lineLimit(1)
                            if let t = track {
                                LinksText(links: trackByline(t, info: false))
                            } else {
                                Text(item?.channelName ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        if player.isMusicOwned {
                            let like = queue.info.like
                            Button { queue.setLike(like == "DISLIKE" ? "INDIFFERENT" : "DISLIKE") } label: {
                                Image(systemName: like == "DISLIKE" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            }
                            .help("Dislike")
                            Button { queue.setLike(like == "LIKE" ? "INDIFFERENT" : "LIKE") } label: {
                                Image(systemName: like == "LIKE" ? "hand.thumbsup.fill" : "hand.thumbsup")
                            }
                            .help("Like")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Transport.
                    HStack(spacing: 18) {
                        Button { app.previous() } label: { Image(systemName: "backward.fill") }.help("Previous (Shift+P)")
                        Button { player.togglePause() } label: {
                            Group {
                                if player.isLoading && player.duration <= 0 {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: player.paused ? "play.fill" : "pause.fill")
                                }
                            }
                            .font(.title)
                            .frame(width: 40, height: 40)
                        }
                        .help(player.paused ? "Play" : "Pause")
                        Button { app.next() } label: { Image(systemName: "forward.fill") }.help("Next (Shift+N)")
                    }
                    .font(.title3)
                    // Right side.
                    HStack(spacing: 12) {
                        Text(player.timeText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button { player.toggleMute() } label: { Image(systemName: player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                        Slider(value: Binding(get: { player.volume }, set: { player.setVolume($0) }), in: 0...130)
                            .frame(width: 90)
                            .controlSize(.small)
                        if player.isMusicOwned {
                            Button { queue.cycleRepeat() } label: {
                                Image(systemName: queue.repeatMode == .one ? "repeat.1" : "repeat")
                                    .foregroundStyle(queue.repeatMode == .off ? Color.secondary : Color.accentColor)
                            }
                            .help("Repeat: \(queue.repeatMode.rawValue)")
                            Button { queue.setShuffle(!queue.shuffle) } label: {
                                Image(systemName: "shuffle").foregroundStyle(queue.shuffle ? Color.accentColor : Color.secondary)
                            }
                            .help("Shuffle")
                        }
                        Button { app.music.setImmersive(true) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .help("Immersive view (f)")
                        Button { app.music.toggleNow() } label: {
                            Image(systemName: app.music.nowVisible ? "chevron.down" : "chevron.up")
                        }
                        .help("Now playing")
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 16)
            }
            .frame(height: 72)
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
