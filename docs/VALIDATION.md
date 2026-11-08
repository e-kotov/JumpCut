# Validation — experimental JumpCut

The combined application has **not yet passed complete physical validation on
the target M4 MacBook Air / macOS 27**. Device capture on macOS 27.2 (26B123)
established that four-finger Space swipes reach the gesture tap with the expected
Dock-swipe shape (CGS type 30, HID type 23, horizontal motion, PID 0). Build
`58a761f62d4c` then rejected every began phase because the overlay heuristic
classified the normal-desktop state `layer18=0, layer20=1` as Mission Control.
The fix removed that lone-layer-20 rule, and four-finger switching was confirmed
working afterward on real hardware. A later 121–500 ms experiment caused visual
glitches, so the longer asynchronous path has been removed. Comprehensive
hardware validation remains incomplete.
Three-finger dragging remains enabled and no finger-count filter is used.
Report these layers separately:

| Layer | What it exercises | What it cannot establish |
|---|---|---|
| CI build and tests | Real serialization, intercepted posting, fault cleanup, parser, engine policy and interceptor state | Actual Dock acceptance or rendered pixels |
| CLI / optional hotkeys | Synthetic engine switching on a real Mac | Physical trackpad interception |
| Physical trackpad | Complete native gesture interception and recovery | Correct rendering without inspecting the destination |
| Visual and input checks | Destination content, menu bar, focus and physical input | Reliability on untested OS builds/configurations |

## Automated checks

From the repository root, with macOS and Swift 6.3+:

```bash
git rev-parse HEAD
sw_vers
swift --version
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
bash Tests/run.sh
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
bash Tests/hotkeys.sh
./Scripts/bundle.sh
codesign --verify --verbose=2 build/JumpCut.app
```

CI checks out and records the exact PR head. The C preparation suite forces both
pre-27 and macOS 27 paths regardless of the host OS, both directions and Natural
Scrolling settings. It inspects real serialized events, replaces `CGEventPost`,
and injects failures throughout preparation. Neither it nor the Swift tests
should switch the CI desktop or request Accessibility. Failure hooks and the
parser test entry point are compiled only into C test executables; CI checks
their symbols are absent from the app.

Parser tests use constructed CoreFoundation containers, not live CGS queries.
Engine tests inject topology, monotonic time and prepared posting actions. These
verify implementation policy, not the Dock's interpretation or compositor.

## Diagnose an unrecognized physical swipe

Keep the existing macOS gesture configuration. From the JumpCut menu choose
**Capture swipes (20 s)**, close the menu, and swipe once each way. On the same
display, reopen the menu and choose **Copy swipe report**, then paste the report
into the troubleshooting discussion. Copy stops capture; the fixed monotonic
20-second deadline also stops it. Starting or stopping capture does not reset
gesture tracking or change interception.

The report separates callback delivery, source/tag rejection, event-shape
recognition, the actual overlay decision, topology readiness when evaluated,
and switch submission. It records incoming fields before terminal motion is
cleared. Overlay counts come from the same query as the decision; a skipped
topology check is explicitly reported as not evaluated. Zero callbacks are a
distinct result. At most 256 detailed events are retained, with decision totals
and an explicit truncation count if that limit is reached. No event objects,
keyboard input, window names, screen images or persistent logs are retained.

Capture and clipboard copying are opt-in. The macOS 27.2 capture identified a
specific false positive: a lone Dock layer-20 window occurs on the normal desktop,
so it is no longer sufficient evidence of Mission Control. The candidate keeps
the older requirement for Dock layer-18 plus layer-20 evidence. A diagnostic
capture identifies this policy error, but only a fresh physical retest can show
that four-finger interception is repaired.

## Prepare the real-device session

Record the commit, OS build, hardware, display layout/refresh rates,
separate-Spaces setting, Natural Scrolling, transition speed and interception
state. Use only JumpCut as the gesture interceptor. Keep Reduce Motion unchanged
through comparisons (off for the primary case). Do not rewrite native keyboard
shortcuts or Dock preferences.

Build/install the app, grant Accessibility and confirm the menu reports active
interception. Arrange at least three distinguishable Spaces with bright,
different content. Include a text editor, a fullscreen app and a genuinely empty
desktop in later cases. Start between the boundaries, cursor on the target display.

## 1. Synthetic CLI and benchmark

Pause resident swipe interception and check the CLI independently:

```bash
./build/JumpCut.app/Contents/MacOS/JumpCut switch right
./build/JumpCut.app/Contents/MacOS/JumpCut switch left
```

Inspect each actual destination. Successful exit means preparation/posting
completed, not that the Dock accepted the switch. Repeat for each speed and both
Natural Scrolling settings. Optional Carbon hotkeys can be checked separately;
they are not required by this procedure.

Run the existing benchmark on **one display**, with a right-hand neighboring
desktop available for its two-window setup:

```bash
cd bench
./bundle-bench.sh
build/bench.app/Contents/MacOS/bench specs
build/bench.app/Contents/MacOS/bench run --mode strafe --trials 20
```

Grant Accessibility to the explicitly launched benchmark when requested. Its
historical `strafe` mode uses the current C instant poster, bypassing the engine
and physical interceptor. Check that setup actually placed its windows on
different desktops. Keep the trial table, summary, timeouts and
`bench/results/strafe-20.csv`; do not hide failures behind a fast median.

Its `native` mode uses legacy unaugmented events and is **not a verified macOS 27
baseline**. Compare physical swipes with interception paused instead. Synthetic
probe-click delivery is a lower bound on physical input readiness, and source
window disappearance is only a proxy. Historical upstream results in
`bench/README.md` are not JumpCut measurements.

## 2. Physical swipe matrix

Enable interception. Perform these checks with **Natural Scrolling both on and
off**, counting intended, missed, doubled and reversed switches separately.
Repeat direction, boundary and animated cases at 0 ms (Instant), 1, 30, 60 and
120 ms, plus at least two custom intermediate values.

| Case | Procedure and expected observation |
|---|---|
| Direction and one step | At least 20 alternating left/right swipes. Each lands exactly one Space away in the expected direction. |
| Rapid reversal | At least 20 left–right–left bursts, then repeated same-direction swipes. Include A→B→A immediately followed by another swipe. Check the final visible desktop. |
| Aborted swipe | Begin moving, then cancel/abort the physical swipe. Check for a partial transition or late switch, then confirm the next complete swipe works. |
| Boundaries | Repeated outward swipes at first/last Space, followed by an inward swipe. No blank surface, extra switch or persistent lockout. |
| Expiry / native switch | Pause longer than 500 ms, then switch. Use Mission Control for an intervening native switch and resume. Also try a native switch during a rapid burst; record failures/ambiguity. |
| Ordered topology | Rearrange Spaces without changing their count, and close/create a fullscreen Space. Boundaries must follow the new order. |
| Fullscreen / empty | Desktop↔fullscreen, fullscreen↔fullscreen and empty desktop. Watch for late jump-back and unexpected focus changes. |
| Overlays | Swipe in Mission Control and App Exposé, close them and swipe again. No unintended synthetic switch or stuck tracking. |
| Displays | Move the pointer between displays, including one without keyboard focus. Check their own boundaries, hot-plug, shared/separate Spaces and mirroring. Unknown layouts should retain native gestures. |
| Animated responsiveness | Leave Settings open and adjust the slider while swiping, including 1, 47 and 120 ms. The next switch should use the new duration without closing Settings. Return to 0 ms and check that Instant remains immediate. Positive durations intentionally hold the callback for their chosen pacing; check responsiveness and tap health. |
| Recovery | Sleep/wake, revoke/regrant Accessibility, pause/resume, quit/relaunch. Native swipes work when interception is off; regrant recovers the tap. |

If topology disappears after an intercepted began or preparation fails, that
owned swipe is suppressed; the next gesture must recover. Concurrent switch
requests are rejected as busy. See the [prediction policy](INTEGRATION.md).

## 3. Visual landing and physical input

Inspect destination windows **and the menu bar** immediately and again after at
least one second. Check black/unpainted surfaces, missing menu text, wrong
windows, visible slides and late jump-back. Use bright reference content:
average darkness can mistake wallpaper for failure or miss a blank menu bar.

Immediately click the destination editor and type a short marker with the
physical keyboard. Confirm the intended window receives it; record lost/delayed
input and unexpected activation. A changed Space ID, correctly painted menu bar
or synthetic probe click does not substitute for this check.

For a recording, explicitly start macOS screen capture (Shift–Command–5),
including the **whole relevant display and menu bar**. `bench/record.sh`
deliberately excludes the menu bar and cannot validate that region. For
hand-to-screen latency, a high-frame-rate external recording can show both the
physical action and first visible response. State the frame rate and uncertainty.

This uses visual-check ideas from
[noswoosh's landing checker](https://github.com/mmathys/noswoosh/blob/14051ab58444c6868f603bee9a4daab12f9f6255/scripts/landing-check.swift)
without its keyboard-driving or first-display assumptions. No screen capture
runs in the normal app.

## Record and interpret results

Keep configuration, attempt/success counts, failure categories and video/CSV
evidence for each case. Report automated, synthetic, physical swipe and
visual/input results separately. Repeat after OS updates before extending
compatibility claims.

Remaining limitations include unsupported private APIs, up to 500 ms prediction
ambiguity for external switches to visited Spaces, ignored Dock events,
scheduling/callback delays and prebuilt ramp timestamps. Empty-desktop focus/jump-back has
no automatic focus-taking workaround. Ad-hoc rebuilds may require a fresh
Accessibility grant. A green build or changed Space ID does not resolve these.
