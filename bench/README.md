# bench — time-to-interactivity harness + video tooling for strafe

`bench` measures, honestly and reproducibly, the thing strafe claims to improve:
**how long after you trigger a Space switch the landed window is actually
interactive** — i.e. how long until a click on the new Space is delivered to the
window living there. It compares two switch mechanisms on the same machine:

- **native** — the standard animated Mission Control space switch, triggered by
  a **normal-velocity synthetic dock-swipe** (a `began` → a short ramp of
  `changed` events → an `ended` with a moderate end velocity, order ~100–400).
  Shaped like a real human trackpad swipe, so macOS plays its animated slide and
  queues input until it finishes.
- **strafe** — strafe's synthetic **high-velocity** dock-swipe, posted through
  the exact same `CStrafe` code path the shipped app uses, which the WindowServer
  reads as a flick and completes instantly with no animation.

Both modes now post the **identical private gesture family** (the dock-swipe
CGEvent `CStrafe.c` synthesizes); they differ **only in the velocity/progress
profile** — normal-velocity ramp (animated) vs. `±FLT_TRUE_MIN` progress + very
high velocity (instant). That makes the comparison an apples-to-apples one: same
mechanism, same WindowServer path, only the swipe speed changes.

> **Why not Ctrl+Arrow for native?** An earlier version triggered native mode by
> posting the "Move left/right a space" Mission Control keyboard shortcut
> (Ctrl+→ / Ctrl+←). On macOS 26 this is a **no-op**: a synthetic Mission Control
> keyboard shortcut never switches spaces (verified empirically on this machine —
> zero space changes on either `.cghidEventTap` or `.cgSessionEventTap`, while
> probe clicks delivered fine, so posting/permissions were working; the keyboard
> shortcut route specifically is dead). The normal-velocity dock-swipe drives the
> same WindowServer path a real trackpad swipe does and actually switches.

It also produces the demo windows and the screen-recording / ffmpeg-composition
scripts for a before/after README video, with **zero personal data** on screen.

> `bench` is a **dev / measurement tool**. It is deliberately a separate SwiftPM
> package and is **not part of the strafe app** that [`SECURITY.md`](../SECURITY.md)
> audits. It depends on the main package only to reuse the `CStrafe` gesture
> synthesis code, so the "strafe" numbers exercise the real code path. Nothing in
> `bench/` ships in `strafe.app`.

## Layout

```
bench/
  Package.swift          standalone executable `bench`, depends on `.package(path: "..")`
  Sources/bench/         Swift sources (see below)
  bundle-bench.sh        assemble ad-hoc-signed bench.app (LSUIElement) for a stable TCC grant
  record.sh              region screen capture below the menu bar
  compose.sh             ffmpeg composition of the before/after video
  results/               CSV output (gitignored)
```

Sources:

| file | role |
|------|------|
| `main.swift` | subcommand dispatch (`windows` / `run` / `specs`) |
| `MachineInfo.swift` | **redacted** machine-info block (model/chip/cores/mem/os only) |
| `DemoWindow.swift` | the borderless per-Space demo view (gradient, label, clock, click flash) |
| `DemoWindowController.swift` | creates both windows across two Spaces, 60fps clock, click routing |
| `StrafeSwitch.swift` | thin wrapper over `strafe_post_switch_gesture` (the app's poster) |
| `EventPosting.swift` | native normal-velocity dock-swipe + probe-click posting |
| `Benchmark.swift` | the trial loop, stats, table + CSV + summary |

## One change to the main package

`bench` needs to `import CStrafe`, so the root `Package.swift` gained a single
library product:

```swift
.library(name: "CStrafe", targets: ["CStrafe"])
```

That is the **only** modification to the main package. The strafe app does not
consume this product; it exists purely so `bench` can reach the C target. The
main package's auditable line count is otherwise untouched.

## Reproducing a measurement session

Everything below is human-driven — `bench` posts synthetic gestures and clicks,
which requires Accessibility, and screen recording requires Screen Recording.
Grant both once, to the **bundle**, and the session is repeatable.

### 0. Prerequisites

- macOS 15+ (developed/verified on macOS 26.3, Apple Silicon).
- `ffmpeg` for the video step: `brew install ffmpeg` (stock build is fine — see
  the drawtext note in *Video tooling*).
- At least **two** Spaces on your main display, arranged left-to-right. `native`
  mode posts a synthetic dock-swipe gesture (not a keyboard shortcut), so no
  Mission Control keyboard-shortcut configuration is required — it drives the
  same WindowServer path as a real trackpad space-swipe.

### 1. Build + grant (once)

```bash
cd bench
./bundle-bench.sh
open build/bench.app                    # launches once (LSUIElement, no dock icon)
# System Settings › Privacy & Security › Accessibility: enable "bench".
# (Remove any stale "bench" entry first — ad-hoc signing changes identity across
#  rebuilds, same caveat as strafe itself.)
```

Run subcommands via the binary **inside** the bundle so the grant stays
attributed to `bench.app`:

```bash
BENCH="build/bench.app/Contents/MacOS/bench"
```

### 2. Sanity: print the redacted specs

```bash
"$BENCH" specs
```

Copy this line for the video caption later. It contains model/chip/cores/memory
and the macOS version — and **never** a serial number, hardware UUID, hostname,
or user name (enforced in `MachineInfo.swift`).

### 3. Run the measurement (native, then strafe)

```bash
"$BENCH" run --mode native --trials 20
"$BENCH" run --mode strafe --trials 20
```

Each run: sets up both demo windows (window 1 on the current Space, switches
right, window 2 on the neighbor, returns home), discards one warmup trial, then
runs 20 measured trials **alternating direction** with a 1.5 s settle between
them. Output is a per-trial table on stdout, a CSV at
`results/<mode>-<trials>.csv`, and a summary line (median / p90 / min / max, ms).
Note the two medians — you'll pass them to `compose.sh`.

Do not touch the trackpad/keyboard during a run; stray input can auto-disable
event taps and perturb timing.

### 4. Record the before/after takes

For the video you want the *visual* switch on camera. Put the demo windows up in
one process and record a few switches by hand (trigger the animated native switch
with a real 3-finger trackpad swipe, or run a `bench run --mode strafe` for the
instant one):

```bash
"$BENCH" windows &                      # both demo windows up, live clocks
./record.sh native.mov 6                # 6-second take; first run prompts Screen Recording
# ... perform a couple of native Ctrl+→ / Ctrl+← switches during the take ...
./record.sh strafe.mov 6
# ... perform strafe switches during this take ...
```

`record.sh` captures the main display **below the menu bar** so no menu-bar
extras (clock, wifi, battery, VPN, user name) are ever in frame.

### 5. Compose the video

```bash
./compose.sh native.mov strafe.mov <native_median_ms> <strafe_median_ms> "$("$BENCH" specs | tr '\n' ' ')"
# e.g.
./compose.sh native.mov strafe.mov 512.0 42.3 "Apple M3 Pro · 6P+6E · 36 GB · macOS 26.3"
```

Produces `../docs/media/demo.mp4` (title → native → strafe → closing card, H.264,
target < 8 MB) and `../docs/media/demo-loop.mp4` (side-by-side hstack, target
< 3 MB, for a README autoplay embed). All numbers are **parameters** — nothing is
baked in.

## Video tooling notes / caveats

- **`screencapture` flags (macOS 26):** `-V<seconds>` and `-R<x,y,w,h>` take
  their values **attached** (`-V6`, `-R0,24,1512,958`) — a space makes
  `screencapture` treat the number as a filename. `-v` selects video, `-x`
  silences the UI sound. Coordinates are in **points**, top-left origin.
- **No `drawtext` in stock Homebrew ffmpeg.** The default formula is built
  without libfreetype, so `drawtext` is unavailable. `compose.sh` therefore
  renders every card/caption to a transparent PNG via macOS CoreText (JavaScript
  for Automation, always present) and composites with `overlay`. The only ffmpeg
  filters used — `color`, `overlay`, `scale`, `pad`, `setsar`, `drawbox`,
  `fade`, `concat`, `hstack`, `format` — are all in the stock build.
- **SAR:** scaled/padded segments carry a near-1 sample aspect ratio that trips
  `concat`; `compose.sh` forces `setsar=1` on every segment so concat succeeds.

## Measurement validity — read this before trusting a number

The measured quantity is **first-click-delivery − T0**, where T0 is captured
(via `CACurrentMediaTime()`) immediately before the switch trigger, and
first-click-delivery is the timestamp the **destination** window's local mouse
monitor stamps for the first probe click it receives. Pitfalls we handle or
report:

1. **Clicks to the source window must not count.** Both Spaces' windows exist in
   one process. Before each trial the `HitRecorder` is *armed* with the
   destination Space; only a click on that window latches `firstHit`. Clicks that
   land on the source window (delivered pre-switch) are counted separately
   (`src_hits` column) and excluded. If you see nonzero `src_hits` it means the
   probe reached the old Space before the switch completed — informative, not
   counted as interactive.
2. **Clicks during the animation: dropped vs queued.** During the native slide,
   some probe clicks may be dropped by the WindowServer and some queued. We
   report both the first-hit time **and** the `clicks_posted` vs `dest_hits`
   counts, so you can see how many probes it took and whether early ones were
   swallowed. A large `clicks_posted` with `dest_hits` ≪ `clicks_posted` implies
   heavy dropping during the transition.
3. **CGEventPost timestamp vs delivery time.** We deliberately time **delivery**
   (when our window's monitor sees the event), not when `CGEventPost` returned.
   The gap between "posted" and "delivered" is precisely the dead time strafe is
   claimed to remove, so timing delivery is the honest choice. Post cadence is
   4 ms; the sampling granularity of the reported Δ is therefore ≈4 ms — treat
   sub-4 ms differences as noise.
4. **Why alternate directions.** Trials alternate right/left so the harness
   returns to its home Space each pair and never walks off the end of the Space
   list (which would hit the bounds guard / rubber-band). It also averages out
   any left/right asymmetry in the OS transition.
5. **`activeSpaceDidChange` is reference-only.** We also record
   `NSWorkspace.activeSpaceDidChangeNotification − T0` (`space_change_ms`), but
   that notification fires on the OS's own schedule (often *after* the window is
   already interactive under strafe, and its coalescing is lossy), so it is a
   cross-check, **not** the headline metric.
6. **Warmup + settle.** One warmup trial per mode is discarded (first-switch
   costs — window-server caches, first CGEvent source creation). A 1.5 s settle
   between trials lets the OS quiesce so trial N doesn't measure trial N−1's tail.
7. **Timeouts are failures, not zeros.** A trial with no destination hit within
   3 s is recorded as `TIMEOUT` / `timed_out=true` and **excluded** from
   median/p90/min/max. The summary prints the timeout count so a run that mostly
   failed can't masquerade as a fast median.

## Privacy

- On-screen content is entirely code-drawn (NSColor gradients + text + a dot).
  No images, no bundled assets, no filenames, no wall-clock **date** (the clock
  shows only seconds.milliseconds, wrapped at 60 s). The windows cover the
  desktop icons completely.
- `record.sh` excludes the menu bar.
- `MachineInfo` reads only non-identifying hardware facts; it never touches
  `IOPlatformSerialNumber`, `IOPlatformUUID`, or the hostname.
- Still: **eyeball every take before publishing.** `record.sh` prints that
  reminder too.

## Results (2026-08-29, MacBook Pro · Apple M3 Pro · 18 GB · macOS 26.3)

20 trials per mode, 0 timeouts, alternating direction, ground-truth space
detection. Both modes triggered by the identical synthetic gesture family,
differing only in velocity profile.

| metric (median) | native swipe | with strafe |
|---|---|---|
| first event delivery | 168.5 ms | 49.6 ms |
| transition complete (logical) | 164.4 ms | 42.3 ms |

Raw CSVs: `results/native-20.csv`, `results/strafe-20.csv`.

### What these numbers do and don't capture

All programmatic signals we found (event delivery, `activeSpaceDidChange`,
source-window-offscreen) fire at the **logical** switch. Frame analysis of a
240fps screen recording puts the visible slide at ~110–125 ms of that window,
ending within a frame or two of the logical signals. Two honest caveats:

1. Synthetic probe clicks bypass the input hold WindowServer applies to real
   HID input mid-transition, so native times are a lower bound on human
   experience — a real finger also spends its own travel time on the gesture
   before macOS even starts.
2. The native trigger uses one fixed release velocity. Real swipes vary, and
   macOS scales the transition duration with release velocity — slow releases
   take visibly longer. strafe removes that variable entirely.
