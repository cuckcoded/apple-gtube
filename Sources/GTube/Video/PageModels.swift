import GTubeCore
import SwiftUI

enum LibraryTab: String, CaseIterable, Identifiable {
    case history, playlists, later, liked, channels
    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: return "History"
        case .playlists: return "Playlists"
        case .later: return "Watch later"
        case .liked: return "Liked videos"
        case .channels: return "Subscriptions"
        }
    }

    var icon: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .playlists: return "list.bullet.rectangle"
        case .later: return "clock"
        case .liked: return "hand.thumbsup"
        case .channels: return "person.2"
        }
    }

    var browseId: String {
        switch self {
        case .history: return "FEhistory"
        case .playlists: return "FEplaylist_aggregation"
        case .later: return "VLWL"
        case .liked: return "VLLL"
        case .channels: return "FEchannels"
        }
    }

    /// Watch later and Liked videos are playlists: shown as lists, played as queues.
    var isList: Bool { self == .later || self == .liked }
}

/// "You": the signed-in user's profile, history, playlists, Watch later,
/// liked videos and subscribed channels.
@MainActor @Observable
final class LibraryModel {
    var tab: LibraryTab = .history
    var account: Account?
    let feeds: [LibraryTab: FeedModel] = Dictionary(uniqueKeysWithValues: LibraryTab.allCases.map {
        ($0, FeedModel(.browse(id: $0.browseId, params: nil), needsLogin: true))
    })

    func show(tab t: LibraryTab) {
        tab = t
        feeds[t]?.ensureLoaded()
    }

    /// Drops loaded data, e.g. after signing in or out.
    func reset() {
        for f in feeds.values { f.invalidate() }
        feeds[tab]?.ensureLoaded()
    }
}

/// Which tab a `browseEndpoint.params` blob refers to (a protobuf whose
/// field 2 is the tab's internal name).
func channelTabKind(_ params: String) -> String {
    var raw = params.removingPercentEncoding ?? params
    raw = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while raw.count % 4 != 0 { raw += "=" }
    guard let data = Data(base64Encoded: raw) else { return "" }
    let b = [UInt8](data)
    if b.count > 2 && b[0] == 0x12 {
        let n = Int(b[1])
        if b.count >= 2 + n { return String(decoding: b[2..<(2 + n)], as: UTF8.self) }
    }
    return ""
}

/// A channel page: banner, avatar, stats, subscribe button and tabs (Videos,
/// Live, Playlists, …). The Shorts tab is never shown.
@MainActor @Observable
final class ChannelModel {
    static let videosParams = "EgZ2aWRlb3PyBgQKAjoA"
    static let shownTabs = ["videos", "streams", "playlists", "podcasts", "releases"]

    let id: String
    private(set) var page: ChannelPage?
    private(set) var tabs: [(String, String)] = []
    var selectedTab: String?
    private(set) var subscribed = false
    var descriptionExpanded = false
    let feed = FeedModel(.empty)
    private(set) var failed: String?

    init(_ id: String) {
        self.id = id
        load()
    }

    func load() {
        Task {
            do {
                let v = try await Client.shared.browse(id, params: Self.videosParams)
                let p = Parse.channel(v)
                page = p
                subscribed = p.subscribed ?? false
                tabs = p.tabs.filter { Self.shownTabs.contains(channelTabKind($0.1)) }
                selectedTab = tabs.first { channelTabKind($0.1) == "videos" }?.1 ?? tabs.first?.1
                feed.setFeed(.browse(id: id, params: Self.videosParams), Parse.feed(v, feedOpts()))
            } catch {
                failed = error.localizedDescription
                toast("Could not load channel: \(error.localizedDescription)")
            }
        }
    }

    func selectTab(_ params: String) {
        selectedTab = params
        feed.setSource(.browse(id: id, params: params))
    }

    func toggleSubscribe() {
        guard Client.shared.isLoggedIn else {
            AppModel.shared.sheet = .signIn
            return
        }
        let sub = !subscribed
        subscribed = sub
        Task {
            do { try await Client.shared.subscribe(id, sub) } catch {
                toast("Could not update subscription: \(error.localizedDescription)")
                subscribed = !sub
            }
        }
    }
}

/// A playlist page (also Watch later and Liked videos).
@MainActor @Observable
final class PlaylistViewModel {
    let id: String
    private(set) var page: PlaylistPage
    let feed = FeedModel(.empty)

    var listId: String { id.hasPrefix("VL") ? String(id.dropFirst(2)) : id }
    var browseId: String { id.hasPrefix("VL") ? id : "VL\(id)" }

    init(_ id: String) {
        self.id = id
        page = PlaylistPage(id: id)
        load()
    }

    func load() {
        Task {
            do {
                let p = Parse.playlist(try await Client.shared.browse(browseId), id: id, feedOpts())
                page = p
                feed.setFeed(.browse(id: browseId, params: nil), p.feed)
            } catch {
                toast("Could not load playlist: \(error.localizedDescription)")
            }
        }
    }

    var thumbnail: String? {
        page.thumbnail ?? page.feed.items.lazy.compactMap(\.video).first?.thumbnailURL
    }

    /// Opening a video from the list plays the list (all of it) from there.
    func play(from i: Int, shuffle: Bool) {
        QueueLoader.playList(title: page.title, listId: listId, items: feed.items, index: i, more: feed.continuation, shuffle: shuffle)
    }

    /// Sends changes; if YouTube refuses, says so and reloads the playlist.
    func send(_ edits: [PlaylistEdit], reloadOnError: Bool = true, done: ((Bool) -> Void)? = nil) {
        let list = listId
        Task {
            do {
                try await Client.shared.editPlaylist(list, edits)
                done?(true)
            } catch {
                toast("Could not change the playlist: \(error.localizedDescription)")
                if reloadOnError { load() }
                done?(false)
            }
        }
    }

    private func setId(_ i: Int) -> String? {
        i >= 0 && i < feed.items.count ? feed.items[i].video?.setVideoId : nil
    }

    func move(from: Int, to: Int) {
        // Without its set id YouTube can't move it: don't pretend to.
        if from == to || max(from, to) >= feed.items.count || setId(from) == nil { return }
        feed.move(from: from, to: to)
        guard let moved = setId(to) else { return }
        let edit: PlaylistEdit
        if let next = setId(to + 1) {
            edit = .moveBefore(moved, next)
        } else if let prev = setId(to - 1) {
            edit = .moveAfter(moved, prev)
        } else {
            return
        }
        send([edit])
    }

    func remove(_ i: Int) {
        guard i < feed.items.count, let v = feed.items[i].video else { return }
        feed.remove(at: i)
        send([.remove(videoId: v.id, setId: v.setVideoId)])
    }

    /// Saves a new name, description and visibility.
    func edit(title: String, description: String, privacy: String) {
        var edits: [PlaylistEdit] = []
        if !title.isEmpty && title != page.title { edits.append(.name(title)) }
        if description != (page.description ?? "") { edits.append(.description(description)) }
        if privacy != (page.privacy ?? "PUBLIC") { edits.append(.privacy(privacy)) }
        if edits.isEmpty { return }
        send(edits, reloadOnError: false) { [weak self] ok in
            guard ok, let self else { return }
            if !title.isEmpty { self.page.title = title }
            self.page.description = description.isEmpty ? nil : description
            self.page.privacy = privacy
        }
    }
}

/// Marking SponsorBlock segments while watching: where a segment starts, then
/// where it ends, and the submission dialog.
@MainActor
enum SponsorBlockMarker {
    struct Draft {
        var video: String
        var start: Double
        var end: Double?
    }

    static var draft: Draft?

    static func set(_ d: Draft?) {
        draft = d
        AppModel.shared.player.setSbDraft(d.map { ($0.start, $0.end) })
    }

    /// Marks where a segment starts; the second time, where it ends, and
    /// opens the submission dialog.
    static func mark() {
        let p = AppModel.shared.player
        guard let video = p.currentId, p.duration > 0 else { return }
        let pos = p.position
        if let d = draft, d.video == video {
            if d.end == nil { set(Draft(video: video, start: min(d.start, pos), end: max(d.start, pos))) }
            AppModel.shared.sheet = .submitSegment
        } else {
            set(Draft(video: video, start: pos, end: nil))
            toast("Segment starts at \(Format.preciseTime(pos)). Mark its end the same way (;)")
        }
    }
}
