import GTubeCore
import SwiftUI

enum FeedSource: Equatable {
    case browse(id: String, params: String?)
    case search(query: String, params: String?)
    case empty
}

enum FeedStatus: Equatable {
    case idle, loading
    case empty
    case needsLogin
    case error(String)
}

func feedOpts() -> Parse.Opts { Parse.Opts(hideShorts: Config.settings.hideShorts) }

/// Fetches a feed page (the first, or the one `token` continues to).
func fetchFeed(_ src: FeedSource, token: String?) async throws -> Feed {
    let c = Client.shared
    let v: JSON
    switch (src, token) {
    case (.search, .some(let t)): v = try await c.searchContinuation(t)
    case (_, .some(let t)): v = try await c.browseContinuation(t)
    case (.browse(let id, let params), nil): v = try await c.browse(id, params: params)
    case (.search(let q, let params), nil): v = try await c.search(q, params: params)
    case (.empty, nil): return Feed()
    }
    return Parse.feed(v, feedOpts())
}

/// An infinitely-loading grid or list of feed items, with chips.
@MainActor @Observable
final class FeedModel {
    private(set) var source: FeedSource
    private(set) var items: [Item] = []
    private(set) var continuation: String?
    private(set) var chips: [Chip] = []
    /// The selected chip (nil: the unfiltered feed).
    private(set) var selectedChip: Int?
    @ObservationIgnored private var defaultChip: Int?
    private(set) var status: FeedStatus = .idle
    private(set) var loadingMore = false
    let needsLogin: Bool
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var emptyLoads = 0

    init(_ source: FeedSource, needsLogin: Bool = false) {
        self.source = source
        self.needsLogin = needsLogin
    }

    func setSource(_ s: FeedSource) {
        source = s
        reload()
    }

    /// Loads the first page if this feed has never been loaded.
    func ensureLoaded() {
        if !loaded { reload() }
    }

    /// Forgets the loaded content; the next `ensureLoaded` fetches again.
    func invalidate() {
        loaded = false
        generation += 1
        clear()
    }

    private func clear() {
        items = []
        continuation = nil
        emptyLoads = 0
        loadingMore = false
    }

    func reload() {
        loaded = true
        generation += 1
        clear()
        chips = []
        selectedChip = nil
        if needsLogin && !Client.shared.isLoggedIn {
            status = .needsLogin
            return
        }
        load(token: nil, first: true)
    }

    /// Loads the feed again from the top, keeping the selected chip.
    func refresh() {
        guard let i = selectedChip, i != defaultChip, i < chips.count else { return reload() }
        loaded = true
        generation += 1
        clear()
        load(token: chips[i].token, first: false)
    }

    /// Shows an already fetched first page (a channel tab, a playlist).
    func setFeed(_ s: FeedSource, _ feed: Feed) {
        source = s
        loaded = true
        generation += 1
        clear()
        chips = []
        status = .idle
        apply(feed, first: true)
    }

    func loadMore() {
        guard let t = continuation, !loadingMore, status != .loading else { return }
        load(token: t, first: false)
    }

    private func load(token: String?, first: Bool) {
        let gen = generation
        if items.isEmpty { status = .loading } else { loadingMore = true }
        let src = source
        Task {
            do {
                let feed = try await fetchFeed(src, token: token)
                guard gen == generation else { return }
                loadingMore = false
                if status == .loading { status = .idle }
                apply(feed, first: first)
            } catch {
                guard gen == generation else { return }
                loadingMore = false
                if items.isEmpty {
                    status = .error(error.localizedDescription)
                } else {
                    status = .idle
                    toast("Could not load more: \(error.localizedDescription)")
                }
            }
        }
    }

    private func apply(_ feed: Feed, first: Bool) {
        if first && !feed.chips.isEmpty {
            chips = feed.chips
            defaultChip = feed.chips.firstIndex { $0.selected }
            selectedChip = defaultChip
        }
        let added = feed.items.count
        var seen = Set(items.map(\.id))
        for it in feed.items where seen.insert(it.id).inserted { items.append(it) }
        continuation = feed.continuation
        if items.isEmpty && continuation == nil { status = .empty }
        // Keep fetching while a page came back empty because everything on it
        // was filtered out.
        emptyLoads = added == 0 ? emptyLoads + 1 : 0
        if added == 0 && emptyLoads < 4 && continuation != nil { loadMore() }
    }

    /// Clicking the selected chip again goes back to the unfiltered feed.
    func selectChip(_ i: Int) {
        var token: String?
        if selectedChip == i {
            if i == defaultChip { return }
            selectedChip = defaultChip
            token = nil
        } else {
            selectedChip = i
            token = i == defaultChip ? nil : chips[i].token
        }
        generation += 1
        clear()
        status = .idle
        loaded = true
        load(token: token, first: false)
    }

    /// Removes an item (own playlists).
    func remove(at i: Int) {
        if i < items.count { items.remove(at: i) }
    }

    func move(from: Int, to: Int) {
        guard from < items.count, to < items.count, from != to else { return }
        let it = items.remove(at: from)
        items.insert(it, at: to)
    }
}
