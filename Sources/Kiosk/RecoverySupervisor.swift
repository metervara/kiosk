import AppKit
import Foundation
import KioskCore
import os

struct RecoveryLease: Codable {
    let token: String
    let pid: Int32
    let launchDate: Date?
    let bundlePath: String
    let configuration: KioskConfiguration
    var heartbeat: Date

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("xyz.metervara.kiosk/Recovery.json")
    }

    static func read(from url: URL = fileURL) -> RecoveryLease? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func write(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor
final class RecoverySupervisor {
    private var lease: RecoveryLease?
    private var process: Process?
    private let logger = Logger(subsystem: "xyz.metervara.kiosk", category: "supervisor")

    func start(configuration: KioskConfiguration) throws {
        guard configuration.recoverApplication, Bundle.main.bundleURL.pathExtension == "app",
              let executable = Bundle.main.executableURL else { return }
        let record = RecoveryLease(token: UUID().uuidString, pid: ProcessInfo.processInfo.processIdentifier,
                                   launchDate: NSRunningApplication.current.launchDate,
                                   bundlePath: Bundle.main.bundlePath, configuration: configuration, heartbeat: Date())
        try record.write()
        lease = record
        let child = Process()
        child.executableURL = executable
        child.arguments = ["--watchdog", RecoveryLease.fileURL.path, record.token]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do {
            try child.run()
            process = child
        } catch {
            stop()
            throw error
        }
    }

    func beat() {
        guard var record = lease else { return }
        record.heartbeat = Date()
        do { try record.write(); lease = record }
        catch { logger.error("Could not update recovery heartbeat: \(error.localizedDescription, privacy: .public)") }
        // Replace a crashed helper while the UI remains healthy.
        if process?.isRunning == false {
            stop()
            do { try start(configuration: record.configuration) }
            catch { logger.error("Could not restart watchdog: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func stop() {
        if let lease, RecoveryLease.read()?.token == lease.token {
            try? FileManager.default.removeItem(at: RecoveryLease.fileURL)
        }
        lease = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
    }
}

/// Runs before NSApplication is created, in a separate instance of the bundled executable.
/// Only a live session creates this process; an intentional stop revokes its lease first.
func runWatchdog(leaseURL: URL, token: String) -> Never {
    let logger = Logger(subsystem: "xyz.metervara.kiosk", category: "watchdog")
    while true {
        Thread.sleep(forTimeInterval: 3)
        guard let lease = RecoveryLease.read(from: leaseURL), lease.token == token else { exit(0) }
        let running = NSRunningApplication(processIdentifier: lease.pid)
        let sameProcess = running?.bundleURL?.path == lease.bundlePath && running?.launchDate == lease.launchDate
        let alive = sameProcess && running?.isTerminated == false
        if alive && Date().timeIntervalSince(lease.heartbeat) < 60 { continue }
        // A second observation allows a Mac waking from sleep to publish a new heartbeat.
        Thread.sleep(forTimeInterval: 8)
        guard let current = RecoveryLease.read(from: leaseURL), current.token == token else { exit(0) }
        if alive && current.heartbeat > lease.heartbeat { continue }
        if alive {
            // Match both bundle path and launch date so a reused PID cannot target another app.
            guard let candidate = NSRunningApplication(processIdentifier: lease.pid),
                  candidate.bundleURL?.path == lease.bundlePath, candidate.launchDate == lease.launchDate else { continue }
            logger.error("Restarting an unresponsive Kiosk application")
            candidate.forceTerminate()
            Thread.sleep(forTimeInterval: 3)
            if !candidate.isTerminated { continue }
        }
        guard RecoveryLease.read(from: leaseURL)?.token == token else { exit(0) }
        logger.notice("Relaunching Kiosk after an unexpected exit")
        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launch.arguments = ["-a", lease.bundlePath, "--args", "--recover", token]
        do { try launch.run(); launch.waitUntilExit() }
        catch { logger.error("Relaunch failed: \(error.localizedDescription, privacy: .public)") }
        Thread.sleep(forTimeInterval: 20)
    }
}
