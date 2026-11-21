import CMpv
import Foundation
import GTubeCore

/// A small wrapper around libmpv's client API and its OpenGL render API.
///
/// mpv does the hard parts of playback: it merges the separate DASH audio and
/// video streams (an `edl://` URL from yt-dlp), decodes (VideoToolbox),
/// renders subtitles and runs the visualizer's audio filter.
final class MPV {
    enum Value {
        case none, flag(Bool), int(Int64), double(Double), string(String)
        var double: Double? {
            switch self {
            case .double(let d): return d
            case .int(let i): return Double(i)
            default: return nil
            }
        }
        var bool: Bool? {
            if case .flag(let b) = self { return b }
            return nil
        }
    }

    enum Format { case flag, double, int, string }

    enum Event {
        case startFile, fileLoaded, playbackRestart, shutdown
        case endFile(reason: Int32, error: String)
        case property(name: String, value: Value)
        case log(prefix: String, level: String, text: String)
    }

    static let endFileEOF: Int32 = 0
    static let endFileError: Int32 = 4

    let handle: OpaquePointer
    private(set) var render: OpaquePointer?
    /// Called (on the main actor) when mpv has events queued.
    var onWakeup: (() -> Void)?
    /// Called (on any thread) when a new frame should be drawn.
    var onRedraw: (() -> Void)?

    init(options: [(String, String)]) throws {
        guard let h = mpv_create() else { throw NSError(domain: "mpv", code: 1, userInfo: [NSLocalizedDescriptionKey: "mpv_create failed"]) }
        handle = h
        for (k, v) in options {
            let r = mpv_set_option_string(h, k, v)
            if r < 0 { Log.warn("mpv: option \(k)=\(v) failed: \(Self.errorString(r))") }
        }
        let r = mpv_initialize(h)
        if r < 0 { throw NSError(domain: "mpv", code: Int(r), userInfo: [NSLocalizedDescriptionKey: "mpv_initialize failed: \(Self.errorString(r))"]) }
        mpv_request_log_messages(h, "warn")
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        mpv_set_wakeup_callback(h, { ctx in
            guard let ctx else { return }
            let me = Unmanaged<MPV>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.onWakeup?() }
        }, ctx)
    }

    static func errorString(_ code: Int32) -> String {
        String(cString: mpv_error_string(code))
    }

    // MARK: Rendering

    /// Must be called with the OpenGL context current.
    func createRenderContext() throws {
        if render != nil { return }
        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name else { return nil }
                let sym = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue)
                guard let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString) else { return nil }
                return CFBundleGetFunctionPointerForName(bundle, sym)
            },
            get_proc_address_ctx: nil
        )
        let api = strdup("opengl")
        defer { free(api) }
        var ctx: OpaquePointer?
        let r: Int32 = withUnsafeMutablePointer(to: &initParams) { ip in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(api)),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(ip)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            return mpv_render_context_create(&ctx, handle, &params)
        }
        if r < 0 { throw NSError(domain: "mpv", code: Int(r), userInfo: [NSLocalizedDescriptionKey: "mpv render context: \(Self.errorString(r))"]) }
        render = ctx
        let me = Unmanaged.passUnretained(self).toOpaque()
        mpv_render_context_set_update_callback(ctx, { me in
            guard let me else { return }
            Unmanaged<MPV>.fromOpaque(me).takeUnretainedValue().onRedraw?()
        }, me)
    }

    func renderFrame(fbo: Int32, width: Int32, height: Int32) {
        guard let render else { return }
        var f = mpv_opengl_fbo(fbo: fbo, w: width, h: height, internal_format: 0)
        var flip: Int32 = 1
        withUnsafeMutablePointer(to: &f) { fp in
            withUnsafeMutablePointer(to: &flip) { flp in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fp)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flp)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                _ = mpv_render_context_render(render, &params)
            }
        }
    }

    func reportSwap() {
        if let render { mpv_render_context_report_swap(render) }
    }

    // MARK: Commands and properties

    @discardableResult
    func command(_ args: [String]) -> String? {
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0.replacingOccurrences(of: "\0", with: ""))) }
        cargs.append(nil)
        defer { for p in cargs { free(UnsafeMutablePointer(mutating: p)) } }
        let r = cargs.withUnsafeMutableBufferPointer { mpv_command(handle, $0.baseAddress) }
        return r < 0 ? Self.errorString(r) : nil
    }

    func set(_ name: String, _ value: String) {
        mpv_set_property_string(handle, name, value)
    }

    func set(_ name: String, _ value: Double) {
        var v = value
        mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &v)
    }

    func set(_ name: String, _ value: Bool) {
        var v: Int32 = value ? 1 : 0
        mpv_set_property(handle, name, MPV_FORMAT_FLAG, &v)
    }

    func double(_ name: String) -> Double? {
        var v = 0.0
        return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &v) >= 0 ? v : nil
    }

    func string(_ name: String) -> String? {
        guard let p = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(p) }
        return String(cString: p)
    }

    func observe(_ name: String, _ f: Format) {
        let fmt: mpv_format
        switch f {
        case .flag: fmt = MPV_FORMAT_FLAG
        case .double: fmt = MPV_FORMAT_DOUBLE
        case .int: fmt = MPV_FORMAT_INT64
        case .string: fmt = MPV_FORMAT_STRING
        }
        mpv_observe_property(handle, 0, name, fmt)
    }

    /// The next queued event, without blocking.
    func poll() -> Event? {
        while true {
            guard let evp = mpv_wait_event(handle, 0) else { return nil }
            let ev = evp.pointee
            switch ev.event_id {
            case MPV_EVENT_NONE: return nil
            case MPV_EVENT_SHUTDOWN: return .shutdown
            case MPV_EVENT_START_FILE: return .startFile
            case MPV_EVENT_FILE_LOADED: return .fileLoaded
            case MPV_EVENT_PLAYBACK_RESTART: return .playbackRestart
            case MPV_EVENT_END_FILE:
                guard let d = ev.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee else { continue }
                return .endFile(reason: Int32(d.reason.rawValue), error: d.error < 0 ? Self.errorString(d.error) : "")
            case MPV_EVENT_LOG_MESSAGE:
                guard let d = ev.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee else { continue }
                func s(_ p: UnsafePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "" }
                return .log(prefix: s(d.prefix), level: s(d.level), text: s(d.text))
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let d = ev.data?.assumingMemoryBound(to: mpv_event_property.self).pointee else { continue }
                let name = String(cString: d.name)
                var value = Value.none
                if let data = d.data {
                    switch d.format {
                    case MPV_FORMAT_FLAG: value = .flag(data.assumingMemoryBound(to: Int32.self).pointee != 0)
                    case MPV_FORMAT_DOUBLE: value = .double(data.assumingMemoryBound(to: Double.self).pointee)
                    case MPV_FORMAT_INT64: value = .int(data.assumingMemoryBound(to: Int64.self).pointee)
                    case MPV_FORMAT_STRING:
                        let p = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee
                        value = .string(p.map { String(cString: $0) } ?? "")
                    default: break
                    }
                }
                return .property(name: name, value: value)
            default:
                continue
            }
        }
    }

    func destroy() {
        if let r = render {
            mpv_render_context_set_update_callback(r, nil, nil)
            mpv_render_context_free(r)
            render = nil
        }
        mpv_set_wakeup_callback(handle, nil, nil)
        mpv_terminate_destroy(handle)
    }
}

