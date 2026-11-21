import AppKit
import GTubeCore
import SwiftUI

/// Thumbnail/avatar loading with an in-memory cache, at most 8 at a time.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()
    private var cache: [String: NSImage] = [:]
    private var pending: [String: [(NSImage) -> Void]] = [:]
    private var running = 0
    private var queue: [String] = []

    func cached(_ url: String) -> NSImage? { cache[url] }

    func load(_ url: String, _ done: @escaping (NSImage) -> Void) {
        if url.isEmpty { return }
        if let img = cache[url] {
            done(img)
            return
        }
        if pending[url] != nil {
            pending[url]!.append(done)
            return
        }
        pending[url] = [done]
        queue.append(url)
        pump()
    }

    private func pump() {
        while running < 8, !queue.isEmpty {
            let url = queue.removeLast()
            running += 1
            Task {
                let img = await Self.fetch(url)
                running -= 1
                let callbacks = pending.removeValue(forKey: url) ?? []
                if let img {
                    if cache.count > 1500 { cache.removeAll() }
                    cache[url] = img
                    for c in callbacks { c(img) }
                }
                pump()
            }
        }
    }

    nonisolated static func fetch(_ url: String) async -> NSImage? {
        guard let r = try? await Client.shared.get(url), (200..<300).contains(r.1.statusCode) else { return nil }
        return NSImage(data: r.0)
    }
}

/// An image from the web, filling its frame (or fitting into it).
struct RemoteImage: View {
    let url: String?
    var contentMode: ContentMode = .fill
    var placeholder = true
    @State private var image: NSImage?
    @State private var loadedURL: String?

    var body: some View {
        ZStack {
            if let image, loadedURL == url {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(placeholder ? Color.secondary.opacity(0.15) : Color.clear)
            }
        }
        .onAppear(perform: load)
        .onChange(of: url) { _, _ in load() }
    }

    private func load() {
        guard let url, !url.isEmpty else {
            image = nil
            loadedURL = nil
            return
        }
        if loadedURL == url && image != nil { return }
        if let c = ImageLoader.shared.cached(url) {
            image = c
            loadedURL = url
            return
        }
        ImageLoader.shared.load(url) { img in
            if self.url == url {
                image = img
                loadedURL = url
            }
        }
    }
}

/// A round avatar: the picture, or the initials of `name`.
struct Avatar: View {
    let url: String?
    let name: String?
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.35))
            if let n = name, let c = n.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@")).first {
                Text(String(c).uppercased()).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white)
            } else {
                Image(systemName: "person.fill").font(.system(size: size * 0.45)).foregroundStyle(.white)
            }
            if let url, !url.isEmpty {
                RemoteImage(url: url, placeholder: false).clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
