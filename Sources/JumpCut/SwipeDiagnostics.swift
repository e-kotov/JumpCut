import Foundation

/// Explicitly enabled, in-memory diagnostics confined to the interceptor's
/// main run loop. Capture retains scalar snapshots, never CGEvents. Starting or
/// stopping it changes no gesture/tap state. Formatting happens only in report().
final class SwipeDiagnostics {
    struct Event {
        let callbackType: UInt32
        let cgsType: Int64
        let hidType: Int64
        let motion: Int64
        let phase: Int64
        let phaseAlias: Int64
        let pid: Int64
        let tagged: Bool
        let progress: Double
        let velocityX: Double
        let velocityY: Double
        let tracking: Bool
        let fired: Bool
        let posted: Bool
    }

    enum Outcome: String, CaseIterable {
        case tapDisabled, paused, unsupportedType, ownSynthetic, nonzeroPID
        case companionPassed, companionSuppressed, nonHorizontal
        case overlayActive, topologyUnavailable, beganOwned
        case changedWithoutBegin, changedOwned
        case endedWithoutBegin, endedNoDirection, endedSuppressed, endedNeutralized
        case cancelledWithoutBegin, cancelledOwned, otherPassed, otherSuppressed
    }

    enum SwitchResult: String, CaseIterable {
        case submitted, edge, preparationFailed, topologyUnavailable, busy, otherFailure
    }

    struct Overlay {
        let active: Bool
        let querySucceeded: Bool?
        let layer18: Int?
        let layer20: Int?
        let usesLoneLayer20Rule: Bool?

        init(active: Bool, querySucceeded: Bool? = nil, layer18: Int? = nil,
             layer20: Int? = nil, usesLoneLayer20Rule: Bool? = nil) {
            self.active = active
            self.querySucceeded = querySucceeded
            self.layer18 = layer18
            self.layer20 = layer20
            self.usesLoneLayer20Rule = usesLoneLayer20Rule
        }
    }

    private struct Record {
        let elapsed: Duration
        let event: Event
        let outcome: Outcome
        let overlay: Overlay?
        let topologyReady: Bool?
        let switchResult: SwitchResult?
    }

    private static let maximumDetailedEvents = 256
    private static let maximumDuration: Duration = .seconds(20)
    private let clock: () -> ContinuousClock.Instant
    private var startedAt: ContinuousClock.Instant?
    private var deadline: ContinuousClock.Instant?
    private var stoppedAt: ContinuousClock.Instant?
    private var reachedDeadline = false
    private var context = ""
    private var records: [Record] = []
    private var totalEvents = 0
    private var outcomeCounts: [Outcome: Int] = [:]
    private var switchCounts: [SwitchResult: Int] = [:]

    init(clock: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now }) {
        self.clock = clock
    }

    var isRecording: Bool {
        guard let deadline else { return false }
        if clock() >= deadline {
            finish(at: deadline, reachedDeadline: true)
            return false
        }
        return true
    }

    /// A zero-event session still has a useful report.
    var hasReport: Bool { startedAt != nil }

    var statusText: String {
        if isRecording { return "Recording swipe diagnostics (20-second limit)" }
        return hasReport ? "Swipe diagnostic report ready" : "Swipe diagnostics are off"
    }

    func start(context: String) {
        let now = clock()
        startedAt = now
        deadline = now.advanced(by: Self.maximumDuration)
        stoppedAt = nil
        reachedDeadline = false
        self.context = context
        records.removeAll(keepingCapacity: true)
        records.reserveCapacity(Self.maximumDetailedEvents)
        totalEvents = 0
        // Populate every key before entering the callback so counting cannot
        // grow either dictionary, including after detailed capture fills up.
        outcomeCounts = Dictionary(uniqueKeysWithValues: Outcome.allCases.map { ($0, 0) })
        switchCounts = Dictionary(uniqueKeysWithValues: SwitchResult.allCases.map { ($0, 0) })
    }

    func stop() {
        guard let deadline else { return }
        let now = clock()
        finish(at: min(now, deadline), reachedDeadline: now >= deadline)
    }

    private func finish(at instant: ContinuousClock.Instant, reachedDeadline: Bool) {
        stoppedAt = instant
        deadline = nil
        self.reachedDeadline = reachedDeadline
    }

    /// No event references, string formatting or I/O on the capture path.
    /// Storage and counters remain bounded even if callbacks exceed the cap.
    func record(_ event: Event, outcome: Outcome, overlay: Overlay? = nil,
                topologyReady: Bool? = nil, switchResult: SwitchResult? = nil) {
        guard let deadline, let startedAt else { return }
        let now = clock()
        guard now < deadline else {
            finish(at: deadline, reachedDeadline: true)
            return
        }
        totalEvents += 1
        outcomeCounts[outcome, default: 0] += 1
        if let switchResult { switchCounts[switchResult, default: 0] += 1 }
        guard records.count < Self.maximumDetailedEvents else { return }
        records.append(Record(elapsed: startedAt.duration(to: now), event: event,
                              outcome: outcome, overlay: overlay,
                              topologyReady: topologyReady, switchResult: switchResult))
    }

    /// Called from the UI, outside the event callback. Stop defensively before
    /// formatting so copying a report cannot race continuing capture.
    func report() -> String {
        stop()
        guard let startedAt, let stoppedAt else {
            return "No swipe diagnostic recording is available."
        }
        var lines = [
            "JumpCut swipe diagnostics",
            "Context at start:", context,
            "Capture: \(reachedDeadline ? "20-second deadline reached" : "stopped manually")",
            "Duration: \(Self.seconds(startedAt.duration(to: stoppedAt))) seconds",
            "Limits: 20 seconds; \(Self.maximumDetailedEvents) detailed events",
            "Captured callbacks: \(totalEvents)",
            "Detailed events: \(records.count)"
        ]
        if totalEvents > records.count {
            lines.append("Truncated: \(totalEvents - records.count) additional events omitted; counts below include them.")
        } else {
            lines.append("Truncated: no")
        }
        if totalEvents == 0 {
            lines.append("No gesture callbacks were recorded. Tap delivery and native event recognition are not established by an empty capture.")
        }
        lines.append("Decisions (including events omitted from details):")
        for outcome in Outcome.allCases {
            if let count = outcomeCounts[outcome], count > 0 {
                lines.append("  \(outcome.rawValue): \(count)")
            }
        }
        if totalEvents == 0 { lines.append("  (none)") }
        lines.append("Switch results (including events omitted from details):")
        var hadSwitch = false
        for result in SwitchResult.allCases {
            if let count = switchCounts[result], count > 0 {
                lines.append("  \(result.rawValue): \(count)")
                hadSwitch = true
            }
        }
        if !hadSwitch { lines.append("  (none)") }
        lines.append("Event details: raw incoming fields and tracking/fired/posted BEFORE the handler. Time offsets are recorded after the handler completes. not-evaluated means the check was skipped.")
        for (index, record) in records.enumerated() {
            let event = record.event
            let topology = record.topologyReady.map { String($0) } ?? "not-evaluated"
            let result = record.switchResult?.rawValue ?? "not-attempted"
            lines.append(
                "event[\(index + 1)] +\(Self.seconds(record.elapsed))s " +
                "callbackType=\(event.callbackType) cgsType=\(event.cgsType) hidType=\(event.hidType) " +
                "motion=\(event.motion) phase=\(event.phase) phaseAlias=\(event.phaseAlias) " +
                "pid=\(event.pid) tagged=\(event.tagged) progress=\(event.progress) " +
                "velocityX=\(event.velocityX) velocityY=\(event.velocityY) " +
                "tracking=\(event.tracking) fired=\(event.fired) posted=\(event.posted) " +
                "outcome=\(record.outcome.rawValue) \(Self.overlayText(record.overlay)) " +
                "topology=\(topology) switchResult=\(result)"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func seconds(_ duration: Duration) -> String {
        let parts = duration.components
        let value = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func observation<T>(_ value: T?) -> String {
        value.map { String(describing: $0) } ?? "not-provided"
    }

    private static func overlayText(_ overlay: Overlay?) -> String {
        guard let overlay else { return "overlay=not-evaluated" }
        return "overlay=\(overlay.active) overlayQuerySucceeded=\(observation(overlay.querySucceeded)) " +
            "layer18=\(observation(overlay.layer18)) layer20=\(observation(overlay.layer20)) " +
            "usesLoneLayer20Rule=\(observation(overlay.usesLoneLayer20Rule))"
    }
}
