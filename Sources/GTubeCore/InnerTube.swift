import CryptoKit
import Foundation

/// A request YouTube answered with an error status.
public struct HTTPStatusError: Error, LocalizedError, Sendable {
    public let status: Int
    public var errorDescription: String? { "YouTube returned HTTP \(status)" }
}

public struct APIError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

public let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:140.0) Gecko/20100101 Firefox/140.0"
let webOrigin = "https://www.youtube.com"
let musicOrigin = "https://music.youtube.com"
let fallbackClientVersion = "2.20261112.10.00"
let musicFallbackClientVersion = "1.20261110.04.00"

/// Which web client a request impersonates: youtube.com or YouTube Music.
public enum Flavor: Sendable {
    case web, music
    var origin: String { self == .web ? webOrigin : musicOrigin }
}

public struct Session: Sendable {
    public var cookies: CookieJar
    public var clientVersion = fallbackClientVersion
    public var visitorData: String?
    public var userSessionId: String?
    public var delegatedSessionId: String?
    public var sessionIndex = "0"
    public var loggedIn: Bool
    public var hl: String
    public var gl: String
    public var musicClientVersion = musicFallbackClientVersion
    /// music.youtube.com's config was fetched (or that was attempted).
    public var musicBootstrapped = false
    /// The player script's signature timestamp (youtube.com's `STS`).
    public var sts: Int?
}

public enum LikeAction: Sendable { case like, dislike, remove }

/// A change to one of the user's playlists. Entries are named by their set id.
public enum PlaylistEdit: Sendable {
    case add(String)
    /// Removes an entry, or (without one) the video.
    case remove(videoId: String, setId: String?)
    /// Moves entry `.0` just before entry `.1`.
    case moveBefore(String, String)
    /// Moves entry `.0` just after entry `.1`.
    case moveAfter(String, String)
    case name(String)
    case description(String)
    /// PUBLIC, UNLISTED or PRIVATE.
    case privacy(String)

    var action: [String: Any] {
        switch self {
        case .add(let id): return ["action": "ACTION_ADD_VIDEO", "addedVideoId": id]
        case .remove(let v, .some(let s)): return ["action": "ACTION_REMOVE_VIDEO", "setVideoId": s, "removedVideoId": v]
        case .remove(let v, .none): return ["action": "ACTION_REMOVE_VIDEO_BY_VIDEO_ID", "removedVideoId": v]
        case .moveBefore(let s, let next): return ["action": "ACTION_MOVE_VIDEO_BEFORE", "setVideoId": s, "movedSetVideoIdSuccessor": next]
        case .moveAfter(let s, let prev): return ["action": "ACTION_MOVE_VIDEO_AFTER", "setVideoId": s, "movedSetVideoIdPredecessor": prev]
        case .name(let t): return ["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": t]
        case .description(let t): return ["action": "ACTION_SET_PLAYLIST_DESCRIPTION", "playlistDescription": t]
        case .privacy(let p): return ["action": "ACTION_SET_PLAYLIST_PRIVACY", "playlistPrivacy": p]
        }
    }
}

/// A value from the page's `ytcfg` ("KEY": "value" | true | 123).
func ytcfgValue(_ html: String, _ key: String) -> String? {
    let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*:\\s*(\"(?:[^\"\\\\]|\\\\.)*\"|true|false|-?\\d+)"
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
          let r = Range(m.range(at: 1), in: html) else { return nil }
    let raw = String(html[r])
    if raw.hasPrefix("\"") {
        return (try? JSON(string: raw))?.string
    }
    return raw
}

/// The InnerTube (YouTube's internal web API) client.
///
/// Requests are made as the regular desktop web client. When signed in, the
/// browser session cookies are sent along with the `SAPISIDHASH`
/// authorization the website computes, so feeds, history and playlists match
/// youtube.com.
public final class Client: @unchecked Sendable {
    public static let shared = Client()

    public let http: URLSession
    private let lock = NSLock()
    private var _session: Session

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 30
        cfg.httpAdditionalHeaders = ["User-Agent": userAgent]
        cfg.httpMaximumConnectionsPerHost = 8
        http = URLSession(configuration: cfg)
        let s = Config.settings
        _session = Session(cookies: CookieJar(), loggedIn: false, hl: s.language, gl: s.region)
    }

    public var session: Session {
        lock.lock(); defer { lock.unlock() }
        return _session
    }

    private func mutate<T>(_ f: (inout Session) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return f(&_session)
    }

    public var isLoggedIn: Bool { session.loggedIn }

    func setSTS(_ sts: Int) { mutate { $0.sts = sts } }

    public func setCookies(_ jar: CookieJar) {
        var jar = jar
        // Pre-answer the EU cookie consent wall ("reject all"), like yt-dlp does.
        if jar.value("www.youtube.com", "SOCS") == nil && jar.value("www.youtube.com", "CONSENT") == nil {
            jar.set(".youtube.com", "SOCS", "CAI")
        }
        mutate { s in
            s.loggedIn = jar.hasLogin
            s.cookies = jar
            s.userSessionId = nil
            s.delegatedSessionId = nil
            s.sessionIndex = "0"
        }
    }

    public func setLocale(hl: String, gl: String) {
        mutate { s in
            s.hl = hl
            s.gl = gl
        }
    }

    // MARK: Plain HTTP

    public func get(_ url: String, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard let u = URL(string: url) else { throw APIError("Bad URL") }
        var req = URLRequest(url: u)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await http.data(for: req)
        guard let h = resp as? HTTPURLResponse else { throw APIError("No HTTP response") }
        return (data, h)
    }

    public func getText(_ url: String, headers: [String: String] = [:]) async throws -> String {
        let (d, _) = try await get(url, headers: headers)
        return String(decoding: d, as: UTF8.self)
    }

    // MARK: Bootstrap

    /// Loads youtube.com once to learn the current client version, visitor id
    /// and account session ids, exactly like the website bootstraps itself.
    public func bootstrap() async throws {
        let (cookie, hl) = (session.cookies.header(for: "www.youtube.com"), session.hl)
        let html = try await getText("\(webOrigin)/?hl=\(hl)", headers: ["Cookie": cookie, "Accept-Language": "\(hl),en;q=0.8"])
        let summary: String = mutate { s in
            if let v = ytcfgValue(html, "INNERTUBE_CLIENT_VERSION") { s.clientVersion = v }
            s.visitorData = ytcfgValue(html, "VISITOR_DATA")
            if let sts = ytcfgValue(html, "STS").flatMap({ Int($0) }) { s.sts = sts }
            if let idx = ytcfgValue(html, "SESSION_INDEX"), !idx.isEmpty { s.sessionIndex = idx }
            var channelSync: String?
            var userSync: String?
            if let d = ytcfgValue(html, "DATASYNC_ID") {
                let parts = d.components(separatedBy: "||")
                let a = parts.first ?? d
                let b = parts.count > 1 ? parts[1] : ""
                channelSync = a.isEmpty ? nil : a
                userSync = b.isEmpty ? nil : b
            }
            s.userSessionId = ytcfgValue(html, "USER_SESSION_ID") ?? userSync ?? channelSync
            if let d = ytcfgValue(html, "DELEGATED_SESSION_ID"), !d.isEmpty {
                s.delegatedSessionId = d
            } else {
                s.delegatedSessionId = userSync != nil ? channelSync : nil
            }
            if let li = ytcfgValue(html, "LOGGED_IN") {
                s.loggedIn = li == "true" && s.cookies.hasLogin
            }
            if s.cookies.hasLogin && !s.loggedIn {
                return "bootstrap: session cookies are present but YouTube treats this session as signed out (expired or revoked?)"
            }
            return "bootstrap: signed in: \(s.loggedIn), client \(s.clientVersion), delegated account: \(s.delegatedSessionId != nil)"
        }
        Log.info(summary)
    }

    /// Picks up YouTube Music's current client version (once per session).
    private func musicBootstrap() async {
        let start: (String, String)? = mutate { s in
            if s.musicBootstrapped { return nil }
            s.musicBootstrapped = true
            return (s.cookies.header(for: "music.youtube.com"), s.hl)
        }
        guard let start else { return }
        let (cookie, hl) = start
        do {
            let html = try await getText("\(musicOrigin)/?hl=\(hl)", headers: ["Cookie": cookie, "Accept-Language": "\(hl),en;q=0.8"])
            let v = mutate { s -> String in
                if let v = ytcfgValue(html, "INNERTUBE_CLIENT_VERSION") { s.musicClientVersion = v }
                if s.visitorData == nil { s.visitorData = ytcfgValue(html, "VISITOR_DATA") }
                return s.musicClientVersion
            }
            Log.info("music bootstrap: client \(v)")
        } catch {
            Log.warn("music bootstrap failed: \(error.localizedDescription)")
        }
    }

    static func sidAuthorization(_ s: Session, origin: String) -> String? {
        let ts = String(nowSecs())
        var parts: [String] = []
        for (scheme, name) in [("SAPISIDHASH", "SAPISID"), ("SAPISID1PHASH", "__Secure-1PAPISID"), ("SAPISID3PHASH", "__Secure-3PAPISID")] {
            guard let sid = s.cookies.value("www.youtube.com", name) else { continue }
            var input: [String] = []
            if let u = s.userSessionId { input.append(u) }
            input += [ts, sid, origin]
            let digest = Insecure.SHA1.hash(data: Data(input.joined(separator: " ").utf8))
            let hash = digest.map { String(format: "%02x", $0) }.joined()
            let suffix = s.userSessionId != nil ? "_u" : ""
            parts.append("\(scheme) \(ts)_\(hash)\(suffix)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: InnerTube requests

    func post(_ endpoint: String, _ body: [String: Any]) async throws -> JSON {
        try await post(as: .web, endpoint, body)
    }

    public func post(as flavor: Flavor, _ endpoint: String, _ body: [String: Any]) async throws -> JSON {
        if flavor == .music { await musicBootstrap() }
        let s = session
        let origin = flavor.origin
        let (clientName, clientId, clientVersion) = flavor == .web
            ? ("WEB", "1", s.clientVersion)
            : ("WEB_REMIX", "67", s.musicClientVersion)
        var client: [String: Any] = [
            "clientName": clientName,
            "clientVersion": clientVersion,
            "hl": s.hl,
            "gl": s.gl,
            "userAgent": userAgent,
            "platform": "DESKTOP",
            "clientFormFactor": "UNKNOWN_FORM_FACTOR",
        ]
        if let v = s.visitorData { client["visitorData"] = v }
        var user: [String: Any] = ["lockedSafetyMode": false]
        if let d = s.delegatedSessionId { user["onBehalfOfUser"] = d }
        var body = body
        body["context"] = ["client": client, "user": user, "request": ["useSsl": true]]

        var req = URLRequest(url: URL(string: "\(origin)/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.httpBody = JSONBody.data(body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(origin, forHTTPHeaderField: "Origin")
        req.setValue(origin, forHTTPHeaderField: "X-Origin")
        req.setValue("\(origin)/", forHTTPHeaderField: "Referer")
        req.setValue(clientId, forHTTPHeaderField: "X-Youtube-Client-Name")
        req.setValue(clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        req.setValue(s.cookies.header(for: "www.youtube.com"), forHTTPHeaderField: "Cookie")
        if let v = s.visitorData { req.setValue(v, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        if s.loggedIn {
            req.setValue(s.sessionIndex, forHTTPHeaderField: "X-Goog-AuthUser")
            req.setValue("true", forHTTPHeaderField: "X-Youtube-Bootstrap-Logged-In")
            if let auth = Self.sidAuthorization(s, origin: origin) { req.setValue(auth, forHTTPHeaderField: "Authorization") }
            if let d = s.delegatedSessionId { req.setValue(d, forHTTPHeaderField: "X-Goog-PageId") }
        }
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await http.data(for: req)
        } catch {
            Log.warn("InnerTube \(endpoint): \(error.localizedDescription)")
            throw APIError("Request to \(endpoint) failed: \(error.localizedDescription)")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let v: JSON
        do {
            v = try JSON(data: data)
        } catch {
            Log.warn("InnerTube \(endpoint): \(status), unreadable response")
            throw APIError("Invalid response from YouTube")
        }
        if !(200..<300).contains(status) {
            let msg = v.pointer("/error/message")?.string ?? "unknown error"
            Log.warn("InnerTube \(flavor) \(endpoint): \(status) \(msg) (signed in: \(s.loggedIn))")
            if status == 401 || status == 403 {
                throw APIError("YouTube rejected the request (\(status)): \(msg). Try signing in again.")
            }
            throw APIError("YouTube returned \(status): \(msg)")
        }
        // Anonymous continuations only work with the visitor id the first page was served for.
        if s.visitorData == nil, let vd = v.pointer("/responseContext/visitorData")?.string {
            mutate { if $0.visitorData == nil { $0.visitorData = vd } }
        }
        return v
    }

    public func browse(_ browseId: String, params: String? = nil) async throws -> JSON {
        var body: [String: Any] = ["browseId": browseId]
        if let p = params { body["params"] = p }
        return try await post("browse", body)
    }

    public func browseContinuation(_ token: String) async throws -> JSON {
        try await post("browse", ["continuation": token])
    }

    public func next(_ videoId: String) async throws -> JSON {
        try await post("next", ["videoId": videoId, "racyCheckOk": true, "contentCheckOk": true])
    }

    /// The watch page of `videoId` played from playlist or mix `list`; it carries
    /// the list's panel. Without a video, the list's first one.
    public func nextInList(videoId: String?, list: String, index: Int?) async throws -> JSON {
        var body: [String: Any] = ["playlistId": list, "racyCheckOk": true, "contentCheckOk": true]
        if let v = videoId { body["videoId"] = v }
        if let i = index { body["playlistIndex"] = i }
        return try await post("next", body)
    }

    public func nextContinuation(_ token: String) async throws -> JSON {
        try await post("next", ["continuation": token])
    }

    public func search(_ query: String, params: String? = nil) async throws -> JSON {
        var body: [String: Any] = ["query": query]
        if let p = params { body["params"] = p }
        return try await post("search", body)
    }

    public func searchContinuation(_ token: String) async throws -> JSON {
        try await post("search", ["continuation": token])
    }

    public func resolveURL(_ url: String) async throws -> Resolved {
        let v = try await post("navigation/resolve_url", ["url": url])
        guard let ep = v["endpoint"] else { throw APIError("Could not resolve \(url)") }
        if let id = ep.pointer("/watchEndpoint/videoId")?.string {
            return .video(id: id, playlist: nil, start: nil)
        }
        if let id = ep.pointer("/browseEndpoint/browseId")?.string {
            if id.hasPrefix("VL") { return .playlist(String(id.dropFirst(2))) }
            return .channel(id)
        }
        throw APIError("Could not resolve \(url)")
    }

    public func account() async throws -> Account? {
        guard isLoggedIn else { return nil }
        let v = try await post("account/account_menu", [:])
        return Parse.account(v)
    }

    public func like(_ videoId: String, _ action: LikeAction) async throws {
        let ep: String
        switch action {
        case .like: ep = "like/like"
        case .dislike: ep = "like/dislike"
        case .remove: ep = "like/removelike"
        }
        _ = try await post(ep, ["target": ["videoId": videoId]])
    }

    public func subscribe(_ channelId: String, _ on: Bool) async throws {
        let (ep, params) = on ? ("subscription/subscribe", "EgIIAhgA") : ("subscription/unsubscribe", "CgIIAhgA")
        _ = try await post(ep, ["channelIds": [channelId], "params": params])
    }

    /// The user's playlists, each saying whether it has `videoId`.
    public func saveTargets(_ videoId: String) async throws -> [SaveTarget] {
        let v = try await post("playlist/get_add_to_playlist", ["videoIds": [videoId], "excludeWatchLater": false])
        return Parse.saveTargets(v)
    }

    /// Creates a playlist with `videoIds` in it; returns its id.
    public func createPlaylist(title: String, privacy: String, videoIds: [String]) async throws -> String {
        let v = try await post("playlist/create", ["title": title, "privacyStatus": privacy, "videoIds": videoIds])
        guard let id = v["playlistId"]?.string else { throw APIError("YouTube didn't create the playlist") }
        return id
    }

    public func editPlaylist(_ playlistId: String, _ edits: [PlaylistEdit]) async throws {
        let v = try await post("browse/edit_playlist", ["playlistId": playlistId, "actions": edits.map(\.action)])
        if let s = v["status"]?.string, s != "STATUS_SUCCEEDED" {
            throw APIError("YouTube refused the change (\(s))")
        }
    }

    /// Downloads a subtitle track (a timedtext URL), as the website's player does.
    public func timedtext(_ url: String) async throws -> String {
        let (data, resp) = try await get(url, headers: ["Cookie": session.cookies.header(for: "www.youtube.com")])
        if !(200..<300).contains(resp.statusCode) { throw HTTPStatusError(status: resp.statusCode) }
        let text = String(decoding: data, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw APIError("YouTube sent empty subtitles") }
        return text
    }

    public func suggestions(_ query: String) async throws -> [String] {
        let s = session
        let q = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        let body = try await getText("https://suggestqueries-clients6.youtube.com/complete/search?client=youtube&ds=yt&hl=\(s.hl)&gl=\(s.gl.lowercased())&q=\(q)")
        guard let a = body.firstIndex(of: "("), let b = body.lastIndex(of: ")"), a < b else { throw APIError("Bad suggestions") }
        let v = try JSON(string: String(body[body.index(after: a)..<b]))
        return v[1]?.array?.compactMap { $0[0]?.string } ?? []
    }
}
