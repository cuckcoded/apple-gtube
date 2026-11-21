import AppKit
import GTubeCore
import OpenGL.GL
import OpenGL.GL3
import QuartzCore

/// The layer mpv draws into, through its OpenGL render API (the way IINA does
/// it on macOS). One OpenGL context for the whole run, so the view can move
/// between the watch page, the miniplayer, Music's "Now playing" and
/// fullscreen without losing it.
final class VideoLayer: CAOpenGLLayer {
    static let pixelFormat: CGLPixelFormatObj? = {
        let attrs: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(rawValue: UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFAAccelerated, kCGLPFADoubleBuffer, kCGLPFAAllowOfflineRenderers,
            kCGLPFAColorSize, CGLPixelFormatAttribute(rawValue: 32),
            CGLPixelFormatAttribute(rawValue: 0),
        ]
        var pf: CGLPixelFormatObj?
        var n: GLint = 0
        if CGLChoosePixelFormat(attrs, &pf, &n) != kCGLNoError || pf == nil {
            // Without hardware acceleration (virtual machines).
            let soft: [CGLPixelFormatAttribute] = [kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(rawValue: UInt32(kCGLOGLPVersion_3_2_Core.rawValue)), kCGLPFADoubleBuffer, CGLPixelFormatAttribute(rawValue: 0)]
            CGLChoosePixelFormat(soft, &pf, &n)
        }
        return pf
    }()

    static let context: CGLContextObj? = {
        guard let pf = pixelFormat else { return nil }
        var ctx: CGLContextObj?
        CGLCreateContext(pf, nil, &ctx)
        if let ctx {
            var swap: GLint = 1
            CGLSetParameter(ctx, kCGLCPSwapInterval, &swap)
            CGLEnable(ctx, kCGLCEMPEngine)
        }
        return ctx
    }()

    weak var mpv: MPV?

    override init() {
        super.init()
        isAsynchronous = false
        needsDisplayOnBoundsChange = true
        backgroundColor = NSColor.black.cgColor
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? VideoLayer { mpv = other.mpv }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        Self.pixelFormat ?? super.copyCGLPixelFormat(forDisplayMask: mask)
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        Self.context ?? super.copyCGLContext(forPixelFormat: pf)
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        true
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fbo)
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
        if let mpv, mpv.render != nil {
            mpv.renderFrame(fbo: fbo, width: viewport[2], height: viewport[3])
        } else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        }
        glFlush()
        mpv?.reportSwap()
    }
}

/// The view that shows the video. There is only one; the player moves it to
/// whichever place shows the video.
final class VideoView: NSView {
    let videoLayer = VideoLayer()
    /// Clicks, double clicks and (in the compact player) drags.
    var onClick: ((Int) -> Void)?
    var onMouseMove: (() -> Void)?
    var dragMovesWindow = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = videoLayer
        videoLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer { videoLayer }

    override var isOpaque: Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        videoLayer.contentsScale = window?.backingScaleFactor ?? 2
        videoLayer.setNeedsDisplay()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let w = window { videoLayer.contentsScale = w.backingScaleFactor }
        videoLayer.setNeedsDisplay()
    }

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseMoved(with event: NSEvent) { onMouseMove?() }
    override func mouseEntered(with event: NSEvent) { onMouseMove?() }

    private var downAt: NSPoint?
    private var dragging = false

    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
        dragging = false
        if !dragMovesWindow { onClick?(event.clickCount) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragMovesWindow, let d = downAt, !dragging else { return }
        let p = event.locationInWindow
        if hypot(p.x - d.x, p.y - d.y) >= 6 {
            dragging = true
            window?.performDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragMovesWindow && !dragging { onClick?(event.clickCount) }
        downAt = nil
        dragging = false
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
