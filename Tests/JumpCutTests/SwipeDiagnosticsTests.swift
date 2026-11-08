import Foundation
import XCTest
@testable import JumpCut

final class SwipeDiagnosticsTests: XCTestCase {
    func testDisabledRecorderDoesNotReadClockOrChangeItsReport() {
        let clock = DiagnosticClock()
        let recorder = SwipeDiagnostics(clock: { clock.read() })
        let before = recorder.report()
        for outcome in SwipeDiagnostics.Outcome.allCases {
            recorder.record(event(), outcome: outcome, topologyReady: false, switchResult: .busy)
        }
        recorder.stop()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(recorder.hasReport)
        XCTAssertEqual(recorder.statusText, "Swipe diagnostics are off")
        XCTAssertEqual(recorder.report(), before)
        XCTAssertEqual(clock.readCount, 0)
    }

    func testDeadlineIsFixedDespiteLateActivityAndExcludesBoundaryEvent() {
        let clock = DiagnosticClock()
        let recorder = SwipeDiagnostics(clock: { clock.read() })
        recorder.start(context: "fixed deadline")
        recorder.record(event(pid: 1), outcome: .beganOwned, topologyReady: true)
        clock.advance(.milliseconds(19_999))
        XCTAssertTrue(recorder.isRecording)
        recorder.record(event(pid: 2), outcome: .changedOwned, switchResult: .submitted)
        clock.advance(.milliseconds(1))
        recorder.record(event(pid: 3), outcome: .endedSuppressed)
        XCTAssertFalse(recorder.isRecording)
        let report = recorder.report()
        XCTAssertTrue(report.contains("20-second deadline reached"))
        XCTAssertTrue(report.contains("Duration: 20.000000 seconds"))
        XCTAssertTrue(report.contains("Captured callbacks: 2"))
        XCTAssertTrue(report.contains("pid=2 "))
        XCTAssertFalse(report.contains("pid=3 "))
        clock.advance(.seconds(60))
        recorder.record(event(pid: 4), outcome: .beganOwned)
        XCTAssertEqual(recorder.report(), report)
    }

    func testDeadlineWithoutCallbacksStillProducesExplicitEmptyReport() {
        let clock = DiagnosticClock()
        let recorder = SwipeDiagnostics(clock: { clock.read() })
        recorder.start(context: "tap enabled at start")
        XCTAssertTrue(recorder.hasReport)
        clock.advance(.seconds(25))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.statusText, "Swipe diagnostic report ready")
        let report = recorder.report()
        XCTAssertTrue(report.contains("tap enabled at start"))
        XCTAssertTrue(report.contains("Captured callbacks: 0"))
        XCTAssertTrue(report.contains("No gesture callbacks were recorded."))
        XCTAssertTrue(report.contains("Duration: 20.000000 seconds"))
    }

    func testDetailCapPreservesLaterDecisionAndSwitchCounts() {
        let clock = DiagnosticClock()
        let recorder = SwipeDiagnostics(clock: { clock.read() })
        recorder.start(context: "bounded capture")
        for pid in 0..<256 {
            recorder.record(event(pid: Int64(pid)), outcome: .changedOwned)
        }
        for _ in 0..<7 {
            recorder.record(event(pid: 9999), outcome: .topologyUnavailable,
                            topologyReady: false, switchResult: .topologyUnavailable)
        }
        for _ in 0..<3 {
            recorder.record(event(pid: 9998), outcome: .endedSuppressed, switchResult: .busy)
        }
        XCTAssertTrue(recorder.isRecording, "The detail cap must not stop decision counting")
        let report = recorder.report()
        XCTAssertEqual(eventLines(report).count, 256)
        XCTAssertTrue(report.contains("Captured callbacks: 266"))
        XCTAssertTrue(report.contains("Detailed events: 256"))
        XCTAssertTrue(report.contains("Truncated: 10 additional events omitted"))
        XCTAssertTrue(report.contains("changedOwned: 256"))
        XCTAssertTrue(report.contains("topologyUnavailable: 7"))
        XCTAssertTrue(report.contains("endedSuppressed: 3"))
        XCTAssertTrue(report.contains("busy: 3"))
        XCTAssertTrue(report.contains("pid=255 "))
        XCTAssertFalse(report.contains("pid=9999 "))
        XCTAssertFalse(report.contains("pid=9998 "))
    }

    func testStopFreezesCaptureAndRestartClearsPreviousSession() {
        let clock = DiagnosticClock()
        let recorder = SwipeDiagnostics(clock: { clock.read() })
        recorder.start(context: "old context")
        recorder.record(event(pid: 41), outcome: .nonzeroPID)
        recorder.stop()
        let stopped = recorder.report()
        clock.advance(.seconds(30))
        recorder.record(event(pid: 42), outcome: .ownSynthetic)
        XCTAssertEqual(recorder.report(), stopped)
        XCTAssertTrue(stopped.contains("Capture: stopped manually"))

        recorder.start(context: "new context")
        XCTAssertTrue(recorder.isRecording)
        recorder.record(event(pid: 43), outcome: .beganOwned, topologyReady: true)
        clock.advance(.seconds(1))
        let restarted = recorder.report() // Copying defensively stops capture.
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(restarted.contains("new context"))
        XCTAssertFalse(restarted.contains("old context"))
        XCTAssertTrue(restarted.contains("Captured callbacks: 1"))
        XCTAssertTrue(restarted.contains("Duration: 1.000000 seconds"))
        XCTAssertTrue(restarted.contains("pid=43 "))
        XCTAssertFalse(restarted.contains("pid=41 "))
        XCTAssertFalse(restarted.contains("pid=42 "))
        XCTAssertFalse(restarted.contains("nonzeroPID"))
    }

    func testReportPreservesRawFieldsAndIncomingState() {
        let clock = DiagnosticClock()
        let recorder = SwipeDiagnostics(clock: { clock.read() })
        recorder.start(context: "raw field probe")
        clock.advance(.milliseconds(125))
        recorder.record(.init(callbackType: UInt32.max, cgsType: 30, hidType: 23,
                              motion: 1, phase: 132, phaseAlias: 4, pid: 42,
                              tagged: true, progress: -0.125, velocityX: 10,
                              velocityY: -2.5, tracking: true, fired: false, posted: false),
                        outcome: .endedNeutralized,
                        overlay: .init(active: false, querySucceeded: true,
                                       layer18: 2, layer20: 3, usesLoneLayer20Rule: false),
                        topologyReady: true, switchResult: .submitted)
        let report = recorder.report()
        let fields = [
            "+0.125000s", "callbackType=4294967295", "cgsType=30", "hidType=23",
            "motion=1", "phase=132", "phaseAlias=4", "pid=42", "tagged=true",
            "progress=-0.125", "velocityX=10.0", "velocityY=-2.5", "tracking=true",
            "fired=false", "posted=false", "outcome=endedNeutralized", "overlay=false",
            "overlayQuerySucceeded=true", "layer18=2", "layer20=3",
            "usesLoneLayer20Rule=false", "topology=true", "switchResult=submitted"
        ]
        for field in fields {
            XCTAssertTrue(eventLines(report).first?.contains(field) == true, "Missing \(field)")
        }
        XCTAssertTrue(report.contains("BEFORE the handler"))
    }

    func testSkippedTopologyIsDistinctFromFailureAndSuccess() {
        let clock = DiagnosticClock()
        let recorder = SwipeDiagnostics(clock: { clock.read() })
        recorder.start(context: "guard outcomes")
        recorder.record(event(), outcome: .overlayActive, overlay: .init(active: true))
        recorder.record(event(), outcome: .topologyUnavailable,
                        overlay: .init(active: false), topologyReady: false)
        recorder.record(event(), outcome: .beganOwned, topologyReady: true)
        let lines = eventLines(recorder.report())
        XCTAssertEqual(lines.count, 3)
        guard lines.count == 3 else { return }
        XCTAssertTrue(lines[0].contains("outcome=overlayActive"))
        XCTAssertTrue(lines[0].contains("topology=not-evaluated"))
        XCTAssertTrue(lines[0].contains("overlayQuerySucceeded=not-provided"))
        XCTAssertTrue(lines[1].contains("outcome=topologyUnavailable"))
        XCTAssertTrue(lines[1].contains("topology=false"))
        XCTAssertTrue(lines[2].contains("topology=true"))
        XCTAssertTrue(lines[2].contains("overlay=not-evaluated"))
        XCTAssertTrue(lines[2].contains("switchResult=not-attempted"))
    }

    private func event(pid: Int64 = 0) -> SwipeDiagnostics.Event {
        .init(callbackType: 30, cgsType: 30, hidType: 23, motion: 1, phase: 1,
              phaseAlias: 1, pid: pid, tagged: false, progress: 0, velocityX: 0,
              velocityY: 0, tracking: false, fired: false, posted: false)
    }

    private func eventLines(_ report: String) -> [Substring] {
        report.split(separator: "\n").filter { $0.hasPrefix("event[") }
    }
}

private final class DiagnosticClock {
    private var now = ContinuousClock().now
    private(set) var readCount = 0

    func read() -> ContinuousClock.Instant {
        readCount += 1
        return now
    }

    func advance(_ duration: Duration) { now = now.advanced(by: duration) }
}
