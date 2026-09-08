import Foundation

/// Monotonic times keep changes to the Mac's wall clock from affecting recovery.
public struct BrowserHealth {
    public enum Action: Equatable { case none, probe, recover, idleReset, refresh }
    public private(set) var retryAt: TimeInterval?
    public private(set) var failures = 0
    private var navigationStarted: TimeInterval?
    private var probeStarted: TimeInterval?
    private var lastProbe: TimeInterval = 0
    private var lastInteraction: TimeInterval
    private var lastRefresh: TimeInterval
    private let timeout: TimeInterval
    private let idle: TimeInterval
    private let refresh: TimeInterval

    public init(configuration: KioskConfiguration, now: TimeInterval) {
        timeout = TimeInterval(configuration.loadTimeout)
        idle = TimeInterval(configuration.idleSeconds)
        refresh = TimeInterval(configuration.refreshMinutes * 60)
        lastInteraction = now
        lastRefresh = now
    }

    public mutating func interacted(at now: TimeInterval) { lastInteraction = now }

    public mutating func navigationStarted(at now: TimeInterval) {
        navigationStarted = now
        probeStarted = nil
        retryAt = nil
        lastRefresh = now
    }

    public mutating func navigationFinished(at now: TimeInterval) {
        navigationStarted = nil
        probeStarted = nil
        retryAt = nil
        lastProbe = now
        failures = 0
    }

    public mutating func failed(at now: TimeInterval) {
        guard retryAt == nil else { return }
        failures += 1
        retryAt = now + min(30, pow(2, Double(min(failures, 5))))
        navigationStarted = nil
        probeStarted = nil
    }

    public mutating func probeCompleted(at now: TimeInterval, healthy: Bool) {
        guard probeStarted != nil else { return }
        probeStarted = nil
        lastProbe = now
        if !healthy { failed(at: now) }
    }

    public mutating func nextAction(at now: TimeInterval) -> Action {
        if let retryAt { return now >= retryAt ? .recover : .none }
        if let started = navigationStarted {
            if now - started >= timeout { failed(at: now) }
            return .none
        }
        if let started = probeStarted {
            if now - started >= 15 { failed(at: now) }
            return .none
        }
        if idle > 0, now - lastInteraction >= idle {
            lastInteraction = now
            return .idleReset
        }
        if refresh > 0, now - lastRefresh >= refresh { return .refresh }
        if now - lastProbe >= 5 {
            probeStarted = now
            return .probe
        }
        return .none
    }
}
