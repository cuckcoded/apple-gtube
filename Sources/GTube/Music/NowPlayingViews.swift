import GTubeCore
import SwiftUI

/// "Now playing": the artwork or the music video (Song / Video switch) next to
/// the Up next, Lyrics and Related tabs.
struct NowPlayingView: View {
    @State private var app = AppModel.shared
    var music: MusicModel { app.music }
    var player: PlayerModel { app.player }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 900
            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 32)) : AnyLayout(VStackLayout(spacing: 20))
            layout {
                VStack(spacing: 14) {
                    Picker("", selection: Binding(get: { player.musicVideo }, set: { music.setVideo($0) })) {
                        Text("Song").tag(false)
                        Text("Video").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                    artwork
                        .frame(maxWidth: wide ? geo.size.width * 0.55 : .infinity, maxHeight: wide ? geo.size.height - 80 : geo.size.height * 0.45)
                }
                .frame(maxWidth: wide ? geo.size.width * 0.58 : .infinity)
                VStack(spacing: 10) {
                    Picker("", selection: Binding(get: { music.nowTab }, set: { music.setNowTab($0) })) {
                        ForEach(NowTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    switch music.nowTab {
                    case .upNext: QueueList()
                    case .lyrics: LyricsView(big: false)
                    case .related:
                        if let r = music.related {
                            MusicPageView(model: r)
                        } else if !music.queue.info.ready {
                            ProgressView().frame(maxHeight: .infinity)
                        } else {
                            StatusBox(icon: "music.note", title: "Nothing related").frame(maxHeight: .infinity)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(24)
        }
        .navigationTitle("Now playing")
    }

    @ViewBuilder
    var artwork: some View {
        if player.musicVideo && player.isMusicOwned {
            PlayerDock(dock: .nowPlaying, controls: false)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            let url = music.queue.current.map { $0.thumbnailURL(1080) } ?? player.current?.thumbnailURL
            RemoteImage(url: url, contentMode: .fit)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 20)
        }
    }
}

/// The play queue as a list; the current track is highlighted and kept in view.
struct QueueList: View {
    @State private var app = AppModel.shared
    var queue: MusicQueue { app.music.queue }
    var big = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let t = queue.title { Text("Playing from \(t)").font(.caption).foregroundStyle(.secondary) }
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(queue.tracks.enumerated()), id: \.offset) { i, t in
                        HStack {
                            TrackRow(track: t, current: i == queue.index)
                                .onTapGesture { queue.playIndex(i) }
                            Menu {
                                if i != queue.index {
                                    Button("Play next") { queue.moveNext(i) }
                                    Button("Remove from queue") { queue.remove(i) }
                                }
                                if i > 0 { Button("Move up") { queue.move(from: i, to: i - 1) } }
                                if i + 1 < queue.tracks.count { Button("Move down") { queue.move(from: i, to: i + 1) } }
                            } label: { Image(systemName: "line.3.horizontal") }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                        }
                        .id(i)
                        .listRowBackground(i == queue.index ? Color.accentColor.opacity(0.15) : Color.clear)
                    }
                    .onMove { from, to in
                        guard let f = from.first else { return }
                        queue.move(from: f, to: to > f ? to - 1 : to)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onAppear { if let i = queue.index { proxy.scrollTo(i, anchor: .top) } }
                .onChange(of: queue.currentChanged) { _, _ in
                    if let i = queue.index { withAnimation { proxy.scrollTo(i, anchor: .top) } }
                }
            }
            if queue.loading { ProgressView().frame(maxWidth: .infinity) }
        }
    }
}

/// Lyrics. Timed lyrics light up the line being sung and keep it in view
/// (scrolling by hand pauses that for a moment); clicking a line plays from there.
struct LyricsView: View {
    var big: Bool
    @State private var app = AppModel.shared
    @State private var holdUntil = Date.distantPast
    /// Lines show this much early, as the words are about to be sung.
    let lead = 0.2

    var body: some View {
        switch app.music.lyrics {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            StatusBox(icon: "text.quote", title: "No lyrics", description: app.player.isMusicOwned ? "There are no lyrics for this song." : "Play something from YouTube Music to see its lyrics.")
                .frame(maxHeight: .infinity)
        case .ready(let l):
            if l.instrumental {
                StatusBox(icon: "music.note", title: "Instrumental").frame(maxHeight: .infinity)
            } else if l.isTimed {
                timed(l)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(l.text).font(big ? .title.weight(.semibold) : .title3).textSelection(.enabled)
                        if let s = l.source { Text(s).font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            }
        }
    }

    func timed(_ l: Lyrics) -> some View {
        let current = l.lineAt(app.player.position + lead)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: big ? 22 : 14) {
                    ForEach(Array(l.lines.enumerated()), id: \.offset) { i, line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(big ? .system(size: 34, weight: .bold) : .title2.weight(.bold))
                            .foregroundStyle(i == current ? Color.primary : (current.map { i < $0 } ?? false) ? Color.secondary.opacity(0.7) : Color.secondary)
                            .scaleEffect(i == current ? 1.0 : 0.97, anchor: .leading)
                            .animation(.easeOut(duration: 0.25), value: current)
                            .id(i)
                            .contentShape(Rectangle())
                            .onTapGesture { app.player.seek(to: line.start) }
                    }
                    if let s = l.source { Text(s).font(.caption).foregroundStyle(.secondary).padding(.top, 20) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 120)
                .padding(.horizontal)
            }
            .simultaneousGesture(DragGesture().onChanged { _ in holdUntil = Date().addingTimeInterval(4) })
            .onScrollWheel { holdUntil = Date().addingTimeInterval(4) }
            .onChange(of: current) { _, c in
                guard let c, Date() > holdUntil else { return }
                withAnimation(.easeOut(duration: 0.45)) { proxy.scrollTo(c, anchor: UnitPoint(x: 0, y: 0.38)) }
            }
            .onAppear { if let c = current { proxy.scrollTo(c, anchor: UnitPoint(x: 0, y: 0.38)) } }
        }
    }
}

extension View {
    /// Notices scrolling with the mouse wheel or trackpad over this view.
    func onScrollWheel(_ f: @escaping () -> Void) -> some View {
        background(ScrollWheelWatcher(onScroll: f))
    }
}

struct ScrollWheelWatcher: NSViewRepresentable {
    let onScroll: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = WheelView()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ v: NSView, context: Context) { (v as? WheelView)?.onScroll = onScroll }

    final class WheelView: NSView {
        var onScroll: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self, let w = self.window, e.window === w else { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                if self.bounds.contains(p) { self.onScroll?() }
                return e
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Immersive view: the track across the whole screen. Big artwork (or the
/// music video) over a blurred wash of the art, a large visualizer, and
/// controls that fade away while it plays. Beside the artwork, the lyrics or
/// the queue.
struct ImmersiveView: View {
    @State private var app = AppModel.shared
    @State private var chrome = true
    @State private var hideTask: Task<Void, Never>?
    var music: MusicModel { app.music }
    var player: PlayerModel { app.player }

    var body: some View {
        let track = music.queue.current
        let art = track.map { $0.thumbnailURL(1080) } ?? player.current?.thumbnailURL
        GeometryReader { geo in
            ZStack {
                Color.black
                RemoteImage(url: art)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .blur(radius: 80)
                    .opacity(0.65)
                    .clipped()
                (music.ambient ?? .black).opacity(0.25)
                VStack {
                    Spacer()
                    SpectrumView(color: .white, heightFactor: 0.9).frame(height: geo.size.height * 0.35).opacity(0.8)
                }
                HStack(spacing: 48) {
                    VStack(spacing: 18) {
                        Group {
                            if player.musicVideo && player.isMusicOwned {
                                PlayerDock(dock: .immersive, controls: false)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                            } else {
                                RemoteImage(url: art, contentMode: .fit).aspectRatio(1, contentMode: .fit)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(radius: 30)
                        .frame(maxWidth: music.immersivePanel.isEmpty ? geo.size.width * 0.7 : geo.size.width * 0.45,
                               maxHeight: geo.size.height * 0.62)
                        VStack(spacing: 4) {
                            Text(track?.title ?? player.current?.title ?? "").font(.system(size: 30, weight: .bold)).lineLimit(2)
                            Text(track?.artistNames ?? player.current?.channelName ?? "").font(.title3).opacity(0.8)
                        }
                        .multilineTextAlignment(.center)
                        controls.opacity(chrome ? 1 : 0)
                        if let next = music.queue.index.flatMap({ i in i + 1 < music.queue.tracks.count ? music.queue.tracks[i + 1] : nil }) {
                            Text("Up next: \(next.title) — \(next.artistNames)").font(.callout).opacity(0.7).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    if !music.immersivePanel.isEmpty {
                        Group {
                            if music.immersivePanel == "lyrics" { LyricsView(big: true) } else { QueueList(big: true) }
                        }
                        .frame(width: geo.size.width * 0.38)
                    }
                }
                .padding(48)
                .foregroundStyle(.white)
                .environment(\.colorScheme, .dark)
                VStack {
                    HStack {
                        Button { music.setImmersive(false) } label: { Image(systemName: "xmark").font(.title2) }
                            .help("Leave (Esc)")
                        Spacer()
                        Toggle(isOn: Binding(get: { music.immersivePanel == "lyrics" }, set: { _ in music.setImmersivePanel("lyrics") })) {
                            Image(systemName: "text.quote")
                        }
                        .toggleStyle(.button)
                        .help("Lyrics")
                        Toggle(isOn: Binding(get: { music.immersivePanel == "queue" }, set: { _ in music.setImmersivePanel("queue") })) {
                            Image(systemName: "list.bullet")
                        }
                        .toggleStyle(.button)
                        .help("Up next")
                    }
                    .buttonStyle(.borderless)
                    .padding(20)
                    .opacity(chrome ? 1 : 0)
                    Spacer()
                }
                .foregroundStyle(.white)
            }
            .onContinuousHover { _ in showChrome() }
            .onAppear { showChrome() }
            .animation(.easeInOut(duration: 0.4), value: chrome)
        }
    }

    var controls: some View {
        VStack(spacing: 10) {
            SeekBar(player: player, tint: .white).frame(maxWidth: 520)
            HStack(spacing: 30) {
                Button { music.queue.setShuffle(!music.queue.shuffle) } label: { Image(systemName: "shuffle").opacity(music.queue.shuffle ? 1 : 0.5) }
                Button { app.previous() } label: { Image(systemName: "backward.fill") }
                Button { player.togglePause() } label: { Image(systemName: player.paused ? "play.circle.fill" : "pause.circle.fill").font(.system(size: 52)) }
                Button { app.next() } label: { Image(systemName: "forward.fill") }
                Button { music.queue.cycleRepeat() } label: {
                    Image(systemName: music.queue.repeatMode == .one ? "repeat.1" : "repeat").opacity(music.queue.repeatMode == .off ? 0.5 : 1)
                }
            }
            .font(.title)
            .buttonStyle(.borderless)
        }
    }

    /// Shows the controls, and hides them again after a while of playing.
    func showChrome() {
        chrome = true
        NSCursor.setHiddenUntilMouseMoves(false)
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            while true {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                if player.paused { continue }
                chrome = false
                NSCursor.setHiddenUntilMouseMoves(true)
                return
            }
        }
    }
}
