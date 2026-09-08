import XCTest
@testable import KioskCore

final class FocusShortcutRunnerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func runner(script: String, timeout: TimeInterval = 3) throws -> FocusShortcutRunner {
        let executable = directory.appendingPathComponent("fake-shortcuts")
        try ("#!/bin/sh\n" + script + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return FocusShortcutRunner(executable: executable, timeout: timeout)
    }

    func testPassesShortcutNameAsOneArgument() async throws {
        for shortcut in [FocusShortcut.turnOn, .turnOff] {
            let subject = try runner(script: "[ \"$#\" -eq 2 ] && [ \"$1\" = run ] && [ \"$2\" = '\(shortcut.rawValue)' ]")
            try await subject.run(shortcut)
        }
    }

    func testListingFindsOnlyTheExactFocusShortcutNames() async throws {
        let subject = try runner(script: "[ \"$1\" = list ] || exit 1; printf '%s\\n' 'Turn DND On ' Another 'Turn DND On' 'Turn DND Off' 'Turn DND Off extra'")
        let installed = try await subject.installedShortcuts()
        XCTAssertEqual(installed, [.turnOn, .turnOff])
    }

    func testMissingShortcutIsNotReportedAsAvailable() async throws {
        let subject = try runner(script: "printf '%s\\n' 'Turn DND On' 'Turn DND Off '")
        let installed = try await subject.installedShortcuts()
        XCTAssertEqual(installed, [.turnOn])
    }

    func testNonzeroExitReportsTheShortcutsError() async throws {
        let subject = try runner(script: "echo 'Shortcut not found' >&2; exit 1")
        do {
            try await subject.run(.turnOn)
            XCTFail("A launched process with exit code 1 must not count as success.")
        } catch FocusShortcutError.failed(let status, let detail) {
            XCTAssertEqual(status, 1)
            XCTAssertTrue(detail.contains("Shortcut not found"))
        }
    }

    func testMissingExecutableIsALaunchFailure() async throws {
        let subject = FocusShortcutRunner(executable: directory.appendingPathComponent("missing"))
        do {
            try await subject.run(.turnOff)
            XCTFail("A missing executable should fail.")
        } catch FocusShortcutError.launchFailed { }
    }

    func testLargeErrorOutputIsDrainedAndCapped() async throws {
        let subject = try runner(script: "i=0; while [ $i -lt 3000 ]; do echo 'A detailed shortcut failure repeated many times' >&2; i=$((i+1)); done; exit 2")
        do {
            try await subject.run(.turnOn)
            XCTFail("The command should report failure.")
        } catch FocusShortcutError.failed(let status, let detail) {
            XCTAssertEqual(status, 2)
            XCTAssertLessThanOrEqual(detail.utf8.count, 4096)
            XCTAssertFalse(detail.isEmpty)
        }
    }

    func testStalledCommandHasABoundedTimeout() async throws {
        let subject = try runner(script: "trap '' TERM; while :; do :; done", timeout: 0.1)
        do {
            try await subject.run(.turnOn)
            XCTFail("A command that never exits should time out.")
        } catch FocusShortcutError.timedOut { }
    }
}
