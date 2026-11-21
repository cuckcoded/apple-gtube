import XCTest
@testable import GTubeCore

final class ParseTests: XCTestCase {
    func j(_ s: String) -> JSON { try! JSON(string: s) }

    func testPlaylistPanel() {
        let v = j(#"""
        {"currentVideoEndpoint":{"watchEndpoint":{"videoId":"b"}},
         "contents":{"twoColumnWatchNextResults":{"playlist":{"playlist":{
           "playlistId":"RDa","title":"Mix - A","isInfinite":true,"ownerName":{"simpleText":"YouTube"},
           "contents":[
             {"playlistPanelVideoRenderer":{"videoId":"a","title":{"simpleText":"A"},"lengthText":{"simpleText":"3:00"},
               "shortBylineText":{"runs":[{"text":"Artist","navigationEndpoint":{"browseEndpoint":{"browseId":"UCx"}}}]}}},
             {"playlistPanelVideoRenderer":{"videoId":"b","title":{"simpleText":"B"}}},
             {"automixPreviewVideoRenderer":{}}]}}}}}
        """#)
        let p = Parse.playlistPanel(v)!
        XCTAssertEqual(p.id, "RDa")
        XCTAssertEqual(p.title, "Mix - A")
        XCTAssertTrue(p.infinite)
        XCTAssertEqual(p.current, 1)
        XCTAssertEqual(p.items.count, 2)
        XCTAssertEqual(p.owner, "YouTube")
        XCTAssertEqual(p.items[0].channelId, "UCx")
        XCTAssertEqual(p.items[0].duration, "3:00")
    }

    func testURLs() {
        XCTAssertEqual(Parse.youtubeURL("https://youtu.be/abc?t=30"), .video(id: "abc", playlist: nil, start: 30))
        if case .video = Parse.youtubeURL("https://www.youtube.com/shorts/xyz") {} else { XCTFail() }
        XCTAssertEqual(Parse.youtubeURL("youtube.com/watch?v=dQw4w9WgXcQ&t=1m5s"), .video(id: "dQw4w9WgXcQ", playlist: nil, start: 65))
        XCTAssertEqual(Parse.youtubeURL("https://www.youtube.com/playlist?list=PL1"), .playlist("PL1"))
        XCTAssertEqual(Parse.youtubeURL("https://www.youtube.com/@handle"), .search("https://www.youtube.com/@handle"))
        XCTAssertNil(Parse.youtubeURL("linux kernel"))
    }

    func testOwnedPlaylistsAreEditable() {
        func entry(_ id: String, _ owned: Bool) -> [String: Any] {
            var l: [String: Any] = ["contentType": "LOCKUP_CONTENT_TYPE_VIDEO", "contentId": id,
                                    "metadata": ["lockupMetadataViewModel": ["title": ["content": id]]]]
            if owned {
                l["menu"] = ["playlistEditEndpoint": ["actions": [["action": "ACTION_REMOVE_VIDEO", "setVideoId": "s\(id)"]]]]
            }
            return ["lockupViewModel": l]
        }
        func page(_ owned: Bool) -> JSON { JSON(any: ["contents": [entry("a", owned), entry("b", owned)]]) }
        let opts = Parse.Opts(hideShorts: false)
        let p = Parse.playlist(page(true), id: "PL1", opts)
        XCTAssertTrue(p.editable)
        XCTAssertEqual(p.feed.items[1].video?.setVideoId, "sb")
        XCTAssertFalse(Parse.playlist(page(false), id: "PL1", opts).editable)
        let old = j(#"{"contents": {"playlistVideoListRenderer": {"isEditable": false, "contents": [{"playlistVideoRenderer": {"videoId": "a", "title": {"simpleText": "A"}, "setVideoId": "sa"}}]}}}"#)
        XCTAssertFalse(Parse.playlist(old, id: "PL1", opts).editable)
    }

    func testSaveTargets() {
        let v = j(#"{"contents": [{"addToPlaylistRenderer": {"playlists": [{"playlistAddToOptionRenderer": {"playlistId": "WL", "title": {"simpleText": "Watch later"}, "containsSelectedVideos": "NONE"}}, {"playlistAddToOptionRenderer": {"playlistId": "PL1", "title": {"simpleText": "Mine"}, "containsSelectedVideos": "ALL"}}]}}]}"#)
        let t = Parse.saveTargets(v)
        XCTAssertEqual(t.map(\.id), ["WL", "PL1"])
        XCTAssertEqual(t.map(\.saved), [false, true])
    }

    func testFeedDropsAdsAndShorts() {
        let v = j(#"""
        {"contents": [
          {"videoRenderer": {"videoId": "v1", "title": {"runs": [{"text": "One"}]},
            "longBylineText": {"runs": [{"text": "Chan", "navigationEndpoint": {"browseEndpoint": {"browseId": "UCc"}}}]},
            "lengthText": {"simpleText": "1:00"}}},
          {"adSlotRenderer": {"x": 1}},
          {"reelShelfRenderer": {"items": []}},
          {"videoRenderer": {"videoId": "v2", "title": {"simpleText": "Two"},
            "navigationEndpoint": {"reelWatchEndpoint": {}}}},
          {"continuationItemRenderer": {"continuationEndpoint": {"continuationCommand": {"token": "TOK"}}}}
        ]}
        """#)
        let f = Parse.feed(v, .init(hideShorts: true))
        XCTAssertEqual(f.items.map(\.id), ["v:v1"])
        XCTAssertEqual(f.items[0].video?.channelId, "UCc")
        XCTAssertEqual(f.continuation, "TOK")
    }

    func testDescriptionLinks() {
        let v = j(#"""
        {"currentVideoEndpoint": {"watchEndpoint": {"videoId": "me"}},
         "contents": {"twoColumnWatchNextResults": {"results": {"results": {"contents": [
           {"videoSecondaryInfoRenderer": {"attributedDescription": {"content": "Ünïcode 1:05 here",
             "commandRuns": [{"startIndex": 8, "length": 4, "onTap": {"innertubeCommand": {"watchEndpoint": {"videoId": "me", "startTimeSeconds": 65}}}}]}}}
         ]}}}}}
        """#)
        let d = Parse.next(v, .init(hideShorts: true))
        XCTAssertEqual(d.descriptionLinks, [DescriptionLink(start: 8, length: 4, target: "seek:65")])
    }
}

final class MusicTests: XCTestCase {
    func l(_ t: String, _ id: String? = nil) -> MLink { MLink(text: t, id: id) }

    func testBylineWithTypeLabelArtistsAlbumAndDuration() {
        var t = Track(videoId: "x")
        let col = [l("Song"), l(" • "), l("Daft Punk", "UCa"), l(" & "), l("Julian Casablancas", "UCb"), l(" • "),
                   l("Random Access Memories", "MPREb_x"), l(" • "), l("5:38")]
        Music.fillByline(&t, [col, [l("1.2B plays")]])
        XCTAssertEqual(t.artistNames, "Daft Punk, Julian Casablancas")
        XCTAssertEqual(t.album?.text, "Random Access Memories")
        XCTAssertEqual(t.duration, "5:38")
        XCTAssertEqual(t.info, "1.2B plays")
    }

    func testBylineWithTypeLabelAndUnlinkedArtist() {
        var t = Track(videoId: "x")
        Music.fillByline(&t, [[l("Song"), l(" • "), l("Daft Punk"), l(" • "), l("54M plays")]])
        XCTAssertEqual(t.artistNames, "Daft Punk")
        XCTAssertEqual(t.info, "54M plays")
        var v = Track(videoId: "y")
        Music.fillByline(&v, [[l("Video"), l(" • "), l("Daft Punk"), l(" • "), l("3:27")]])
        XCTAssertEqual(v.kind, .video)
        XCTAssertEqual(v.artistNames, "Daft Punk")
        XCTAssertEqual(v.duration, "3:27")
    }

    func testBylineWithUnlinkedArtist() {
        var t = Track(videoId: "x")
        Music.fillByline(&t, [[l("Dante Velar"), l(" • "), l("2:41")]])
        XCTAssertEqual(t.artistNames, "Dante Velar")
        XCTAssertEqual(t.duration, "2:41")
    }

    func testImageSizes() {
        XCTAssertEqual(Music.imageURL("https://lh3.googleusercontent.com/abc=w120-h120-l90-rj", 544), "https://lh3.googleusercontent.com/abc=w544-h544-l90-rj")
        XCTAssertEqual(Music.imageURL("https://yt3.ggpht.com/x=s48-c-k", 240), "https://yt3.ggpht.com/x=s240-c-k")
        XCTAssertEqual(Music.imageURL("https://lh3.googleusercontent.com/b=w1440-h600-p", 544), "https://lh3.googleusercontent.com/b=w1440-h600-p")
        XCTAssertEqual(Music.imageURL("https://i.ytimg.com/vi/x/hqdefault.jpg", 544), "https://i.ytimg.com/vi/x/hqdefault.jpg")
    }

    func testMusicURLs() {
        XCTAssertEqual(Music.musicURL("https://music.youtube.com/watch?v=abc&list=RDx"), .watch(videoId: "abc", playlistId: "RDx", params: nil, index: nil))
        XCTAssertEqual(Music.musicURL("music.youtube.com/playlist?list=PL1"), .browseTo("VLPL1"))
        XCTAssertEqual(Music.musicURL("https://music.youtube.com/browse/MPREb_1"), .browseTo("MPREb_1"))
        XCTAssertNil(Music.musicURL("https://www.youtube.com/watch?v=abc"))
    }
}

final class LyricsTests: XCTestCase {
    func testReadsLRC() {
        let lrc = "[ar:Someone]\n[offset:+500]\n[00:12.50]First line\n[00:10.00][01:02.25]Chorus\n\n[00:15.00]\n[1:05:00.00]Late\nno time here\n"
        let got = LyricsParse.lrc(lrc).map { "\($0.start)|\($0.text)" }
        XCTAssertEqual(got, ["9.5|Chorus", "12.0|First line", "14.5|", "61.75|Chorus", "3899.5|Late"])
    }

    func testDropsWordTimes() {
        let lines = LyricsParse.lrc("[00:18.89] <00:18.89>We're <00:19.25>no <00:19.53>strangers <00:20.07>to <00:20.33>love\n[00:22.00]a <b> c")
        XCTAssertEqual(lines[0].text, "We're no strangers to love")
        XCTAssertEqual(lines[1].text, "a <b> c")
        XCTAssertEqual(LyricsParse.lrcTime("01:02:03")!, 62.03, accuracy: 1e-9)
        XCTAssertNil(LyricsParse.lrcTime("ar"))
    }

    func testFindsTheCurrentLine() {
        let l = Lyrics.timed([LyricLine(start: 5, text: "b"), LyricLine(start: 1, text: "a")], source: nil)
        XCTAssertEqual(l.text, "a\nb")
        XCTAssertNil(l.lineAt(0.5))
        XCTAssertEqual(l.lineAt(1), 0)
        XCTAssertEqual(l.lineAt(4.9), 0)
        XCTAssertEqual(l.lineAt(100), 1)
    }

    func testReadsYouTubeTimedLyrics() throws {
        let v = try JSON(string: #"{"contents": {"elementRenderer": {"newElement": {"type": {"componentType": {"model": {"timedLyricsModel": {"lyricsData": {"timedLyricsData": [{"lyricLine": "Two", "cueRange": {"startTimeMilliseconds": "20450", "endTimeMilliseconds": "24930"}}, {"lyricLine": "One", "cueRange": {"startTimeMilliseconds": "1000", "endTimeMilliseconds": "2000"}}, {"lyricLine": "♪", "cueRange": {"startTimeMilliseconds": "30000", "endTimeMilliseconds": "40000"}}], "sourceMessage": "Source: Musixmatch"}}}}}}}}"#)
        let l = LyricsParse.timed(v)!
        XCTAssertTrue(l.isTimed)
        XCTAssertEqual(l.lines[0], LyricLine(start: 1, text: "One"))
        XCTAssertEqual(l.lines[1].start, 20.45, accuracy: 1e-9)
        XCTAssertEqual(l.source, "Source: Musixmatch")
        let s = try JSON(string: #"{"timedLyricsModel": {"lyricsData": {"timedLyricsData": [{"lyricLine": "a"}, {"lyricLine": "b"}]}}}"#)
        let p = LyricsParse.timed(s)!
        XCTAssertFalse(p.isTimed)
        XCTAssertEqual(p.text, "a\nb")
    }

    func testPicksMatchingLrclibLyrics() {
        let song = Song(title: "Song", artists: ["The Band"], duration: 200)
        let records = [
            LrclibRecord(trackName: "Song", artistName: "Other", duration: 200, plainLyrics: nil, syncedLyrics: "[00:01.00]wrong artist"),
            LrclibRecord(trackName: "Song (Live)", artistName: "The Band", duration: 260, plainLyrics: "live text", syncedLyrics: "[00:01.00]too long"),
            LrclibRecord(trackName: "Song", artistName: "The Band feat. X", duration: 201.5, plainLyrics: "right", syncedLyrics: "[00:02.00]right"),
        ]
        let l = pickLrclib(records, song)!
        XCTAssertTrue(l.isTimed)
        XCTAssertEqual(l.lines[0].text, "right")
        XCTAssertEqual(l.source, "LRCLIB")
        let p = pickLrclib(Array(records[..<2]), song)!
        XCTAssertFalse(p.isTimed)
        XCTAssertEqual(p.text, "live text")
        XCTAssertNil(pickLrclib(Array(records[..<1]), song))
    }

    func testCleansVideoTitles() {
        XCTAssertEqual(LyricsParse.cleanTitle("Never Gonna Give You Up (Official Video) (4K Remaster)"), "Never Gonna Give You Up")
        XCTAssertEqual(LyricsParse.cleanTitle("Song [Official Music Video]"), "Song")
        XCTAssertEqual(LyricsParse.cleanTitle("Song (feat. Someone) [Lyric Video]"), "Song (feat. Someone)")
        XCTAssertEqual(LyricsParse.cleanTitle("Song (Acoustic)"), "Song (Acoustic)")
        XCTAssertEqual(LyricsParse.cleanTitle("Song (2022 Remaster)"), "Song")
        XCTAssertEqual(LyricsParse.cleanTitle("Odd (title"), "Odd (title")
    }
}

final class ExtractTests: XCTestCase {
    func testSplitStreamsBecomeEDL() throws {
        let v = JSON(any: ["requested_formats": [
            ["url": "https://v.example/a,b", "available_at": 100, "http_headers": ["User-Agent": "UA, x"]],
            ["url": "https://a.example/c", "available_at": 104.5],
        ]])
        let s = try Extract.parse(v)
        XCTAssertEqual(s.url, "edl://!no_clip;!no_chapters;%21%https://v.example/a,b;!new_stream;!no_clip;!no_chapters;%19%https://a.example/c")
        XCTAssertEqual(s.userAgent, "UA, x")
        XCTAssertEqual(s.availableAt, 104.5)
    }

    func testReadsCaptions() throws {
        func tt(_ q: String) -> String { "https://www.youtube.com/api/timedtext?v=x&ei=y&\(q)&signature=z" }
        let v = JSON(any: [
            "url": "https://x/y",
            "language": "en-US",
            "subtitles": [
                "en": [["ext": "json3", "name": "English", "url": tt("lang=en&fmt=json3")], ["ext": "vtt", "name": "English", "url": tt("lang=en&fmt=vtt")]],
                "de-DE": [["ext": "vtt", "name": "German (Germany)", "url": tt("lang=de-DE&fmt=vtt")]],
                "live_chat": [["ext": "json", "url": "https://www.youtube.com/watch?v=x&bpctr=1"]],
            ],
            "automatic_captions": [
                "en-orig": [["ext": "vtt", "name": "English (Original)", "url": tt("lang=en&kind=asr&fmt=vtt")]],
                "ar-orig": [["ext": "vtt", "name": "Arabic (Original)", "url": tt("lang=ar&kind=asr&fmt=vtt")]],
                "en": [["ext": "vtt", "url": "https://manifest.googlevideo.com/api/manifest/hls_timedtext_playlist/x"],
                       ["ext": "vtt", "name": "English", "url": tt("lang=en&kind=asr&fmt=vtt")]],
                "it": [["ext": "vtt", "name": "Italian", "url": tt("lang=en&tlang=it&kind=asr&fmt=vtt")]],
                "af": [["ext": "vtt", "name": "Afrikaans", "url": tt("lang=en&tlang=af&kind=asr&fmt=vtt")]],
            ],
        ] as [String: Any])
        let c = try Extract.parse(v).captions
        XCTAssertEqual(c.tracks.map(\.name), ["English", "German (Germany)", "English (auto-generated)"])
        XCTAssertEqual(c.tracks.map(\.lang), ["en", "de-DE", "en"])
        XCTAssertEqual(c.tracks.map(\.auto), [false, false, true])
        XCTAssertEqual(c.translations, [Translation(code: "af", name: "Afrikaans"), Translation(code: "it", name: "Italian")])
        XCTAssertEqual(c.tracks[0].url, tt("lang=en"))
        XCTAssertEqual(c.tracks[2].vttURL("pt-BR"), tt("lang=en&kind=asr") + "&fmt=vtt&tlang=pt-BR")
        XCTAssertEqual(try Extract.parse(JSON(any: ["url": "u"])).captions, Captions())
    }

    func testListsHeights() throws {
        let v = JSON(any: [
            "formats": [
                ["vcodec": "none", "height": NSNull()], ["vcodec": "avc1", "height": 360], ["vcodec": "vp9", "height": 1080],
                ["vcodec": "avc1", "height": 1080], ["vcodec": "none", "acodec": "none", "ext": "mhtml", "height": 90], ["vcodec": "none", "acodec": "opus"],
            ] as [Any],
            "requested_formats": [["url": "v", "vcodec": "vp9", "height": 1080], ["url": "a", "vcodec": "none"]],
        ] as [String: Any])
        let s = try Extract.parse(v)
        XCTAssertEqual(s.heights, [1080, 360])
        XCTAssertEqual(s.height, 1080)
    }
}

final class SubtitleTests: XCTestCase {
    func captions(_ tracks: [(String, Bool)], _ translations: [String]) -> Captions {
        Captions(tracks: tracks.map { CaptionTrack(lang: $0.0, name: $0.0, auto: $0.1, url: "https://www.youtube.com/api/timedtext?lang=\($0.0)") },
                 translations: translations.map { Translation(code: $0, name: $0) })
    }

    func testPrefersUploadedTracksInTheLanguage() {
        let c = captions([("de-DE", false), ("en-GB", false), ("en", true)], ["it", "pt-BR"])
        XCTAssertEqual(Subtitles.preferred(c, lang: "en", translate: false), .track(1))
        XCTAssertEqual(Subtitles.preferred(c, lang: "de", translate: true), .track(0))
        XCTAssertEqual(Subtitles.preferred(c, lang: "it", translate: false), .track(1))
        XCTAssertEqual(Subtitles.preferred(c, lang: "it", translate: true), .translate(from: 1, to: "it"))
        XCTAssertEqual(Subtitles.preferred(c, lang: "pt", translate: true), .translate(from: 1, to: "pt-BR"))
        XCTAssertEqual(Subtitles.preferred(c, lang: "fr", translate: true), .track(1))
        XCTAssertEqual(Subtitles.preferred(captions([("ja", true)], ["en"]), lang: "en", translate: false), .track(0))
        XCTAssertEqual(Subtitles.preferred(captions([], []), lang: "en", translate: true), .off)
    }

    func testMenuKeysRoundTrip() {
        let c = captions([("en", false), ("ja", true)], ["it"])
        for ch in [SubtitleChoice.off, .track(1)] {
            XCTAssertEqual(SubtitleChoice.from(key: ch.key, captions: c, current: .off), ch)
        }
        XCTAssertEqual(SubtitleChoice.from(key: "x:it", captions: c, current: .track(1)), .translate(from: 1, to: "it"))
        XCTAssertEqual(SubtitleChoice.from(key: "x:it", captions: c, current: .off), .translate(from: 0, to: "it"))
        XCTAssertNil(SubtitleChoice.from(key: "x:fr", captions: c, current: .off))
        XCTAssertNil(SubtitleChoice.from(key: "t5", captions: c, current: .off))
        let s = SubtitleChoice.translate(from: 1, to: "it").source(c)!
        XCTAssertEqual(s.url, "https://www.youtube.com/api/timedtext?lang=ja&fmt=vtt&tlang=it")
        XCTAssertEqual(s.title, "it (auto-translated)")
        XCTAssertEqual(s.lang, "it")
    }

    func testSuggestsYourLanguages() {
        let c = captions([("en", true)], ["af", "de", "it", "pt-BR", "pt-PT"])
        XCTAssertEqual(Subtitles.suggested(c, ["pt-PT", "it"]).map(\.code), ["pt-PT", "it"])
        XCTAssertEqual(Subtitles.suggested(c, ["pt", "", "it", "it-CH"]).map(\.code), ["pt-BR", "it"])
        XCTAssertTrue(Subtitles.suggested(c, ["ja"]).isEmpty)
    }
}

final class StatsTests: XCTestCase {
    func tracking() -> Tracking {
        Tracking(playbackURL: "https://s.youtube.com/api/stats/playback?cl=1&docid=abc&ei=E&len=600&ns=yt&el=detailpage",
                 watchtimeURL: "https://s.youtube.com/api/stats/watchtime?cl=1&docid=abc&ei=E&len=600&ns=yt&el=detailpage",
                 resume: nil, length: 600)
    }

    func query(_ url: String) -> [String: String] {
        var out: [String: String] = [:]
        for i in URLComponents(string: url)?.queryItems ?? [] { out[i.name] = i.value ?? "" }
        return out
    }

    func testReadsThePlayerResponse() throws {
        let v = try JSON(string: #"{"playbackTracking": {"videostatsPlaybackUrl": {"baseUrl": "https://s.youtube.com/api/stats/playback?docid=x"}, "videostatsWatchtimeUrl": {"baseUrl": "https://s.youtube.com/api/stats/watchtime?docid=x"}}, "playerConfig": {"playbackStartConfig": {"startSeconds": 312}}, "videoDetails": {"lengthSeconds": "798"}}"#)
        let t = parseTracking(v)
        XCTAssertEqual(t.resume, 312)
        XCTAssertEqual(t.length, 798)
        XCTAssertTrue(t.watchtimeURL!.contains("watchtime"))
        XCTAssertNil(parseTracking(.object([:])).resume)
    }

    func testFormatsLikeTheWebPlayer() {
        XCTAssertEqual(secs(12), "12")
        XCTAssertEqual(secs(12.3456), "12.346")
        XCTAssertEqual(secs(0.5), "0.5")
        XCTAssertEqual(secs(-1), "0")
        XCTAssertEqual(nonce().count, 16)
        XCTAssertNotEqual(nonce(), nonce())
    }

    func testReportsWhatPlayed() {
        let r = Report(video: "abc", live: false, clientVersion: "2.2026", hl: "en", gl: "US")
        r.setLength(600)
        XCTAssertTrue(r.time(100, rate: 1, now: 0).isEmpty)
        XCTAssertTrue(r.time(102, rate: 1, now: 2).isEmpty)
        var out = r.setTracking(tracking(), now: 2.5)
        XCTAssertEqual(out.count, 1)
        let p = query(out[0])
        XCTAssertTrue(out[0].hasPrefix("https://s.youtube.com/api/stats/playback?"))
        XCTAssertEqual(p["docid"], "abc")
        XCTAssertEqual(p["ver"], "2")
        XCTAssertEqual(p["cpn"]?.count, 16)

        XCTAssertTrue(r.time(107, rate: 1, now: 7).isEmpty)
        out = r.time(110, rate: 1, now: 10)
        XCTAssertEqual(out.count, 1)
        var w = query(out[0])
        XCTAssertEqual(w["cpn"], p["cpn"])
        XCTAssertEqual(w["st"], "100")
        XCTAssertEqual(w["et"], "110")
        XCTAssertEqual(w["cmt"], "110")
        XCTAssertEqual(w["state"], "playing")
        XCTAssertEqual(w["len"], "600")
        XCTAssertNil(w["final"])

        _ = r.time(112, rate: 1, now: 12)
        _ = r.time(300, rate: 1, now: 13)
        _ = r.time(305, rate: 1, now: 18)
        out = r.pause(now: 18.5)
        w = query(out[0])
        XCTAssertEqual(w["st"], "110,300")
        XCTAssertEqual(w["et"], "112,305")
        XCTAssertEqual(w["state"], "paused")
        XCTAssertEqual(w["volume"], "100,100")
        XCTAssertEqual(WatchPositions.position("abc"), 305)

        _ = r.time(305, rate: 1, now: 30)
        _ = r.time(306.5, rate: 2, now: 31)
        out = r.finish(now: 32)
        w = query(out[0])
        XCTAssertEqual(w["final"], "1")
        XCTAssertEqual(w["st"], "305")
        XCTAssertEqual(w["et"], "306.5")
        XCTAssertEqual(w["rate"], "2")
        XCTAssertTrue(r.finish(now: 33).isEmpty)
        XCTAssertTrue(r.time(310, rate: 1, now: 34).isEmpty)
    }

    func testScheduleFollowsTheWebPlayer() {
        let r = Report(video: "sched", live: false, clientVersion: "2", hl: "en", gl: "US")
        _ = r.setTracking(tracking(), now: 0)
        var at: [Int] = []
        for s in 0...150 where r.time(Double(s), rate: 1, now: Double(s)).contains(where: { $0.contains("/watchtime") }) {
            at.append(s)
        }
        XCTAssertEqual(at, [10, 20, 30, 70, 110, 150])
    }

    func testWatchedToTheEndStartsOver() {
        WatchPositions.record("end", 590, 600)
        XCTAssertEqual(WatchPositions.position("end"), 0)
        XCTAssertEqual(WatchPositions.progress("end"), 1)
        WatchPositions.record("mid", 300, 600)
        XCTAssertEqual(WatchPositions.position("mid"), 300)
        XCTAssertEqual(WatchPositions.progress("mid"), 0.5)
        XCTAssertNil(WatchPositions.position("never"))
    }

    func testLiveStreamsOnlyCountTheView() {
        let r = Report(video: "live", live: true, clientVersion: "2", hl: "en", gl: "US")
        _ = r.setTracking(tracking(), now: 0)
        let out = r.time(5, rate: 1, now: 0)
        XCTAssertTrue(out[0].contains("/playback"))
        _ = r.time(15, rate: 1, now: 10)
        XCTAssertTrue(r.finish(now: 20).isEmpty)
    }
}

final class MiscTests: XCTestCase {
    func testCookies() {
        let text = "# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tTRUE\t0\tSAPISID\tabc\n#HttpOnly_.google.com\tTRUE\t/\tTRUE\t0\tSID\tx\n"
        let jar = CookieJar.parseNetscape(text)
        XCTAssertEqual(jar.cookies.count, 2)
        XCTAssertTrue(jar.hasLogin)
        XCTAssertEqual(jar.header(for: "www.youtube.com"), "SAPISID=abc")
        XCTAssertEqual(jar.onlyYouTube().cookies.count, 1)
        XCTAssertEqual(CookieJar.parseNetscape(jar.toNetscape()).cookies, jar.cookies)
    }

    func testSameAccount() {
        var a = SavedAccount(id: "1")
        a.name = "Ann"
        a.channelId = "UCa"
        XCTAssertTrue(a.isSame(name: "Ann B", channelId: "UCa"))
        XCTAssertFalse(a.isSame(name: "Ann", channelId: "UCb"))
        XCTAssertFalse(a.isSame(name: "Ann", channelId: nil))
        XCTAssertFalse(SavedAccount(id: "2").isSame(name: "", channelId: nil))
        var named = SavedAccount(id: "3")
        named.name = "Bo"
        XCTAssertTrue(named.isSame(name: "Bo", channelId: nil))
    }

    func testQueueShuffleKeepsCurrentFirstAndRestores() {
        var q = VideoQueue()
        q.items = ["a", "b", "c", "d", "e", "f"].map { VideoItem(id: $0) }
        q.index = 3
        q.shuffle(everything: false)
        XCTAssertEqual(q.index, 0)
        XCTAssertEqual(q.items[0].id, "d")
        XCTAssertEqual(q.items.map(\.id).sorted(), ["a", "b", "c", "d", "e", "f"])
        q.index = 2
        let id = q.items[2].id
        q.unshuffle()
        XCTAssertEqual(q.items.map(\.id), ["a", "b", "c", "d", "e", "f"])
        XCTAssertEqual(q.items[q.index].id, id)
    }

    func testMixesSkipRepeats() {
        var q = VideoQueue()
        q.items = [VideoItem(id: "a"), VideoItem(id: "b")]
        q.listId = "RDa"
        XCTAssertEqual(q.append(["b", "c", "a", "d"].map { VideoItem(id: $0) }), 2)
        XCTAssertEqual(q.items.map(\.id), ["a", "b", "c", "d"])
        var p = VideoQueue()
        p.items = [VideoItem(id: "a")]
        p.listId = "PLx"
        XCTAssertEqual(p.append([VideoItem(id: "a")]), 1)
    }

    func testEditsKeepThePlayingVideo() {
        var q = VideoQueue()
        q.items = ["a", "b", "c", "d"].map { VideoItem(id: $0) }
        q.index = 1
        q.total = 4
        q.move(from: 3, to: 0)
        XCTAssertEqual(q.items.map(\.id), ["d", "a", "b", "c"])
        XCTAssertEqual(q.index, 2)
        q.move(from: 2, to: 3)
        XCTAssertEqual(q.items.map(\.id), ["d", "a", "c", "b"])
        XCTAssertEqual(q.index, 3)
        q.remove(3)
        XCTAssertEqual(q.items.count, 4)
        q.remove(0)
        XCTAssertEqual(q.items.map(\.id), ["a", "c", "b"])
        XCTAssertEqual(q.index, 2)
        XCTAssertEqual(q.total, 3)
    }

    func testCountsVideos() {
        XCTAssertEqual(videoCount(["1,234 videos", "5 views"]), 1234)
        XCTAssertNil(videoCount(["No views"]))
    }

    func testTimes() {
        XCTAssertEqual(Format.preciseTime(83.44), "1:23.4")
        XCTAssertEqual(Format.preciseTime(3723), "1:02:03.0")
        XCTAssertEqual(Format.parseTime("1:23.4")!, 83.4, accuracy: 1e-9)
        XCTAssertEqual(Format.parseTime(" 83 "), 83)
        XCTAssertEqual(Format.parseTime("1:02:03"), 3723)
        XCTAssertNil(Format.parseTime("x"))
        XCTAssertNil(Format.parseTime("1:-3"))
        XCTAssertEqual(Format.count(1234), "1.2K")
        XCTAssertEqual(Format.count(12345), "12K")
        XCTAssertEqual(Format.count(2_000_000), "2M")
        XCTAssertEqual(Format.time(65), "1:05")
    }

    func testRedactsQueries() {
        XCTAssertEqual(Log.redact("Failed to open https://rr1---sn.googlevideo.com/videoplayback?ip=1.2.3.4&sig=x now"),
                       "Failed to open https://rr1---sn.googlevideo.com/videoplayback?… now")
        XCTAssertEqual(Log.redact("plain https://example.com/a b"), "plain https://example.com/a b")
    }

    func testLinkify() {
        let a = Linkify.attributed("see https://example.com/x. at 1:05 #tag")
        let links = a.runs.compactMap { $0.link?.absoluteString }
        XCTAssertEqual(links, ["https://example.com/x", "seek:65.0", "search:%23tag"])
    }
}
