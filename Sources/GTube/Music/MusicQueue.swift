import GTubeCore
import SwiftUI

enum MusicRepeat: String {
    case off, all, one
}

/// What YouTube Music knows about the current track beyond the queue.
struct TrackInfo: Equatable {
    var videoId = ""
    var lyricsId: String?
    var relatedId: String?
    /// "LIKE", "DISLIKE" or "INDIFFERENT".
    var like: String?
    /// The fields above have arrived.
    var ready = false
}

/// The Music play queue ("Up next"). YouTube Music's `next` endpoint builds
/// it (an album, a playlist, a radio…); radios continue endlessly and, once a
/// list ends, autoplay continues with a mix of similar songs.
@MainActor @Observable
final class MusicQueue {
    private(set) var tracks: [Track] = []
    private var unshuffled: [Track]?
    private(set) var index: Int?
    private var continuation: String?
    private var playlistId: String?
    private var automix: Target?
    private(set) var title: String?
    private(set) var shuffle = Config.settings.musicShuffle
    private(set) var repeatMode = MusicRepeat(rawValue: Config.settings.musicRepeat) ?? .off
    private(set) var loading = false
    private(set) var info = TrackInfo()
    @ObservationIgnored private var request = 0
    @ObservationIgnored private var infoRequest = 0
    @ObservationIgnored private var extending = false
    @ObservationIgnored private var advanceAfterExtend = false
    @ObservationIgnored private var errors = 0
    /// Bumped when another track plays.
    private(set) var currentChanged = 0

    var player: PlayerModel { AppModel.shared.player }

    var current: Track? {
        guard let i = index, i < tracks.count else { return nil }
        return tracks[i]
    }

    var hasNext: Bool {
        if let i = index, i + 1 < tracks.count { return true }
        return continuation != nil || automix != nil || repeatMode == .all
    }

    /// Plays `target` (an album, playlist, song with its radio…), replacing the queue.
    func play(_ target: Target) {
        // A lone song plays with its radio, like on music.youtube.com.
        var target = target
        if case .watch(.some(let v), nil, let params, let index) = target {
            target = .watch(videoId: v, playlistId: "RDAMVM\(v)", params: params ?? "wAEB", index: index)
        }
        request += 1
        let req = request
        loading = true
        let t = target
        Task {
            do {
                let page = Music.queue(try await Client.shared.musicNext(t))
                guard request == req else { return }
                loading = false
                if page.tracks.isEmpty {
                    toast("Nothing to play here")
                } else {
                    replace(page)
                }
            } catch {
                guard request == req else { return }
                loading = false
                Log.warn("music queue for \(t) failed: \(error.localizedDescription)")
                toast("Couldn't start playback: \(error.localizedDescription)")
            }
        }
    }

    private func replace(_ page: MQueue) {
        var tracks = page.tracks
        var index = min(page.selected ?? 0, tracks.count - 1)
        unshuffled = nil
        if shuffle && tracks.count > 2 {
            unshuffled = tracks
            let cur = tracks.remove(at: index)
            tracks.shuffle()
            tracks.insert(cur, at: 0)
            index = 0
        }
        self.tracks = tracks
        self.index = index
        continuation = page.continuation
        playlistId = page.playlistId
        automix = page.automix
        title = page.title
        errors = 0
        info = TrackInfo(videoId: current?.videoId ?? "", lyricsId: page.lyricsId, relatedId: page.relatedId, like: page.likeStatus, ready: true)
        // The first track's info came with the queue.
        startCurrent(fetchInfo: false)
    }

    /// Plays the version (song or music video) that matches the Song / Video
    /// switch, when YouTube Music offers both.
    @discardableResult
    private func preferVersion(video: Bool) -> Bool {
        guard let i = index, i < tracks.count else { return false }
        let t = tracks[i]
        guard let cp = t.counterpart?.track else { return false }
        let isVideo = t.kind == .video
        if isVideo == video || (cp.kind == .video) != video { return false }
        var old = t
        old.counterpart = nil
        var new = cp
        new.counterpart = TrackBox(old)
        tracks[i] = new
        return true
    }

    private func startCurrent(fetchInfo: Bool) {
        preferVersion(video: player.musicVideo)
        guard let t = current else { return }
        player.loadMusic(t.videoItem)
        currentChanged += 1
        if fetchInfo { self.fetchInfo(t) }
        extendIfNeeded()
        AppModel.shared.music.trackChanged()
    }

    func playIndex(_ i: Int) {
        guard i < tracks.count else { return }
        index = i
        startCurrent(fetchInfo: true)
    }

    /// Like status, lyrics and related for a track picked inside the queue.
    private func fetchInfo(_ t: Track) {
        infoRequest += 1
        let req = infoRequest
        info = TrackInfo(videoId: t.videoId)
        let target = Target.watch(videoId: t.videoId, playlistId: playlistId ?? t.playlistId, params: t.params, index: nil)
        Task {
            guard let v = try? await Client.shared.musicNext(target), infoRequest == req else { return }
            let page = Music.queue(v)
            info.lyricsId = page.lyricsId
            info.relatedId = page.relatedId
            info.like = page.likeStatus
            info.ready = true
            AppModel.shared.music.infoChanged()
        }
    }

    /// The user asked for the next track.
    func next() { advance(user: true) }

    /// The current track finished.
    func onEnded() {
        if repeatMode == .one { return player.replay() }
        advance(user: false)
    }

    private func advance(user: Bool) {
        guard let i = index else { return }
        if i + 1 < tracks.count {
            playIndex(i + 1)
        } else if continuation != nil {
            extend(advance: true)
        } else if repeatMode == .all && !tracks.isEmpty {
            playIndex(0)
        } else if (user || Config.settings.autoplay) && automix != nil {
            extend(advance: true)
        } else if user {
            toast("This is the end of the queue")
        }
    }

    func previous() {
        if let i = index, i > 0, player.position < 3 {
            playIndex(i - 1)
        } else {
            player.seek(to: 0)
        }
    }

    private func extendIfNeeded() {
        guard let i = index else { return }
        if i + 3 >= tracks.count && continuation != nil { extend(advance: false) }
    }

    /// Fetches more tracks: the radio's continuation or, at the end of a
    /// list, autoplay's mix. With `advance`, plays the next track after.
    private func extend(advance: Bool) {
        if advance { advanceAfterExtend = true }
        if extending { return }
        let cont = continuation
        let pid = playlistId
        let mix = cont == nil ? automix : nil
        if cont == nil && mix == nil {
            advanceAfterExtend = false
            return
        }
        extending = true
        let req = request
        Task {
            var result: Result<([Track], String?, String?, Bool), Error>
            do {
                if let token = cont {
                    let (t, more, _) = Music.queueMore(try await Client.shared.musicNextContinuation(playlistId: pid, token: token))
                    result = .success((t, more, nil, false))
                } else if let target = mix {
                    let q = Music.queue(try await Client.shared.musicNext(target))
                    result = .success((q.tracks, q.continuation, q.playlistId, true))
                } else {
                    result = .success(([], nil, nil, false))
                }
            } catch {
                result = .failure(error)
            }
            extending = false
            guard request == req else { return }
            let adv = advanceAfterExtend
            advanceAfterExtend = false
            switch result {
            case .success(let (new, more, newPid, isMix)):
                let cur = current?.videoId
                let added = new.filter { $0.videoId != cur }
                continuation = more
                if isMix {
                    // Autoplay went on with a new mix: keep going with it.
                    automix = nil
                    if let p = newPid { playlistId = p }
                }
                tracks += added
                unshuffled? += added
                if adv && !added.isEmpty, let i = index {
                    playIndex(i + 1)
                } else if adv {
                    toast("This is the end of the queue")
                }
            case .failure(let e):
                Log.warn("music queue continuation failed: \(e.localizedDescription)")
                if adv { toast("Couldn't load more songs: \(e.localizedDescription)") }
            }
        }
    }

    private func insert(_ new: [Track], next: Bool) {
        if new.isEmpty { return }
        let at: Int
        if let i = index, next { at = min(i + 1, tracks.count) } else { at = tracks.count }
        tracks.insert(contentsOf: new, at: at)
        unshuffled? += new
        if !player.isMusicOwned {
            // Nothing from Music is playing: start with what was added.
            return playIndex(at)
        }
        let what = new.count == 1 ? "Song" : "Songs"
        toast(next ? "\(what) will play next" : "\(what) added to the queue")
    }

    func addNext(_ t: [Track]) { insert(t, next: true) }
    func addLast(_ t: [Track]) { insert(t, next: false) }

    /// Adds what `target` plays (an album, a playlist) to the queue.
    func addTarget(_ target: Target, next: Bool) {
        Task {
            do {
                let page = Music.queue(try await Client.shared.musicNext(target))
                if page.tracks.isEmpty { toast("Nothing to add") } else { insert(page.tracks, next: next) }
            } catch {
                toast("Couldn't add to the queue: \(error.localizedDescription)")
            }
        }
    }

    func remove(_ i: Int) {
        if i == index || i >= tracks.count { return }
        let removed = tracks.remove(at: i)
        if let p = unshuffled?.firstIndex(where: { $0.videoId == removed.videoId }) { unshuffled?.remove(at: p) }
        if let cur = index, i < cur { index = cur - 1 }
    }

    /// Moves a queued track to play right after the current one.
    func moveNext(_ i: Int) {
        guard let cur = index else { return }
        move(from: i, to: i < cur ? cur : cur + 1)
    }

    func move(from: Int, to: Int) {
        if from == to || from >= tracks.count || to >= tracks.count { return }
        let t = tracks.remove(at: from)
        tracks.insert(t, at: to)
        if let cur = index { index = movedIndex(cur, from: from, to: to) }
    }

    func setShuffle(_ on: Bool) {
        if shuffle == on { return }
        shuffle = on
        Config.update { $0.musicShuffle = on }
        if on {
            unshuffled = tracks
            let from = min((index ?? -1) + 1, tracks.count)
            var rest = Array(tracks[from...])
            rest.shuffle()
            tracks.replaceSubrange(from..., with: rest)
        } else if let orig = unshuffled {
            unshuffled = nil
            let id = current?.videoId
            let pos = id.flatMap { id in orig.firstIndex { $0.videoId == id } }
            tracks = orig
            if index != nil { index = pos ?? 0 }
        }
    }

    func cycleRepeat() {
        repeatMode = repeatMode == .off ? .all : repeatMode == .all ? .one : .off
        Config.update { $0.musicRepeat = repeatMode.rawValue }
    }

    /// The Song / Video switch changed: switch to the other version of the
    /// current track if there is one, at the same position.
    func videoSwitched(_ video: Bool) {
        guard player.isMusicOwned, preferVersion(video: video), let t = current else { return }
        let pos = player.position
        player.loadMusic(t.videoItem, start: pos)
        currentChanged += 1
        fetchInfo(t)
    }

    func setLike(_ status: String) {
        guard let t = current else { return }
        guard Client.shared.isLoggedIn else { return toast("Sign in to rate songs") }
        let action: LikeAction = status == "LIKE" ? .like : status == "DISLIKE" ? .dislike : .remove
        info.like = status
        let liked = status == "LIKE"
        let id = t.videoId
        Task {
            do {
                try await Client.shared.like(id, action)
                if liked { toast("Added to Liked music") }
            } catch {
                toast("Couldn't rate the song: \(error.localizedDescription)")
            }
        }
    }

    /// The player couldn't play the current track: skip it.
    func onError() {
        errors += 1
        if errors > 3 { return toast("Several songs in a row couldn't be played; stopped") }
        toast("Skipping “\(current?.title ?? "")”: it can't be played")
        let (req, idx) = (request, index)
        after(1.5) { [weak self] in
            guard let self, self.request == req, self.index == idx else { return }
            self.advance(user: false)
        }
    }

    /// Playback is going fine again.
    func playingOK() { errors = 0 }
}
