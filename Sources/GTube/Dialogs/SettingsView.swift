import GTubeCore
import SwiftUI

/// Bumped whenever a setting is changed here, so the views showing it update.
@MainActor @Observable
final class SettingsVersion {
    static let shared = SettingsVersion()
    var value = 0
}

/// A settings value read from and written to `Config`.
@MainActor
func setting<T>(_ key: WritableKeyPath<GTubeCore.Settings, T>, then: ((T) -> Void)? = nil) -> Binding<T> {
    Binding(get: {
        _ = SettingsVersion.shared.value
        return Config.settings[keyPath: key]
    }, set: { v in
        Config.update { $0[keyPath: key] = v }
        SettingsVersion.shared.value += 1
        then?(v)
    })
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            PlaybackSettings().tabItem { Label("Playback", systemImage: "play.circle") }
            SponsorBlockSettings().tabItem { Label("SponsorBlock", systemImage: "shield.lefthalf.filled") }
            DownloadSettings().tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
        }
        .frame(width: 640, height: 560)
    }
}

struct GeneralSettings: View {
    @State private var app = AppModel.shared
    @State private var language = Config.settings.language
    @State private var region = Config.settings.region
    @State private var refresh = 0

    var body: some View {
        Form {
            SwiftUI.Section("Content") {
                Toggle("Hide Shorts", isOn: setting(\.hideShorts))
                Text("Shorts are removed from every feed, search and channel. Short links still open in the normal player.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Language (e.g. en, it, de)", text: $language)
                    Button("Apply") {
                        let v = language.trimmingCharacters(in: .whitespaces).lowercased()
                        if !v.isEmpty {
                            Config.update { $0.language = v }
                            app.applyLocale()
                        }
                    }
                }
                HStack {
                    TextField("Region (e.g. US, IT, DE)", text: $region)
                    Button("Apply") {
                        let v = region.trimmingCharacters(in: .whitespaces).uppercased()
                        if !v.isEmpty {
                            Config.update { $0.region = v }
                            app.applyLocale()
                        }
                    }
                }
            }
            SwiftUI.Section {
                LabeledContent("Removed this session") {
                    Text("\(Parse.adsBlocked) ads and promotions • \(Parse.shortsHidden) Shorts").id(refresh)
                }
            } header: {
                Text("Ad blocking")
            } footer: {
                Text("Playback goes straight to the media streams through yt-dlp and mpv, so video ads are never requested. Promoted results, ad slots and banners are removed from every feed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Return YouTube Dislike") {
                Toggle("Show dislikes", isOn: setting(\.dislikes))
                Text("Estimated dislike counts from returnyoutubedislikeapi.com").font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Account") {
                HStack {
                    VStack(alignment: .leading) {
                        Text(app.loggedIn ? "Signed in" : "Not signed in")
                        Text(app.loggedIn ? "Your YouTube session is stored in \(Config.cookiesPath?.path ?? "")" : "Sign in to see your own feed, subscriptions and history")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if app.loggedIn {
                        Button("Sign out", role: .destructive) { app.signOut() }
                    } else {
                        Button("Sign in") { app.sheet = .signIn }
                    }
                }
            }
            SwiftUI.Section("Tools") {
                LabeledContent("yt-dlp", value: Tools.ytdlp ?? "not found (brew install yt-dlp)")
                LabeledContent("ffmpeg", value: Tools.ffmpeg ?? "not found (brew install ffmpeg)")
                LabeledContent("deno", value: Tools.find("deno") ?? Tools.find("node") ?? "not found (brew install deno)")
                Button("Show log") { NSWorkspace.shared.activateFileViewerSelecting([Log.path]) }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh += 1 }
    }
}

struct PlaybackSettings: View {
    @State private var app = AppModel.shared
    @State private var subLang = Config.settings.subtitleLang

    var body: some View {
        Form {
            SwiftUI.Section {
                Picker("Preferred quality", selection: setting(\.maxQuality)) {
                    ForEach([2160, 1440, 1080, 720, 480, 360], id: \.self) { Text("\($0)p").tag($0) }
                }
                Toggle("Autoplay", isOn: setting(\.autoplay) { app.watch.setAutoplay($0) })
                Toggle("Audio only", isOn: Binding(get: { app.player.audioOnlySetting }, set: { app.player.setAudioOnly($0) }))
                Toggle("Hardware decoding (takes effect after restarting GTube)", isOn: setting(\.hwdec))
                Toggle("Add to YouTube watch history", isOn: setting(\.markWatched))
                Text("Videos you watch here show up in your history on youtube.com, with how far you got (when signed in)").font(.caption).foregroundStyle(.secondary)
                Toggle("Resume where you left off", isOn: setting(\.resumePlayback))
                Text("Videos you watched part of, here or on another device, continue from there (when signed in)").font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section {
                Toggle("Show subtitles", isOn: setting(\.subtitles) { _ in app.player.subtitleSettingsChanged() })
                HStack {
                    TextField("Language (empty for “\(Config.settings.language)”)", text: $subLang)
                    Button("Apply") {
                        Config.update { $0.subtitleLang = subLang.trimmingCharacters(in: .whitespaces) }
                        app.player.subtitleSettingsChanged()
                    }
                }
                Toggle("Auto-translate", isOn: setting(\.subtitleTranslate) { _ in app.player.subtitleSettingsChanged() })
                Text("When a video has no subtitles in that language, show YouTube's automatic translation").font(.caption).foregroundStyle(.secondary)
                Picker("Size", selection: setting(\.subtitleScale) { app.player.setSubtitleScale($0) }) {
                    Text("Small").tag(0.75)
                    Text("Normal").tag(1.0)
                    Text("Large").tag(1.3)
                    Text("Very large").tag(1.6)
                }
            } header: {
                Text("Subtitles")
            } footer: {
                Text("Picking subtitles in the player (or pressing C) changes these too.").font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("YouTube Music") {
                Toggle("Ambient color", isOn: setting(\.musicAmbient) { _ in app.music.appearanceChanged() })
                Text("Tint Music mode with the colors of the album art that is playing").font(.caption).foregroundStyle(.secondary)
                Toggle("Spectrum visualizer", isOn: setting(\.musicVisualizer) { _ in app.music.appearanceChanged() })
                Text("Show the music's spectrum behind the player bar").font(.caption).foregroundStyle(.secondary)
                Toggle("Synced lyrics from LRCLIB", isOn: setting(\.lyricsLrclib) { _ in app.music.lyricsSourceChanged() })
                Text("When YouTube Music has no timed lyrics for a song, look for them on lrclib.net (sends the song's title and artist)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct SponsorBlockSettings: View {
    @State private var tick = 0

    var body: some View {
        Form {
            SwiftUI.Section {
                Toggle("Enable SponsorBlock", isOn: setting(\.sponsorblock))
            } footer: {
                Text("Crowd-sourced segments from sponsor.ajay.app. Lookups only send the first characters of a hash of the video ID.").font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Categories") {
                ForEach(Extras.sbCategories, id: \.id) { c in
                    Picker(selection: Binding(get: { _ = tick; return Config.settings.sbMode(c.id) }, set: { m in
                        Config.update { $0.sbModes[c.id] = m }
                        tick += 1
                    })) {
                        Text("Skip automatically").tag(SbMode.skip)
                        Text("Show in seek bar").tag(SbMode.show)
                        Text("Off").tag(SbMode.off)
                    } label: {
                        HStack {
                            Circle().fill(Color(hex: c.color)).frame(width: 12, height: 12)
                            VStack(alignment: .leading) {
                                Text(c.label)
                                if c.id == "poi_highlight" { Text("“Skip” shows a Jump to highlight button").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct DownloadSettings: View {
    @State private var dir = Config.settings.downloadDir
    @State private var choosing = false

    var body: some View {
        Form {
            LabeledContent("Download folder") {
                HStack {
                    Text(dir).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { choosing = true }
                }
            }
            Toggle("Embed metadata, thumbnail and chapters", isOn: setting(\.downloadEmbedMetadata))
            Toggle("Cut out sponsor segments by default", isOn: setting(\.downloadSbRemove))
            Text("Downloads need ffmpeg to merge video and audio and to convert audio (brew install ffmpeg).").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { r in
            if case .success(let u) = r {
                dir = u.path
                Config.update { $0.downloadDir = u.path }
            }
        }
    }
}
