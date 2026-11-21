import Foundation

/// The list of videos the watch page plays: from a playlist (all of it, page
/// by page as it plays), a mix (endless: more comes as it plays) or put
/// together by hand ("Play next" / "Add to queue").
public struct VideoQueue: Sendable {
    public var title = ""
    public var owner: String?
    public var items: [VideoItem] = []
    public var index = 0
    /// The playlist or mix it plays (nil: put together by hand).
    public var listId: String?
    /// Continuation for the rest of a long playlist.
    public var more: String?
    /// Number of videos in the playlist, when YouTube says.
    public var total: Int?
    public var repeatAll = false
    /// The original order, while shuffled.
    public var unshuffled: [VideoItem]?
    /// A mix that stopped giving new videos.
    public var mixDone = false

    public init() {}

    public var isMix: Bool { listId.map(GTubeCore.isMix) ?? false }

    public var canGrow: Bool { (isMix && !mixDone) || more != nil }

    public var current: VideoItem? { index < items.count ? items[index] : nil }

    /// Adds fetched videos. A mix's pages overlap, so it skips repeats.
    @discardableResult
    public mutating func append(_ new: [VideoItem]) -> Int {
        let before = items.count
        for v in new where !isMix || !items.contains(where: { $0.id == v.id }) {
            unshuffled?.append(v)
            items.append(v)
        }
        return items.count - before
    }

    /// Shuffles the queue. The current video stays (first) unless `everything`.
    public mutating func shuffle(everything: Bool) {
        if unshuffled == nil { unshuffled = items }
        if items.isEmpty { return }
        let cur: VideoItem? = everything ? nil : items.remove(at: min(index, items.count - 1))
        items.shuffle()
        if let c = cur { items.insert(c, at: 0) }
        index = 0
    }

    public mutating func unshuffle() {
        guard let original = unshuffled else { return }
        unshuffled = nil
        let id = current?.id
        index = id.flatMap { id in original.firstIndex { $0.id == id } } ?? 0
        items = original
    }

    /// Removes a video other than the playing one.
    public mutating func remove(_ i: Int) {
        if i == index || i >= items.count { return }
        let v = items.remove(at: i)
        if let p = unshuffled?.firstIndex(where: { $0.id == v.id }) { unshuffled?.remove(at: p) }
        if i < index { index -= 1 }
        total = total.map { max($0 - 1, 0) }
    }

    public mutating func move(from: Int, to: Int) {
        if from == to || from >= items.count || to >= items.count || from < 0 || to < 0 { return }
        let v = items.remove(at: from)
        items.insert(v, at: to)
        index = movedIndex(index, from: from, to: to)
    }

    public static func from(panel p: PlaylistPanel, list: String) -> VideoQueue {
        var q = VideoQueue()
        q.title = p.title
        q.owner = p.owner
        q.index = p.current
        q.items = p.items
        q.listId = p.id.isEmpty ? list : p.id
        q.total = p.total
        // Some generated lists ("RD…" album radios) do end.
        q.mixDone = !p.infinite
        return q
    }
}

/// Where the item at `cur` ends up when the one at `from` moves to `to`.
public func movedIndex(_ cur: Int, from: Int, to: Int) -> Int {
    if cur == from { return to }
    if from < cur && to >= cur { return cur - 1 }
    if from > cur && to <= cur { return cur + 1 }
    return cur
}

/// "123 videos" (from a playlist page's stats).
public func videoCount(_ stats: [String]) -> Int? {
    for s in stats where s.contains("video") {
        let digits = s.prefix { $0.isASCII && ($0.isNumber || $0 == "," || $0 == ".") }.filter { $0.isNumber }
        if let n = Int(String(digits)) { return n }
    }
    return nil
}

public func videosOf(_ items: [Item]) -> [VideoItem] { items.compactMap(\.video) }
