# Integration notes

Base: `rileycx/strafe` at `42f69de6007348f7da0f5cba8c5b3ec534f18da2`.

- Renamed SwiftPM executable and test target to `JumpCut`; moved Swift source into `Sources/JumpCut` and tests into `Tests/JumpCutTests`. Product bundle `JumpCut.app`, executable `JumpCut`, preferences domain `dev.ekotov.jumpcut`.
- Retained internal `CStrafe` module and C symbols to reduce unnecessary changes, as well as the original benchmark harness (its historical comparisons are not JumpCut results).
- Optional keyboard shortcuts default off. The native macOS Ctrl+arrow preferences remain unchanged.
- macOS 27 synthetic instant swipe uses progress `0.1` and high terminal velocity `9999`, based on noswoosh 1.7.7 observations. Earlier OS path unchanged.
- Synthetic Dock gestures and companion events are tagged with `0x4A554D50` only after serialization. The tap excludes explicitly tagged events and nonzero source PIDs.
- C and Swift regression tests cover the tagged event and new gesture profile.
- Not adopted from noswoosh: LaunchAgent, system shortcut rewriting, Dock preference clearing, automatic focus guard, nor direct SkyLight switching.

See `docs/VALIDATION.md` before interpreting the change as macOS 27-safe.

## Reliable-swipe integration

The macOS 27 payload, `0.1`/`9999` profile, synthetic tags, separate incoming
and outgoing direction conventions, gesture-only tap, permission recovery and
optional Carbon hotkeys were already present. This change adds the following.

### Complete preparation

The C layer prepares the complete began/changed/ended sequence, including every
augmented event and companion, before anything is posted. Animated presets
prepare all eight changed phases too. Any allocation, serialization or final-tag
verification failure releases all prepared objects and posts nothing. Capability
and Natural Scrolling are sampled once per sequence, and tags are set and checked
after augmentation.

The Swift engine prepares and posts one complete gesture before returning. A
nonblocking gate rejects a simultaneous caller as busy, so instant and animated
streams cannot interleave or accumulate a backlog based on stale boundaries.
A preparation failure is reported before advancing the prediction. The
standalone benchmark's single-phase API remains available; it makes only a
per-phase preparation guarantee.

This is all-or-nothing **preparation**. `CGEventPost` has no acceptance result,
and posting is neither transactional nor a guarantee that the Dock switched.
Prebuilt event timestamps precede delivery; animated timing still needs the
physical checks in [VALIDATION.md](VALIDATION.md).

Synchronous submission preserves the original instant path's ordering: its
synthetic ended is submitted before the interceptor returns the neutralized real
terminal event on macOS 27. All positive ramp durations also complete before returning, including the
user's configurable 1–120 ms pacing (plus scheduling and processing overhead).
Instant at 0 ms adds no intentional delay. This responsiveness tradeoff
avoids a new native-event replay mechanism and needs device validation.

### Prediction policy

Each display has its own predicted target, exact ordered Space IDs and a fixed
500 ms deadline measured with Swift's monotonic `ContinuousClock`. The deadline
starts with the first accepted sequence in a burst; later commands and
notifications do not extend it. The clock continues through sleep.

While the burst is valid, a live Space visited by that burst can be an
intermediate/late notification. Keep the target in that case, including an
`A → B → A` reversal whose live state still says `A`. A live Space outside the
visited set, changed ordered IDs, or expiry reconciles against the live query.
Notifications reconcile the cursor display and prune expiry; they do not blindly
erase every display's predictions. Other displays are rechecked on use.

There are no deferred switch reservations. A concurrent caller is rejected as
busy before preparation and prediction advancement. An already-started gesture
always completes; topology is rechecked before the next one.

An external/native switch to a Space already visited in the same burst cannot
be distinguished from a delayed acknowledgement. It can remain ambiguous for
up to 500 ms. Likewise, posted events the Dock ignores can temporarily produce
wrong predictions; the deadline prevents indefinite reuse. No claim of confirmed
Dock acceptance is inferred from a successful preparation or notification.

### Unknown topology

The C parser validates container types, display identity, Space IDs, uniqueness,
active-Space membership and bounds. All ordered IDs, including fullscreen
Spaces, are retained. Same-count reorder/replacement therefore invalidates a
prediction. More than 128 Spaces is conservatively unavailable, never truncated.

Failed/ambiguous cursor-display lookup does not use another display's bounds.
Missing, malformed or unmatched data does not become index zero. Shared or
mirrored layouts that cannot identify exactly one matching display may therefore
use native swiping instead of acceleration.

The interceptor checks readiness before suppressing began and latches that
decision for the whole stream. If topology is initially unavailable, all native
phases and companions pass through. If it disappears after began was suppressed,
the remaining owned stream is suppressed and the next gesture can recover; it
cannot be reconstructed by forwarding only its ending. A failed preparation,
busy engine or confirmed boundary likewise does not forward a partial stream.
CLI/optional hotkey calls report unavailable topology rather than guessing.

No automatic focus-taking guard is included. Empty-desktop focus/jump-back
behavior remains a real-device validation item. Historical upstream latency
figures are no longer presented as JumpCut timings in the speed menu.

### Live transition pacing

Settings exposes a slider and 1 ms stepper over 0–120 ms, plus an exact-value
field (commit with Return). Slider and stepper callbacks synchronously update
the running engine under its lock and persist immediately. Each new switch
samples the current duration when it prepares its complete gesture; the active
sequence cannot change timing halfway through. The Settings window joins
Spaces so it can remain open while testing swipes. This range is deliberately
bounded because pacing occurs in the event-tap callback.

0 ms uses the existing instant synthetic profile; positive durations adjust
only the delay in the same eight-phase ramp (the peak progress and end velocity
remain unchanged). This is not an end-to-end animation-latency setting.

Existing saved `transitionSpeed` values 0/1/2 migrate on read to 0/30/60 ms
unless `transitionDurationMs` has been set; retired 3 or invalid old presets
fall back to Instant. The CLI accepts exact 0–120 millisecond values as well
as its old `instant`, `quick`, `smooth` aliases. CLI writes while the app
runs affect the next launch rather than notifying the resident app.

### Rollback to measured stable pacing

The macOS 27.2 physical test confirmed that the experimental 121–500 ms
synthetic ramps can cause visual glitches. The deferred posting worker,
native-terminal replay and synthetic Native mode have been removed; only
0–120 ms remains, using the previous synchronous, all-events-prepared path.

For native macOS animation, uncheck **Accelerate trackpad Space swipes** in
Settings or use the matching menu-bar action. The checkbox and menu share a
persistent state, apply immediately, and leave JumpCut running. Optional
keyboard shortcuts operate independently.

The experimental V2 duration preference remains readable to avoid losing
user choices. Invalid/slow durations are clamped to 120 ms; former Native
sentinels (501 in V2 or 121 in the earlier duration key) are interpreted as
disabled acceleration unless explicitly overridden. Subsequent numeric
changes are persisted to the V2 duration key; the old sentinel is never
written again.

### Changing interception while a gesture is in progress

The swipe-acceleration toggle takes effect at gesture boundaries. If JumpCut
has already suppressed the native began phase, it continues owning the rest of
that gesture even if the user turns acceleration off. This prevents forwarding
an orphan changed/end event and preserves macOS 27 terminal neutralization.
A subsequent swipe is passed through natively. Conversely, enabling
acceleration after a native began does not seize an incomplete stream.
The next began resets stale tracking if the previous terminal was lost.

When upgrading from an older Native selection, editing the numeric duration
now explicitly saves the inferred enable/disable state before overwriting the
old duration-based Native sentinel. Any previously explicit toggle choice wins.
