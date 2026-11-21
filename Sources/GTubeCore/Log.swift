import Foundation

/// The log file: `~/Library/Logs/GTube/gtube.log` (the previous run is kept as
/// `gtube.log.1`). URL query strings are stripped (stream URLs carry your IP
/// address) and nothing from the session cookies is ever logged.
public enum Log {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var written = 0
    private static let maxBytes = 4 * 1024 * 1024

    public static var path: URL { Paths.logs.appendingPathComponent("gtube.log") }

    /// Starts a new log file, keeping the previous one.
    public static func open(version: String) {
        let p = path
        let old = p.deletingPathExtension().appendingPathExtension("log.1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: p, to: old)
        FileManager.default.createFile(atPath: p.path, contents: nil, attributes: [.posixPermissions: 0o600])
        lock.lock()
        handle = try? FileHandle(forWritingTo: p)
        written = 0
        lock.unlock()
        info("GTube \(version) started")
    }

    public static func info(_ msg: String) { write("INFO", msg) }
    public static func warn(_ msg: String) { write("WARN", msg) }
    public static func error(_ msg: String) { write("ERROR", msg) }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static func write(_ level: String, _ msg: String) {
        let msg = redact(msg)
        FileHandle.standardError.write(Data("gtube \(level): \(msg)\n".utf8))
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle, written <= maxBytes else { return }
        var line = "\(formatter.string(from: Date())) \(level.padding(toLength: 5, withPad: " ", startingAt: 0)) \(msg)\n"
        written += line.utf8.count
        if written > maxBytes {
            line += "… log size limit reached, further messages are only printed to stderr\n"
        }
        h.write(Data(line.utf8))
    }

    private static let urlQuery = try! NSRegularExpression(pattern: #"(https?://[^\s?#'"()]+)[?#][^\s'"()]*"#)

    /// Strips URL query strings and fragments.
    public static func redact(_ msg: String) -> String {
        let r = NSRange(msg.startIndex..., in: msg)
        return urlQuery.stringByReplacingMatches(in: msg, range: r, withTemplate: "$1?…")
    }
}

/// Where GTube keeps its files.
public enum Paths {
    private static func dir(_ base: FileManager.SearchPathDirectory, _ sub: String...) -> URL {
        var u = FileManager.default.urls(for: base, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        for s in sub { u.appendPathComponent(s) }
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// `~/Library/Application Support/GTube`: settings and accounts.
    public static var config: URL { dir(.applicationSupportDirectory, "GTube") }
    public static var caches: URL { dir(.cachesDirectory, "GTube") }
    public static var logs: URL { dir(.libraryDirectory, "Logs", "GTube") }
}
