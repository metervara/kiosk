import AppKit
import WebKit
import IOKit.pwr_mgt
import KioskCore
import os

@MainActor
final class KioskSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    private(set) var isRunning = false
    private(set) var isPreview = false
    private(set) var status = "Ready" { didSet { onStatusChange?(status) } }
    var onStatusChange: ((String) -> Void)?
    var onStop: (() -> Void)?
    var credential: OperatorCredential?

    private var configuration = KioskConfiguration()
    private var policy: NavigationPolicy?
    private var health: BrowserHealth?
    private var window: KioskWindow?
    private var shields: [NSWindow] = []
    private var webView: KioskWebView?
    private var reconnectView: NSView?
    private var timer: Timer?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var savedPresentation: NSApplication.PresentationOptions = []
    private var activity: NSObjectProtocol?
    private var displayAssertion: IOPMAssertionID = 0
    private var unlockPanel: NSPanel?
    private var unlockField: NSSecureTextField?
    private var unlockMessage: NSTextField?
    private var unlockDeadline: TimeInterval = 0
    private var failedUnlocks = 0
    private var nextUnlockAttempt: TimeInterval = 0
    private let recovery = RecoverySupervisor()
    private let logger = Logger(subsystem: "xyz.metervara.kiosk", category: "browser")
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var usesFullScreen: Bool { configuration.usesFullScreen(preview: isPreview) }

    func start(_ value: KioskConfiguration, preview: Bool = false) throws {
        guard !isRunning else { return }
        guard !NSScreen.screens.isEmpty else { throw ConfigurationError("Connect a display before starting Kiosk.") }
        configuration = try value.validated()
        let home = try WebsiteAddress.parse(configuration.website)
        policy = try NavigationPolicy(home: home, additionalHosts: configuration.additionalHosts,
                                      restricted: configuration.restrictNavigation)
        health = BrowserHealth(configuration: configuration, now: now)
        isPreview = preview
        savedPresentation = NSApp.presentationOptions
        // Establish recovery before entering the locked presentation. A failure leaves settings accessible.
        if !preview { try recovery.start(configuration: configuration) }
        isRunning = true
        createWindows()
        installEventMonitor()
        installObservers()
        rebuildBrowser()
        if usesFullScreen {
            NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableAppleMenu,
                .disableProcessSwitching, .disableForceQuit, .disableSessionTermination,
                .disableHideApplication, .disableCursorLocationAssistance]
        }
        if !preview {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Running an exhibition kiosk")
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Kiosk exhibition" as CFString, &displayAssertion)
            if result != kIOReturnSuccess { logger.error("Display sleep assertion failed: \(result)") }
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if !usesFullScreen {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else { enforceFocus() }
    }

    func stop() {
        guard isRunning else { return }
        recovery.stop() // Revoke restart permission before releasing anything else.
        isRunning = false
        timer?.invalidate()
        timer = nil
        dismissUnlock()
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor) }
        eventMonitor = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        webView = nil
        reconnectView?.removeFromSuperview()
        reconnectView = nil
        window?.orderOut(nil)
        window = nil
        shields.forEach { $0.orderOut(nil) }
        shields.removeAll()
        NSApp.presentationOptions = savedPresentation
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
        status = "Ready"
        onStop?()
    }

    func requestUnlock() {
        guard isRunning, unlockPanel == nil else { return }
        if isPreview || credential == nil { stop(); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 216),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Operator access"
        panel.level = NSWindow.Level(rawValue: (window?.level.rawValue ?? 0) + 1)
        panel.isReleasedWhenClosed = false
        let content = NSView(frame: panel.contentView!.bounds)
        panel.contentView = content
        let title = NSTextField(labelWithString: "End this kiosk session")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        title.frame = NSRect(x: 24, y: 163, width: 370, height: 28)
        content.addSubview(title)
        let label = NSTextField(labelWithString: "Enter the operator passcode to return to settings.")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 24, y: 133, width: 370, height: 22)
        content.addSubview(label)
        let field = NSSecureTextField(frame: NSRect(x: 24, y: 94, width: 372, height: 28))
        field.placeholderString = "Operator passcode"
        field.target = self
        field.action = #selector(submitUnlock)
        content.addSubview(field)
        let message = NSTextField(labelWithString: "")
        message.textColor = .systemRed
        message.font = .systemFont(ofSize: 11)
        message.frame = NSRect(x: 24, y: 65, width: 372, height: 22)
        content.addSubview(message)
        let cancel = NSButton(title: "Keep running", target: self, action: #selector(cancelUnlock))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 158, y: 20, width: 125, height: 32)
        let unlock = NSButton(title: "Unlock", target: self, action: #selector(submitUnlock))
        unlock.bezelStyle = .rounded
        unlock.keyEquivalent = "\r"
        unlock.frame = NSRect(x: 288, y: 20, width: 108, height: 32)
        content.addSubview(cancel)
        content.addSubview(unlock)
        unlockPanel = panel
        unlockField = field
        unlockMessage = message
        unlockDeadline = now + 30
        window?.beginSheet(panel)
        panel.makeFirstResponder(field)
    }

    func bringToFront() {
        if !usesFullScreen { window?.makeKeyAndOrderFront(nil) }
        else { enforceFocus() }
    }

    @objc private func submitUnlock() {
        guard now >= nextUnlockAttempt else {
            unlockMessage?.stringValue = "Try again in \(Int(ceil(nextUnlockAttempt - now))) seconds."
            return
        }
        guard let field = unlockField, credential?.verifies(field.stringValue) == true else {
            failedUnlocks += 1
            nextUnlockAttempt = now + min(30, pow(2, Double(min(failedUnlocks, 5))))
            unlockMessage?.stringValue = "Incorrect passcode. Please wait before trying again."
            unlockField?.stringValue = ""
            return
        }
        failedUnlocks = 0
        stop()
    }

    @objc private func cancelUnlock() { dismissUnlock() }

    private func dismissUnlock() {
        if let panel = unlockPanel { window?.endSheet(panel); panel.orderOut(nil) }
        unlockPanel = nil
        unlockField = nil
        unlockMessage = nil
        health?.interacted(at: now)
        if isRunning { enforceFocus() }
    }

    private func createWindows() {
        let screen = NSScreen.screens.first { $0.displayID == configuration.displayID } ?? NSScreen.screens.first
        guard let screen else { return }
        let width = min(1000, screen.visibleFrame.width - 40)
        let height = min(680, screen.visibleFrame.height - 80)
        let frame = !usesFullScreen ? NSRect(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.midY - height / 2,
                                            width: width, height: height) : screen.frame
        let kiosk = KioskWindow(contentRect: frame, styleMask: !usesFullScreen ? [.titled, .resizable] : [.borderless],
                                backing: .buffered, defer: false)
        kiosk.title = isPreview ? "Kiosk preview — ⌃⌥⌘K to close" : "Kiosk (windowed) — ⌃⌥⌘K to end session"
        kiosk.isReleasedWhenClosed = false
        kiosk.backgroundColor = .black
        kiosk.hasShadow = !usesFullScreen
        kiosk.isMovable = !usesFullScreen
        kiosk.isMovableByWindowBackground = false
        kiosk.level = !usesFullScreen ? .normal : NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        if usesFullScreen { kiosk.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle] }
        kiosk.contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        window = kiosk
        updateScreens()
    }

    private func updateScreens() {
        guard isRunning, usesFullScreen else { return }
        dismissUnlock()
        shields.forEach { $0.orderOut(nil) }
        shields.removeAll()
        let target = NSScreen.screens.first { $0.displayID == configuration.displayID } ?? NSScreen.screens.first
        for screen in NSScreen.screens {
            if screen == target { window?.setFrame(screen.frame, display: true); continue }
            let shield = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            shield.backgroundColor = .black
            shield.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue)
            shield.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            shield.isReleasedWhenClosed = false
            shield.orderFrontRegardless()
            shields.append(shield)
        }
        enforceFocus()
    }

    private func installObservers() {
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateScreens() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enforceFocus() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recovery.beat()
                self?.rebuildBrowser()
                self?.enforceFocus()
            }
        })
    }

    private func installEventMonitor() {
        let events: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                             .mouseMoved, .leftMouseDragged, .scrollWheel, .magnify, .smartMagnify,
                                             .swipe, .rotate]
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            let allowed = MainActor.assumeIsolated {
                guard let self else { return true }
                return self.filter(event) != nil
            }
            return allowed ? event : nil
        }
    }

    private func filter(_ event: NSEvent) -> NSEvent? {
        guard isRunning else { return event }
        health?.interacted(at: now)
        if event.type == .keyDown {
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if flags == [.command, .control, .option], event.keyCode == 40 {
                requestUnlock()
                return nil
            }
            if unlockPanel != nil {
                if event.keyCode == 53 { dismissUnlock(); return nil }
                // Allow text entry, but no app commands while the passcode panel is open.
                return flags.contains(.command) ? nil : event
            }
            if event.keyCode == 53 || flags.contains(.command) || flags.contains(.control)
                || (flags.contains(.option) && [123, 124].contains(event.keyCode)) {
                return nil
            }
        }
        if [.rightMouseDown, .otherMouseDown, .magnify, .smartMagnify, .swipe, .rotate].contains(event.type) { return nil }
        if event.type == .scrollWheel && !event.modifierFlags.intersection([.control, .command]).isEmpty { return nil }
        return event
    }

    private func enforceFocus() {
        guard isRunning, usesFullScreen, let window else { return }
        if NSApp.isHidden { NSApp.unhide(nil) }
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if let panel = unlockPanel { panel.makeKeyAndOrderFront(nil); return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(webView)
        }
        window.orderFrontRegardless()
    }

    private func tick() {
        guard isRunning else { return }
        recovery.beat()
        enforceFocus()
        if unlockPanel != nil {
            if now >= unlockDeadline { dismissUnlock() }
            return
        }
        switch health?.nextAction(at: now) ?? .none {
        case .none:
            if health?.retryAt != nil { showReconnecting() }
        case .recover:
            rebuildBrowser()
        case .idleReset, .refresh:
            rebuildBrowser()
        case .probe:
            guard let browser = webView else { rebuildBrowser(); return }
            browser.evaluateJavaScript("document.readyState", in: nil, in: .defaultClient) { [weak self, weak browser] result in
                guard let self, let browser, self.webView === browser, self.isRunning else { return }
                let healthy: Bool
                switch result {
                case .success(let value): healthy = value as? String != nil
                case .failure: healthy = false
                }
                self.health?.probeCompleted(at: self.now, healthy: healthy)
            }
        }
    }

    private func rebuildBrowser() {
        guard isRunning, let home = URL(string: configuration.website), let content = window?.contentView else { return }
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        let options = WKWebViewConfiguration()
        options.websiteDataStore = configuration.persistentSession ? .default() : .nonPersistent()
        options.preferences.javaScriptCanOpenWindowsAutomatically = false
        options.preferences.isElementFullscreenEnabled = false
        options.preferences.isTextInteractionEnabled = true
        options.mediaTypesRequiringUserActionForPlayback = []
        if let scriptURL = Bundle.main.url(forResource: "Kiosk", withExtension: "js", subdirectory: "Model"),
           let script = try? String(contentsOf: scriptURL) {
            options.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                                                    forMainFrameOnly: false, in: .defaultClient))
        }
        let browser = KioskWebView(frame: content.bounds, configuration: options)
        browser.autoresizingMask = [.width, .height]
        browser.allowsBackForwardNavigationGestures = false
        browser.allowsMagnification = false
        browser.allowsLinkPreview = false
        if #available(macOS 13.3, *) { browser.isInspectable = false }
        browser.navigationDelegate = self
        browser.uiDelegate = self
        content.addSubview(browser, positioned: .below, relativeTo: reconnectView)
        webView = browser
        health?.navigationStarted(at: now)
        status = "Loading website…"
        browser.load(URLRequest(url: home, cachePolicy: .reloadIgnoringLocalCacheData,
                                timeoutInterval: TimeInterval(configuration.loadTimeout)))
        window?.makeFirstResponder(browser)
    }

    private func showReconnecting() {
        status = "Reconnecting…"
        guard reconnectView == nil, let content = window?.contentView else { return }
        let overlay = NSView(frame: content.bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 1).cgColor
        overlay.autoresizingMask = [.width, .height]
        let label = NSTextField(labelWithString: "Reconnecting…\nThe experience will return automatically.")
        label.font = .systemFont(ofSize: 20, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                                     label.centerYAnchor.constraint(equalTo: overlay.centerYAnchor)])
        content.addSubview(overlay)
        reconnectView = overlay
    }

    private func failed(_ browser: WKWebView, error: Error? = nil) {
        guard webView === browser, isRunning else { return }
        if let error, (error as NSError).code == NSURLErrorCancelled,
           (error as NSError).domain == NSURLErrorDomain { return }
        logger.notice("Website recovery scheduled\(error.map { ": \(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "")")
        health?.failed(at: now)
        showReconnecting()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard self.webView === webView else { return }
        health?.navigationStarted(at: now)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard self.webView === webView else { return }
        health?.navigationFinished(at: now)
        reconnectView?.removeFromSuperview()
        reconnectView = nil
        status = isPreview ? "Preview running" : (usesFullScreen ? "Full-screen kiosk running" : "Windowed kiosk running")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(webView, error: error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(webView, error: error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed(webView) }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard self.webView === webView, isRunning, let url = action.request.url else { decisionHandler(.cancel); return }
        let topLevel = action.targetFrame?.isMainFrame ?? true
        // Embedded frames may use other web hosts (maps, video, CDNs). They cannot launch external apps.
        let allowed = topLevel ? policy?.allows(url) == true : ["http", "https", "about", "blob", "data"].contains(url.scheme?.lowercased() ?? "")
        guard allowed, !action.shouldPerformDownload else { decisionHandler(.cancel); return }
        if action.targetFrame == nil {
            decisionHandler(.cancel)
            webView.load(action.request) // Keep allowed target=_blank links in this window.
        } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame {
            guard let url = response.response.url, policy?.allows(url) == true else { decisionHandler(.cancel); return }
            if let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
                decisionHandler(.cancel)
                failed(webView)
                return
            }
        }
        let attachment = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?
            .lowercased().hasPrefix("attachment") == true
        decisionHandler(response.canShowMIMEType && !attachment ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webViewDidClose(_ webView: WKWebView) { /* A website cannot close its kiosk window. */ }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Use normal TLS validation; suppress HTTP/client-certificate login dialogs.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
