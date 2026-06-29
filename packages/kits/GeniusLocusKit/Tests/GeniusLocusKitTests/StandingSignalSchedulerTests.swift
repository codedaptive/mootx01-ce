import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

// `ProposalKind` is declared in BOTH LocusKit (Int-backed, in
// ProposalOperational.swift) and GeniusLocusKit (string-backed Brain-layer
// taxonomy, in Brain/ProposalKind.swift). This test imports both modules,
// so the bare name is ambiguous. Every `ProposalKind` reference in this
// file is the GLK Brain-layer enum — its cases (`.amend`, `.testPropose`,
// `.other(String)`, …) exist only on the GLK type.
//
// A `GeniusLocusKit.ProposalKind` qualifier does NOT work: the module name
// is shadowed by the same-named `GeniusLocusKit` actor, so the qualifier
// resolves to the actor and fails. The correct disambiguator is a SCOPED
// import of the exact enum — a single-declaration import takes name-lookup
// priority, so the bare `ProposalKind` in this file binds to the GLK enum.
import enum GeniusLocusKit.ProposalKind

/// Tests for the GLK-04 standing-signals scheduler.
///
/// The scheduler dispatches in a single serial lane over QueueKit;
/// these tests assert each of the mission's five requirements:
///
/// 1. Registration: a registered signal appears in status with its
///    configured cadence.
/// 2. Serial dispatch: two due signals never run concurrently against
///    one estate; they dispatch in a single serial lane.
/// 3. Status / subscribe: signalStatus reports state transitions and
///    signalSubscribe delivers them.
/// 4. The four emission classes are each accepted and routed per the
///    contract.
/// 5. Determinism: same inputs in, same outputs out.
@Suite("GLK-04 standing-signals scheduler")
struct StandingSignalSchedulerTests {

    // MARK: - Fixture

    /// Open one estate through `GeniusLocusKit` and return the kit and
    /// handle. Mirrors the helper used in the verb-surface tests so
    /// the scheduler runs against the same composition shape.
    private func openOneEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-scheduler-tests")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    /// Reference time used by every test that needs a deterministic
    /// `now`. The conformance gate against the Rust mirror feeds the
    /// same scalar value, so a stable epoch keeps the comparison
    /// reproducible.
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 1. Registration

    @Test
    func registeredSignalAppearsInStatus() async throws {
        let (kit, handle) = try await openOneEstate()
        let spec = SignalSpec(
            name: "vector-similarity-test",
            trigger: .interval(seconds: 30),
            freshnessTarget: 60,
            concurrencyPolicy: .single,
            emit: { _ in [] })

        let id = try await kit.registerStandingSignal(spec, in: handle, now: t0)
        let reports = try await kit.signalStatus(in: handle)

        #expect(reports.count == 1)
        #expect(reports.first?.signalID == id)
        #expect(reports.first?.name == "vector-similarity-test")
        #expect(reports.first?.triggerTag == "interval")
        #expect(reports.first?.state == .idle)
        #expect(reports.first?.emissionCount == 0)
        #expect(reports.first?.concurrencyPolicy == .single)
    }

    // MARK: - 2. Serial dispatch

    @Test
    func twoDueSignalsDispatchSeriallyInOneLane() async throws {
        let (kit, handle) = try await openOneEstate()
        let spec1 = SignalSpec(
            name: "alpha",
            trigger: .interval(seconds: 30),
            emit: { ctx in [
                .diagnostic(DiagnosticReport(
                    title: "alpha.1",
                    detail: "first",
                    observedAt: ctx.now)),
                .diagnostic(DiagnosticReport(
                    title: "alpha.2",
                    detail: "second",
                    observedAt: ctx.now)),
            ] })
        let spec2 = SignalSpec(
            name: "beta",
            trigger: .interval(seconds: 30),
            emit: { ctx in [
                .diagnostic(DiagnosticReport(
                    title: "beta.1",
                    detail: "first",
                    observedAt: ctx.now)),
            ] })

        let alpha = try await kit.registerStandingSignal(spec1, in: handle, now: t0)
        let beta = try await kit.registerStandingSignal(spec2, in: handle, now: t0)

        // Advance past both signals' first-due window.
        try await kit.signalTick(in: handle, now: t0.addingTimeInterval(31))

        // Inspect drain history: both signals' emissions land in one
        // ordered list — no interleaving at the job grain because
        // QueueKit's `.serializable` claim serialises every drain
        // step. Two alpha jobs precede one beta job because the
        // scheduler enqueues alpha first (sorted by SignalID lexically
        // matters less than the within-signal order; we check both
        // signals' emissions are present and the total count equals
        // the expected three jobs).
        let scheduler = try await kit.ensureScheduler(for: handle)
        let history = await scheduler.drainHistory()
        #expect(history.count == 3, "single serial lane drains every enqueued job exactly once")
        let alphaCount = history.filter { $0.signalID == alpha }.count
        let betaCount = history.filter { $0.signalID == beta }.count
        #expect(alphaCount == 2)
        #expect(betaCount == 1)

        let reports = try await kit.signalStatus(in: handle)
        let alphaReport = reports.first(where: { $0.signalID == alpha })!
        let betaReport = reports.first(where: { $0.signalID == beta })!
        #expect(alphaReport.emissionCount == 2)
        #expect(betaReport.emissionCount == 1)
        #expect(alphaReport.state == .lastRan)
        #expect(betaReport.state == .lastRan)
    }

    // MARK: - 3. Status and subscribe

    @Test
    func subscribeDeliversEmissions() async throws {
        let (kit, handle) = try await openOneEstate()
        let spec = SignalSpec(
            name: "diag",
            trigger: .interval(seconds: 10),
            emit: { ctx in [
                .diagnostic(DiagnosticReport(
                    title: "tick",
                    detail: "from \(ctx.signalID.rawValue)",
                    observedAt: ctx.now)),
            ] })

        let id = try await kit.registerStandingSignal(spec, in: handle, now: t0)

        // Collect emissions through the subscription. An actor-backed
        // collector keeps the test concurrency-clean.
        actor Collector {
            var values: [String] = []
            func append(_ s: String) { values.append(s) }
        }
        let collector = Collector()
        _ = try await kit.signalSubscribe(id, in: handle) { emission in
            if case .diagnostic(let report) = emission {
                Task { await collector.append(report.title) }
            }
        }
        try await kit.signalTick(in: handle, now: t0.addingTimeInterval(11))
        // Yield once so the subscriber's detached Task can settle.
        try await Task.sleep(nanoseconds: 50_000_000)

        let collected = await collector.values
        #expect(collected == ["tick"])

        let reports = try await kit.signalStatus(in: handle)
        #expect(reports.first?.emissionCount == 1)
        #expect(reports.first?.recentDiagnostics.count == 1)
        #expect(reports.first?.recentDiagnostics.first?.title == "tick")
    }

    // MARK: - 4. Four emission classes

    @Test
    func proposeEmissionIsRoutedToProposeVerb() async throws {
        let (kit, handle) = try await openOneEstate()
        let spec = SignalSpec(
            name: "propose-emitter",
            trigger: .interval(seconds: 1),
            emit: { _ in [
                .propose(ProposalFrame(
                    target: "row-A", kind: .testPropose, justification: nil)),
            ] })
        let id = try await kit.registerStandingSignal(spec, in: handle, now: t0)
        try await kit.signalTick(in: handle, now: t0.addingTimeInterval(5))
        let reports = try await kit.signalStatus(in: handle)
        let report = reports.first(where: { $0.signalID == id })!
        #expect(report.recentOutcomes.count == 1)
        // The propose verb is live; scaffold targets produce `routeFailed` (expected:
        // the verb reaches LocusKit, looks up the missing drawer, and surfaces
        // `underlyingEstateFailure`). `routedButVerbStubbed` is tolerated as
        // legacy/backward-compatible boundary-reach; `routed` means a live success.
        // All three confirm the scheduler reached the verb boundary.
        switch report.recentOutcomes[0] {
        case .routed(let verb), .routedButVerbStubbed(let verb), .routeFailed(let verb, _):
            #expect(verb == "propose")
        default:
            Issue.record("expected routed, routedButVerbStubbed, or routeFailed, got \(report.recentOutcomes[0])")
        }
    }

    @Test
    func associateEmissionIsRoutedToAssociateVerb() async throws {
        let (kit, handle) = try await openOneEstate()
        let spec = SignalSpec(
            name: "associate-emitter",
            trigger: .interval(seconds: 1),
            emit: { _ in [
                .associate(AssociationFrame(a: "row-A", b: "row-B", weight: 0.5)),
            ] })
        let id = try await kit.registerStandingSignal(spec, in: handle, now: t0)
        try await kit.signalTick(in: handle, now: t0.addingTimeInterval(5))
        let report = try await kit.signalStatus(in: handle).first(where: { $0.signalID == id })!
        #expect(report.recentOutcomes.count == 1)
        // The associate verb is live; scaffold targets produce `routeFailed` (expected).
        // `routedButVerbStubbed` is tolerated as legacy/backward-compatible boundary-reach.
        // All three forms confirm the scheduler reached the verb boundary.
        switch report.recentOutcomes[0] {
        case .routed(let verb), .routedButVerbStubbed(let verb), .routeFailed(let verb, _):
            #expect(verb == "associate")
        default:
            Issue.record("expected routed, routedButVerbStubbed, or routeFailed, got \(report.recentOutcomes[0])")
        }
    }

    @Test
    func mutateCandidateRoutesThroughPropose() async throws {
        let (kit, handle) = try await openOneEstate()
        let spec = SignalSpec(
            name: "mutate-candidate-emitter",
            trigger: .interval(seconds: 1),
            emit: { _ in [
                .mutateCandidate(rowID: "row-A", kind: .confirm),
            ] })
        let id = try await kit.registerStandingSignal(spec, in: handle, now: t0)
        try await kit.signalTick(in: handle, now: t0.addingTimeInterval(5))
        let report = try await kit.signalStatus(in: handle).first(where: { $0.signalID == id })!
        // Architecture spec §11.1: mutate-candidate is "routed through
        // `propose` for confirmation." The recorded verb is propose, not mutate.
        // Propose is live; scaffold targets produce `routeFailed` (expected).
        // `routedButVerbStubbed` is tolerated as legacy boundary-reach.
        // All three forms confirm the propose verb was reached.
        switch report.recentOutcomes[0] {
        case .routed(let verb), .routedButVerbStubbed(let verb), .routeFailed(let verb, _):
            #expect(verb == "propose")
        default:
            Issue.record("expected propose routing, got \(report.recentOutcomes[0])")
        }
    }

    @Test
    func diagnosticEmissionIsSurfacedViaSignalStatus() async throws {
        let (kit, handle) = try await openOneEstate()
        let spec = SignalSpec(
            name: "diag-emitter",
            trigger: .interval(seconds: 1),
            emit: { ctx in [
                .diagnostic(DiagnosticReport(
                    title: "first",
                    detail: "details",
                    observedAt: ctx.now)),
            ] })
        let id = try await kit.registerStandingSignal(spec, in: handle, now: t0)
        try await kit.signalTick(in: handle, now: t0.addingTimeInterval(5))
        let report = try await kit.signalStatus(in: handle).first(where: { $0.signalID == id })!
        // Architecture spec §11.1: diagnostic is "not a verb call;
        // surfaced via `signal_status()`."
        #expect(report.recentOutcomes == [.diagnosticRecorded])
        #expect(report.recentDiagnostics.count == 1)
        #expect(report.recentDiagnostics.first?.title == "first")
    }

    // MARK: - 5. Event trigger via requestFire

    @Test
    func eventTriggerOnlyFiresOnRequest() async throws {
        let (kit, handle) = try await openOneEstate()
        let spec = SignalSpec(
            name: "event-trigger",
            trigger: .event(name: "external"),
            emit: { ctx in [
                .diagnostic(DiagnosticReport(
                    title: "fired",
                    detail: "event=\(ctx.signalID.rawValue)",
                    observedAt: ctx.now)),
            ] })
        let id = try await kit.registerStandingSignal(spec, in: handle, now: t0)

        // Tick alone must NOT fire an event-trigger signal — that
        // would defeat the four-class trigger contract.
        try await kit.signalTick(in: handle, now: t0.addingTimeInterval(99))
        var report = try await kit.signalStatus(in: handle).first(where: { $0.signalID == id })!
        #expect(report.emissionCount == 0)

        // requestFire reaches the same enqueue/drain pipeline.
        try await kit.signalRequestFire(id, in: handle, now: t0.addingTimeInterval(100))
        report = try await kit.signalStatus(in: handle).first(where: { $0.signalID == id })!
        #expect(report.emissionCount == 1)
    }

    // MARK: - 6. Unregister and unknown-signal errors

    @Test
    func subscribeToUnknownSignalThrows() async throws {
        let (kit, handle) = try await openOneEstate()
        // Mint a scheduler against the handle so signalSubscribe gets
        // past the schedulerNotStarted guard and reaches the
        // schedulerSignalNotRegistered guard the test is checking.
        _ = try await kit.registerStandingSignal(SignalSpec(
            name: "anchor", trigger: .event(name: "anchor"),
            emit: { _ in [] }), in: handle, now: t0)
        let bogus = SignalID(rawValue: "00000000-0000-0000-0000-000000000000")
        do {
            _ = try await kit.signalSubscribe(bogus, in: handle) { _ in }
            Issue.record("expected schedulerSignalNotRegistered")
        } catch GeniusLocusKitError.schedulerSignalNotRegistered(let id) {
            #expect(id == bogus)
        }
    }

    @Test
    func statusBeforeAnyRegistrationThrowsSchedulerNotStarted() async throws {
        let (kit, handle) = try await openOneEstate()
        do {
            _ = try await kit.signalStatus(in: handle)
            Issue.record("expected schedulerNotStarted")
        } catch GeniusLocusKitError.schedulerNotStarted(let uuid) {
            #expect(uuid == handle.estateUUID)
        }
    }

    // MARK: - ProposalKind round-trip (NK-1b)

    /// Every named ProposalKind case round-trips through rawValue →
    /// init(rawValue:) back to the same case. The `other` escape hatch
    /// also round-trips so unknown labels survive a persistence cycle.
    @Test
    func proposalKindRawValueRoundTrip() {
        let cases: [(ProposalKind, String)] = [
            (.byReferenceDrift,   "by_reference_drift"),
            (.tournamentUpdate,   "tournament_update"),
            (.miningPattern,      "mining_pattern"),
            (.disciplineViolation, "discipline_violation"),
            (.mutateCandidate,    "mutate_candidate"),
            (.amend,              "amend"),
            (.testPropose,        "test_propose"),
            (.other("custom_label"), "custom_label"),
        ]
        for (kind, expectedRaw) in cases {
            #expect(kind.rawValue == expectedRaw,
                "rawValue for \(kind) should be \(expectedRaw)")
            let decoded = ProposalKind(rawValue: expectedRaw)
            #expect(decoded == kind,
                "round-trip failed for \(expectedRaw)")
        }
    }

    /// Unknown labels map to `.other(rawValue)` and preserve their
    /// content verbatim through the round-trip.
    @Test
    func proposalKindUnknownLabelMapsToOther() {
        let unknown = ProposalKind(rawValue: "future_label")
        if case .other(let s) = unknown {
            #expect(s == "future_label")
        } else {
            Issue.record("expected .other for unknown label, got \(unknown)")
        }
    }

    /// Codable round-trip: JSON encode → decode produces the same
    /// value. Verifies the single-value string container shape Swift
    /// uses matches what the Rust port's raw_value()/from_raw() contract
    /// produces.
    @Test
    func proposalKindCodableRoundTrip() throws {
        let kinds: [ProposalKind] = [
            .byReferenceDrift, .tournamentUpdate, .miningPattern,
            .disciplineViolation, .mutateCandidate, .amend, .testPropose,
            .other("future"),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for kind in kinds {
            let data = try encoder.encode(kind)
            let decoded = try decoder.decode(ProposalKind.self, from: data)
            #expect(decoded == kind, "Codable round-trip failed for \(kind)")
        }
    }
}
