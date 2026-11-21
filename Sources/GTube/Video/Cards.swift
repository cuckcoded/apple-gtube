import GTubeCore
import SwiftUI

enum CardLayout { case grid, list }

struct Thumbnail: View {
    let url: String
    var badge: String?
    var live = false
    var progress: Double?
    var stacked = false

    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(RemoteImage(url: url).clipped())
            .overlay(alignment: .bottomTrailing) {
                if let b = badge, !b.isEmpty {
                    HStack(spacing: 3) {
                        if stacked { Image(systemName: "list.bullet") }
                        Text(b)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(live ? Color.red : Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
                }
            }
            .overlay(alignment: .bottom) {
                if let p = progress, p > 0 {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.gray.opacity(0.6))
                            Rectangle().fill(Color.red).frame(width: g.size.width * min(p, 1))
                        }
                    }
                    .frame(height: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// A video, channel or playlist in a feed.
struct ItemCard: View {
    let item: Item
    var layout: CardLayout = .grid

    var body: some View {
        Group {
            switch item {
            case .video(let v): VideoCard(video: v, layout: layout)
            case .channel(let c): ChannelCard(channel: c, layout: layout)
            case .playlist(let p): PlaylistCard(playlist: p, layout: layout)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { ItemMenu(item: item) }
    }
}

struct VideoCard: View {
    let video: VideoItem
    var layout: CardLayout = .grid

    var progress: Double? { video.progress ?? WatchPositions.progress(video.id) }

    var body: some View {
        if layout == .grid {
            VStack(alignment: .leading, spacing: 8) {
                Thumbnail(url: video.thumbnailURL, badge: video.duration, live: video.isLive, progress: progress)
                HStack(alignment: .top, spacing: 10) {
                    if video.channelAvatar != nil {
                        Avatar(url: video.channelAvatar, name: video.channelName, size: 36)
                            .onTapGesture { if let c = video.channelId { AppModel.shared.openChannel(c) } }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(video.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                        if let c = video.channelName {
                            Text(c).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                .onTapGesture { if let id = video.channelId { AppModel.shared.openChannel(id) } }
                        }
                        if !video.metaLine.isEmpty {
                            Text(video.metaLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                Thumbnail(url: video.thumbnailURL, badge: video.duration, live: video.isLive, progress: progress)
                    .frame(width: 168)
                VStack(alignment: .leading, spacing: 3) {
                    Text(video.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    if let c = video.channelName { Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    if !video.metaLine.isEmpty { Text(video.metaLine).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct ChannelCard: View {
    let channel: ChannelItem
    var layout: CardLayout = .grid

    var body: some View {
        let lines = [channel.handle, channel.subscribers].compactMap { $0 }.joined(separator: " • ")
        if layout == .grid {
            VStack(spacing: 8) {
                Avatar(url: channel.avatar, name: channel.title, size: 120)
                Text(channel.title).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                if !lines.isEmpty { Text(lines).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if let d = channel.description { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } else {
            HStack(spacing: 12) {
                Avatar(url: channel.avatar, name: channel.title, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.title).font(.headline)
                    if !lines.isEmpty { Text(lines).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
            }
        }
    }
}

struct PlaylistCard: View {
    let playlist: PlaylistItem
    var layout: CardLayout = .grid

    var body: some View {
        let thumb = playlist.thumbnail ?? playlist.videoId.map { "https://i.ytimg.com/vi/\($0)/hqdefault.jpg" } ?? ""
        let sub = playlist.isMix ? "Mix • endless" : "Playlist"
        let content = VStack(alignment: .leading, spacing: 3) {
            Text(playlist.title).font(layout == .grid ? .headline : .subheadline.weight(.semibold)).lineLimit(2)
            Text(sub).font(.caption).foregroundStyle(.secondary)
            if let c = playlist.channelName { Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        if layout == .grid {
            VStack(alignment: .leading, spacing: 8) {
                Thumbnail(url: thumb, badge: playlist.videoCount ?? (playlist.isMix ? "Mix" : nil), stacked: true)
                content
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                Thumbnail(url: thumb, badge: playlist.videoCount, stacked: true).frame(width: 168)
                content
                Spacer(minLength: 0)
            }
        }
    }
}

/// The right-click menu with the usual per-item actions.
struct ItemMenu: View {
    let item: Item

    var body: some View {
        let app = AppModel.shared
        Button("Open") { app.activate(item) }
        switch item {
        case .video(let v) where !v.isShort:
            Divider()
            Button("Play next") { app.watch.enqueue(v, next: true) }
            Button("Add to queue") { app.watch.enqueue(v, next: false) }
            Button("Start mix") { QueueLoader.openMix(video: v.id, list: "RD\(v.id)", start: 0) }
            Divider()
            Button("Play as audio only") {
                app.player.setAudioOnly(true)
                app.openVideo(v)
            }
            Button("Download…") { app.sheet = .download(v) }
            if app.loggedIn {
                Button("Save to playlist…") { app.sheet = .saveToPlaylist(v.id) }
            }
            if let c = v.channelId {
                Button("Go to channel") { app.openChannel(c) }
            }
        case .video(let v):
            Button("Download…") { app.sheet = .download(v) }
        case .playlist(let p) where p.isMix:
            EmptyView()
        case .playlist(let p):
            Button("Shuffle play") { QueueLoader.openPlaylist(video: nil, list: p.id, start: 0, shuffle: true) }
            Button("Play all") { QueueLoader.openPlaylist(video: nil, list: p.id, start: 0, shuffle: false) }
            Button("Download playlist") { app.sheet = .downloadPlaylist(p) }
        case .channel:
            EmptyView()
        }
        Divider()
        Button("Copy link") {
            copyToPasteboard(item.url)
            toast("Link copied")
        }
        Button("Open in browser") { openInBrowser(item.url) }
    }
}

/// A centered icon + title + description block for empty and error states.
struct StatusBox: View {
    let icon: String
    let title: String
    var description = ""
    var buttonTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 64)).foregroundStyle(.secondary)
            Text(title).font(.title.weight(.semibold)).multilineTextAlignment(.center)
            if !description.isEmpty {
                Text(description).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
            }
            if let b = buttonTitle, let action {
                Button(b, action: action).buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity)
    }
}

/// Filter chips ("All", "Music", "Gaming"…).
struct ChipsRow: View {
    let titles: [String]
    let selected: Int?
    let select: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(titles.enumerated()), id: \.offset) { i, t in
                    Button(t) { select(i) }
                        .buttonStyle(ChipStyle(selected: i == selected))
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

struct ChipStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color(nsColor: .windowBackgroundColor) : Color.primary)
            .background(selected ? Color.primary : Color.secondary.opacity(configuration.isPressed ? 0.3 : 0.15), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }
}
