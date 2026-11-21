import AppKit
import GTubeCore
import SwiftUI

/// Holds the one video view while this place is where the player shows.
struct VideoHost: NSViewRepresentable {
    let player: PlayerModel
    let active: Bool

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        let video = player.videoView
        if active {
            if video.superview !== v {
                video.removeFromSuperview()
                video.frame = v.bounds
                video.autoresizingMask = [.width, .height]
                v.addSubview(video)
            }
        } else if video.superview === v {
            video.removeFromSuperview()
        }
    }

    static func dismantleNSView(_ v: NSView, coordinator: ()) {
        for s in v.subviews { s.removeFromSuperview() }
    }
}

/// A place in a page that shows the player (the watch page's, Music's "Now
/// playing" video area, the immersive view).
struct PlayerDock: View {
    let dock: Dock
    var controls = true
    @State private var player = AppModel.shared.player

    var body: some View {
        ZStack {
            Color.black
            if player.slot == .dock(dock) {
                PlayerSurface(player: player, controls: controls ? .full : .none)
            }
        }
        .onAppear { player.setDock(dock, visible: true) }
        .onDisappear { player.setDock(dock, visible: false) }
    }
}

enum ControlsKind { case none, full, mini }

/// The video (or the audio-only cover) with its controls on top.
struct PlayerSurface: View {
    let player: PlayerModel
    var controls: ControlsKind

    var body: some View {
        ZStack {
            VideoHost(player: player, active: true)
            if !player.showsVideo, let v = player.current {
                AudioCover(item: v, music: player.isMusicOwned)
                    .contentShape(Rectangle())
                    .onTapGesture { player.togglePause() }
            }
            StatusOverlay(player: player)
            switch controls {
            case .full: FullControls(player: player)
            case .mini: MiniControls(player: player)
            case .none: EmptyView()
            }
        }
        .clipped()
        .onHover { if $0 { player.showControls() } }
    }
}

struct AudioCover: View {
    let item: VideoItem
    let music: Bool

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 8) {
                RemoteImage(url: music ? (item.thumbnail ?? item.thumbnailURL) : "https://i.ytimg.com/vi/\(item.id)/hqdefault.jpg", contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Label("Audio only", systemImage: "headphones")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.bottom, 12)
            }
        }
    }
}

/// Spinner, "Starting in N s", errors with Retry, SponsorBlock notices.
struct StatusOverlay: View {
    let player: PlayerModel

    var body: some View {
        ZStack {
            if player.loading && player.errorText == nil && player.waitLeft == nil {
                ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
            }
            if let left = player.waitLeft {
                VStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Text("Starting in \(left) s").font(.headline)
                        Text("YouTube delays the video by the length of the ad you're not seeing")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.bottom, 24)
                    .padding(.horizontal, 12)
                }
                .allowsHitTesting(false)
            }
            if let err = player.errorText {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40))
                    Text(err)
                        .multilineTextAlignment(.center)
                        .lineLimit(6)
                        .textSelection(.enabled)
                    Button("Retry") { player.reloadCurrent() }
                        .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
                .padding(24)
                .frame(maxWidth: 520)
            }
            if let n = player.notice {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "shield.lefthalf.filled")
                            Text(n)
                            Button("Undo") { player.undoSkip() }.buttonStyle(.borderless).fontWeight(.semibold)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.7), in: Capsule())
                        .padding(.trailing, 16)
                        .padding(.bottom, 80)
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: player.notice)
    }
}

/// The YouTube-style control bar along the bottom of the video.
struct FullControls: View {
    let player: PlayerModel
    @State private var app = AppModel.shared

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            VStack(spacing: 0) {
                if player.mode == .fullscreen || player.mode == .compact {
                    Text(player.current?.title ?? "")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
                        .opacity(player.controlsVisible ? 1 : 0)
                }
                Spacer(minLength: 0)
                if !(player.music && player.mode == .docked) {
                    bar(width: w)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                        .opacity(player.controlsVisible ? 1 : 0)
                        .onAppear { player.updateSubMargin(bar: 64, height: geo.size.height) }
                        .onChange(of: player.controlsVisible) { _, v in
                            player.updateSubMargin(bar: v ? 64 : 0, height: geo.size.height)
                        }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: player.controlsVisible)
        }
    }

    @ViewBuilder
    func bar(width w: Double) -> some View {
        VStack(spacing: 2) {
            SeekBar(player: player).padding(.horizontal, 12)
            HStack(spacing: 2) {
                if player.wantPrev && w >= 400 {
                    icon("backward.end.fill", "Previous (Shift+P)") { app.previous() }
                }
                icon(player.paused ? "play.fill" : "pause.fill", player.paused ? "Play (k)" : "Pause (k)") { player.togglePause() }
                if player.wantNext && w >= 300 {
                    icon("forward.end.fill", "Next (Shift+N)") { app.next() }
                }
                icon(volumeIcon, "Mute (m)") { player.toggleMute() }
                if w >= 500 {
                    Slider(value: Binding(get: { player.volume }, set: { player.setVolume($0) }), in: 0...130)
                        .frame(width: 90)
                        .controlSize(.small)
                }
                if w >= 280 {
                    Text(player.timeText)
                        .monospacedDigit()
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(.leading, 8)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if player.highlightVisible && w >= 600 {
                    Button("Jump to highlight") { player.jumpToHighlight() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color(hex: "#ff1684"))
                        .help(player.highlight.map { "Jump to \(Format.time($0))" } ?? "")
                }
                if w >= 620 { icon("shield.lefthalf.filled", "Mark a SponsorBlock segment (;)") { SponsorBlockMarker.mark() } }
                if w >= 420 { subtitlesMenu }
                if w >= 540 {
                    icon(player.isAudioOnly ? "headphones.circle.fill" : "headphones", "Audio only (a)") { player.setAudioOnly(!player.isAudioOnly) }
                }
                if w >= 580 { speedMenu }
                if w >= 680 { qualityMenu }
                if w >= 760 {
                    icon("arrow.down.circle", "Download") {
                        if let v = player.current { app.showDownload(v) }
                    }
                }
                if w >= 440 && player.mode != .compact {
                    icon("pip.enter", "Miniplayer (i)") { player.minimize() }
                }
                if w >= 360 {
                    icon(player.mode == .compact ? "arrow.up.left.and.arrow.down.right" : "rectangle.inset.bottomright.filled",
                         player.mode == .compact ? "Restore window (Esc)" : "Compact player (Ctrl+Shift+M)") { app.toggleCompact() }
                }
                if w >= 480 && player.onWatchPage {
                    icon(player.theater ? "rectangle.split.2x1" : "rectangle", player.theater ? "Default view (t)" : "Theater mode (t)") { player.toggleTheater() }
                }
                icon(player.mode == .fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", "Fullscreen (f)") {
                    player.toggleFullscreen()
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
        .foregroundStyle(.white)
    }

    var volumeIcon: String {
        if player.muted || player.volume <= 0 { return "speaker.slash.fill" }
        if player.volume < 34 { return "speaker.wave.1.fill" }
        if player.volume < 67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    func icon(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    var subtitlesMenu: some View {
        let c = player.captions
        let on = (player.subChoice ?? .off) != .off
        return Menu {
            Picker("Subtitles", selection: Binding(get: { (player.subChoice ?? .off).key }, set: { player.pickSubtitles($0) })) {
                Text("Off").tag("off")
                Divider()
                ForEach(Array(c.tracks.enumerated()), id: \.offset) { i, t in
                    Text(t.name).tag("t\(i)")
                }
            }
            .pickerStyle(.inline)
            if !c.tracks.isEmpty && !c.translations.isEmpty {
                Menu("Auto-translate") {
                    ForEach(player.suggestedTranslations, id: \.code) { t in
                        Button(t.name) { player.pickSubtitles("x:\(t.code)") }
                    }
                    Divider()
                    ForEach(c.translations, id: \.code) { t in
                        Button(t.name) { player.pickSubtitles("x:\(t.code)") }
                    }
                }
            }
        } label: {
            Image(systemName: on ? "captions.bubble.fill" : "captions.bubble")
                .font(.system(size: 15, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 30, height: 30)
        .disabled(c.tracks.isEmpty)
        .help(c.tracks.isEmpty ? "No subtitles" : "Subtitles (c)")
    }

    var speedMenu: some View {
        Menu {
            ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3], id: \.self) { s in
                Button {
                    player.setSpeed(s)
                } label: {
                    if abs(player.speed - s) < 0.01 { Label(s == 1 ? "Normal" : "\(fmt(s))×", systemImage: "checkmark") } else { Text(s == 1 ? "Normal" : "\(fmt(s))×") }
                }
            }
        } label: {
            Text("\(fmt(player.speed))×").font(.callout.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback speed")
    }

    var qualityMenu: some View {
        Menu {
            ForEach(player.heights, id: \.self) { h in
                Button {
                    player.setQuality(h)
                } label: {
                    if player.playingHeight == h { Label("\(h)p", systemImage: "checkmark") } else { Text("\(h)p") }
                }
            }
        } label: {
            Text("\(player.playingHeight ?? player.quality)p").font(.callout.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(player.heights.isEmpty)
        .help("Quality")
    }

    func fmt(_ s: Double) -> String {
        var t = String(format: "%g", s)
        if t.hasSuffix(".0") { t.removeLast(2) }
        return t
    }
}

/// The miniplayer's buttons: play / pause, back to the video, close.
struct MiniControls: View {
    let player: PlayerModel

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { player.expand() }
            Button { player.togglePause() } label: {
                Image(systemName: player.paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)
            VStack {
                HStack {
                    Button { player.expand() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").padding(6).background(.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Expand")
                    Spacer()
                    Button { player.stop() } label: {
                        Image(systemName: "xmark").padding(6).background(.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                }
                .padding(6)
                Spacer()
            }
            VStack {
                Spacer()
                GeometryReader { g in
                    Rectangle().fill(Color.red)
                        .frame(width: g.size.width * (player.duration > 0 ? min(max(player.position / player.duration, 0), 1) : 0))
                }
                .frame(height: 3)
            }
        }
        .foregroundStyle(.white)
        .opacity(player.controlsVisible ? 1 : 0.0001)
    }
}

/// The seek bar: what played, what is buffered, SponsorBlock segments and
/// highlights, a segment being marked, and the time under the pointer.
struct SeekBar: View {
    let player: PlayerModel
    var tint: Color = .red
    @State private var hover: Double?
    @State private var dragging: Double?
    @State private var lastSeek = Date.distantPast

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let dur = player.duration
            let frac: (Double) -> Double = { dur > 0 ? min(max($0 / dur, 0), 1) : 0 }
            let pos = dragging ?? player.position
            let tall = hover != nil || dragging != nil
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: tall ? 6 : 4)
                Capsule().fill(.white.opacity(0.4)).frame(width: w * frac(player.buffered), height: tall ? 6 : 4)
                ForEach(player.barSegments) { s in
                    if s.point {
                        Rectangle().fill(s.color).frame(width: 3, height: 10).offset(x: w * frac(s.start) - 1.5)
                    } else {
                        Rectangle().fill(s.color.opacity(0.85))
                            .frame(width: max(w * (frac(s.end) - frac(s.start)), 2), height: tall ? 6 : 4)
                            .offset(x: w * frac(s.start))
                    }
                }
                if let d = player.sbDraft {
                    let e = d.1 ?? pos
                    Rectangle().fill(Color.yellow.opacity(0.7))
                        .frame(width: max(w * abs(frac(e) - frac(d.0)), 2), height: 8)
                        .offset(x: w * min(frac(d.0), frac(e)))
                }
                Capsule().fill(tint).frame(width: w * frac(pos), height: tall ? 6 : 4)
                Circle().fill(tint).frame(width: tall ? 14 : 0, height: tall ? 14 : 0).offset(x: w * frac(pos) - (tall ? 7 : 0))
                if let h = hover, dur > 0 {
                    Text(label(at: h))
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .offset(x: min(max(w * frac(h) - 24, 0), w - 60), y: -22)
                }
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = dur > 0 ? Double(p.x / w) * dur : nil
                case .ended: hover = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard dur > 0 else { return }
                        let t = min(max(Double(g.location.x / w), 0), 1) * dur
                        dragging = t
                        hover = t
                        if Date().timeIntervalSince(lastSeek) > 0.08 {
                            lastSeek = Date()
                            player.seek(to: t, exact: false)
                        }
                    }
                    .onEnded { g in
                        guard dur > 0 else { return }
                        let t = min(max(Double(g.location.x / w), 0), 1) * dur
                        player.seek(to: t, exact: true)
                        dragging = nil
                    }
            )
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.12), value: hover != nil)
    }

    func label(at t: Double) -> String {
        let seg = player.barSegments.first { !$0.point && t >= $0.start && t < $0.end }
        return seg.map { "\(Format.time(t)) • \($0.label)" } ?? Format.time(t)
    }
}

/// The miniplayer / fullscreen / compact player above everything else.
struct PlayerOverlay: View {
    @State private var player = AppModel.shared.player

    var body: some View {
        GeometryReader { geo in
            switch player.mode {
            case .mini:
                let mw = min(max(geo.size.width * 0.3, 260), 420)
                let mh = mw * 9 / 16
                PlayerSurface(player: player, controls: .mini)
                    .frame(width: mw, height: mh)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                    .position(x: geo.size.width - mw / 2 - 16, y: geo.size.height - mh / 2 - 16)
            case .fullscreen, .compact:
                PlayerSurface(player: player, controls: .full)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .ignoresSafeArea()
            default:
                EmptyView()
            }
        }
    }
}
