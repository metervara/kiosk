import Foundation

/// Pairs Focus commands with a whole kiosk session, never with individual page reloads.
@MainActor
public final class SessionFocusController {
    private enum Phase { case idle, starting, running, stopping }
    private var phase = Phase.idle
    private var shouldTurnOff = false
    private let runShortcut: (FocusShortcut) async throws -> Void
    private let installedShortcuts: () async throws -> Set<FocusShortcut>

    public init(runner: FocusShortcutRunner = FocusShortcutRunner()) {
        runShortcut = { try await runner.run($0) }
        installedShortcuts = { try await runner.installedShortcuts() }
    }

    /// Injected commands let lifecycle tests run without changing the Mac's Focus.
    public init(runShortcut: @escaping (FocusShortcut) async throws -> Void,
                installedShortcuts: @escaping () async throws -> Set<FocusShortcut>) {
        self.runShortcut = runShortcut
        self.installedShortcuts = installedShortcuts
    }

    public func start(configuration: KioskConfiguration, preview: Bool,
                      openSession: () throws -> Void) async throws {
        guard phase == .idle else { throw ConfigurationError("A kiosk session is already starting or running.") }
        phase = .starting
        defer { if phase == .starting { phase = .idle } }
        let automatic = configuration.automaticDoNotDisturb && !preview
        if automatic {
            let installed = try await installedShortcuts()
            guard installed.contains(.turnOn), installed.contains(.turnOff) else {
                throw ConfigurationError("Automatic Do Not Disturb needs both “Turn DND On” and “Turn DND Off”. Set them up in Mac setup, or turn off the automatic option.")
            }
        }
        try Task.checkCancellation()
        do {
            if automatic {
                // Even a failed command may already have changed Focus before reporting an error.
                shouldTurnOff = true
                try await runShortcut(.turnOn)
            }
            try Task.checkCancellation()
            try openSession()
            phase = .running
        } catch {
            let startError = error
            if shouldTurnOff {
                shouldTurnOff = false
                do { try await runShortcut(.turnOff) }
                catch {
                    throw ConfigurationError("Kiosk did not start: \(startError.localizedDescription)\n\nDo Not Disturb could not be turned off: \(error.localizedDescription) Check Focus in Control Center or use Turn DND Off in Mac setup.")
                }
            }
            throw startError
        }
    }

    /// Call after the website has closed and macOS presentation controls have been restored.
    public func end() async throws {
        guard phase == .running else { return }
        phase = .stopping
        defer { phase = .idle }
        guard shouldTurnOff else { return }
        shouldTurnOff = false
        do { try await runShortcut(.turnOff) }
        catch {
            throw ConfigurationError("The kiosk session ended, but Do Not Disturb could not be turned off. \(error.localizedDescription)\n\nCheck Focus in Control Center or retry Turn DND Off in Mac setup.")
        }
    }
}
