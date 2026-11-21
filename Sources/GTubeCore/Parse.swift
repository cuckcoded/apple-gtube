import Foundation

/// Turns InnerTube JSON into models.
///
/// YouTube's response layout shifts constantly, so instead of following exact
/// paths the parsers walk the tree and pick out the renderers they understand,
/// wherever they live. Ads and Shorts are dropped during the walk.
public enum Parse {
    public struct Opts: Sendable {
        public var hideShorts: Bool
        public init(hideShorts: Bool) { self.hideShorts = hideShorts }
    }

    private static let counterLock = NSLock()
    nonisolated(unsafe) private static var _ads = 0
    nonisolated(unsafe) private static var _shorts = 0
    /// Ads and promotions removed this session.
    public static var adsBlocked: Int { counterLock.withLock { _ads } }
    /// Shorts removed this session.
    public static var shortsHidden: Int { counterLock.withLock { _shorts } }
    static func countAd() { counterLock.withLock { _ads += 1 } }
    static func countShort() { counterLock.withLock { _shorts += 1 } }

    /// Renderers that only ever carry ads or paid promotions.
    static let adKeys: Set<String> = [
        "adSlotRenderer", "promotedSparklesWebRenderer", "promotedSparklesTextSearchRenderer", "promotedVideoRenderer",
        "compactPromotedVideoRenderer", "compactPromotedItemRenderer", "searchPyvRenderer", "displayAdRenderer",
        "inFeedAdLayoutRenderer", "bannerPromoRenderer", "statementBannerRenderer", "brandVideoShelfRenderer",
        "brandVideoSingletonRenderer", "movieOfferModuleRenderer", "mealbarPromoRenderer", "adsEngagementPanelContentRenderer",
        "playerLegacyDesktopWatchAdsRenderer", "merchandiseShelfRenderer", "ticketShelfRenderer", "primetimePromoRenderer",
        "adBreakServiceRenderer", "playerAds", "adPlacements", "adSlots",
    ]

    /// Subtrees that never contain feed items (or contain items not wanted).
    static let skipKeys: Set<String> = [
        "frameworkUpdates", "responseContext", "topbar", "microformat", "trackingParams", "menu", "menuButton",
        "loggingDirectives", "engagementPanels", "playerOverlays", "accessibility", "commandMetadata",
        "backstagePostThreadRenderer", "postRenderer", "commentsEntryPointHeaderRenderer", "channelVideoPlayerRenderer",
        "unifiedSharePanelRenderer", "playlistPanelRenderer",
    ]

    static let shortsKeys: Set<String> = ["reelItemRenderer", "shortsLockupViewModel"]

    // MARK: Helpers

    public static func text(_ v: JSON?) -> String? {
        guard let v else { return nil }
        var s: String?
        switch v {
        case .string(let x): s = x
        case .object(let m):
            if let x = m["simpleText"]?.string {
                s = x
            } else if let runs = m["runs"]?.array {
                s = runs.compactMap { $0["text"]?.string }.joined()
            } else if let x = m["content"]?.string {
                s = x
            } else {
                s = text(m["text"])
            }
        default: s = nil
        }
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    static func textAt(_ v: JSON, _ ptr: String) -> String? { text(v.pointer(ptr)) }
    static func strAt(_ v: JSON, _ ptr: String) -> String? { v.pointer(ptr)?.string }

    public static func fixURL(_ u: String) -> String {
        u.hasPrefix("//") ? "https:" + u : u
    }

    /// The smallest thumbnail at least `target` px wide (or the largest one).
    public static func bestThumb(_ v: JSON, _ target: Int) -> String? {
        let arr: [JSON]
        if let a = v.array {
            arr = a
        } else if let a = v["thumbnails"]?.array {
            arr = a
        } else if let a = v["sources"]?.array {
            arr = a
        } else if let t = v["thumbnail"] {
            return bestThumb(t, target)
        } else if let t = v["image"] {
            return bestThumb(t, target)
        } else {
            return nil
        }
        var items: [(Int, String)] = arr.compactMap { t in
            guard let u = t["url"]?.string else { return nil }
            return (t["width"]?.uint ?? 0, u)
        }
        if items.isEmpty { return nil }
        items.sort { $0.0 < $1.0 }
        let pick = items.first { $0.0 >= target } ?? items.last!
        return fixURL(pick.1)
    }

    static func continuationToken(_ v: JSON) -> String? {
        guard let cmd = v.findFirst("continuationCommand") else { return nil }
        return cmd["token"]?.string ?? cmd.findFirst("token")?.string
    }

    static func browseId(_ v: JSON) -> String? {
        v.findFirst("browseEndpoint")?["browseId"]?.string
    }

    static func channelFromRuns(_ v: JSON?) -> (String?, String?) {
        guard let v else { return (nil, nil) }
        let name = v.pointer("/runs/0/text")?.string ?? text(v)
        let id = v.pointer("/runs/0/navigationEndpoint/browseEndpoint/browseId")?.string.flatMap { $0.hasPrefix("UC") ? $0 : nil }
        return (name, id)
    }

    static func isShortsEndpoint(_ v: JSON) -> Bool {
        if v["reelWatchEndpoint"] != nil { return true }
        return strAt(v, "/commandMetadata/webCommandMetadata/url")?.hasPrefix("/shorts/") ?? false
    }

    // MARK: Feed walker

    final class Walker {
        let opts: Opts
        var feed = Feed()
        var seen = Set<String>()

        init(_ opts: Opts) { self.opts = opts }

        func push(_ item: Item) {
            if case .video(let v) = item, v.isShort, opts.hideShorts {
                Parse.countShort()
                return
            }
            if seen.insert(item.id).inserted {
                feed.items.append(item)
            }
        }

        func walk(_ v: JSON) {
            switch v {
            case .array(let a): a.forEach(walk)
            case .object(let m):
                for k in m.keys.sorted() { visit(k, m[k]!) }
            default: break
            }
        }

        func visit(_ k: String, _ x: JSON) {
            if Parse.adKeys.contains(k) {
                Parse.countAd()
                return
            }
            if Parse.skipKeys.contains(k) { return }
            if Parse.shortsKeys.contains(k) {
                if opts.hideShorts {
                    Parse.countShort()
                } else if let v = Parse.short(k, x) {
                    push(.video(v))
                }
                return
            }
            switch k {
            case "reelShelfRenderer" where opts.hideShorts:
                Parse.countShort()
            case "videoRenderer", "gridVideoRenderer", "compactVideoRenderer", "playlistVideoRenderer", "videoWithContextRenderer":
                if let v = Parse.videoRenderer(x) { push(.video(v)) }
            case "lockupViewModel":
                if let item = Parse.lockup(x) { push(item) }
            case "channelRenderer", "gridChannelRenderer":
                if let c = Parse.channelRenderer(x) { push(.channel(c)) }
            case "playlistRenderer", "gridPlaylistRenderer", "compactPlaylistRenderer":
                if let p = Parse.playlistRenderer(x) { push(.playlist(p)) }
            case "continuationItemRenderer", "continuationItemViewModel":
                if let t = Parse.continuationToken(x) { feed.continuation = t }
            case "nextContinuationData":
                if let t = x["continuation"]?.string { feed.continuation = t }
            case "chipCloudChipRenderer":
                if let title = Parse.text(x["text"]), let token = x["navigationEndpoint"].flatMap(Parse.continuationToken) {
                    feed.chips.append(Chip(title: title, token: token, selected: x["isSelected"]?.bool ?? false))
                }
            case "chipViewModel":
                if let title = Parse.text(x["text"]), let token = x["tapCommand"].flatMap(Parse.continuationToken) {
                    feed.chips.append(Chip(title: title, token: token, selected: x["selected"]?.bool ?? false))
                }
            default:
                walk(x)
            }
        }
    }

    /// Any browse/search/continuation response as a feed.
    public static func feed(_ root: JSON, _ opts: Opts) -> Feed {
        let w = Walker(opts)
        for key in ["contents", "onResponseReceivedActions", "onResponseReceivedEndpoints", "onResponseReceivedCommands", "continuationContents"] {
            if let v = root[key] { w.walk(v) }
        }
        return w.feed
    }

    static func feedFrom(_ v: JSON, _ opts: Opts) -> Feed {
        let w = Walker(opts)
        w.walk(v)
        return w.feed
    }

    // MARK: Item renderers

    static func videoRenderer(_ v: JSON) -> VideoItem? {
        guard let id = v["videoId"]?.string else { return nil }
        if v["isPlayable"]?.bool == false { return nil }
        guard let title = text(v["title"]) ?? text(v["headline"]) else { return nil }
        let byline = v["longBylineText"] ?? v["ownerText"] ?? v["shortBylineText"]
        var (channelName, channelId) = channelFromRuns(byline)
        let avatarSrc = v.pointer("/channelThumbnailSupportedRenderers/channelThumbnailWithLinkRenderer") ?? v["channelThumbnail"]
        let avatar = avatarSrc.flatMap { bestThumb($0, 68) }
        if channelId == nil {
            channelId = avatarSrc.flatMap(browseId).flatMap { $0.hasPrefix("UC") ? $0 : nil }
        }
        var duration = text(v["lengthText"])
        var isLive = false
        var isShort = false
        var progress: Double?
        for o in v["thumbnailOverlays"]?.array ?? [] {
            if let ts = o["thumbnailOverlayTimeStatusRenderer"] {
                switch ts["style"]?.string {
                case "LIVE": isLive = true
                case "SHORTS": isShort = true
                default: break
                }
                if duration == nil { duration = text(ts["text"]) }
            }
            if let p = o.pointer("/thumbnailOverlayResumePlaybackRenderer/percentDurationWatched")?.double {
                progress = p / 100
            }
        }
        for b in v["badges"]?.array ?? [] where strAt(b, "/metadataBadgeRenderer/style") == "BADGE_STYLE_TYPE_LIVE_NOW" {
            isLive = true
        }
        if let ep = v["navigationEndpoint"], isShortsEndpoint(ep) { isShort = true }
        if v["upcomingEventData"] != nil && duration == nil { duration = "Upcoming" }
        var views: String?
        var published: String?
        if let info = text(v["videoInfo"]) {
            views = info
        } else {
            views = text(v["shortViewCountText"]) ?? text(v["viewCountText"])
            published = text(v["publishedTimeText"])
        }
        var item = VideoItem(id: id, title: title)
        item.channelName = channelName
        item.channelId = channelId
        item.channelAvatar = avatar
        item.thumbnail = v["thumbnail"].flatMap { bestThumb($0, 480) }
        item.duration = isLive ? "LIVE" : duration
        item.views = views
        item.published = published
        item.isLive = isLive
        item.isShort = isShort
        item.progress = progress
        item.setVideoId = v["setVideoId"]?.string
        return item
    }

    struct MetaPart {
        var text: String
        var browseId: String?
        var a11y: String?
        var hasIcon: Bool
    }

    static func lockupRows(_ meta: JSON) -> [[MetaPart]] {
        guard let rows = meta.pointer("/metadata/contentMetadataViewModel/metadataRows")?.array else { return [] }
        return rows.map { row in
            (row["metadataParts"]?.array ?? []).compactMap { p -> MetaPart? in
                guard let t = p["text"], let s = text(t) else { return nil }
                return MetaPart(text: s, browseId: browseId(t), a11y: p["accessibilityLabel"]?.string, hasIcon: p["leadingIcon"] != nil)
            }
        }.filter { !$0.isEmpty }
    }

    static func lockup(_ v: JSON) -> Item? {
        let contentType = v["contentType"]?.string ?? ""
        guard let id = v["contentId"]?.string,
              let meta = v.pointer("/metadata/lockupMetadataViewModel"),
              let title = text(meta["title"]) else { return nil }
        let rows = lockupRows(meta)
        let image = v.pointer("/contentImage/thumbnailViewModel/image")
            ?? v.pointer("/contentImage/collectionThumbnailViewModel/primaryThumbnail/thumbnailViewModel/image")
        let thumbnail = image.flatMap { bestThumb($0, 480) }
        let badges = v["contentImage"]?.findAll("thumbnailBadgeViewModel") ?? []
        let badgeText = badges.lazy.compactMap { text($0["text"]) }.first
        let isLive = badges.contains { $0["badgeStyle"]?.string?.contains("LIVE") ?? false }
        var progress: Double?
        if let pb = v["contentImage"]?.findFirst("thumbnailOverlayProgressBarViewModel") {
            progress = pb["startPercent"]?.double.map { $0 / 100 }
        }
        let onTap = v.pointer("/rendererContext/commandContext/onTap/innertubeCommand")
        let avatarVM = meta.pointer("/image/decoratedAvatarViewModel")
        let avatar = avatarVM?.pointer("/avatar/avatarViewModel/image").flatMap { bestThumb($0, 68) }
        let avatarChannel = avatarVM.flatMap(browseId).flatMap { $0.hasPrefix("UC") ? $0 : nil }

        switch contentType {
        case "LOCKUP_CONTENT_TYPE_VIDEO", "LOCKUP_CONTENT_TYPE_EPISODE", "":
            let isShort = onTap.map(isShortsEndpoint) ?? false
            // With two or more rows the first one is the channel; a single row
            // (e.g. on a channel's own Videos tab) only holds views and age.
            let channelRow: [MetaPart]? = rows.count >= 2 ? rows[0] : nil
            let statRows = rows.count >= 2 ? Array(rows[1...]) : rows
            let channelName = channelRow?.first?.text
            let channelId = channelRow?.lazy.compactMap(\.browseId).first.flatMap { $0.hasPrefix("UC") ? $0 : nil } ?? avatarChannel
            let stats = statRows.flatMap { $0 }.map { $0.hasIcon ? ($0.a11y ?? $0.text) : $0.text }
            var views: String?
            var published: String?
            if stats.count == 1 {
                views = stats[0]
            } else if stats.count > 1 {
                views = stats[0]
                published = stats[1...].joined(separator: " • ")
            }
            var item = VideoItem(id: id, title: title)
            item.channelName = channelName
            item.channelId = channelId
            item.channelAvatar = avatar
            item.thumbnail = thumbnail
            item.duration = badgeText
            item.views = views
            item.published = published
            item.isLive = isLive
            item.isShort = isShort
            item.progress = progress
            // In the owner's playlist, its "Remove" command names the entry.
            item.setVideoId = v.findFirst("setVideoId")?.string
            return .video(item)
        case "LOCKUP_CONTENT_TYPE_PLAYLIST", "LOCKUP_CONTENT_TYPE_PODCAST", "LOCKUP_CONTENT_TYPE_ALBUM":
            let owner = rows.flatMap { $0 }.first { $0.browseId?.hasPrefix("UC") ?? false }
            var p = PlaylistItem(id: id, title: title)
            p.thumbnail = thumbnail
            p.videoCount = badgeText
            p.channelName = owner?.text
            p.channelId = owner?.browseId
            p.videoId = onTap?.findFirst("watchEndpoint")?["videoId"]?.string
            return .playlist(p)
        default:
            return nil
        }
    }

    static func short(_ kind: String, _ v: JSON) -> VideoItem? {
        if kind == "shortsLockupViewModel" {
            guard let id = v["onTap"]?.findFirst("reelWatchEndpoint")?["videoId"]?.string,
                  let title = textAt(v, "/overlayMetadata/primaryText") else { return nil }
            var item = VideoItem(id: id, title: title)
            item.views = textAt(v, "/overlayMetadata/secondaryText")
            item.thumbnail = v["thumbnail"].flatMap { bestThumb($0, 480) }
            item.duration = "Short"
            item.isShort = true
            return item
        }
        guard let id = v["videoId"]?.string, let title = text(v["headline"]) else { return nil }
        var item = VideoItem(id: id, title: title)
        item.views = text(v["viewCountText"])
        item.thumbnail = v["thumbnail"].flatMap { bestThumb($0, 480) }
        item.duration = "Short"
        item.isShort = true
        return item
    }

    static func channelRenderer(_ v: JSON) -> ChannelItem? {
        guard let id = v["channelId"]?.string, let title = text(v["title"]) else { return nil }
        let subText = text(v["subscriberCountText"])
        let videoText = text(v["videoCountText"])
        // Search results put the @handle in subscriberCountText and the
        // subscriber count in videoCountText.
        var c = ChannelItem()
        c.id = id
        c.title = title
        if let s = subText, s.hasPrefix("@") {
            c.handle = s
            c.subscribers = videoText
        } else {
            c.subscribers = subText
        }
        c.avatar = v["thumbnail"].flatMap { bestThumb($0, 176) }
        c.description = text(v["descriptionSnippet"])
        return c
    }

    static func playlistRenderer(_ v: JSON) -> PlaylistItem? {
        guard let id = v["playlistId"]?.string, let title = text(v["title"]) else { return nil }
        let thumb = v.pointer("/thumbnails/0") ?? v["thumbnail"] ?? v["thumbnailRenderer"]?.findFirst("thumbnail")
        let (channelName, channelId) = channelFromRuns(v["shortBylineText"] ?? v["longBylineText"])
        var p = PlaylistItem(id: id, title: title)
        p.videoId = v["navigationEndpoint"]?.findFirst("watchEndpoint")?["videoId"]?.string
        p.thumbnail = thumb.flatMap { bestThumb($0, 480) }
        p.videoCount = text(v["videoCountText"]) ?? text(v["videoCountShortText"]) ?? v["videoCount"]?.string.map { "\($0) videos" }
        p.channelName = channelName
        p.channelId = channelId
        return p
    }

    // MARK: Watch page

    /// Where an InnerTube command leads, as a link the UI understands.
    static func commandTarget(_ cmd: JSON, videoId: String) -> String? {
        if let w = cmd["watchEndpoint"] {
            guard let vid = w["videoId"]?.string else { return nil }
            let t = w["startTimeSeconds"]?.uint
            if vid == videoId { return "seek:\(t ?? 0)" }
            if let t, t > 0 { return "https://www.youtube.com/watch?v=\(vid)&t=\(t)s" }
            return "https://www.youtube.com/watch?v=\(vid)"
        }
        guard var url = (cmd.pointer("/urlEndpoint/url") ?? cmd.pointer("/commandMetadata/webCommandMetadata/url"))?.string else { return nil }
        if url.hasPrefix("/") { url = "https://www.youtube.com" + url }
        guard let comps = URLComponents(string: url) else { return nil }
        if comps.path == "/redirect", let q = comps.queryItems?.first(where: { $0.name == "q" })?.value {
            return q
        }
        if comps.path.hasPrefix("/hashtag/") {
            let tag = String(comps.path.dropFirst("/hashtag/".count))
            return "search:" + ("#" + tag).addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        }
        return url
    }

    static func descriptionLinks(_ ad: JSON, content: String, videoId: String) -> [DescriptionLink] {
        let n = content.utf16.count
        var out: [DescriptionLink] = []
        for run in ad["commandRuns"]?.array ?? [] {
            guard let start = run["startIndex"]?.uint, let len = run["length"]?.uint,
                  let cmd = run.pointer("/onTap/innertubeCommand"), start + len <= n,
                  let target = commandTarget(cmd, videoId: videoId) else { continue }
            out.append(DescriptionLink(start: start, length: len, target: target))
        }
        out.sort { $0.start < $1.start }
        // Drop overlapping runs.
        var end = 0
        return out.filter { l in
            let ok = l.start >= end
            if ok { end = l.start + l.length }
            return ok
        }
    }

    /// The playlist panel of a `next` response for a playlist or mix.
    public static func playlistPanel(_ root: JSON) -> PlaylistPanel? {
        guard let pl = root.pointer("/contents/twoColumnWatchNextResults/playlist/playlist"),
              let contents = pl["contents"]?.array,
              let pid = pl["playlistId"]?.string else { return nil }
        let items: [VideoItem] = contents.compactMap { $0["playlistPanelVideoRenderer"] }.compactMap { r in
            guard let id = r["videoId"]?.string else { return nil }
            let (cn, cid) = channelFromRuns(r["shortBylineText"] ?? r["longBylineText"])
            var v = VideoItem(id: id, title: text(r["title"]) ?? "")
            v.channelName = cn
            v.channelId = cid
            v.thumbnail = r["thumbnail"].flatMap { bestThumb($0, 336) }
            v.duration = text(r["lengthText"])
            return v
        }
        var current = strAt(root, "/currentVideoEndpoint/watchEndpoint/videoId").flatMap { id in items.firstIndex { $0.id == id } }
            ?? pl["currentIndex"]?.uint ?? 0
        current = min(current, max(items.count - 1, 0))
        var p = PlaylistPanel()
        p.id = pid
        p.title = text(pl["title"]) ?? text(pl["titleText"]) ?? ""
        p.owner = text(pl["ownerName"]) ?? text(pl["shortBylineText"])
        p.items = items
        p.current = current
        p.infinite = pl["isInfinite"]?.bool ?? false
        p.total = pl["totalVideos"]?.uint
        return p
    }

    public static func next(_ root: JSON, _ opts: Opts) -> VideoDetails {
        var d = VideoDetails()
        d.id = strAt(root, "/currentVideoEndpoint/watchEndpoint/videoId") ?? ""
        let results = root.pointer("/contents/twoColumnWatchNextResults/results/results/contents")
        let primary = results?.findFirst("videoPrimaryInfoRenderer")
        let secondary = results?.findFirst("videoSecondaryInfoRenderer")
        if let p = primary {
            d.title = text(p["title"]) ?? ""
            let vc = p.pointer("/viewCount/videoViewCountRenderer")
            d.views = text(vc?["viewCount"])
            d.isLive = vc?["isLive"]?.bool ?? false
            d.date = text(p["dateText"])
            d.relativeDate = text(p["relativeDateText"])
            if let lb = p.findFirst("likeButtonViewModel") {
                let buttons = lb.findAll("buttonViewModel")
                let b = buttons.first { $0["iconName"]?.string == "LIKE" } ?? buttons.first
                d.likes = text(b?["title"])
                d.likeStatus = lb.findFirst("likeStatusEntity")?["likeStatus"]?.string
            }
        }
        if let s = secondary {
            if let o = s.pointer("/owner/videoOwnerRenderer") {
                d.channel.title = text(o["title"]) ?? ""
                d.channel.id = browseId(o["title"] ?? o) ?? browseId(o) ?? ""
                d.channel.avatar = o["thumbnail"].flatMap { bestThumb($0, 88) }
                d.channel.subscribers = text(o["subscriberCountText"])
            }
            if let ad = s["attributedDescription"], let content = ad["content"]?.string {
                d.description = content
                d.descriptionLinks = descriptionLinks(ad, content: content, videoId: d.id)
            } else {
                d.description = text(s["description"]) ?? ""
            }
            d.subscribed = s.findFirst("subscribeButtonRenderer")?["subscribed"]?.bool
        }
        if let b = root["frameworkUpdates"]?.findFirst("subscriptionStateEntity")?["subscribed"]?.bool {
            d.subscribed = b
        }
        if let r = results {
            d.commentsToken = r.findAll("itemSectionRenderer")
                .first { $0["sectionIdentifier"]?.string == "comment-item-section" }
                .flatMap(continuationToken)
        }
        for p in root["engagementPanels"]?.array ?? [] {
            guard let panel = p["engagementPanelSectionListRenderer"],
                  panel["panelIdentifier"]?.string == "engagement-panel-comments-section" else { continue }
            d.commentsCount = textAt(panel, "/header/engagementPanelTitleHeaderRenderer/contextualInfo")
            if let items = panel.findFirst("sortFilterSubMenuRenderer")?["subMenuItems"]?.array {
                for it in items {
                    if let t = text(it["title"]), let tok = it["serviceEndpoint"].flatMap(continuationToken) {
                        d.commentSorts.append((t, tok))
                    }
                }
            }
        }
        if let sec = root.pointer("/contents/twoColumnWatchNextResults/secondaryResults") {
            d.related = feedFrom(sec, opts)
            d.related.chips = []
        }
        return d
    }

    // MARK: Comments

    public static func comments(_ root: JSON) -> CommentsPage {
        var entities: [String: JSON] = [:]
        for m in root.pointer("/frameworkUpdates/entityBatchUpdate/mutations")?.array ?? [] {
            if let k = m["entityKey"]?.string, let p = m["payload"] { entities[k] = p }
        }
        var page = CommentsPage()
        var items: [JSON] = []
        for key in ["onResponseReceivedEndpoints", "onResponseReceivedActions"] {
            for ep in root[key]?.array ?? [] {
                let list = ep.pointer("/reloadContinuationItemsCommand/continuationItems") ?? ep.pointer("/appendContinuationItemsAction/continuationItems")
                items += list?.array ?? []
            }
        }
        for it in items {
            if let thread = it["commentThreadRenderer"] {
                let repliesToken = thread["replies"].flatMap(continuationToken)
                let c: Comment?
                if let vm = thread.pointer("/commentViewModel/commentViewModel") {
                    c = commentFromViewModel(vm, entities)
                } else {
                    c = thread.pointer("/comment/commentRenderer").flatMap(commentFromRenderer)
                }
                if var c {
                    c.repliesToken = repliesToken
                    page.comments.append(c)
                }
            } else if let vm = it["commentViewModel"] {
                if let c = commentFromViewModel(vm, entities) { page.comments.append(c) }
            } else if let r = it["commentRenderer"] {
                if let c = commentFromRenderer(r) { page.comments.append(c) }
            } else if it["continuationItemRenderer"] != nil {
                page.continuation = continuationToken(it)
            }
        }
        return page
    }

    static func commentFromViewModel(_ vm: JSON, _ entities: [String: JSON]) -> Comment? {
        guard let key = vm["commentKey"]?.string,
              let payload = entities[key]?["commentEntityPayload"],
              let props = payload["properties"] else { return nil }
        let author = payload["author"]
        let toolbar = payload["toolbar"]
        let hearted = vm["toolbarStateKey"]?.string.flatMap { entities[$0] }?
            .pointer("/engagementToolbarStateEntityPayload/heartState")?.string == "TOOLBAR_HEART_STATE_HEARTED"
        func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty || $0 == "0" ? nil : $0 } }
        var c = Comment()
        c.author = author?["displayName"]?.string ?? "Unknown"
        c.authorChannelId = author?["channelId"]?.string
        c.avatar = author?["avatarThumbnailUrl"]?.string.map(fixURL) ?? payload["avatar"].flatMap { bestThumb($0, 88) }
        c.text = props.pointer("/content/content")?.string ?? ""
        c.published = props["publishedTime"]?.string ?? ""
        c.likes = nonEmpty(toolbar?["likeCountNotliked"]?.string)
        c.replyCount = nonEmpty(toolbar?["replyCount"]?.string)
        c.isCreator = author?["isCreator"]?.bool ?? false
        c.isVerified = author?["isVerified"]?.bool ?? false
        c.pinned = text(vm["pinnedText"])
        c.hearted = hearted
        return c
    }

    static func commentFromRenderer(_ r: JSON) -> Comment? {
        guard r["commentId"] != nil else { return nil }
        var c = Comment()
        c.author = text(r["authorText"]) ?? "Unknown"
        c.authorChannelId = r.pointer("/authorEndpoint/browseEndpoint/browseId")?.string
        c.avatar = r["authorThumbnail"].flatMap { bestThumb($0, 88) }
        c.text = text(r["contentText"]) ?? ""
        c.published = text(r["publishedTimeText"]) ?? ""
        c.likes = text(r["voteCount"])
        if let rc = r["replyCount"] { c.replyCount = rc.uint.map(String.init) ?? text(rc) }
        c.isCreator = r["authorIsChannelOwner"]?.bool ?? false
        c.pinned = r["pinnedCommentBadge"] != nil ? "Pinned" : nil
        c.hearted = r.pointer("/actionButtons/commentActionButtonsRenderer/creatorHeart") != nil
        return c
    }

    // MARK: Channel and playlist pages

    public static func channel(_ root: JSON) -> ChannelPage {
        var page = ChannelPage()
        if let m = root.pointer("/metadata/channelMetadataRenderer") {
            page.info.id = m["externalId"]?.string ?? ""
            page.info.title = m["title"]?.string ?? ""
            page.info.description = m["description"]?.string
            page.info.avatar = m["avatar"].flatMap { bestThumb($0, 176) }
            page.info.handle = m["vanityChannelUrl"]?.string?.split(separator: "/").last.map(String.init).flatMap { $0.hasPrefix("@") ? $0 : nil }
        }
        if let header = root["header"] {
            if let ph = header.findFirst("pageHeaderViewModel") {
                if page.info.title.isEmpty { page.info.title = textAt(ph, "/title/dynamicTextViewModel/text") ?? "" }
                if let img = ph.pointer("/image/decoratedAvatarViewModel/avatar/avatarViewModel/image") {
                    page.info.avatar = bestThumb(img, 176) ?? page.info.avatar
                }
                if let b = ph.findFirst("imageBannerViewModel") {
                    page.banner = b["image"].flatMap { bestThumb($0, 2120) }
                }
                var others: [String] = []
                for row in lockupRows(ph) {
                    for p in row {
                        if p.text.hasPrefix("@") { page.info.handle = p.text } else { others.append(p.text) }
                    }
                }
                page.info.subscribers = others.first
                page.videoCount = others.count > 1 ? others[1] : nil
            } else if let c4 = header["c4TabbedHeaderRenderer"] {
                page.info.subscribers = text(c4["subscriberCountText"])
                page.videoCount = text(c4["videosCountText"])
                page.info.handle = text(c4["channelHandleText"]) ?? page.info.handle
                page.banner = c4["banner"].flatMap { bestThumb($0, 2120) }
            }
        }
        for t in root["contents"]?.findAll("tabRenderer") ?? [] {
            if let title = text(t["title"]), let params = strAt(t, "/endpoint/browseEndpoint/params") {
                page.tabs.append((title, params))
            }
        }
        page.subscribed = root["frameworkUpdates"]?.findFirst("subscriptionStateEntity")?["subscribed"]?.bool
            ?? root["header"]?.findFirst("subscribeButtonRenderer")?["subscribed"]?.bool
        return page
    }

    public static func playlist(_ root: JSON, id: String, _ opts: Opts) -> PlaylistPage {
        var page = PlaylistPage(id: id)
        if let m = root.pointer("/metadata/playlistMetadataRenderer") {
            page.title = m["title"]?.string ?? ""
            page.description = m["description"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let header = root["header"] {
            if let ph = header.findFirst("pageHeaderViewModel") {
                if page.title.isEmpty { page.title = textAt(ph, "/title/dynamicTextViewModel/text") ?? "" }
                if let stack = ph.findFirst("avatarStackViewModel") {
                    page.owner = text(stack["text"])
                    page.ownerId = browseId(stack).flatMap { $0.hasPrefix("UC") ? $0 : nil }
                }
                for row in lockupRows(ph) {
                    for p in row where p.text != page.owner && !p.text.hasPrefix("by ") {
                        page.stats.append(p.text)
                    }
                }
                if let hero = ph.findFirst("contentPreviewImageViewModel") {
                    page.thumbnail = hero["image"].flatMap { bestThumb($0, 480) }
                }
            } else if let h = header["playlistHeaderRenderer"] {
                if page.title.isEmpty { page.title = text(h["title"]) ?? "" }
                (page.owner, page.ownerId) = channelFromRuns(h["ownerText"])
                if let s = text(h["numVideosText"]) { page.stats.append(s) }
            }
        }
        if page.thumbnail == nil, let t = root["sidebar"]?.findFirst("playlistVideoThumbnailRenderer") {
            page.thumbnail = bestThumb(t, 480)
        }
        page.feed = feed(root, opts)
        page.feed.chips = []
        if let l = root.findFirst("playlistVideoListRenderer") {
            page.editable = l["isEditable"]?.bool ?? false
        } else {
            // Newer pages: only the owner's entries carry a set id.
            page.editable = page.feed.items.contains { $0.video?.setVideoId != nil }
        }
        page.privacy = root["header"]?.findFirst("privacy")?.string
            ?? page.stats.lazy.compactMap { ["Public", "Unlisted", "Private"].contains($0) ? $0.uppercased() : nil }.first
        return page
    }

    /// The user's playlists from `playlist/get_add_to_playlist`.
    public static func saveTargets(_ root: JSON) -> [SaveTarget] {
        root.findAll("playlistAddToOptionRenderer").compactMap { o in
            guard let id = o["playlistId"]?.string, let title = text(o["title"]) else { return nil }
            return SaveTarget(id: id, title: title, saved: o["containsSelectedVideos"]?.string == "ALL")
        }
    }

    public static func account(_ root: JSON) -> Account? {
        guard let h = root.findFirst("activeAccountHeaderRenderer"), let name = text(h["accountName"]) else { return nil }
        let ids = root.findAll("browseEndpoint").compactMap { $0["browseId"]?.string }
        return Account(name: name, handle: text(h["channelHandle"]), avatar: h["accountPhoto"].flatMap { bestThumb($0, 88) },
                       channelId: ids.first { $0.hasPrefix("UC") })
    }

    // MARK: URLs

    /// Parses a YouTube URL locally, without any network request. Handles
    /// (and other pages) come back as `.search` to be resolved through the API.
    public static func youtubeURL(_ input: String) -> Resolved? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme: String
        if input.hasPrefix("http://") || input.hasPrefix("https://") {
            withScheme = input
        } else if ["www.", "youtube.com", "youtu.be", "m.youtube.com", "music.youtube.com"].contains(where: input.hasPrefix) {
            withScheme = "https://" + input
        } else {
            return nil
        }
        guard let comps = URLComponents(string: withScheme), var host = comps.host else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.hasPrefix("m.") { host.removeFirst(2) }
        func q(_ k: String) -> String? { comps.queryItems?.first { $0.name == k }?.value }
        let start = q("t").flatMap(parseTimeParam)
        let segs = comps.path.split(separator: "/").map(String.init)
        if host == "youtu.be" {
            return segs.first.map { .video(id: $0, playlist: q("list"), start: start) }
        }
        if !host.hasSuffix("youtube.com") && !host.hasSuffix("youtube-nocookie.com") { return nil }
        switch segs.first ?? "" {
        case "watch" where segs.count == 1:
            return q("v").map { .video(id: $0, playlist: q("list"), start: start) }
        case "shorts", "live", "embed", "v":
            if segs.count >= 2 { return .video(id: segs[1], playlist: nil, start: start) }
        case "playlist" where segs.count == 1:
            return q("list").map { .playlist($0) }
        case "channel":
            if segs.count >= 2 { return .channel(segs[1]) }
        default:
            break
        }
        return .search(withScheme)
    }

    static func parseTimeParam(_ t: String) -> Double? {
        var s = Substring(t)
        if s.hasSuffix("s") { s = s.dropLast() }
        if let n = Double(s) { return n }
        guard let re = try? NSRegularExpression(pattern: #"^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$"#),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
        func g(_ i: Int) -> Double {
            guard let r = Range(m.range(at: i), in: t) else { return 0 }
            return Double(t[r]) ?? 0
        }
        return g(1) * 3600 + g(2) * 60 + g(3)
    }
}
