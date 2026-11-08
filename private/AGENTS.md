# JumpCut — agent/developer notes

> **Internal file.** This note and everything else under `private/` is gitignored
> and must never be committed or pushed; it lives only in local clones. The public
> repository history was reset, so nothing under `private/` exists on GitHub.

This is `e-kotov/JumpCut`, a private experimental macOS Spaces utility. Prioritize **reliable, minimal, swipe-only behavior**.

- Pinned derivative base: strafe `42f69de6007348f7da0f5cba8c5b3ec534f18da2`. Preserve attribution and original licenses; never push or open PRs to strafe, noswoosh or InstantSpaceSwitcher unless explicitly asked.
- Runtime source: `Sources/JumpCut/` and `Sources/CStrafe/`. `CStrafe` and `strafe_*` names are inherited internal APIs, not app branding.
- Product: `JumpCut.app`, executable `JumpCut`, bundle identifier `dev.ekotov.jumpcut`, package executable `JumpCut`.
- Trackpad-first: gesture tap event mask must remain ONLY (1 << 29) | (1 << 30), never monitor key-down/up. Optional Carbon hotkeys default off.
- Never require SIP changes, root, system shortcut defaults changes, Dock tweaks, a persistent LaunchAgent, network telemetry or credential access.
- Current macOS 27 experimental profile: instant progress=0.1 and ended velocity=9999. All our synthetic Dock and companion events use tag 0x4A554D50 after event augmentation, so our tap ignores them even if source PID is zero.
- Tests: `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`; `bash Tests/run.sh`; `swift test`; `bash Tests/hotkeys.sh`; `./Scripts/bundle.sh`; `codesign --verify --verbose=2 build/JumpCut.app`; `python3 Scripts/macos-sign.test.py` (needs the `FORK_MACOS_APPLE_*` secrets; runs in CI via `.github/workflows/macos-signing.yml`).
- Green CI is necessary but *insufficient*. Real macOS 27 tests must include reversed directions, rapid swipes, fullscreen, blank desktops, external displays, Mission Control, natural-scrolling both ways, and permissions recovery.
- Keep improvements on this repository only, review before merging, and avoid declaring releases production-ready without hardware validation.
