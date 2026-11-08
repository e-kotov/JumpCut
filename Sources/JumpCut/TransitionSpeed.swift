import Foundation

/// Configured pacing for a synthetic Space switch, not measured render latency.
/// Zero uses the original instant flick; positive values use the same eight-step
/// progress ramp with the requested total delay. Limit the ramp to 120 ms:
/// submission is synchronous inside the gesture-tap callback, and longer delays
/// risk making the tap unresponsive. The entire gesture uses one value.
struct TransitionSpeed: Equatable, Sendable {
    static let maximumMilliseconds = 120

    let milliseconds: Int

    init(milliseconds: Int) {
        self.milliseconds = min(max(milliseconds, 0), Self.maximumMilliseconds)
    }

    var rampMilliseconds: Double? {
        milliseconds == 0 ? nil : Double(milliseconds)
    }

    var title: String {
        milliseconds == 0 ? "Instant" : "\(milliseconds) ms"
    }

    var name: String {
        milliseconds == 0 ? "instant" : "\(milliseconds)ms"
    }

    static let instant = TransitionSpeed(milliseconds: 0)
    // Compatibility with prior CLI arguments and preferences; not UI presets.
    static let quick = TransitionSpeed(milliseconds: 30)
    static let smooth = TransitionSpeed(milliseconds: 60)
    static let `default`: TransitionSpeed = .instant

    /// The CLI accepts any exact integer in 0...120 and the old preset names.
    init?(name: String) {
        switch name {
        case "instant": self = .instant
        case "quick": self = .quick
        case "smooth": self = .smooth
        default:
            guard let value = Int(name), (0...Self.maximumMilliseconds).contains(value) else {
                return nil
            }
            self.init(milliseconds: value)
        }
    }

    // Keep ramp shape fixed while timing varies. These constants were already
    // in use for the former Quick/Smooth presets.
    static let rampSteps = 8
    static let rampPeakProgress: Double = 0.35
    static let rampEndVelocity: Double = 130.0

    // The 500 ms experiment used V2, including Native=501. Keep the key to
    // avoid resurrecting obsolete values when a user changes the slider.
    static let storageKey = "transitionDurationMsV2"
    static let previousStorageKey = "transitionDurationMs"
    static let legacyStorageKey = "transitionSpeed"

    static var stored: TransitionSpeed { load(from: Preferences.store) }

    static func load(from store: UserDefaults) -> TransitionSpeed {
        if let milliseconds = store.object(forKey: storageKey) as? Int {
            return milliseconds == 501 ? .instant : TransitionSpeed(milliseconds: milliseconds)
        }
        if let milliseconds = store.object(forKey: previousStorageKey) as? Int {
            return milliseconds == 121 ? .instant : TransitionSpeed(milliseconds: milliseconds)
        }
        switch store.object(forKey: legacyStorageKey) as? Int {
        case 1: return .quick
        case 2: return .smooth
        default: return .instant
        }
    }

    func persist(to store: UserDefaults = Preferences.store) {
        // Older builds encoded Native in the duration itself (121 or 501).
        // Preserve the inferred acceleration choice before replacing that
        // sentinel. An explicit on/off preference always takes precedence.
        if store.object(forKey: SwipeAccelerationPreference.storageKey) == nil {
            SwipeAccelerationPreference.persist(
                SwipeAccelerationPreference.load(from: store), to: store
            )
        }
        store.set(milliseconds, forKey: Self.storageKey)
    }
}
