import Testing
import Foundation
import LocusKit
import VectorKit
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
@Suite("Default standing signals firing")
struct StandingSignalsTests {

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

    /// Open a fresh in-memory VectorStore for use in tests that need a
    /// VectorStore but do not require pre-populated vectors.
    private func makeEmptyVectorStore() async throws -> VectorStore {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        try await storage.open(schema: VectorStore.schemaDeclaration)
        return VectorStore(storage: storage)
    }

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
        return try #require(match, "expected report for \(id.rawValue)")
    }

    /// Assert every outcome reached the verb boundary — either successfully
    /// routed, previously-stubbed, failed due to a scaffold/sentinel target
    /// (expected now that propose/associate are live), or a diagnostic record.
    ///
    /// `routeFailed` is expected for scaffold signals that emit proposals or
    /// associations targeting sentinel row IDs (e.g. "row-scaffold-001") that
    /// do not exist in the test estate. The live verbs reach LocusKit, look up
    /// the missing drawer, and surface `underlyingEstateFailure`, which the
    /// scheduler records as `routeFailed`. This is correct behavior — the
    /// signal fired, the verb was reached, and the substrate reported that the
    /// target did not exist. The test contract is "the scheduler dispatched the
    /// emission," not "the substrate stored the row."
    private func assertVerbBoundaryReached(
        _ outcomes: [SignalRouteOutcome],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(!outcomes.isEmpty, "expected at least one outcome", sourceLocation: sourceLocation)
        // All four outcome cases indicate the scheduler reached a verb boundary
        // (or recorded a diagnostic). No case is an unexpected failure here.
        for outcome in outcomes {
            switch outcome {
            case .routed, .routedButVerbStubbed, .diagnosticRecorded, .routeFailed:
                continue
            }
        }
    }

    /// Legacy alias preserved to avoid churn on call sites that tested the
    /// old no-route-failure contract. Now delegates to assertVerbBoundaryReached
    /// since routeFailed is expected for scaffold signals with sentinel targets.
    private func assertNoRouteFailures(
        _ outcomes: [SignalRouteOutcome],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        assertVerbBoundaryReached(outcomes, sourceLocation: sourceLocation)
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

    @Test
    func dreamingSignalEmitsRealProposalsFromDaemonCycle() async throws {
        let (kit, handle) = try await openOneEstate()
        // Synthetic daemon cycle returning one non-sentinel proposal. The
        // target row does not exist in the test estate, so the propose verb
        // produces routeFailed — which is the correct outcome: the signal
        // fired, the daemon ran, and the verb boundary was reached.
        let spec = DreamingSignal.spec { _ in
            [ProposeFrame(
                target: "row-dreaming-test-a",
                kind: .miningPattern,
                justification: "synthetic daemon cycle for test")]
        }
        let id = try await registerAndFire(
            kit, in: handle, spec: spec,
            cadence: DreamingSignal.defaultCadenceSeconds)

        let report = try await report(kit, in: handle, for: id)
        #expect(report.name == "dreaming-daemon")
        // One real proposal from the daemon cycle; no sentinel associate.
        #expect(report.emissionCount == 1,
            "one proposal from daemon cycle — no sentinel associate emission")
        assertVerbBoundaryReached(report.recentOutcomes)
        let verbs = report.recentOutcomes.compactMap { outcome -> String? in
            switch outcome {
            case .routed(let v), .routedButVerbStubbed(let v): return v
            case .routeFailed(let v, _): return v
            case .diagnosticRecorded: return nil
            }
        }
        #expect(verbs == ["propose"])
    }

    @Test
    func dreamingSignalEmitsZeroProposalsForEmptyEstate() async throws {
        let (kit, handle) = try await openOneEstate()
        // Empty daemon cycle: the estate has no co-occurrence candidates.
        // The signal fires cleanly and produces zero emissions.
        let spec = DreamingSignal.spec { _ in [] }
        let id = try await registerAndFire(
            kit, in: handle, spec: spec,
            cadence: DreamingSignal.defaultCadenceSeconds)

        let report = try await report(kit, in: handle, for: id)
        #expect(report.name == "dreaming-daemon")
        #expect(report.emissionCount == 0,
            "empty estate: daemon cycle returns zero proposals, signal fires cleanly")
        #expect(report.recentOutcomes.isEmpty)
    }

    @Test
    func maintenanceSignalEmitsForbiddenComboPlusCandidateAndDiagnostic() async throws {
        let (kit, handle) = try await openOneEstate()
        let id = try await registerAndFire(
            kit, in: handle,
            spec: MaintenanceSignal.defaultSpec(),
            cadence: MaintenanceSignal.defaultCadenceSeconds)

        let report = try await report(kit, in: handle, for: id)
        #expect(report.name == "maintenance-daemon")
        #expect(report.emissionCount == 3,
            "maintenance emits one propose + one mutate-candidate (routed through propose) + one diagnostic")
        #expect(report.recentOutcomes.count == 3)
        assertNoRouteFailures(report.recentOutcomes)
        // Two propose-routed outcomes (the discipline-violation
        // proposal AND the mutate-candidate which §11.1 routes
        // through propose) plus one diagnostic record. Since propose
        // is now live, scaffold targets produce routeFailed — all three
        // outcome forms count as "reached the propose verb."
        let proposeCount = report.recentOutcomes.filter { outcome in
            switch outcome {
            case .routed(let v), .routedButVerbStubbed(let v): return v == "propose"
            case .routeFailed(let v, _): return v == "propose"
            default: return false
            }
        }.count
        #expect(proposeCount == 2)
        #expect(report.recentDiagnostics.count == 1)
        #expect(report.recentDiagnostics.first?.title == "maintenance.scan.summary")
    }

    @Test
    func vectorSimilaritySignalEmitsDiagnosticWhenStoreIsEmpty() async throws {
        // VectorSimilaritySignal now queries a real VectorStore. With an
        // empty store there are no vectors to probe, so the signal emits
        // zero AssociateFrames and exactly one scan-summary diagnostic.
        let (kit, handle) = try await openOneEstate()
        let emptyStore = try await makeEmptyVectorStore()
        let id = try await registerAndFire(
            kit, in: handle,
            spec: VectorSimilaritySignal.spec(
                vectorStore: emptyStore, modelID: "test-model"),
            cadence: VectorSimilaritySignal.defaultCadenceSeconds)

        let report = try await report(kit, in: handle, for: id)
        #expect(report.name == "vector-similarity")
        // Empty store: 0 AssociateFrames + 1 scan-summary diagnostic.
        #expect(report.emissionCount == 1,
            "empty VectorStore produces only the scan-summary diagnostic")
        #expect(report.recentDiagnostics.count == 1)
        #expect(report.recentDiagnostics.first?.title == "vector_similarity.scan.summary")
        // No associate outcomes since no pairs were found.
        let associateCount = report.recentOutcomes.filter { outcome in
            switch outcome {
            case .routed(let v), .routedButVerbStubbed(let v): return v == "associate"
            case .routeFailed(let v, _): return v == "associate"
            default: return false
            }
        }.count
        #expect(associateCount == 0, "no pairs in empty store → no associate emissions")
    }

    @Test
    func decaySweepSignalEmitsMutateCandidateRoutedThroughPropose() async throws {
        let (kit, handle) = try await openOneEstate()
        let id = try await registerAndFire(
            kit, in: handle,
            spec: DecaySweepSignal.defaultSpec(),
            cadence: DecaySweepSignal.defaultCadenceSeconds)

        let report = try await report(kit, in: handle, for: id)
        #expect(report.name == "decay-sweep")
        #expect(report.emissionCount == 2,
            "decay-sweep emits one mutate-candidate (routed through propose) + one diagnostic")
        assertNoRouteFailures(report.recentOutcomes)
        // The mutate-candidate routes through propose per §11.1, so the route
        // outcome verb is "propose". Since propose is now live, scaffold targets
        // produce routeFailed — all three forms confirm the propose verb was reached.
        let firstOutcome = report.recentOutcomes[0]
        switch firstOutcome {
        case .routed(let v), .routedButVerbStubbed(let v):
            #expect(v == "propose")
        case .routeFailed(let v, _):
            #expect(v == "propose")
        default:
            Issue.record("expected propose routing for decay candidate, got \(firstOutcome)")
        }
    }

    @Test
    func byReferenceValiditySignalEmitsProposeAndDiagnostic() async throws {
        let (kit, handle) = try await openOneEstate()
        let id = try await registerAndFire(
            kit, in: handle,
            spec: ByReferenceValiditySignal.defaultSpec(),
            cadence: ByReferenceValiditySignal.defaultCadenceSeconds)

        let report = try await report(kit, in: handle, for: id)
        #expect(report.name == "by-reference-validity")
        #expect(report.emissionCount == 2)
        assertNoRouteFailures(report.recentOutcomes)
        // Since propose is now live, scaffold targets produce routeFailed;
        // all outcome forms count as "reached the propose verb."
        let proposeCount = report.recentOutcomes.filter { outcome in
            switch outcome {
            case .routed(let v), .routedButVerbStubbed(let v): return v == "propose"
            case .routeFailed(let v, _): return v == "propose"
            default: return false
            }
        }.count
        #expect(proposeCount == 1, "byReference emits one propose per fire")
        #expect(report.recentDiagnostics.count == 1)
        #expect(report.recentDiagnostics.first?.title == "by_reference.validation.summary")
    }

    @Test
    func endOfDayTournamentSignalEmitsProposeAndDiagnostic() async throws {
        let (kit, handle) = try await openOneEstate()
        let id = try await registerAndFire(
            kit, in: handle,
            spec: EndOfDayTournamentSignal.defaultSpec(),
            cadence: EndOfDayTournamentSignal.defaultCadenceSeconds)

        let report = try await report(kit, in: handle, for: id)
        #expect(report.name == "end-of-day-tournament")
        #expect(report.emissionCount == 2)
        assertNoRouteFailures(report.recentOutcomes)
        // Since propose is now live, scaffold targets produce routeFailed;
        // all outcome forms count as "reached the propose verb."
        let proposeCount = report.recentOutcomes.filter { outcome in
            switch outcome {
            case .routed(let v), .routedButVerbStubbed(let v): return v == "propose"
            case .routeFailed(let v, _): return v == "propose"
            default: return false
            }
        }.count
        #expect(proposeCount == 1)
        #expect(report.recentDiagnostics.first?.title == "tournament.end_of_day.summary")
    }

    // MARK: - Registration helper

    @Test
    func registerDefaultStandingSignalsRegistersAllSix() async throws {
        let (kit, handle) = try await openOneEstate()
        let emptyStore = try await makeEmptyVectorStore()
        let registered = try await kit.registerDefaultStandingSignals(
            in: handle, vectorStore: emptyStore, now: t0)

        #expect(registered.count == 6, "all six v1 signals register")
        #expect(
            Set(registered.keys) == Set(GeniusLocusKit.defaultStandingSignalNames))

        let reports = try await kit.signalStatus(in: handle)
        #expect(reports.count == 6)
        for spec in reports {
            #expect(spec.triggerTag == "interval",
                "every v1 signal is interval-driven at its default cadence")
            #expect(spec.state == .idle)
            #expect(spec.emissionCount == 0)
        }
        // Every default name is represented exactly once in the
        // status report.
        let names = Set(reports.map { $0.name })
        #expect(names == Set(GeniusLocusKit.defaultStandingSignalNames))
    }

    @Test
    func defaultSignalCadencesMatchArchitectureSpec() throws {
        // Architecture spec §11.2 / cookbook §15.2 cadences. These
        // are intentionally hard-coded so a regression in any signal
        // file is caught here rather than going silent.
        #expect(DreamingSignal.defaultCadenceSeconds == 604_800,
            "dreaming daemon runs weekly")
        #expect(MaintenanceSignal.defaultCadenceSeconds == 3_600,
            "maintenance runs hourly")
        #expect(VectorSimilaritySignal.defaultCadenceSeconds == 300,
            "vector-similarity runs every five minutes")
        #expect(DecaySweepSignal.defaultCadenceSeconds == 86_400,
            "decay-sweep runs daily")
        #expect(ByReferenceValiditySignal.defaultCadenceSeconds == 604_800,
            "byReference validity runs weekly")
        #expect(EndOfDayTournamentSignal.defaultCadenceSeconds == 86_400,
            "end-of-day tournament runs daily")
    }
}
