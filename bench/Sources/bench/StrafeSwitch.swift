import Foundation
import CStrafe

/// Direction of a single-step space switch. Mirrors the app's `SwitchDirection`
/// (which lives in the strafe *executable* target and so isn't importable here);
/// bench depends only on the CStrafe C library product.
enum SwitchDirection: Sendable {
    case left
    case right

    var cDirection: StrafeDirection {
        self == .left ? StrafeDirectionLeft : StrafeDirectionRight
    }
}

/// Thin wrapper over the CStrafe poster. bench calls the SAME C entry point the
/// shipped app calls (`strafe_post_switch_gesture` via `GestureSwitchEngine`), so
/// the "strafe" measurement exercises the real synthesis code path.
///
/// The app's `GestureSwitchEngine` additionally does bounds/prediction
/// bookkeeping around this call; bench deliberately posts unconditionally
/// because the demo-window trials always have a valid neighbor to switch to and
/// we do not want prediction state to skip a post mid-run. The gesture-posting
/// itself — the thing whose latency we measure — is byte-for-byte identical.
enum StrafeSwitch {
    static let instantVelocity: Double = 2000.0

    @discardableResult
    static func perform(_ direction: SwitchDirection) -> Bool {
        strafe_post_switch_gesture(direction.cDirection, instantVelocity)
    }
}
