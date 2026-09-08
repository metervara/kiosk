import AppKit
import ServiceManagement
import KioskCore

@MainActor
final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private let store: SettingsStore
    var onStart: ((Bool) -> Void)?
    private let website = NSTextField()
    private let hosts = NSTextField()
    private let display = NSPopUpButton()
    private let fullScreen = NSButton(checkboxWithTitle: "Use full screen for kiosk sessions", target: nil, action: nil)
    private let automaticDND = NSButton(checkboxWithTitle: "Turn DND on for kiosk sessions and off when they end", target: nil, action: nil)
    private let restrict = NSButton(checkboxWithTitle: "Keep visitors on these hosts", target: nil, action: nil)
    private let persistent = NSButton(checkboxWithTitle: "Remember website cookies and login", target: nil, action: nil)
    private let idle = NSTextField()
    private let refresh = NSTextField()
    private let timeout = NSTextField()
    private let automatic = NSButton(checkboxWithTitle: "Start the website when Kiosk opens", target: nil, action: nil)
    private let login = NSButton(checkboxWithTitle: "Open Kiosk at login", target: nil, action: nil)
    private let recovery = NSButton(checkboxWithTitle: "Relaunch Kiosk if the app crashes or freezes", target: nil, action: nil)
    private let passcode = NSSecureTextField()
    private let removePasscode = NSButton(checkboxWithTitle: "Remove saved passcode", target: nil, action: nil)
    private let passcodeNote = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "READY TO RUN")
    private let focusStatus = NSTextField(wrappingLabelWithString: "Focus state: not verified. Enable it here, then check Control Center.")
    private let shortcutStatus = NSTextField(labelWithString: "Checking shortcuts…")
    private let cornersConfirmed = NSButton(checkboxWithTitle: "I’ve checked Hot Corners", target: nil, action: nil)
    private let gesturesConfirmed = NSButton(checkboxWithTitle: "I’ve checked system gestures", target: nil, action: nil)
    private let lockConfirmed = NSButton(checkboxWithTitle: "I’ve checked screen locking", target: nil, action: nil)
    private let cornersStatus = NSTextField(labelWithString: "Needs your check")
    private let gesturesStatus = NSTextField(labelWithString: "Needs your check")
    private let lockStatus = NSTextField(labelWithString: "Needs your check")
    private let focusProgress = NSProgressIndicator()
    private var focusOnButton: NSButton!
    private var focusOffButton: NSButton!
    private var startButton: NSButton!
    private var previewButton: NSButton!
    private(set) var isRunningFocusShortcut = false
    private var isChangingSession = false
    private let focusRunner = FocusShortcutRunner()
    private var installedFocusShortcuts: Set<FocusShortcut>?
    private var isCheckingFocusShortcuts = false
    private var displayIDs: [UInt32] = [0]

    init(store: SettingsStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Kiosk"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        populate()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        refreshFocusShortcuts()
    }

    func windowDidBecomeKey(_ notification: Notification) { refreshFocusShortcuts() }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 22
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])
        let icon = NSImageView()
        icon.image = Bundle.main.image(forResource: "AppIcon") ?? NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 62).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 62).isActive = true
        let heading = vertical([
            // text("METERVARA / UTILITIES", size: 10, weight: .semibold, color: .secondaryLabelColor),
            text("A simple kiosk utility for websites", size: 25, weight: .semibold),
            // text("A quiet, self-recovering browser for public spaces.", size: 12, color: .secondaryLabelColor)
        ], spacing: 5)
        let header = NSStackView(views: [icon, heading])
        header.spacing = 16
        header.alignment = .centerY
        root.addArrangedSubview(header)

        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        for (name, view) in [("Website", websiteTab()), ("Operation", operationTab()), ("Mac setup", systemTab())] {
            let tab = NSTabViewItem(identifier: name)
            tab.label = name
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            let container = FlippedSettingsView()
            container.translatesAutoresizingMaskIntoConstraints = false
            scroll.documentView = container
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
                view.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -22),
                container.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
            ])
            tab.view = scroll
            tabs.addTabViewItem(tab)
        }
        root.addArrangedSubview(tabs)
        tabs.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 432).isActive = true

        let footer = NSStackView()
        footer.spacing = 10
        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        footer.addArrangedSubview(statusLabel)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(spacer)
        let save = button("Save", action: #selector(saveOnly))
        let preview = button("Preview", action: #selector(previewWebsite))
        let start = button("Start kiosk", action: #selector(startWebsite))
        previewButton = preview
        startButton = start
        start.bezelColor = .controlAccentColor
        footer.addArrangedSubview(save)
        footer.addArrangedSubview(preview)
        footer.addArrangedSubview(start)
        root.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    private func websiteTab() -> NSStackView {
        website.placeholderString = "https://your-exhibition.com"
        website.font = .systemFont(ofSize: 17)
        website.heightAnchor.constraint(equalToConstant: 34).isActive = true
        hosts.placeholderString = "www.example.com, login.example.com"
        let stack = vertical([
            title("Where should visitors begin?", "Enter the home page of your exhibition or experience."),
            website,
            fullScreen,
            text("On: fills the selected display, hides system controls, and keeps focus.\nOff: runs in a normal window so you can keep working. Preview is always windowed.", size: 11, color: .secondaryLabelColor),
            row("Display", display),
            separator(),
            title("Navigation", "The home host is always allowed. Add any hosts used by redirects or sign-in."),
            restrict,
            hosts,
            text("Exact host names, separated by commas. Subdomains must be added explicitly.", size: 11, color: .secondaryLabelColor),
            separator(),
            persistent,
            text("Off: start a fresh private session at every reset. On: retain this kiosk’s website data.\nPreview uses the same data setting; it never locks your Mac.", size: 11, color: .secondaryLabelColor)
        ], spacing: 13)
        for view in [website, hosts] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            view.maximumNumberOfLines = 1
        }
        return stack
    }

    private func operationTab() -> NSStackView {
        idle.widthAnchor.constraint(equalToConstant: 70).isActive = true
        refresh.widthAnchor.constraint(equalToConstant: 70).isActive = true
        timeout.widthAnchor.constraint(equalToConstant: 70).isActive = true
        passcode.placeholderString = "New passcode (at least 6 characters)"
        passcode.widthAnchor.constraint(equalToConstant: 318).isActive = true
        passcodeNote.font = .systemFont(ofSize: 11)
        passcodeNote.textColor = .secondaryLabelColor
        let timers = vertical([
            vertical([row("Return home after inactivity", inline([idle, text("seconds · 0 disables", size: 11, color: .secondaryLabelColor)])),
                      text("Returns to the home page when visitors stop interacting.", size: 11, color: .secondaryLabelColor)], spacing: 3),
            vertical([row("Scheduled refresh", inline([refresh, text("minutes · 0 disables", size: 11, color: .secondaryLabelColor)])),
                      text("Restarts the website at this interval, even while someone is using it.", size: 11, color: .secondaryLabelColor)], spacing: 3),
            vertical([row("Page load timeout", inline([timeout, text("seconds · 15–300", size: 11, color: .secondaryLabelColor)])),
                      text("Retries if a page takes too long to load. Browser crash recovery is always on.", size: 11, color: .secondaryLabelColor)], spacing: 3)
        ], spacing: 12)
        return vertical([
            timers, separator(),
            vertical([recovery, text("A separate watchdog restarts the app if it unexpectedly exits or stops responding.", size: 11, color: .secondaryLabelColor)], spacing: 3),
            vertical([automatic, text("Opens your website immediately instead of showing these settings.", size: 11, color: .secondaryLabelColor)], spacing: 3),
            vertical([login, text("Launches the menu-bar app when this macOS account signs in.", size: 11, color: .secondaryLabelColor)], spacing: 3),
            separator(),
            title("Operator access  ·  ⌃⌥⌘K", "Press Control + Option + Command + K to end a session."),
            passcode, passcodeNote, removePasscode
        ], spacing: 12)
    }

    private func systemTab() -> NSStackView {
        focusOnButton = button("Turn DND On", action: #selector(turnDNDOn))
        focusOffButton = button("Turn DND Off", action: #selector(turnDNDOff))
        focusOnButton.bezelColor = .controlAccentColor
        focusStatus.font = .systemFont(ofSize: 12)
        focusStatus.textColor = .secondaryLabelColor
        focusStatus.maximumNumberOfLines = 3
        focusProgress.style = .spinning
        focusProgress.controlSize = .small
        focusProgress.isDisplayedWhenStopped = false
        focusProgress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        focusProgress.heightAnchor.constraint(equalToConstant: 16).isActive = true
        shortcutStatus.font = .systemFont(ofSize: 11, weight: .medium)
        for control in [cornersConfirmed, gesturesConfirmed, lockConfirmed] {
            control.target = self
            control.action = #selector(confirmSetup)
        }
        let stack = vertical([
            title("Check this Mac", "Shortcuts are detected automatically. Confirm the other settings after checking them."),
            inline([text("Do Not Disturb", size: 14, weight: .semibold), shortcutStatus]),
            inline([focusOnButton, focusOffButton, focusProgress]),
            focusStatus,
            inline([button("Set up DND shortcuts…", action: #selector(showShortcutSetup)),
                    button("Focus options ↗", action: #selector(openFocus)),
                    button("Refresh status", action: #selector(refreshSetup))]),
            automaticDND,
            text("Applies to full-screen and windowed kiosk sessions; Preview never changes Focus. Ending a session turns DND off even if it was already on before you started.", size: 11, color: .secondaryLabelColor),
            separator(),
            inline([text("Hot Corners", size: 14, weight: .semibold), cornersStatus]),
            text("In Desktop & Dock, scroll to Hot Corners and set all four corners to “–”.", size: 12, color: .secondaryLabelColor),
            inline([button("Desktop & Dock ↗", action: #selector(openDesktop)), cornersConfirmed]),
            separator(),
            inline([text("System gestures", size: 14, weight: .semibold), gesturesStatus]),
            text("In Trackpad → More Gestures, turn off Mission Control, App Exposé, Show Desktop, and swiping between full-screen apps. Also check system keyboard shortcuts.", size: 12, color: .secondaryLabelColor),
            inline([button("Trackpad ↗", action: #selector(openTrackpad)), gesturesConfirmed]),
            separator(),
            inline([text("Screen locking", size: 14, weight: .semibold), lockStatus]),
            text("Review Lock Screen settings for the exhibition account. Kiosk keeps the display awake during a session, but cannot override password requirements or explicit locking.", size: 12, color: .secondaryLabelColor),
            inline([button("Lock Screen ↗", action: #selector(openLockScreen)), lockConfirmed]),
            text("“Confirmed by you” is a saved checklist entry, not a live system check. Recheck it after changing macOS settings. DND commands run your named shortcuts; they do not verify Focus state.", size: 11, color: .secondaryLabelColor)
        ], spacing: 10)
        focusStatus.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func refreshFocusShortcuts() {
        guard !isCheckingFocusShortcuts, !isRunningFocusShortcut, !isChangingSession else { return }
        isCheckingFocusShortcuts = true
        shortcutStatus.stringValue = "Checking shortcuts…"
        shortcutStatus.textColor = .secondaryLabelColor
        updateFocusButtons()
        Task { [self] in
            defer { isCheckingFocusShortcuts = false; updateFocusButtons() }
            do {
                let shortcuts = try await focusRunner.installedShortcuts()
                installedFocusShortcuts = shortcuts
                shortcutStatus.stringValue = "\(shortcuts.count) of 2 shortcuts found"
                shortcutStatus.textColor = shortcuts.count == 2 ? .systemGreen : .systemOrange
            } catch {
                installedFocusShortcuts = nil
                shortcutStatus.stringValue = "Could not check shortcuts"
                shortcutStatus.textColor = .systemOrange
                shortcutStatus.toolTip = error.localizedDescription
            }
        }
    }

    private func updateFocusButtons() {
        focusOnButton?.isEnabled = !isRunningFocusShortcut && !isCheckingFocusShortcuts && !isChangingSession
            && (installedFocusShortcuts?.contains(.turnOn) ?? true)
        focusOffButton?.isEnabled = !isRunningFocusShortcut && !isCheckingFocusShortcuts && !isChangingSession
            && (installedFocusShortcuts?.contains(.turnOff) ?? true)
    }

    @objc private func refreshSetup() { refreshFocusShortcuts() }

    @objc private func confirmSetup() {
        for (key, control) in [("corners", cornersConfirmed), ("gestures", gesturesConfirmed), ("lock", lockConfirmed)] {
            UserDefaults.standard.set(control.state == .on, forKey: "setup.confirmed.\(key)")
        }
        updateSetupConfirmations()
    }

    private func updateSetupConfirmations() {
        for (key, control, label) in [("corners", cornersConfirmed, cornersStatus),
                                      ("gestures", gesturesConfirmed, gesturesStatus), ("lock", lockConfirmed, lockStatus)] {
            let confirmed = UserDefaults.standard.bool(forKey: "setup.confirmed.\(key)")
            control.state = confirmed ? .on : .off
            label.stringValue = confirmed ? "Confirmed by you" : "Needs your check"
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = confirmed ? .secondaryLabelColor : .systemOrange
        }
    }

    @objc private func showShortcutSetup() {
        let alert = NSAlert()
        alert.messageText = "Set up Do Not Disturb shortcuts"
        alert.informativeText = "1. In Shortcuts, create “Turn DND On”. Add Set Focus: turn Do Not Disturb on until turned off.\n\n2. Create “Turn DND Off”. Add Set Focus: turn Do Not Disturb off.\n\n3. Run each once in Shortcuts to complete any prompts. Use just the Set Focus action, with no input requests or dialogs.\n\nReturn here and click Refresh status. Focus options configures allowed interruptions; the On and Off buttons here change Focus through your shortcuts."
        alert.addButton(withTitle: "Open Shortcuts")
        alert.addButton(withTitle: "Done")
        if let window {
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.openShortcuts() }
            }
        }
    }

    private func populate() {
        let c = store.configuration
        fullScreen.state = c.fullScreen ? .on : .off
        automaticDND.state = c.automaticDoNotDisturb ? .on : .off
        updateSetupConfirmations()
        website.stringValue = c.website
        hosts.stringValue = c.additionalHosts
        restrict.state = c.restrictNavigation ? .on : .off
        persistent.state = c.persistentSession ? .on : .off
        idle.stringValue = String(c.idleSeconds)
        refresh.stringValue = String(c.refreshMinutes)
        timeout.stringValue = String(c.loadTimeout)
        automatic.state = c.startAutomatically ? .on : .off
        recovery.state = c.recoverApplication ? .on : .off
        login.state = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status) ? .on : .off
        passcode.stringValue = ""
        removePasscode.state = .off
        removePasscode.isEnabled = store.credential != nil
        passcodeNote.stringValue = store.credential == nil
            ? "Optional. Without a passcode, anyone who knows the shortcut can exit."
            : "Passcode is set. Leave this field empty to keep it."
        display.removeAllItems()
        display.addItem(withTitle: "Main display (automatic)")
        displayIDs = [0]
        for screen in NSScreen.screens {
            display.addItem(withTitle: "\(screen.localizedName) · \(Int(screen.frame.width)) × \(Int(screen.frame.height))")
            displayIDs.append(screen.displayID)
        }
        if c.displayID != 0, !displayIDs.contains(c.displayID) {
            display.addItem(withTitle: "Disconnected display · \(c.displayID) (main display for now)")
            displayIDs.append(c.displayID)
        }
        display.selectItem(at: displayIDs.firstIndex(of: c.displayID) ?? 0)
        statusLabel.stringValue = "READY TO RUN"
    }

    private func save() -> Bool {
        do {
            guard let idleValue = Int(idle.stringValue), let refreshValue = Int(refresh.stringValue),
                  let timeoutValue = Int(timeout.stringValue) else {
                throw ConfigurationError("Enter whole numbers for the three timing settings.")
            }
            var c = store.configuration
            c.website = website.stringValue
            c.fullScreen = fullScreen.state == .on
            c.automaticDoNotDisturb = automaticDND.state == .on
            c.additionalHosts = hosts.stringValue
            c.restrictNavigation = restrict.state == .on
            c.persistentSession = persistent.state == .on
            c.idleSeconds = idleValue
            c.refreshMinutes = refreshValue
            c.loadTimeout = timeoutValue
            c.startAutomatically = automatic.state == .on
            c.recoverApplication = recovery.state == .on
            c.displayID = displayIDs[max(0, display.indexOfSelectedItem)]
            try store.save(c, newPasscode: passcode.stringValue, removePasscode: removePasscode.state == .on)
            let service = SMAppService.mainApp
            if login.state == .on, ![.enabled, .requiresApproval].contains(service.status) {
                try service.register()
            } else if login.state == .off, [.enabled, .requiresApproval].contains(service.status) {
                try service.unregister()
            }
            populate()
            statusLabel.stringValue = service.status == .requiresApproval ? "APPROVE IN LOGIN ITEMS" : "SETTINGS SAVED"
            return true
        } catch {
            showError(error.localizedDescription)
            return false
        }
    }

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Check your kiosk settings"
        alert.informativeText = message
        alert.alertStyle = .warning
        if let window { alert.beginSheetModal(for: window) }
    }

    @objc private func saveOnly() { _ = save() }
    @objc private func previewWebsite() { if !isChangingSession, !isRunningFocusShortcut, save() { onStart?(true) } }
    @objc private func startWebsite() { if !isChangingSession, !isRunningFocusShortcut, save() { onStart?(false) } }
    @objc private func turnDNDOn() { runFocusShortcut(.turnOn) }
    @objc private func turnDNDOff() { runFocusShortcut(.turnOff) }
    @objc private func openShortcuts() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") else {
            focusStatus.stringValue = "Shortcuts could not be found. Open the Shortcuts app on this Mac and complete the setup below."
            focusStatus.textColor = .systemRed
            return
        }
        NSWorkspace.shared.open(url)
    }

    func setSessionTransition(busy: Bool, message: String? = nil, failed: Bool = false) {
        isChangingSession = busy
        startButton.isEnabled = !busy && !isRunningFocusShortcut
        previewButton.isEnabled = !busy && !isRunningFocusShortcut
        updateFocusButtons()
        if busy { focusProgress.startAnimation(nil) }
        else if !isRunningFocusShortcut { focusProgress.stopAnimation(nil) }
        if let message {
            focusStatus.stringValue = message
            focusStatus.textColor = failed ? .systemRed : .secondaryLabelColor
        }
    }

    private func runFocusShortcut(_ shortcut: FocusShortcut) {
        guard !isRunningFocusShortcut, !isCheckingFocusShortcuts, !isChangingSession else { return }
        isRunningFocusShortcut = true
        focusOnButton.isEnabled = false
        focusOffButton.isEnabled = false
        // Keep settings accessible if Shortcuts needs permission or input before locking the Mac.
        startButton.isEnabled = false
        previewButton.isEnabled = false
        focusProgress.startAnimation(nil)
        focusStatus.textColor = .secondaryLabelColor
        focusStatus.stringValue = "Running “\(shortcut.rawValue)”…"
        Task { [self] in
            defer {
                isRunningFocusShortcut = false
                updateFocusButtons()
                startButton.isEnabled = true
                previewButton.isEnabled = true
                focusProgress.stopAnimation(nil)
            }
            do {
                try await focusRunner.run(shortcut)
                focusStatus.textColor = .secondaryLabelColor
                focusStatus.stringValue = "“\(shortcut.rawValue)” completed. Check Focus in Control Center to confirm the setting."
            } catch {
                focusStatus.textColor = .systemRed
                focusStatus.stringValue = "“\(shortcut.rawValue)” did not complete. Open Shortcuts and check its name, actions, and permissions."
                let alert = NSAlert()
                alert.messageText = "Could not complete “\(shortcut.rawValue)”"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                if let window, window.isVisible, window.attachedSheet == nil {
                    alert.beginSheetModal(for: window, completionHandler: nil)
                }
            }
        }
    }
    @objc private func openFocus() { openSettings("com.apple.Focus-Settings.extension") }
    @objc private func openTrackpad() { openSettings("com.apple.Trackpad-Settings.extension") }
    @objc private func openDesktop() { openSettings("com.apple.Desktop-Settings.extension") }
    @objc private func openLockScreen() { openSettings("com.apple.Lock-Screen-Settings.extension") }
    @objc private func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }

    private func text(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }
    private func title(_ heading: String, _ detail: String) -> NSStackView {
        vertical([text(heading, size: 14, weight: .semibold), text(detail, size: 12, color: .secondaryLabelColor)], spacing: 5)
    }
    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }
    private func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }
    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for view in views where view is NSBox { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }
    private func inline(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }
    private func row(_ label: String, _ control: NSView) -> NSStackView {
        let label = text(label, size: 12)
        label.widthAnchor.constraint(equalToConstant: 205).isActive = true
        return inline([label, control])
    }
}

private final class FlippedSettingsView: NSView {
    override var isFlipped: Bool { true }
}
