import CoreGraphics
import Foundation
import CStrafe

/// Owns the `CGEventTap` that detects the user's configured horizontal
/// space-swipe, suppresses it, and fires the engine's instant switch instead
/// (SPEC §2).
///
/// Concurrency: the tap source is installed on the **main** run loop in
/// `kCFRunLoopCommonModes` (SPEC §2.1), so `eventTapCallback` always runs on
/// the main thread. All mutable gesture and tap lifecycle state is
/// therefore touched only from that single run loop and needs
/// no locking. The class is `@unchecked Sendable` because the C callback
/// reaches it through an opaque pointer; that confinement invariant is what
/// makes the unchecked conformance sound.
final class SwipeInterceptor: @unchecked Sendable {
    private let engine: SwitchEngine
    private let readOverlay: () -> SwipeDiagnostics.Overlay
    private let usesIOHIDPayload: () -> Bool
    private var eventTap: (any SwipeEventTap)?
    private let accessibilityGranted: () -> Bool
    private let makeTap: (CGEventTapCallBack, UnsafeMutableRawPointer) -> (any SwipeEventTap)?
    private var recoveryTimer: Timer?
    private var wantsRunning = false
    private var reportedCreationFailure = false
    let diagnostics = SwipeDiagnostics()

    /// Whether the tap is currently created and enabled.
    var isRunning: Bool { eventTap?.isEnabled ?? false }

    var statusDescription: String {
        if !overrideEnabled { return "Swipe interception is paused" }
        if !accessibilityGranted() { return "Accessibility permission required" }
        return isRunning ? "Swipe interception is active" : "Waiting for gesture access — retrying automatically"
    }

    /// Whether interception is active. When false the callback passes every
    /// event through untouched (SPEC §2.2: "only acts when swipeOverrideEnabled").
    var overrideEnabled: Bool = true

    // MARK: - State machine (SPEC §2.3). Main-run-loop confined.
    private var swipeTracking = false
    private var swipeFired = false
    private var swipePosted = false

    init(engine: SwitchEngine,
         isExposeActive: (() -> Bool)? = nil,
         usesIOHIDPayload: @escaping () -> Bool = { strafe_uses_iohid_payload() },
         accessibilityGranted: @escaping () -> Bool = { Permissions.isAccessibilityGranted },
         makeTap: @escaping (CGEventTapCallBack, UnsafeMutableRawPointer) -> (any SwipeEventTap)? = SystemSwipeEventTap.make) {
        self.engine = engine
        if let isExposeActive {
            self.readOverlay = { SwipeDiagnostics.Overlay(active: isExposeActive()) }
        } else {
            self.readOverlay = {
                var details = StrafeOverlayDiagnostics()
                let active = strafe_is_expose_active_with_diagnostics(&details)
                return SwipeDiagnostics.Overlay(
                    active: active, querySucceeded: details.querySucceeded,
                    layer18: Int(details.layer18Count), layer20: Int(details.layer20Count),
                    usesLoneLayer20Rule: details.usesLoneLayer20Rule
                )
            }
        }
        self.usesIOHIDPayload = usesIOHIDPayload
        self.accessibilityGranted = accessibilityGranted
        self.makeTap = makeTap
    }

    deinit {
        recoveryTimer?.invalidate()
        eventTap?.invalidate()
    }

    // MARK: - Lifecycle

    /// Keep trying until the tap exists, including when permission is granted
    /// after launch. The timer only checks trust/tap health; it reads no input.
    func start() {
        wantsRunning = true
        if recoveryTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                self?.recoverIfNeeded()
            }
            recoveryTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        recoverIfNeeded()
    }

    /// Reconcile permission and tap health without creating duplicate taps.
    func recoverIfNeeded() {
        guard wantsRunning else { return }
        guard accessibilityGranted() else {
            eventTap?.invalidate()
            eventTap = nil
            resetGesture()
            return
        }
        if let eventTap {
            if !eventTap.isEnabled {
                resetGesture()
                eventTap.enable()
                // A revoked/invalid tap may no longer be re-enableable.
                if !eventTap.isEnabled {
                    eventTap.invalidate()
                    self.eventTap = nil
                }
            }
            if self.eventTap != nil { return }
        }

        // Trampoline `self` through the tap's userInfo pointer.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = makeTap(
            { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let interceptor = Unmanaged<SwipeInterceptor>
                    .fromOpaque(refcon).takeUnretainedValue()
                return interceptor.handle(type: type, event: event)
            },
            userInfo
        ) else {
            if !reportedCreationFailure {
                FileHandle.standardError.write(Data(
                    "[SwipeInterceptor] gesture tap unavailable; retrying automatically\n".utf8))
                reportedCreationFailure = true
            }
            return
        }
        self.eventTap = tap
        reportedCreationFailure = false
        tap.enable()
    }

    /// Enable the tap, creating it or retrying if permission is pending.
    func enable() {
        start()
    }

    /// Disable the tap without tearing it down (can be re-enabled cheaply).
    func disable() {
        wantsRunning = false
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        eventTap?.disable()
        resetGesture()
    }

    /// Fully remove the tap from the main run loop and release it.
    func teardown() {
        disable()
        eventTap?.invalidate()
        eventTap = nil
    }

    private func resetGesture() {
        swipeTracking = false
        swipeFired = false
        swipePosted = false
    }

    // Explicitly invoked by the menu UI. These operations do not change
    // tracking, interception, or system gesture settings.
    func startSwipeDiagnostics() {
        let build = Bundle.main.object(forInfoDictionaryKey: "JumpCutBuildCommit") as? String ?? "development"
        let idle = readOverlay()
        diagnostics.start(context: """
        Build: \(build)
        OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Capture start: \(statusDescription); tapEnabled=\(isRunning); override=\(overrideEnabled)
        Overlay at capture start (before swiping): active=\(idle.active), layer18=\(idle.layer18.map { String($0) } ?? "unavailable"), layer20=\(idle.layer20.map { String($0) } ?? "unavailable"), querySucceeded=\(idle.querySucceeded.map { String($0) } ?? "unavailable")
        """)
    }

    func swipeDiagnosticsReport() -> String {
        diagnostics.report() + "\nCapture finish: \(statusDescription); tapEnabled=\(isRunning); override=\(overrideEnabled)\n"
    }

    // MARK: - Callback (runs on the main run loop)

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // HOT PATH — runs for every gesture/dock-control event the tap sees.
        // Invariant: the reject path (any non-candidate event) must do zero
        // allocations, no Swift string work, no logging, and acquire no lock.
        // `Unmanaged.passUnretained` only wraps the pointer (no ARC retain).
        // A candidate native began checks topology under the engine lock before
        // taking ownership; an accepted switch also locks through submission.
        let passthrough = Unmanaged.passUnretained(event)

        // Capture scalar input before any terminal-event mutation, and attach
        // the actual decision below. Disabled diagnostics read no extra fields.
        let sample: SwipeDiagnostics.Event? = diagnostics.isRecording ? .init(
            callbackType: type.rawValue, cgsType: strafe_event_cgs_type(event),
            hidType: strafe_event_hid_type(event), motion: strafe_event_swipe_motion(event),
            phase: strafe_event_gesture_phase(event),
            phaseAlias: event.getIntegerValueField(CGEventField(rawValue: 134)!),
            pid: strafe_event_source_pid(event), tagged: strafe_event_is_own_synthetic(event),
            progress: strafe_event_swipe_progress(event),
            velocityX: strafe_event_swipe_velocity_x(event),
            velocityY: event.getDoubleValueField(CGEventField(rawValue: 130)!),
            tracking: swipeTracking, fired: swipeFired, posted: swipePosted
        ) : nil
        var outcome = SwipeDiagnostics.Outcome.unsupportedType
        var overlay: SwipeDiagnostics.Overlay?
        var topologyReady: Bool?
        var switchResult: SwipeDiagnostics.SwitchResult?
        defer {
            if let sample {
                diagnostics.record(sample, outcome: outcome, overlay: overlay,
                                   topologyReady: topologyReady, switchResult: switchResult)
            }
        }

        // SPEC §2.3 / §7.5: the system auto-disables the tap on timeout or
        // heavy user input. Re-enable and pass the event through, else the
        // override silently dies.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            outcome = .tapDisabled
            // A disable can swallow a gesture's `ended`/`cancelled`, leaving the
            // state machine mid-track. Reset before re-enabling so a dropped
            // gesture-end can't leave us stuck suppressing companion events.
            resetGesture()
            if wantsRunning { eventTap?.enable() }
            return passthrough
        }

        // A disabled toggle takes effect at the *next* gesture boundary.
        // If began was already suppressed, finish owning its changed/end
        // phases even after disabling; otherwise macOS receives an orphan
        // partial native stream and tracking can remain stuck on reenable.
        guard overrideEnabled || swipeTracking else { outcome = .paused; return passthrough }

        // Read the private CGSEventType (field 55). We only care about the
        // dock-control swipe and its companion gesture events.
        let cgsType = strafe_event_cgs_type(event)
        let dockControl = strafe_cgs_event_dock_control()
        let gesture = strafe_cgs_event_gesture()

        guard cgsType == dockControl || cgsType == gesture else {
            return passthrough
        }

        // SPEC §2.2 step 3: real HID gestures originate in the kernel with
        // source pid == 0. Synthetic events (ours + any other app's) have a
        // nonzero pid — pass them through so we don't re-trap our own posts.
        // Synthetic gestures may be attributed to PID zero on macOS 27.
        // Explicit event tags stop us re-intercepting our own event pairs.
        if strafe_event_is_own_synthetic(event) {
            outcome = .ownSynthetic
            return passthrough
        }
        if strafe_event_source_pid(event) != 0 {
            outcome = .nonzeroPID
            return passthrough
        }

        // Companion gesture events (type 29) are dropped while tracking (SPEC §2.3).
        if cgsType == gesture {
            outcome = swipeTracking ? .companionSuppressed : .companionPassed
            return swipeTracking ? nil : passthrough
        }

        // From here: a real (pid 0) dock-control event.
        // SPEC §2.2 step 4: require a horizontal dock swipe; anything else
        // (vertical / App Exposé) passes through untouched.
        guard strafe_event_hid_type(event) == strafe_iohid_event_dock_swipe(),
              strafe_event_swipe_motion(event) == strafe_gesture_motion_horizontal()
        else {
            outcome = .nonHorizontal
            return passthrough
        }

        // SPEC §2.3 state machine, driven by the gesture phase (field 132).
        let phase = strafe_event_gesture_phase(event)

        if phase == strafe_gesture_phase_began() {
            resetGesture()
            // A missing terminal must not let a newly begun swipe be owned
            // while the toggle is off, even if tracking was previously set.
            guard overrideEnabled else { outcome = .paused; return passthrough }
            // Decide before swallowing began. Unknown topology and overlays
            // leave the entire native stream (including companions) untouched.
            // Do not start intercepting halfway through if topology recovers.
            let observedOverlay = readOverlay()
            overlay = observedOverlay
            guard !observedOverlay.active else { outcome = .overlayActive; return passthrough }
            let ready = engine.canInterceptGesture()
            topologyReady = ready
            guard ready else { outcome = .topologyUnavailable; return passthrough }
            swipeTracking = true
            swipeFired = false
            swipePosted = false
            outcome = .beganOwned
            return nil  // SUPPRESS the real 'began'

        } else if phase == strafe_gesture_phase_changed() {
            guard swipeTracking else { outcome = .changedWithoutBegin; return passthrough }
            outcome = .changedOwned
            if !swipeFired {
                let progress = strafe_event_swipe_progress(event)
                if progress != 0.0 {
                    // Direction is the sign of progress; fire as soon as known.
                    let dir: SwitchDirection = strafe_event_moves_right(progress) ? .right : .left
                    switchResult = fire(dir)
                }
            }
            return nil  // SUPPRESS

        } else if phase == strafe_gesture_phase_ended() {
            guard swipeTracking else { outcome = .endedWithoutBegin; return passthrough }
            if !swipeFired {
                // Fallback: derive direction from the end velocity's sign.
                let velocity = strafe_event_swipe_velocity_x(event)
                if velocity != 0.0 {
                    let dir: SwitchDirection = strafe_event_moves_right(velocity) ? .right : .left
                    switchResult = fire(dir)
                } else {
                    // Began was suppressed, so this is still our stream even
                    // when it never acquired a direction. Do not forward an
                    // orphan terminal phase to the Dock.
                    resetGesture()
                    outcome = .endedNoDirection
                    return nil
                }
            }
            let didPost = swipePosted
            swipeTracking = false
            swipeFired = false
            swipePosted = false
            if didPost && usesIOHIDPayload() {
                // The Dock still needs the real terminal event to close its
                // native gesture state. Remove motion so it cannot switch twice.
                strafe_clear_swipe_motion(event)
                outcome = .endedNeutralized
                return passthrough
            }
            outcome = .endedSuppressed
            return nil  // SUPPRESS

        } else if phase == strafe_gesture_phase_cancelled() {
            guard swipeTracking else { outcome = .cancelledWithoutBegin; return passthrough }
            swipeTracking = false
            swipeFired = false
            swipePosted = false
            outcome = .cancelledOwned
            return nil

        } else {
            // Any other phase (mayBegin/none): suppress only while tracking.
            outcome = swipeTracking ? .otherSuppressed : .otherPassed
            return swipeTracking ? nil : passthrough
        }
    }

    private func fire(_ direction: SwitchDirection) -> SwipeDiagnostics.SwitchResult {
        swipeFired = true
        do {
            try engine.switchSpace(direction)
            swipePosted = true
            return .submitted
        } catch SwitchEngineError.atEdge {
            // Suppress the entire real gesture, including its terminal event,
            // when no neighboring Space exists. Passing the end through on
            // macOS 27 can trigger the Dock's blank-screen rubber-band effect.
            return .edge
        } catch {
            FileHandle.standardError.write(Data("[SwipeInterceptor] switch failed: \(error)\n".utf8))
            switch error as? SwitchEngineError {
            case .postFailed: return .preparationFailed
            case .topologyUnavailable: return .topologyUnavailable
            case .busy: return .busy
            default: return .otherFailure
            }
        }
    }
}

/// The narrow lifecycle seam lets permission recovery be tested without
/// installing a system event tap or requesting test-runner Accessibility.
protocol SwipeEventTap: AnyObject {
    var isEnabled: Bool { get }
    func enable()
    func disable()
    func invalidate()
}

private final class SystemSwipeEventTap: SwipeEventTap {
    private let port: CFMachPort
    private let source: CFRunLoopSource

    var isEnabled: Bool {
        CFMachPortIsValid(port) && CGEvent.tapIsEnabled(tap: port)
    }

    static func make(callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer) -> (any SwipeEventTap)? {
        // Gesture (29) and dock-control (30) only. Never keyboard events.
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(strafe_tap_event_mask()),
            callback: callback, userInfo: userInfo
        ) else { return nil }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return SystemSwipeEventTap(port: port, source: source)
    }

    private init(port: CFMachPort, source: CFRunLoopSource) {
        self.port = port
        self.source = source
    }

    func enable() { CGEvent.tapEnable(tap: port, enable: true) }
    func disable() { CGEvent.tapEnable(tap: port, enable: false) }
    func invalidate() {
        disable()
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(port)
    }
}
