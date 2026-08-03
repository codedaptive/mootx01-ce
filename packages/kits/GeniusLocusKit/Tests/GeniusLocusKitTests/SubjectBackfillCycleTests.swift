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

/// Producer whose output always violates the register (narrative frame)
/// — proves inadmissible output is skipped, never stored.
private struct InadmissibleProducer: SubjectProducer {
    let pipelineVersion = "bad-v1"
    func subject(forContent content: String) async throws -> String {
        "This is a summary that violates the register."
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
        #expect(lane?.detail == "pipeline: stub-v1")

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

    @Test func inadmissibleProducerOutputIsSkippedNeverStored() async throws {
        let (kit, handle, estate) = try await openEstate(owner: "inadmissible")
        defer { Task { try? await kit.close(handle) } }
        try await seedDebt(kit, handle, count: 2)
        try await kit.registerSubjectProducer(InadmissibleProducer(), for: handle)
        let report = try await kit.subjectBackfillSweep(handle, now: Date())
        #expect(report.written == 0)
        #expect(report.skippedInadmissible == 2)
        #expect(report.remainingDebt == 2, "skipped rows remain debt")
        let drawers = try await estate.allDrawers()
        #expect(!drawers.contains { $0.subjectPipelineVersion == "bad-v1" },
                "inadmissible output must never be stored")
    }
}
