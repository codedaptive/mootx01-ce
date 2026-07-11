import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

/// Copy-on-write branch substrate tests — GLK-COW-01.
///
/// Invariant I-15: branch derivation never modifies the parent estate.
/// Every test that writes to a branch verifies the parent is untouched.
@Suite("Copy-on-write branches")
struct GLK_COW_01_BranchTests {

    // MARK: - Helpers

    /// Open a fresh estate through GeniusLocusKit backed by in-memory storage.
    private func openEstate(owner: String = "test-owner") async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let credentials = OwnerCredentials(ownerIdentifier: owner)
        _ = try await LocusKit.Estate.create(storage: storage, owner: credentials)
        let handle = try await kit.open(storage: storage, owner: credentials)
        return (kit, handle)
    }

    /// Capture one drawer into an estate through the GLK verb surface.
    private func captureOne(kit: GeniusLocusKit, handle: EstateHandle, content: String) async throws -> Drawer {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "branch-tests",
            latticeAnchor: .udc("000"),
            addedBy: "branch-tests",
            embeddingModelID: "test-model-v1"
        )
        return try await kit.capture(handle, frame)
    }

    /// Recall all active drawers from an estate through the GLK verb surface.
    ///
    /// Uses `.full` hydration so callers can check `content` values directly.
    /// Per spec § 7.3, `.structured` returns `content = ""` (no blob reads),
    /// which would break tests 7 and 8 that match by content after promotion/merge.
    private func recallAll(kit: GeniusLocusKit, handle: EstateHandle) async throws -> [Drawer] {
        let frame = RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .full,
            ordering: .byCaptureTimeDesc
        )
        return try await kit.recall(handle, frame)
    }

    // MARK: - Test 1: deriveBranch returns active BranchHandle

    /// `glkDeriveBranch` returns a handle with `status == .active`.
    @Test
    func deriveBranchReturnsActiveHandle() async throws {
        let (kit, handle) = try await openEstate()
        let branch = try await kit.glkDeriveBranch(name: "test-branch", from: handle)
        #expect(branch.status == .active)
        #expect(!branch.name.isEmpty)
    }

    // MARK: - Test 2: capture writes to branch, not parent

    /// `BranchHandle.capture` writes to the branch estate only.
    /// Rows captured into the branch must not appear in the parent (I-15).
    @Test
    func branchCaptureDoesNotModifyParent() async throws {
        let (kit, handle) = try await openEstate()
        // Capture one row into the parent so we have a known parent state.
        _ = try await captureOne(kit: kit, handle: handle, content: "parent-row")
        let parentRowsBefore = try await recallAll(kit: kit, handle: handle)

        let branch = try await kit.glkDeriveBranch(name: "isolation-branch", from: handle)
        let branchFrame = CaptureFrame(
            content: "branch-only-row",
            channel: .typed,
            room: "branch-tests",
            latticeAnchor: .udc("000"),
            addedBy: "branch-tests",
            embeddingModelID: "test-model-v1"
        )
        _ = try await branch.capture(branchFrame)

        let parentRowsAfter = try await recallAll(kit: kit, handle: handle)
        // Parent row count must not increase after a branch capture.
        #expect(parentRowsBefore.count == parentRowsAfter.count,
            "I-15 violated: parent estate modified by branch capture")
    }

    // MARK: - Test 3: recall from branch includes branch-only rows

    /// `BranchHandle.recall` returns rows captured into the branch.
    @Test
    func branchRecallIncludesBranchRows() async throws {
        let (kit, handle) = try await openEstate()
        let branch = try await kit.glkDeriveBranch(name: "recall-branch", from: handle)

        let branchFrame = CaptureFrame(
            content: "branch-exclusive-content",
            channel: .typed,
            room: "branch-tests",
            latticeAnchor: .udc("000"),
            addedBy: "branch-tests",
            embeddingModelID: "test-model-v1"
        )
        let stored = try await branch.capture(branchFrame)

        let recallFrame = RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
        let branchRows = try await branch.recall(recallFrame)
        #expect(branchRows.contains(where: { $0.id == stored.id }),
            "Branch recall should return the branch-captured row")
    }

    // MARK: - Test 4: parent recall does NOT see branch-only rows (I-15)

    /// Rows captured into a branch must be invisible to the parent estate's recall.
    @Test
    func parentRecallDoesNotSeeBranchRows() async throws {
        let (kit, handle) = try await openEstate()
        let branch = try await kit.glkDeriveBranch(name: "invisible-branch", from: handle)

        let branchFrame = CaptureFrame(
            content: "branch-only-content",
            channel: .typed,
            room: "branch-tests",
            latticeAnchor: .udc("000"),
            addedBy: "branch-tests",
            embeddingModelID: "test-model-v1"
        )
        let stored = try await branch.capture(branchFrame)

        let parentRows = try await recallAll(kit: kit, handle: handle)
        #expect(!parentRows.contains(where: { $0.id == stored.id }),
            "I-15 violated: parent estate can see branch-only row")
    }

    // MARK: - Test 5: discard transitions status to .discarded

    /// `BranchHandle.discard()` transitions the branch status to `.discarded`.
    @Test
    func discardTransitionsStatus() async throws {
        let (kit, handle) = try await openEstate()
        let branch = try await kit.glkDeriveBranch(name: "discard-branch", from: handle)
        #expect(branch.status == .active)

        try await branch.discard()
        #expect(branch.status == .discarded)
    }

    // MARK: - Test 6: discard releases rows, retains the status shell

    /// A discarded branch releases its heavy row copy (DoS fix — a
    /// derive→discard loop must not accumulate row copies), but the O(1)
    /// status shell is retained so C-5 can still refuse a disqualified branch
    /// as unpromotable.
    @Test
    func discardReleasesRowsKeepingStatusShell() async throws {
        let (kit, handle) = try await openEstate()
        let branch = try await kit.glkDeriveBranch(name: "audit-branch", from: handle)

        let branchFrame = CaptureFrame(
            content: "released-on-discard",
            channel: .typed,
            room: "branch-tests",
            latticeAnchor: .udc("000"),
            addedBy: "branch-tests",
            embeddingModelID: "test-model-v1"
        )
        _ = try await branch.capture(branchFrame)

        try await branch.discard()
        #expect(branch.status == .discarded)

        let recallFrame = RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
        let branchRows = try await branch.recall(recallFrame)
        #expect(branchRows.isEmpty,
            "Discarded branch releases its rows; only the status shell is retained")
    }

    // MARK: - Test 7: glkPromoteBranch — parent rows match branch rows

    /// After promotion the parent estate contains what the branch contained.
    @Test
    func promoteBranchReplacesParentRows() async throws {
        let (kit, handle) = try await openEstate()

        // Capture one row into the parent before branching.
        _ = try await captureOne(kit: kit, handle: handle, content: "original-parent-row")

        let branch = try await kit.glkDeriveBranch(name: "promote-branch", from: handle)

        // Add a branch-only row — this should end up in the parent after promotion.
        let branchFrame = CaptureFrame(
            content: "branch-row-that-promotes",
            channel: .typed,
            room: "branch-tests",
            latticeAnchor: .udc("000"),
            addedBy: "branch-tests",
            embeddingModelID: "test-model-v1"
        )
        let branchRow = try await branch.capture(branchFrame)

        try await kit.glkPromoteBranch(branch, replacing: handle)

        // The promoted row must now be readable from the parent estate.
        let parentRows = try await recallAll(kit: kit, handle: handle)
        // Promotion re-captures content into the parent (new IDs are minted);
        // match by content rather than ID since CaptureFrame has no id field.
        #expect(parentRows.contains(where: { $0.content == "branch-row-that-promotes" }),
            "After promotion the branch row must appear in the parent estate")
        // Branch status must be .won after promotion.
        #expect(branch.status == .won)
        _ = branchRow
    }

    // MARK: - Test 8: glkMergeDrawers — selected drawers appear in parent

    /// Cherry-picked drawers appear in the parent; non-selected branch rows do not.
    @Test
    func mergeDrawersSelectivelyPropagatesToParent() async throws {
        let (kit, handle) = try await openEstate()
        let branch = try await kit.glkDeriveBranch(name: "merge-branch", from: handle)

        // Capture two rows into the branch — only one will be cherry-picked.
        let framePick = CaptureFrame(
            content: "picked-row",
            channel: .typed,
            room: "branch-tests",
            latticeAnchor: .udc("000"),
            addedBy: "branch-tests",
            embeddingModelID: "test-model-v1"
        )
        let frameSkip = CaptureFrame(
            content: "skipped-row",
            channel: .typed,
            room: "branch-tests",
            latticeAnchor: .udc("000"),
            addedBy: "branch-tests",
            embeddingModelID: "test-model-v1"
        )
        let pickedRow = try await branch.capture(framePick)
        let skippedRow = try await branch.capture(frameSkip)

        let report = try await kit.glkMergeDrawers([pickedRow.id], from: branch, into: handle)

        let parentRows = try await recallAll(kit: kit, handle: handle)

        // Merge re-captures content into the parent (new IDs are minted);
        // match by content rather than ID since CaptureFrame has no id field.
        #expect(parentRows.contains(where: { $0.content == "picked-row" }),
            "Merged drawer must appear in parent estate")
        // The skipped row must NOT appear in the parent.
        #expect(!parentRows.contains(where: { $0.content == "skipped-row" }),
            "Non-selected branch row must not propagate to parent")
        // MergeReport must list the picked row's branch ID.
        #expect(report.merged.contains(pickedRow.id))
        _ = skippedRow
    }

    // MARK: - Test 9: lineageDepth is 1 for first-gen, 2 for branch-of-branch

    /// `lineageDepth` reports generation count: 1 for a direct branch, 2 for
    /// a branch derived from another branch.
    ///
    /// Uses the branch-overload of `glkDeriveBranch` which takes `from branch:`
    /// instead of `from handle:` to derive from an existing branch.
    @Test
    func lineageDepth() async throws {
        let (kit, handle) = try await openEstate()
        let branch1 = try await kit.glkDeriveBranch(name: "gen1", from: handle)
        #expect(branch1.lineageDepth == 1)

        // Derive a second-generation branch from the first branch.
        let branch2 = try await kit.glkDeriveBranch(name: "gen2", fromBranch: branch1)
        #expect(branch2.lineageDepth == 2)
    }

    // MARK: - Test 10: compareToParent returns non-empty report when branch has new rows

    /// `compareToParent` must return a non-empty `DifferentialReport` when the
    /// branch contains rows added after derivation.
    @Test
    func compareToParentDetectsNewRows() async throws {
        let (kit, handle) = try await openEstate()
        let branch = try await kit.glkDeriveBranch(name: "diff-branch", from: handle)

        // Add a row to the branch after derivation.
        let branchFrame = CaptureFrame(
            content: "new-in-branch",
            channel: .typed,
            room: "branch-tests",
            latticeAnchor: .udc("000"),
            addedBy: "branch-tests",
            embeddingModelID: "test-model-v1"
        )
        _ = try await branch.capture(branchFrame)

        let interval = DateInterval(start: Date.distantPast, end: Date.distantFuture)
        let report = try await branch.compareToParent(over: interval)

        #expect(!report.newInBranch.isEmpty,
            "compareToParent must detect rows added to branch after derivation")
    }

    // MARK: - Test 11: derive preserves wing (ADR-016 wing-integrity, Finding A)

    /// A drawer captured into the parent in a non-default wing must land in the
    /// SAME wing in the branch estate after derivation.
    ///
    /// Before this fix `EstateBranch.init` built CaptureFrame without the `wing`
    /// field, silently re-filing every derived row into the default "Agentic Memory"
    /// wing regardless of its original wing. Grant/federation boundary violations
    /// like this are silent data-routing bugs — content becomes visible to filters
    /// scoped to the wrong wing.
    @Test
    func deriveBranchPreservesWing() async throws {
        let (kit, handle) = try await openEstate()
        // Capture a row into the parent in a non-default wing ("User Canon").
        let frame = CaptureFrame(
            content: "wing-tagged-content",
            channel: .typed,
            room: "wing-room",
            latticeAnchor: .udc("000"),
            addedBy: "wing-integrity-test",
            embeddingModelID: "test-model-v1",
            wing: "User Canon"
        )
        _ = try await kit.capture(handle, frame)

        // Derive a branch — the snapshot copy must preserve the wing.
        let branch = try await kit.glkDeriveBranch(name: "wing-check-branch", from: handle)

        // Recall from the branch with full hydration and verify the wing is preserved.
        let recallFrame = RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .full,
            ordering: .byCaptureTimeDesc
        )
        let branchRows = try await branch.recall(recallFrame)
        let branchRow = try #require(branchRows.first(where: { $0.content == "wing-tagged-content" }),
            "Branch should contain the parent's wing-tagged row after derivation")

        // The wing is encoded in the node tree: the branch row's parentNodeId points to
        // a room node whose parent is the wing node. Verify via recall filter — recall
        // with a wing filter should surface the row.
        let wingFilterFrame = RecallFrame(
            filterChain: [.unconfirmed, .inWing("User Canon")],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
        let wingRows = try await branch.recall(wingFilterFrame)
        #expect(wingRows.contains(where: { $0.id == branchRow.id }),
            "Derived branch row must be in 'User Canon' wing — wing was dropped before this fix")
    }

    // MARK: - Test 12: promote preserves wing (ADR-016 wing-integrity, Finding A)

    /// A drawer captured into the parent in a non-default wing must land in the
    /// SAME wing after derive → capture-in-branch → promote.
    ///
    /// Specifically: rows that were already in the parent's branch snapshot are
    /// NOT promoted (only branch-new rows are). This test captures a wing-tagged
    /// row DIRECTLY INTO THE BRANCH (post-derivation) so it qualifies as a new
    /// row that glkPromoteBranch will re-capture into the parent.
    @Test
    func promoteBranchPreservesWing() async throws {
        let (kit, handle) = try await openEstate()

        // Derive an empty branch.
        let branch = try await kit.glkDeriveBranch(name: "promote-wing-branch", from: handle)

        // Capture a wing-tagged row directly into the branch (post-derivation → new row).
        let frame = CaptureFrame(
            content: "branch-wing-tagged",
            channel: .typed,
            room: "wing-room",
            latticeAnchor: .udc("000"),
            addedBy: "wing-integrity-test",
            embeddingModelID: "test-model-v1",
            wing: "User Canon"
        )
        _ = try await branch.capture(frame)

        // Promote — the new branch row should land in "User Canon" in the parent.
        try await kit.glkPromoteBranch(branch, replacing: handle)

        // Recall from the parent with a wing filter.
        let wingFilterFrame = RecallFrame(
            filterChain: [.unconfirmed, .inWing("User Canon")],
            hydrationLevel: .full,
            ordering: .byCaptureTimeDesc
        )
        let parentWingRows = try await kit.recall(handle, wingFilterFrame)
        #expect(parentWingRows.contains(where: { $0.content == "branch-wing-tagged" }),
            "Promoted branch row must land in 'User Canon' wing — wing was dropped before this fix")
    }

    // MARK: - Test 13: merge preserves wing (ADR-016 wing-integrity, Finding A)

    /// A drawer cherry-picked via glkMergeDrawers must land in its original wing
    /// in the parent estate, not the default wing.
    @Test
    func mergeDrawersPreservesWing() async throws {
        let (kit, handle) = try await openEstate()
        let branch = try await kit.glkDeriveBranch(name: "merge-wing-branch", from: handle)

        // Capture a wing-tagged row into the branch.
        let frame = CaptureFrame(
            content: "merge-wing-tagged",
            channel: .typed,
            room: "wing-room",
            latticeAnchor: .udc("000"),
            addedBy: "wing-integrity-test",
            embeddingModelID: "test-model-v1",
            wing: "User Canon"
        )
        let captured = try await branch.capture(frame)

        // Cherry-pick the row into the parent.
        _ = try await kit.glkMergeDrawers([captured.id], from: branch, into: handle)

        // Recall from the parent with a wing filter.
        let wingFilterFrame = RecallFrame(
            filterChain: [.unconfirmed, .inWing("User Canon")],
            hydrationLevel: .full,
            ordering: .byCaptureTimeDesc
        )
        let parentWingRows = try await kit.recall(handle, wingFilterFrame)
        #expect(parentWingRows.contains(where: { $0.content == "merge-wing-tagged" }),
            "Merged branch row must land in 'User Canon' wing — wing was dropped before this fix")
    }

    // MARK: - Test 14: derive preserves exportability (Finding A — field audit)

    /// A born-public drawer must remain public after derivation.
    /// Exportability is a security field — silently re-privatizing it would
    /// break recall filters scoped to exportable content.
    @Test
    func deriveBranchPreservesExportability() async throws {
        let (kit, handle) = try await openEstate()
        let frame = CaptureFrame(
            content: "born-public-content",
            channel: .typed,
            room: "pub-room",
            latticeAnchor: .udc("000"),
            addedBy: "wing-integrity-test",
            embeddingModelID: "test-model-v1",
            exportability: .public_
        )
        _ = try await kit.capture(handle, frame)

        let branch = try await kit.glkDeriveBranch(name: "exportability-branch", from: handle)

        let recallFrame = RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .full,
            ordering: .byCaptureTimeDesc
        )
        let rows = try await branch.recall(recallFrame)
        let row = try #require(rows.first(where: { $0.content == "born-public-content" }))
        #expect(row.exportability == .public_,
            "Exportability must be preserved on derive — born-public row went private before fix")
    }

    // The active-branch quota semantics (refuse past maxActiveBranches;
    // terminal branches free a slot) are covered by the fast in-memory Rust
    // test `active_branch_quota_bounds_live_branches_and_terminal_frees_a_slot`
    // in branches.rs — the logic is a byte-mirror. Reproducing it in Swift
    // would require 64 real estate-backed derivations (heavy per-derive
    // setup), exceeding the unit-test time budget, so the Swift leg is proven
    // through the parity contract rather than a duplicated slow test.
}
