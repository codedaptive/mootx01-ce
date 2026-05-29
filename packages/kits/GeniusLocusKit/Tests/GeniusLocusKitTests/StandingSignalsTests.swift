import XCTest
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

/// Firing tests for the six default standing signals — architecture
/// spec §11.2 / mission GLK-05.
///
/// Every test follows the same template:
///
/// 1. Open one estate through the composed `GeniusLocusKit` surface.
/// 2. Register the signal's `defaultSpec()` at deterministic time `t0`.
/// 3. Tick the scheduler past the signal's default cadence.
/// 4. Inspect the resulting `SignalReport` and assert the emission
///    classes, the verb routing, and the mutation-free contract.
///
/// No test mutates the substrate directly; every assertion is against
/// the scheduler's outcome log and the diagnostics surface. This is
/// the mission's hardest invariant: signals emit proposals, never
/// state.
final class StandingSignalsTests: XCTestCase {

    // MARK: - Fixture

    /// Open one estate through `GeniusLocusKit` and return the kit
    /// and handle. Mirrors the helper in `StandingSignalSchedulerTests`
    /// so the firing fixtures use the same composition shape as the
    /// scheduler's own tests.
    private func openOneEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-signals-tests")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    /// Reference time used by every firing test. The conformance gate
    /// feeds the same scalar to the Rust mirror so the comparison is
    /// reproducible.
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// Tick a hair past `cadence + t0` so the signal's interval
    /// trigger is unambiguously due on the very first tick.
    private func firstFireTime(after cadence: TimeInterval) -> Date {
        t0.addingTimeInterval(cadence + 1)
    }

    /// Look up the report for `signalID` and fail the test if it is
    /// absent. Tests use this to keep the inner assertions tight.
    private func report(
        _ kit: GeniusLocusKit, in handle: EstateHandle, for id: SignalID
    ) async throws -> SignalReport {
        let reports = try await kit.signalStatus(in: handle)
        let match = reports.first(where: { $0.signalID == id })
        return try XCTUnwrap(match, "expected report for \(id.rawValue)")
    }

    /// Assert every outcome is a propose/associate routing (the
    /// substrate may stub it; both forms satisfy the contract) or
    /// a diagnostic record. `routeFailed` is never expected from a
    /// firing test.
    private func assertNoRouteFailures(
        _ outcomes: [SignalRouteOutcome],
        file: StaticString = #file, line: UInt = #line
    ) {
        for outcome in outcomes {
            switch outcome {
            case .routed, .routedButVerbStubbed, .diagnosticRecorded:
                continue
            case .routeFailed(let verb, let reason):
                XCTFail(
                    "unexpected route failure on verb=\(verb) reason=\(reason)",
                    file: file, line: line)
            }
        }
    }

    /// Helper: register a single signal and tick past its cadence.
    private func registerAndFire(
        _ kit: GeniusLocusKit, in handle: EstateHandle,
        spec: SignalSpec, cadence: TimeInterval
    ) async throws -> SignalID {
        let id = try await kit.registerStandingSignal(spec, in: handle, now: t0)
        try await kit.signalTick(in: handle, now: firstFireTime(after: cadence))
        return id
    }

    // MARK: - Per-signal firing tests

    func testDreamingSignalEmitsProposeAndAssociate() async throws {
        let (kit, handle) = try await openOneEstate()
        let id = try await registerAndFire(
            kit, in: handle,
            spec: DreamingSignal.defaultSpec(),
            cadence: DreamingSignal.defaultCadenceSeconds)

        let report = try await report(kit, in: handle, for: id)
        XCTAssertEqual(report.name, "dreaming-daemon")
        XCTAssertEqual(report.emissionCount, 2,
            "dreaming daemon emits one propose + one associate per fire")
        // Two emissions, one routed through propose and one through
        // associate. The order matches the spec's emission list.
        XCTAssertEqual(report.recentOutcomes.count, 2)
        assertNoRouteFailures(report.recentOutcomes)
        let verbs = report.recentOutcomes.compactMap { outcome -> String? in
            switch outcome {
            case .routed(let v), .routedButVerbStubbed(let v): return v
            case .diagnosticRecorded, .routeFailed: return nil
            }
        }
        XCTAssertEqual(verbs.sorted(), ["associate", "propose"])
    }

    func testMaintenanceSignalEmitsForbiddenComboPlusCandidateAndDiagnostic() async throws {
        let (kit, handle) = try await openOneEstate()
        let id = try await registerAndFire(
            kit, in: handle,
            spec: MaintenanceSignal.defaultSpec(),
            cadence: MaintenanceSignal.defaultCadenceSeconds)

        let report = try await report(kit, in: handle, for: id)
        XCTAssertEqual(report.name, "maintenance-daemon")
        XCTAssertEqual(report.emissionCount, 3,
            "maintenance emits one propose + one mutate-candidate (routed through propose) + one diagnostic")
        XCTAssertEqual(report.recentOutcomes.count, 3)
        assertNoRouteFailures(report.recentOutcomes)
        // Two propose-routed outcomes (the discipline-violation
        // proposal AND the mutate-candidate which §11.1 routes
        // through propose) plus one diagnostic record.
        let proposeCount = report.recentOutcomes.filter { outcome in
            switch outcome {
            case .routed(let v), .routedButVerbStubbed(let v): return v == "propose"
            default: return false
            }
        }.count
        XCTAssertEqual(proposeCount, 2)
        XCTAssertEqual(report.recentDiagnostics.count, 1)
        XCTAssertEqual(report.recentDiagnostics.first?.title, "maintenance.scan.summary")
    }

    func testVectorSimilaritySignalEmitsAssociateAndDiagnostic() async throws {
        let (kit, handle) = try await openOneEstate()
        let id = try await registerAndFire(
            kit, in: handle,
            spec: VectorSimilaritySignal.defaultSpec(),
            cadence: VectorSimilaritySignal.defaultCadenceSeconds)

        let report = try await report(kit, in: handle, for: id)
        XCTAssertEqual(report.name, "vector-similarity")
        XCTAssertEqual(report.emissionCount, 2)
        assertNoRouteFailures(report.recentOutcomes)
        let associateCount = report.recentOutcomes.filter { outcome in
            switch outcome {
            case .routed(let v), .routedButVerbStubbed(let v): return v == "associate"
            default: return false
            }
        }.count
        XCTAssertEqual(associateCount, 1, "vector-similarity emits one associate per fire")
        XCTAssertEqual(report.recentDiagnostics.count, 1)
    }

    func testDecaySweepSignalEmitsMutateCandidateRoutedThroughPropose() async throws {
        let (kit, handle) = try await openOneEstate()
        let id = try await registerAndFire(
            kit, in: handle,
            spec: DecaySweepSignal.defaultSpec(),
            cadence: DecaySweepSignal.defaultCadenceSeconds)

        let report = try await report(kit, in: handle, for: id)
        XCTAssertEqual(report.name, "decay-sweep")
        XCTAssertEqual(report.emissionCount, 2,
            "decay-sweep emits one mutate-candidate (routed through propose) + one diagnostic")
        assertNoRouteFailures(report.recentOutcomes)
        // The mutate-candidate routes through propose per §11.1, so
        // the route outcome is verb=propose.
        let firstOutcome = report.recentOutcomes[0]
        switch firstOutcome {
        case .routed(let v), .routedButVerbStubbed(let v):
            XCTAssertEqual(v, "propose")
        default:
            XCTFail("expected propose routing for decay candidate, got \(firstOutcome)")
        }
    }

    func testByReferenceValiditySignalEmitsProposeAndDiagnostic() async throws {
        let (kit, handle) = try await openOneEstate()
        let id = try await registerAndFire(
            kit, in: handle,
            spec: ByReferenceValiditySignal.defaultSpec(),
            cadence: ByReferenceValiditySignal.defaultCadenceSeconds)

        let report = try await report(kit, in: handle, for: id)
        XCTAssertEqual(report.name, "by-reference-validity")
        XCTAssertEqual(report.emissionCount, 2)
        assertNoRouteFailures(report.recentOutcomes)
        let proposeCount = report.recentOutcomes.filter { outcome in
            switch outcome {
            case .routed(let v), .routedButVerbStubbed(let v): return v == "propose"
            default: return false
            }
        }.count
        XCTAssertEqual(proposeCount, 1, "byReference emits one propose per fire")
        XCTAssertEqual(report.recentDiagnostics.count, 1)
        XCTAssertEqual(report.recentDiagnostics.first?.title, "by_reference.validation.summary")
    }

    func testEndOfDayTournamentSignalEmitsProposeAndDiagnostic() async throws {
        let (kit, handle) = try await openOneEstate()
        let id = try await registerAndFire(
            kit, in: handle,
            spec: EndOfDayTournamentSignal.defaultSpec(),
            cadence: EndOfDayTournamentSignal.defaultCadenceSeconds)

        let report = try await report(kit, in: handle, for: id)
        XCTAssertEqual(report.name, "end-of-day-tournament")
        XCTAssertEqual(report.emissionCount, 2)
        assertNoRouteFailures(report.recentOutcomes)
        let proposeCount = report.recentOutcomes.filter { outcome in
            switch outcome {
            case .routed(let v), .routedButVerbStubbed(let v): return v == "propose"
            default: return false
            }
        }.count
        XCTAssertEqual(proposeCount, 1)
        XCTAssertEqual(report.recentDiagnostics.first?.title, "tournament.end_of_day.summary")
    }

    // MARK: - Registration helper

    func testRegisterDefaultStandingSignalsRegistersAllSix() async throws {
        let (kit, handle) = try await openOneEstate()
        let registered = try await kit.registerDefaultStandingSignals(
            in: handle, now: t0)

        XCTAssertEqual(registered.count, 6, "all six v1 signals register")
        XCTAssertEqual(
            Set(registered.keys),
            Set(GeniusLocusKit.defaultStandingSignalNames))

        let reports = try await kit.signalStatus(in: handle)
        XCTAssertEqual(reports.count, 6)
        for spec in reports {
            XCTAssertEqual(spec.triggerTag, "interval",
                "every v1 signal is interval-driven at its default cadence")
            XCTAssertEqual(spec.state, .idle)
            XCTAssertEqual(spec.emissionCount, 0)
        }
        // Every default name is represented exactly once in the
        // status report.
        let names = Set(reports.map { $0.name })
        XCTAssertEqual(names, Set(GeniusLocusKit.defaultStandingSignalNames))
    }

    func testDefaultSignalCadencesMatchArchitectureSpec() throws {
        // Architecture spec §11.2 / cookbook §15.2 cadences. These
        // are intentionally hard-coded so a regression in any signal
        // file is caught here rather than going silent.
        XCTAssertEqual(DreamingSignal.defaultCadenceSeconds, 604_800,
            "dreaming daemon runs weekly")
        XCTAssertEqual(MaintenanceSignal.defaultCadenceSeconds, 3_600,
            "maintenance runs hourly")
        XCTAssertEqual(VectorSimilaritySignal.defaultCadenceSeconds, 300,
            "vector-similarity runs every five minutes")
        XCTAssertEqual(DecaySweepSignal.defaultCadenceSeconds, 86_400,
            "decay-sweep runs daily")
        XCTAssertEqual(ByReferenceValiditySignal.defaultCadenceSeconds, 604_800,
            "byReference validity runs weekly")
        XCTAssertEqual(EndOfDayTournamentSignal.defaultCadenceSeconds, 86_400,
            "end-of-day tournament runs daily")
    }
}
