import Foundation
import CStrafe
import XCTest
@testable import JumpCut

final class PredictionTests: XCTestCase {
    func testRapidSwitchesUsePredictedBoundsWhileLiveStateLags() throws {
        let state = EngineFixture(info: makeTestSpaceInfo(spaces: [10, 20, 30, 40]))
        let engine = state.makeEngine()
        try engine.switchSpace(.right)
        try engine.switchSpace(.right)
        try engine.switchSpace(.right)
        expect(.atEdge, try engine.switchSpace(.right))
        XCTAssertEqual(state.preparationCount, 3)
        XCTAssertEqual(state.completedCount, 3)
    }

    func testIntermediateNotificationDoesNotDiscardFinalTarget() throws {
        let state = EngineFixture(info: makeTestSpaceInfo(spaces: [10, 20, 30, 40]))
        let engine = state.makeEngine()
        try engine.switchSpace(.right)
        try engine.switchSpace(.right)
        state.info = makeTestSpaceInfo(spaces: [10, 20, 30, 40], index: 1)
        engine.reconcilePredictions()
        try engine.switchSpace(.right)
        expect(.atEdge, try engine.switchSpace(.right))
        XCTAssertEqual(state.preparationCount, 3)
    }

    func testReversalSurvivesOriginalThenDelayedIntermediateNotification() throws {
        let state = EngineFixture(info: makeTestSpaceInfo(spaces: [10, 20, 30]))
        let engine = state.makeEngine()
        try engine.switchSpace(.right)
        try engine.switchSpace(.left)
        engine.reconcilePredictions() // live A may still be the original A
        state.info = makeTestSpaceInfo(spaces: [10, 20, 30], index: 1)
        engine.reconcilePredictions() // delayed B must not replace predicted A
        expect(.atEdge, try engine.switchSpace(.left))
        try engine.switchSpace(.right)
        XCTAssertEqual(state.preparationCount, 3)
    }

    func testIgnoredPostsRecoverFromLiveStateAtExpiryWithoutNotification() throws {
        let state = EngineFixture(info: makeTestSpaceInfo(spaces: [10, 20]))
        let engine = state.makeEngine()
        try engine.switchSpace(.right)
        expect(.atEdge, try engine.switchSpace(.right))
        state.advance(.milliseconds(500))
        try engine.switchSpace(.right) // Dock still reports A; expired B is ignored
        XCTAssertEqual(state.preparationCount, 2)
    }

    func testRepeatedRequestsAndNotificationsDoNotExtendDeadline() throws {
        let state = EngineFixture(info: makeTestSpaceInfo())
        let engine = state.makeEngine()
        try engine.switchSpace(.right)
        state.advance(.milliseconds(300))
        try engine.switchSpace(.right)
        engine.reconcilePredictions()
        state.advance(.milliseconds(201))
        expect(.atEdge, try engine.switchSpace(.left))
        XCTAssertEqual(state.preparationCount, 2)
    }

    func testDisplayPredictionsAndDeadlinesAreIndependent() throws {
        let state = EngineFixture(info: makeTestSpaceInfo(display: "A", spaces: [10, 20]))
        let engine = state.makeEngine()
        try engine.switchSpace(.right)
        state.advance(.milliseconds(300))
        state.info = makeTestSpaceInfo(display: "B", spaces: [50, 60])
        try engine.switchSpace(.right)
        state.info = makeTestSpaceInfo(display: "A", spaces: [10, 20])
        engine.reconcilePredictions()
        expect(.atEdge, try engine.switchSpace(.right))
        state.advance(.milliseconds(200))
        try engine.switchSpace(.right) // A expires at 500 ms, regardless of B
        state.info = makeTestSpaceInfo(display: "B", spaces: [50, 60])
        expect(.atEdge, try engine.switchSpace(.right)) // B still predicts its last Space
        XCTAssertEqual(state.preparationCount, 3)
    }

    func testOrderingReplacementAndSpaceCountChangesInvalidatePrediction() throws {
        let replacements: [[UInt64]] = [
            [20, 10, 30], // same count, reordered
            [10, 99, 30], // same count, replaced Space (including fullscreen)
            [10, 20], [10, 20, 30, 40]
        ]
        for replacement in replacements {
            let state = EngineFixture(info: makeTestSpaceInfo(spaces: [10, 20, 30]))
            let engine = state.makeEngine()
            try engine.switchSpace(.right)
            state.info = makeTestSpaceInfo(spaces: replacement)
            engine.reconcilePredictions()
            expect(.atEdge, try engine.switchSpace(.left))
            XCTAssertEqual(state.preparationCount, 1)
        }
    }

    func testLiveStateOutsideVisitedPathOverridesPrediction() throws {
        let state = EngineFixture(info: makeTestSpaceInfo(index: 1))
        let engine = state.makeEngine()
        try engine.switchSpace(.right) // visited B, C
        state.info = makeTestSpaceInfo(index: 4) // native/external jump to E
        engine.reconcilePredictions()
        expect(.atEdge, try engine.switchSpace(.right))
        try engine.switchSpace(.left)
        XCTAssertEqual(state.preparationCount, 2)
    }

    func testPreparationFailureDoesNotAdvanceOrBlockRecovery() throws {
        for speed in [TransitionSpeed.instant, .quick, .smooth, .init(milliseconds: 1),
                      .init(milliseconds: 47), .init(milliseconds: 120)] {
            let state = EngineFixture(info: makeTestSpaceInfo(spaces: [10, 20]))
            let engine = state.makeEngine()
            engine.setTransitionSpeed(speed)
            state.failNextPreparation()
            expect(.postFailed, try engine.switchSpace(.right))
            expect(.atEdge, try engine.switchSpace(.left))
            XCTAssertEqual(state.completedCount, 0)
            try engine.switchSpace(.right)
            XCTAssertEqual(state.preparationCount, 2)
            XCTAssertEqual(state.completedCount, 1)
        }
    }

    func testFailedReversalPreservesEarlierPrediction() throws {
        let state = EngineFixture(info: makeTestSpaceInfo(spaces: [10, 20, 30, 40], index: 1))
        let engine = state.makeEngine()
        try engine.switchSpace(.right) // predicted C
        state.failNextPreparation()
        expect(.postFailed, try engine.switchSpace(.left))
        try engine.switchSpace(.right) // predicted D, because failed reversal did not advance
        expect(.atEdge, try engine.switchSpace(.right))
        XCTAssertEqual(state.preparationCount, 3)
        XCTAssertEqual(state.completedCount, 2)
    }

    func testUnknownAndMalformedTopologyNeverPreparesEvents() {
        var excessiveCount = makeTestSpaceInfo()
        excessiveCount.spaceCount = 129
        var unterminated = makeTestSpaceInfo()
        withUnsafeMutableBytes(of: &unterminated.displayID) { bytes in
            for index in bytes.indices { bytes[index] = 65 }
        }
        var invalidUTF8 = makeTestSpaceInfo()
        withUnsafeMutableBytes(of: &invalidUTF8.displayID) { bytes in
            bytes[0] = 0xff; bytes[1] = 0
        }
        let cases: [StrafeInfo?] = [
            nil, makeTestSpaceInfo(display: ""), unterminated, invalidUTF8,
            makeTestSpaceInfo(spaces: []), excessiveCount,
            makeTestSpaceInfo(index: 5), makeTestSpaceInfo(index: UInt32.max),
            makeTestSpaceInfo(spaces: [10, 0]), makeTestSpaceInfo(spaces: [10, 10])
        ]
        for info in cases {
            let state = EngineFixture(info: info)
            let engine = state.makeEngine()
            XCTAssertFalse(engine.canInterceptGesture())
            expect(.topologyUnavailable, try engine.switchSpace(.right))
            XCTAssertEqual(state.preparationCount, 0)
        }
    }

    func testUnknownTopologyClearsEarlierPredictionBeforeRecovery() throws {
        let state = EngineFixture(info: makeTestSpaceInfo(spaces: [10, 20]))
        let engine = state.makeEngine()
        try engine.switchSpace(.right)
        state.info = nil
        XCTAssertFalse(engine.canInterceptGesture())
        state.info = makeTestSpaceInfo(spaces: [10, 20])
        XCTAssertTrue(engine.canInterceptGesture())
        expect(.atEdge, try engine.switchSpace(.left))
    }

    func testConcurrentRequestsFailWithoutPreparingOrAdvancing() throws {
        let state = EngineFixture(info: makeTestSpaceInfo(spaces: [10, 20, 30]))
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let engine = state.makeEngine { _, _ in
            if state.completedCount == 0 { started.signal(); release.wait() }
        }
        let group = startSwitch(engine, state: state)
        defer { release.signal(); _ = group.wait(timeout: .now() + 5) }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        for _ in 0..<8 { expect(.busy, try engine.switchSpace(.right)) }
        XCTAssertEqual(state.preparationCount, 1)
        XCTAssertEqual(state.completedCount, 0)
        release.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(state.errors, [])
        XCTAssertEqual(state.successCount, 1)
        try engine.switchSpace(.right)
        expect(.atEdge, try engine.switchSpace(.right))
        XCTAssertEqual(state.preparationCount, 2)
        XCTAssertEqual(state.completedCount, 2)
    }


    func testTransitionDurationCoversEveryMillisecondAndMigratesOldPresets() {
        let suite = "dev.ekotov.jumpcut.speed-tests.\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suite) else {
            XCTFail("Unable to create isolated preferences")
            return
        }
        defer { store.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TransitionSpeed.load(from: store), .instant)
        for (legacy, expected) in [(0, 0), (1, 30), (2, 60), (3, 0), (99, 0)] {
            store.removeObject(forKey: TransitionSpeed.storageKey)
            store.set(legacy, forKey: TransitionSpeed.legacyStorageKey)
            XCTAssertEqual(TransitionSpeed.load(from: store).milliseconds, expected)
        }
        for value in 0...TransitionSpeed.maximumMilliseconds {
            let speed = TransitionSpeed(milliseconds: value)
            XCTAssertEqual(TransitionSpeed(name: String(value)), speed)
            XCTAssertEqual(speed.rampMilliseconds, value == 0 ? nil : Double(value))
            speed.persist(to: store)
            XCTAssertEqual(TransitionSpeed.load(from: store), speed)
        }
        XCTAssertEqual(TransitionSpeed(milliseconds: -100), .instant)
        XCTAssertEqual(TransitionSpeed(milliseconds: 400).milliseconds, 120)
        XCTAssertNil(TransitionSpeed(name: "native"))
        store.set(500, forKey: TransitionSpeed.storageKey)
        XCTAssertEqual(TransitionSpeed.load(from: store).milliseconds, 120)
        store.set(501, forKey: TransitionSpeed.storageKey)
        XCTAssertEqual(TransitionSpeed.load(from: store), .instant)
        store.removeObject(forKey: TransitionSpeed.storageKey)
        store.set(121, forKey: TransitionSpeed.previousStorageKey)
        XCTAssertEqual(TransitionSpeed.load(from: store), .instant)
        store.removeObject(forKey: TransitionSpeed.previousStorageKey)
        for invalid in ["-1", "121", "10ms", "1.5", "nan"] {
            XCTAssertNil(TransitionSpeed(name: invalid))
        }
        XCTAssertEqual(TransitionSpeed(name: "quick"), .quick)
        XCTAssertEqual(TransitionSpeed(name: "smooth"), .smooth)
        XCTAssertEqual(TransitionSpeed(name: "instant"), .instant)
        store.set(-99, forKey: TransitionSpeed.storageKey)
        XCTAssertEqual(TransitionSpeed.load(from: store), .instant)
        store.set(999, forKey: TransitionSpeed.storageKey)
        XCTAssertEqual(TransitionSpeed.load(from: store).milliseconds, 120)
    }

    func testChangingDurationImmediatelyAffectsNextGestureWithoutRecreatingEngine() throws {
        let state = EngineFixture(info: makeTestSpaceInfo(spaces: [10, 20, 30, 40, 50]))
        let engine = state.makeEngine { _, speed in
            state.append(String(speed.milliseconds))
        }
        engine.setTransitionSpeed(.init(milliseconds: 0))
        try engine.switchSpace(.right)
        engine.setTransitionSpeed(.init(milliseconds: 17))
        try engine.switchSpace(.right)
        engine.setTransitionSpeed(.init(milliseconds: 89))
        try engine.switchSpace(.right)
        engine.setTransitionSpeed(.init(milliseconds: 120))
        try engine.switchSpace(.right)
        XCTAssertEqual(state.events, ["0", "17", "89", "120"])
        XCTAssertEqual(state.completedCount, 4)
    }

    func testChangingSpeedCannotInterleaveCompleteStreams() throws {
        let pairs: [(TransitionSpeed, TransitionSpeed)] = [(.smooth, .instant), (.instant, .quick)]
        for (first, second) in pairs {
            let state = EngineFixture(info: makeTestSpaceInfo())
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let engine = state.makeEngine { _, speed in
                state.append("\(speed.name):began")
                if state.completedCount == 0 { started.signal(); release.wait() }
                state.append("\(speed.name):changed")
                state.append("\(speed.name):ended")
            }
            engine.setTransitionSpeed(first)
            let group = startSwitch(engine, state: state)
            defer { release.signal(); _ = group.wait(timeout: .now() + 5) }
            XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
            expect(.busy, try engine.switchSpace(.left))
            XCTAssertEqual(state.events, ["\(first.name):began"])
            release.signal()
            XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(state.errors, [])
            engine.setTransitionSpeed(second)
            try engine.switchSpace(.left)
            expect(.atEdge, try engine.switchSpace(.left))
            XCTAssertEqual(state.events, [
                "\(first.name):began", "\(first.name):changed", "\(first.name):ended",
                "\(second.name):began", "\(second.name):changed", "\(second.name):ended"
            ])
        }
    }

    func testEverySpeedSubmitsItsEntireStreamBeforeReturning() {
        for speed in [TransitionSpeed.instant, .quick, .smooth, .init(milliseconds: 1),
                      .init(milliseconds: 47), .init(milliseconds: 120)] {
            let state = EngineFixture(info: makeTestSpaceInfo())
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let engine = state.makeEngine { _, _ in
                started.signal()
                release.wait()
            }
            engine.setTransitionSpeed(speed)
            let group = startSwitch(engine, state: state)
            defer { release.signal(); _ = group.wait(timeout: .now() + 5) }
            XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
            // Returning here would let an intercepted native ended overtake
            // this incomplete synthetic sequence.
            XCTAssertEqual(group.wait(timeout: .now() + 0.05), .timedOut)
            XCTAssertEqual(state.successCount, 0)
            release.signal()
            XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(state.successCount, 1)
            XCTAssertEqual(state.completedCount, 1)
            XCTAssertEqual(state.errors, [])
        }
    }

    func testExpiryDuringSubmissionCannotReserveStaleWork() throws {
        let state = EngineFixture(info: makeTestSpaceInfo(spaces: [10, 20, 30]))
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let engine = state.makeEngine { _, _ in
            if state.completedCount == 0 { started.signal(); release.wait() }
        }
        let group = startSwitch(engine, state: state)
        defer { release.signal(); _ = group.wait(timeout: .now() + 5) }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        state.advance(.seconds(1))
        expect(.busy, try engine.switchSpace(.right))
        XCTAssertEqual(state.preparationCount, 1)
        release.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(state.errors, [])
        try engine.switchSpace(.right) // use live A after the expired submission
        try engine.switchSpace(.right)
        expect(.atEdge, try engine.switchSpace(.right))
        XCTAssertEqual(state.completedCount, 3)
    }

    private func startSwitch(_ engine: GestureSwitchEngine, state: EngineFixture) -> DispatchGroup {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                try engine.switchSpace(.right)
                state.recordResult(nil)
            } catch {
                state.recordResult(error as? SwitchEngineError ?? .postFailed)
            }
        }
        return group
    }

    private func expect(_ error: SwitchEngineError,
                        _ action: @autoclosure () throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) {
            XCTAssertEqual($0 as? SwitchEngineError, error, file: file, line: line)
        }
    }
}

/// Shared with the boundary tests; no CGS query or system event post is needed.
func makeTestSpaceInfo(display: String = "display-a",
                       spaces: [UInt64] = [10, 20, 30, 40, 50],
                       index: UInt32 = 0) -> StrafeInfo {
    var info = StrafeInfo()
    info.currentIndex = index
    info.spaceCount = UInt32(spaces.count)
    withUnsafeMutableBytes(of: &info.displayID) { bytes in
        for (index, byte) in display.utf8.prefix(bytes.count).enumerated() { bytes[index] = byte }
    }
    withUnsafeMutableBytes(of: &info.spaceIDs) { bytes in
        let values = bytes.bindMemory(to: UInt64.self)
        for (index, value) in spaces.prefix(values.count).enumerated() { values[index] = value }
    }
    return info
}

private final class EngineFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: StrafeInfo?
    private var now = ContinuousClock().now
    private var failNext = false
    private var preparations = 0
    private var completed = 0
    private var successes = 0
    private var failures: [SwitchEngineError] = []
    private var recordedEvents: [String] = []

    init(info: StrafeInfo?) { snapshot = info }

    var info: StrafeInfo? {
        get { lock.lock(); defer { lock.unlock() }; return snapshot }
        set { lock.lock(); defer { lock.unlock() }; snapshot = newValue }
    }
    var preparationCount: Int { lock.lock(); defer { lock.unlock() }; return preparations }
    var completedCount: Int { lock.lock(); defer { lock.unlock() }; return completed }
    var successCount: Int { lock.lock(); defer { lock.unlock() }; return successes }
    var errors: [SwitchEngineError] { lock.lock(); defer { lock.unlock() }; return failures }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return recordedEvents }

    func advance(_ duration: Duration) {
        lock.lock(); defer { lock.unlock() }; now = now.advanced(by: duration)
    }

    func failNextPreparation() {
        lock.lock(); defer { lock.unlock() }; failNext = true
    }

    func append(_ event: String) {
        lock.lock(); defer { lock.unlock() }; recordedEvents.append(event)
    }

    func recordResult(_ error: SwitchEngineError?) {
        lock.lock(); defer { lock.unlock() }
        if let error { failures.append(error) } else { successes += 1 }
    }

    func makeEngine(onPost: @escaping @Sendable (SwitchDirection, TransitionSpeed) -> Void = { _, _ in })
        -> GestureSwitchEngine {
        GestureSwitchEngine(spaceInfo: { self.info }, clock: {
            self.lock.lock(); defer { self.lock.unlock() }; return self.now
        }, prepare: { direction, speed, _ in
            self.lock.lock()
            self.preparations += 1
            let failed = self.failNext
            self.failNext = false
            self.lock.unlock()
            guard !failed else { return nil }
            return {
                onPost(direction, speed)
                self.lock.lock(); defer { self.lock.unlock() }; self.completed += 1
            }
        })
    }
}
