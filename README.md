# GTube for macOS

A native macOS (SwiftUI + AppKit) YouTube and YouTube Music client: a Swift port of [GTube](https://github.com/cuckcoded/gtube), the GTK4 / libadwaita client written in Rust, with all of its features.

- **Your YouTube:** sign in and get the same home feed, subscriptions, history, playlists, Watch later and liked videos as on youtube.com. Like, dislike and subscribe from the app. Add several accounts and switch between them from the account menu, or pick "No account" to browse signed out.
- **Trending:** what's popular in Music, Gaming, News, Sports, Live and Fashion & Beauty (YouTube's Explore pages). It's where GTube opens when you aren't signed in.
- **No ads:** videos play straight from the media streams (yt-dlp finds them, libmpv plays them), so video ads are never fetched. Promoted results, ad slots and banners are removed from every feed.
- **No Shorts:** removed from feeds, search, Up next and channel pages (Settings → General). A Shorts link still opens in the normal player.
- **SponsorBlock:** segments are skipped automatically (with Undo) or marked in the seek bar, per category, and highlights get a marker and a "Jump to highlight" button. **Submit segments** too: press `;` (or the shield button in the player) where one starts and again where it ends, check it in the dialog (Preview), pick the category and submit.
- **Subtitles:** uploaded ones, YouTube's auto-generated ones and YouTube's automatic translation of either (the subtitles button in the player, or C). GTube remembers whether they're on and the language you picked.
- **Return YouTube Dislike:** estimated dislike counts and the like/dislike ratio bar.
- **Downloads:** video (up to 4K) or audio (mp3/m4a/opus/flac), whole playlists, with optional metadata/thumbnail/chapters, and SponsorBlock segments cut out.
- **Miniplayer:** keep watching in a corner while you browse. **Compact player:** shrink the whole window to just the player (Ctrl+Shift+M, the button next to fullscreen, or the menu). On macOS it stays on top of other windows; drag the video to move it, Esc brings the app back. **Audio-only** mode streams just the audio.
- **Theater mode:** the player spans the whole width of the watch page (T, or the button next to fullscreen).
- **Media controls:** GTube shows up in Control Center and the menu bar's Now Playing, with title, channel or artist, album and artwork. Media keys, AirPods and the Touch Bar play, pause, skip, seek and change the speed, and in Music mode also shuffle and repeat.
- **Playlists and mixes:** a playlist plays as a queue next to the video, all of it, with loop and shuffle; Play all / Shuffle on playlist pages. Mixes play as queues that keep going. Every video has Play next, Add to queue and Start mix in its right-click menu, and the player gets previous / next buttons (Shift+P / Shift+N). Drag a queue's videos to reorder them, or use their ⋯ menu.
- **Your playlists:** save any video to your playlists, or to a new one. On your own playlists, drag videos to reorder them, remove them, and edit the name, description and visibility.
- **Picks up where you left off:** GTube reports what you watch to YouTube the way youtube.com does, so your watch history shows how far you got, and videos continue from where YouTube says you stopped (with "Start over"). Needs signing in; both can be turned off in Settings → Playback.
- **YouTube Music mode:** switch with the YouTube | Music switch at the top of the sidebar (or Ctrl+M):
  - Home with mood chips and quick picks; Explore; your Library and playlists in the sidebar.
  - Search with suggestions, a top result and filters, plus artist, album and playlist pages.
  - A player bar with an endless queue: radios keep going, and autoplay continues with a mix when a list ends. Shuffle, repeat (all / one), like / dislike, and play next / add to queue / start radio / go to album or artist / download on every song.
  - **Now playing:** the artwork or the music video (Song / Video switch), with Up next, Lyrics and Related.
  - **Synced lyrics:** the line being sung is lit and the lyrics scroll along; click a line to jump to it. From YouTube Music's own timed lyrics, else [LRCLIB](https://lrclib.net) (can be turned off), else plain lyrics.
  - **Immersive view** (F, or the button in the player bar): the song across the whole screen with big artwork or the video over a blurred wash of the art, a large visualizer, and the lyrics or the queue beside it.
  - **Ambient color** and a **spectrum visualizer** behind the player bar, in sync with what you hear (it needs ffmpeg installed).
  - `music.youtube.com` links open in Music mode. The mode you used last is remembered.

## Install

Builds come from GitHub Actions (`.github/workflows/build.yml`): every run keeps `GTube-macos-arm64.zip` as an artifact, and tagged versions (`v*`) are published as releases. It holds `GTube.app` with libmpv, yt-dlp and deno inside. It isn't notarized: open it with right-click → Open the first time, or run `xattr -dr com.apple.quarantine GTube.app`.

A yt-dlp installed with Homebrew is used instead of the bundled one when there is one, since it's usually more up to date. **ffmpeg** isn't included: downloads need it to merge and convert, and the Music visualizer needs it too (`brew install ffmpeg`).

Requires macOS 14 (Sonoma) or newer.

## Build

```sh
brew install mpv yt-dlp deno ffmpeg
swift build -c release        # .build/release/GTube
swift test                    # parser and logic tests
packaging/bundle.sh           # build/GTube.app and build/GTube-macos-arm64.zip (also needs: brew install librsvg dylibbundler)
```

`swift run GTube` runs it from the terminal; `GTube <link or search terms>` opens a video, channel, playlist or search.

## Signing in

Open **Sign in** in the sidebar or account menu. There are three ways:

1. **Sign in with Google:** a normal Google login page in an in-app browser (WebKit), with a fresh private session each time.
2. **From browser:** copies your youtube.com session out of Safari, Chrome, Firefox, Brave, Edge, … (uses `yt-dlp --cookies-from-browser`; Safari needs Full Disk Access).
3. **cookies.txt:** import a Netscape cookies file exported by a browser extension.

Only youtube.com cookies are kept. Each account's are stored in `~/Library/Application Support/GTube/accounts/` (mode 600). **Add account…** in the account menu signs in another one; **Sign out** deletes the active account's cookies and leaves the others.

A third-party client is against YouTube's terms of service; it's very unlikely to cause problems, but use it knowing that.

## How ad blocking works

YouTube serves ads through its web player, which GTube doesn't use: yt-dlp resolves the audio/video streams and mpv plays them. In feeds, every ad and promoted renderer is dropped while parsing (Settings → General shows how many this session).

When YouTube attaches a pre-roll ad, its servers hold the video back for the ad's length. You don't see the ad, but you do see a short **"Starting in N s"** countdown.

## Keyboard shortcuts

| Key | Action |
|---|---|
| Space / K | play / pause |
| J / L | back / forward 10 s |
| ← / → | back / forward 5 s (player view) |
| ↑ / ↓ | volume (fullscreen) |
| F | fullscreen (Music: immersive view) |
| Esc | leave fullscreen / immersive view / compact player |
| Ctrl+Shift+M | compact player |
| ; | mark a SponsorBlock segment's start, then its end |
| C | subtitles on / off |
| T | theater mode |
| M | mute |
| I | miniplayer / back to the video |
| A | audio only (Music: Song / Video) |
| Shift+N / Shift+P | next / previous |
| + / − | volume (Music) |
| Ctrl+M | switch between YouTube and YouTube Music |
| / or ⌘F or Ctrl+L | search |
| ⌘R or Ctrl+R | refresh |
| ⌘[ or ⌥← | back |
| ⌘1 … ⌘4 (or ⌥1 … ⌥4) | Home, Subscriptions, You, Downloads |
| ⌘, | settings |
| ⌘Q | quit |

## Scripting

GTube registers the `gtube:` URL scheme, so a running GTube can be driven from scripts and Shortcuts:

```sh
open "gtube://open?q=https://youtu.be/jNQXAC9IVRw"   # a link or search terms
open "gtube://mode/music"                             # or gtube://mode/video
open "gtube://now-playing"
open "gtube://play-pause"; open "gtube://next"; open "gtube://previous"
```

## Files

- `~/Library/Application Support/GTube/settings.json`: settings (the same keys as GTube for Linux)
- `~/Library/Application Support/GTube/accounts/`: your sessions
- `~/Library/Logs/GTube/gtube.log`: log of the current run (`gtube.log.1`: the previous one). URLs are stripped of their query strings and cookies are never logged.
- Downloads go to `~/Movies/GTube` by default (Settings → Downloads)

## Development

Layout:

- `Sources/GTubeCore`: everything that isn't UI, Foundation only — the InnerTube client (`InnerTube.swift`) and its parsers (`Parse.swift`, `Music.swift`), lyrics, watch-history reports (`Stats.swift`), SponsorBlock and Return YouTube Dislike (`Extras.swift`), yt-dlp and subtitles (`Extract.swift`), settings and accounts.
- `Sources/GTube`: the app. `Player/` is playback (libmpv's OpenGL render API into a `CAOpenGLLayer`, the player model and its controls), `Video/` is YouTube mode, `Music/` is YouTube Music mode, `Dialogs/` the dialogs and settings.
- `Sources/CMpv`: libmpv's C headers (mpv's own, ISC license); the library comes from Homebrew.
- `Tests/GTubeCoreTests`: the original's parser and logic tests, ported.

`GTUBE_MPV_AO` overrides mpv's audio output (e.g. `null`), `GTUBE_SPONSORBLOCK_API` points SponsorBlock at another server, and `GTUBE_STATS_DRY_RUN=1` writes the watch-history reports to the log instead of sending them.

## License

GPL-3.0-or-later, like GTube.
