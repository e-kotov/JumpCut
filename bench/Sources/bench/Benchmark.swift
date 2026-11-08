import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import CStrafe

/// Which switch mechanism a run measures.
enum BenchMode: String, Sendable {
    case native  // normal-velocity synthetic dock-swipe -> animated Mission Control switch
    case strafe  // strafe_post_switch_gesture -> instant (high-velocity) dock-swipe
}

/// Outcome of a single trial.
struct TrialResult: Sendable {
    let index: Int
    let direction: SwitchDirection
    /// Time-to-interactivity: first destination click delivery − T0, in ms.
    /// `nil` on timeout (recorded as a failure, excluded from stats).
    /// CAVEAT: synthetic probes bypass the input hold WindowServer applies to
    /// real HID input during a transition, so for native this is a lower bound
    /// on what a human experiences — see `transitionMs` for the human-felt end.
    let interactivityMs: Double?
    /// Transition-complete time: source window drops offscreen − T0, in ms.
    /// During a Space slide BOTH spaces' windows are composited on screen; the
    /// source window leaving the screen marks the animation's end — which is
    /// also when macOS starts delivering REAL (human) input to the new space.
    /// This is the human time-to-interactivity proxy.
    let transitionMs: Double?
    /// activeSpaceDidChange − T0, in ms (reference only). `nil` if not observed.
    let spaceChangeMs: Double?
    /// How many probe clicks we posted before the first hit (or timeout).
    let clicksPosted: Int
    /// How many probe clicks the destination window actually received.
    let destinationHits: Int
    /// Clicks that landed on the SOURCE window post-arm (excluded, reported).
    let sourceHits: Int

    var timedOut: Bool { interactivityMs == nil }
}

/// Main-actor box for the last activeSpaceDidChange timestamp.
@MainActor
final class SpaceChangeStamp {
    var value: CFTimeInterval?
}

/// Pump the AppKit event loop until `deadline`, dispatching every queued event
/// via `NSApp.sendEvent(_:)`.
///
/// WHY THIS EXISTS (Bug 1): the trial engine runs on the main thread while
/// `NSApplication.run()` is blocked one frame up the stack. A bare
/// `RunLoop.run(until:)` services run-loop input sources and timers, but it does
/// NOT run NSApplication's `nextEventMatchingMask:` + `sendEvent:` cycle — and
/// that cycle is the ONLY thing that delivers mouse events to
/// `addLocalMonitorForEvents` monitors (our HitRecorder) and to window
/// first-responders. So under the old code the harness posted probe clicks that
/// piled up in the window-server queue and were never dispatched, giving
/// destHits=0 / TIMEOUT every trial. Draining with `nextEventMatchingMask` here
/// keeps AppKit event delivery alive during settle/probe waits.
///
/// `.default` run-loop mode is used (not `.eventTracking`) so main-queue blocks —
/// including the `activeSpaceDidChange` observer posted to `.main` — also run.
@MainActor
func pumpEvents(until deadline: Date) {
    let app = NSApplication.shared
    while true {
        let now = Date()
        if now >= deadline { break }
        // Block up to the remaining interval waiting for the next event; return
        // promptly when one arrives so probe clicks are delivered with minimal
        // added latency. `dequeue: true` + `sendEvent` is what actually fires
        // local monitors and routes clicks to the demo windows.
        guard let event = app.nextEvent(
            matching: .any, until: deadline, inMode: .default, dequeue: true
        ) else { break }
        app.sendEvent(event)
    }
}

/// Runs the trial loop for one mode and emits the table + CSV + summary.
@MainActor
final class Benchmark {
    private let mode: BenchMode
    private let trials: Int
    private let controller: DemoWindowController
    private let recorder: HitRecorder

    /// Probe cadence (SPEC: post a probe click every 4 ms).
    private let probeIntervalMs: Double = 4
    /// Settle time between trials (SPEC: 1.5 s so state returns home).
    private let settleBetweenTrials: TimeInterval = 1.5
    /// Per-trial probe timeout (SPEC: 3 s).
    private let probeTimeout: TimeInterval = 3.0

    private let clickSource = CGEventSource(stateID: .hidSystemState)

    init(mode: BenchMode, trials: Int, controller: DemoWindowController, recorder: HitRecorder) {
        self.mode = mode
        self.trials = trials
        self.controller = controller
        self.recorder = recorder
    }

    /// Execute warmup + `trials` measured trials, print the table, write CSV,
    /// print the summary. Returns the summary so callers can reuse it.
    @discardableResult
    func run(machine: MachineInfo) -> Summary {
        // Observe activeSpaceDidChange for the reference timing. The stamp lives
        // in a main-actor box so the .main-queue observer can write it without
        // tripping strict-concurrency capture rules.
        let stamp = SpaceChangeStamp()
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { stamp.value = CACurrentMediaTime() }
        }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }

        // 1 warmup trial, discarded (SPEC).
        _ = runTrial(index: 0, spaceChangeStamp: { stamp.value },
                     resetStamp: { stamp.value = nil })

        var results: [TrialResult] = []
        results.reserveCapacity(trials)

        for i in 0..<trials {
            // Direction is derived from ground truth inside runTrial (which demo
            // window is actually frontmost), so trials alternate naturally when
            // switches succeed AND self-correct when one fails — an assumed
            // even/odd pattern drifts after any failed switch and produces false
            // sub-10ms hits on a window that never left the screen.
            let result = runTrial(
                index: i + 1,
                spaceChangeStamp: { stamp.value },
                resetStamp: { stamp.value = nil }
            )
            results.append(result)
            // Settle so the next trial starts from a quiesced state. Pump AppKit
            // events (not a bare RunLoop) so any late clicks / space-change
            // notifications still drain instead of piling up for the next trial.
            pumpEvents(until: Date().addingTimeInterval(settleBetweenTrials))
        }

        printTable(results)
        writeCSV(results, machine: machine)
        let summary = Summary(mode: mode, results: results)
        summary.print(machine: machine)
        return summary
    }

    /// One trial. Direction is derived from ground truth: whichever demo window
    /// is frontmost is the source; the trial switches toward the other one.
    private func runTrial(
        index: Int,
        spaceChangeStamp: () -> CFTimeInterval?,
        resetStamp: () -> Void
    ) -> TrialResult {
        guard let here = controller.activeDemoSpace() else {
            // Neither (or both) demo windows report as frontmost: the run has
            // been disturbed (e.g. a manual switch to a third space). Guessing
            // here is how false positives happen — bail out loudly instead.
            FileHandle.standardError.write(Data("""
            bench: cannot determine the current demo space — the machine was \
            likely used mid-run. Keep hands off and re-run.\n
            """.utf8))
            exit(4)
        }
        let direction: SwitchDirection = here == .one ? .right : .left
        let destination: DemoSpace = here == .one ? .two : .one
        recorder.arm(destination: destination)
        resetStamp()

        // T0 is captured immediately before triggering the switch.
        let t0 = CACurrentMediaTime()
        switch mode {
        case .native:
            EventPosting.postNativeSwitch(direction)
        case .strafe:
            // Exact app code path (CStrafe poster).
            StrafeSwitch.perform(direction)
        }

        // Immediately begin probing the destination screen center. We post a
        // probe click, then PUMP APPKIT EVENTS for the 4 ms cadence window so the
        // click is actually dispatched to the destination window's local monitor
        // (see `pumpEvents` — a bare RunLoop would not deliver it, Bug 1). The
        // measured Δ is still first-destination-hit − T0 exactly as documented.
        let point = controller.destinationClickPointCG
        let sourceWindowID = controller.windowID(for: here)
        var clicksPosted = 0
        var transitionEnd: CFTimeInterval?
        let probeCadence = probeIntervalMs / 1000.0
        let wallDeadline = Date().addingTimeInterval(probeTimeout)

        // Run until BOTH signals are captured (or timeout): first probe delivery
        // (event availability) and source-window-offscreen (transition complete —
        // the human input-unlock proxy). Probes stop once the first hit lands;
        // the offscreen poll continues, since for native the animation outlives
        // synthetic event delivery (synthetic probes bypass the HID input hold).
        while recorder.firstHit == nil || transitionEnd == nil {
            if Date() >= wallDeadline { break }
            if recorder.firstHit == nil {
                EventPosting.postProbeClick(at: point, source: clickSource)
                clicksPosted += 1
            }
            if transitionEnd == nil, let id = sourceWindowID,
               !Benchmark.isWindowOnscreen(id) {
                transitionEnd = CACurrentMediaTime()
            }
            // Pump events for the cadence window so the click can be delivered to
            // our window and the local monitor can stamp it. Cap the pump at the
            // overall timeout so a stuck trial can't overrun.
            let pumpUntil = min(Date().addingTimeInterval(probeCadence), wallDeadline)
            pumpEvents(until: pumpUntil)
        }

        let firstHit = recorder.firstHit
        let interactivityMs = firstHit.map { ($0 - t0) * 1000.0 }
        let transitionMs = transitionEnd.map { ($0 - t0) * 1000.0 }
        let spaceChangeMs = spaceChangeStamp().map { ($0 - t0) * 1000.0 }

        let result = TrialResult(
            index: index,
            direction: direction,
            interactivityMs: interactivityMs,
            transitionMs: transitionMs,
            spaceChangeMs: spaceChangeMs,
            clicksPosted: clicksPosted,
            destinationHits: recorder.destinationHitCount,
            sourceHits: recorder.sourceHitCount
        )
        recorder.disarm()
        return result
    }

    /// Whether the WindowServer still composites this window on screen. During a
    /// Space transition both spaces' windows are on screen; the source window
    /// dropping offscreen marks the animation's end.
    private static func isWindowOnscreen(_ id: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id)
                as? [[String: Any]],
              let info = list.first else { return false }
        return (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
    }

    // MARK: - Output

    private func printTable(_ results: [TrialResult]) {
        print("")
        print("trial  dir    interactive(ms)  transition(ms)  spaceChange(ms)  clicksPosted  destHits  srcHits")
        for r in results {
            let inter = r.interactivityMs.map { String(format: "%.1f", $0) } ?? "TIMEOUT"
            let trans = r.transitionMs.map { String(format: "%.1f", $0) } ?? "-"
            let space = r.spaceChangeMs.map { String(format: "%.1f", $0) } ?? "-"
            let dir = r.direction == .right ? "right" : "left "
            print(String(
                format: "%4d   %@  %15@  %14@  %15@  %12d  %8d  %7d",
                r.index, dir, inter as NSString, trans as NSString, space as NSString,
                r.clicksPosted, r.destinationHits, r.sourceHits
            ))
        }
    }

    /// Resolve the results directory to an ABSOLUTE path (Bug 2).
    ///
    /// When launched via `open`, LaunchServices sets the process cwd to "/", so a
    /// cwd-relative "results" resolved to "/results" (filesystem root). Instead:
    ///   - Running from the bundle (bench/build/bench.app/Contents/MacOS/bench):
    ///     derive the bench dir from the bundle path and use bench/results.
    ///     Bundle.main.bundlePath is …/bench/build/bench.app, so ../../results.
    ///   - Running bare (swift run / direct binary, no .app): fall back to
    ///     <cwd>/results.
    static func resultsDirectory() -> URL {
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".app") {
            // …/bench/build/bench.app -> up two (build, bench.app) to bench/, then results.
            let benchDir = URL(fileURLWithPath: bundlePath)
                .deletingLastPathComponent()   // drop bench.app
                .deletingLastPathComponent()   // drop build/
            return benchDir.appendingPathComponent("results")
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("results")
    }

    private func writeCSV(_ results: [TrialResult], machine: MachineInfo) {
        let dir = Benchmark.resultsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(mode.rawValue)-\(trials).csv")

        var lines: [String] = []
        // Machine-info header as CSV comments (redacted — see MachineInfo).
        lines.append("# mode,\(mode.rawValue)")
        for line in machine.block.split(separator: "\n") {
            lines.append("# \(line)")
        }
        lines.append("trial,direction,interactive_ms,transition_ms,space_change_ms,clicks_posted,dest_hits,src_hits,timed_out")
        for r in results {
            let inter = r.interactivityMs.map { String(format: "%.3f", $0) } ?? ""
            let trans = r.transitionMs.map { String(format: "%.3f", $0) } ?? ""
            let space = r.spaceChangeMs.map { String(format: "%.3f", $0) } ?? ""
            let dir = r.direction == .right ? "right" : "left"
            lines.append("\(r.index),\(dir),\(inter),\(trans),\(space),\(r.clicksPosted),\(r.destinationHits),\(r.sourceHits),\(r.timedOut)")
        }
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        print("\nwrote \(url.path)")
    }
}

/// Median / p90 / min / max over the non-timed-out trials.
struct Summary: Sendable {
    let mode: BenchMode
    let median: Double?
    let p90: Double?
    let min: Double?
    let max: Double?
    let valid: Int
    let timeouts: Int

    /// Transition-complete stats (the human input-unlock proxy).
    let transMedian: Double?
    let transP90: Double?
    let transMin: Double?
    let transMax: Double?
    let transValid: Int

    init(mode: BenchMode, results: [TrialResult]) {
        self.mode = mode
        let values = results.compactMap { $0.interactivityMs }.sorted()
        self.valid = values.count
        self.timeouts = results.count - values.count
        if values.isEmpty {
            median = nil; p90 = nil; min = nil; max = nil
        } else {
            median = Summary.percentile(values, 0.50)
            p90 = Summary.percentile(values, 0.90)
            min = values.first
            max = values.last
        }
        let trans = results.compactMap { $0.transitionMs }.sorted()
        self.transValid = trans.count
        if trans.isEmpty {
            transMedian = nil; transP90 = nil; transMin = nil; transMax = nil
        } else {
            transMedian = Summary.percentile(trans, 0.50)
            transP90 = Summary.percentile(trans, 0.90)
            transMin = trans.first
            transMax = trans.last
        }
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let rank = p * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = Int(rank.rounded(.up))
        let frac = rank - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }

    func print(machine: MachineInfo) {
        func fmt(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "n/a" }
        Swift.print("")
        Swift.print("=== \(mode.rawValue) summary (\(valid) valid, \(timeouts) timeout) ===")
        Swift.print("event delivery:      median=\(fmt(median)) ms  p90=\(fmt(p90)) ms  min=\(fmt(min)) ms  max=\(fmt(max)) ms")
        Swift.print("transition complete: median=\(fmt(transMedian)) ms  p90=\(fmt(transP90)) ms  min=\(fmt(transMin)) ms  max=\(fmt(transMax)) ms  (\(transValid) observed — human input unlocks here)")
    }
}
