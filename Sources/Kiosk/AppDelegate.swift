import AppKit
import KioskCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = SettingsStore()
    private let session = KioskSession()
    private lazy var settings = SettingsWindow(store: store)
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var statusLine: NSMenuItem!
    private var startItem: NSMenuItem!
    private var stopItem: NSMenuItem!
    private let sessionFocus = SessionFocusController()
    private var isChangingSession = false
    private var sessionTransition: Task<Void, Never>?
    private var terminationRequested = false
    private var sessionUsesAutomaticDND = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menuIcon = Bundle.main.image(forResource: "MenuBarIconTemplate")
            ?? NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Kiosk")
        menuIcon?.size = NSSize(width: 20, height: 18)
        menuIcon?.isTemplate = true
        menuIcon?.accessibilityDescription = "Kiosk"
        statusItem.button?.image = menuIcon
        statusItem.button?.toolTip = "Kiosk · Metervara"
        statusItem.menu = menu
        menu.delegate = self
        statusLine = item("Ready", action: nil)
        menu.addItem(.separator())
        startItem = item("Start kiosk", action: #selector(startKiosk))
        stopItem = item("End session…", action: #selector(endSession))
        _ = item("Settings…", action: #selector(showSettings))
        menu.addItem(.separator())
        _ = item("Quit Kiosk", action: #selector(quit))
        session.onStatusChange = { [weak self] status in
            self?.statusLine.title = status
            self?.statusItem.button?.toolTip = "Kiosk · \(status)"
        }
        session.onStop = { [weak self] in self?.sessionEnded() }
        settings.onStart = { [weak self] preview in self?.start(preview: preview) }
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--settings") {
            // Operator launch override for troubleshooting automatic startup.
            revokeAbandonedLease()
            settings.present()
        } else if let index = arguments.firstIndex(of: "--recover"), arguments.indices.contains(index + 1),
                  let lease = RecoveryLease.read(), lease.token == arguments[index + 1], store.loadError == nil {
            // Consume the old lease even if startup fails, avoiding an endless reopen loop.
            try? FileManager.default.removeItem(at: RecoveryLease.fileURL)
            start(configuration: lease.configuration)
        } else if store.configuration.startAutomatically, store.loadError == nil {
            start()
        } else {
            revokeAbandonedLease()
            settings.present()
            if let error = store.loadError { settings.showError(error) }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        startItem.isEnabled = !session.isRunning && !settings.isRunningFocusShortcut && !isChangingSession
        stopItem.isHidden = !session.isRunning
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isChangingSession {
            // Finish any Focus cleanup before quitting. A pending start must not open the website.
            terminationRequested = true
            sessionTransition?.cancel()
            return .terminateLater
        }
        if settings.isRunningFocusShortcut { return .terminateCancel }
        if session.isRunning { session.requestUnlock(); return .terminateCancel }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // LaunchServices activation is not an operator exit request.
        if session.isRunning { session.bringToFront() } else { settings.present() }
        return false
    }

    private func start(configuration: KioskConfiguration? = nil, preview: Bool = false) {
        guard !session.isRunning, !isChangingSession, !settings.isRunningFocusShortcut else { return }
        guard store.loadError == nil else { settings.present(); settings.showError(store.loadError!); return }
        let value: KioskConfiguration
        do {
            value = try (configuration ?? store.configuration).validated()
        } catch {
            settings.present()
            settings.showError(error.localizedDescription)
            return
        }
        let automaticDND = value.automaticDoNotDisturb && !preview
        if automaticDND { settings.present() }
        isChangingSession = true
        settings.setSessionTransition(busy: true, message: automaticDND ? "Preparing kiosk and running “Turn DND On”…" : nil)
        sessionTransition = Task { [self] in
            do {
                try await sessionFocus.start(configuration: value, preview: preview) {
                    session.credential = store.credential
                    try session.start(value, preview: preview)
                    sessionUsesAutomaticDND = automaticDND
                    settings.window?.orderOut(nil)
                }
                finishSessionTransition(message: automaticDND ? "“Turn DND On” completed for this session." : nil)
            } catch {
                finishSessionTransition(error: error)
            }
        }
    }

    private func sessionEnded() {
        let automaticDND = sessionUsesAutomaticDND
        sessionUsesAutomaticDND = false
        isChangingSession = true
        settings.setSessionTransition(busy: true, message: automaticDND ? "Session ended. Running “Turn DND Off”…" : nil)
        settings.present()
        sessionTransition = Task { [self] in
            do {
                try await sessionFocus.end()
                finishSessionTransition(message: automaticDND ? "“Turn DND Off” completed. Check Focus in Control Center to confirm." : nil)
            } catch {
                finishSessionTransition(error: error)
            }
        }
    }

    private func finishSessionTransition(message: String? = nil, error: Error? = nil) {
        isChangingSession = false
        sessionTransition = nil
        let cancelled = error is CancellationError
        settings.setSessionTransition(busy: false,
            message: cancelled ? "Kiosk start cancelled." : (error == nil ? message : "Session setup or automatic DND needs attention. Check the error below."),
            failed: error != nil && !cancelled)
        if terminationRequested {
            terminationRequested = false
            let canQuit = !session.isRunning && (error == nil || cancelled)
            NSApp.reply(toApplicationShouldTerminate: canQuit)
            if canQuit { return }
        }
        if let error, !cancelled {
            settings.present()
            settings.showError(error.localizedDescription)
        }
    }

    private func revokeAbandonedLease() {
        guard let lease = RecoveryLease.read() else { return }
        let prior = NSRunningApplication(processIdentifier: lease.pid)
        if prior?.launchDate != lease.launchDate || prior?.isTerminated != false {
            try? FileManager.default.removeItem(at: RecoveryLease.fileURL)
        }
    }

    @objc private func startKiosk() { start() }
    @objc private func endSession() { session.requestUnlock() }
    @objc private func showSettings() {
        if session.isRunning { session.requestUnlock() } else { settings.present() }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func item(_ title: String, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let quit = NSMenuItem(title: "Quit Kiosk", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (name, selector, key) in [("Undo", Selector(("undo:")), "z"),
                                      ("Cut", #selector(NSText.cut(_:)), "x"),
                                      ("Copy", #selector(NSText.copy(_:)), "c"),
                                      ("Paste", #selector(NSText.paste(_:)), "v"),
                                      ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(NSMenuItem(title: name, action: selector, keyEquivalent: key))
        }
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}
