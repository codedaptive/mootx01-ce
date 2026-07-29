import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

/// Firing tests for DistillationSignal — architecture spec §11.2, signal 8.
///
/// Verifies cadence, concurrency policy, and diagnostic emission for both
/// the `defaultSpec()` no-op variant and the `spec(distillationCycle:)`
/// live-closure variant.
@Suite("DistillationSignal firing and diagnostic tests (dg2)")
struct DistillationSignalTests {

    // MARK: - Fixture

    private func openOneEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-distillation-tests")
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

    @Test
    func defaultSpecReturnsCorrectSignalName() throws {
        let spec = DistillationSignal.defaultSpec()
        #expect(spec.name == "distillation-sweep")
    }

    @Test
    func defaultSpecCadenceIsThreeSixHundredSeconds() throws {
        #expect(DistillationSignal.defaultCadenceSeconds == 3_600,
            "distillation sweep runs hourly per architecture spec §11.2")
        let spec = DistillationSignal.defaultSpec()
        guard case .interval(let seconds) = spec.trigger else {
            Issue.record("defaultSpec must use an interval trigger")
            return
        }
        #expect(seconds == 3_600.0,
            "defaultSpec trigger cadence must match defaultCadenceSeconds")
    }

    @Test
    func defaultSpecConcurrencyIsSingle() throws {
        let spec = DistillationSignal.defaultSpec()
        #expect(spec.concurrencyPolicy == .single,
            "distillation sweep is .single — only one sweep runs at a time")
    }

    // MARK: - Firing tests

    @Test
    func defaultSpecFiresEmitsExactlyOneDiagnostic() async throws {
        let (kit, handle) = try await openOneEstate()
        let id = try await registerAndFire(
            kit, in: handle,
            spec: DistillationSignal.defaultSpec(),
            cadence: DistillationSignal.defaultCadenceSeconds)

        let report = try await report(kit, in: handle, for: id)
        #expect(report.name == "distillation-sweep")
        #expect(report.emissionCount == 1,
            "defaultSpec fires exactly one diagnostic on fire")
        #expect(report.recentDiagnostics.count == 1)
        #expect(report.recentDiagnostics.first?.title == "distillation-sweep.fired")
    }

    @Test
    func specWithClosureReturningThreeEmitsCompleteWithItemCount() async throws {
        let (kit, handle) = try await openOneEstate()
        // Closure reports 3 items distilled — verifies diagnostic detail contains count.
        let spec = DistillationSignal.spec { _ in 3 }
        let id = try await registerAndFire(
            kit, in: handle,
            spec: spec,
            cadence: DistillationSignal.defaultCadenceSeconds)

        let report = try await report(kit, in: handle, for: id)
        #expect(report.name == "distillation-sweep")
        #expect(report.emissionCount == 1)
        #expect(report.recentDiagnostics.count == 1)
        #expect(report.recentDiagnostics.first?.title == "distillation-sweep.complete")
        let detail = report.recentDiagnostics.first?.detail ?? ""
        #expect(detail.contains("3 item(s)"),
            "diagnostic detail must contain the items-distilled count; got: \(detail)")
    }

    @Test
    func specWithThrowingClosureEmitsErrorDiagnostic() async throws {
        let (kit, handle) = try await openOneEstate()
        struct SweepError: Error { let message: String }
        let spec = DistillationSignal.spec { _ in
            throw SweepError(message: "cluster store unavailable")
        }
        let id = try await registerAndFire(
            kit, in: handle,
            spec: spec,
            cadence: DistillationSignal.defaultCadenceSeconds)

        let report = try await report(kit, in: handle, for: id)
        #expect(report.name == "distillation-sweep")
        #expect(report.emissionCount == 1,
            "error path surfaces one diagnostic — drain loop must continue")
        #expect(report.recentDiagnostics.first?.title == "distillation-sweep.error")
    }
}
