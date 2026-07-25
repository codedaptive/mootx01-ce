// UpdateAdvisorTests.swift
//
// TTL-cache and gating behavior of UpdateAdvisor — the resident daemon's
// lazily-evaluated upstream-release advisory. Everything is injected
// (check function, clock, environment); no test touches the network.

import Foundation
import Testing

@testable import MootInstallerCore

/// Injected clock the tests advance by hand to cross the TTL boundary.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

/// Thread-safe probe counter so the tests can assert how many times the
/// feed was actually consulted across advisory() calls.
private final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

@Suite("UpdateAdvisor")
struct UpdateAdvisorTests {

    @Test("newer tag renders the advisory line with tag, installed version, and the upgrade command")
    func rendersAdvisoryLine() async {
        let advisor = UpdateAdvisor(installedVersion: "1.0.33", environment: [:]) { "v1.0.34" }
        let line = await advisor.advisory()
        #expect(line == "v1.0.34 is available (installed 1.0.33) — upgrade with `mootx01 upgrade`")
    }

    @Test("up-to-date (nil tag) stays silent")
    func upToDateIsSilent() async {
        let advisor = UpdateAdvisor(installedVersion: "1.0.33", environment: [:]) { nil }
        #expect(await advisor.advisory() == nil)
    }

    @Test("probe failure stays silent — a broken feed never breaks ping")
    func failureIsSilent() async {
        struct FeedDown: Error {}
        let advisor = UpdateAdvisor(installedVersion: "1.0.33", environment: [:]) { throw FeedDown() }
        #expect(await advisor.advisory() == nil)
    }

    @Test("within the TTL the cached answer is served without re-probing")
    func cachesWithinTTL() async {
        let clock = FakeClock()
        let probes = ProbeCounter()
        let advisor = UpdateAdvisor(
            installedVersion: "1.0.33", ttl: 3600, environment: [:],
            now: { clock.now }
        ) {
            _ = probes.increment()
            return "v1.0.34"
        }
        _ = await advisor.advisory()
        clock.advance(by: 3599)
        let line = await advisor.advisory()
        #expect(probes.count == 1, "second call inside the TTL must be served from cache")
        #expect(line != nil, "cached advisory must still be returned")
    }

    @Test("after the TTL expires the feed is probed again")
    func reprobesAfterTTL() async {
        let clock = FakeClock()
        let probes = ProbeCounter()
        let advisor = UpdateAdvisor(
            installedVersion: "1.0.33", ttl: 3600, environment: [:],
            now: { clock.now }
        ) {
            _ = probes.increment()
            return "v1.0.34"
        }
        _ = await advisor.advisory()
        clock.advance(by: 3601)
        _ = await advisor.advisory()
        #expect(probes.count == 2, "TTL expiry must trigger a fresh probe")
    }

    @Test("failures are cached too — an offline machine probes once per TTL, not once per ping")
    func failureIsRateLimited() async {
        struct FeedDown: Error {}
        let clock = FakeClock()
        let probes = ProbeCounter()
        let advisor = UpdateAdvisor(
            installedVersion: "1.0.33", ttl: 3600, environment: [:],
            now: { clock.now }
        ) {
            _ = probes.increment()
            throw FeedDown()
        }
        _ = await advisor.advisory()
        _ = await advisor.advisory()
        #expect(probes.count == 1, "failed probe must also be rate-limited by the TTL stamp")
    }

    @Test("MOOTX01_NO_UPDATE_CHECK disables the surface entirely — no probe, no advisory")
    func killSwitchDisables() async {
        let probes = ProbeCounter()
        let advisor = UpdateAdvisor(
            installedVersion: "1.0.33",
            environment: ["MOOTX01_NO_UPDATE_CHECK": "1"]
        ) {
            _ = probes.increment()
            return "v1.0.34"
        }
        #expect(await advisor.advisory() == nil)
        #expect(probes.count == 0, "kill switch must prevent the probe itself, not just the line")
    }

    // Promptness is enforced by the .timeLimit trait, not a wall-clock
    // assertion: under swift-testing's parallel runner a loaded machine can
    // stretch elapsed time far past any tight bound (observed 24 s against
    // a 5 s assert) even though the advisory returned at its own timeout.
    // The trait's floor is one minute — coarse, but it still fails a probe
    // that genuinely hangs for its full 10 s-per-retry schedule, while the
    // `line == nil` expectation carries the semantic claim.
    @Test("a hung probe is cut off at the probe timeout and stays silent",
          .timeLimit(.minutes(1)))
    func hungProbeTimesOut() async {
        let advisor = UpdateAdvisor(
            installedVersion: "1.0.33", probeTimeout: 0.05, environment: [:]
        ) {
            // Simulates a black-holed feed host: sleeps far past the
            // probe timeout; task cancellation tears it down.
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return "v9.9.9"
        }
        let line = await advisor.advisory()
        #expect(line == nil)
    }
}
