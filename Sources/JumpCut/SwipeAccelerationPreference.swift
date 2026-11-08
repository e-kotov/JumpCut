import Foundation

/// Off means normal macOS trackpad gestures; JumpCut itself stays running.
/// Preserve any previous Native speed choice as disabled on upgrade.
enum SwipeAccelerationPreference {
    static let storageKey = "swipeAccelerationEnabled"

    static var stored: Bool { load(from: Preferences.store) }

    static func load(from store: UserDefaults) -> Bool {
        if let enabled = store.object(forKey: storageKey) as? Bool { return enabled }
        if let value = store.object(forKey: "transitionDurationMsV2") as? Int {
            return value != 501
        }
        if let value = store.object(forKey: "transitionDurationMs") as? Int {
            return value != 121
        }
        return true
    }

    static func persist(_ enabled: Bool, to store: UserDefaults = Preferences.store) {
        store.set(enabled, forKey: storageKey)
    }
}
