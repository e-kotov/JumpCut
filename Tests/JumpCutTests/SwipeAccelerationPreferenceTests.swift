import Foundation
import XCTest
@testable import JumpCut

final class SwipeAccelerationPreferenceTests: XCTestCase {
    func testDurationEditPreservesInferredNativeStateAcrossRelaunch() {
        // This mirrors Settings: launch with an old Native preference, move
        // the duration slider without touching the enable checkbox, relaunch.
        for (key, sentinel) in [("transitionDurationMs", 121),
                                ("transitionDurationMsV2", 501)] {
            let suite = "dev.ekotov.jumpcut.native-migration.\(UUID().uuidString)"
            guard let store = UserDefaults(suiteName: suite) else {
                XCTFail("Unable to create isolated preferences")
                continue
            }
            defer { store.removePersistentDomain(forName: suite) }
            store.set(sentinel, forKey: key)
            XCTAssertFalse(SwipeAccelerationPreference.load(from: store))
            TransitionSpeed(milliseconds: 47).persist(to: store)
            XCTAssertEqual(TransitionSpeed.load(from: store).milliseconds, 47)
            XCTAssertEqual(store.object(forKey: SwipeAccelerationPreference.storageKey) as? Bool, false)
            store.synchronize()
            guard let reopened = UserDefaults(suiteName: suite) else {
                XCTFail("Unable to reopen preferences")
                continue
            }
            XCTAssertFalse(SwipeAccelerationPreference.load(from: reopened))
        }
    }

    func testDurationEditPreservesExplicitTogglePrecedence() {
        for (key, sentinel) in [("transitionDurationMs", 121),
                                ("transitionDurationMsV2", 501)] {
            for explicitlyEnabled in [false, true] {
                let suite = "dev.ekotov.jumpcut.explicit-preference.\(UUID().uuidString)"
                guard let store = UserDefaults(suiteName: suite) else {
                    XCTFail("Unable to create isolated preferences")
                    continue
                }
                defer { store.removePersistentDomain(forName: suite) }
                store.set(sentinel, forKey: key)
                SwipeAccelerationPreference.persist(explicitlyEnabled, to: store)
                TransitionSpeed(milliseconds: 60).persist(to: store)
                XCTAssertEqual(SwipeAccelerationPreference.load(from: store), explicitlyEnabled)
                XCTAssertEqual(store.object(forKey: SwipeAccelerationPreference.storageKey) as? Bool,
                               explicitlyEnabled)
                store.synchronize()
                XCTAssertEqual(SwipeAccelerationPreference.load(from: UserDefaults(suiteName: suite)!),
                               explicitlyEnabled)
            }
        }
    }

    func testNumericDurationWithoutNativeDefaultsToEnabled() {
        let suite = "dev.ekotov.jumpcut.default-migration.\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suite) else {
            XCTFail("Unable to create isolated preferences")
            return
        }
        defer { store.removePersistentDomain(forName: suite) }
        TransitionSpeed(milliseconds: 90).persist(to: store)
        XCTAssertEqual(store.object(forKey: SwipeAccelerationPreference.storageKey) as? Bool, true)
        XCTAssertTrue(SwipeAccelerationPreference.load(from: store))
    }

    func testOldNativeSpeedMigratesToDisabledAcceleration() {
        let suite = "dev.ekotov.jumpcut.acceleration-tests.\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suite) else {
            XCTFail("Unable to create isolated preferences")
            return
        }
        defer { store.removePersistentDomain(forName: suite) }
        XCTAssertTrue(SwipeAccelerationPreference.load(from: store))
        store.set(121, forKey: "transitionDurationMs")
        XCTAssertFalse(SwipeAccelerationPreference.load(from: store))
        store.set(47, forKey: "transitionDurationMsV2")
        XCTAssertTrue(SwipeAccelerationPreference.load(from: store))
        store.set(501, forKey: "transitionDurationMsV2")
        XCTAssertFalse(SwipeAccelerationPreference.load(from: store))
        SwipeAccelerationPreference.persist(true, to: store)
        XCTAssertTrue(SwipeAccelerationPreference.load(from: store))
        SwipeAccelerationPreference.persist(false, to: store)
        XCTAssertFalse(SwipeAccelerationPreference.load(from: store))
    }
}
