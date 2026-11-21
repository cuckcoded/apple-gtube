import GTubeCore
import SwiftUI

/// The comments under a video.
@MainActor @Observable
final class CommentsModel {
    private(set) var comments: [Comment] = []
    private(set) var count: String?
    private(set) var sorts: [(String, String)] = []
    var sortIndex = 0
    private(set) var loading = false
    private(set) var hasMore = false
    private(set) var empty = false
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var generation = 0

    func reset(token: String?, sorts: [(String, String)], count: String?) {
        self.count = count
        self.sorts = sorts
        sortIndex = 0
        start(token)
    }

    func clear() {
        generation += 1
        comments = []
        token = nil
        hasMore = false
        empty = false
        loading = false
    }

    func start(_ t: String?) {
        clear()
        if let t {
            token = t
            loadMore()
        } else {
            empty = true
        }
    }

    func sort(_ i: Int) {
        guard i < sorts.count, i != sortIndex else { return }
        sortIndex = i
        start(sorts[i].1)
    }

    func loadMore() {
        guard !loading, let t = token else { return }
        loading = true
        hasMore = false
        let gen = generation
        Task {
            do {
                let page = Parse.comments(try await Client.shared.nextContinuation(t))
                guard gen == generation else { return }
                loading = false
                if page.comments.isEmpty && comments.isEmpty { empty = true }
                comments += page.comments
                token = page.continuation
                hasMore = page.continuation != nil
            } catch {
                guard gen == generation else { return }
                loading = false
                hasMore = true
                toast("Could not load comments: \(error.localizedDescription)")
            }
        }
    }

    /// The replies of a thread (lazily, page by page).
    static func replies(_ token: String) async throws -> CommentsPage {
        Parse.comments(try await Client.shared.nextContinuation(token))
    }
}

/// The watch page: the video's details, likes and dislikes, description,
/// comments, related videos and the queue when playing a list.
@MainActor @Observable
final class WatchModel {
    private(set) var video: VideoItem?
    private(set) var details: VideoDetails?
    private(set) var likes: Int?
    private(set) var dislikes: Int?
    var likeStatus: String?
    private(set) var subscribed = false
    private(set) var related: [VideoItem] = []
    private(set) var relatedToken: String?
    private(set) var loadingRelated = false
    private(set) var sbInfo: String?
    var descriptionExpanded = false
    let comments = CommentsModel()
    let queue = QueuePanelModel()
    private(set) var autoplay = Config.settings.autoplay

    func setAutoplay(_ on: Bool) {
        autoplay = on
        Config.update { $0.autoplay = on }
    }
    @ObservationIgnored private var generation = 0
    /// Bumped on each open, so the page scrolls back to the top.
    private(set) var openCount = 0

    var player: PlayerModel { AppModel.shared.player }

    init() {
        queue.onChanged = { [self] in updateSkip() }
    }

    /// Opens `v` (optionally as part of a queue) and shows the page.
    func open(_ v: VideoItem, queue q: VideoQueue?, start: Double) {
        reset(v)
        setQueue(q)
        openCount += 1
        AppModel.shared.showWatch()
        if player.currentId != v.id {
            player.load(v, start: start)
        } else if start > 0 {
            player.seek(to: start)
        }
        loadDetails(v.id)
        if Config.settings.dislikes { loadVotes(v.id) }
    }

    private func reset(_ v: VideoItem) {
        generation += 1
        video = v
        details = nil
        likes = nil
        dislikes = nil
        likeStatus = nil
        subscribed = false
        related = []
        relatedToken = nil
        sbInfo = nil
        descriptionExpanded = false
        comments.clear()
    }

    /// The watch page came on screen again after its video was closed: start it again.
    func pageShown() {
        if let v = video, player.currentId != v.id { player.load(v, start: 0) }
    }

    private func setQueue(_ q: VideoQueue?) {
        queue.set(q)
        updateSkip()
    }

    /// Shows the player's previous / next buttons when they'd do something.
    func updateSkip() {
        player.wantPrev = queue.hasPrevious
        player.wantNext = queue.isActive || !related.isEmpty
    }

    /// "Play next" / "Add to queue".
    func enqueue(_ v: VideoItem, next: Bool) {
        let playing = video.flatMap { c in !player.isMusicOwned && player.currentId == c.id ? c : nil }
        if playing == nil && !queue.isActive { return open(v, queue: nil, start: 0) }
        queue.add(v, next: next, playing: playing)
        updateSkip()
        toast(next ? "Playing next: \(v.title)" : "Added to queue: \(v.title)")
    }

    /// The next video of the queue, or (like the Next button on youtube.com)
    /// the first related one.
    func next() { advance(user: true) }

    func previous() {
        if player.position > 3 { return player.seek(to: 0) }
        if let q = queue.previous(), let v = q.current {
            openKeepView(v, q)
        } else {
            player.seek(to: 0)
        }
    }

    /// Playback reached the end.
    func playNext() { advance(user: false) }

    private func advance(user: Bool) {
        if queue.isActive {
            queue.next { [weak self] q in
                guard let self else { return }
                if let q, let v = q.current {
                    if !user { toast("Up next: \(v.title)") }
                    openKeepView(v, q)
                } else {
                    // The queue is over: carry on like a single video.
                    playRelated(user: user)
                }
            }
            return
        }
        playRelated(user: user)
    }

    private func playRelated(user: Bool) {
        if !user && !Config.settings.autoplay { return }
        if let v = related.first(where: { !$0.isLive }) {
            if !user { toast("Up next: \(v.title)") }
            openKeepView(v, nil)
        }
    }

    /// Like `open`, but doesn't pull the page to the front while browsing
    /// elsewhere with the miniplayer.
    private func openKeepView(_ v: VideoItem, _ q: VideoQueue?) {
        if player.mode == .mini {
            player.load(v, start: 0)
            reset(v)
            setQueue(q)
            loadDetails(v.id)
            if Config.settings.dislikes { loadVotes(v.id) }
        } else {
            open(v, queue: q, start: 0)
        }
    }

    private func loadDetails(_ id: String) {
        let gen = generation
        Task {
            do {
                let d = Parse.next(try await Client.shared.next(id), feedOpts())
                guard gen == generation else { return }
                applyDetails(d)
            } catch {
                guard gen == generation else { return }
                toast("Could not load video details: \(error.localizedDescription)")
            }
        }
    }

    private func applyDetails(_ d: VideoDetails) {
        if var v = video {
            if !d.title.isEmpty { v.title = d.title }
            if v.channelId == nil && !d.channel.id.isEmpty { v.channelId = d.channel.id }
            if v.channelName == nil { v.channelName = d.channel.title }
            v.isLive = v.isLive || d.isLive
            video = v
        }
        player.setDetails(id: d.id, title: d.title, channel: d.channel.title)
        details = d
        subscribed = d.subscribed ?? false
        likeStatus = d.likeStatus
        appendRelated(d.related.items)
        relatedToken = d.related.continuation
        comments.reset(token: d.commentsToken, sorts: d.commentSorts, count: d.commentsCount)
    }

    private func appendRelated(_ items: [Item]) {
        related += items.compactMap(\.video)
        updateSkip()
    }

    func loadMoreRelated() {
        guard let t = relatedToken, !loadingRelated else { return }
        loadingRelated = true
        let gen = generation
        Task {
            defer { if gen == generation { loadingRelated = false } }
            do {
                let f = Parse.feed(try await Client.shared.nextContinuation(t), feedOpts())
                guard gen == generation else { return }
                appendRelated(f.items)
                relatedToken = f.continuation
            } catch {
                toast("Could not load more: \(error.localizedDescription)")
            }
        }
    }

    private func loadVotes(_ id: String) {
        let gen = generation
        Task {
            guard let v = try? await Extras.dislikes(id), gen == generation else { return }
            likes = v.likes
            dislikes = v.dislikes
        }
    }

    var likesText: String {
        if let l = likes { return Format.count(l) }
        return details?.likes ?? "–"
    }

    var dislikesText: String {
        if let d = dislikes { return Format.count(d) }
        return Config.settings.dislikes ? "–" : ""
    }

    var ratio: Double? {
        guard let l = likes, let d = dislikes, l + d > 0 else { return nil }
        return Double(l) / Double(l + d)
    }

    /// What SponsorBlock found for the current video.
    func setSegments(_ segs: [Segment]) {
        if segs.isEmpty {
            sbInfo = nil
            return
        }
        if let full = segs.first(where: { $0.action == "full" }) {
            sbInfo = "SponsorBlock: the whole video is labeled “\(Extras.sbLabel(full.category))”"
            return
        }
        var counts: [(String, Int)] = []
        for s in segs where s.action != "poi" {
            let l = Extras.sbLabel(s.category)
            if let i = counts.firstIndex(where: { $0.0 == l }) { counts[i].1 += 1 } else { counts.append((l, 1)) }
        }
        sbInfo = counts.isEmpty ? "SponsorBlock: highlight available"
            : "SponsorBlock: " + counts.map { $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0 }.joined(separator: ", ")
    }

    func toggleSubscribe() {
        guard Client.shared.isLoggedIn else {
            AppModel.shared.sheet = .signIn
            return
        }
        guard let id = details?.channel.id, !id.isEmpty else { return }
        let sub = !subscribed
        subscribed = sub
        Task {
            do {
                try await Client.shared.subscribe(id, sub)
                toast(sub ? "Subscribed" : "Unsubscribed")
            } catch {
                toast("Could not update subscription: \(error.localizedDescription)")
                subscribed = !sub
            }
        }
    }

    func rate(like: Bool) {
        guard Client.shared.isLoggedIn else { return toast("Sign in to rate videos") }
        guard let id = video?.id else { return }
        let target = like ? "LIKE" : "DISLIKE"
        let action: LikeAction
        if likeStatus == target {
            likeStatus = "INDIFFERENT"
            action = .remove
        } else {
            likeStatus = target
            action = like ? .like : .dislike
        }
        Task {
            do { try await Client.shared.like(id, action) } catch { toast("Could not save rating: \(error.localizedDescription)") }
        }
    }
}

/// The queue on the watch page.
@MainActor @Observable
final class QueuePanelModel {
    private(set) var queue: VideoQueue?
    private(set) var growing = false
    private(set) var shuffling = false
    @ObservationIgnored private var waiters: [(QueuePanelModel) -> Void] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored var onChanged: (() -> Void)?

    var isActive: Bool { queue != nil }

    var hasPrevious: Bool {
        guard let q = queue else { return false }
        return q.index > 0 || (q.repeatAll && !q.isMix)
    }

    var header: (String, String) {
        guard let q = queue else { return ("", "") }
        let pos = q.isMix ? "Mix" : "\(q.index + 1) / \(max(q.total ?? 0, q.items.count))"
        return (q.title.isEmpty ? "Queue" : q.title, [q.owner, pos].compactMap { $0 }.joined(separator: " • "))
    }

    func set(_ q: VideoQueue?) {
        let same: Bool
        if let a = queue, let b = q {
            same = a.items.map(\.id) == b.items.map(\.id)
        } else {
            same = false
        }
        if !same { generation += 1 }
        queue = q
        onChanged?()
        if let q, q.canGrow, q.index + 5 >= q.items.count { grow(nil) }
    }

    /// Changes the queue by hand, without dropping a fetch.
    func edit(_ f: (inout VideoQueue) -> Void) {
        guard var q = queue else { return }
        f(&q)
        queue = q
        onChanged?()
    }

    func play(_ i: Int) {
        guard var q = queue, i < q.items.count else { return }
        q.index = i
        AppModel.shared.watch.open(q.items[i], queue: q, start: 0)
    }

    func setRepeat(_ on: Bool) { edit { $0.repeatAll = on } }

    func setShuffled(_ on: Bool) {
        guard var q = queue else { return }
        if !on {
            q.unshuffle()
            return set(q)
        }
        if q.more == nil {
            q.shuffle(everything: false)
            return set(q)
        }
        // Shuffle all of a long playlist, not just what's loaded.
        shuffling = true
        let gen = generation
        let startQueue = q
        Task {
            var q = startQueue
            await QueueLoader.loadRest(&q)
            shuffling = false
            guard gen == generation else { return }
            // Playback may have moved on meanwhile.
            if let now = queue {
                q.index = now.index
                q.repeatAll = now.repeatAll
            }
            q.more = nil
            q.shuffle(everything: false)
            set(q)
        }
    }

    /// Loads more of the playlist or mix; `then` runs once that's done.
    func grow(_ then: ((QueuePanelModel) -> Void)?) {
        if let then { waiters.append(then) }
        if growing { return }
        guard let q = queue, q.canGrow else {
            let w = waiters
            waiters = []
            for f in w { f(self) }
            return
        }
        growing = true
        let gen = generation
        Task {
            var fetched: Result<([VideoItem], String?), Error>
            do {
                if q.isMix {
                    let p = try await QueueLoader.fetchPanel(video: q.items.last?.id, list: q.listId ?? "", index: max(q.items.count - 1, 0))
                    fetched = .success((p?.items ?? [], nil))
                } else {
                    fetched = .success(try await QueueLoader.fetchPage(q.more ?? ""))
                }
            } catch {
                fetched = .failure(error)
            }
            growing = false
            if gen == generation, var cur = queue {
                switch fetched {
                case .success(let (items, more)):
                    let added = cur.append(items)
                    if cur.isMix { cur.mixDone = added == 0 } else { cur.more = more }
                case .failure(let e):
                    Log.warn("queue: \(e.localizedDescription)")
                    // Don't keep retrying a failing list.
                    cur.more = nil
                    cur.mixDone = true
                }
                queue = cur
                onChanged?()
            }
            let w = waiters
            waiters = []
            for f in w { f(self) }
        }
    }

    /// The queue moved to its next video (nil: it's over).
    func next(_ f: @escaping (VideoQueue?) -> Void) {
        guard var q = queue else { return f(nil) }
        let next = q.index + 1
        if next < q.items.count {
            q.index = next
            return f(q)
        }
        if q.canGrow {
            grow { t in
                guard var q = t.queue else { return f(nil) }
                if next < q.items.count {
                    q.index = next
                    f(q)
                } else if q.repeatAll && !q.items.isEmpty {
                    q.index = 0
                    f(q)
                } else {
                    f(nil)
                }
            }
            return
        }
        if q.repeatAll && !q.isMix && !q.items.isEmpty {
            q.index = 0
            return f(q)
        }
        f(nil)
    }

    func previous() -> VideoQueue? {
        guard var q = queue else { return nil }
        if q.index > 0 {
            q.index -= 1
        } else if q.repeatAll && !q.isMix && !q.items.isEmpty && q.more == nil {
            q.index = q.items.count - 1
        } else {
            return nil
        }
        return q
    }

    /// "Play next" / "Add to queue". Without a queue, one is started with
    /// `playing` (the video that is playing).
    func add(_ v: VideoItem, next: Bool, playing: VideoItem?) {
        var q = queue ?? {
            var n = VideoQueue()
            n.items = playing.map { [$0] } ?? []
            return n
        }()
        let at = next ? min(q.index + 1, q.items.count) : q.items.count
        q.unshuffled?.append(v)
        q.items.insert(v, at: at)
        set(q)
    }
}

/// Loading playlists and mixes into the watch page's queue.
@MainActor
enum QueueLoader {
    /// Pages of a playlist loaded at most to find a video in it, or to shuffle.
    static let maxPages = 50

    nonisolated static func fetchPanel(video: String?, list: String, index: Int?) async throws -> PlaylistPanel? {
        Parse.playlistPanel(try await Client.shared.nextInList(videoId: video, list: list, index: index))
    }

    /// The next page of a playlist.
    nonisolated static func fetchPage(_ token: String) async throws -> ([VideoItem], String?) {
        let f = Parse.feed(try await Client.shared.browseContinuation(token), feedOpts())
        return (videosOf(f.items), f.continuation)
    }

    /// Loads the rest of a long playlist (up to `maxPages` pages).
    static func loadRest(_ q: inout VideoQueue) async {
        for _ in 0..<maxPages {
            guard let token = q.more else { return }
            q.more = nil
            do {
                let (items, more) = try await fetchPage(token)
                q.append(items)
                q.more = more
            } catch {
                Log.warn("playlist page: \(error.localizedDescription)")
                q.more = token
                return
            }
        }
    }

    static func play(_ q: VideoQueue, start: Double) {
        if let v = q.current { AppModel.shared.watch.open(v, queue: q, start: start) }
    }

    /// Plays mix `list` from `video` (or wherever YouTube starts it).
    static func openMix(video: String?, list: String, start: Double) {
        Task {
            do {
                if let p = try await fetchPanel(video: video, list: list, index: nil), !p.items.isEmpty {
                    return play(VideoQueue.from(panel: p, list: list), start: start)
                }
            } catch {
                Log.warn("mix \(list): \(error.localizedDescription)")
            }
            if let id = video {
                AppModel.shared.watch.open(VideoItem(id: id), queue: nil, start: start)
            } else {
                toast("Could not load the mix")
            }
        }
    }

    /// Plays playlist `list` with all of it as the queue, from `video` (its
    /// first video when nil). `shuffle` starts it shuffled.
    static func openPlaylist(video: String?, list: String, start: Double, shuffle: Bool) {
        if isMix(list) { return openMix(video: video, list: list, start: start) }
        Task {
            var q = VideoQueue()
            do {
                let p = Parse.playlist(try await Client.shared.browse("VL\(list)"), id: list, feedOpts())
                q.total = videoCount(p.stats)
                q.title = p.title
                q.owner = p.owner
                q.items = videosOf(p.feed.items)
                q.listId = list
                q.more = p.feed.continuation
            } catch {
                Log.warn("playlist \(list): \(error.localizedDescription)")
            }
            if shuffle {
                await loadRest(&q)
                q.more = nil
                q.shuffle(everything: true)
            }
            // Find the video, loading further pages when needed.
            var index: Int?
            while true {
                if let id = video {
                    index = q.items.firstIndex { $0.id == id }
                } else {
                    index = q.items.isEmpty ? nil : 0
                }
                if index != nil || q.more == nil { break }
                let token = q.more!
                q.more = nil
                if let page = try? await fetchPage(token) {
                    q.append(page.0)
                    q.more = page.1
                }
            }
            if let i = index {
                q.index = i
                return play(q, start: start)
            }
            // Hidden from the playlist's page: the watch page's panel knows the
            // playlist around the video.
            if let p = try? await fetchPanel(video: video, list: list, index: nil), !p.items.isEmpty {
                return play(VideoQueue.from(panel: p, list: list), start: start)
            }
            if let id = video {
                AppModel.shared.watch.open(VideoItem(id: id), queue: nil, start: start)
            } else {
                toast("Could not load the playlist")
            }
        }
    }

    /// Plays `items` (a loaded list) from `index`, with the rest of the list
    /// (also what isn't loaded yet, through `more`) as the queue.
    static func playList(title: String, listId: String?, items: [Item], index: Int, more: String?, shuffle: Bool) {
        let videos = videosOf(items)
        var pos = 0
        if index < items.count {
            if case .video(let target) = items[index] {
                pos = videos.firstIndex { $0.id == target.id } ?? 0
            } else if !shuffle {
                return AppModel.shared.activate(items[index])
            }
        }
        var q = VideoQueue()
        q.title = title
        q.items = videos
        q.index = pos
        q.listId = listId
        q.more = more
        if !shuffle { return play(q, start: 0) }
        let startQueue = q
        Task {
            var q = startQueue
            await loadRest(&q)
            q.more = nil
            q.shuffle(everything: true)
            play(q, start: 0)
        }
    }
}
