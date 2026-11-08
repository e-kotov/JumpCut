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
