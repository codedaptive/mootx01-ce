import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

/// Cycle-level firing tests for AnomalySweepSignal — architecture spec §11.18,
/// signal 12 (P3a).
///
/// Verifies cadence, concurrency policy, and diagnostic emission for both
/// the `defaultSpec()` no-op variant and the `spec(anomalyCycle:)` live-closure
/// variant. Mirrors the TemporalCausalitySignal cases in `StandingSignalsTests.swift`.
///
/// Cross-port golden pin: the live-spec test asserts `Ok(1)` from the closure
/// surfaces `"updated 1 drawer(s)"` in the diagnostic detail — the same
/// invariant asserted in `standing_signals_parity.rs`.
@Suite("AnomalySweepSignal — signal 12 cycle-level firing tests (P3a)")
struct AnomalySweepSignalTests {

    // MARK: - Fixture

    private func openOneEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-anomaly-signal-tests")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func firstFireTime(after cadence: TimeInterval) -> Date {
        t0.addingTimeInterval(cadence + 1)
    }

    private func registerAndFire(
        _ kit: GeniusLocusKit, in handle: EstateHandle,
        spec: SignalSpec, cadence: TimeInterval
    ) async throws -> SignalID {
        let id = try await kit.registerStandingSignal(spec, in: handle, now: t0)
        try await kit.signalTick(in: handle, now: firstFireTime(after: cadence))
        return id
    }

    private func report(
        _ kit: GeniusLocusKit, in handle: EstateHandle, for id: SignalID
    ) async throws -> SignalReport {
        let reports = try await kit.signalStatus(in: handle)
        let match = reports.first(where: { $0.signalID == id })
        return try #require(match, "expected report for \(id.rawValue)")
    }

    // MARK: - Static property tests

    @Test("defaultSpec returns the canonical signal name")
    func defaultSpecReturnsCorrectSignalName() throws {
        let spec = AnomalySweepSignal.defaultSpec()
        #expect(spec.name == "anomaly-flag-sweep")
    }

    @Test("cadence is 3 600 seconds per architecture spec §11.18")
    func defaultSpecCadenceIsThreeSixHundredSeconds() throws {
        #expect(
            AnomalySweepSignal.defaultCadenceSeconds == 3_600,
            "anomaly-flag-sweep runs hourly per architecture spec §11.18"
        )
        let spec = AnomalySweepSignal.defaultSpec()
        guard case .interval(let seconds) = spec.trigger else {
            Issue.record("defaultSpec must use an interval trigger")
            return
        }
        #expect(
            seconds == 3_600.0,
            "defaultSpec trigger cadence must match defaultCadenceSeconds"
        )
    }

    @Test("concurrencyPolicy is .single — only one sweep runs at a time")
    func defaultSpecConcurrencyIsSingle() throws {
        let spec = AnomalySweepSignal.defaultSpec()
        #expect(
            spec.concurrencyPolicy == .single,
            "anomaly-flag-sweep is .single — only one sweep runs at a time"
        )
    }

    // MARK: - Firing tests

    @Test("defaultSpec fires exactly one 'anomaly-flag-sweep.fired' diagnostic")
    func defaultSpecFiresEmitsExactlyOneDiagnostic() async throws {
        let (kit, handle) = try await openOneEstate()
        let id = try await registerAndFire(
            kit, in: handle,
            spec: AnomalySweepSignal.defaultSpec(),
            cadence: AnomalySweepSignal.defaultCadenceSeconds)

        let r = try await report(kit, in: handle, for: id)
        #expect(r.name == "anomaly-flag-sweep")
        #expect(r.emissionCount == 1,
            "defaultSpec fires exactly one diagnostic on fire")
        #expect(r.recentDiagnostics.count == 1)
        #expect(r.recentDiagnostics.first?.title == "anomaly-flag-sweep.fired")
    }

    @Test("live spec with closure returning 1 emits 'anomaly-flag-sweep.complete' with count")
    func specWithClosureReturningOneEmitsCompleteWithDrawerCount() async throws {
        // Cross-port golden pin: Ok(1) → detail contains "updated 1 drawer(s)".
        // The Rust twin asserts the identical string in standing_signals_parity.rs.
        let (kit, handle) = try await openOneEstate()
        let spec = AnomalySweepSignal.spec { _ in 1 }
        let id = try await registerAndFire(
            kit, in: handle,
            spec: spec,
            cadence: AnomalySweepSignal.defaultCadenceSeconds)

        let r = try await report(kit, in: handle, for: id)
        #expect(r.name == "anomaly-flag-sweep")
        #expect(r.emissionCount == 1)
        #expect(r.recentDiagnostics.count == 1)
        #expect(r.recentDiagnostics.first?.title == "anomaly-flag-sweep.complete")
        let detail = r.recentDiagnostics.first?.detail ?? ""
        #expect(
            detail.contains("updated 1 drawer(s)"),
            "diagnostic detail must contain the changed-drawer count; got: \(detail)"
        )
    }

    @Test("live spec with zero return emits 'anomaly-flag-sweep.complete' with 0 count (idempotence)")
    func specWithClosureReturningZeroEmitsCompleteWithZeroCount() async throws {
        // Idempotence golden pin: second-run Ok(0) surfaces "updated 0 drawer(s)".
        // Cross-port: Rust anomaly_sweep_signal_idempotence_ok_zero_on_second_run asserts same.
        let (kit, handle) = try await openOneEstate()
        let spec = AnomalySweepSignal.spec { _ in 0 }
        let id = try await registerAndFire(
            kit, in: handle,
            spec: spec,
            cadence: AnomalySweepSignal.defaultCadenceSeconds)

        let r = try await report(kit, in: handle, for: id)
        #expect(r.recentDiagnostics.first?.title == "anomaly-flag-sweep.complete")
        let detail = r.recentDiagnostics.first?.detail ?? ""
        #expect(
            detail.contains("updated 0 drawer(s)"),
            "zero-count return must surface '0 drawer(s)' in detail; got: \(detail)"
        )
    }

    @Test("live spec with throwing closure emits 'anomaly-flag-sweep.error' diagnostic")
    func specWithThrowingClosureEmitsErrorDiagnostic() async throws {
        let (kit, handle) = try await openOneEstate()
        struct SweepError: Error { let message: String }
        let spec = AnomalySweepSignal.spec { _ in
            throw SweepError(message: "estate handle unavailable during sweep")
        }
        let id = try await registerAndFire(
            kit, in: handle,
            spec: spec,
            cadence: AnomalySweepSignal.defaultCadenceSeconds)

        let r = try await report(kit, in: handle, for: id)
        #expect(r.name == "anomaly-flag-sweep")
        #expect(
            r.emissionCount == 1,
            "error path surfaces one diagnostic — drain loop must continue"
        )
        #expect(r.recentDiagnostics.first?.title == "anomaly-flag-sweep.error")
    }
}
