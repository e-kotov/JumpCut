import CoreGraphics
import Foundation
import CStrafe
import XCTest
@testable import JumpCut

final class NativePassthroughTests: XCTestCase {
    func testDiscreteNativeEndCannotOvertakeSyntheticEndForAnySpeedOrOSPath() {
        for modern in [false, true] {
            for speed in [TransitionSpeed.instant, .quick, .smooth, .init(milliseconds: 1),
                      .init(milliseconds: 47), .init(milliseconds: 120)] {
                let fixture = NativeEndOrderFixture()
                DispatchQueue.global().async { fixture.run(speed: speed, modern: modern) }
                XCTAssertEqual(fixture.started.wait(timeout: .now() + 5), .success)
                // The first known direction arrives in ended. Hold the real
                // engine's posting action mid-stream: handle must not return
                // that native terminal before the synthetic ended is submitted.
                XCTAssertEqual(fixture.returned.wait(timeout: .now() + .milliseconds(50)), .timedOut)
                XCTAssertEqual(fixture.events, ["synthetic:began"])
                fixture.release.signal()
                XCTAssertEqual(fixture.finished.wait(timeout: .now() + 5), .success)
                XCTAssertEqual(fixture.events, [
                    "synthetic:began", "synthetic:changed", "synthetic:ended",
                    modern ? "native:neutral-end" : "native:suppressed-end"
                ])
            }
        }
    }

    func testDisablingMidOwnedGestureFinishesItBeforeNativePassthrough() {
        for modern in [false, true] {
            let engine = ReadinessEngine()
            let interceptor = SwipeInterceptor(engine: engine, isExposeActive: { false },
                                               usesIOHIDPayload: { modern })
            XCTAssertNil(send(event(1), through: interceptor))
            interceptor.overrideEnabled = false
            XCTAssertNil(send(event(0, companion: true), through: interceptor))
            XCTAssertNil(send(event(2), through: interceptor))
            XCTAssertEqual(engine.attempts, 1)
            let end = event(4)
            let result = send(end, through: interceptor)
            if modern {
                XCTAssertTrue(result?.takeUnretainedValue() === end)
                XCTAssertEqual(strafe_event_swipe_progress(end), 0)
                XCTAssertEqual(strafe_event_swipe_velocity_x(end), 0)
            } else {
                XCTAssertNil(result)
            }
            assertPassed(event(0, companion: true), through: interceptor)

            // The next complete swipe is entirely native while paused.
            for sample in [event(1), event(0, companion: true),
                           event(2), event(4)] {
                assertPassed(sample, through: interceptor)
            }
            XCTAssertEqual(engine.attempts, 1)

            // Reenable without restarting. No stale tracking or companion
            // suppression remains from the first, already-owned stream.
            interceptor.overrideEnabled = true
            XCTAssertNil(send(event(1), through: interceptor))
            XCTAssertNil(send(event(0, companion: true), through: interceptor))
            XCTAssertNil(send(event(2), through: interceptor))
            XCTAssertEqual(engine.attempts, 2)
            _ = send(event(4), through: interceptor)
        }
    }

    func testEnablingMidNativeGestureDoesNotCaptureOrphanPhases() {
        let engine = ReadinessEngine()
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: { false })
        interceptor.overrideEnabled = false
        assertPassed(event(1), through: interceptor)
        interceptor.overrideEnabled = true
        assertPassed(event(0, companion: true), through: interceptor)
        assertPassed(event(2), through: interceptor)
        assertPassed(event(4), through: interceptor)
        XCTAssertEqual(engine.attempts, 0)
        XCTAssertNil(send(event(1), through: interceptor))
        XCTAssertNil(send(event(2), through: interceptor))
        XCTAssertEqual(engine.attempts, 1)
    }

    func testMissingTerminalThenDisableClearsOwnershipOnNextBegan() {
        let engine = ReadinessEngine()
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: { false })
        XCTAssertNil(send(event(1), through: interceptor))
        interceptor.overrideEnabled = false
        // Simulate a dropped end: a new began while paused must pass through,
        // not inherit ownership from the previous interrupted stream.
        for sample in [event(1), event(0, companion: true),
                       event(2), event(4)] {
            assertPassed(sample, through: interceptor)
        }
        XCTAssertEqual(engine.attempts, 0)
        interceptor.overrideEnabled = true
        XCTAssertNil(send(event(1), through: interceptor))
        XCTAssertNil(send(event(2), through: interceptor))
        XCTAssertEqual(engine.attempts, 1)
    }

    func testDisablingAndReenablingWithinOwnedGestureKeepsSameStream() {
        let engine = ReadinessEngine()
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: { false },
                                           usesIOHIDPayload: { true })
        XCTAssertNil(send(event(1), through: interceptor))
        interceptor.overrideEnabled = false
        interceptor.overrideEnabled = true
        XCTAssertNil(send(event(2), through: interceptor))
        XCTAssertEqual(engine.attempts, 1)
        let end = event(4)
        XCTAssertTrue(send(end, through: interceptor)?.takeUnretainedValue() === end)
        XCTAssertEqual(strafe_event_swipe_progress(end), 0)
        assertPassed(event(0, companion: true), through: interceptor)
    }

    func testUnknownTopologyLeavesWholeGestureNativeEvenIfItRecovers() {
        let engine = ReadinessEngine()
        engine.available = false
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: { false })
        assertPassed(event(1), through: interceptor)
        engine.available = true
        assertPassed(event(0, companion: true), through: interceptor)
        assertPassed(event(2), through: interceptor)
        assertPassed(event(4), through: interceptor)
        assertPassed(event(0, companion: true), through: interceptor)
        XCTAssertEqual(engine.attempts, 0)
        XCTAssertEqual(engine.readinessChecks, 1)

        XCTAssertNil(send(event(1), through: interceptor))
        XCTAssertNil(send(event(2), through: interceptor))
        _ = send(event(4), through: interceptor)
        XCTAssertEqual(engine.attempts, 1)
    }

    func testUnknownTopologyCancellationAndCompanionsPassThrough() {
        let engine = ReadinessEngine()
        engine.available = false
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: { false })
        for sample in [event(1), event(0, companion: true), event(2), event(8)] {
            assertPassed(sample, through: interceptor)
        }
        XCTAssertEqual(engine.attempts, 0)
    }

    func testTopologyLostAfterBeganDoesNotForwardAnIncompleteNativeGesture() {
        let engine = ReadinessEngine()
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: { false })
        XCTAssertNil(send(event(1), through: interceptor))
        engine.available = false
        XCTAssertNil(send(event(2), through: interceptor))
        XCTAssertNil(send(event(0, companion: true), through: interceptor))
        XCTAssertNil(send(event(4), through: interceptor))
        XCTAssertEqual(engine.attempts, 1)

        // The next stream is native from began; no half-stream replay.
        for sample in [event(1), event(2), event(4)] { assertPassed(sample, through: interceptor) }
        XCTAssertEqual(engine.attempts, 1)
    }

    func testPreparationFailureSuppressesOwnedStreamAndNextGestureCanRecover() {
        let engine = ReadinessEngine()
        engine.failPreparation = true
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: { false })
        XCTAssertNil(send(event(1), through: interceptor))
        XCTAssertNil(send(event(2), through: interceptor))
        XCTAssertNil(send(event(2), through: interceptor))
        XCTAssertNil(send(event(4), through: interceptor))
        XCTAssertEqual(engine.attempts, 1)

        engine.failPreparation = false
        XCTAssertNil(send(event(1), through: interceptor))
        XCTAssertNil(send(event(2), through: interceptor))
        _ = send(event(4), through: interceptor)
        XCTAssertEqual(engine.attempts, 2)
    }

    func testTaggedCompanionsPassThroughEvenWhileTracking() {
        let engine = ReadinessEngine()
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: { false })
        XCTAssertNil(send(event(1), through: interceptor))
        XCTAssertNil(send(event(0, companion: true), through: interceptor))
        let synthetic = event(0, companion: true)
        synthetic.setIntegerValueField(.eventSourceUserData, value: 0x4A554D50)
        XCTAssertEqual(synthetic.getIntegerValueField(.eventSourceUnixProcessID), 0)
        XCTAssertEqual(synthetic.getIntegerValueField(.eventSourceUserData), 0x4A554D50)
        assertPassed(synthetic, through: interceptor)
        XCTAssertEqual(engine.attempts, 0)
    }

    func testOwnedGestureWithoutDirectionDoesNotForwardOrphanEnd() {
        let engine = ReadinessEngine()
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: { false })
        XCTAssertNil(send(event(1), through: interceptor))
        for phase: Int64 in [2, 4] {
            let stationary = event(phase)
            stationary.setDoubleValueField(CGEventField(rawValue: 124)!, value: 0)
            stationary.setDoubleValueField(CGEventField(rawValue: 129)!, value: 0)
            XCTAssertNil(send(stationary, through: interceptor))
        }
        assertPassed(event(0, companion: true), through: interceptor)
        XCTAssertEqual(engine.attempts, 0)
        XCTAssertNil(send(event(1), through: interceptor))
        XCTAssertNil(send(event(2), through: interceptor))
        XCTAssertEqual(engine.attempts, 1)
    }

    func testTapDisableResetsTrackingAndDoesNotConsumeNextCompanion() {
        let engine = ReadinessEngine()
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: { false })
        for disabledType in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            XCTAssertNil(send(event(1), through: interceptor))
            let disabled = event(0)
            XCTAssertTrue(interceptor.handle(type: disabledType, event: disabled)?.takeUnretainedValue() === disabled)
            assertPassed(event(0, companion: true), through: interceptor)
        }
        XCTAssertEqual(engine.attempts, 0)
    }

    private func event(_ phase: Int64, companion: Bool = false) -> CGEvent {
        let event = CGEvent(source: nil)!
        event.setIntegerValueField(CGEventField(rawValue: 55)!, value: companion ? 29 : 30)
        event.setIntegerValueField(CGEventField(rawValue: 110)!, value: 23)
        event.setIntegerValueField(CGEventField(rawValue: 123)!, value: 1)
        event.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        event.setDoubleValueField(CGEventField(rawValue: 124)!, value: 0.1)
        event.setDoubleValueField(CGEventField(rawValue: 129)!, value: 10)
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        return event
    }

    private func send(_ event: CGEvent, through interceptor: SwipeInterceptor) -> Unmanaged<CGEvent>? {
        interceptor.handle(type: CGEventType(rawValue: UInt32(strafe_event_cgs_type(event)))!, event: event)
    }

    private func assertPassed(_ event: CGEvent, through interceptor: SwipeInterceptor,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(send(event, through: interceptor)?.takeUnretainedValue() === event, file: file, line: line)
        XCTAssertEqual(strafe_event_swipe_progress(event), 0.1, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(strafe_event_swipe_velocity_x(event), 10, file: file, line: line)
    }
}

/// The interceptor is still confined to one thread in this fixture. Only the
/// synchronized recorder/semaphores cross threads; no desktop event is posted.
private final class NativeEndOrderFixture: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let returned = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var recorded: [String] = []

    var events: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    private func append(_ value: String) {
        lock.lock(); defer { lock.unlock() }; recorded.append(value)
    }

    func run(speed: TransitionSpeed, modern: Bool) {
        defer { finished.signal() }
        let engine = GestureSwitchEngine(spaceInfo: { makeTestSpaceInfo() }, prepare: { _, _, _ in
            return {
                self.append("synthetic:began")
                self.started.signal()
                self.release.wait()
                self.append("synthetic:changed")
                self.append("synthetic:ended")
            }
        })
        engine.setTransitionSpeed(speed)
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: { false },
                                           usesIOHIDPayload: { modern })
        let begin = event(1)
        _ = interceptor.handle(type: CGEventType(rawValue: 30)!, event: begin)
        let end = event(4)
        let result = interceptor.handle(type: CGEventType(rawValue: 30)!, event: end)
        if result == nil {
            append("native:suppressed-end")
        } else if strafe_event_swipe_progress(end) == 0 && strafe_event_swipe_velocity_x(end) == 0 {
            append("native:neutral-end")
        } else {
            append("native:unmodified-end")
        }
        returned.signal()
    }

    private func event(_ phase: Int64) -> CGEvent {
        let event = CGEvent(source: nil)!
        event.setIntegerValueField(CGEventField(rawValue: 55)!, value: 30)
        event.setIntegerValueField(CGEventField(rawValue: 110)!, value: 23)
        event.setIntegerValueField(CGEventField(rawValue: 123)!, value: 1)
        event.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        event.setDoubleValueField(CGEventField(rawValue: 129)!, value: 10)
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        return event
    }
}

private final class ReadinessEngine: SwitchEngine {
    var available = true
    var failPreparation = false
    var readinessChecks = 0
    var attempts = 0

    func canInterceptGesture() -> Bool {
        readinessChecks += 1
        return available
    }

    func switchSpace(_ direction: SwitchDirection) throws {
        attempts += 1
        if !available { throw SwitchEngineError.topologyUnavailable }
        if failPreparation { throw SwitchEngineError.postFailed }
    }
}
