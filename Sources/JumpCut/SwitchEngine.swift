import Foundation
import CStrafe

/// The direction to move between macOS Spaces.
enum SwitchDirection: Sendable {
    case left
    case right

    var cDirection: StrafeDirection {
        self == .left ? StrafeDirectionLeft : StrafeDirectionRight
    }
}

enum SwitchEngineError: Error, Equatable {
    case atEdge
    /// Preparation failed; none of this sequence's events were posted.
    case postFailed
    case topologyUnavailable
    /// Another complete gesture is being prepared or submitted.
    case busy
}

protocol SwitchEngine {
    func switchSpace(_ direction: SwitchDirection) throws
    /// Checked before the interceptor takes ownership of a native gesture.
    func canInterceptGesture() -> Bool
}

extension SwitchEngine {
    func canInterceptGesture() -> Bool { true }
}

struct StubSwitchEngine: SwitchEngine {
    func switchSpace(_ direction: SwitchDirection) throws {
        let arrow = direction == .left ? "←" : "→"
        FileHandle.standardError.write(
            Data("[StubSwitchEngine] switchSpace(\(arrow) \(direction))\n".utf8)
        )
    }
}

/// Owns an already prepared C sequence. Releasing an unused owner also releases
/// every prepared event. The engine submits each owner only once.
private final class PreparedGesture: @unchecked Sendable {
    private let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    func post() { strafe_post_prepared_gesture(pointer) }
    deinit { strafe_free_prepared_gesture(pointer) }
}

/// Bounds and predictions are meaningful only for a complete, identified
/// topology. Validate the injected seam as well as the C parser's output.
private struct SpaceSnapshot {
    let displayID: String
    let spaces: [UInt64]
    let current: Int

    init?(_ info: StrafeInfo?) {
        guard let info, info.spaceCount > 0, info.currentIndex < info.spaceCount else {
            return nil
        }
        let capacity = MemoryLayout.size(ofValue: info.spaceIDs) / MemoryLayout<UInt64>.stride
        guard Int(info.spaceCount) <= capacity else { return nil }
        guard let displayID = withUnsafeBytes(of: info.displayID, { raw -> String? in
            guard let end = raw.firstIndex(of: 0), end > 0 else { return nil }
            return String(bytes: raw.prefix(end), encoding: .utf8)
        }) else { return nil }
        let spaces = withUnsafeBytes(of: info.spaceIDs) {
            Array($0.bindMemory(to: UInt64.self).prefix(Int(info.spaceCount)))
        }
        guard !spaces.contains(0), Set(spaces).count == spaces.count else { return nil }
        self.displayID = displayID
        self.spaces = spaces
        self.current = Int(info.currentIndex)
    }
}

/// Preparation, complete event submission and prediction updates share one
/// lock. A concurrent request fails immediately instead of queuing stale work
/// or interleaving streams. Instant has no sleeps; any positive user-selected
/// ramp holds the calling thread for its pacing duration. The interceptor can
/// forward its native terminal only after all synthetic events were submitted.
final class GestureSwitchEngine: SwitchEngine, @unchecked Sendable {
    static let instantVelocity: Double = 2000.0
    static let predictionLifetime: Duration = .milliseconds(500)

    typealias PreparedPost = @Sendable () -> Void

    private struct Prediction {
        let spaces: [UInt64]
        let expiresAt: ContinuousClock.Instant
        var target: Int
        var visited: Set<UInt64>
    }

    private let velocity: Double
    private let spaceInfo: @Sendable () -> StrafeInfo?
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let prepare: @Sendable (SwitchDirection, TransitionSpeed, Double) -> PreparedPost?
    private let lock = NSLock()
    private var predictions: [String: Prediction] = [:]
    private var speed: TransitionSpeed = .default

    init(velocity: Double = GestureSwitchEngine.instantVelocity,
         spaceInfo: @escaping @Sendable () -> StrafeInfo? = {
             var info = StrafeInfo()
             return strafe_get_space_info(&info) ? info : nil
         },
         clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
         prepare: @escaping @Sendable (SwitchDirection, TransitionSpeed, Double) -> PreparedPost? = {
             GestureSwitchEngine.prepareGesture($0, speed: $1, velocity: $2)
         }) {
        self.velocity = velocity
        self.spaceInfo = spaceInfo
        self.clock = clock
        self.prepare = prepare
    }

    var cgsAvailable: Bool { strafe_cgs_available() }

    var transitionSpeed: TransitionSpeed {
        lock.lock(); defer { lock.unlock() }
        return speed
    }

    func setTransitionSpeed(_ newValue: TransitionSpeed) {
        lock.lock(); defer { lock.unlock() }
        speed = newValue
    }

    private static func prepareGesture(_ direction: SwitchDirection,
                                       speed: TransitionSpeed,
                                       velocity: Double) -> PreparedPost? {
        let pointer: OpaquePointer?
        if let rampMs = speed.rampMilliseconds {
            let steps = TransitionSpeed.rampSteps
            pointer = strafe_prepare_ramp_gesture(
                direction.cDirection, TransitionSpeed.rampPeakProgress,
                TransitionSpeed.rampEndVelocity, UInt32(steps),
                UInt32((rampMs / Double(steps)) * 1000.0)
            )
        } else {
            pointer = strafe_prepare_switch_gesture(direction.cDirection, velocity)
        }
        guard let pointer else { return nil }
        let gesture = PreparedGesture(pointer)
        return { gesture.post() }
    }

    func canInterceptGesture() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        discardExpiredPredictions(at: now)
        guard let snapshot = SpaceSnapshot(spaceInfo()) else {
            predictions.removeAll(keepingCapacity: true)
            return false
        }
        _ = prediction(for: snapshot, at: now)
        return true
    }

    func switchSpace(_ direction: SwitchDirection) throws {
        guard lock.try() else { throw SwitchEngineError.busy }
        defer { lock.unlock() }
        let now = clock()
        discardExpiredPredictions(at: now)
        guard let snapshot = SpaceSnapshot(spaceInfo()) else {
            predictions.removeAll(keepingCapacity: true)
            throw SwitchEngineError.topologyUnavailable
        }
        let pending = prediction(for: snapshot, at: now)
        let current = pending?.target ?? snapshot.current
        let target = current + (direction == .right ? 1 : -1)
        guard snapshot.spaces.indices.contains(target) else { throw SwitchEngineError.atEdge }
        // All allocations, augmentation and companions must succeed before
        // submitting any event. The returned action cannot fail preparation
        // halfway through a stream; CGEventPost still has no Dock acknowledgement.
        guard let post = prepare(direction, speed, velocity) else {
            throw SwitchEngineError.postFailed
        }
        var next = pending ?? Prediction(
            spaces: snapshot.spaces,
            expiresAt: now.advanced(by: Self.predictionLifetime),
            target: current, visited: [snapshot.spaces[current]]
        )
        next.target = target
        next.visited.insert(snapshot.spaces[target])
        post()
        predictions[snapshot.displayID] = next
    }

    /// Intermediate notifications can describe any Space visited in a burst.
    /// In particular A→B→A cannot be declared finished just because live still
    /// says A: a delayed B notification may follow it. Keep the final target
    /// until the fixed deadline, or until live state lies outside that path.
    /// An external switch to a visited Space is indistinguishable during this
    /// short window; predictions never extend it by accepting more requests.
    private func prediction(for snapshot: SpaceSnapshot,
                            at now: ContinuousClock.Instant) -> Prediction? {
        guard let prediction = predictions[snapshot.displayID] else { return nil }
        guard now < prediction.expiresAt,
              snapshot.spaces == prediction.spaces,
              prediction.visited.contains(snapshot.spaces[snapshot.current]) else {
            predictions.removeValue(forKey: snapshot.displayID)
            return nil
        }
        return prediction
    }

    private func discardExpiredPredictions(at now: ContinuousClock.Instant) {
        predictions = predictions.filter { now < $0.value.expiresAt }
    }

    /// Notifications do not identify their display. Reconcile the currently
    /// queryable display and expire others; each display's next request also
    /// checks its complete ordered topology before using its prediction.
    func reconcilePredictions() {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        discardExpiredPredictions(at: now)
        guard let snapshot = SpaceSnapshot(spaceInfo()) else {
            predictions.removeAll(keepingCapacity: true)
            return
        }
        _ = prediction(for: snapshot, at: now)
    }
}
