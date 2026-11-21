import Foundation

public struct VideoItem: Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String = ""
    public var channelName: String?
    public var channelId: String?
    public var channelAvatar: String?
    public var thumbnail: String?
    public var duration: String?
    public var views: String?
    public var published: String?
    public var isLive = false
    public var isShort = false
    /// Watch progress in 0...1, when YouTube reports it (signed in).
    public var progress: Double?
    /// Its entry in a playlist the user can edit (to remove or move it).
    public var setVideoId: String?

    public init(id: String, title: String = "") {
        self.id = id
        self.title = title
    }

    public var url: String { "https://www.youtube.com/watch?v=\(id)" }

    public var thumbnailURL: String {
        thumbnail ?? "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"
    }

    public var metaLine: String {
        [views, published].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • ")
    }
}

public struct ChannelItem: Hashable, Sendable {
    public var id: String = ""
    public var title: String = ""
    public var avatar: String?
    public var handle: String?
    public var subscribers: String?
    public var description: String?
    public init() {}
}

public struct PlaylistItem: Hashable, Sendable {
    public var id: String
    public var title: String = ""
    public var thumbnail: String?
    public var videoCount: String?
    public var channelName: String?
    public var channelId: String?
    /// The video it starts with (mixes are generated around one).
    public var videoId: String?

    public init(id: String, title: String = "") {
        self.id = id
        self.title = title
    }

    /// Mixes ("RD…") are endless playlists YouTube generates per viewer;
    /// they have no playlist page and are played from the watch page.
    public var isMix: Bool { GTubeCore.isMix(id) }
}

public func isMix(_ listId: String) -> Bool { listId.hasPrefix("RD") }

/// The playlist panel of a watch page that plays a playlist or a mix.
public struct PlaylistPanel: Sendable {
    public var id = ""
    public var title = ""
    public var owner: String?
    public var items: [VideoItem] = []
    /// Index (in `items`) of the video the page is for.
    public var current = 0
    /// Mixes never end: more items come with each request.
    public var infinite = false
    public var total: Int?
}

public enum Item: Hashable, Identifiable, Sendable {
    case video(VideoItem)
    case channel(ChannelItem)
    case playlist(PlaylistItem)

    public var id: String {
        switch self {
        case .video(let v): return "v:\(v.id)"
        case .channel(let c): return "c:\(c.id)"
        case .playlist(let p): return "p:\(p.id)"
        }
    }

    public var video: VideoItem? {
        if case .video(let v) = self { return v }
        return nil
    }

    public var url: String {
        switch self {
        case .video(let v): return v.url
        case .channel(let c): return "https://www.youtube.com/channel/\(c.id)"
        case .playlist(let p):
            if p.isMix, let v = p.videoId {
                return "https://www.youtube.com/watch?v=\(v)&list=\(p.id)"
            }
            return "https://www.youtube.com/playlist?list=\(p.id)"
        }
    }
}

public struct Chip: Hashable, Sendable {
    public var title: String
    public var token: String
    public var selected: Bool
}

public struct Feed: Sendable {
    public var items: [Item] = []
    public var continuation: String?
    public var chips: [Chip] = []
    public init() {}
}

public struct DescriptionLink: Hashable, Sendable {
    /// UTF-16 offset and length into the description.
    public var start: Int
    public var length: Int
    public var target: String
}

public struct VideoDetails: Sendable {
    public var id = ""
    public var title = ""
    public var views: String?
    public var date: String?
    public var relativeDate: String?
    public var description = ""
    /// Links inside `description` (UTF-16 ranges).
    public var descriptionLinks: [DescriptionLink] = []
    public var channel = ChannelItem()
    public var likes: String?
    /// "LIKE", "DISLIKE" or "INDIFFERENT" (only meaningful when signed in).
    public var likeStatus: String?
    public var subscribed: Bool?
    public var related = Feed()
    public var commentsToken: String?
    public var commentsCount: String?
    public var commentSorts: [(String, String)] = []
    public var isLive = false
    public init() {}
}

public struct Comment: Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var author = ""
    public var authorChannelId: String?
    public var avatar: String?
    public var text = ""
    public var published = ""
    public var likes: String?
    public var replyCount: String?
    public var repliesToken: String?
    public var isCreator = false
    public var isVerified = false
    public var pinned: String?
    public var hearted = false
    public init() {}
}

public struct CommentsPage: Sendable {
    public var comments: [Comment] = []
    public var continuation: String?
}

public struct ChannelPage: Sendable {
    public var info = ChannelItem()
    public var banner: String?
    public var videoCount: String?
    public var tabs: [(String, String)] = []
    public var subscribed: Bool?
}

public struct PlaylistPage: Sendable {
    public var id: String
    public var title = ""
    public var description: String?
    public var owner: String?
    public var ownerId: String?
    public var stats: [String] = []
    public var thumbnail: String?
    public var feed = Feed()
    /// The user's own playlist (or Watch later).
    public var editable = false
    /// PUBLIC, UNLISTED or PRIVATE, when shown.
    public var privacy: String?
    public init(id: String) { self.id = id }
}

/// One of the user's playlists, offered by "Save to playlist".
public struct SaveTarget: Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var saved: Bool
}

public struct Account: Hashable, Sendable {
    public var name: String
    public var handle: String?
    public var avatar: String?
    public var channelId: String?
}

public enum Resolved: Equatable, Sendable {
    case video(id: String, playlist: String?, start: Double?)
    case channel(String)
    case playlist(String)
    case search(String)
}
