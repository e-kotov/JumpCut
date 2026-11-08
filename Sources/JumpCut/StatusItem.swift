import AppKit

/// The menu-bar controller. Owns the `NSStatusItem` and wires its menu to the
/// interceptor / permission state. LSUIElement is set in the bundled
/// Info.plist so there is no dock icon.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let statusItem: NSStatusItem
    private let interceptor: SwipeInterceptor
    private let engine: GestureSwitchEngine?
    private let hotkeys: HotkeyManager?
    private var settings: SettingsWindowController?

    private let toggleItem = NSMenuItem(
        title: "Enable swipe acceleration", action: #selector(toggleEnabled), keyEquivalent: ""
    )
    private let speedItem = NSMenuItem(
        title: "Transition pacing", action: #selector(showSettings), keyEquivalent: ""
    )
    private let hotkeysItem = NSMenuItem(
        title: "Space-switch hotkeys", action: #selector(toggleHotkeys), keyEquivalent: ""
    )
    private let accessibilityItem = NSMenuItem(
        title: "Accessibility granted: —", action: nil, keyEquivalent: ""
    )
    private let captureItem = NSMenuItem(
        title: "Capture swipes (20 s)", action: #selector(startSwipeCapture), keyEquivalent: ""
    )
    private let copyReportItem = NSMenuItem(
        title: "Copy swipe report", action: #selector(copySwipeReport), keyEquivalent: ""
    )
    private let captureStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    /// Shipped version, read from the bundle so `VERSION` stays the single
    /// source of truth (`Scripts/bundle.sh` stamps it into Info.plist). A bare
    /// `swift build` binary has no Info.plist, and "dev" is the honest answer
    /// there — it genuinely isn't a released build.
    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    init(interceptor: SwipeInterceptor, engine: GestureSwitchEngine? = nil, hotkeys: HotkeyManager? = nil) {
        self.interceptor = interceptor
        self.engine = engine
        self.hotkeys = hotkeys
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let hotkeys {
            settings = SettingsWindowController(hotkeys: hotkeys, engine: engine, interceptor: interceptor)
        }

        // AppKit restores the previous visibility; every new launch starts visible.
        statusItem.isVisible = true

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.on.rectangle",
                accessibilityDescription: "JumpCut"
            )
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self

        toggleItem.target = self
        accessibilityItem.isEnabled = false

        engine?.setTransitionSpeed(TransitionSpeed.stored)
        interceptor.overrideEnabled = SwipeAccelerationPreference.stored

        menu.addItem(toggleItem)
        if engine != nil {
            speedItem.target = self
            menu.addItem(speedItem)
        }
        if hotkeys != nil {
            hotkeysItem.target = self
            menu.addItem(hotkeysItem)
        }
        menu.addItem(accessibilityItem)
        menu.addItem(.separator())
        captureItem.target = self
        copyReportItem.target = self
        captureStatusItem.isEnabled = false
        menu.addItem(captureItem)
        menu.addItem(copyReportItem)
        menu.addItem(captureStatusItem)
        if settings != nil {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
            item.target = self
            menu.addItem(item)
        }

        // Update story, stated rather than performed. JumpCut cannot reach the
        // internet, so it cannot check for a new version; instead of a
        // check-for-updates button that would need that ability, the menu just
        // says what's running and where newer builds live. Both items are inert
        // text — nothing is opened, copied, or fetched. Keeping them inert is
        // what lets the greps in SECURITY.md keep returning zero hits, so
        // resist the urge to make this line clickable.
        menu.addItem(.separator())
        for line in ["JumpCut \(Self.version)",
                     "No auto-update — github.com/e-kotov/JumpCut"] {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let hide = NSMenuItem(
            title: "Hide from menu bar", action: #selector(hideFromMenuBar), keyEquivalent: ""
        )
        hide.target = self
        menu.addItem(hide)
        let quit = NSMenuItem(title: "Quit JumpCut", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        refresh()
    }

    // Show the icon again. Called when the app is reopened while it is already running.
    func show() {
        statusItem.isVisible = true
    }

    @objc func showSettings() {
        settings?.showSettings()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem !== copyReportItem || interceptor.diagnostics.hasReport
    }

    // MARK: - Actions

    @objc private func startSwipeCapture() {
        interceptor.startSwipeDiagnostics()
        copyReportItem.title = "Copy swipe report"
        refresh()
    }

    @objc private func stopSwipeCapture() {
        // Keep Stop bound to stopping even if the deadline expires while the
        // menu is open; never turn a stale Stop action into a fresh capture.
        interceptor.diagnostics.stop()
        refresh()
    }

    @objc private func copySwipeReport() {
        guard interceptor.diagnostics.hasReport else { return }
        let report = interceptor.swipeDiagnosticsReport()
        // An explicit Copy action writes the report; clipboard contents are
        // never read. Nothing is saved or sent automatically.
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(report, forType: .string)
        copyReportItem.title = copied ? "Copy swipe report (copied)" : "Copy swipe report (retry)"
        refresh()
    }

    @objc private func toggleEnabled() {
        // Toggle interception. The tap stays alive (so it can re-enable itself
        // after a system auto-disable); `overrideEnabled` gates whether real
        // swipes are actually suppressed and replaced (SPEC §2.2).
        interceptor.overrideEnabled.toggle()
        SwipeAccelerationPreference.persist(interceptor.overrideEnabled)
        if interceptor.overrideEnabled && !interceptor.isRunning {
            interceptor.start()
        }
        settings?.refreshSwipeControls()
        refresh()
    }

    /// Toggle the Ctrl+Option+Left/Right global hotkeys, independent of the
    /// gesture tap (`toggleEnabled`). This is the mechanism that can conflict
    /// with third-party window-tiling shortcuts bound to the same chord.
    @objc private func toggleHotkeys() {
        guard let hotkeys else { return }
        let newValue = !HotkeyManager.enabled
        HotkeyManager.persist(enabled: newValue)
        hotkeys.applyStoredState()
        refresh()
    }

    // AppKit saves visibility; initialization resets it on the next launch.
    @objc private func hideFromMenuBar() {
        let alert = NSAlert()
        alert.messageText = "Hide JumpCut from the menu bar?"
        alert.informativeText = """
            JumpCut stays running in the background. Swipes and keyboard \
            shortcuts keep working.

            To bring the icon back or to quit, open JumpCut again from \
            Applications or Spotlight.
            """
        alert.addButton(withTitle: "Hide")
        alert.addButton(withTitle: "Cancel")
        // An accessory app is never frontmost, so bring the alert forward.
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        statusItem.isVisible = false
    }

    @objc private func quit() {
        interceptor.teardown()
        NSApp.terminate(nil)
    }

    // MARK: - State

    private func refresh() {
        toggleItem.title = interceptor.overrideEnabled
            ? "Disable swipe acceleration" : "Enable swipe acceleration"
        if let engine {
            speedItem.title = "Transition pacing: \(engine.transitionSpeed.title) — Settings…"
        }
        accessibilityItem.title = interceptor.statusDescription
        let recording = interceptor.diagnostics.isRecording
        captureItem.title = recording ? "Stop swipe capture" : "Capture swipes (20 s)"
        captureItem.action = recording ? #selector(stopSwipeCapture) : #selector(startSwipeCapture)
        captureStatusItem.title = interceptor.diagnostics.statusText
        captureStatusItem.isHidden = !interceptor.diagnostics.hasReport
        hotkeysItem.state = HotkeyManager.enabled ? .on : .off
    }
}
