import AppKit
import QuartzCore

/// Which demo space a window represents. Drives colors + label only; it has no
/// bearing on the actual macOS Space the window lives on (that is decided by
/// *when* the window is created, per `DemoWindowController`).
enum DemoSpace: Int, Sendable {
    case one = 1
    case two = 2

    var label: String { "SPACE \(rawValue)" }

    /// Flat modern two-stop gradient (top-leading -> bottom-trailing).
    var gradientColors: [CGColor] {
        switch self {
        case .one:
            // deep blue -> violet
            return [
                NSColor(srgbRed: 0.05, green: 0.10, blue: 0.42, alpha: 1).cgColor,
                NSColor(srgbRed: 0.35, green: 0.09, blue: 0.62, alpha: 1).cgColor
            ]
        case .two:
            // teal -> green
            return [
                NSColor(srgbRed: 0.02, green: 0.42, blue: 0.45, alpha: 1).cgColor,
                NSColor(srgbRed: 0.09, green: 0.58, blue: 0.28, alpha: 1).cgColor
            ]
        }
    }
}

/// The view drawn inside a demo window. Everything is code-drawn (NSColor
/// gradients + text + shapes) — no images, no bundled assets, and no personal
/// content of any kind, so a recording is safe to publish. It covers the whole
/// window (which itself covers the desktop icons), a giant centered space label,
/// a giant live clock (seconds.milliseconds) updated by a 60fps timer, and a
/// status dot that flashes bright when the window is clicked.
final class DemoContentView: NSView {
    private let space: DemoSpace

    private let gradientLayer = CAGradientLayer()
    private let labelLayer = CATextLayer()
    private let clockLayer = CATextLayer()
    private let dotLayer = CAShapeLayer()
    private let hintLayer = CATextLayer()

    /// Time of the most recent click, used to fade the flash out.
    private var lastFlash: CFTimeInterval = -1

    init(space: DemoSpace) {
        self.space = space
        super.init(frame: .zero)
        wantsLayer = true
        setupLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }

    // The demo window is a floating, borderless, non-key window. Without this a
    // click that lands on it while it is not key would be swallowed as an
    // activation click and never dispatched as a mouseDown, so the local monitor
    // (HitRecorder) would never see the probe. Accept the first click directly.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setupLayers() {
        guard let root = layer else { return }
        root.masksToBounds = true

        gradientLayer.colors = space.gradientColors
        gradientLayer.startPoint = CGPoint(x: 0, y: 1)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0)
        root.addSublayer(gradientLayer)

        configureText(labelLayer, size: 220, weight: .heavy, color: .white)
        labelLayer.string = space.label
        root.addSublayer(labelLayer)

        configureText(clockLayer, size: 150, weight: .medium,
                      color: NSColor.white.withAlphaComponent(0.92))
        // Monospaced so the millisecond digits don't jitter horizontally.
        clockLayer.font = CTFontCreateWithName("SFMono-Medium" as CFString, 150, nil)
        root.addSublayer(clockLayer)

        configureText(hintLayer, size: 42, weight: .regular,
                      color: NSColor.white.withAlphaComponent(0.55))
        hintLayer.string = "bench demo window — click to flash"
        root.addSublayer(hintLayer)

        dotLayer.fillColor = NSColor.white.withAlphaComponent(0.25).cgColor
        dotLayer.strokeColor = NSColor.white.withAlphaComponent(0.6).cgColor
        dotLayer.lineWidth = 4
        root.addSublayer(dotLayer)
    }

    private func configureText(
        _ text: CATextLayer, size: CGFloat, weight: NSFont.Weight, color: NSColor
    ) {
        text.alignmentMode = .center
        text.foregroundColor = color.cgColor
        text.fontSize = size
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        text.font = font
        text.truncationMode = .none
    }

    override func layout() {
        super.layout()
        // Non-animated layout: geometry only, driven from the display-link tick.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        let scale = window?.backingScaleFactor ?? 2
        for l in [gradientLayer, labelLayer, clockLayer, dotLayer, hintLayer] {
            l.contentsScale = scale
        }

        gradientLayer.frame = b

        // Vertical stack, roughly centered: label above clock, dot below,
        // hint at the very bottom.
        let labelHeight: CGFloat = 260
        let clockHeight: CGFloat = 190
        labelLayer.frame = CGRect(x: 0, y: b.midY + 30,
                                  width: b.width, height: labelHeight)
        clockLayer.frame = CGRect(x: 0, y: b.midY - clockHeight,
                                  width: b.width, height: clockHeight)

        let dotSize: CGFloat = 120
        dotLayer.frame = CGRect(x: b.midX - dotSize / 2,
                                y: b.midY - clockHeight - dotSize - 40,
                                width: dotSize, height: dotSize)
        dotLayer.path = CGPath(ellipseIn: dotLayer.bounds.insetBy(dx: 6, dy: 6),
                               transform: nil)

        hintLayer.frame = CGRect(x: 0, y: 60, width: b.width, height: 60)
        CATransaction.commit()
    }

    /// Advance the clock + fade the flash. Called by the controller's 60fps
    /// display link. `now` is `CACurrentMediaTime()`-domain so it matches the
    /// measurement clock exactly.
    func tick(now: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // seconds.milliseconds wall-clock, wrapped at 60s so the field stays a
        // fixed width and reads like a stopwatch. No date, no timezone — nothing
        // that identifies when/where the recording was made.
        let t = Date().timeIntervalSince1970
        let secs = Int(t) % 60
        let millis = Int((t - floor(t)) * 1000)
        clockLayer.string = String(format: "%02d.%03d", secs, millis)

        // Flash fade: 1.0 immediately after a click, decaying to rest over 180ms.
        let flashAge = now - lastFlash
        if lastFlash >= 0, flashAge < 0.18 {
            let intensity = 1.0 - (flashAge / 0.18)
            let bright = NSColor(srgbRed: 0.6 + 0.4 * intensity,
                                 green: 1.0,
                                 blue: 0.6 + 0.4 * intensity,
                                 alpha: 1).cgColor
            dotLayer.fillColor = bright
            dotLayer.shadowColor = NSColor.white.cgColor
            dotLayer.shadowRadius = 40 * intensity
            dotLayer.shadowOpacity = Float(intensity)
        } else {
            dotLayer.fillColor = NSColor.white.withAlphaComponent(0.25).cgColor
            dotLayer.shadowOpacity = 0
        }
        CATransaction.commit()
    }

    /// Trigger the click flash. `now` is in `CACurrentMediaTime()` domain.
    func flash(now: CFTimeInterval) {
        lastFlash = now
    }
}

/// The borderless demo window. It fills the screen below the menu bar, floats
/// above normal windows, and is pinned to whichever macOS Space it was created
/// on (NO `.canJoinAllSpaces` — that is the whole point: window 1 stays on
/// space 1, window 2 on space 2).
final class DemoWindow: NSWindow {
    // Borderless windows are non-key by default; allow key + main so the local
    // click monitor and first-responder path work.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
