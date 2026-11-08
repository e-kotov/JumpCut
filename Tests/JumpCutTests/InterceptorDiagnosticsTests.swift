import CoreGraphics
import CStrafe
import XCTest
@testable import JumpCut

final class InterceptorDiagnosticsTests: XCTestCase {
    func testOverlayRejectionRecordsTheActualDecisionWithoutQueryingTopology() {
        let engine = DiagnosticEngine()
        var overlayQueries = 0
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: {
            overlayQueries += 1
            return true
        })
        interceptor.diagnostics.start(context: "fixture")
        let begin = event(1)
        XCTAssertTrue(send(begin, to: interceptor)?.takeUnretainedValue() === begin)
        XCTAssertEqual(overlayQueries, 1)
        XCTAssertEqual(engine.readinessChecks, 0)
        let report = interceptor.diagnostics.report()
        XCTAssertTrue(report.contains("outcome=overlayActive"))
        XCTAssertTrue(report.contains("topology=not-evaluated"))
    }

    func testTopologyRejectionIsDistinctFromOverlayRejection() {
        let engine = DiagnosticEngine()
        engine.ready = false
        var overlayQueries = 0
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: {
            overlayQueries += 1
            return false
        })
        interceptor.diagnostics.start(context: "fixture")
        // The callback result is unretained. Keep the input alive while
        // checking passthrough identity, as the real event-tap caller does.
        let begin = event(1)
        XCTAssertTrue(send(begin, to: interceptor)?.takeUnretainedValue() === begin)
        XCTAssertEqual(overlayQueries, 1)
        XCTAssertEqual(engine.readinessChecks, 1)
        let report = interceptor.diagnostics.report()
        XCTAssertTrue(report.contains("outcome=topologyUnavailable"))
        XCTAssertTrue(report.contains("topology=false"))
    }

    func testNonzeroPIDIsRecordedBeforeOverlayAndTopologyAreConsulted() {
        let engine = DiagnosticEngine()
        var overlayQueries = 0
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: {
            overlayQueries += 1
            return false
        })
        interceptor.diagnostics.start(context: "fixture")
        let begin = event(1)
        begin.setIntegerValueField(.eventSourceUnixProcessID, value: 42)
        XCTAssertEqual(begin.getIntegerValueField(.eventSourceUnixProcessID), 42)
        XCTAssertTrue(send(begin, to: interceptor)?.takeUnretainedValue() === begin)
        XCTAssertEqual(overlayQueries, 0)
        XCTAssertEqual(engine.readinessChecks, 0)
        let report = interceptor.diagnostics.report()
        XCTAssertTrue(report.contains("outcome=nonzeroPID"))
        XCTAssertTrue(report.contains("pid=42"))
    }

    func testDiagnosticsPreserveIncomingMotionBeforeTheNativeEndIsCleared() {
        let engine = DiagnosticEngine()
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: { false },
                                           usesIOHIDPayload: { true })
        interceptor.diagnostics.start(context: "fixture")
        XCTAssertNil(send(event(1), to: interceptor))
        let end = event(4)
        XCTAssertTrue(send(end, to: interceptor)?.takeUnretainedValue() === end)
        XCTAssertEqual(strafe_event_swipe_velocity_x(end), 0)
        XCTAssertEqual(strafe_event_swipe_progress(end), 0)
        let report = interceptor.diagnostics.report()
        let endLine = report.split(separator: "\n").first { $0.contains("outcome=endedNeutralized") }
        XCTAssertNotNil(endLine)
        XCTAssertTrue(endLine?.contains("velocityX=10.0") == true)
        XCTAssertTrue(endLine?.contains("switchResult=submitted") == true)
        XCTAssertEqual(engine.switches, 1)
    }

    func testStartingStoppingAndCopyingCaptureDoNotResetAnOwnedGesture() {
        let engine = DiagnosticEngine()
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: { false },
                                           usesIOHIDPayload: { false })
        XCTAssertNil(send(event(1), to: interceptor))
        interceptor.startSwipeDiagnostics()
        interceptor.diagnostics.stop()
        interceptor.startSwipeDiagnostics()
        _ = interceptor.swipeDiagnosticsReport()
        XCTAssertNil(send(event(2), to: interceptor))
        XCTAssertNil(send(event(4), to: interceptor))
        XCTAssertEqual(engine.switches, 1)
        XCTAssertEqual(engine.readinessChecks, 1)
    }

    private func event(_ phase: Int64) -> CGEvent {
        let event = CGEvent(source: nil)!
        event.setIntegerValueField(CGEventField(rawValue: 55)!, value: 30)
        event.setIntegerValueField(CGEventField(rawValue: 110)!, value: 23)
        event.setIntegerValueField(CGEventField(rawValue: 123)!, value: 1)
        event.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        event.setDoubleValueField(CGEventField(rawValue: 124)!, value: 0.1)
        event.setDoubleValueField(CGEventField(rawValue: 129)!, value: 10)
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUnixProcessID), 0)
        return event
    }

    private func send(_ event: CGEvent, to interceptor: SwipeInterceptor) -> Unmanaged<CGEvent>? {
        interceptor.handle(type: CGEventType(rawValue: 30)!, event: event)
    }
}

private final class DiagnosticEngine: SwitchEngine {
    var ready = true
    var readinessChecks = 0
    var switches = 0
    func canInterceptGesture() -> Bool { readinessChecks += 1; return ready }
    func switchSpace(_ direction: SwitchDirection) throws { switches += 1 }
}
