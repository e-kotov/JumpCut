# JumpCut — instant macOS Spaces switching

JumpCut replaces a three-finger horizontal trackpad swipe's slow desktop-slide animation with a near-instant native macOS Spaces transition. It's an **experimental derivative of [strafe](https://github.com/rileycx/strafe)** with a macOS 27 compositor-safe gesture profile and explicit synthetic-event tagging informed by [noswoosh](https://github.com/mmathys/noswoosh).

> **Experimental source preview, not a validated release.** It has not been fully validated on real macOS 27 hardware. It uses undocumented Apple event and Spaces interfaces, which can change between OS releases. See the [validation checklist](docs/VALIDATION.md).

## What JumpCut does

- **Trackpad-first.** Three-finger horizontal swipes switch to the next/previous native macOS Space. Keyboard shortcuts are *disabled by default* but can be explicitly enabled in the menu bar.
- **No broad system changes.** No SIP disabling, root permission, injected system daemon, Dock modifications, global Reduce Motion, or changes to native Ctrl+arrow shortcuts.
- **Narrow interception.** The event tap listens only for DockControl and gesture event types (29/30), not keystrokes. Optional hotkeys use Carbon registration.
- **macOS 27 fix.** Instant synthetic gestures use progress `0.1` and terminal velocity `9999` instead of `0.0001`, based on the compositor investigation in [noswoosh #9](https://github.com/mmathys/noswoosh/issues/9) and [#15](https://github.com/mmathys/noswoosh/issues/15). Each synthetic event, including the companion event, gets a unique tag *after* serialized IOHID augmentation.
- **Reversible.** Quit JumpCut, or disable interception in the menu bar, and macOS's normal trackpad behavior returns.

## Building

Requires Apple Silicon, Xcode command-line tools with Swift **6.3+**, and macOS for running/testing the app. The primary compatibility target is **macOS 27**.

```bash
git clone https://github.com/e-kotov/JumpCut.git
cd JumpCut
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
bash Tests/run.sh
swift test
bash Tests/hotkeys.sh
./Scripts/bundle.sh
```

This builds `build/JumpCut.app` with executable `JumpCut` and bundle ID `dev.ekotov.jumpcut`. Install and launch with:

```bash
./Scripts/install.sh
```

Then grant **JumpCut** Accessibility permission in **System Settings → Privacy & Security → Accessibility**. Check its menu-bar status for **Swipe interception is active**.

Ad-hoc signing means updates can require removing an old Accessibility grant and granting a new one. Keep Reduce Motion off if you dislike macOS's crossfade; JumpCut does not require it.

**Do not run JumpCut alongside strafe, noswoosh, InstantSpaceSwitcher, or other utilities intercepting the same gestures.** If you encounter blank windows or reversed switching, turn off JumpCut interception immediately and use Mission Control to recover.

## Controls

```text
JumpCut                         launch menu-bar app
JumpCut status                  permissions and API availability
JumpCut switch left|right       one programmatic switch
JumpCut speed instant|quick|smooth
JumpCut hotkeys on|off          optional global shortcuts (default off)
```

You can pause/restart interception and adjust transition speed from the menu bar. This app does not override native Ctrl+arrow behavior.

## Code and provenance

This repository contains the **complete Swift/C source, macOS CI, unit tests and benchmark harness**. Internal `CStrafe` and `strafe_*` C symbol names, plus the benchmark's historical `strafe` mode label, are intentionally retained to minimize unrelated changes. The distributed macOS bundle is named **JumpCut**, not strafe. Historical benchmark numbers are from upstream strafe, **not JumpCut benchmarks**.

Start with [integration notes](docs/INTEGRATION.md), [security scope](SECURITY.md), and the [real-device validation checklist](docs/VALIDATION.md). GitHub Actions tests compilation and event serialization, but a green CI result cannot prove that WindowServer renders macOS 27 desktops correctly.

## License and credits

JumpCut is released under the [MIT LICENSE](LICENSE) (© 2026 Egor Kotov).

JumpCut contains MIT-licensed code from strafe by **Riley Hennigh**, based on the original synthetic Dock gesture technique from **jurplel/InstantSpaceSwitcher** (MIT); macOS 27 IOHID payload work from **joshuarli/iss** (0BSD); and ideas/measurements from **Max Mathys's noswoosh** (MIT). Full source notices are preserved under [third_party](third_party/) and explained in [docs/THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md).

JumpCut is independent and not endorsed by the upstream authors; no upstream repositories were modified.
