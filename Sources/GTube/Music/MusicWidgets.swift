import GTubeCore
import SwiftUI

/// Artwork of `size` points, cropped to the shape.
struct MusicArt: View {
    let url: String?
    var size: CGFloat
    var shape: GTubeCore.Shape = .square

    var body: some View {
        let px = Int(size * 2)
        let u = url.map { Music.imageURL($0, px) }
        let w = shape == .wide ? size * 16 / 9 : size
        RemoteImage(url: u)
            .frame(width: w, height: size)
            .clipShape(shape == .round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 6)))
    }
}

func explicitBadge() -> some View {
    Text("E")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 3)
        .background(Color.secondary.opacity(0.25), in: RoundedRectangle(cornerRadius: 2))
}

/// Text whose parts link to Music pages ("Artist • Album").
struct LinksText: View {
    let links: [MLink]
    var font: Font = .subheadline

    var body: some View {
        var a = AttributedString()
        for l in links {
            var p = AttributedString(l.text)
            if let id = l.id { p.link = URL(string: "gtube-music:\(id)") }
            a += p
        }
        return Text(a).font(font).foregroundStyle(.secondary).lineLimit(1).tint(.secondary)
    }
}

/// "Artist, Artist • Album • 1.2B plays"
func trackByline(_ t: Track, album: Bool = true, info: Bool = true) -> [MLink] {
    var out: [MLink] = []
    for (i, a) in t.artists.enumerated() {
        if i > 0 { out.append(MLink(text: ", ")) }
        out.append(a)
    }
    if album, let al = t.album {
        if !out.isEmpty { out.append(MLink(text: " • ")) }
        out.append(al)
    }
    if info, let i = t.info {
        if !out.isEmpty { out.append(MLink(text: " • ")) }
        out.append(MLink(text: i))
    }
    return out
}

@MainActor func musicTrackMenu(_ t: Track) -> some View {
    let m = AppModel.shared.music
    return Group {
        Button("Start radio") { m.play(t.radioTarget) }
        Divider()
        Button("Play next") { m.queue.addNext([t]) }
        Button("Add to queue") { m.queue.addLast([t]) }
        Divider()
        if let id = t.album?.id { Button("Go to album") { m.open(.browse(id)) } }
        if let id = t.firstArtistId { Button("Go to artist") { m.open(.browse(id)) } }
        Divider()
        Button("Download…") { AppModel.shared.sheet = .download(t.videoItem) }
        Button("Copy link") {
            copyToPasteboard(t.url)
            toast("Link copied")
        }
    }
}

@MainActor func musicCardMenu(_ c: Card) -> some View {
    let m = AppModel.shared.music
    var list: String?
    if case .watch(_, .some(let p), _, _) = c.play { list = p }
    let own: String? = { if case .browse(let id, _) = c.target { return id } else { return nil } }()
    let artist = c.subtitle.compactMap(\.id).first { $0.hasPrefix("UC") && $0 != own }
    return Group {
        if let p = c.play {
            Button("Play next") { m.queue.addTarget(p, next: true) }
            Button("Add to queue") { m.queue.addTarget(p, next: false) }
        }
        if let l = list, !l.hasPrefix("RD") {
            Button("Start radio") { m.play(.watch(videoId: nil, playlistId: "RDAMPL\(l)", params: "wAEB", index: nil)) }
        }
        Divider()
        if let a = artist { Button("Go to artist") { m.open(.browse(a)) } }
        if let t = c.target, let url = Music.shareURL(t) {
            Button("Copy link") {
                copyToPasteboard(url)
                toast("Link copied")
            }
        }
    }
}

@MainActor func activateEntry(_ e: Entry) {
    let m = AppModel.shared.music
    switch e {
    case .track(let t): m.play(t.playTarget)
    case .card(let c):
        if let t = c.target { m.open(t) } else if let p = c.play { m.play(p) }
    case .mood(let md): m.open(md.target)
    }
}

/// A song row: artwork (or track number), title, byline, length, menu.
struct TrackRow: View {
    let track: Track
    var showArt = true
    var current = false

    var body: some View {
        HStack(spacing: 12) {
            if let i = track.index, !showArt {
                Text(i).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 28)
            } else {
                MusicArt(url: track.thumbnail ?? track.thumbnailURL(96), size: 44, shape: track.kind == .video ? .wide : .square)
                    .frame(width: 44 * (track.kind == .video ? 16 / 9 : 1))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(track.title).font(.body.weight(current ? .bold : .medium)).lineLimit(1)
                    if track.explicit { explicitBadge() }
                }
                LinksText(links: trackByline(track))
            }
            Spacer(minLength: 8)
            if let d = track.duration { Text(d).font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
            Menu { musicTrackMenu(track) } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { AppModel.shared.music.play(track.playTarget) }
        .contextMenu { musicTrackMenu(track) }
    }
}

struct CardRow: View {
    let card: Card

    var body: some View {
        HStack(spacing: 12) {
            MusicArt(url: card.thumbnail, size: 52, shape: card.shape == .round ? .round : .square)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(card.title).font(.body.weight(.medium)).lineLimit(1)
                    if card.explicit { explicitBadge() }
                }
                LinksText(links: card.subtitle)
            }
            Spacer()
            if let p = card.play {
                Button { AppModel.shared.music.play(p) } label: { Image(systemName: "play.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { activateEntry(.card(card)) }
        .contextMenu { musicCardMenu(card) }
    }
}

/// An album / playlist / artist / video tile.
struct CardTile: View {
    let card: Card
    var size: CGFloat = 176
    @State private var hover = false

    var body: some View {
        let w = card.shape == .wide ? size * 16 / 9 : size
        VStack(alignment: card.shape == .round ? .center : .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                MusicArt(url: card.thumbnail, size: size, shape: card.shape)
                if let p = card.play, hover {
                    Button { AppModel.shared.music.play(p) } label: {
                        Image(systemName: "play.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.7), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                }
            }
            HStack(spacing: 4) {
                Text(card.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                if card.explicit { explicitBadge() }
            }
            LinksText(links: card.subtitle, font: .caption)
        }
        .frame(width: w, alignment: card.shape == .round ? .center : .leading)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { activateEntry(.card(card)) }
        .contextMenu { musicCardMenu(card) }
    }
}

/// A song as a tile (carousels of singles).
struct TrackTile: View {
    let track: Track
    var size: CGFloat = 176

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MusicArt(url: track.thumbnail ?? track.thumbnailURL(352), size: size, shape: track.kind == .video ? .wide : .square)
            Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            LinksText(links: trackByline(track, album: false), font: .caption)
        }
        .frame(width: track.kind == .video ? size * 16 / 9 : size, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { AppModel.shared.music.play(track.playTarget) }
        .contextMenu { musicTrackMenu(track) }
    }
}

struct MoodTile: View {
    let mood: Mood

    var body: some View {
        Button { AppModel.shared.music.open(mood.target) } label: {
            HStack(spacing: 0) {
                Rectangle().fill(mood.color.map { Color(argb: $0) } ?? .gray).frame(width: 6)
                Text(mood.title).font(.subheadline.weight(.semibold)).lineLimit(1).padding(.horizontal, 12)
                Spacer(minLength: 0)
            }
            .frame(width: 180, height: 48)
            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

struct EntryTile: View {
    let entry: Entry
    var body: some View {
        switch entry {
        case .track(let t): TrackTile(track: t)
        case .card(let c): CardTile(card: c)
        case .mood(let m): MoodTile(mood: m)
        }
    }
}

struct EntryRow: View {
    let entry: Entry
    var showArt = true
    var body: some View {
        switch entry {
        case .track(let t): TrackRow(track: t, showArt: showArt)
        case .card(let c): CardRow(card: c)
        case .mood(let m): MoodTile(mood: m)
        }
    }
}

/// A shelf: a title (maybe linking to more) and its entries as rows, a
/// carousel or a grid.
struct ShelfView: View {
    let shelf: Shelf
    /// Album pages number their tracks instead of showing the art.
    var numbered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if shelf.title != nil || shelf.more != nil {
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let s = shelf.strapline { Text(s.uppercased()).font(.caption).foregroundStyle(.secondary) }
                        if let t = shelf.title {
                            Text(t).font(.title2.weight(.bold))
                                .onTapGesture { if let tt = shelf.titleTarget { AppModel.shared.music.open(tt) } }
                        }
                    }
                    Spacer()
                    if let more = shelf.more {
                        Button(more.0) { AppModel.shared.music.open(more.1) }.buttonStyle(.bordered)
                    }
                }
            }
            switch shelf.style {
            case .text:
                Text(shelf.text ?? "").fixedSize(horizontal: false, vertical: true)
                if let f = shelf.footer { Text(f).font(.caption).foregroundStyle(.secondary) }
            case .carousel:
                ScrollView(.horizontal, showsIndicators: false) {
                    if shelf.entries.count > 4 && shelf.entries.allSatisfy(isListTrack) {
                        // Quick picks: columns of four rows.
                        LazyHGrid(rows: Array(repeating: GridItem(.fixed(56), spacing: 4), count: 4), spacing: 24) {
                            ForEach(Array(shelf.entries.enumerated()), id: \.offset) { _, e in
                                EntryRow(entry: e).frame(width: 360)
                            }
                        }
                    } else if shelf.entries.allSatisfy({ if case .mood = $0 { return true } else { return false } }) {
                        LazyHGrid(rows: Array(repeating: GridItem(.fixed(48), spacing: 8), count: 4), spacing: 12) {
                            ForEach(Array(shelf.entries.enumerated()), id: \.offset) { _, e in EntryTile(entry: e) }
                        }
                    } else {
                        LazyHStack(alignment: .top, spacing: 18) {
                            ForEach(Array(shelf.entries.enumerated()), id: \.offset) { _, e in EntryTile(entry: e) }
                        }
                    }
                }
            case .grid:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 176, maximum: 240), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                    ForEach(Array(shelf.entries.enumerated()), id: \.offset) { _, e in EntryTile(entry: e) }
                }
            case .list:
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(shelf.entries.enumerated()), id: \.offset) { _, e in
                        EntryRow(entry: e, showArt: !numbered)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    func isListTrack(_ e: Entry) -> Bool {
        if case .track = e { return true }
        return false
    }
}

/// The large "top result" card of a search.
struct TopResultView: View {
    let top: TopResult

    var body: some View {
        let m = AppModel.shared.music
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                MusicArt(url: top.card.thumbnail, size: 120, shape: top.card.shape)
                Text(top.card.title).font(.title.weight(.bold)).lineLimit(2)
                LinksText(links: top.card.subtitle)
                HStack {
                    if let p = top.card.play { Button { m.play(p) } label: { Label("Play", systemImage: "play.fill") }.buttonStyle(.borderedProminent) }
                    if let s = top.shuffle { Button { m.play(s) } label: { Label("Shuffle", systemImage: "shuffle") } }
                    if let r = top.radio { Button { m.play(r) } label: { Label("Radio", systemImage: "dot.radiowaves.left.and.right") } }
                }
            }
            .frame(width: 320, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if let t = top.card.target { m.open(t) } }
            if !top.tracks.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(top.tracks) { t in TrackRow(track: t) }
                }
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// An artist's or a collection's header.
struct MusicHeaderView: View {
    let header: MHeader
    let page: MusicPageModel

    var body: some View {
        let m = AppModel.shared.music
        switch header.kind {
        case .artist:
            ZStack(alignment: .bottomLeading) {
                if let t = header.thumbnail {
                    RemoteImage(url: Music.imageURL(t, 1440))
                        .frame(height: 320)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .overlay(LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor)], startPoint: .center, endPoint: .bottom))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(header.title).font(.system(size: 44, weight: .bold))
                    if let mo = header.monthly { Text(mo).foregroundStyle(.secondary) }
                    if let d = header.description {
                        Text(d.components(separatedBy: "\n").first ?? d).lineLimit(3).foregroundStyle(.secondary).frame(maxWidth: 720, alignment: .leading).help(d)
                    }
                    HStack {
                        if let pl = header.play { Button { m.play(pl.1) } label: { Label(pl.0.isEmpty ? "Shuffle" : pl.0, systemImage: "shuffle") }.buttonStyle(.borderedProminent) }
                        if let r = header.radio { Button { m.play(r.1) } label: { Label(r.0.isEmpty ? "Radio" : r.0, systemImage: "dot.radiowaves.left.and.right") } }
                        if let c = header.channelId { SubscribeButton(channelId: c, subscribed: header.subscribed ?? false, subscribers: header.subscribers, page: page) }
                    }
                    .controlSize(.large)
                }
                .padding(.bottom, 8)
            }
        case .collection, .simple:
            HStack(alignment: .bottom, spacing: 24) {
                MusicArt(url: header.thumbnail, size: 220)
                VStack(alignment: .leading, spacing: 8) {
                    Text(header.title).font(.system(size: 34, weight: .bold)).lineLimit(3)
                    if !header.owner.isEmpty { LinksText(links: header.owner, font: .headline) }
                    if let s = header.subtitle { Text(s).foregroundStyle(.secondary) }
                    if let s = header.secondSubtitle { Text(s).foregroundStyle(.secondary) }
                    if let d = header.description { Text(d).lineLimit(3).foregroundStyle(.secondary).help(d) }
                    HStack {
                        if let pl = header.play { Button { m.play(pl.1) } label: { Label("Play", systemImage: "play.fill") }.buttonStyle(.borderedProminent) }
                        if let s = header.shuffle { Button { m.play(s) } label: { Label("Shuffle", systemImage: "shuffle") } }
                        if let r = header.radio { Button { m.play(r.1) } label: { Label(r.0, systemImage: "dot.radiowaves.left.and.right") } }
                        if let pid = header.playlistId, let saved = header.saved {
                            SaveToLibraryButton(playlistId: pid, saved: saved, page: page)
                        }
                    }
                    .controlSize(.large)
                }
            }
        }
    }
}

struct SubscribeButton: View {
    let channelId: String
    let subscribed: Bool
    let subscribers: String?
    let page: MusicPageModel

    var body: some View {
        Button {
            guard Client.shared.isLoggedIn else {
                AppModel.shared.sheet = .signIn
                return
            }
            let on = !subscribed
            page.setSubscribed(on)
            Task {
                do { try await Client.shared.subscribe(channelId, on) } catch {
                    toast("Could not update subscription: \(error.localizedDescription)")
                    page.setSubscribed(!on)
                }
            }
        } label: {
            Text(subscribed ? "Subscribed" : "Subscribe") + Text(subscribers.map { " \($0)" } ?? "").foregroundStyle(.secondary)
        }
    }
}

struct SaveToLibraryButton: View {
    let playlistId: String
    let saved: Bool
    let page: MusicPageModel

    var body: some View {
        Button {
            guard Client.shared.isLoggedIn else {
                AppModel.shared.sheet = .signIn
                return
            }
            let on = !saved
            page.setSaved(on)
            Task {
                do {
                    try await Client.shared.musicSavePlaylist(playlistId, save: on)
                    toast(on ? "Saved to your library" : "Removed from your library")
                } catch {
                    toast("Couldn't change your library: \(error.localizedDescription)")
                    page.setSaved(!on)
                }
            }
        } label: {
            Label(saved ? "Saved" : "Save", systemImage: saved ? "checkmark" : "plus")
        }
    }
}
