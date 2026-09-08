import XCTest
@testable import KioskCore

@MainActor
final class SessionFocusControllerTests: XCTestCase {
    private enum FixtureError: Error { case failed }

    func testDisabledOptionAndPreviewNeverRunFocusCommands() async throws {
        for (enabled, preview) in [(false, false), (true, true), (false, true)] {
            var opened = false
            let subject = SessionFocusController(runShortcut: { _ in XCTFail("Must not change Focus") },
                                                 installedShortcuts: { XCTFail("Must not query Shortcuts"); return [] })
            var configuration = KioskConfiguration()
            configuration.automaticDoNotDisturb = enabled
            try await subject.start(configuration: configuration, preview: preview) { opened = true }
            try await subject.end()
            XCTAssertTrue(opened)
        }
    }

    func testBothWindowModesTurnOnBeforeOpeningAndOffOnceOnEnd() async throws {
        for fullScreen in [true, false] {
            var events: [String] = []
            let subject = SessionFocusController(runShortcut: { events.append($0.rawValue) },
                installedShortcuts: { events.append("list"); return [.turnOn, .turnOff] })
            var configuration = KioskConfiguration()
            configuration.automaticDoNotDisturb = true
            configuration.fullScreen = fullScreen
            try await subject.start(configuration: configuration, preview: false) { events.append("open") }
            XCTAssertEqual(events, ["list", "Turn DND On", "open"])
            // The session's captured choice governs cleanup, even if saved settings change.
            configuration.automaticDoNotDisturb = false
            try await subject.end()
            try await subject.end()
            XCTAssertEqual(events, ["list", "Turn DND On", "open", "Turn DND Off"])
        }
    }

    func testMissingOffShortcutPreventsChangingFocusOrOpeningWebsite() async throws {
        let subject = SessionFocusController(runShortcut: { _ in XCTFail("Must not change Focus") },
                                             installedShortcuts: { [.turnOn] })
        var configuration = KioskConfiguration()
        configuration.automaticDoNotDisturb = true
        do {
            try await subject.start(configuration: configuration, preview: false) { XCTFail("Must not open") }
            XCTFail("Both shortcuts must exist")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("needs both"))
        }
    }

    func testFailedOnCommandCleansUpAndDoesNotOpenWebsite() async throws {
        var commands: [FocusShortcut] = []
        let subject = SessionFocusController(runShortcut: {
            commands.append($0)
            if $0 == .turnOn { throw FixtureError.failed }
        }, installedShortcuts: { [.turnOn, .turnOff] })
        var configuration = KioskConfiguration()
        configuration.automaticDoNotDisturb = true
        do {
            try await subject.start(configuration: configuration, preview: false) { XCTFail("Must not open") }
            XCTFail("Startup must fail")
        } catch FixtureError.failed { }
        try await subject.end()
        XCTAssertEqual(commands, [.turnOn, .turnOff])
    }

    func testWebsiteStartupFailureTurnsDNDBackOff() async throws {
        var commands: [FocusShortcut] = []
        let subject = SessionFocusController(runShortcut: { commands.append($0) },
                                             installedShortcuts: { [.turnOn, .turnOff] })
        var configuration = KioskConfiguration()
        configuration.automaticDoNotDisturb = true
        do {
            try await subject.start(configuration: configuration, preview: false) { throw FixtureError.failed }
            XCTFail("Startup must fail")
        } catch FixtureError.failed { }
        XCTAssertEqual(commands, [.turnOn, .turnOff])
    }

    func testOffFailureIsReportedAndDoesNotBlockLaterSessions() async throws {
        let subject = SessionFocusController(runShortcut: {
            if $0 == .turnOff { throw FixtureError.failed }
        }, installedShortcuts: { [.turnOn, .turnOff] })
        var configuration = KioskConfiguration()
        configuration.automaticDoNotDisturb = true
        try await subject.start(configuration: configuration, preview: false) { }
        do {
            try await subject.end()
            XCTFail("Off failure must be reported")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("session ended"))
            XCTAssertTrue(error.localizedDescription.contains("could not be turned off"))
        }
        // Manual Focus correction remains possible, and the coordinator is no longer busy.
        configuration.automaticDoNotDisturb = false
        try await subject.start(configuration: configuration, preview: false) { }
        try await subject.end()
    }

    func testCancellationWhileTurningOnCleansUpWithoutOpening() async throws {
        var commands: [FocusShortcut] = []
        var releaseOn: CheckedContinuation<Void, Never>?
        let subject = SessionFocusController(runShortcut: {
            commands.append($0)
            if $0 == .turnOn { await withCheckedContinuation { releaseOn = $0 } }
        }, installedShortcuts: { [.turnOn, .turnOff] })
        var configuration = KioskConfiguration()
        configuration.automaticDoNotDisturb = true
        let task = Task {
            try await subject.start(configuration: configuration, preview: false) { XCTFail("Cancelled start must not open") }
        }
        while releaseOn == nil { await Task.yield() }
        task.cancel()
        releaseOn?.resume()
        do { try await task.value; XCTFail("Start must cancel") }
        catch is CancellationError { }
        XCTAssertEqual(commands, [.turnOn, .turnOff])
    }

    func testDuplicateStartDoesNotRunAnotherOnCommand() async throws {
        var commands: [FocusShortcut] = []
        let subject = SessionFocusController(runShortcut: { commands.append($0) },
                                             installedShortcuts: { [.turnOn, .turnOff] })
        var configuration = KioskConfiguration()
        configuration.automaticDoNotDisturb = true
        try await subject.start(configuration: configuration, preview: false) { }
        do {
            try await subject.start(configuration: configuration, preview: false) { XCTFail("Must not reopen") }
            XCTFail("Duplicate start must fail")
        } catch { }
        XCTAssertEqual(commands, [.turnOn])
        try await subject.end()
    }

    func testFailedCleanupAfterStartupFailureIsReported() async throws {
        let subject = SessionFocusController(runShortcut: {
            if $0 == .turnOff { throw FixtureError.failed }
        }, installedShortcuts: { [.turnOn, .turnOff] })
        var configuration = KioskConfiguration()
        configuration.automaticDoNotDisturb = true
        do {
            try await subject.start(configuration: configuration, preview: false) { throw FixtureError.failed }
            XCTFail("Startup must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Kiosk did not start"))
            XCTAssertTrue(error.localizedDescription.contains("could not be turned off"))
        }
    }
}
