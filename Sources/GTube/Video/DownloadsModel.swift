import AppKit
import GTubeCore
import SwiftUI

struct DownloadOptions {
    var audioOnly: Bool
    var quality: Int
    var audioFormat: String
    var sbRemove: Bool
}

@MainActor @Observable
final class DownloadTask: Identifiable {
    enum State: Equatable { case running, done, failed(String), cancelled }

    let id = UUID()
    let title: String
    let kind: String
    var progress = 0.0
    var status = "Starting…"
    var state: State = .running
    var path: String?
    @ObservationIgnored var process: Process?

    init(title: String, kind: String) {
        self.title = title
        self.kind = kind
    }

    func handle(_ line: String) {
        if line.hasPrefix("GTPROG ") {
            let parts = line.dropFirst(7).split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if let p = parts.first.flatMap({ Double($0.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) }) {
                progress = min(max(p / 100, 0), 1)
            }
            func at(_ i: Int) -> String { i < parts.count ? parts[i] : "" }
            var s = "\(at(0)) • \(at(1)) • ETA \(at(2))"
            if parts.count > 4, parts[3] != "NA", parts[4] != "NA" { s = "Video \(parts[3]) of \(parts[4]) • \(s)" }
            status = s
        } else if line.hasPrefix("GTPATH ") {
            path = String(line.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if ["[ExtractAudio]", "[Merger]", "[SponsorBlock]", "[ModifyChapters]"].contains(where: line.hasPrefix) {
            status = "Post-processing…"
        }
    }

    func finish(_ s: State) {
        switch s {
        case .done:
            progress = 1
            status = path ?? "Finished"
        case .failed(let m): status = "Failed: \(m)"
        case .cancelled: status = "Cancelled"
        case .running: break
        }
        state = s
        process = nil
    }

    func cancel() {
        process?.terminate()
        finish(.cancelled)
    }
}

/// Downloads through yt-dlp, with progress, cancel and optional SponsorBlock
/// segment removal.
@MainActor @Observable
final class DownloadsModel {
    private(set) var tasks: [DownloadTask] = []

    var active: Int { tasks.filter { $0.state == .running }.count }

    func cancelAll() {
        for t in tasks where t.state == .running { t.cancel() }
    }

    func remove(_ t: DownloadTask) { tasks.removeAll { $0.id == t.id } }

    func start(title: String, url: String, options o: DownloadOptions, playlist: Bool) {
        let s = Config.settings
        let dir = URL(fileURLWithPath: s.downloadDir)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return toast("Cannot create \(dir.path): \(error.localizedDescription)")
        }
        guard let ytdlp = Tools.ytdlp else { return toast("yt-dlp was not found. Install it with: brew install yt-dlp") }
        let template = playlist
            ? dir.appendingPathComponent("%(playlist_title)s/%(playlist_index)03d - %(title)s [%(id)s].%(ext)s").path
            : dir.appendingPathComponent("%(title)s [%(id)s].%(ext)s").path
        var args = [
            "--newline", "--no-colors", "--progress",
            "--progress-template", "download:GTPROG %(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s|%(info.playlist_index)s|%(info.n_entries)s",
            "--print", "after_move:GTPATH %(filepath)s",
            // --print implies --quiet, which would hide the post-processing lines.
            "--no-quiet",
            "-o", template,
        ]
        if !playlist { args.append("--no-playlist") }
        if Client.shared.isLoggedIn, let c = Config.cookiesPath { args += ["--cookies", c.path] }
        if let ff = Tools.ffmpeg { args += ["--ffmpeg-location", ff] }
        let kind: String
        if o.audioOnly {
            kind = "Audio • \(o.audioFormat.uppercased())"
            args += ["-f", "bestaudio/best", "-x", "--audio-format", o.audioFormat, "--audio-quality", "0"]
        } else {
            kind = "Video • up to \(o.quality)p"
            args += ["-f", "bv*[height<=?\(o.quality)]+ba/b[height<=?\(o.quality)]/b", "-S", "res:\(o.quality),vcodec:h264,acodec:m4a", "--merge-output-format", "mp4/mkv"]
        }
        if s.downloadEmbedMetadata { args += ["--embed-metadata", "--embed-thumbnail", "--embed-chapters"] }
        if o.sbRemove {
            let cats = s.sbModes.filter { $0.value == .skip && $0.key != "poi_highlight" }.map(\.key).sorted()
            if !cats.isEmpty { args += ["--sponsorblock-remove", cats.joined(separator: ",")] }
        }
        args.append(url)

        let task = DownloadTask(title: title, kind: kind)
        tasks.insert(task, at: 0)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ytdlp)
        p.arguments = args
        p.environment = Tools.environment
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        task.process = p

        let lastErr = LockedString()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { return }
            for line in String(decoding: d, as: UTF8.self).components(separatedBy: "\n") where !line.isEmpty {
                lastErr.update { cur in if line.hasPrefix("ERROR") || cur.isEmpty { cur = line } }
            }
        }
        let buffer = LockedString()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { return }
            var lines: [String] = []
            buffer.update { cur in
                cur += String(decoding: d, as: UTF8.self)
                while let r = cur.range(of: "\n") {
                    lines.append(String(cur[..<r.lowerBound]))
                    cur.removeSubrange(..<r.upperBound)
                }
            }
            if !lines.isEmpty {
                Task { @MainActor in for l in lines { task.handle(l) } }
            }
        }
        p.terminationHandler = { proc in
            let ok = proc.terminationStatus == 0
            let msg = lastErr.value.replacingOccurrences(of: "ERROR: ", with: "")
            Task { @MainActor in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                if task.state == .cancelled { return }
                if ok {
                    task.finish(.done)
                    toast("Downloaded “\(title)”")
                } else {
                    Log.error("download failed: \(msg)")
                    task.finish(.failed(msg.isEmpty ? "yt-dlp failed" : msg))
                }
            }
        }
        do {
            try p.run()
            toast("Downloading “\(title)”")
        } catch {
            task.finish(.failed("Could not run yt-dlp: \(error.localizedDescription)"))
        }
    }

    func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func reveal(_ t: DownloadTask) {
        if let p = t.path {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
        } else {
            open(Config.settings.downloadDir)
        }
    }
}

/// A string several threads write to.
final class LockedString: @unchecked Sendable {
    private let lock = NSLock()
    private var s = ""
    var value: String { lock.withLock { s } }
    func update(_ f: (inout String) -> Void) { lock.withLock { f(&s) } }
}
