# Validation plan — experimental JumpCut

The application has **not been validated on real macOS 27 hardware**. Even a green CI cannot establish real-space reliability or WindowServer rendering.

## Automated

```bash
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
bash Tests/run.sh
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
bash Tests/hotkeys.sh
./Scripts/bundle.sh
codesign --verify --verbose=2 build/JumpCut.app
```

Verify correct bundle identifier and executable, active gesture-only event mask, regression assertions for progress=0.1 / velocity=9999 on 27 and explicit tag filtering, and that shortcuts start disabled.

## Real macOS 27

Test with only JumpCut installed and Reduce Motion off:

1. Natural Scrolling ON and OFF: 3-finger swipes move in expected directions, no reversed progress.
2. At least 20 rapid left-right-left sequences and first/last Space boundary swipes, without repeated or missed switches.
3. Fullscreen-to-fullscreen, fullscreen-to-desktop, empty desktop, and desktop with multiple apps/windows.
4. Exposé/Mission Control open and close; swiping while those are active must not cause an unintended switch.
5. External monitor / separate Spaces settings, including pointer on a display other than the one with keyboard focus.
6. Confirm no black/unpainted windows, blank menu bar, unexpected app activation or dropped keyboard/mouse input.
7. Grant/revoke Accessibility; quit/toggle JumpCut and confirm original macOS gestures return.

Record macOS 27 build number, display refresh rate, hardware type, test counts and failures. Measure **time until the destination window accepts input**, not just animation frames.

## Known limitations

Private unsupported APIs can break on OS updates. The high-progress gesture profile is supported by *noswoosh* measurements but has not been verified in JumpCut. Native Ctrl+arrow is not accelerated unless explicit custom hotkeys are configured; it is never rewritten. SwiftPM source builds require Swift 6.3+. Ad-hoc signing may require Accessibility permission to be regranted after each rebuild. The bench tool retains its original upstream mode names and measurements, which are not JumpCut results.
