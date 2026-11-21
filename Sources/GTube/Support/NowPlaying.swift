import AppKit
import GTubeCore
import MediaPlayer

/// GTube in the system's media controls (Control Center, the menu bar's Now
/// Playing, media keys, AirPods, the lock screen): title, channel or artist,
/// album and artwork; play, pause, skip, seek, speed, and in Music mode
/// shuffle and repeat. (The macOS counterpart of the original's MPRIS.)
@MainActor
final class NowPlaying {
    static let shared = NowPlaying()
    private var artURL: String?
    private var artwork: MPMediaItemArtwork?
    private var lastKey = ""

    func start() {
        let c = MPRemoteCommandCenter.shared()
        let app = AppModel.shared
        func on(_ cmd: MPRemoteCommand, _ f: @escaping @MainActor (MPRemoteCommandEvent) -> Bool) {
            cmd.isEnabled = true
            cmd.addTarget { ev in
                if Thread.isMainThread {
                    return MainActor.assumeIsolated { f(ev) } ? .success : .commandFailed
                }
                DispatchQueue.main.async { MainActor.assumeIsolated { _ = f(ev) } }
                return .success
            }
        }
        on(c.playCommand) { _ in app.player.play(); return app.player.current != nil }
        on(c.pauseCommand) { _ in app.player.pause(); return true }
        on(c.togglePlayPauseCommand) { _ in app.player.togglePause(); return app.player.current != nil }
        on(c.stopCommand) { _ in app.player.pause(); return true }
        on(c.nextTrackCommand) { _ in app.next(); return true }
        on(c.previousTrackCommand) { _ in app.previous(); return true }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.preferredIntervals = [10]
        on(c.skipForwardCommand) { _ in app.player.seekRelative(10); return true }
        on(c.skipBackwardCommand) { _ in app.player.seekRelative(-10); return true }
        on(c.changePlaybackPositionCommand) { ev in
            guard let e = ev as? MPChangePlaybackPositionCommandEvent else { return false }
            app.player.seek(to: e.positionTime)
            return true
        }
        c.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 0.75, 1, 1.25, 1.5, 2]
        on(c.changePlaybackRateCommand) { ev in
            guard let e = ev as? MPChangePlaybackRateCommandEvent else { return false }
            app.player.setSpeed(Double(e.playbackRate))
            return true
        }
        on(c.changeShuffleModeCommand) { ev in
            guard let e = ev as? MPChangeShuffleModeCommandEvent, app.player.isMusicOwned else { return false }
            app.music.queue.setShuffle(e.shuffleType != .off)
            return true
        }
        on(c.changeRepeatModeCommand) { ev in
            guard let e = ev as? MPChangeRepeatModeCommandEvent, app.player.isMusicOwned else { return false }
            let want: MusicRepeat = e.repeatType == .one ? .one : e.repeatType == .all ? .all : .off
            while app.music.queue.repeatMode != want { app.music.queue.cycleRepeat() }
            return true
        }
    }

    /// Something about playback changed.
    func update() {
        let app = AppModel.shared
        let p = app.player
        let center = MPNowPlayingInfoCenter.default()
        guard let v = p.current else {
            if center.playbackState != .stopped || center.nowPlayingInfo != nil {
                center.nowPlayingInfo = nil
                center.playbackState = .stopped
            }
            lastKey = ""
            return
        }
        // The track's own info (album, art) when it came from Music.
        let track = p.isMusicOwned ? app.music.queue.current.flatMap { $0.videoId == v.id ? $0 : nil } : nil
        let art = track.map { $0.thumbnailURL(544) } ?? v.thumbnail ?? "https://i.ytimg.com/vi/\(v.id)/hqdefault.jpg"
        if art != artURL {
            artURL = art
            artwork = nil
            ImageLoader.shared.load(art) { [weak self] img in
                guard let self, self.artURL == art else { return }
                self.artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                self.lastKey = ""
                self.update()
            }
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: v.title,
            MPMediaItemPropertyArtist: track?.artistNames.nonEmpty ?? v.channelName ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: p.position,
            MPMediaItemPropertyPlaybackDuration: p.duration,
            MPNowPlayingInfoPropertyPlaybackRate: p.paused ? 0.0 : p.speed,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: p.isAudioOnly ? MPNowPlayingInfoMediaType.audio.rawValue : MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: v.isLive,
        ]
        if let a = track?.album?.text { info[MPMediaItemPropertyAlbumTitle] = a }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        // Elapsed time is extrapolated by the system: only send changes that matter.
        let key = "\(v.id)|\(v.title)|\(p.paused)|\(p.speed)|\(Int(p.duration))|\(artwork != nil)|\(Int(p.position / 5))"
        if key == lastKey { return }
        lastKey = key
        center.nowPlayingInfo = info
        center.playbackState = p.paused ? .paused : .playing
        let c = MPRemoteCommandCenter.shared()
        c.changeShuffleModeCommand.isEnabled = p.isMusicOwned
        c.changeRepeatModeCommand.isEnabled = p.isMusicOwned
    }

    /// Playback jumped: the system's clock must follow.
    func seeked() {
        lastKey = ""
        update()
    }
}
