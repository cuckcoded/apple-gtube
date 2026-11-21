import AppKit
import GTubeCore
import SwiftUI

/// Runs `f` on the main actor after `seconds`; cancel the task to drop it.
@discardableResult
func after(_ seconds: Double, _ f: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1e9))
        if !Task.isCancelled { f() }
    }
}

/// Seconds on a steady clock, for the watch-time reports.
func steadyClock() -> Double {
    ProcessInfo.processInfo.systemUptime
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

func openInBrowser(_ url: String) {
    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
}

extension Color {
    /// "#rrggbb".
    init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0x888888
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    /// 0xAARRGGBB.
    init(argb: UInt32) {
        self.init(red: Double((argb >> 16) & 0xff) / 255, green: Double((argb >> 8) & 0xff) / 255, blue: Double(argb & 0xff) / 255)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// A toast: a short message at the bottom of the window, maybe with a button.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var button: String?
    var action: (@MainActor () -> Void)?
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

@MainActor @Observable
final class Toasts {
    static let shared = Toasts()
    var current: [Toast] = []

    func show(_ text: String, button: String? = nil, action: (@MainActor () -> Void)? = nil) {
        Log.info("toast: \(text)")
        let t = Toast(text: text, button: button, action: action)
        current.append(t)
        if current.count > 3 { current.removeFirst() }
        after(button == nil ? 4 : 6) { [weak self] in
            self?.current.removeAll { $0.id == t.id }
        }
    }

    func dismiss(_ t: Toast) { current.removeAll { $0.id == t.id } }
}

@MainActor func toast(_ text: String) { Toasts.shared.show(text) }

@MainActor func toast(_ text: String, button: String, action: @escaping @MainActor () -> Void) {
    Toasts.shared.show(text, button: button, action: action)
}

struct ToastsView: View {
    @State private var toasts = Toasts.shared

    var body: some View {
        VStack(spacing: 8) {
            ForEach(toasts.current) { t in
                HStack(spacing: 12) {
                    Text(t.text).lineLimit(3).multilineTextAlignment(.leading)
                    if let b = t.button {
                        Button(b) {
                            t.action?()
                            toasts.dismiss(t)
                        }
                        .buttonStyle(.borderless)
                        .fontWeight(.semibold)
                    }
                    Button {
                        toasts.dismiss(t)
                    } label: {
                        Image(systemName: "xmark").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 6, y: 2)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 560)
        .padding(.bottom, 24)
        .animation(.easeOut(duration: 0.2), value: toasts.current)
    }
}
