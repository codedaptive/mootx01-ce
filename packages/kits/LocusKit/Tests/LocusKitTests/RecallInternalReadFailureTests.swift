// RecallInternalReadFailureTests.swift
//
// P0-5 sites 1-5: recall internal-read failures must be DISTINGUISHABLE
// from a genuine-empty estate. A failed liveRows / room-fingerprints /
// room-drawer-read / bitmap-eval read previously collapsed to `[]`,
// identical to "no matches." These tests drive each failure via the
// Estate `_testForceInternalReadError` fault seam and assert the recall
// stream surfaces the corresponding NAMED degraded stage — while a
// genuine-empty estate surfaces NONE. The distinction is the whole point.

import Foundation
import Testing
@testable import LocusKit

@Suite("Recall internal-read failure surfacing (P0-5 sites 1-5)")
struct RecallInternalReadFailureTests {

    // A drawer with the hasVoice operational flag so the pruning path
    // (which only runs when the chain carries a prunable filter) visits a
    // surviving room. provenance confirmation = userConfirmed (raw 1 at
    // bits 18-23) so the default frame admits the row.
    private func voiceDrawer(id: String, room: String) -> Drawer {
        Drawer(id: TestStorage.tid(id), content: "c-" + id, wing: "w", room: room, addedBy: "t",
               filedAt: Date(timeIntervalSince1970: 1_700_000_000),
               embeddingModelID: "m",
               provenance: Int64(1) << 18,
               adjectiveBitmap: 0,
               operationalBitmap: Int64(1) << 13,
               lineageID: UUID())
    }

    /// Open a seeded estate with one hasVoice drawer in room r1.
    private func seededEstate(url: URL) async throws -> Estate {
        let storage = TestStorage.sqlite(url)
        _ = try await Estate.create(storage: storage,
                                    owner: OwnerCredentials(ownerIdentifier: "o"))
        let drawerStore = try await DrawerStore(storage: storage)
        try await drawerStore.addDrawer(voiceDrawer(id: "d1", room: "r1"))
        return try await Estate.open(storage: storage,
                                     owner: OwnerCredentials(ownerIdentifier: "o"))
    }

    private func drain(_ stream: RecallStream) async -> [String] {
        var ids: [String] = []
        for await page in stream { ids.append(contentsOf: page.rows.map(\.id)) }
        return ids
    }

    // MARK: - genuine-empty baseline (the control)

    @Test("Genuine-empty estate: empty result, NO degraded stage")
    func genuineEmptyHasNoDegradedStage() async throws {
        let url = TestStorage.tempURL(); defer { TestStorage.cleanup(url) }
        let storage = TestStorage.sqlite(url)
        _ = try await Estate.create(storage: storage,
                                    owner: OwnerCredentials(ownerIdentifier: "o"))
        let estate = try await Estate.open(storage: storage,
                                           owner: OwnerCredentials(ownerIdentifier: "o"))

        // No fault armed. An empty estate must return [] with no stages.
        let stream = await estate.recall(RecallFrame(filterChain: []))
        let ids = await drain(stream)
        #expect(ids.isEmpty)
        #expect(stream.degradedStages.isEmpty,
                "a genuine-empty estate must record no degraded stage")
    }

    @Test("Non-empty estate, no fault: rows returned, NO degraded stage")
    func successfulRecallHasNoDegradedStage() async throws {
        let url = TestStorage.tempURL(); defer { TestStorage.cleanup(url) }
        let estate = try await seededEstate(url: url)
        let stream = await estate.recall(RecallFrame(filterChain: [.hasFeatureFlag(.hasVoice)]))
        let ids = await drain(stream)
        #expect(ids == [TestStorage.tid("d1")])
        #expect(stream.degradedStages.isEmpty)
    }

    // MARK: - each internal-read failure surfaces its named stage (failed ≠ empty)

    @Test("liveRows read failure → locus.liveRows.readFailed (non-pruning scan)")
    func liveRowsFailureSurfaced() async throws {
        let url = TestStorage.tempURL(); defer { TestStorage.cleanup(url) }
        let estate = try await seededEstate(url: url)
        await estate._setTestForceInternalReadError(.liveRows)
        // Empty filter chain → non-pruning bounded scan path (liveRows).
        let stream = await estate.recall(RecallFrame(filterChain: []))
        let ids = await drain(stream)
        #expect(ids.isEmpty, "failed scan yields no rows")
        #expect(stream.degradedStages == ["locus.liveRows.readFailed"],
                "a FAILED scan is distinguishable from a genuine-empty estate")
    }

    @Test("room-fingerprints read failure → locus.roomFingerprints.readFailed (pruning path)")
    func roomFingerprintsFailureSurfaced() async throws {
        let url = TestStorage.tempURL(); defer { TestStorage.cleanup(url) }
        let estate = try await seededEstate(url: url)
        await estate._setTestForceInternalReadError(.roomFingerprints)
        // Prunable filter → fingerprint-pruning path (roomLevelEntries).
        let stream = await estate.recall(RecallFrame(filterChain: [.hasFeatureFlag(.hasVoice)]))
        let ids = await drain(stream)
        #expect(ids.isEmpty)
        #expect(stream.degradedStages == ["locus.roomFingerprints.readFailed"])
    }

    @Test("room-drawer read failure → locus.roomDrawerRead.readFailed (pruning path)")
    func roomDrawerReadFailureSurfaced() async throws {
        let url = TestStorage.tempURL(); defer { TestStorage.cleanup(url) }
        let estate = try await seededEstate(url: url)
        await estate._setTestForceInternalReadError(.roomDrawerRead)
        let stream = await estate.recall(RecallFrame(filterChain: [.hasFeatureFlag(.hasVoice)]))
        let ids = await drain(stream)
        #expect(ids.isEmpty, "a failed surviving-room read yields no rows for that room")
        #expect(stream.degradedStages == ["locus.roomDrawerRead.readFailed"])
    }

    @Test("bitmap-eval failure → locus.bitmapEval.failed")
    func bitmapEvalFailureSurfaced() async throws {
        let url = TestStorage.tempURL(); defer { TestStorage.cleanup(url) }
        let estate = try await seededEstate(url: url)
        await estate._setTestForceInternalReadError(.bitmapEval)
        let stream = await estate.recall(RecallFrame(filterChain: []))
        let ids = await drain(stream)
        #expect(ids.isEmpty)
        #expect(stream.degradedStages == ["locus.bitmapEval.failed"])
    }

    // MARK: - trace-WRITE failure is fail-closed (rows still returned)

    // The trace write fires AFTER reads + eval succeed and ONLY when the caller
    // opts in via traceLimit on a non-empty result. A forced `.traceWrite` fault
    // must therefore yield a POPULATED result WITH the `recall.trace_write_failed`
    // stage — proving recall stays non-throwing (spec §7.8.1) while a dropped
    // trace (the reward sweep's missing input) is observable, not silent.

    @Test("trace-write failure → recall.trace_write_failed, rows STILL returned (fail-closed)")
    func traceWriteFailureSurfacedRowsStillReturned() async throws {
        let url = TestStorage.tempURL(); defer { TestStorage.cleanup(url) }
        let estate = try await seededEstate(url: url)
        await estate._setTestForceInternalReadError(.traceWrite)
        // traceLimit opts the caller into the reward cycle so the write path runs.
        var frame = RecallFrame(filterChain: [.hasFeatureFlag(.hasVoice)])
        frame.traceLimit = 5
        let stream = await estate.recall(frame)
        let ids = await drain(stream)
        // Non-throwing: the caller STILL receives its rows despite the lost trace.
        #expect(ids == [TestStorage.tid("d1")],
                "recall stays non-throwing — a trace-write fault must not empty the result")
        // The dropped trace is observable on the same degradedStages channel.
        #expect(stream.degradedStages == ["recall.trace_write_failed"],
                "a lost recall trace must be observable, not silently swallowed")
    }

    @Test("Healthy control: traceLimit set, write succeeds → rows returned, NO stage")
    func traceWriteSuccessRecordsNoStage() async throws {
        let url = TestStorage.tempURL(); defer { TestStorage.cleanup(url) }
        let estate = try await seededEstate(url: url)
        // No fault armed — a genuine successful trace write records nothing.
        var frame = RecallFrame(filterChain: [.hasFeatureFlag(.hasVoice)])
        frame.traceLimit = 5
        let stream = await estate.recall(frame)
        let ids = await drain(stream)
        #expect(ids == [TestStorage.tid("d1")])
        #expect(stream.degradedStages.isEmpty,
                "a clean trace write records no degraded stage")
    }

    // MARK: - seam is single-use

    @Test("Fault seam is single-use: next recall behaves normally")
    func faultSeamIsSingleUse() async throws {
        let url = TestStorage.tempURL(); defer { TestStorage.cleanup(url) }
        let estate = try await seededEstate(url: url)
        await estate._setTestForceInternalReadError(.liveRows)

        let firstStream = await estate.recall(RecallFrame(filterChain: []))
        _ = await drain(firstStream)
        #expect(firstStream.degradedStages == ["locus.liveRows.readFailed"])

        // Seam consumed — the next recall is a normal, successful read.
        let secondStream = await estate.recall(RecallFrame(filterChain: [.hasFeatureFlag(.hasVoice)]))
        let ids = await drain(secondStream)
        #expect(ids == [TestStorage.tid("d1")])
        #expect(secondStream.degradedStages.isEmpty)
    }
}
