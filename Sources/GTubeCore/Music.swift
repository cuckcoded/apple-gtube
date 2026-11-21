import Foundation

// YouTube Music: requests made as music.youtube.com's web client (`WEB_REMIX`)
// and parsers that turn its renderers into a small set of models — pages made
// of shelves of tracks and cards, the play queue and lyrics.
//
// Every YouTube Music page (home, explore, search, artists, albums,
// playlists, library, moods, charts, "related") is built from the same
// handful of renderers, so one generic page parser covers all of them.

/// A piece of text that may link to a page (artist, album, profile).
public struct MLink: Hashable, Sendable {
    public var text: String
    public var id: String?
    public init(text: String, id: String? = nil) {
        self.text = text
        self.id = id
    }
}

/// What activating something does.
public enum Target: Hashable, Sendable {
    case browse(id: String, params: String?)
    case watch(videoId: String?, playlistId: String?, params: String?, index: Int?)
    case search(query: String, params: String?)

    public static func browseTo(_ id: String) -> Target { .browse(id: id, params: nil) }
}

public enum VideoKind: Sendable {
    /// An "Art Track": the song, with the album cover as its picture.
    case song
    /// A music video (official or uploaded).
    case video
    case episode
}

public final class TrackBox: @unchecked Sendable, Hashable {
    public let track: Track
    public init(_ t: Track) { track = t }
    public static func == (a: TrackBox, b: TrackBox) -> Bool { a.track == b.track }
    public func hash(into h: inout Hasher) { h.combine(track) }
}

public struct Track: Hashable, Sendable, Identifiable {
    public var videoId: String
    public var title = ""
    public var artists: [MLink] = []
    public var album: MLink?
    public var duration: String?
    public var thumbnail: String?
    public var kind: VideoKind = .song
    public var explicit = false
    /// "1.2B plays", "36M views", a year…
    public var info: String?
    /// Track number on album pages.
    public var index: String?
    /// The list this row plays from (album, playlist, radio).
    public var playlistId: String?
    public var params: String?
    public var listIndex: Int?
    /// The other version of this track (song ↔ music video), when offered.
    public var counterpart: TrackBox?

    public init(videoId: String) { self.videoId = videoId }

    public var id: String { videoId }

    public var artistNames: String { artists.map(\.text).joined(separator: ", ") }

    public var firstArtistId: String? { artists.lazy.compactMap(\.id).first }

    public var url: String { "https://music.youtube.com/watch?v=\(videoId)" }

    public func thumbnailURL(_ px: Int) -> String {
        if let t = thumbnail { return Music.imageURL(t, px) }
        return "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg"
    }

    /// The form the shared player and the downloader work with.
    public var videoItem: VideoItem {
        var v = VideoItem(id: videoId, title: title)
        v.channelName = artistNames.isEmpty ? nil : artistNames
        v.channelId = firstArtistId
        v.thumbnail = thumbnail.map { Music.imageURL($0, 544) }
        v.duration = duration
        return v
    }

    /// The watch target that plays this track in its own list (album,
    /// playlist) or, failing that, as a radio.
    public var playTarget: Target {
        guard playlistId != nil else { return radioTarget }
        return .watch(videoId: videoId, playlistId: playlistId, params: params, index: listIndex)
    }

    public var radioTarget: Target {
        .watch(videoId: videoId, playlistId: "RDAMVM\(videoId)", params: "wAEB", index: nil)
    }
}

public enum Shape: Sendable {
    case square
    /// Artists and profiles.
    case round
    /// 16:9 music videos.
    case wide
}

/// An album, single, playlist, artist, video or mood tile.
public struct Card: Hashable, Sendable {
    public var title = ""
    public var subtitle: [MLink] = []
    public var thumbnail: String?
    public var target: Target?
    /// Plays the item directly (the play button over the thumbnail).
    public var play: Target?
    public var shape: Shape = .square
    public var explicit = false
    public init() {}

    public var subtitleText: String { subtitle.map(\.text).joined() }
}

/// A colored "mood or genre" button.
public struct Mood: Hashable, Sendable {
    public var title: String
    public var target: Target
    /// 0xAARRGGBB.
    public var color: UInt32?
}

public enum Entry: Hashable, Sendable {
    case track(Track)
    case card(Card)
    case mood(Mood)
}

public enum ShelfStyle: Sendable {
    /// Rows (songs, search results, album tracks).
    case list
    /// A horizontally scrolling row of tiles (or columns of songs).
    case carousel
    /// Wrapping tiles.
    case grid
    /// Text ("About").
    case text
}

public struct Shelf: Sendable, Identifiable {
    public var id = UUID()
    public var title: String?
    public var strapline: String?
    public var titleTarget: Target?
    /// "More", "See all"…
    public var more: (String, Target)?
    public var style: ShelfStyle = .list
    public var entries: [Entry] = []
    public var text: String?
    public var footer: String?
    public var continuation: String?
    public init() {}
}

public enum HeaderKind: Sendable { case simple, artist, collection }

public struct MHeader: Sendable {
    public var kind: HeaderKind = .simple
    public var title = ""
    /// "Album • 2013"
    public var subtitle: String?
    /// "13 songs • 1 hour, 14 minutes"
    public var secondSubtitle: String?
    /// Album artist / playlist owner.
    public var owner: [MLink] = []
    public var description: String?
    public var thumbnail: String?
    /// (label, target): "Play" for collections, "Shuffle" for artists.
    public var play: (String, Target)?
    public var shuffle: Target?
    public var radio: (String, Target)?
    public var channelId: String?
    public var subscribed: Bool?
    public var subscribers: String?
    public var monthly: String?
    /// Album/playlist "save to library" state and the id to save.
    public var saved: Bool?
    public var playlistId: String?
    public init() {}
}

public struct MChip: Hashable, Sendable {
    public var title: String
    public var target: Target
    public var selected: Bool
}

/// The large "top result" card of a search.
public struct TopResult: Sendable {
    public var card = Card()
    public var tracks: [Track] = []
    public var shuffle: Target?
    public var radio: Target?
}

public struct MPage: Sendable {
    public var title: String?
    public var header: MHeader?
    public var chips: [MChip] = []
    public var top: TopResult?
    public var shelves: [Shelf] = []
    /// Loads more shelves (home).
    public var continuation: String?
    public init() {}
}

/// The result of a continuation request: more shelves (section lists) or more
/// entries for the shelf that asked.
public struct MMore: Sendable {
    public var shelves: [Shelf] = []
    public var entries: [Entry] = []
    public var continuation: String?
}

public struct MQueue: Sendable {
    /// "Playing from": the album, playlist or mix name.
    public var title: String?
    public var tracks: [Track] = []
    public var selected: Int?
    public var continuation: String?
    public var playlistId: String?
    /// Where to continue once the list runs out ("autoplay").
    public var automix: Target?
    public var lyricsId: String?
    public var relatedId: String?
    public var likeStatus: String?
}

public enum Suggestion: Sendable, Hashable {
    case query(String)
    case entry(Entry)
}

// MARK: Requests

extension Client {
    public func musicBrowse(_ id: String, params: String? = nil) async throws -> JSON {
        var body: [String: Any] = ["browseId": id]
        if let p = params { body["params"] = p }
        return try await post(as: .music, "browse", body)
    }

    /// `endpoint` is "browse" or "search", whichever served the first page.
    public func musicContinuation(_ endpoint: String, _ token: String) async throws -> JSON {
        try await post(as: .music, endpoint, ["continuation": token])
    }

    public func musicSearch(_ query: String, params: String? = nil) async throws -> JSON {
        var body: [String: Any] = ["query": query]
        if let p = params { body["params"] = p }
        return try await post(as: .music, "search", body)
    }

    /// The play queue ("Up next") for a video and/or playlist, plus the lyrics
    /// and related tabs of the selected track.
    public func musicNext(_ target: Target) async throws -> JSON {
        var body: [String: Any] = [
            "isAudioOnly": true,
            "enablePersistentPlaylistPanel": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ]
        if case .watch(let v, let p, let params, let i) = target {
            if let v { body["videoId"] = v }
            if let p { body["playlistId"] = p }
            if let params { body["params"] = params }
            if let i { body["index"] = i }
        }
        return try await post(as: .music, "next", body)
    }

    public func musicNextContinuation(playlistId: String?, token: String) async throws -> JSON {
        var body: [String: Any] = ["continuation": token, "isAudioOnly": true, "enablePersistentPlaylistPanel": true]
        if let p = playlistId { body["playlistId"] = p }
        return try await post(as: .music, "next", body)
    }

    public func musicSuggestions(_ input: String) async throws -> [Suggestion] {
        let v = try await post(as: .music, "music/get_search_suggestions", ["input": input])
        return Music.suggestions(v)
    }

    /// Adds an album or playlist to the library, or removes it.
    public func musicSavePlaylist(_ playlistId: String, save: Bool) async throws {
        _ = try await post(as: .music, save ? "like/like" : "like/removelike", ["target": ["playlistId": playlistId]])
    }
}

// MARK: Parsers

public enum Music {
    static func text(_ v: JSON?) -> String? {
        guard let v else { return nil }
        if let s = v.string { return s }
        if let s = v["simpleText"]?.string { return s }
        if let s = v["content"]?.string { return s }
        guard let runs = v["runs"]?.array else { return nil }
        return runs.compactMap { $0["text"]?.string }.joined()
    }

    static func nonempty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    static func browseId(_ ep: JSON?) -> String? { ep?.pointer("/browseEndpoint/browseId")?.string }

    static func runs(_ v: JSON?) -> [MLink] {
        guard let arr = v?["runs"]?.array else {
            return text(v).map { [MLink(text: $0)] } ?? []
        }
        return arr.map { MLink(text: $0["text"]?.string ?? "", id: browseId($0["navigationEndpoint"])) }
    }

    static func strAt(_ v: JSON, _ p: String) -> String? { v.pointer(p)?.string }

    /// Any navigation/play endpoint as a `Target`.
    public static func target(_ ep: JSON) -> Target? {
        let ep = ep["innertubeCommand"] ?? ep
        if let b = ep["browseEndpoint"] {
            guard let id = b["browseId"]?.string else { return nil }
            return .browse(id: id, params: b["params"]?.string)
        }
        if let w = ep["watchEndpoint"] {
            return .watch(videoId: w["videoId"]?.string, playlistId: w["playlistId"]?.string, params: w["params"]?.string, index: w["index"]?.uint)
        }
        if let w = ep["watchPlaylistEndpoint"] {
            guard let p = w["playlistId"]?.string else { return nil }
            return .watch(videoId: nil, playlistId: p, params: w["params"]?.string, index: nil)
        }
        if let s = ep["searchEndpoint"] {
            guard let q = s["query"]?.string else { return nil }
            return .search(query: q, params: s["params"]?.string)
        }
        return nil
    }

    static func pageType(_ ep: JSON?) -> String {
        ep?.pointer("/browseEndpoint/browseEndpointContextSupportedConfigs/browseEndpointContextMusicConfig/pageType")?.string ?? ""
    }

    static func videoKind(_ ep: JSON?) -> VideoKind {
        switch ep?.pointer("/watchEndpoint/watchEndpointMusicSupportedConfigs/watchEndpointMusicConfig/musicVideoType")?.string ?? "" {
        case "MUSIC_VIDEO_TYPE_ATV", "": return .song
        case "MUSIC_VIDEO_TYPE_PODCAST_EPISODE": return .episode
        default: return .video
        }
    }

    /// The largest image in the first `thumbnails` list found under `v`.
    static func bestThumb(_ v: JSON) -> String? {
        func find(_ v: JSON, _ depth: Int) -> [JSON]? {
            if depth > 6 { return nil }
            switch v {
            case .object(let m):
                if let a = m["thumbnails"]?.array, !a.isEmpty { return a }
                if let a = m["sources"]?.array, !a.isEmpty { return a }
                for k in m.keys.sorted() {
                    if let f = find(m[k]!, depth + 1) { return f }
                }
                return nil
            case .array(let a):
                for x in a { if let f = find(x, depth + 1) { return f } }
                return nil
            default: return nil
            }
        }
        guard let list = find(v, 0) else { return nil }
        // The widest (the last of equally wide ones).
        var best: JSON?
        var bw = -1
        for t in list {
            let w = t["width"]?.uint ?? 0
            if w >= bw {
                bw = w
                best = t
            }
        }
        guard let url = best?["url"]?.string else { return nil }
        return url.hasPrefix("//") ? "https:" + url : url
    }

    private static let whRe = try! NSRegularExpression(pattern: #"=w(\d+)-h(\d+)"#)
    private static let sRe = try! NSRegularExpression(pattern: #"=s(\d+)"#)

    /// Asks Google's image servers for a square image of `px` pixels (artwork
    /// and avatars come with a size suffix such as `=w120-h120-l90-rj`).
    public static func imageURL(_ url: String, _ px: Int) -> String {
        guard url.contains("googleusercontent.com") || url.contains("ggpht.com") else { return url }
        let r = NSRange(url.startIndex..., in: url)
        if let m = whRe.firstMatch(in: url, range: r),
           let a = Range(m.range(at: 1), in: url), let b = Range(m.range(at: 2), in: url), url[a] == url[b],
           let whole = Range(m.range, in: url) {
            return url.replacingCharacters(in: whole, with: "=w\(px)-h\(px)")
        }
        if let m = sRe.firstMatch(in: url, range: r), let whole = Range(m.range, in: url) {
            return url.replacingCharacters(in: whole, with: "=s\(px)")
        }
        return url
    }

    private static let durRe = try! NSRegularExpression(pattern: #"^\d{1,2}(:\d{2}){1,2}$"#)

    static func isDuration(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return durRe.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    /// The type word that starts rows of mixed search results ("Song • Artist • 54M plays").
    static func typeLabel(_ s: String) -> VideoKind? {
        switch s {
        case "Song", "Brano", "Canción", "Titre", "Música", "Titel", "Utwór", "Nummer", "Låt", "Песня", "Şarkı", "曲", "노래": return .song
        case "Video", "Vídeo", "Vidéo", "Wideo", "Видео", "動画", "동영상": return .video
        case "Episode", "Episodio", "Épisode", "Episódio", "Folge", "Odcinek", "Aflevering", "Эпизод", "Bölüm", "エピソード", "에피소드": return .episode
        default: return nil
        }
    }

    static func isSeparator(_ s: String) -> Bool {
        ["•", "&", ",", "·", ""].contains(s.trimmingCharacters(in: .whitespaces))
    }

    static func explicit(_ it: JSON) -> Bool {
        func has(_ key: String) -> Bool {
            it[key]?.array?.contains { strAt($0, "/musicInlineBadgeRenderer/icon/iconType") == "MUSIC_EXPLICIT_BADGE" } ?? false
        }
        return has("badges") || has("subtitleBadges")
    }

    static func isRound(_ it: JSON, _ ep: JSON?) -> Bool {
        let crop = (it.pointer("/thumbnail/musicThumbnailRenderer/thumbnailCrop") ?? it.pointer("/thumbnailRenderer/musicThumbnailRenderer/thumbnailCrop"))?.string
        return crop == "MUSIC_THUMBNAIL_CROP_CIRCLE" || ["MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL"].contains(pageType(ep))
    }

    /// Splits runs into " • "-separated groups.
    static func groups(_ links: [MLink]) -> [[MLink]] {
        var out: [[MLink]] = [[]]
        for l in links {
            if l.text.trimmingCharacters(in: .whitespaces) == "•" {
                out.append([])
            } else {
                out[out.count - 1].append(l)
            }
        }
        return out.filter { !$0.isEmpty }
    }

    /// Sorts byline runs ("Artist & Artist • Album • 2013 • 5:38") into the track's fields.
    public static func fillByline(_ t: inout Track, _ cols: [[MLink]]) {
        var plainArtists: [MLink]?
        var info: [String] = []
        for (ci, col) in cols.enumerated() {
            let gs = groups(col)
            func laterHasArtist(_ from: Int) -> Bool {
                gs[from...].joined().contains { $0.id?.hasPrefix("UC") ?? false }
            }
            for (gi, g) in gs.enumerated() {
                let joined = g.map(\.text).joined().trimmingCharacters(in: .whitespaces)
                if joined.isEmpty { continue }
                let ids = g.compactMap(\.id)
                if ids.contains(where: { $0.hasPrefix("MPREb") }) {
                    t.album = g.first { $0.id != nil }
                } else if ids.contains(where: { $0.hasPrefix("UC") }) {
                    t.artists = g.filter { !isSeparator($0.text) }
                } else if isDuration(joined) {
                    t.duration = joined
                } else if ci == 0 && gi == 0 && gs.count > 1 && (laterHasArtist(1) || typeLabel(joined) != nil) {
                    // A type label ("Song", "Video", "Episode") in mixed results.
                    if let k = typeLabel(joined) {
                        t.kind = k
                    } else if joined == "Video" {
                        t.kind = .video
                    }
                } else if joined.contains(where: { $0.isASCII && $0.isNumber }) {
                    info.append(joined)
                } else if plainArtists == nil && ci == 0 {
                    plainArtists = g.filter { !isSeparator($0.text) }
                } else if t.album == nil && ci > 0 {
                    t.album = MLink(text: joined)
                }
            }
        }
        if t.artists.isEmpty, let p = plainArtists { t.artists = p }
        if !info.isEmpty { t.info = info.joined(separator: " • ") }
    }

    static func flexColumns(_ it: JSON) -> [JSON] {
        (it["flexColumns"]?.array ?? []).compactMap { $0.pointer("/musicResponsiveListItemFlexColumnRenderer/text") }
    }

    static func listItem(_ it: JSON) -> Entry? {
        let cols = flexColumns(it)
        guard let titleCol = cols.first, let title = nonempty(text(titleCol)) else { return nil }
        let titleEp = titleCol.pointer("/runs/0/navigationEndpoint")
        let nav = it["navigationEndpoint"]
        let playEp = it.pointer("/overlay/musicItemThumbnailOverlayRenderer/content/musicPlayButtonRenderer/playNavigationEndpoint")
        let thumbnail = it["thumbnail"].flatMap(bestThumb)

        if let nav, nav["browseEndpoint"] != nil {
            var subtitle: [MLink] = []
            for c in cols.dropFirst() {
                let r = runs(c)
                if r.allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
                if !subtitle.isEmpty { subtitle.append(MLink(text: " • ")) }
                subtitle += r
            }
            var c = Card()
            c.title = title
            c.subtitle = subtitle
            c.thumbnail = thumbnail
            c.target = target(nav)
            c.play = playEp.flatMap(target)
            c.shape = isRound(it, nav) ? .round : .square
            c.explicit = explicit(it)
            return .card(c)
        }

        // The play button's endpoint carries the list (album, radio) to play in.
        let watch = [playEp, titleEp].compactMap { $0 }.first { $0["watchEndpoint"] != nil }
        guard let videoId = strAt(it, "/playlistItemData/videoId") ?? watch.flatMap({ strAt($0, "/watchEndpoint/videoId") }) else { return nil }
        var t = Track(videoId: videoId)
        t.title = title
        t.thumbnail = thumbnail
        t.kind = videoKind(watch)
        t.explicit = explicit(it)
        t.index = nonempty(text(it["index"]))
        t.playlistId = watch.flatMap { strAt($0, "/watchEndpoint/playlistId") }
        t.params = watch.flatMap { strAt($0, "/watchEndpoint/params") }
        t.listIndex = watch?.pointer("/watchEndpoint/index")?.uint
        fillByline(&t, cols.dropFirst().map { runs($0) })
        for f in it["fixedColumns"]?.array ?? [] {
            if let s = nonempty(text(f.pointer("/musicResponsiveListItemFixedColumnRenderer/text"))), isDuration(s) {
                t.duration = s
            }
        }
        return .track(t)
    }

    static func twoRow(_ it: JSON) -> Entry? {
        guard let title = nonempty(text(it["title"])) else { return nil }
        let nav = it["navigationEndpoint"] ?? it.pointer("/title/runs/0/navigationEndpoint")
        let play = it.pointer("/thumbnailOverlay/musicItemThumbnailOverlayRenderer/content/musicPlayButtonRenderer/playNavigationEndpoint")
        let aspect = it["aspectRatio"]?.string ?? ""
        var c = Card()
        c.title = title
        c.subtitle = runs(it["subtitle"])
        c.thumbnail = it["thumbnailRenderer"].flatMap(bestThumb)
        c.target = nav.flatMap(target)
        c.play = play.flatMap(target)
        c.shape = aspect.contains("16_9") ? .wide : (isRound(it, nav) ? .round : .square)
        c.explicit = explicit(it)
        return .card(c)
    }

    static func mood(_ it: JSON) -> Entry? {
        guard let title = nonempty(text(it["buttonText"])), let cmd = it["clickCommand"], let t = target(cmd) else { return nil }
        return .mood(Mood(title: title, target: t, color: it.pointer("/solid/leftStripeColor")?.uint.map { UInt32(truncatingIfNeeded: $0) }))
    }

    /// A queue item ("Up next").
    static func panelVideo(_ it: JSON) -> Track? {
        if it["unplayableText"] != nil { return nil }
        guard let videoId = it["videoId"]?.string, let title = nonempty(text(it["title"])) else { return nil }
        let ep = it["navigationEndpoint"]
        var t = Track(videoId: videoId)
        t.title = title
        t.duration = nonempty(text(it["lengthText"]))
        t.thumbnail = it["thumbnail"].flatMap(bestThumb)
        t.kind = videoKind(ep)
        t.explicit = explicit(it)
        t.playlistId = ep.flatMap { strAt($0, "/watchEndpoint/playlistId") }
        t.params = ep.flatMap { strAt($0, "/watchEndpoint/params") }
        t.listIndex = ep?.pointer("/watchEndpoint/index")?.uint
        fillByline(&t, [runs(it["longBylineText"] ?? it["shortBylineText"])])
        return t
    }

    static func entry(_ k: String, _ it: JSON) -> Entry? {
        switch k {
        case "musicResponsiveListItemRenderer": return listItem(it)
        case "musicTwoRowItemRenderer": return twoRow(it)
        case "musicNavigationButtonRenderer": return mood(it)
        case "playlistPanelVideoRenderer": return panelVideo(it).map { .track($0) }
        default: return nil
        }
    }

    static func continuationToken(_ v: JSON) -> String? {
        for p in ["/continuations/0/nextContinuationData/continuation", "/continuations/0/nextRadioContinuationData/continuation"] {
            if let t = strAt(v, p) { return t }
        }
        for key in ["contents", "items", "continuationItems"] {
            if let last = v[key]?.array?.last,
               let t = strAt(last, "/continuationItemRenderer/continuationEndpoint/continuationCommand/token") {
                return t
            }
        }
        return nil
    }

    static func entries(_ list: JSON?) -> [Entry] {
        (list?.array ?? []).compactMap { i in i.firstEntry.flatMap { entry($0.key, $0.value) } }
    }

    static func topResult(_ s: JSON) -> TopResult? {
        let titleEp = s.pointer("/title/runs/0/navigationEndpoint") ?? s["onTap"]
        guard let title = nonempty(text(s["title"])) else { return nil }
        var card = Card()
        card.title = title
        card.subtitle = runs(s["subtitle"])
        card.thumbnail = s["thumbnail"].flatMap(bestThumb)
        card.target = titleEp.flatMap(target)
        card.shape = isRound(s, titleEp) ? .round : .square
        var top = TopResult()
        top.card = card
        top.tracks = entries(s["contents"]).compactMap { if case .track(let t) = $0 { return t } else { return nil } }
        for b in s["buttons"]?.array ?? [] {
            guard let br = b["buttonRenderer"] else { continue }
            let t = (br["command"] ?? br["navigationEndpoint"]).flatMap(target)
            switch strAt(br, "/icon/iconType") {
            case "MUSIC_SHUFFLE": top.shuffle = t
            case "MIX": top.radio = t
            default: if top.card.play == nil { top.card.play = t }
            }
        }
        return top
    }

    static func shelf(_ k: String, _ s: JSON) -> Shelf? {
        var shelf = Shelf()
        switch k {
        case "musicCarouselShelfRenderer", "musicImmersiveCarouselShelfRenderer":
            shelf.style = .carousel
            if let h = s["header"]?.firstEntry?.value {
                shelf.title = nonempty(text(h["title"]))
                shelf.titleTarget = h.pointer("/title/runs/0/navigationEndpoint").flatMap(target)
                shelf.strapline = nonempty(text(h["strapline"]))
                if let b = h.pointer("/moreContentButton/buttonRenderer"),
                   let label = nonempty(text(b["text"])), let t = b["navigationEndpoint"].flatMap(target) {
                    shelf.more = (label, t)
                }
            }
            shelf.entries = entries(s["contents"])
        case "musicShelfRenderer", "musicPlaylistShelfRenderer":
            shelf.title = nonempty(text(s["title"]))
            shelf.titleTarget = s.pointer("/title/runs/0/navigationEndpoint").flatMap(target)
            if let label = nonempty(text(s["bottomText"])), let t = s["bottomEndpoint"].flatMap(target) {
                shelf.more = (label, t)
            }
            shelf.entries = entries(s["contents"])
            shelf.continuation = continuationToken(s)
        case "gridRenderer":
            shelf.style = .grid
            shelf.title = nonempty(text(s.pointer("/header/gridHeaderRenderer/title")))
            shelf.entries = entries(s["items"])
            shelf.continuation = continuationToken(s)
        case "musicDescriptionShelfRenderer":
            shelf.style = .text
            shelf.title = nonempty(text(s["header"]))
            shelf.text = nonempty(text(s["description"]))
            shelf.footer = nonempty(text(s["footer"]))
            if shelf.text == nil { return nil }
        default:
            return nil
        }
        if shelf.style != .text && shelf.entries.isEmpty && shelf.continuation == nil { return nil }
        return shelf
    }

    static func chips(_ sl: JSON) -> [MChip] {
        (sl.pointer("/header/chipCloudRenderer/chips")?.array ?? []).compactMap { c in
            guard let c = c["chipCloudChipRenderer"], let title = nonempty(text(c["text"])),
                  let nav = c["navigationEndpoint"], let t = target(nav) else { return nil }
            return MChip(title: title, target: t, selected: c["isSelected"]?.bool ?? false)
        }
    }

    /// Adds the sections of a section list to `page`.
    static func addSections(_ page: inout MPage, _ sections: [JSON]) {
        var loose = Shelf()
        func flush() {
            if !loose.entries.isEmpty {
                page.shelves.append(loose)
                loose = Shelf()
            }
        }
        for sec in sections {
            guard let fe = sec.firstEntry else { continue }
            let (k, s) = (fe.key, fe.value)
            switch k {
            case "itemSectionRenderer":
                for c in s["contents"]?.array ?? [] {
                    guard let fe = c.firstEntry else { continue }
            let (ck, cv) = (fe.key, fe.value)
                    if let e = entry(ck, cv) {
                        loose.entries.append(e)
                    } else if let sh = shelf(ck, cv) {
                        flush()
                        page.shelves.append(sh)
                    }
                }
            case "musicCardShelfRenderer":
                flush()
                if page.top == nil { page.top = topResult(s) }
            case "musicResponsiveHeaderRenderer", "musicEditablePlaylistDetailHeaderRenderer", "musicDetailHeaderRenderer":
                if page.header == nil { page.header = header(k, s) }
            default:
                if let sh = shelf(k, s) {
                    flush()
                    page.shelves.append(sh)
                }
            }
        }
        flush()
    }

    static func addSectionList(_ page: inout MPage, _ sl: JSON) {
        if page.chips.isEmpty { page.chips = chips(sl) }
        if let a = sl["contents"]?.array { addSections(&page, a) }
        if let t = continuationToken(sl) { page.continuation = t }
    }

    static func buttonTarget(_ b: JSON) -> (String, Target)? {
        guard let br = b["buttonRenderer"], let t = (br["navigationEndpoint"] ?? br["command"]).flatMap(target) else { return nil }
        return (nonempty(text(br["text"])) ?? "", t)
    }

    static func header(_ k: String, _ h: JSON) -> MHeader? {
        switch k {
        case "musicEditablePlaylistDetailHeaderRenderer":
            guard let inner = h["header"]?.firstEntry, var hd = header(inner.key, inner.value) else { return nil }
            if let pid = strAt(h, "/playlistId") { hd.playlistId = pid }
            return hd
        case "musicImmersiveHeaderRenderer", "musicVisualHeaderRenderer":
            guard let title = nonempty(text(h["title"])) else { return nil }
            let sub = h.pointer("/subscriptionButton/subscribeButtonRenderer")
            var hd = MHeader()
            hd.kind = .artist
            hd.title = title
            hd.description = nonempty(text(h["description"]))
            hd.thumbnail = h["thumbnail"].flatMap(bestThumb) ?? h["foregroundThumbnail"].flatMap(bestThumb)
            hd.play = h["playButton"].flatMap(buttonTarget)
            hd.radio = h["startRadioButton"].flatMap(buttonTarget)
            hd.channelId = sub.flatMap { strAt($0, "/channelId") }
            hd.subscribed = sub?["subscribed"]?.bool
            hd.subscribers = sub.flatMap { nonempty(text($0["longSubscriberCountText"]) ?? text($0["subscriberCountText"])) }
            hd.monthly = nonempty(text(h["monthlyListenerCount"]))
            return hd
        case "musicResponsiveHeaderRenderer", "musicDetailHeaderRenderer":
            guard let title = nonempty(text(h["title"])) else { return nil }
            var hd = MHeader()
            hd.kind = .collection
            hd.title = title
            hd.subtitle = nonempty(text(h["subtitle"]))
            hd.secondSubtitle = nonempty(text(h["secondSubtitle"]))
            hd.owner = runs(h["straplineTextOne"]).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            hd.description = nonempty(text(h.pointer("/description/musicDescriptionShelfRenderer/description"))) ?? nonempty(text(h["description"]))
            hd.thumbnail = h["thumbnail"].flatMap(bestThumb)
            if hd.owner.isEmpty, let av = h.pointer("/facepile/avatarStackViewModel"), let name = nonempty(text(av["text"])) {
                let id = av.pointer("/rendererContext/commandContext/onTap/innertubeCommand/browseEndpoint/browseId")?.string
                hd.owner = [MLink(text: name, id: id)]
            }
            var menuItems: [JSON] = []
            for b in h["buttons"]?.array ?? [] {
                if let p = b.pointer("/musicPlayButtonRenderer/playNavigationEndpoint").flatMap(target) {
                    hd.play = ("Play", p)
                }
                if let tb = b["toggleButtonRenderer"] {
                    hd.saved = tb["isToggled"]?.bool
                    if let pid = strAt(tb, "/defaultServiceEndpoint/likeEndpoint/target/playlistId") { hd.playlistId = pid }
                }
                menuItems += b.pointer("/menuRenderer/items")?.array ?? []
            }
            menuItems += h.pointer("/menu/menuRenderer/items")?.array ?? []
            for it in menuItems {
                guard let m = it["menuNavigationItemRenderer"] else { continue }
                let t = m["navigationEndpoint"].flatMap(target)
                switch strAt(m, "/icon/iconType") {
                case "MUSIC_SHUFFLE": hd.shuffle = t
                case "MIX": hd.radio = t.map { (nonempty(text(m["text"])) ?? "Radio", $0) }
                default: break
                }
            }
            if hd.playlistId == nil {
                // The album's/playlist's own list id, for saving it.
                for t in [hd.shuffle, hd.play?.1].compactMap({ $0 }) {
                    if case .watch(_, .some(let p), _, _) = t, !p.hasPrefix("RDAM") {
                        hd.playlistId = p
                        break
                    }
                }
            }
            return hd
        default:
            return nil
        }
    }

    /// Any browse or search response.
    public static func page(_ v: JSON) -> MPage {
        var page = MPage()
        if let fe = v["header"]?.firstEntry {
            let (k, h) = (fe.key, fe.value)
            if k == "musicHeaderRenderer" {
                page.title = nonempty(text(h["title"]))
            } else {
                page.header = header(k, h)
            }
        }
        let c = v["contents"]
        func tabList(_ root: String) -> JSON? { c?.pointer("/\(root)/tabs/0/tabRenderer/content/sectionListRenderer") }
        for root in ["singleColumnBrowseResultsRenderer", "tabbedSearchResultsRenderer", "twoColumnBrowseResultsRenderer"] {
            if let sl = tabList(root) { addSectionList(&page, sl) }
        }
        if let sl = c?.pointer("/twoColumnBrowseResultsRenderer/secondaryContents/sectionListRenderer") { addSectionList(&page, sl) }
        if let sl = c?["sectionListRenderer"] { addSectionList(&page, sl) }
        if let sl = v.pointer("/continuationContents/sectionListContinuation") { addSectionList(&page, sl) }
        if page.title == nil { page.title = page.header?.title }
        return page
    }

    /// A continuation response (more shelves, or more rows for one shelf).
    public static func more(_ v: JSON) -> MMore {
        var more = MMore()
        for (k, c) in v["continuationContents"]?.sortedEntries ?? [] {
            switch k {
            case "sectionListContinuation":
                var p = MPage()
                addSectionList(&p, c)
                more.shelves = p.shelves
                more.continuation = p.continuation
            case "musicShelfContinuation", "musicPlaylistShelfContinuation":
                more.entries = entries(c["contents"])
                more.continuation = continuationToken(c)
            case "gridContinuation":
                more.entries = entries(c["items"])
                more.continuation = continuationToken(c)
            default: break
            }
        }
        for a in v["onResponseReceivedActions"]?.array ?? [] {
            if let items = a.pointer("/appendContinuationItemsAction/continuationItems") {
                more.entries += entries(items)
                if let t = continuationToken(a["appendContinuationItemsAction"] ?? .null) { more.continuation = t }
            }
        }
        return more
    }

    static func panelItems(_ contents: JSON?) -> ([Track], Int?, Target?) {
        var tracks: [Track] = []
        var selected: Int?
        var automix: Target?
        for item in contents?.array ?? [] {
            guard let fe = item.firstEntry else { continue }
            let (k, it) = (fe.key, fe.value)
            switch k {
            case "playlistPanelVideoRenderer":
                if let t = panelVideo(it) {
                    if it["selected"]?.bool == true { selected = tracks.count }
                    tracks.append(t)
                }
            case "playlistPanelVideoWrapperRenderer":
                guard let primary = it.pointer("/primaryRenderer/playlistPanelVideoRenderer"), var t = panelVideo(primary) else { continue }
                if let cp = it.pointer("/counterpart/0/counterpartRenderer/playlistPanelVideoRenderer").flatMap(panelVideo) {
                    t.counterpart = TrackBox(cp)
                }
                if primary["selected"]?.bool == true { selected = tracks.count }
                tracks.append(t)
            case "automixPreviewVideoRenderer":
                automix = it.pointer("/content/automixPlaylistVideoRenderer/navigationEndpoint").flatMap(target)
            default: break
            }
        }
        return (tracks, selected, automix)
    }

    /// A `next` response: the queue and the selected track's lyrics/related tabs.
    public static func queue(_ v: JSON) -> MQueue {
        var q = MQueue()
        let tabs = v.pointer("/contents/singleColumnMusicWatchNextResultsRenderer/tabbedRenderer/watchNextTabbedResultsRenderer/tabs")?.array ?? []
        for tab in tabs {
            guard let tr = tab["tabRenderer"] else { continue }
            if let panel = tr.pointer("/content/musicQueueRenderer/content/playlistPanelRenderer") {
                (q.tracks, q.selected, q.automix) = panelItems(panel["contents"])
                q.continuation = continuationToken(panel)
                q.title = nonempty(text(panel["title"]))
                q.playlistId = panel["playlistId"]?.string
            }
            if tr["unselectable"]?.bool == true { continue }
            if let id = browseId(tr["endpoint"]) {
                if id.hasPrefix("MPLYt") {
                    q.lyricsId = id
                } else if id.hasPrefix("MPTRt") {
                    q.relatedId = id
                }
            }
        }
        q.likeStatus = v.pointer("/playerOverlays/playerOverlayRenderer/actions/0/likeButtonRenderer/likeStatus")?.string
        return q
    }

    /// More queue items (radio continuation).
    public static func queueMore(_ v: JSON) -> ([Track], String?, Target?) {
        guard let c = v.pointer("/continuationContents/playlistPanelContinuation") else { return ([], nil, nil) }
        let (tracks, _, automix) = panelItems(c["contents"])
        return (tracks, continuationToken(c), automix)
    }

    public static func lyrics(_ v: JSON) -> Lyrics? {
        func walk(_ v: JSON) -> Lyrics? {
            switch v {
            case .object(let m):
                if let d = m["musicDescriptionShelfRenderer"], let body = nonempty(text(d["description"])) {
                    return Lyrics.plain(body, source: nonempty(text(d["footer"])))
                }
                for k in m.keys.sorted() {
                    if let l = walk(m[k]!) { return l }
                }
                return nil
            case .array(let a):
                for x in a { if let l = walk(x) { return l } }
                return nil
            default: return nil
            }
        }
        guard let c = v["contents"] else { return nil }
        return walk(c)
    }

    public static func suggestions(_ v: JSON) -> [Suggestion] {
        var out: [Suggestion] = []
        for sec in v["contents"]?.array ?? [] {
            for c in sec.pointer("/searchSuggestionsSectionRenderer/contents")?.array ?? [] {
                guard let fe = c.firstEntry else { continue }
            let (k, it) = (fe.key, fe.value)
                if k == "searchSuggestionRenderer" {
                    if let q = nonempty(strAt(it, "/navigationEndpoint/searchEndpoint/query") ?? text(it["suggestion"])) {
                        out.append(.query(q))
                    }
                } else if let e = entry(k, it) {
                    out.append(.entry(e))
                }
            }
        }
        return out
    }

    /// A music.youtube.com link → what it opens.
    public static func musicURL(_ input: String) -> Target? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = input.hasPrefix("music.youtube.com") ? "https://" + input : input
        guard let comps = URLComponents(string: withScheme), comps.host == "music.youtube.com" else { return nil }
        func q(_ k: String) -> String? { comps.queryItems?.first { $0.name == k }?.value }
        let segs = comps.path.split(separator: "/").map(String.init)
        switch segs.count {
        case 0: return .browseTo("FEmusic_home")
        case 1:
            switch segs[0] {
            case "watch": return .watch(videoId: q("v"), playlistId: q("list"), params: nil, index: nil)
            case "playlist": return q("list").map { .browseTo("VL\($0)") }
            case "search": return q("q").map { .search(query: $0, params: nil) }
            default: return nil
            }
        case 2 where segs[0] == "browse" || segs[0] == "channel":
            return .browseTo(segs[1])
        default:
            return nil
        }
    }

    /// A Music link for an item, for copying.
    public static func shareURL(_ t: Target) -> String? {
        switch t {
        case .browse(let id, _):
            if id.hasPrefix("VL") { return "https://music.youtube.com/playlist?list=\(id.dropFirst(2))" }
            if id.hasPrefix("UC") { return "https://music.youtube.com/channel/\(id)" }
            return "https://music.youtube.com/browse/\(id)"
        case .watch(let v, let p, _, _):
            if let v { return "https://music.youtube.com/watch?v=\(v)" + (p.map { "&list=\($0)" } ?? "") }
            return p.map { "https://music.youtube.com/playlist?list=\($0)" }
        case .search(let q, _):
            return "https://music.youtube.com/search?q=\(q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q)"
        }
    }
}
