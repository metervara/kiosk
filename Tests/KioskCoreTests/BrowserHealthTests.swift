import XCTest
@testable import KioskCore

final class BrowserHealthTests: XCTestCase {
    private func makeHealth(idle: Int = 0, refresh: Int = 0) -> BrowserHealth {
        var c = KioskConfiguration()
        c.idleSeconds = idle
        c.refreshMinutes = refresh
        c.loadTimeout = 45
        return BrowserHealth(configuration: c, now: 100)
    }

    func testFailedLoadsRetryWithBackoff() {
        var health = makeHealth()
        health.failed(at: 100)
        XCTAssertEqual(health.nextAction(at: 101), .none)
        XCTAssertEqual(health.nextAction(at: 102), .recover)
        health.navigationStarted(at: 102)
        health.failed(at: 103)
        XCTAssertEqual(health.retryAt, 107)
        health.navigationStarted(at: 107)
        health.navigationFinished(at: 108)
        health.failed(at: 109)
        XCTAssertEqual(health.retryAt, 111)
    }

    func testDuplicateFailureDoesNotPushOutRecovery() {
        var health = makeHealth()
        health.failed(at: 100)
        health.failed(at: 101)
        XCTAssertEqual(health.retryAt, 102)
        XCTAssertEqual(health.failures, 1)
    }

    func testRetryDelayIsCapped() {
        var health = makeHealth()
        for index in 0...20 {
            let time = Double(index * 100)
            health.navigationStarted(at: time)
            health.failed(at: time)
            XCTAssertLessThanOrEqual(health.retryAt! - time, 30)
        }
    }

    func testLoadTimeoutRecoversInsteadOfProbingUnloadedPage() {
        var health = makeHealth()
        health.navigationStarted(at: 100)
        XCTAssertEqual(health.nextAction(at: 144), .none)
        XCTAssertEqual(health.nextAction(at: 145), .none)
        XCTAssertEqual(health.nextAction(at: 147), .recover)
    }

    func testHungJavaScriptTriggersRecovery() {
        var health = makeHealth()
        health.navigationFinished(at: 100)
        XCTAssertEqual(health.nextAction(at: 104), .none)
        XCTAssertEqual(health.nextAction(at: 105), .probe)
        XCTAssertEqual(health.nextAction(at: 119), .none)
        XCTAssertEqual(health.nextAction(at: 120), .none)
        XCTAssertEqual(health.nextAction(at: 122), .recover)
    }

    func testHealthyProbeDoesNotReload() {
        var health = makeHealth()
        health.navigationFinished(at: 100)
        XCTAssertEqual(health.nextAction(at: 105), .probe)
        health.probeCompleted(at: 106, healthy: true)
        XCTAssertEqual(health.nextAction(at: 110), .none)
        XCTAssertEqual(health.nextAction(at: 111), .probe)
    }

    func testOldProbeCallbackCannotClearScheduledRecovery() {
        var health = makeHealth()
        health.navigationFinished(at: 100)
        _ = health.nextAction(at: 105)
        health.failed(at: 106)
        health.probeCompleted(at: 107, healthy: true)
        XCTAssertEqual(health.nextAction(at: 108), .recover)
    }

    func testIdleResetHonorsUserActivity() {
        var health = makeHealth(idle: 20)
        health.navigationFinished(at: 100)
        health.interacted(at: 115)
        XCTAssertEqual(health.nextAction(at: 119), .probe)
        health.probeCompleted(at: 120, healthy: true)
        XCTAssertEqual(health.nextAction(at: 135), .idleReset)
        health.navigationStarted(at: 135)
        XCTAssertEqual(health.nextAction(at: 136), .none)
    }

    func testScheduledRefresh() {
        var health = makeHealth(refresh: 1)
        health.navigationStarted(at: 100)
        health.navigationFinished(at: 101)
        XCTAssertEqual(health.nextAction(at: 160), .refresh)
    }

    func testFailedLoadTakesPriorityOverIdleReset() {
        var health = makeHealth(idle: 10)
        health.failed(at: 120)
        XCTAssertEqual(health.nextAction(at: 121), .none)
        XCTAssertEqual(health.nextAction(at: 122), .recover)
    }
}
