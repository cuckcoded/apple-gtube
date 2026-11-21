import GTubeCore
import SwiftUI
import WebKit

/// A normal Google sign-in page inside the app. Each sign-in gets a fresh,
/// in-memory browser session (so another account can be picked); only the
/// youtube.com cookies are kept, in the account's own file.
struct GoogleSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator = SignInCoordinator()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in with Google").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") { coordinator.check(manual: true) }
                    .keyboardShortcut(.defaultAction)
                    .help("Use the current session (if sign-in wasn't detected automatically)")
            }
            .padding(12)
            Divider()
            SignInWebView(coordinator: coordinator)
        }
        .frame(width: 520, height: 760)
        .onAppear { coordinator.onDone = { dismiss() } }
    }
}

@MainActor
final class SignInCoordinator: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var finished = false
    var onDone: (() -> Void)?

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15"
        super.init()
        webView.navigationDelegate = self
        Log.info("sign-in: opening Google sign-in window")
        webView.load(URLRequest(url: URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&passive=true&hl=en&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26next%3D%252F")!))
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            if webView.url?.absoluteString.hasPrefix("https://www.youtube.com") == true { check(manual: false) }
        }
    }

    /// Every youtube.com page load checks for a session; only the first
    /// success finishes the sign-in.
    func check(manual: Bool) {
        if finished { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            MainActor.assumeIsolated {
                if self.finished { return }
                let jar = CookieJar(cookies: cookies.map { c in
                    Cookie(domain: c.domain, includeSubdomains: c.domain.hasPrefix("."), path: c.path, secure: c.isSecure,
                           httpOnly: c.isHTTPOnly, expires: Int64(c.expiresDate?.timeIntervalSince1970 ?? 0), name: c.name, value: c.value)
                }).onlyYouTube()
                if jar.hasLogin {
                    self.finished = true
                    Log.info("sign-in: session detected")
                    self.onDone?()
                    AppModel.shared.addAccount(jar)
                } else if manual {
                    toast("Not signed in yet — finish signing in first")
                }
            }
        }
    }
}

struct SignInWebView: NSViewRepresentable {
    let coordinator: SignInCoordinator
    func makeNSView(context: Context) -> WKWebView { coordinator.webView }
    func updateNSView(_ v: WKWebView, context: Context) {}
}
