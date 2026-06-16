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

    // MARK: - Test 6: discarded branch recall still works (audit trail preserved)

    /// Rows captured before discard remain accessible in a discarded branch.
    @Test
    func discardedBranchRecallPreservesAuditTrail() async throws {
        let (kit, handle) = try await openEstate()
        let branch = try await kit.glkDeriveBranch(name: "audit-branch", from: handle)

        let branchFrame = CaptureFrame(
            content: "audit-preserved-content",
            channel: .typed,
            room: "branch-tests",
            latticeAnchor: .udc("000"),
            addedBy: "branch-tests",
            embeddingModelID: "test-model-v1"
        )
        let stored = try await branch.capture(branchFrame)

        try await branch.discard()
        #expect(branch.status == .discarded)

        let recallFrame = RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
        let branchRows = try await branch.recall(recallFrame)
        #expect(branchRows.contains(where: { $0.id == stored.id }),
            "Discarded branch must preserve audit trail — rows must remain recall-able")
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
}
