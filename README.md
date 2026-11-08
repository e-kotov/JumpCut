# JumpCut — instant macOS Spaces switching

JumpCut aims to replace the configured horizontal Spaces swipe's slow desktop-slide animation with a near-instant native macOS transition. It's an **experimental derivative of [strafe](https://github.com/rileycx/strafe)** with a macOS 27 gesture profile and explicit synthetic-event tagging informed by [noswoosh](https://github.com/mmathys/noswoosh).

> **Experimental.** Four-finger interception worked in physical testing on macOS 27.2; the full reliability matrix still needs validation. Compilation and intercepted-event tests cannot establish correct rendering or trackpad behavior. This implementation uses undocumented Apple event and Spaces interfaces, which can change between OS releases. See the [validation procedure](docs/VALIDATION.md).

## What JumpCut does

- **Trackpad-first.** Recognizes the native horizontal Spaces gesture without testing finger count or changing macOS gesture settings. A macOS 27.2 device capture confirmed that four-finger Space swipes (and three-finger dragging) reach the expected Dock-swipe event path; a false-positive overlay guard was fixed, and four-finger swipes were confirmed working on real hardware. Keyboard shortcuts are *disabled by default* but can be explicitly enabled in the menu bar.
- **No broad system changes.** No SIP disabling, root permission, injected system daemon, Dock modifications, global Reduce Motion, or changes to native Ctrl+arrow shortcuts.
- **Narrow interception.** The event tap listens only for DockControl and gesture event types (29/30), not keystrokes. Optional hotkeys use Carbon registration.
- **Experimental macOS 27 profile.** Instant synthetic gestures use progress `0.1` and terminal velocity `9999`, based on the compositor investigation in [noswoosh #9](https://github.com/mmathys/noswoosh/issues/9) and [#15](https://github.com/mmathys/noswoosh/issues/15). Each synthetic event, including the companion event, gets a unique tag *after* serialized IOHID augmentation.
- **Complete preparation and bounded predictions.** Every event in an instant or animated gesture is prepared before posting begins. Per-display predictions expire after 500 ms and are invalidated by ordered Space changes. If display topology is unknown when a swipe begins, the complete native gesture passes through. [Policy and limitations](docs/INTEGRATION.md).
- **Reversible.** Turn off **Accelerate trackpad Space swipes** in Settings (or disable it in the menu bar) and macOS's normal animation returns without quitting JumpCut.

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
JumpCut speed 0..120
JumpCut hotkeys on|off          optional global shortcuts (default off)
```

Open **Settings → Space transitions** to adjust **0–120 ms** with a live slider, 1 ms stepper, or exact number. Turn off **Accelerate trackpad Space swipes** for native macOS animation immediately. JumpCut stays running, both choices persist, and Settings remains visible across Spaces for live testing. Old `instant`, `quick`, and `smooth` CLI names remain accepted for compatibility. This app does not override native Ctrl+arrow behavior.

## Code and provenance

This repo contains the **actual Swift/C source, macOS CI, unit tests and benchmark harness**, not just a bootstrap script. Internal `CStrafe` and `strafe_*` C symbol names, plus the benchmark's historical `strafe` mode label, are intentionally retained to minimize unrelated changes. The distributed macOS bundle is named **JumpCut**, not strafe. Historical benchmark numbers are from upstream strafe, **not JumpCut benchmarks**.

Start with [integration notes](docs/INTEGRATION.md), [security scope](SECURITY.md), and the [real-device validation checklist](docs/VALIDATION.md). GitHub Actions tests compilation and event serialization, but a green CI result cannot prove that WindowServer renders macOS 27 desktops correctly.

## License and credits

The existing [MIT LICENSE](LICENSE) (© 2026 Egor Kotov) is preserved.

JumpCut contains MIT-licensed code from strafe by **Riley Hennigh**, based on the original synthetic Dock gesture technique from **jurplel/InstantSpaceSwitcher** (MIT); macOS 27 IOHID payload work from **joshuarli/iss** (0BSD); and ideas/measurements from **Max Mathys's noswoosh** (MIT). Full source notices are preserved under [third_party](third_party/) and explained in [docs/THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md).

No upstream repositories were modified.
