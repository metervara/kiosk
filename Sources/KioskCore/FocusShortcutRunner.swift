import Foundation
import Darwin

public enum FocusShortcut: String, Sendable {
    case turnOn = "Turn DND On"
    case turnOff = "Turn DND Off"
}

public enum FocusShortcutError: LocalizedError {
    case launchFailed(String)
    case failed(status: Int32, detail: String)
    case timedOut
    case listingTooLarge

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let detail):
            return "Could not launch Shortcuts. \(detail)"
        case .failed(let status, let detail):
            return "Shortcuts returned exit code \(status). " + (detail.isEmpty
                ? "Check the shortcut name and run it once in the Shortcuts app."
                : detail)
        case .timedOut:
            return "The shortcut took too long. Check Shortcuts for a prompt and use a single Set Focus action without input. An action may already have run; check Focus in Control Center before retrying."
        case .listingTooLarge:
            return "The shortcut list was too large to check completely. Open Shortcuts to verify the two names."
        }
    }
}

/// Runs a known shortcut directly, without a shell, away from the app's main run loop.
/// The executable override allows tests to exercise process behavior without changing Focus.
public struct FocusShortcutRunner: Sendable {
    private let executable: URL
    private let timeout: TimeInterval

    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/shortcuts"), timeout: TimeInterval = 30) {
        self.executable = executable
        self.timeout = max(0.05, min(timeout, 300))
    }

    public func run(_ shortcut: FocusShortcut) async throws {
        _ = try await command(["run", shortcut.rawValue], captureOutput: false)
    }

    public func installedShortcuts() async throws -> Set<FocusShortcut> {
        let output = try await command(["list"], captureOutput: true)
        return Set(output.components(separatedBy: .newlines).compactMap { FocusShortcut(rawValue: $0) })
    }

    private func command(_ arguments: [String], captureOutput: Bool) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try execute(arguments, captureOutput: captureOutput) })
            }
        }
    }

    private func execute(_ arguments: [String], captureOutput: Bool) throws -> String {
        let process = Process()
        let errors = Pipe()
        let capture = BoundedShortcutOutput()
        let outputPipe = Pipe()
        let output = BoundedShortcutOutput(limit: 1_048_576)
        let outputFinished = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let errorsFinished = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = captureOutput ? outputPipe : FileHandle.nullDevice
        process.standardError = errors
        process.terminationHandler = { _ in finished.signal() }
        // Drain stderr while the process runs so a full pipe cannot stall it.
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                errorsFinished.signal()
            } else { capture.append(data) }
        }
        if captureOutput {
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    outputFinished.signal()
                } else { output.append(data) }
            }
        }
        defer {
            errors.fileHandleForReading.readabilityHandler = nil
            try? errors.fileHandleForReading.close()
            try? errors.fileHandleForWriting.close()
            outputPipe.fileHandleForReading.readabilityHandler = nil
            try? outputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
        }

        do { try process.run() }
        catch { throw FocusShortcutError.launchFailed(error.localizedDescription) }
        try? errors.fileHandleForWriting.close()
        try? outputPipe.fileHandleForWriting.close()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                // Reap only this command, even if it ignores the graceful stop.
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            throw FocusShortcutError.timedOut
        }
        // A descendant retaining stderr must not keep this operation open forever.
        _ = errorsFinished.wait(timeout: .now() + 0.25)
        if captureOutput, outputFinished.wait(timeout: .now() + 0.25) == .timedOut {
            throw FocusShortcutError.failed(status: -1, detail: "The shortcut list could not be read completely. Try Refresh status again.")
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw FocusShortcutError.failed(status: process.terminationStatus, detail: capture.text)
        }
        if output.isTruncated { throw FocusShortcutError.listingTooLarge }
        return output.rawText
    }
}

/// The file-handle callback and process worker access this buffer from different queues.
private final class BoundedShortcutOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int
    private var truncated = false

    init(limit: Int = 4_096) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        if chunk.count > limit - data.count { truncated = true }
        if data.count < limit { data.append(contentsOf: chunk.prefix(limit - data.count)) }
    }

    var isTruncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return truncated
    }

    var rawText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    var text: String { rawText.trimmingCharacters(in: .whitespacesAndNewlines) }
}
