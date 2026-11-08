import AppKit

/// Captures keys only as the first responder of JumpCut's visible settings window.
/// No global monitor (or keyboard event tap) is installed.
@MainActor
private final class ShortcutRecorder: NSButton {
    var recording = false
    var onRecord: ((NSEvent) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onCancel?()
        } else if !event.isARepeat {
            onRecord?(event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let hotkeys: HotkeyManager
    private let engine: GestureSwitchEngine?
    private let interceptor: SwipeInterceptor
    private var recorders: [ShortcutAction: ShortcutRecorder] = [:]
    private var recordingAction: ShortcutAction?
    private let enableShortcuts = NSButton(checkboxWithTitle: "Enable keyboard shortcuts", target: nil, action: nil)
    private let accelerateSwipes = NSButton(checkboxWithTitle: "Accelerate trackpad Space swipes", target: nil, action: nil)
    private let durationSlider = NSSlider(value: 0, minValue: 0, maxValue: Double(TransitionSpeed.maximumMilliseconds), target: nil, action: nil)
    private let durationField = NSTextField(string: "0")
    private var durationStepper: NSStepper?
    private let message = NSTextField(wrappingLabelWithString: "")
    private let swipeStatus = NSTextField(wrappingLabelWithString: "")
    private var statusTimer: Timer?

    init(hotkeys: HotkeyManager, engine: GestureSwitchEngine?, interceptor: SwipeInterceptor) {
        self.hotkeys = hotkeys
        self.engine = engine
        self.interceptor = interceptor
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "JumpCut Settings"
        // Keep this window available while switching Spaces, including when
        // testing changes via four-finger swipes without closing Settings.
        window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("JumpCut.settings")
        super.init(window: window)
        window.delegate = self
        window.center()
        buildContent()
        hotkeys.onStateChanged = { [weak self] in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showSettings() {
        refresh()
        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSwipeStatus() }
        }
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)
        ])

        let heading = NSTextField(labelWithString: "Keyboard shortcuts")
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        stack.addArrangedSubview(heading)
        enableShortcuts.target = self
        enableShortcuts.action = #selector(toggleShortcuts)
        stack.addArrangedSubview(enableShortcuts)

        for action in ShortcutAction.allCases {
            let label = NSTextField(labelWithString: action.title)
            label.widthAnchor.constraint(equalToConstant: 135).isActive = true
            let recorder = ShortcutRecorder(title: "", target: self, action: #selector(beginRecording(_:)))
            recorder.bezelStyle = .rounded
            recorder.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            recorder.widthAnchor.constraint(equalToConstant: 210).isActive = true
            recorder.setAccessibilityLabel("\(action.title) shortcut")
            recorder.onRecord = { [weak self] event in self?.record(event, for: action) }
            recorder.onCancel = { [weak self] in self?.cancelRecording() }
            recorders[action] = recorder
            let clear = NSButton(title: "Clear", target: self, action: #selector(clearShortcut(_:)))
            clear.bezelStyle = .rounded
            clear.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            let row = NSStackView(views: [label, recorder, clear])
            row.spacing = 10
            stack.addArrangedSubview(row)
        }
        let help = NSTextField(wrappingLabelWithString: "Click a shortcut, then press a key with ⌘, ⌃, or ⌥ (or a function key). Press Esc to cancel. Changes apply immediately.")
        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(help)
        help.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let reset = NSButton(title: "Restore Default Shortcuts", target: self, action: #selector(restoreDefaults))
        reset.bezelStyle = .rounded
        stack.addArrangedSubview(reset)

        message.font = .systemFont(ofSize: 12)
        message.textColor = .systemRed
        stack.addArrangedSubview(message)
        message.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        message.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true

        let divider = NSBox()
        divider.boxType = .separator
        stack.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let transitions = NSTextField(labelWithString: "Space transitions")
        transitions.font = .systemFont(ofSize: 16, weight: .semibold)
        stack.addArrangedSubview(transitions)
        accelerateSwipes.target = self
        accelerateSwipes.action = #selector(toggleSwipeAcceleration)
        accelerateSwipes.isEnabled = engine != nil
        accelerateSwipes.setAccessibilityLabel("Accelerate trackpad Space swipes, or use native macOS animation when off")
        stack.addArrangedSubview(accelerateSwipes)
        durationSlider.isContinuous = true
        durationSlider.target = self
        durationSlider.action = #selector(slideDuration(_:))
        durationSlider.isEnabled = engine != nil
        durationSlider.setAccessibilityLabel("Transition pacing, zero is instant")
        durationSlider.widthAnchor.constraint(equalToConstant: 300).isActive = true

        durationField.target = self
        durationField.action = #selector(commitDuration(_:))
        durationField.isEnabled = engine != nil
        durationField.alignment = .right
        durationField.widthAnchor.constraint(equalToConstant: 46).isActive = true
        durationField.setAccessibilityLabel("Transition pacing in milliseconds")
        let stepper = NSStepper()
        stepper.minValue = 0
        stepper.maxValue = Double(TransitionSpeed.maximumMilliseconds)
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.isEnabled = engine != nil
        stepper.target = self
        stepper.action = #selector(stepDuration(_:))
        stepper.setAccessibilityLabel("Adjust transition pacing by one millisecond")
        durationStepper = stepper

        let durationRow = NSStackView(views: [
            NSTextField(labelWithString: "Instant"), durationSlider,
            durationField, NSTextField(labelWithString: "ms"), stepper
        ])
        durationRow.spacing = 10
        stack.addArrangedSubview(durationRow)
        let speedHelp = NSTextField(wrappingLabelWithString:
            "0 ms uses an instant switch. Drag the slider or use the stepper for 1 ms changes. Enter an exact value (0–120 ms) and press Return. Each change applies to the very next swipe or shortcut, even while Settings stays open.")
        speedHelp.font = .systemFont(ofSize: 12)
        speedHelp.textColor = .secondaryLabelColor
        stack.addArrangedSubview(speedHelp)
        speedHelp.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let accelerationHelp = NSTextField(wrappingLabelWithString:
            "Turn acceleration off for normal macOS swipes. JumpCut stays running; keyboard shortcuts are independent.")
        accelerationHelp.font = .systemFont(ofSize: 12)
        accelerationHelp.textColor = .secondaryLabelColor
        stack.addArrangedSubview(accelerationHelp)
        accelerationHelp.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let gestureDivider = NSBox()
        gestureDivider.boxType = .separator
        stack.addArrangedSubview(gestureDivider)
        gestureDivider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let gestures = NSTextField(labelWithString: "Trackpad gestures")
        gestures.font = .systemFont(ofSize: 16, weight: .semibold)
        stack.addArrangedSubview(gestures)
        swipeStatus.font = .systemFont(ofSize: 12)
        swipeStatus.textColor = .secondaryLabelColor
        stack.addArrangedSubview(swipeStatus)
        swipeStatus.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24).isActive = true
        window?.setContentSize(NSSize(width: 550, height: 600))
    }

    private func refresh() {
        enableShortcuts.state = HotkeyManager.enabled ? .on : .off
        for action in ShortcutAction.allCases {
            let recorder = recorders[action]!
            recorder.recording = recordingAction == action
            recorder.title = recorder.recording ? "Type shortcut… (Esc cancels)" : (action.storedShortcut?.displayName ?? "Record Shortcut…")
        }
        if let error = hotkeys.registrationError { message.stringValue = error }
        displayDuration(engine?.transitionSpeed ?? TransitionSpeed.stored)
        refreshSwipeControls()
    }

    func refreshSwipeControls() {
        accelerateSwipes.state = interceptor.overrideEnabled ? .on : .off
        swipeStatus.stringValue = interceptor.statusDescription
    }

    private func refreshSwipeStatus() {
        refreshSwipeControls()
    }

    @objc private func toggleSwipeAcceleration() {
        let enabled = accelerateSwipes.state == .on
        interceptor.overrideEnabled = enabled
        SwipeAccelerationPreference.persist(enabled)
        if enabled && !interceptor.isRunning { interceptor.start() }
        refreshSwipeControls()
    }

    @objc private func beginRecording(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let action = ShortcutAction(rawValue: value) else { return }
        recordingAction = action
        message.stringValue = ""
        hotkeys.setRecording(true)
        refresh()
        window?.makeFirstResponder(sender)
    }

    private func record(_ event: NSEvent, for action: ShortcutAction) {
        let shortcut = KeyboardShortcut(event: event)
        if let error = shortcut.validationError {
            message.stringValue = error
            return
        }
        recordingAction = nil
        let error = hotkeys.updateShortcut(shortcut, for: action)
        // Duplicate validation happens before updateShortcut resumes registration.
        hotkeys.setRecording(false)
        refresh()
        message.stringValue = error ?? ""
    }

    private func cancelRecording() {
        recordingAction = nil
        hotkeys.setRecording(false)
        refresh()
    }

    @objc private func clearShortcut(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let action = ShortcutAction(rawValue: value) else { return }
        cancelRecording()
        let error = hotkeys.updateShortcut(nil, for: action)
        refresh()
        message.stringValue = error ?? ""
    }

    @objc private func restoreDefaults() {
        cancelRecording()
        let error = hotkeys.restoreDefaultShortcuts()
        refresh()
        message.stringValue = error ?? ""
    }

    @objc private func toggleShortcuts() {
        let enabled = enableShortcuts.state == .on
        cancelRecording()
        HotkeyManager.persist(enabled: enabled)
        hotkeys.applyStoredState()
        message.stringValue = hotkeys.registrationError ?? ""
        refresh()
    }

    private func displayDuration(_ duration: TransitionSpeed) {
        durationSlider.doubleValue = Double(duration.milliseconds)
        durationField.stringValue = "\(duration.milliseconds)"
        durationStepper?.integerValue = duration.milliseconds
    }

    // Each slider event applies synchronously. No delayed commit, debounce,
    // window-close callback or app restart is needed.
    private func applyDuration(_ milliseconds: Int) {
        let duration = TransitionSpeed(milliseconds: milliseconds)
        engine?.setTransitionSpeed(duration)
        duration.persist()
        displayDuration(duration)
    }

    @objc private func slideDuration(_ sender: NSSlider) {
        applyDuration(Int(sender.doubleValue.rounded()))
    }

    @objc private func stepDuration(_ sender: NSStepper) {
        applyDuration(sender.integerValue)
    }

    @objc private func commitDuration(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let milliseconds = Int(value), (0...TransitionSpeed.maximumMilliseconds).contains(milliseconds) else {
            displayDuration(engine?.transitionSpeed ?? TransitionSpeed.stored)
            return
        }
        applyDuration(milliseconds)
    }

    func windowDidResignKey(_ notification: Notification) { cancelRecording() }
    func windowWillClose(_ notification: Notification) {
        cancelRecording()
        statusTimer?.invalidate()
        statusTimer = nil
    }
}
