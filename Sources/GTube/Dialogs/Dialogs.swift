import GTubeCore
import SwiftUI
import UniformTypeIdentifiers

/// Every dialog the window shows.
struct SheetView: View {
    let sheet: Sheet

    var body: some View {
        switch sheet {
        case .download(let v):
            DownloadDialog(title: "Download video", subtitle: v.title, allowVideo: true) { o in
                AppModel.shared.downloads.start(title: v.title, url: v.url, options: o, playlist: false)
            }
        case .downloadPlaylist(let p):
            DownloadDialog(title: "Download playlist", subtitle: p.title.isEmpty ? "Every video in this playlist" : p.title, allowVideo: true) { o in
                AppModel.shared.downloads.start(title: p.title.isEmpty ? "Playlist" : p.title,
                                                url: "https://www.youtube.com/playlist?list=\(p.id)", options: o, playlist: true)
            }
        case .saveToPlaylist(let id): SaveToPlaylistDialog(videoId: id)
        case .newPlaylist(let id): NewPlaylistDialog(videoId: id)
        case .editPlaylist(let m): EditPlaylistDialog(model: m)
        case .submitSegment: SubmitSegmentDialog()
        case .signIn: SignInDialog()
        case .browserImport: BrowserImportDialog()
        case .googleSignIn: GoogleSignInView()
        }
    }
}

struct DialogFrame<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.bold))
            if let s = subtitle { Text(s).foregroundStyle(.secondary).lineLimit(3) }
            content()
        }
        .padding(24)
        .frame(minWidth: 440, maxWidth: 520)
    }
}

struct DownloadDialog: View {
    let title: String
    let subtitle: String
    let allowVideo: Bool
    let done: (DownloadOptions) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var audio = Config.settings.audioOnly
    @State private var quality = Config.settings.maxQuality
    @State private var format = Config.settings.audioFormat
    @State private var sb = Config.settings.downloadSbRemove

    var body: some View {
        DialogFrame(title: title, subtitle: subtitle) {
            Form {
                Picker("Format", selection: $audio) {
                    Text("Video").tag(false)
                    Text("Audio only").tag(true)
                }
                if audio {
                    Picker("Audio format", selection: $format) {
                        ForEach(["mp3", "m4a", "opus", "flac"], id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    Picker("Maximum quality", selection: $quality) {
                        ForEach([2160, 1440, 1080, 720, 480, 360], id: \.self) { Text("\($0)p").tag($0) }
                    }
                }
                Toggle("Cut out sponsor segments", isOn: $sb)
                Text("Uses SponsorBlock; categories set to “Skip” in Settings").font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Download") {
                    Config.update { c in
                        c.audioFormat = format
                        c.downloadSbRemove = sb
                    }
                    done(DownloadOptions(audioOnly: audio || !allowVideo, quality: quality, audioFormat: format, sbRemove: sb))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// "Save to playlist": the user's playlists, ticked where the video is.
struct SaveToPlaylistDialog: View {
    let videoId: String
    @Environment(\.dismiss) private var dismiss
    @State private var targets: [SaveTarget]?
    @State private var failed: String?

    var body: some View {
        DialogFrame(title: "Save to playlist") {
            if let targets {
                if targets.isEmpty { Text("You have no playlists yet").foregroundStyle(.secondary) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(targets.enumerated()), id: \.element.id) { i, t in
                            Toggle(t.title, isOn: Binding(get: { self.targets?[i].saved ?? false }, set: { toggle(i, $0) }))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 360)
            } else if let failed {
                Text(failed).foregroundStyle(.red)
            } else {
                ProgressView()
            }
            HStack {
                Button("New playlist…") {
                    dismiss()
                    after(0.3) { AppModel.shared.sheet = .newPlaylist(videoId) }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .task {
            do { targets = try await Client.shared.saveTargets(videoId) } catch { failed = "Could not load your playlists: \(error.localizedDescription)" }
        }
    }

    func toggle(_ i: Int, _ on: Bool) {
        guard var t = targets else { return }
        t[i].saved = on
        targets = t
        let list = t[i].id
        let edit: PlaylistEdit = on ? .add(videoId) : .remove(videoId: videoId, setId: nil)
        Task {
            do {
                try await Client.shared.editPlaylist(list, [edit])
            } catch {
                toast("Could not change the playlist: \(error.localizedDescription)")
                targets?[i].saved = !on
            }
        }
    }
}

let privacies = [("PUBLIC", "Public"), ("UNLISTED", "Unlisted"), ("PRIVATE", "Private")]

struct NewPlaylistDialog: View {
    let videoId: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var privacy = "PRIVATE"

    var body: some View {
        DialogFrame(title: "New playlist") {
            Form {
                TextField("Name", text: $name)
                Picker("Visibility", selection: $privacy) {
                    ForEach(privacies, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let title = name.trimmingCharacters(in: .whitespaces)
                    let (p, v) = (privacy, videoId)
                    Task {
                        do {
                            _ = try await Client.shared.createPlaylist(title: title, privacy: p, videoIds: [v])
                            toast("Saved to \(title)")
                        } catch {
                            toast("Could not create the playlist: \(error.localizedDescription)")
                        }
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// Name, description and visibility of the user's playlist.
struct EditPlaylistDialog: View {
    let model: PlaylistViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var desc = ""
    @State private var privacy = "PUBLIC"

    var body: some View {
        DialogFrame(title: "Edit playlist") {
            Form {
                TextField("Name", text: $name)
                Picker("Visibility", selection: $privacy) {
                    ForEach(privacies, id: \.0) { Text($0.1).tag($0.0) }
                }
                SwiftUI.Section("Description") {
                    TextEditor(text: $desc).frame(minHeight: 96, maxHeight: 240)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.edit(title: name.trimmingCharacters(in: .whitespaces), description: desc.trimmingCharacters(in: .whitespacesAndNewlines), privacy: privacy)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            name = model.page.title
            desc = model.page.description ?? ""
            // No "Private"/"Unlisted" badge shown: public.
            privacy = model.page.privacy ?? "PUBLIC"
        }
    }
}

/// Submitting a segment to SponsorBlock: check it, preview it, send it.
struct SubmitSegmentDialog: View {
    @Environment(\.dismiss) private var dismiss
    @State private var start = ""
    @State private var end = ""
    @State private var category = "sponsor"
    @State private var mute = false
    @State private var status: String?
    @State private var sending = false

    var player: PlayerModel { AppModel.shared.player }

    var note: String {
        switch category {
        case "poi_highlight": return "A highlight marks the moment people came for; players offer to jump to it."
        case "exclusive_access": return "Marks the whole video as showcasing a product or service the creator got exclusive access to."
        case "sponsor": return "Paid promotion, paid referrals and direct advertisements."
        case "selfpromo": return "Unpaid or self promotion: merch, donations, shout-outs to other channels."
        case "interaction": return "A short reminder to like, subscribe or follow in the middle of the content."
        case "intro": return "An interval without actual content: a pause, a static frame, a repeating animation."
        case "outro": return "Credits or end cards."
        case "preview": return "A collection of clips that show what's coming up, or a recap of what came before."
        case "hook": return "Narrated trailers or greetings and goodbyes."
        case "music_offtopic": return "Only for music videos: a part that isn't music."
        case "filler": return "A tangent that isn't needed to understand the main content."
        default: return ""
        }
    }

    var body: some View {
        DialogFrame(title: "Submit Segment") {
            Form {
                HStack {
                    TextField("Start", text: $start)
                    Button("Now") { start = Format.preciseTime(player.position) }.help("Set to the current playback position")
                }
                if category != "poi_highlight" && category != "exclusive_access" {
                    HStack {
                        TextField("End", text: $end)
                        Button("Now") { end = Format.preciseTime(player.position) }.help("Set to the current playback position")
                    }
                }
                Picker("Category", selection: $category) {
                    ForEach(Extras.sbCategories, id: \.id) { c in
                        HStack {
                            Circle().fill(Color(hex: c.color)).frame(width: 10, height: 10)
                            Text(c.label)
                        }
                        .tag(c.id)
                    }
                }
                if category != "poi_highlight" && category != "exclusive_access" {
                    Picker("Action", selection: $mute) {
                        Text("Skip").tag(false)
                        Text("Mute").tag(true)
                    }
                }
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            if let status { Text(status).foregroundStyle(.red) }
            HStack {
                Button("Preview") {
                    status = nil
                    guard let seg = read() else { return }
                    player.setSbDraft((seg.start, seg.end))
                    player.seek(to: max(seg.start - 2, 0))
                    player.play()
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Submit") { submit() }.keyboardShortcut(.defaultAction).disabled(sending)
            }
            Text(try! AttributedString(markdown: "Submissions are public and help everyone who uses SponsorBlock. They're credited to an anonymous ID kept on this Mac. Please follow the [guidelines](https://wiki.sponsor.ajay.app/w/Guidelines)."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            if let d = SponsorBlockMarker.draft {
                start = Format.preciseTime(d.start)
                end = Format.preciseTime(d.end ?? d.start)
            }
        }
        // Closing the dialog drops the marked segment (also once it's sent).
        .onDisappear { SponsorBlockMarker.set(nil) }
    }

    func read() -> Segment? {
        let duration = player.duration
        if category == "exclusive_access" { return Segment(start: 0, end: 0, category: category, action: "full") }
        guard let s = Format.parseTime(start) else {
            status = "The start time isn't a time (like 1:23.4)."
            return nil
        }
        if category == "poi_highlight" {
            if s >= duration {
                status = "The highlight is past the end of the video."
                return nil
            }
            return Segment(start: s, end: s, category: category, action: "poi")
        }
        guard let e = Format.parseTime(end) else {
            status = "The end time isn't a time (like 1:23.4)."
            return nil
        }
        if e - s < 0.5 {
            status = "The segment must end after it starts."
            return nil
        }
        if e > duration + 1 {
            status = "The segment ends after the video."
            return nil
        }
        return Segment(start: s, end: min(e, duration), category: category, action: mute ? "mute" : "skip")
    }

    func submit() {
        status = nil
        guard let seg = read(), let video = SponsorBlockMarker.draft?.video ?? player.currentId else { return }
        sending = true
        let duration = player.duration
        Task {
            do {
                try await Extras.submit(videoId: video, userId: Extras.userId(), duration: duration, segment: seg)
                sending = false
                dismiss()
                toast("Segment submitted. Thanks for helping!")
                if player.currentId == video { player.refreshSegments() }
            } catch {
                sending = false
                Log.warn("SponsorBlock submission: \(error.localizedDescription)")
                status = error.localizedDescription
            }
        }
    }
}

// MARK: Signing in

struct SignInDialog: View {
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false

    var body: some View {
        DialogFrame(title: Client.shared.isLoggedIn ? "Add a YouTube account" : "Sign in to YouTube") {
            Text("Signing in makes your home feed, subscriptions, history and playlists the same as on youtube.com. The session is stored only on this Mac (\(Paths.config.appendingPathComponent("accounts").path)). You can add more accounts and switch between them from the account menu.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                Button {
                    dismiss()
                    after(0.3) { AppModel.shared.sheet = .googleSignIn }
                } label: {
                    Label("Sign in with Google", systemImage: "person.badge.key").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button {
                    dismiss()
                    after(0.3) { AppModel.shared.sheet = .browserImport }
                } label: {
                    Label("From browser…", systemImage: "safari").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                Button {
                    importing = true
                } label: {
                    Label("cookies.txt…", systemImage: "doc.text").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, .data]) { r in
            guard case .success(let url) = r else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                dismiss()
                AppModel.shared.addAccount(CookieJar.parseNetscape(text))
            } catch {
                toast("Could not read \(url.path): \(error.localizedDescription)")
            }
        }
    }
}

let browsers: [(String, String)] = [
    ("safari", "Safari"), ("chrome", "Google Chrome"), ("firefox", "Firefox"), ("chromium", "Chromium"), ("brave", "Brave"),
    ("edge", "Microsoft Edge"), ("vivaldi", "Vivaldi"), ("opera", "Opera"), ("whale", "Whale"),
]

/// Uses the YouTube session of a browser where you are signed in (yt-dlp
/// reads the browser's cookie store).
struct BrowserImportDialog: View {
    @Environment(\.dismiss) private var dismiss
    @State private var browser = "chrome"
    @State private var profile = ""

    var body: some View {
        DialogFrame(title: "Import from browser", subtitle: "Uses the YouTube session of a browser where you are already signed in. yt-dlp reads the browser's cookie store; only youtube.com cookies are kept. Safari needs Full Disk Access for GTube (System Settings → Privacy & Security).") {
            Form {
                Picker("Browser", selection: $browser) {
                    ForEach(browsers, id: \.0) { Text($0.1).tag($0.0) }
                }
                TextField("Profile (optional)", text: $profile)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") {
                    let spec = profile.trimmingCharacters(in: .whitespaces).isEmpty ? browser : "\(browser):\(profile.trimmingCharacters(in: .whitespaces))"
                    dismiss()
                    importFromBrowser(spec)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

@MainActor func importFromBrowser(_ spec: String) {
    guard let ytdlp = Tools.ytdlp else { return toast("yt-dlp was not found. Install it with: brew install yt-dlp") }
    let tmp = Paths.config.appendingPathComponent("import-cookies.tmp")
    try? FileManager.default.removeItem(at: tmp)
    toast("Reading browser cookies…")
    Task {
        // Without a URL yt-dlp exits with an error, but it still writes the
        // cookie jar to --cookies on the way out.
        let out = try? await Tools.run(ytdlp, ["--cookies-from-browser", spec, "--cookies", tmp.path])
        let text = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: tmp)
        if text.isEmpty {
            let err = out.map { String(decoding: $0.stderr, as: UTF8.self) } ?? ""
            var msg = err.components(separatedBy: "\n").first { $0.contains("ERROR") && !$0.contains("provide at least one URL") } ?? "no cookies found"
            msg = msg.replacingOccurrences(of: "ERROR: ", with: "")
            return toast("Import failed: \(msg)")
        }
        AppModel.shared.addAccount(CookieJar.parseNetscape(text))
    }
}
