// SubjectBackfillCycleTests.swift
//
// PR-09 verification for the subject-backfill rider seam. Everything
// pinned here is DETERMINISTIC — eligibility, ordering, batch bounds,
// validation, versioning, settled-skip, rider gating. Producer output
// text is never pinned (the stub is a test fixture, not a model claim).

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

/// Deterministic stub producer: derives a valid register subject from
/// the content's first line.
private struct StubProducer: SubjectProducer {
    let pipelineVersion = "stub-v1"
    func subject(forContent content: String) async throws -> String {
        String(content.split(separator: "\n").first.map(String.init)!.prefix(120))
    }
}

/// Producer whose output always violates the register (narrative frame).
private struct InadmissibleProducer: SubjectProducer {
    let pipelineVersion = "bad-v1"
    func subject(forContent content: String) async throws -> String {
        "This is a summary that violates the register."
    }
}


/// Refuses any content carrying the marker word, produces for the rest.
private struct RefusingProducer: SubjectProducer {
    let pipelineVersion = "refusing-v1"
    func subject(forContent content: String) async throws -> String {
        if content.contains("REFUSE") { throw SubjectProducerError.refused(reason: "guardrail") }
        return String(content.split(separator: "\n").first.map(String.init)!.prefix(120))
    }
}

/// Cannot answer at all right now.
private struct UnavailableProducer: SubjectProducer {
    let pipelineVersion = "unavailable-v1"
    func subject(forContent content: String) async throws -> String {
        throw SubjectProducerError.unavailable(reason: "rate limited")
    }
}

@Suite("Subject backfill cycle — rider seam", .serialized)
struct SubjectBackfillCycleTests {

    private func openEstate(
        owner: String
    ) async throws -> (GeniusLocusKit, EstateHandle, LocusKit.Estate) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let creds = OwnerCredentials(ownerIdentifier: owner)
        _ = try await LocusKit.Estate.create(storage: storage, owner: creds)
        let handle = try await kit.open(
            storage: storage, owner: creds,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        let estate = try await kit.estate(for: handle)
        return (kit, handle, estate)
    }

    private func seedDebt(
        _ kit: GeniusLocusKit, _ handle: EstateHandle, count: Int
    ) async throws {
        for i in 1...count {
            let frame = CaptureFrame(
                content: "Debt row number \(i) awaiting a subject.",
                channel: .typed,
                room: "backfill-tests",
                latticeAnchor: LatticeAnchor(udcCode: "000"),
                addedBy: "subject-backfill-tests",
                embeddingModelID: "test-model-v1")
            _ = try await kit.capture(handle, frame)
        }
    }


    @Test func aRefusalMarksTheDrawerAndTheSweepMovesOn() async throws {
        let (kit, handle, estate) = try await openEstate(owner: "refusal")
        try await seedDebt(kit, handle, count: 4)
        for i in 1...2 {
            let frame = CaptureFrame(
                content: "REFUSE row \(i) the model will not summarise.",
                channel: .typed, room: "backfill-tests",
                latticeAnchor: LatticeAnchor(udcCode: "000"),
                addedBy: "subject-backfill-tests", embeddingModelID: "test-model-v1")
            _ = try await kit.capture(handle, frame)
        }
        try await kit.registerSubjectProducer(RefusingProducer(), for: handle)
        let report = try await kit.subjectBackfillSweep(handle, now: Date(timeIntervalSince1970: 1_700_000_001))
        #expect(report.written == 4)
        #expect(report.refused == 2)
        #expect(report.remainingDebt == 0, "refused rows left the lane")
        let marker = DrawerStore.subjectRefusedMarker(for: "refusing-v1")
        var refusedRows = 0
        for d in try await estate.allDrawers() {
            if d.content.contains("REFUSE") {
                #expect(d.subject == nil, "a refusal stores no subject")
                #expect(d.subjectPipelineVersion == marker)
                let trail = try await kit.auditTrail(in: handle, rowID: d.id)
                #expect(trail.last?.verb == "subjectRefused", "one sealed custody event per refusal")
                #expect(trail.last?.reason == "guardrail")
                refusedRows += 1
            } else {
                #expect(d.subject != nil)
            }
        }
        #expect(refusedRows == 2)
        #expect(try await estate.countSubjectRefused(pipelineVersion: "refusing-v1") == 2)
        // Another producer still sees those two rows as debt.
        #expect(try await estate.countSubjectDebt(includingPipelines: [], refusedBy: "other-v1") == 2)
        // The lane reports the refusals and the second sweep enumerates none of them.
        let lane = try await kit.drainStatuses(handle).first { $0.name == DrainStatus.subjectBackfillName }
        #expect(lane?.pending == 0)
        #expect(lane?.detail == "pipeline: refusing-v1, refused: 2")
        let again = try await kit.subjectBackfillSweep(handle, now: Date(timeIntervalSince1970: 1_700_000_002))
        #expect(again.written == 0 && again.refused == 0)
    }

    @Test func anUnavailableProducerStopsTheSweepAndMarksNothing() async throws {
        let (kit, handle, estate) = try await openEstate(owner: "unavailable")
        try await seedDebt(kit, handle, count: 3)
        try await kit.registerSubjectProducer(UnavailableProducer(), for: handle)
        await #expect(throws: SubjectProducerError.self) {
            try await kit.subjectBackfillSweep(handle, now: Date(timeIntervalSince1970: 1_700_000_001))
        }
        #expect(try await estate.countSubjectDebt(includingPipelines: [], refusedBy: "unavailable-v1") == 3, "pending unchanged")
        #expect(try await estate.countSubjectRefused(pipelineVersion: "unavailable-v1") == 0)
    }

    @Test func sweepRefusesWhileLaneIsDark() async throws {
        let (kit, handle, _) = try await openEstate(owner: "dark-lane")
        defer { Task { try? await kit.close(handle) } }
        try await seedDebt(kit, handle, count: 2)
        await #expect(throws: GeniusLocusKitError.self) {
            _ = try await kit.subjectBackfillSweep(handle, now: Date())
        }
        // And the drain lane does not render while dark (barrier safety).
        let drains = try await kit.drainStatuses(handle)
        #expect(!drains.contains { $0.name == DrainStatus.subjectBackfillName },
                "subject_backfill lane must not render without a rider: \(drains)")
    }

    /// The fact_extraction lane is ALWAYS rendered (extractor or not) and its
    /// pending is the bit-28 row debt, so a caller settles an estate on
    /// product state: draining while drawers are owed, idle once none are.
    @Test func factExtractionLaneReportsRowDebtWithoutAnExtractor() async throws {
        let (kit, handle, estate) = try await openEstate(owner: "fact-debt")
        defer { Task { try? await kit.close(handle) } }

        // Empty estate: lane present, nothing owed, idle.
        let empty = try await kit.drainStatuses(handle)
        let emptyLane = try #require(empty.first { $0.name == DrainStatus.factExtractionName })
        #expect(emptyLane.pending == 0)
        #expect(!emptyLane.isDraining)

        // Two filed memories, no extractor registered: pending is the debt
        // count and the detail names the missing extractor.
        try await seedDebt(kit, handle, count: 2)
        #expect(try await estate.countFactExtractionDebt() == 2)
        let drains = try await kit.drainStatuses(handle)
        let lane = try #require(drains.first { $0.name == DrainStatus.factExtractionName })
        #expect(lane.pending == 2, "pending must be the bit-28 row debt: \(drains)")
        #expect(lane.inFlight == 0)
        #expect(lane.isDraining)
        #expect(lane.detail
            == "no extractor registered; ready: 0, running: 0, partial: 0, retrying: 0, blocked: 2, rejected: 0, not applicable: 0, empty: 0")
        #expect(DrainStatus.encodeSettled(drains),
                "fact row debt must not extend the corpus-only detached finisher")
    }

    @Test func sweepDrainsDebtWithRegisteredProducerAndLaneRenders() async throws {
        let (kit, handle, estate) = try await openEstate(owner: "sweep-drains")
        defer { Task { try? await kit.close(handle) } }
        try await seedDebt(kit, handle, count: 5)
        #expect(try await estate.countSubjectDebt() == 5)

        try await kit.registerSubjectProducer(StubProducer(), for: handle)
        // Lane renders once the rider is registered, pending = debt.
        let drains = try await kit.drainStatuses(handle)
        let lane = drains.first { $0.name == DrainStatus.subjectBackfillName }
        #expect(lane?.pending == 5, "lane pending must be the presence debt: \(drains)")
        #expect(lane?.detail == "pipeline: stub-v1, refused: 0")

        // Bounded batch: limit 3 writes 3, leaves 2.
        let first = try await kit.subjectBackfillSweep(handle, batchLimit: 3, now: Date())
        #expect(first.written == 3)
        #expect(first.skippedInadmissible == 0)
        #expect(first.remainingDebt == 2)
        // Settled-skip is structural: the second sweep drains the REST.
        let second = try await kit.subjectBackfillSweep(handle, batchLimit: 10, now: Date())
        #expect(second.written == 2)
        #expect(second.remainingDebt == 0)
        // Provenance: every written subject carries the producer's tier.
        let drawers = try await estate.allDrawers()
        let stamped = drawers.filter { $0.subjectPipelineVersion == "stub-v1" }
        #expect(stamped.count == 5)
        // Idempotent rerun: nothing left to enumerate.
        let third = try await kit.subjectBackfillSweep(handle, batchLimit: 10, now: Date())
        #expect(third.written == 0)
    }

    @Test func inadmissibleProducerOutputSettlesAsRefused() async throws {
        let (kit, handle, estate) = try await openEstate(owner: "inadmissible")
        defer { Task { try? await kit.close(handle) } }
        try await seedDebt(kit, handle, count: 2)
        try await kit.registerSubjectProducer(InadmissibleProducer(), for: handle)
        let report = try await kit.subjectBackfillSweep(handle, now: Date())
        #expect(report.written == 0)
        #expect(report.refused == 2)
        #expect(report.skippedInadmissible == 0)
        #expect(report.remainingDebt == 0)
        let drawers = try await estate.allDrawers()
        #expect(drawers.count == 2)
        for drawer in drawers {
            #expect(drawer.subject == nil)
            #expect(drawer.subjectPipelineVersion == DrawerStore.subjectRefusedMarker(for: "bad-v1"))
            let trail = try await kit.auditTrail(in: handle, rowID: drawer.id)
            #expect(trail.last?.verb == "subjectRefused")
            #expect(trail.last?.reason == "inadmissible: narrativeFrame(\"this is a \")")
        }
    }
}

/// Producer with regeneration tiers (PR-10 shape) — regenerates the
/// deterministic tiers, never ai-v1.
private struct TieredStubProducer: SubjectProducer {
    let pipelineVersion = "tiered-stub-v1"
    let regeneratesPipelines = ["consolidation-v1", "seed-v1"]
    func subject(forContent content: String) async throws -> String {
        String(content.split(separator: "\n").first.map(String.init)!.prefix(120))
    }
}

extension SubjectBackfillCycleTests {

    /// PR-10 trust ladder through the sweep: NULL + deterministic-tier
    /// rows regenerate; ai-v1 rows are untouched; the producer's writes
    /// carry its own tier.
    @Test func tieredSweepRegeneratesBelowTiersAndNeverAIV1() async throws {
        let (kit, handle, estate) = try await openEstate(owner: "tiered-sweep")
        defer { Task { try? await kit.close(handle) } }
        // One NULL row.
        try await seedDebt(kit, handle, count: 1)
        // One ai-v1 row and one consolidation-v1 row.
        let all = try await estate.allDrawers()
        let nullID = all[0].id
        let frame = CaptureFrame(
            content: "Filing-AI authored row.", channel: .typed,
            room: "backfill-tests", latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "subject-backfill-tests", embeddingModelID: "test-model-v1",
            subject: "Filing-AI subject stays untouched.")
        let aiDrawer = try await kit.capture(handle, frame)
        let consFrame = CaptureFrame(
            content: "Deterministic writer row.", channel: .typed,
            room: "backfill-tests", latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "subject-backfill-tests", embeddingModelID: "test-model-v1")
        let consDrawer = try await kit.capture(handle, consFrame)
        _ = try await estate.setSubjectRepresentation(
            drawerId: consDrawer.id,
            subject: "Deterministic vague subject.",
            pipelineVersion: "consolidation-v1",
            at: Date())

        try await kit.registerSubjectProducer(TieredStubProducer(), for: handle)
        let report = try await kit.subjectBackfillSweep(handle, batchLimit: 10, now: Date())
        #expect(report.written == 2, "NULL + consolidation-v1 regenerate: \(report)")
        #expect(report.remainingDebt == 0)

        let after = Dictionary(uniqueKeysWithValues:
            try await estate.allDrawers().map { ($0.id, $0) })
        #expect(after[aiDrawer.id]?.subjectPipelineVersion == "ai-v1",
                "ai-v1 outranks the model — never overwritten")
        #expect(after[aiDrawer.id]?.subject == "Filing-AI subject stays untouched.")
        #expect(after[consDrawer.id]?.subjectPipelineVersion == "tiered-stub-v1")
        #expect(after[nullID]?.subjectPipelineVersion == "tiered-stub-v1")
    }
}

/// Answers over the 120-character contract, the shapes the on-device model
/// returns for dense technical drawers. Twin of Rust `OverLengthProducer`.
private struct OverLengthProducer: SubjectProducer {
    let pipelineVersion = "over-length-v1"
    /// 40 three-character words separated by single spaces ("w01 w02 … w40"): 159 characters.
    static let words = (1...40).map { String(format: "w%02d", $0) }.joined(separator: " ")
    func subject(forContent content: String) async throws -> String {
        if content.hasPrefix("words") { return Self.words }
        if content.hasPrefix("identifier") { return String(repeating: "x", count: 150) }
        // 130 two-scalar grapheme clusters (e + combining acute), no space.
        return String(repeating: "e\u{301}", count: 130)
    }
}

private actor RecordingInadmissibleProducer: SubjectProducer {
    let pipelineVersion = "bad-recording-v1"
    private(set) var asked: [String] = []

    func subject(forContent content: String) async throws -> String {
        asked.append(content)
        return "This is a note about the row."
    }
}

extension SubjectBackfillCycleTests {
    @Test func overLengthAnswersAreCutAtAWordBoundary() async throws {
        let (kit, handle, estate) = try await openEstate(owner: "over-length")
        defer { Task { try? await kit.close(handle) } }
        for content in ["words drawer", "identifier drawer", "accent drawer"] {
            _ = try await kit.capture(handle, CaptureFrame(
                content: content, channel: .typed, room: "backfill-tests",
                latticeAnchor: LatticeAnchor(udcCode: "000"),
                addedBy: "subject-backfill-tests", embeddingModelID: "test-model-v1"))
        }
        try await kit.registerSubjectProducer(OverLengthProducer(), for: handle)
        let report = try await kit.subjectBackfillSweep(handle, now: Date(timeIntervalSince1970: 1_700_000_010))
        #expect((report.written, report.refused, report.skippedInadmissible) == (3, 0, 0))
        let drawers = try await estate.allDrawers()
        func subject(_ prefix: String) -> String? { drawers.first { $0.content.hasPrefix(prefix) }?.subject }
        // The last space within the first 121 characters is at index 119, after w30.
        #expect(subject("words") == (1...30).map { String(format: "w%02d", $0) }.joined(separator: " "))
        #expect(subject("identifier") == String(repeating: "x", count: 120))
        let accent = try #require(subject("accent"))
        #expect(accent == String(repeating: "e\u{301}", count: 120))
        #expect(accent.count == 120)
    }

    @Test func inadmissibleRowsSettleAndTheNextSweepMovesOn() async throws {
        let (kit, handle, _) = try await openEstate(owner: "inadmissible-batches")
        defer { Task { try? await kit.close(handle) } }
        try await seedDebt(kit, handle, count: 3)
        let producer = RecordingInadmissibleProducer()
        try await kit.registerSubjectProducer(producer, for: handle)

        let first = try await kit.subjectBackfillSweep(handle, batchLimit: 2, now: Date())
        #expect(first.refused == 2)
        #expect(first.written == 0)
        #expect(first.remainingDebt == 1)
        #expect(await producer.asked.count == 2)

        let second = try await kit.subjectBackfillSweep(handle, batchLimit: 2, now: Date())
        #expect(second.refused == 1)
        #expect(second.remainingDebt == 0)
        let asked = await producer.asked
        #expect(asked.count == 3)
        #expect(Set(asked).count == 3)

        _ = try await kit.subjectBackfillSweep(handle, batchLimit: 2, now: Date())
        #expect(await producer.asked == asked)
    }
}
