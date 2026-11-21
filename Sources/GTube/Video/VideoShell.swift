import GTubeCore
import SwiftUI

/// The "YouTube | Music" switch at the top of both sidebars.
struct ModeSwitch: View {
    @State private var app = AppModel.shared

    var body: some View {
        Picker("", selection: Binding(get: { app.isMusic }, set: { app.setMode(music: $0) })) {
            Label("YouTube", systemImage: "play.rectangle.fill").tag(false)
            Label("Music", systemImage: "music.note").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Switch between YouTube and YouTube Music (Ctrl+M)")
    }
}

/// The account button: you, accounts, mode, settings, sign out.
struct AccountMenu: View {
    @State private var app = AppModel.shared

    var body: some View {
        Menu {
            if app.loggedIn {
                Button(app.account?.name ?? "Your account") { app.isMusic ? app.music.go(.library) : app.go(.you) }
            }
            Button("Downloads") {
                if app.isMusic { app.setMode(music: false) }
                app.go(.downloads)
            }
            SwiftUI.Section("Accounts") {
                ForEach(Array(app.accounts.enumerated()), id: \.element.id) { i, a in
                    Toggle(a.name.isEmpty ? "Account \(i + 1)" : a.name, isOn: Binding(get: { app.activeAccount == a.id }, set: { if $0 { app.switchAccount(a.id) } }))
                }
                if !app.accounts.isEmpty {
                    Toggle("No account", isOn: Binding(get: { app.activeAccount.isEmpty }, set: { if $0 { app.switchAccount("") } }))
                }
                Button(app.accounts.isEmpty ? "Sign in…" : "Add account…") { app.sheet = .signIn }
            }
            Divider()
            Button("YouTube") { app.setMode(music: false) }
            Button("YouTube Music") { app.setMode(music: true) }
            Divider()
            Button("Refresh") { app.refresh() }
            Button("Compact Player") { app.toggleCompact() }
            SettingsLink { Text("Settings…") }
            Button("About GTube") { showAbout() }
            if app.loggedIn {
                Divider()
                Button("Sign out") { app.signOut() }
            }
        } label: {
            Avatar(url: app.account?.avatar, name: app.account?.name, size: 24)
        }
        .menuIndicator(.hidden)
        .help("Account")
    }
}

func showAbout() {
    let credits = NSAttributedString(
        string: "A native YouTube client with SponsorBlock, Return YouTube Dislike, ad blocking and downloads.\n\nBuilt on mpv, yt-dlp, SponsorBlock and Return YouTube Dislike.",
        attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    NSApp.orderFrontStandardAboutPanel(options: [
        .applicationName: "GTube",
        .applicationVersion: gtubeVersion,
        .credits: credits,
        NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "GPL-3.0-or-later",
    ])
}

/// YouTube mode: sidebar, header with search, and the pages.
struct VideoShell: View {
    @State private var app = AppModel.shared
    @State private var columns: NavigationSplitViewVisibility = .all

    var sidebarSelection: Binding<NavSection?> {
        Binding(get: { app.section }, set: { if let s = $0 { app.go(s) } })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: sidebarSelection) {
                ModeSwitch().padding(.vertical, 4)
                SwiftUI.Section {
                    ForEach([NavSection.home, .subs, .trending]) { s in Label(s.title, systemImage: s.icon).tag(s) }
                }
                SwiftUI.Section("You") {
                    ForEach([NavSection.you, .history, .playlists, .later, .liked, .channels]) { s in Label(s.title, systemImage: s.icon).tag(s) }
                }
                SwiftUI.Section {
                    Label(NavSection.downloads.title, systemImage: NavSection.downloads.icon).tag(NavSection.downloads)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            NavigationStack(path: $app.path) {
                sectionView
                    .navigationDestination(for: Route.self) { r in
                        switch r {
                        case .watch: WatchView()
                        case .search: SearchResultsView()
                        case .channel(let id): ChannelView(id: id)
                        case .playlist(let id): PlaylistView(id: id)
                        }
                    }
            }
        }
        .searchable(text: $app.searchText, placement: .toolbar, prompt: "Search YouTube or paste a link")
        .searchSuggestions {
            ForEach(app.suggestions, id: \.self) { s in Text(s).searchCompletion(s) }
        }
        .onSubmit(of: .search) { app.videoSearch(app.searchText) }
        .onChange(of: app.searchText) { _, t in app.updateSuggestions(t) }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if app.canRefresh {
                    Button { app.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh (Ctrl+R)")
                }
                AccountMenu()
            }
        }
        .onChange(of: app.player.fullscreen) { _, fs in columns = fs ? .detailOnly : .all }
    }

    @ViewBuilder
    var sectionView: some View {
        switch app.section {
        case .home:
            FeedView(feed: app.home, emptyIcon: "magnifyingglass", emptyTitle: "Your feed is empty",
                     emptyText: "Search for something to watch, or sign in to see your recommendations.")
                .navigationTitle("Home")
        case .subs:
            FeedView(feed: app.subs, emptyIcon: "play.square.stack", emptyTitle: "No new videos", emptyText: "Videos from channels you subscribe to show up here.")
                .navigationTitle("Subscriptions")
        case .trending:
            TrendingView()
        case .you, .history, .playlists, .later, .liked, .channels:
            LibraryView()
        case .downloads:
            DownloadsView()
        }
    }
}

extension NavSection: Identifiable {
    var id: String { rawValue }
}

/// The signed-in user (or "Sign in") and the settings button.
struct SidebarFooter: View {
    @State private var app = AppModel.shared

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if app.loggedIn {
                    app.isMusic ? app.music.go(.library) : app.go(.you)
                } else {
                    app.sheet = .signIn
                }
            } label: {
                HStack(spacing: 10) {
                    Avatar(url: app.account?.avatar, name: app.account?.name, size: 28)
                    Text(app.account?.name ?? (app.loggedIn ? "Signed in" : "Sign in")).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings (⌘,)")
        }
        .padding(10)
    }
}
