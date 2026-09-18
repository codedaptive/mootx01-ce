// AnomalyFlagSweepTests.swift
//
// Integration tests for the anomaly-flag sweep and the anomalousFilter
// admission gate on GLKRecallRequest (§11.18).
//
// Coverage:
//   1. anomalyFlagSweepFlagsOutlier — 5 near-identical drawers + 1 outlier
//      in the same room. After the sweep, exactly the outlier has bit 26 set.
//   2. anomalyFlagSweepClearsSmallRoom — room with 2 drawers (below the
//      minimum-3 threshold). Any pre-existing bit 26 is cleared; no outlier
//      is declared when the cohort is too small for z-scores.
//   3. anomalyFlagSweepSkipsUnchangedBit — second sweep run on a stable
//      estate returns 0 changed (write skipped when bit already correct).
//   4. anomalousFilterTrueAdmitsOnlyOutlier — recall with anomalousFilter:
//      true returns only the outlier after the sweep.
//   5. anomalousFilterFalseExcludesOutlier — recall with anomalousFilter:
//      false returns the 5 cohort drawers and not the outlier.
//   6. anomalousFilterNilIsPassthrough — recall with anomalousFilter: nil
//      returns the same hit IDs as an identical request with no filter
//      (byte-identical gate path).
//
// Cohort design for tests 1/4/5/6:
//   5 near-identical items + 1 fully different outlier in room "test-cohort".
//   With 6 drawers where similarity(cohort, cohort) ≈ 0.95 and
//   similarity(cohort, outlier) ≈ 0.0:
//     cohort cohesion ≈ (4 × 0.95 + 0.0) / 5 ≈ 0.76
//     outlier cohesion ≈ 0.0
//     mean ≈ (5 × 0.76 + 0.0) / 6 ≈ 0.633
//     stddev ≈ 0.283
//     z_outlier ≈ (0.0 − 0.633) / 0.283 ≈ −2.24  ← below default threshold 2.0
//     z_cohort ≈ +0.45 ← above threshold (not flagged)
//
// Tests use the GeniusLocusKit.provision path to get a fully-open estate.

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes
@testable import SubstrateML
@testable import GeniusLocusKit

@Suite("AnomalyFlagSweep — bit 26 maintenance sweep and anomalousFilter gate (§11.18)")
struct AnomalyFlagSweepTests {

    // MARK: - Constants

    private static let modelID = "test-model-v1"
    private static let wing = "Agentic Memory"
    private static let room = "test-cohort"

    /// Five near-identical items that form a tight cohesion cluster.
    /// Differences are minimal (one word each) to keep char-4 Jaccard high.
    private static let cohortContents: [String] = [
        "Project Falcon deadline moved to March. Falcon deploy target is the staging cluster. Maria owns the Falcon rollout checklist.",
        "Project Falcon deadline moved to March. Falcon deploy target is the staging cluster. Maria owns the Falcon rollout list.",
        "Project Falcon deadline moved to March. Falcon deploy target is the staging cluster. Maria owns the Falcon deployment checklist.",
        "Project Falcon deadline was moved to March. Falcon deploy target is the staging cluster. Maria owns the Falcon rollout checklist.",
        "Project Falcon deadline moved to March. Falcon deploy target is the staging cluster. Maria controls the Falcon rollout checklist.",
    ]

    /// The outlier — completely different topic and vocabulary so char-4 shingle
    /// overlap with the cohort is ≈ 0, driving a large negative z-score.
    private static let outlierContent =
        "Banana pudding recipe: vanilla wafers layered with custard and sliced bananas. Refrigerate overnight before serving."

    // MARK: - Estate factory

    /// Open a provisioned estate (GLK schema applied). Returns the kit,
    /// handle; the underlying estate is accessible via kit.estate(for:).
    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "anomaly-sweep-tests-\(UUID().uuidString)")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let params = EstateProvisionParams(
            estateName: "Anomaly Sweep Test Estate",
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

    /// Capture a single item into the test room and return the resulting drawer.
    private func captureInRoom(
        content: String,
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> Drawer {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: Self.room,
            latticeAnchor: LatticeAnchor.udc("000"),
            addedBy: "anomaly-sweep-tests",
            embeddingModelID: Self.modelID
        )
        return try await kit.capture(handle, frame)
    }

    // MARK: - Test 1: Sweep flags the outlier

    @Test("anomalyFlagSweep flags the cohesion outlier and leaves cohort members clear")
    func anomalyFlagSweepFlagsOutlier() async throws {
        let (kit, handle) = try await openEstate()
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)

        // Plant 5 cohort items and 1 outlier in the same room.
        var cohortIDs: [String] = []
        for content in Self.cohortContents {
            let d = try await captureInRoom(content: content, kit: kit, handle: handle)
            cohortIDs.append(d.id)
        }
        let outlierDrawer = try await captureInRoom(
            content: Self.outlierContent, kit: kit, handle: handle)

        // Run the sweep with the default threshold (2.0).
        let changed = try await kit.anomalyFlagSweep(handle: handle, now: t0)

        // Exactly 1 drawer should change state (the outlier gains bit 26).
        #expect(changed == 1, "exactly one drawer transitions to isAnomalous = true")

        // Verify the bit directly from the database via drawersIn.
        let estate = try await kit.estate(for: handle)
        let drawers = try await estate.drawersIn(
            wing: Self.wing, room: Self.room)

        let byID = Dictionary(uniqueKeysWithValues: drawers.map { ($0.id, $0) })

        // Outlier must be flagged.
        let outlierRow = try #require(byID[outlierDrawer.id], "outlier drawer must be in the room")
        #expect(outlierRow.isAnomalous, "outlier must have bit 26 set after sweep")

        // All cohort drawers must remain clear.
        for id in cohortIDs {
            if let row = byID[id] {
                #expect(!row.isAnomalous, "cohort drawer \(id) must not have bit 26 set")
            }
        }
    }

    // MARK: - Test 1b: The incremental duty scores only touched rooms

    @Test("anomaly duty owes a room until scored, then only after a write touches it again")
    func anomalyDutyScoresOnlyTouchedRooms() async throws {
        let (kit, handle) = try await openEstate()
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        for content in Self.cohortContents {
            _ = try await captureInRoom(content: content, kit: kit, handle: handle)
        }
        let outlier = try await captureInRoom(content: Self.outlierContent, kit: kit, handle: handle)

        // Never scored: the room is owed.
        let owedBefore = try await kit.anomalySweepOwedContainers(handle, now: t0)
        #expect(owedBefore.contains { $0.wing == Self.wing && $0.room == Self.room })
        #expect(try await kit.dutyDebt(.anomalySweep, in: handle, now: t0) == owedBefore.count)

        // One batch wide enough for every owed room scores them all and flags the outlier.
        let scored = try await kit.runAnomalySweepBatch(handle, limit: owedBefore.count, now: t0)
        #expect(scored == owedBefore.count)
        let estate = try await kit.estate(for: handle)
        let flagged = try await estate.drawersIn(wing: Self.wing, room: Self.room).filter(\.isAnomalous).map(\.id)
        #expect(flagged == [outlier.id])

        // Scored and untouched: nothing owed, so the resident's tick costs no scoring.
        #expect(try await kit.dutyDebt(.anomalySweep, in: handle, now: t0) == 0)

        // A write into the room makes exactly that room owed again.
        _ = try await captureInRoom(content: Self.cohortContents[0], kit: kit, handle: handle)
        let owedAfter = try await kit.anomalySweepOwedContainers(handle, now: t0.addingTimeInterval(1))
        #expect(owedAfter.count == 1)
        #expect(owedAfter.first?.room == Self.room)
    }

    // MARK: - Test 1c: F4 — a reanchor move dirties BOTH the room a drawer
    // leaves and the room it joins; an expunge dirties its own room.

    @Test("F4: moving a drawer to another room owes both rooms; expunging a drawer owes its room")
    func anomalySweepOwesBothRoomsAfterMoveAndOwesRoomAfterExpunge() async throws {
        let (kit, handle) = try await openEstate()
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        let destinationRoom = "test-cohort-destination"

        // Room A ("test-cohort") starts with 4 drawers; a fifth is a
        // second drawer used for the expunge half of the test below. Keeping
        // 3 drawers in room A after the move means room A never drops out of
        // `roomLevelFingerprints()` entirely — a room with zero remaining
        // drawers would not be a fair test of "still-owed", since an absent
        // room is filtered out of the owed list by construction (step 2 of
        // `anomalySweepOwedContainers` only ever reports rooms the fingerprint
        // store still knows about).
        var roomADrawers: [Drawer] = []
        for content in Self.cohortContents {
            roomADrawers.append(try await captureInRoom(content: content, kit: kit, handle: handle))
        }
        let mover = roomADrawers[0]
        let toExpunge = roomADrawers[1]
        // Seed the destination room with a capture BEFORE the move. The
        // room-level fingerprint aggregate (`ContainerFingerprintStore`,
        // read by `roomLevelFingerprints()`, the source of the owed list's
        // candidate rooms) is written only by `containerFP.orIn` on capture
        // — `reanchorGated` never touches it. A destination room with no
        // prior capture would never appear in `roomLevelFingerprints()` at
        // all regardless of dirtying, which is a separate, pre-existing gap
        // from the one this test targets (see completion report).
        let destFrame = CaptureFrame(
            content: "destination room seed", channel: .typed, room: destinationRoom,
            latticeAnchor: LatticeAnchor.udc("000"), addedBy: "anomaly-sweep-tests",
            embeddingModelID: Self.modelID)
        _ = try await kit.capture(handle, destFrame)

        // Settle all debt before the move so the owed set below reflects
        // ONLY what the move itself (not the initial captures) creates.
        let owedInitially = try await kit.anomalySweepOwedContainers(handle, now: t0)
        _ = try await kit.runAnomalySweepBatch(handle, limit: owedInitially.count, now: t0)
        #expect(try await kit.anomalySweepOwedContainers(handle, now: t0).isEmpty)

        // Move one drawer out of room A into a brand-new room. Before the F4
        // fix, the owed read only used the drawer's CURRENT (post-
        // move) parentNodeId off the audit-touched row, so only the
        // destination room was ever dirtied — room A's now-changed cohesion
        // peer set was silently skipped.
        try await kit.reanchor(handle, ReanchorFrame(rowID: mover.id, toRoom: destinationRoom))
        let owedAfterMove = try await kit.anomalySweepOwedContainers(handle, now: t0.addingTimeInterval(1))
        let owedKeys = Set(owedAfterMove.map { $0.wing + "/" + $0.room })
        #expect(owedKeys.contains(Self.wing + "/" + Self.room), "the room the drawer LEFT must be owed")
        #expect(owedKeys.contains(Self.wing + "/" + destinationRoom), "the room the drawer JOINED must be owed")

        // Settle again so the expunge half below starts from zero debt.
        _ = try await kit.runAnomalySweepBatch(
            handle, limit: owedAfterMove.count, now: t0.addingTimeInterval(1))
        #expect(try await kit.anomalySweepOwedContainers(handle, now: t0.addingTimeInterval(1)).isEmpty)

        // Expunging a drawer must owe its (unchanged) room — no reanchor
        // involved, so the existing audit-fold path already resolves the
        // CURRENT parentNodeId correctly; this pins that it stays correct.
        _ = try await kit.expunge(handle, ExpungeFrame(
            rowID: toExpunge.id, reason: "F4 test expunge", confirmation: true))
        let owedAfterExpunge = try await kit.anomalySweepOwedContainers(handle, now: t0.addingTimeInterval(2))
        #expect(
            owedAfterExpunge.contains { $0.wing == Self.wing && $0.room == Self.room },
            "expunging a drawer must owe the room it was filed in"
        )
    }

    // MARK: - Test 2: Small room clears bit 26

    @Test("anomalyFlagSweep clears bit 26 in rooms below the minimum size")
    func anomalyFlagSweepClearsSmallRoom() async throws {
        let (kit, handle) = try await openEstate()
        let t0 = Date(timeIntervalSince1970: 1_750_000_100)

        // Capture only 2 drawers (below the 3-drawer minimum).
        let d1 = try await captureInRoom(content: "Alpha content.", kit: kit, handle: handle)
        let d2 = try await captureInRoom(content: "Beta content.", kit: kit, handle: handle)

        // Directly set bit 26 on d1 via the estate, simulating a stale flag
        // from a prior sweep when the room had more items.
        let estate = try await kit.estate(for: handle)
        _ = try await estate.setAnomalousFlag(drawerId: d1.id, anomalous: true, now: t0)

        // Verify it was set.
        let before = try await estate.getDrawers(ids: [d1.id])
        #expect(before.first?.isAnomalous == true, "bit 26 must be set before sweep")

        // Run the sweep — small room (2 items) must clear the bit.
        let changed = try await kit.anomalyFlagSweep(handle: handle, now: t0)
        #expect(changed == 1, "sweep must clear 1 stale bit 26 in the small room")

        // Confirm d1 no longer has bit 26.
        let after = try await estate.getDrawers(ids: [d1.id, d2.id])
        let byID = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
        #expect(byID[d1.id]?.isAnomalous == false, "d1 bit 26 must be cleared by sweep")
        #expect(byID[d2.id]?.isAnomalous == false, "d2 bit 26 must remain clear")
    }

    // MARK: - Test 3: Idempotent — second sweep returns 0 changed

    @Test("anomalyFlagSweep is idempotent — second run returns 0 changed on a stable estate")
    func anomalyFlagSweepSkipsUnchangedBit() async throws {
        let (kit, handle) = try await openEstate()
        let t0 = Date(timeIntervalSince1970: 1_750_000_200)

        for content in Self.cohortContents {
            _ = try await captureInRoom(content: content, kit: kit, handle: handle)
        }
        _ = try await captureInRoom(content: Self.outlierContent, kit: kit, handle: handle)

        // First sweep sets the bit.
        let first = try await kit.anomalyFlagSweep(handle: handle, now: t0)
        #expect(first == 1, "first sweep must set 1 bit")

        // Second sweep on the same stable estate must make no writes.
        let second = try await kit.anomalyFlagSweep(handle: handle, now: t0)
        #expect(second == 0, "second sweep must find 0 changed bits (idempotent)")
    }

    // MARK: - Recall filter gate tests

    /// Shared fixture: estate with 5 cohort + 1 outlier, sweep run, outlier
    /// has bit 26. Returns kit, handle, and the outlier's drawer ID.
    private func openEstateWithSweptOutlier() async throws -> (
        GeniusLocusKit, EstateHandle, String, [String]
    ) {
        let (kit, handle) = try await openEstate()
        let t0 = Date(timeIntervalSince1970: 1_750_000_300)

        var cohortIDs: [String] = []
        for content in Self.cohortContents {
            let d = try await captureInRoom(content: content, kit: kit, handle: handle)
            cohortIDs.append(d.id)
        }
        let outlier = try await captureInRoom(
            content: Self.outlierContent, kit: kit, handle: handle)

        let changed = try await kit.anomalyFlagSweep(handle: handle, now: t0)
        // Sanity: sweep must have flagged the outlier.
        precondition(changed == 1, "test precondition: sweep must flag exactly 1 outlier")

        return (kit, handle, outlier.id, cohortIDs)
    }

    // MARK: - Test 4: anomalousFilter: true → only outlier

    @Test("anomalousFilter: true admits only the anomalous outlier")
    func anomalousFilterTrueAdmitsOnlyOutlier() async throws {
        let (kit, handle, outlierID, cohortIDs) = try await openEstateWithSweptOutlier()

        // Recall all items in the room with anomalousFilter: true.
        let frame = RecallFrame(
            filterChain: [],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
        let request = GLKRecallRequest(
            frame: frame,
            mode: .locusOnly,
            scoring: .raw,
            limit: 20,
            fallback: .allowDegraded,
            origin: .internal,
            anomalousFilter: true
        )
        let result = try await kit.recall(handle, request)

        // Only the outlier should appear; cohort drawers must be excluded.
        let hitIDs = Set(result.hits.compactMap { $0.drawer?.id })
        #expect(hitIDs.contains(outlierID),
                "anomalousFilter:true must include the outlier")
        for id in cohortIDs {
            #expect(!hitIDs.contains(id),
                    "anomalousFilter:true must exclude cohort drawer \(id)")
        }
    }

    // MARK: - Test 5: anomalousFilter: false → cohort only

    @Test("anomalousFilter: false excludes the anomalous outlier")
    func anomalousFilterFalseExcludesOutlier() async throws {
        let (kit, handle, outlierID, cohortIDs) = try await openEstateWithSweptOutlier()

        let frame = RecallFrame(
            filterChain: [],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
        let request = GLKRecallRequest(
            frame: frame,
            mode: .locusOnly,
            scoring: .raw,
            limit: 20,
            fallback: .allowDegraded,
            origin: .internal,
            anomalousFilter: false
        )
        let result = try await kit.recall(handle, request)

        let hitIDs = Set(result.hits.compactMap { $0.drawer?.id })
        // Outlier must be absent.
        #expect(!hitIDs.contains(outlierID),
                "anomalousFilter:false must exclude the outlier")
        // At least some cohort drawers must appear.
        let cohortHits = cohortIDs.filter { hitIDs.contains($0) }
        #expect(!cohortHits.isEmpty,
                "anomalousFilter:false must include cohort drawers")
    }

    // MARK: - Test 6: anomalousFilter: nil — passthrough (same hits as unflitered)

    @Test("anomalousFilter: nil is a passthrough — same hit IDs as an unfiltered request")
    func anomalousFilterNilIsPassthrough() async throws {
        let (kit, handle, _, _) = try await openEstateWithSweptOutlier()

        let frame = RecallFrame(
            filterChain: [],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
        // Unfiltered request (default anomalousFilter = nil, but spelled out).
        let unfiltered = GLKRecallRequest(
            frame: frame,
            mode: .locusOnly,
            scoring: .raw,
            limit: 20,
            fallback: .allowDegraded,
            origin: .internal,
            anomalousFilter: nil
        )
        // Explicit nil — same as unfiltered.
        let explicitNil = GLKRecallRequest(
            frame: frame,
            mode: .locusOnly,
            scoring: .raw,
            limit: 20,
            fallback: .allowDegraded,
            origin: .internal
        )

        let resultA = try await kit.recall(handle, unfiltered)
        let resultB = try await kit.recall(handle, explicitNil)

        let idsA = Set(resultA.hits.compactMap { $0.drawer?.id })
        let idsB = Set(resultB.hits.compactMap { $0.drawer?.id })

        // Both paths must produce identical hit ID sets.
        #expect(idsA == idsB,
                "anomalousFilter:nil must be byte-identical passthrough to no-filter")
        // Sanity: at least 1 hit expected from 6 captured drawers.
        #expect(!idsA.isEmpty, "recall must return at least one hit")
    }
}
