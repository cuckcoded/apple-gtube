import GTubeCore
import SwiftUI

struct ChannelView: View {
    @State private var model: ChannelModel

    init(id: String) { _model = State(initialValue: ChannelModel(id)) }

    var body: some View {
        FeedView(feed: model.feed, layout: .grid, emptyIcon: "video", emptyTitle: "No videos", emptyText: "This channel has nothing to show here.") {
            header
        }
        .navigationTitle(model.page?.info.title.nonEmpty ?? "Channel")
        .environment(\.openURL, AppModel.shared.linkAction)
    }

    @ViewBuilder
    var header: some View {
        if let p = model.page {
            VStack(alignment: .leading, spacing: 16) {
                if let b = p.banner {
                    Color.clear.aspectRatio(6.2, contentMode: .fit)
                        .overlay(RemoteImage(url: b).clipped())
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                HStack(alignment: .top, spacing: 24) {
                    Avatar(url: p.info.avatar, name: p.info.title, size: 120)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(p.info.title).font(.largeTitle.weight(.bold))
                        let meta = [p.info.handle, p.info.subscribers, p.videoCount].compactMap { $0 }.joined(separator: " • ")
                        if !meta.isEmpty { Text(meta).foregroundStyle(.secondary) }
                        if let d = p.info.description, !d.isEmpty {
                            let ex = Linkify.excerpt(d, maxLines: 1, maxChars: 140)
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(model.descriptionExpanded || !ex.truncated ? Linkify.attributed(d) : Linkify.attributed(ex.0) + AttributedString("…"))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: 720, alignment: .leading)
                                if ex.truncated {
                                    Button(model.descriptionExpanded ? "less" : "more") { model.descriptionExpanded.toggle() }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                        Button(model.subscribed ? "Subscribed" : "Subscribe") { model.toggleSubscribe() }
                            .buttonStyle(.borderedProminent)
                            .tint(model.subscribed ? .gray : .red)
                            .controlSize(.large)
                    }
                }
                ChipsRow(titles: model.tabs.map(\.0), selected: model.tabs.firstIndex { $0.1 == model.selectedTab }) { i in
                    model.selectTab(model.tabs[i].1)
                }
            }
        } else {
            HStack { Spacer(); ProgressView(); Spacer() }.padding(40)
        }
    }
}

struct PlaylistView: View {
    @State private var model: PlaylistViewModel

    init(id: String) { _model = State(initialValue: PlaylistViewModel(id)) }

    var body: some View {
        Group {
            if model.page.editable {
                editableList
            } else {
                FeedView(feed: model.feed, layout: .list, emptyIcon: "list.bullet", emptyTitle: "This playlist is empty",
                         onActivate: { model.play(from: $0, shuffle: false) }) { header }
            }
        }
        .navigationTitle(model.page.title.nonEmpty ?? "Playlist")
        .environment(\.openURL, AppModel.shared.linkAction)
    }

    var header: some View {
        let p = model.page
        return HStack(alignment: .top, spacing: 24) {
            Thumbnail(url: model.thumbnail ?? "").frame(width: 320)
            VStack(alignment: .leading, spacing: 8) {
                Text(p.title).font(.largeTitle.weight(.bold))
                if let o = p.owner {
                    Text(o).font(.headline).onTapGesture { if let id = p.ownerId { AppModel.shared.openChannel(id) } }
                }
                if !p.stats.isEmpty { Text(p.stats.joined(separator: " • ")).foregroundStyle(.secondary) }
                if let d = p.description { Text(Linkify.attributed(d)).foregroundStyle(.secondary).lineLimit(3) }
                HStack(spacing: 8) {
                    Button("Play all") { if !model.feed.items.isEmpty { model.play(from: 0, shuffle: false) } }
                        .buttonStyle(.borderedProminent)
                    Button { if !model.feed.items.isEmpty { model.play(from: 0, shuffle: true) } } label: { Label("Shuffle", systemImage: "shuffle") }
                    Button("Download") {
                        var item = PlaylistItem(id: model.listId, title: p.title)
                        item.thumbnail = model.thumbnail
                        AppModel.shared.sheet = .downloadPlaylist(item)
                    }
                    if p.editable {
                        Button("Edit") { AppModel.shared.sheet = .editPlaylist(model) }
                    }
                }
                .controlSize(.large)
            }
        }
        .padding(.bottom, 8)
    }

    /// The user's own playlist: rows can be dragged to reorder them, moved or removed.
    var editableList: some View {
        List {
            header.listRowSeparator(.hidden)
            ForEach(Array(model.feed.items.enumerated()), id: \.element.id) { i, item in
                HStack {
                    Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                    ItemCard(item: item, layout: .list)
                        .onTapGesture { model.play(from: i, shuffle: false) }
                    Menu {
                        if i > 0 { Button("Move up") { model.move(from: i, to: i - 1) } }
                        Button("Move down") { model.move(from: i, to: i + 1) }
                        Divider()
                        Button("Remove from playlist") { model.remove(i) }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                }
                .onAppear { if i + 5 >= model.feed.items.count { model.feed.loadMore() } }
            }
            .onMove { from, to in
                guard let f = from.first else { return }
                model.move(from: f, to: to > f ? to - 1 : to)
            }
        }
        .listStyle(.plain)
    }
}

struct LibraryView: View {
    @State private var app = AppModel.shared
    var lib: LibraryModel { app.library }

    var body: some View {
        let feed = lib.feeds[lib.tab]!
        let tab = lib.tab
        let play: ((Int) -> Void)? = tab.isList ? { i in
            QueueLoader.playList(title: tab.title, listId: String(tab.browseId.dropFirst(2)), items: feed.items, index: i, more: feed.continuation, shuffle: false)
        } : nil
        FeedView(feed: feed, layout: tab.isList ? .list : .grid, emptyIcon: tab.icon, emptyTitle: "No \(tab.title.lowercased())", onActivate: play) {
            VStack(alignment: .leading, spacing: 16) {
                if let a = lib.account {
                    HStack(spacing: 20) {
                        Avatar(url: a.avatar, name: a.name, size: 72)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(a.name).font(.largeTitle.weight(.bold))
                            if let h = a.handle { Text(h).foregroundStyle(.secondary) }
                            if let c = a.channelId {
                                Button("View channel") { app.openChannel(c) }
                            }
                        }
                    }
                }
                Picker("", selection: Binding(get: { lib.tab }, set: { lib.show(tab: $0) })) {
                    ForEach(LibraryTab.allCases) { t in Label(t.title, systemImage: t.icon).tag(t) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .id(lib.tab)
        .navigationTitle("You")
    }
}

struct DownloadsView: View {
    @State private var dl = AppModel.shared.downloads

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if dl.tasks.isEmpty {
                    StatusBox(icon: "arrow.down.circle", title: "No downloads yet",
                              description: "Use the download button on a video or right-click any video, then choose Download.")
                }
                ForEach(dl.tasks) { t in DownloadRow(task: t) }
                Button("Open download folder") { dl.open(Config.settings.downloadDir) }
                    .controlSize(.large)
            }
            .frame(maxWidth: 900)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Downloads")
    }
}

struct DownloadRow: View {
    let task: DownloadTask

    var body: some View {
        let dl = AppModel.shared.downloads
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title).font(.headline).lineLimit(1)
                Text(task.kind).font(.caption).foregroundStyle(.secondary)
                ProgressView(value: task.progress)
                Text(task.status).font(.caption).foregroundStyle({ if case .failed = task.state { return Color.red } else { return Color.secondary } }())
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            if task.state == .running {
                Button { task.cancel() } label: { Image(systemName: "stop.circle") }.help("Cancel")
            } else {
                if task.state == .done, let p = task.path {
                    Button { dl.open(p) } label: { Image(systemName: "play.circle") }.help("Open file")
                }
                if task.state == .done {
                    Button { dl.reveal(task) } label: { Image(systemName: "folder") }.help("Show in Finder")
                }
                Button { dl.remove(task) } label: { Image(systemName: "xmark.circle") }.help("Remove from list")
            }
        }
        .buttonStyle(.borderless)
        .font(.title3)
        .padding(14)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct TrendingView: View {
    @State private var app = AppModel.shared

    var body: some View {
        FeedView(feed: app.trending, emptyIcon: "flame", emptyTitle: "Nothing here right now", emptyText: "Try another category.") {
            ChipsRow(titles: trendingCategories.map(\.0), selected: app.trendingIndex) { app.setTrending($0) }
        }
        .navigationTitle("Trending")
    }
}

struct SearchResultsView: View {
    @State private var app = AppModel.shared

    var body: some View {
        FeedView(feed: app.searchFeed, emptyIcon: "magnifyingglass", emptyTitle: "No results", emptyText: "Try different keywords or remove filters.") {
            ChipsRow(titles: searchFilters.map(\.0), selected: searchFilters.firstIndex { $0.1 == app.searchFilter } ?? 0) {
                app.setSearchFilter(searchFilters[$0].1)
            }
        }
        .navigationTitle("“\(app.searchQuery)”")
    }
}
