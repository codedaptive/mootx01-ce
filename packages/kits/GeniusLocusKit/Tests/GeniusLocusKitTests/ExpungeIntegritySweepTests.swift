// ExpungeIntegritySweepTests.swift
//
// Tests for GeniusLocusKit's `runExpungeIntegritySweep(_:now:)` maintenance
// function. Swift mirror of expunge_integrity_sweep.rs.
//
// The sweep detects tombstoned rows that have no sealed "tombstone" or
// "expungeOrphan" audit event — the crash-window scenario where step 1 of
// the §B-2a expunge (LocusKit storage tombstone+scrub) ran, but the process
// crashed before step 3 (the audit seal) completed. The sweep re-attempts
// the cross-kit vector+corpus delete and seals a synthetic "expungeOrphan"
// audit to close the audit gap.
//
// Tests:
//   S1 — crash-window: tombstoned row with no audit is detected, re-deleted
//        from the corpus, and sealed as expungeOrphan. remediatedCount == 1.
//   S2 — no-op: when all tombstoned rows have audits, the sweep is a clean
//        no-op (zero counts, zero errors).
//   S3 — locusOnly crash-window: tombstoned row with no audit, no Corpus or
//        VectorStore registered. Re-delete is a no-op; the row is sealed as
//        expungeOrphan with remediatedCount == 1 (audit gap closed).
//   S4 — sweep re-delete removes orphaned distillation-features-v1 lane
//        entry: crash-window after distillation leaves a structural
//        fingerprint entry in the VectorStore; sweep re-delete must scrub
//        the distillation lane as well as the corpus-model lane.
//        Parity with Rust S4: s4_sweep_remediates_orphaned_distillation_lane_entry.

import Testing
import Foundation
import CorpusKit
import VectorKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes
@testable import LocusKit
@testable import GeniusLocusKit

@Suite("Expunge integrity sweep — crash-window audit-gap remediation")
struct ExpungeIntegritySweepTests {

    // MARK: - Shared helpers

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func captureFrame(content: String) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "sweep-tests",
            latticeAnchor: .udc("000"),
            addedBy: "sweep-tests",
            embeddingModelID: "test-embed-v1"
        )
    }

    /// Provision a `.glk` estate (LocusKit + Corpus + VectorStore wired).
    private func provisionGLKEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-sweep-tests")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let params = EstateProvisionParams(
            estateName: "Sweep Test Estate GLK",
            kind: .glk,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none
        )
        let handle = try await kit.provision(
            storage: storage, owner: owner, params: params,
            embeddingModels: [.deterministic])
        return (kit, handle)
    }

    /// Provision a `.locusOnly` estate (no Corpus, no VectorStore).
    private func provisionLocusOnlyEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-sweep-locusonly")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let params = EstateProvisionParams(
            estateName: "Sweep Test Estate LocusOnly",
            kind: .locusOnly,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none
        )
        let handle = try await kit.provision(
            storage: storage, owner: owner, params: params)
        return (kit, handle)
    }

    /// Seed a crash-window state: capture a drawer, tombstone it via the
    /// LocusKit estate directly using `expungeReturningUnsealedEvent`, and
    /// discard the returned unsealed event without calling `sealExpungeAudit`.
    /// The row is left tombstoned with no audit event — simulating a process
    /// crash between step 1 (storage expunge) and step 3 (audit seal).
    private func seedCrashWindow(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        content: String
    ) async throws -> String {
        let drawer = try await kit.capture(handle, captureFrame(content: content))

        let estate = try await kit.estate(for: handle)
        // expungeReturningUnsealedEvent — tombstones without sealing.
        // Discard the event to simulate a crash before the seal call.
        let _ = try await estate.expungeReturningUnsealedEvent(
            rowID: drawer.id,
            reason: "crash-window-sim",
            confirmation: true,
            now: Self.now
        )
        // Event deliberately not sealed — crash-window state established.
        return drawer.id
    }

    // MARK: - S1: crash-window row is detected and remediated

    /// Seeds a crash-window tombstoned row (no audit) on a .glk estate, then
    /// runs the sweep. The sweep must detect the row, re-attempt the corpus
    /// delete, and seal an expungeOrphan audit. remediatedCount == 1.
    ///
    /// Also verifies that the audit trail has exactly one "expungeOrphan"
    /// event after the sweep, and that the corpus no longer recalls the drawer.
    @Test
    func sweepRemediatesCrashWindowRowWithCorpus() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        defer { Task { try? await kit.close(handle) } }

        // Capture and encode into corpus BEFORE seeding the crash window so
        // the corpus has an entry to re-delete.
        let content = "sweep test content for s1 noble gas element"
        let drawer = try await kit.capture(
            handle, captureFrame(content: content), mode: .impatient)

        // Tombstone WITHOUT sealing any audit (crash-window simulation).
        let estate = try await kit.estate(for: handle)
        let _ = try await estate.expungeReturningUnsealedEvent(
            rowID: drawer.id,
            reason: "crash-window-sim",
            confirmation: true,
            now: Self.now
        )

        // Pre-condition: no tombstone or expungeOrphan audit event yet.
        let trailBefore = try await estate.auditTrail(rowID: drawer.id)
        let hasExpungeAudit = trailBefore.contains { $0.verb == "tombstone" || $0.verb == "expungeOrphan" }
        #expect(
            !hasExpungeAudit,
            "crash-window row must have no expunge audit before sweep; got verbs: \(trailBefore.map(\.verb))"
        )

        // Run the sweep.
        let sweepNow = Self.now.addingTimeInterval(1)
        let result = try await kit.runExpungeIntegritySweep(handle, now: sweepNow)

        #expect(result.remediatedCount == 1,
                "sweep must remediate exactly one crash-window row; got \(result)")
        #expect(result.orphanedCount == 0,
                "no rows should remain un-remediated; got \(result)")
        #expect(result.perRowErrors.isEmpty,
                "no per-row errors expected; got \(result.perRowErrors)")

        // Verify: audit trail now has exactly one expungeOrphan event.
        let trailAfter = try await estate.auditTrail(rowID: drawer.id)
        let orphanEvents = trailAfter.filter { $0.verb == "expungeOrphan" }
        #expect(
            orphanEvents.count == 1,
            "exactly one expungeOrphan audit must exist after sweep; trail verbs: \(trailAfter.map(\.verb))"
        )

        // Verify: corpus no longer recalls the drawer after the sweep re-deleted it.
        let corpus = try #require(
            await kit.corpusKits[handle],
            "a .glk estate must have a registered Corpus")
        let chunksAfter = try await corpus.recall(
            "noble gas element", limit: 10, now: sweepNow)
        let vectorSurvived = chunksAfter.contains { $0.id == drawer.id }
        #expect(
            !vectorSurvived,
            "corpus must not recall the drawer after the sweep re-attempted the delete"
        )
    }

    // MARK: - S2: no-op — all tombstoned rows already have audits

    /// After a successful full expunge (which seals the "tombstone" success
    /// audit), the sweep must be a no-op: zero remediated, zero orphaned, zero
    /// errors. No false remediation on a healthy estate.
    @Test
    func sweepIsNoopWhenAllTombstonedRowsHaveAudits() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        defer { Task { try? await kit.close(handle) } }

        let content = "sweep noop probe"
        let drawer = try await kit.capture(
            handle, captureFrame(content: content), mode: .impatient)

        // Full expunge via GLK — seals the "tombstone" success audit.
        try await kit.expunge(handle, ExpungeFrame(
            rowID: drawer.id, reason: "full expunge for noop test", confirmation: true))

        // Run the sweep. Must find nothing to remediate.
        let result = try await kit.runExpungeIntegritySweep(
            handle, now: Self.now.addingTimeInterval(1))

        #expect(
            result.remediatedCount == 0 && result.orphanedCount == 0 && result.perRowErrors.isEmpty,
            "sweep must be a no-op when all tombstoned rows have audits; got \(result)"
        )
    }

    // MARK: - S3: locusOnly crash-window — audit gap closed even without cross-kit stores

    /// Seeds a crash-window tombstoned row on a locusOnly estate (no Corpus,
    /// no VectorStore registered). The sweep finds the row, the re-delete step
    /// is a no-op (nothing to delete from), and the row is sealed with a
    /// synthetic expungeOrphan audit. remediatedCount == 1.
    ///
    /// This mirrors the locusOnly expunge happy path: no cross-kit stores →
    /// delete closure returns immediately → seal runs → audit gap closed.
    @Test
    func sweepLocusOnlyClosesAuditGapWithNoVectorStore() async throws {
        let (kit, handle) = try await provisionLocusOnlyEstate()
        defer { Task { try? await kit.close(handle) } }

        let rowID = try await seedCrashWindow(
            kit: kit, handle: handle, content: "s3 locusOnly crash window")

        // Run sweep on locusOnly estate.
        let result = try await kit.runExpungeIntegritySweep(
            handle, now: Self.now.addingTimeInterval(1))

        // No corpus/VectorStore → re-delete is a no-op → remediatedCount == 1.
        #expect(result.remediatedCount == 1,
                "locusOnly sweep must close the audit gap (remediatedCount == 1); got \(result)")
        #expect(result.orphanedCount == 0,
                "orphanedCount must be zero for locusOnly estate; got \(result)")
        #expect(result.perRowErrors.isEmpty,
                "no per-row errors expected for locusOnly sweep; got \(result.perRowErrors)")

        // Verify: audit trail now has an expungeOrphan event.
        let estate = try await kit.estate(for: handle)
        let trail = try await estate.auditTrail(rowID: rowID)
        let orphanCount = trail.filter { $0.verb == "expungeOrphan" }.count
        #expect(
            orphanCount == 1,
            "exactly one expungeOrphan audit must exist after locusOnly sweep; trail verbs: \(trail.map(\.verb))"
        )
    }

    // MARK: - S4: sweep re-delete removes orphaned distillation-features-v1 lane entry

    /// Three-sentence content is distilled (writes a distillation-features-v1
    /// lane entry in the VectorStore), then the process crashes between step 1
    /// (LocusKit tombstone) and step 2 (cross-kit delete). The lane entry
    /// survives the crash window. The integrity sweep's re-delete must now
    /// scrub the distillation lane in addition to the corpus-model lane.
    ///
    /// Parity with Rust S4: `s4_sweep_remediates_orphaned_distillation_lane_entry`.
    @Test
    func sweepRemediatesOrphanedDistillationLaneEntry() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        defer { Task { try? await kit.close(handle) } }

        // Three-sentence content with repeated named entity ("Rhenium") so
        // the matrix distillation path (≥3 sentences) produces a non-zero
        // structural fingerprint — which causes distillItemsSweep to write a
        // distillation-features-v1 VectorStore lane entry keyed by drawer id.
        // Same content style as Rust S4 (proven non-zero fingerprint via the
        // default extractor).
        let content = "Batch S4 used Rhenium wire. Tests on Rhenium passed. Labs shipped Rhenium early."
        let drawer = try await kit.capture(
            handle, captureFrame(content: content), mode: .impatient)

        // Distill the item to write the structural fingerprint lane entry.
        let distilled = try await kit.distillItemsSweep(
            handle: handle,
            distillFn: GeniusLocusKit.defaultDistillFn,
            now: Self.now)
        #expect(
            distilled >= 1,
            "distillItemsSweep must produce at least 1 item; got \(distilled)"
        )

        // Verify the lane entry exists before the crash window.
        let vectorStore = try #require(
            await kit.vectorStores[handle],
            "a .glk estate must have a registered VectorStore")
        let laneBefore = try await vectorStore.getVector(
            itemID: drawer.id, modelID: GeniusLocusKit.distillationLaneModelID)
        #expect(
            laneBefore != nil,
            "distillation-features-v1 lane entry must exist after distillation"
        )

        // Crash-window: tombstone WITHOUT sealing any audit event.
        // step 1 (LocusKit storage expunge) runs; step 2 (cross-kit delete)
        // and step 3 (audit seal) never execute — the lane entry survives.
        let estate = try await kit.estate(for: handle)
        let _ = try await estate.expungeReturningUnsealedEvent(
            rowID: drawer.id,
            reason: "crash-window-sim-s4",
            confirmation: true,
            now: Self.now
        )

        // Lane entry must STILL exist after the crash window (step 2 never ran).
        let laneMid = try await vectorStore.getVector(
            itemID: drawer.id, modelID: GeniusLocusKit.distillationLaneModelID)
        #expect(
            laneMid != nil,
            "lane entry must survive the crash-window (step 2 never ran)"
        )

        // Run the sweep. With the fix the re-delete block now scrubs the
        // distillation lane BEFORE attempting the corpus-model lane delete.
        let sweepNow = Self.now.addingTimeInterval(1)
        let result = try await kit.runExpungeIntegritySweep(handle, now: sweepNow)

        #expect(
            result.remediatedCount == 1,
            "sweep must remediate the crash-window row; got \(result)"
        )
        #expect(
            result.orphanedCount == 0,
            "no rows should remain un-remediated; got \(result)"
        )
        #expect(
            result.perRowErrors.isEmpty,
            "no per-row errors expected; got \(result.perRowErrors)"
        )

        // Distillation lane entry must be gone after the sweep's re-delete.
        let laneAfter = try await vectorStore.getVector(
            itemID: drawer.id, modelID: GeniusLocusKit.distillationLaneModelID)
        #expect(
            laneAfter == nil,
            "distillation-features-v1 lane entry must be scrubbed by the sweep re-delete"
        )
    }
}
