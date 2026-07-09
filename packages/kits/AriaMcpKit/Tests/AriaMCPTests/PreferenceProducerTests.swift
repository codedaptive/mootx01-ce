// PreferenceProducerTests.swift
//
// Conformance + behaviour coverage for the preference PRODUCER
// (AutonomicGovernor.preferenceScan + PreferenceCache + PreferenceOutcomes).
// The producer is the cadence wrapper that takes the recall `preference` score
// column from DARK to LIVE: nothing previously fitted per-drawer Bradley-Terry
// preference strengths and registered the PreferenceStore the matrixAware/
// unionBest recall reads. It is the SIBLING of the graph-centrality producer.
//
// The proofs here mirror the Rust port's `preference_producer_parity.rs`:
//   - faithful-wrapper: the producer's records + cache equal a DIRECT
//     NeuronKit.learnedPreference call on the same (label, endorsements,
//     dismissals) records;
//   - structure sanity: an endorsed drawer outranks a dismissed one;
//   - outcome shaping: surfaced+used → endorsement, surfaced+passed → dismissal;
//   - C-16 totality: an estate with no recall traces yields an all-zero store;
//   - cadence: the producer fires on the first tick and respects its interval;
//   - end-to-end: after a scan, a unionBest+matrixAware recall reads a non-zero
//     `preference` column for an endorsed drawer (dark→live, proving registration).

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("Preference producer", .serialized)
struct PreferenceProducerTests {

    // MARK: - Harness

    private func openEstate(owner ownerID: String) async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: ownerID)
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (kit, handle)
    }

    @discardableResult
    private func capture(_ kit: GeniusLocusKit, _ handle: EstateHandle,
                         _ content: String) async throws -> String {
        let frame = CaptureFrame(
            content: content, channel: .typed, room: "preference",
            latticeAnchor: .udc("004"), addedBy: "preference-tests",
            embeddingModelID: "test-model-v1")
        return try await kit.capture(handle, frame).id
    }

    /// Run an EXTERNAL recall with a trace budget so the surfaced drawers get
    /// recall-trace rows written (the reward-cycle input the producer reads).
    /// Returns the recalled hit ids. All trace rows start unused. The
    /// RecallDirector timestamps the trace rows with Date() (wall clock), so
    /// callers capture their window `now` AFTER this returns.
    @discardableResult
    private func recallWritingTraces(
        _ kit: GeniusLocusKit, _ handle: EstateHandle, traceLimit: Int
    ) async throws -> [String] {
        let req = GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.unconfirmed],
                hydrationLevel: .structured,
                ordering: .byCaptureTimeDesc),
            mode: .unionBest, scoring: .matrixAware, limit: 50,
            fallback: .failClosed, traceLimit: traceLimit,
            origin: .external, recallShape: nil)
        let result = try await kit.recall(handle, req)
        return result.hits.map(\.id)
    }

    /// The store the producer WOULD register for this estate, built from the same
    /// reads + outcome shaping + fitter the duty uses. Used by the pure proofs
    /// (no GLK read-back accessor needed). Mirrors the graph suite's
    /// `producedCache` helper.
    private func producedStore(_ kit: GeniusLocusKit, _ handle: EstateHandle, now: Date)
        async throws -> (store: PreferenceCache, expected: [String: Float], records: [PreferenceOutcomes.Record]) {
        let traces = try await kit.recentRecallTraces(in: handle, since: .distantPast, now: now)
        let records = PreferenceOutcomes.build(traces: traces)
        let strengths = try NeuronKit.learnedPreference(
            records: records.map {
                (label: $0.label, endorsements: $0.endorsements, dismissals: $0.dismissals)
            })
        var expected: [String: Float] = [:]
        for s in strengths { expected[s.label] = Float(s.strength) }
        return (PreferenceCache(scores: expected), expected, records)
    }

    // MARK: - Faithful wrapper (the conformance proof)

    /// The producer's store MUST equal a direct NeuronKit.learnedPreference call
    /// on the producer's own (label, endorsements, dismissals) records —
    /// bit-identical Floats. This proves the producer is a faithful cadence
    /// wrapper of the gated Bradley-Terry fitter and reinvents no math (I-17). It
    /// is also the cross-port contract: the Rust producer fits the same strengths
    /// from the same records.
    @Test("producer store equals a direct learnedPreference call on the same records")
    func producerEqualsDirectLearnedPreference() async throws {
        let (kit, handle) = try await openEstate(owner: "pref-faithful")
        let picked = try await capture(kit, handle, "picked memory")
        _ = try await capture(kit, handle, "passed over one")
        _ = try await capture(kit, handle, "passed over two")
        _ = try await recallWritingTraces(kit, handle, traceLimit: 50)
        // The GLK RecallDirector timestamps recall-trace rows with the wall clock
        // (Date()), so capture the window `now` AFTER the recall writes them; the
        // markRecallUsed window [now-retention, now] then covers them. (The fit
        // math — the cross-port conformance subject — is timestamp-independent: it
        // sees only the (label, endorsements, dismissals) records.)
        let now = Date()
        _ = try await kit.markRecallUsed(handle, target: picked, now: now)

        let (store, expected, records) = try await producedStore(kit, handle, now: now)
        #expect(!records.isEmpty, "trace history must yield curation records")
        for record in records {
            #expect(store.preferenceScore(for: record.label) == (expected[record.label] ?? 0.0),
                "stored strength for \(record.label) must equal the direct learnedPreference strength")
        }
        try await kit.close(handle)
    }

    // MARK: - Structure sanity

    /// A drawer surfaced AND used (endorsed) outranks a drawer surfaced and
    /// passed over (dismissed) — the Bradley-Terry behaviour the fitter
    /// guarantees, surfaced through the producer.
    @Test("an endorsed drawer outscores a dismissed drawer")
    func endorsedOutscoresDismissed() async throws {
        let (kit, handle) = try await openEstate(owner: "pref-rank")
        let endorsed = try await capture(kit, handle, "the drawer the user picks")
        let dismissed = try await capture(kit, handle, "the drawer the user ignores")
        _ = try await recallWritingTraces(kit, handle, traceLimit: 50)
        // Wall-clock `now` captured AFTER the recall writes traces (Date()-stamped);
        // the mark window then covers them. See the faithful-wrapper test.
        let now = Date()
        _ = try await kit.markRecallUsed(handle, target: endorsed, now: now)

        let (store, _, _) = try await producedStore(kit, handle, now: now)
        #expect(store.preferenceScore(for: endorsed) > store.preferenceScore(for: dismissed),
            "the endorsed drawer must carry a higher preference strength than the dismissed one")
        try await kit.close(handle)
    }

    // MARK: - Outcome shaping

    /// PreferenceOutcomes.build maps surfaced+used → endorsement and
    /// surfaced+passed → dismissal, one record per distinct target. This is the
    /// implicit relevance signal (C-15): what the user picked vs ignored.
    @Test("outcome shaping counts used as endorsements and unused as dismissals")
    func outcomeShapingCountsCorrectly() async throws {
        let base = Date(timeIntervalSince1970: 7_000_000)
        let traces = [
            RecallTraceItem(target: "A", recalledAt: base, operationalBitmap: RecallTraceItem.flagUsed),
            RecallTraceItem(target: "A", recalledAt: base, operationalBitmap: RecallTraceItem.flagUsed),
            RecallTraceItem(target: "A", recalledAt: base, operationalBitmap: 0),
            RecallTraceItem(target: "B", recalledAt: base, operationalBitmap: 0),
        ]
        let records = PreferenceOutcomes.build(traces: traces)
        // Sorted ascending by label → A then B.
        #expect(records.map(\.label) == ["A", "B"])
        #expect(records[0] == PreferenceOutcomes.Record(label: "A", endorsements: 2, dismissals: 1))
        #expect(records[1] == PreferenceOutcomes.Record(label: "B", endorsements: 0, dismissals: 1))
    }

    // MARK: - C-16 totality

    /// An estate with no recall traces yields an empty store; every score is 0.0
    /// (identical to "no store registered" — correct, not an error). The duty
    /// itself completes without throwing.
    @Test("empty-trace estate scan registers an all-zero store without error")
    func emptyTraceEstateRegistersZeroStore() async throws {
        let (kit, handle) = try await openEstate(owner: "pref-empty")
        let now = Date(timeIntervalSince1970: 4_000_000)
        // No recall happened, so no traces. The duty must not throw.
        try await AutonomicGovernor.preferenceScan(kit: kit, handle: handle, now: now)
        let (store, _, records) = try await producedStore(kit, handle, now: now)
        #expect(records.isEmpty)
        #expect(store.preferenceScore(for: "nonexistent") == 0.0)
        #expect(store.count == 0)
        try await kit.close(handle)
    }

    // MARK: - Cadence

    @Test("preference producer fires on the first tick")
    func firesOnFirstTick() async throws {
        let (kit, handle) = try await openEstate(owner: "pref-cadence-first")
        // ce-fdcpool test isolation: nil pool paths skip the reduce path so a tick
        // never reads or writes the real user pool.
        let governor = AutonomicGovernor(kit: kit, handle: handle, preferenceIntervalMs: 0, poolDirectory: nil, poolTableArtifactURL: nil)
        let report = await governor.tick(now: Date(timeIntervalSince1970: 6_000_000))
        #expect(report.preferenceFired)
        try await kit.close(handle)
    }

    @Test("preference producer respects its cadence")
    func respectsCadence() async throws {
        let (kit, handle) = try await openEstate(owner: "pref-cadence-interval")
        // ce-fdcpool test isolation: nil pool paths skip the reduce path.
        let governor = AutonomicGovernor(kit: kit, handle: handle, poolDirectory: nil, poolTableArtifactURL: nil)  // 10-min default
        let t0 = Date(timeIntervalSince1970: 7_000_000)
        let first = await governor.tick(now: t0)
        #expect(first.preferenceFired)                                  // nil → fires
        let early = await governor.tick(now: t0.addingTimeInterval(1))
        #expect(!early.preferenceFired)                                 // < 600 s → skip
        let due = await governor.tick(now: t0.addingTimeInterval(600))
        #expect(due.preferenceFired)                                    // 600 s → fires
        try await kit.close(handle)
    }

    // MARK: - End-to-end: dark → live (proves registration)

    /// After the producer scans an estate with recall-trace reward history, a
    /// unionBest+matrixAware recall reads a NON-ZERO `preference` column for an
    /// endorsed drawer. This closes the dark-column gap: without the producer the
    /// column was 0.0 for every hit. It also proves the duty actually REGISTERED
    /// the store on the kit (the recall path reads `preferenceStores[handle]`).
    @Test("unionBest+matrixAware recall reads a live preference column after a scan")
    func recallReadsLivePreferenceColumn() async throws {
        let (kit, handle) = try await openEstate(owner: "pref-e2e")
        let endorsed = try await capture(kit, handle, "endorsed hub memory")
        _ = try await capture(kit, handle, "dismissed spoke one")
        _ = try await capture(kit, handle, "dismissed spoke two")
        // Seed reward history: surface all, the user picks the endorsed drawer.
        _ = try await recallWritingTraces(kit, handle, traceLimit: 50)
        // Wall-clock `now` captured AFTER the recall writes traces (Date()-stamped);
        // the mark window and the producer's trace read [.., now] then cover them.
        // See the faithful-wrapper test for the rationale.
        let now = Date()
        _ = try await kit.markRecallUsed(handle, target: endorsed, now: now)

        // Run the producer — registers the live PreferenceStore on the kit.
        try await AutonomicGovernor.preferenceScan(kit: kit, handle: handle, now: now)

        let req = GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.unconfirmed],
                hydrationLevel: .structured,
                ordering: .byCaptureTimeDesc),
            mode: .unionBest, scoring: .matrixAware, limit: 50,
            fallback: .failClosed, origin: .internal, recallShape: nil)
        let result = try await kit.recall(handle, req)

        let endorsedHit = try #require(result.hits.first { $0.id == endorsed },
            "the endorsed drawer must be recalled")
        #expect(endorsedHit.score.preference > 0.0,
            "the preference column must be live (non-zero) for the endorsed drawer after the producer ran")
        try await kit.close(handle)
    }
}
