import AppKit
import GTubeCore
import SwiftUI

@main
enum Main {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--version") || args.contains("-v") {
            print("GTube \(gtubeVersion)")
            exit(0)
        }
        if args.contains("--help") || args.contains("-h") {
            print("""
            Usage: GTube [LINK | SEARCH TERMS…]

            Watch YouTube. Opens a video, channel or playlist link, or searches for the given terms.
            In a running GTube: open "gtube://open?q=<link or terms>"
            """)
            exit(0)
        }
        Log.open(version: gtubeVersion)
        // libmpv refuses to start unless numbers are formatted the C way.
        setlocale(LC_NUMERIC, "C")
        GTubeApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Links and searches from the command line, opened once the window is up.
    var pending: [String] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        // Process arguments that aren't AppKit's own (-NSDocumentRevisions…).
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let text = args.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { pending.append(text) }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    /// `gtube://open?q=<link or search>`, `gtube://open/<link>`, `gtube://mode/music`,
    /// `gtube://now-playing`, `gtube://play-pause`, `gtube://next`, `gtube://previous`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls { MainActor.assumeIsolated { handleURL(u) } }
    }

    @MainActor func handleURL(_ u: URL) {
        let app = AppModel.shared
        guard app.window != nil else {
            pending.append(u.absoluteString)
            return
        }
        let comps = URLComponents(url: u, resolvingAgainstBaseURL: false)
        let host = comps?.host ?? ""
        let path = String((comps?.path ?? "").drop { $0 == "/" })
        switch host {
        case "open", "search":
            let q = comps?.queryItems?.first { $0.name == "q" || $0.name == "url" }?.value ?? path.removingPercentEncoding ?? path
            if !q.isEmpty { app.search(q) }
        case "mode": app.setMode(music: path == "music")
        case "now-playing":
            if app.isMusic { app.music.toggleNow() } else if app.player.isMusicOwned {
                app.setMode(music: true)
                app.music.showNow(true)
            }
        case "play-pause": app.player.togglePause()
        case "next": app.next()
        case "previous": app.previous()
        case "go":
            if let s = NavSection(rawValue: path) { app.go(s) }
        default:
            // gtube:<link>
            let rest = u.absoluteString.dropFirst("gtube:".count)
            let q = String(rest.drop { $0 == "/" })
            if !q.isEmpty { app.search(q.removingPercentEncoding ?? q) }
        }
    }

    @MainActor func openPending() {
        let p = pending
        pending = []
        for item in p {
            if item.hasPrefix("gtube:"), let u = URL(string: item) { handleURL(u) } else { AppModel.shared.search(item) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let app = AppModel.shared
            app.saveWindowState()
            let n = app.downloads.active
            if n == 0 { return .terminateNow }
            let a = NSAlert()
            a.messageText = "Downloads in progress"
            a.informativeText = "\(n) download(s) are still running. Quit and cancel them?"
            a.addButton(withTitle: "Keep running")
            a.addButton(withTitle: "Quit")
            a.buttons[1].hasDestructiveAction = true
            if a.runModal() == .alertSecondButtonReturn {
                app.downloads.cancelAll()
                return .terminateNow
            }
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.player.shutdown()
            Spectrum.cleanup()
        }
    }
}

struct GTubeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("GTube", id: "main") {
            RootView()
                .onAppear {
                    AppModel.shared.start()
                    after(0.5) { delegate.openPending() }
                }
        }
        .defaultSize(width: CGFloat(max(Config.settings.windowWidth, 480)), height: CGFloat(max(Config.settings.windowHeight, 400)))
        .commands { GTubeCommands() }

        SwiftUI.Settings {
            SettingsView()
        }
    }
}

struct GTubeCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(after: .sidebar) {
            Button("Switch YouTube / Music") { AppModel.shared.toggleMode() }
                .keyboardShortcut("m", modifiers: .control)
            Button("Compact Player") { AppModel.shared.toggleCompact() }
                .keyboardShortcut("m", modifiers: [.control, .shift])
            Button("Refresh") { AppModel.shared.refresh() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Search") { AppModel.shared.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
            Button("Back") { AppModel.shared.back() }
                .keyboardShortcut("[", modifiers: .command)
            Divider()
        }
        CommandMenu("Go") {
            Button("Home") { AppModel.shared.goNumber(1) }.keyboardShortcut("1", modifiers: .command)
            Button("Subscriptions") { AppModel.shared.goNumber(2) }.keyboardShortcut("2", modifiers: .command)
            Button("You") { AppModel.shared.goNumber(3) }.keyboardShortcut("3", modifiers: .command)
            Button("Downloads") { AppModel.shared.goNumber(4) }.keyboardShortcut("4", modifiers: .command)
            Divider()
            Button("Trending") {
                let a = AppModel.shared
                if a.isMusic { a.setMode(music: false) }
                a.go(.trending)
            }
            Button("Music Explore") {
                AppModel.shared.setMode(music: true)
                AppModel.shared.music.go(.explore)
            }
            Button("Music Library") {
                AppModel.shared.setMode(music: true)
                AppModel.shared.music.go(.library)
            }
        }
        CommandMenu("Playback") {
            Button("Play / Pause (Space, K)") { AppModel.shared.player.togglePause() }
            Button("Next (Shift+N)") { AppModel.shared.next() }
            Button("Previous (Shift+P)") { AppModel.shared.previous() }
            Divider()
            Button("Back 10 s (J)") { AppModel.shared.player.seekRelative(-10) }
            Button("Forward 10 s (L)") { AppModel.shared.player.seekRelative(10) }
            Button("Mute (M)") { AppModel.shared.player.toggleMute() }
            Divider()
            Button("Fullscreen (F)") { AppModel.shared.player.toggleFullscreen() }
            Button("Theater Mode (T)") { AppModel.shared.player.toggleTheater() }
            Button("Miniplayer (I)") {
                let p = AppModel.shared.player
                if p.mode == .mini { p.expand() } else { p.minimize() }
            }
            Button("Audio Only (A)") {
                let p = AppModel.shared.player
                p.setAudioOnly(!p.isAudioOnly)
            }
            Button("Subtitles (C)") { AppModel.shared.player.toggleSubtitles() }
            Button("Mark SponsorBlock Segment (;)") { SponsorBlockMarker.mark() }
            Divider()
            Button("Now Playing") {
                let a = AppModel.shared
                if a.isMusic { a.music.toggleNow() } else if a.player.isMusicOwned {
                    a.setMode(music: true)
                    a.music.showNow(true)
                }
            }
            Button("Immersive View") {
                let a = AppModel.shared
                guard a.player.currentId != nil else { return }
                if !a.isMusic { a.setMode(music: true) }
                a.music.setImmersive(!a.music.immersive)
            }
        }
        CommandGroup(replacing: .appInfo) {
            Button("About GTube") { showAbout() }
        }
        CommandGroup(replacing: .help) {
            Button("GTube Log") { NSWorkspace.shared.activateFileViewerSelecting([Log.path]) }
        }
    }
}

/// The window's content: YouTube or YouTube Music, the immersive view, the
/// player overlay and toasts.
struct RootView: View {
    @State private var app = AppModel.shared

    var body: some View {
        ZStack {
            if app.isCompact {
                Color.black.ignoresSafeArea()
            } else if app.isMusic {
                MusicShell()
            } else {
                VideoShell()
            }
            if app.music.immersive && !app.isCompact {
                ImmersiveView().transition(.opacity).ignoresSafeArea()
            }
            PlayerOverlay()
            VStack {
                Spacer()
                ToastsView()
            }
            .allowsHitTesting(!Toasts.shared.current.isEmpty)
        }
        .frame(minWidth: app.isCompact ? 200 : 480, minHeight: app.isCompact ? 112 : 400)
        .toolbar(app.isCompact || app.player.mode == .fullscreen || app.music.immersive ? .hidden : .visible, for: .windowToolbar)
        .sheet(item: $app.sheet) { s in SheetView(sheet: s) }
        .background(WindowAccessor())
        .environment(\.openURL, app.linkAction)
    }
}

/// Finds the window and follows its fullscreen state.
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowWatcher() }
    func updateNSView(_ v: NSView, context: Context) {}

    final class WindowWatcher: NSView {
        private var observers: [Any] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            MainActor.assumeIsolated {
                let app = AppModel.shared
                if app.window === w { return }
                app.window = w
                w.title = app.isMusic ? "GTube Music" : "GTube"
                w.minSize = NSSize(width: 480, height: 400)
                w.tabbingMode = .disallowed
                if Config.settings.windowMaximized, !w.isZoomed { w.zoom(nil) }
            }
            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.windowFullscreenChanged(true) }
            })
            observers.append(nc.addObserver(forName: NSWindow.didExitFullScreenNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.windowFullscreenChanged(false) }
            })
            observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.saveWindowState() }
            })
        }
    }
}
