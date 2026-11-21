import GTubeCore
import SwiftUI

/// The watch page: the player, the video's info, likes/dislikes, description,
/// comments and related videos (and the queue, when playing a list).
struct WatchView: View {
    @State private var app = AppModel.shared
    var watch: WatchModel { app.watch }
    var player: PlayerModel { app.player }

    var body: some View {
        GeometryReader { geo in
            let stacked = geo.size.width < 1000
            let side: CGFloat = geo.size.width >= 1900 ? 440 : 400
            // As wide as the window allows while the player still fits on
            // screen with the title below it.
            let maxPlayerW = (geo.size.height - 166) * 16 / 9
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id("top")
                        if player.theater {
                            PlayerDock(dock: .watch)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: max(geo.size.height - 136, 200))
                                .background(Color.black)
                        }
                        if stacked {
                            VStack(alignment: .leading, spacing: 16) {
                                main(maxPlayerWidth: .infinity)
                                sideColumn
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 16)
                        } else {
                            HStack(alignment: .top, spacing: 24) {
                                main(maxPlayerWidth: max(maxPlayerW, 480))
                                    .frame(maxWidth: .infinity, alignment: .top)
                                sideColumn.frame(width: side)
                            }
                            .padding(.horizontal, 24)
                            .padding(.top, 16)
                        }
                    }
                    .padding(.bottom, 32)
                }
                .onChange(of: watch.openCount) { _, _ in proxy.scrollTo("top", anchor: .top) }
            }
        }
        .navigationTitle(watch.video?.title.nonEmpty ?? "Watch")
        .onAppear { watch.pageShown() }
        .environment(\.openURL, app.linkAction)
    }

    @ViewBuilder
    func main(maxPlayerWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !player.theater {
                PlayerDock(dock: .watch)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: maxPlayerWidth)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity)
            }
            Text(watch.details?.title.nonEmpty ?? watch.video?.title ?? "")
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            infoRow
            description
            CommentsView(comments: watch.comments)
        }
    }

    var infoRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { owner; Spacer(minLength: 8); actions }
            VStack(alignment: .leading, spacing: 10) { owner; actions }
        }
    }

    var owner: some View {
        let d = watch.details
        let name = d?.channel.title ?? watch.video?.channelName ?? ""
        return HStack(spacing: 12) {
            Button {
                if let id = d?.channel.id.nonEmpty ?? watch.video?.channelId { app.openChannel(id) }
            } label: {
                HStack(spacing: 12) {
                    Avatar(url: d?.channel.avatar ?? watch.video?.channelAvatar, name: name, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.headline).lineLimit(1)
                        if let s = d?.channel.subscribers { Text(s).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .buttonStyle(.plain)
            if let d, !d.channel.id.isEmpty {
                Button(watch.subscribed ? "Subscribed" : "Subscribe") { watch.toggleSubscribe() }
                    .buttonStyle(.borderedProminent)
                    .tint(watch.subscribed ? .gray : .red)
                    .controlSize(.large)
            }
        }
    }

    var actions: some View {
        HStack(spacing: 8) {
            VStack(spacing: 4) {
                HStack(spacing: 0) {
                    Button { watch.rate(like: true) } label: {
                        Label(watch.likesText, systemImage: watch.likeStatus == "LIKE" ? "hand.thumbsup.fill" : "hand.thumbsup")
                    }
                    .help("I like this")
                    Divider().frame(height: 18)
                    Button { watch.rate(like: false) } label: {
                        Label(watch.dislikesText, systemImage: watch.likeStatus == "DISLIKE" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    }
                    .help("Dislikes are estimated by Return YouTube Dislike")
                }
                .buttonStyle(.bordered)
                if let r = watch.ratio {
                    ProgressView(value: r)
                        .tint(.primary)
                        .frame(width: 140)
                        .help(String(format: "%.1f%% liked (Return YouTube Dislike)", r * 100))
                }
            }
            roundButton(player.isAudioOnly ? "headphones.circle.fill" : "headphones", "Toggle audio only") { player.setAudioOnly(!player.isAudioOnly) }
            roundButton("pip.enter", "Miniplayer") { player.minimize() }
            roundButton("bookmark", "Save to playlist") {
                if let v = watch.video {
                    if app.loggedIn { app.sheet = .saveToPlaylist(v.id) } else { app.sheet = .signIn }
                }
            }
            roundButton("arrow.down.circle", "Download") { if let v = watch.video { app.sheet = .download(v) } }
            Menu {
                Button("Copy link") {
                    if let v = watch.video {
                        copyToPasteboard(v.url)
                        toast("Link copied")
                    }
                }
                Button("Copy link at current time") {
                    if let v = watch.video {
                        copyToPasteboard("https://youtu.be/\(v.id)?t=\(Int(player.position))")
                        toast("Link copied")
                    }
                }
                Button("Open in browser") { if let v = watch.video { openInBrowser(v.url) } }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            .help("Share")
        }
    }

    func roundButton(_ icon: String, _ help: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) { Image(systemName: icon).frame(width: 18, height: 18) }
            .buttonStyle(.bordered)
            .clipShape(Circle())
            .help(help)
    }

    @ViewBuilder
    var description: some View {
        let d = watch.details
        VStack(alignment: .leading, spacing: 8) {
            let meta = d.map { [$0.views, $0.date].compactMap { $0 }.joined(separator: " • ") } ?? (watch.video?.metaLine ?? "")
            if !meta.isEmpty { Text(meta).font(.headline) }
            if let sb = watch.sbInfo { Text(sb).font(.caption).foregroundStyle(.secondary) }
            if let d {
                let full = d.description
                let ex = Linkify.excerpt(full, maxLines: 4, maxChars: 280)
                let cut = ex.0
                let truncated = ex.truncated
                if watch.descriptionExpanded || !truncated {
                    Text(Linkify.attributed(full, links: d.descriptionLinks))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    let n = (cut as NSString).length
                    Text(Linkify.attributed(cut, links: d.descriptionLinks.filter { $0.start + $0.length <= n }) + AttributedString("…"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if truncated {
                    Button(watch.descriptionExpanded ? "Show less" : "Show more") { watch.descriptionExpanded.toggle() }
                        .buttonStyle(.borderless)
                        .fontWeight(.semibold)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    var sideColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            if watch.queue.isActive { QueuePanelView(panel: watch.queue) }
            HStack {
                Text("Up next").font(.headline)
                Spacer()
                Text("Autoplay").foregroundStyle(.secondary)
                Toggle("", isOn: Binding(get: { watch.autoplay }, set: { watch.setAutoplay($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(watch.related) { v in
                    ItemCard(item: .video(v), layout: .list)
                        .onTapGesture { watch.open(v, queue: nil, start: 0) }
                }
            }
            if watch.relatedToken != nil {
                Button(watch.loadingRelated ? "Loading…" : "Show more") { watch.loadMoreRelated() }
                    .disabled(watch.loadingRelated)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// The queue panel on the watch page.
struct QueuePanelView: View {
    let panel: QueuePanelModel

    var body: some View {
        let q = panel.queue
        let header = panel.header
        let title = header.0
        let sub = header.1
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(2)
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let q, !q.isMix {
                    Toggle(isOn: Binding(get: { q.repeatAll }, set: { panel.setRepeat($0) })) { Image(systemName: "repeat") }
                        .toggleStyle(.button)
                        .help("Loop playlist")
                    Toggle(isOn: Binding(get: { q.unshuffled != nil }, set: { panel.setShuffled($0) })) { Image(systemName: "shuffle") }
                        .toggleStyle(.button)
                        .disabled(panel.shuffling)
                        .help("Shuffle")
                }
                Button { panel.set(nil) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close queue")
            }
            if let q {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(q.items.enumerated()), id: \.offset) { i, v in
                            QueueRow(video: v, index: i, current: i == q.index, count: q.items.count, panel: panel)
                                .id(i)
                                .onAppear { if i + 3 >= q.items.count { panel.grow(nil) } }
                        }
                        .onMove { from, to in
                            guard let f = from.first else { return }
                            let dest = to > f ? to - 1 : to
                            panel.edit { $0.move(from: f, to: dest) }
                        }
                    }
                    .listStyle(.plain)
                    .frame(height: min(CGFloat(q.items.count) * 74 + 8, 440))
                    .onAppear { proxy.scrollTo(max(q.index - 1, 0), anchor: .top) }
                    .onChange(of: q.index) { _, i in withAnimation { proxy.scrollTo(max(i - 1, 0), anchor: .top) } }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct QueueRow: View {
    let video: VideoItem
    let index: Int
    let current: Bool
    let count: Int
    let panel: QueuePanelModel

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if current {
                    Image(systemName: "play.fill").foregroundStyle(Color.accentColor)
                } else {
                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(width: 24)
            Thumbnail(url: video.thumbnailURL, badge: video.duration).frame(width: 112)
            VStack(alignment: .leading, spacing: 2) {
                Text(video.title).font(.subheadline.weight(current ? .bold : .regular)).lineLimit(2)
                Text(video.channelName ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                if index > 0 { Button("Move up") { panel.edit { $0.move(from: index, to: index - 1) } } }
                if index + 1 < count { Button("Move down") { panel.edit { $0.move(from: index, to: index + 1) } } }
                if !current { Button("Remove from queue") { panel.edit { $0.remove(index) } } }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { panel.play(index) }
        .listRowBackground(current ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}

/// Comment threads under a video.
struct CommentsView: View {
    let comments: CommentsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Comments").font(.title3.weight(.semibold))
                if let c = comments.count { Text(c).foregroundStyle(.secondary) }
                Spacer()
                if !comments.sorts.isEmpty {
                    Picker("Sort by", selection: Binding(get: { comments.sortIndex }, set: { comments.sort($0) })) {
                        ForEach(Array(comments.sorts.enumerated()), id: \.offset) { i, s in Text(s.0).tag(i) }
                    }
                    .fixedSize()
                }
            }
            if comments.empty {
                Text("No comments").foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(comments.comments) { c in CommentRow(comment: c, reply: false) }
            }
            if comments.loading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if comments.hasMore {
                Color.clear.frame(height: 1)
                    .id(comments.comments.count)
                    .onAppear { comments.loadMore() }
                Button("Load more comments") { comments.loadMore() }.frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 8)
    }
}

struct CommentRow: View {
    let comment: Comment
    let reply: Bool
    @State private var showReplies = false
    @State private var replies: [Comment] = []
    @State private var repliesToken: String?
    @State private var loaded = false
    @State private var loadingReplies = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(url: comment.avatar, name: comment.author, size: reply ? 28 : 40)
                .onTapGesture { if let id = comment.authorChannelId { AppModel.shared.openChannel(id) } }
            VStack(alignment: .leading, spacing: 4) {
                if let p = comment.pinned {
                    Text("📌 \(p)").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text(comment.author)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, comment.isCreator ? 6 : 0)
                        .background(comment.isCreator ? Color.secondary.opacity(0.25) : .clear, in: Capsule())
                    if comment.isVerified { Text("✓").foregroundStyle(.secondary) }
                    Text(comment.published).font(.caption).foregroundStyle(.secondary)
                }
                Text(Linkify.attributed(comment.text)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Label(comment.likes ?? "", systemImage: "hand.thumbsup").font(.caption).foregroundStyle(.secondary)
                    if comment.hearted { Text("❤").foregroundStyle(.red).help("Hearted by the creator") }
                }
                if !reply, let token = comment.repliesToken {
                    Button("\(showReplies ? "▴" : "▾") \(comment.replyCount ?? "") replies") {
                        showReplies.toggle()
                        if showReplies && !loaded {
                            loaded = true
                            load(token)
                        }
                    }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                    if showReplies {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(replies) { r in CommentRow(comment: r, reply: true) }
                            if loadingReplies { ProgressView().controlSize(.small) }
                            if let t = repliesToken, !loadingReplies {
                                Button("Show more replies") { load(t) }.buttonStyle(.borderless).fontWeight(.semibold)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            }
        }
    }

    func load(_ token: String) {
        loadingReplies = true
        repliesToken = nil
        Task {
            do {
                let page = try await CommentsModel.replies(token)
                replies += page.comments
                repliesToken = page.continuation
            } catch {
                toast("Could not load replies: \(error.localizedDescription)")
            }
            loadingReplies = false
        }
    }
}
