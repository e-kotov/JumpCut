import AppKit
import QuartzCore
import CStrafe

/// Records the destination-hit for a measurement trial. The controller calls
/// `record(space:now:)` on every click a demo window receives; the measurement
/// harness sets `armedDestination` before triggering a switch and reads back the
/// first hit on that destination.
///
/// Concurrency: created and mutated only on the main actor (all AppKit event
/// delivery + the run loop live there), so plain stored properties are fine.
@MainActor
final class HitRecorder {
    /// The space whose window we currently expect to receive the probe click.
    /// Clicks on the *source* window (pre-switch) must not count as interactive
    /// (SPEC/measurement pitfall), so we only latch a hit when it lands on this.
    var armedDestination: DemoSpace?

    /// `CACurrentMediaTime()` of the first click on the armed destination since
    /// the last `arm()`. `nil` until such a click arrives.
    private(set) var firstHit: CFTimeInterval?

    /// Count of clicks seen on the armed destination (to report the hit-vs-posted
    /// gap: how many probe clicks were delivered vs. how many we posted).
    private(set) var destinationHitCount = 0

    /// Count of clicks seen on the *source* (non-destination) window after arming
    /// — these are the "delivered to the wrong window pre-switch" case we exclude.
    private(set) var sourceHitCount = 0

    func arm(destination: DemoSpace) {
        armedDestination = destination
        firstHit = nil
        destinationHitCount = 0
        sourceHitCount = 0
    }

    func disarm() {
        armedDestination = nil
    }

    func record(space: DemoSpace, now: CFTimeInterval) {
        guard let dest = armedDestination else { return }
        if space == dest {
            destinationHitCount += 1
            if firstHit == nil { firstHit = now }
        } else {
            sourceHitCount += 1
        }
    }
}

/// Owns the two demo windows (one per space), the shared 60fps display link that
/// drives their clocks, and the click routing into a `HitRecorder`.
@MainActor
final class DemoWindowController {
    private let recorder: HitRecorder

    private var windows: [DemoSpace: DemoWindow] = [:]
    private var views: [DemoSpace: DemoContentView] = [:]
    private var clickMonitor: Any?
    private var displayLink: CADisplayLink?

    init(recorder: HitRecorder) {
        self.recorder = recorder
    }

    /// Ground truth for trial direction: which demo space is frontmost right
    /// now, per AppKit's own space tracking. Returns nil when indeterminate
    /// (e.g. the user manually switched to a third space mid-run) — callers
    /// must not guess in that case, it is exactly the bookkeeping-drift bug
    /// that produced false sub-10ms "hits" in early smoke runs.
    func activeDemoSpace() -> DemoSpace? {
        let oneActive = windows[.one]?.isOnActiveSpace ?? false
        let twoActive = windows[.two]?.isOnActiveSpace ?? false
        switch (oneActive, twoActive) {
        case (true, false): return .one
        case (false, true): return .two
        default: return nil
        }
    }

    /// WindowServer window ID for a demo space's window, for occlusion polling.
    func windowID(for space: DemoSpace) -> CGWindowID? {
        windows[space].map { CGWindowID($0.windowNumber) }
    }

    /// Center of the main screen's *content* area (below the menu bar), in the
    /// global display coordinate space CGEvent uses (origin top-left, y down).
    /// This is where the measurement harness posts probe clicks.
    var destinationClickPointCG: CGPoint {
        guard let screen = NSScreen.main else { return .zero }
        let full = screen.frame
        // CGEvent uses a top-left origin. NSScreen uses bottom-left. For a single
        // main display the x is identical; y flips about the full display height.
        let contentMidYFromTop = (menuBarHeight(for: screen)
            + (full.height - menuBarHeight(for: screen)) / 2)
        return CGPoint(x: full.midX, y: contentMidYFromTop)
    }

    private func menuBarHeight(for screen: NSScreen) -> CGFloat {
        // visibleFrame excludes the menu bar (and Dock); the gap at the top is
        // the menu bar height.
        let full = screen.frame
        let visible = screen.visibleFrame
        return full.maxY - visible.maxY
    }

    /// Create window 1 on the CURRENT space, switch right via the CStrafe poster,
    /// then create window 2 on the now-current (neighbor) space. Both windows are
    /// pinned to the space they were created on. Returns after both are up.
    ///
    /// `settle` is how long to wait for the OS to finish the switch before
    /// creating window 2 (the switch itself is instant, but window-server space
    /// bookkeeping needs a beat).
    func setUpWindows(settle: TimeInterval = 0.6) {
        makeWindow(for: .one)
        // Switch right using the exact app code path (CStrafe poster).
        StrafeSwitch.perform(.right)
        // Let the space change settle before pinning window 2 to it. Pump AppKit
        // events (not a bare RunLoop) so window ordering / space bookkeeping and
        // the activeSpaceDidChange notification actually process during the wait.
        pumpEvents(until: Date().addingTimeInterval(settle))
        makeWindow(for: .two)
        // Return home (left) so we start trials from space 1 with both windows up.
        StrafeSwitch.perform(.left)
        pumpEvents(until: Date().addingTimeInterval(settle))

        startDisplayLink()
        installClickMonitor()
    }

    private func makeWindow(for space: DemoSpace) {
        guard let screen = NSScreen.main else { return }
        let full = screen.frame
        let menuH = menuBarHeight(for: screen)
        // Fill the screen below the menu bar (bottom-left origin, so height is
        // reduced by the menu bar and the window sits at y=0).
        let frame = NSRect(x: full.minX, y: full.minY,
                           width: full.width, height: full.height - menuH)

        let window = DemoWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        // Pin to THIS space (created while this space is active). No
        // canJoinAllSpaces: window 1 must stay on space 1, window 2 on space 2.
        window.collectionBehavior = [.stationary, .ignoresCycle]

        let view = DemoContentView(space: space)
        window.contentView = view
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()

        windows[space] = window
        views[space] = view
    }

    // MARK: - Click detection

    private func installClickMonitor() {
        // A local monitor sees clicks routed to our own windows. We identify
        // which demo window (hence which space) got the click by matching the
        // event's window, then stamp it in the CACurrentMediaTime() domain that
        // the measurement uses for T0.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) {
            [weak self] event in
            guard let self else { return event }
            let now = CACurrentMediaTime()
            for (space, window) in self.windows where event.window === window {
                self.views[space]?.flash(now: now)
                self.recorder.record(space: space, now: now)
            }
            return event
        }
    }

    // MARK: - Display link (60fps clock)

    private func startDisplayLink() {
        // The modern, non-deprecated display link runs its selector on the main
        // thread already (the run loop it's added to), so no CV-thread hop.
        guard let window = windows.values.first else { return }
        let link = window.displayLink(target: self, selector: #selector(displayTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        for view in views.values { view.tick(now: now) }
    }

    func teardown() {
        displayLink?.invalidate()
        displayLink = nil
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
        for window in windows.values { window.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
    }
}
