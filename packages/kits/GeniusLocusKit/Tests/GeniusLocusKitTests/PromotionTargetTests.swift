import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

/// Branch promotion target guard — Mission FUP-D (E-2).
///
/// AUDIT-01 Zone E flagged that `glkPromoteBranch`/`glkMergeDrawers` did not
/// check that the destination estate is the branch's parent. Cross-estate
/// promotion was silent; with per-estate keys this lets content cross an
/// estate (and key) boundary unnoticed. These tests pin the guard: promoting
/// or merging a branch into a non-parent estate throws
/// `invalidPromotionTarget`; the legitimate parent promotion still succeeds.
@Suite("Branch promotion target guard")
struct PromotionTargetTests {

    // MARK: - Helpers

    /// Open a fresh estate through GeniusLocusKit backed by in-memory storage.
    private func openEstate(in kit: GeniusLocusKit, owner: String) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let credentials = OwnerCredentials(ownerIdentifier: owner)
        _ = try await LocusKit.Estate.create(storage: storage, owner: credentials)
        return try await kit.open(storage: storage, owner: credentials)
    }

    private func captureOne(kit: GeniusLocusKit, handle: EstateHandle, content: String) async throws -> Drawer {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "promotion-target-tests",
            latticeAnchor: .udc("000"),
            addedBy: "promotion-target-tests",
            embeddingModelID: "test-model-v1"
        )
        return try await kit.capture(handle, frame)
    }

    private func captureInBranch(_ branch: any BranchHandle, content: String) async throws -> Drawer {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "promotion-target-tests",
            latticeAnchor: .udc("000"),
            addedBy: "promotion-target-tests",
            embeddingModelID: "test-model-v1"
        )
        return try await branch.capture(frame)
    }

    private func recallAll(kit: GeniusLocusKit, handle: EstateHandle) async throws -> [Drawer] {
        // `.full` hydration required: callers check `row.content` to verify
        // which rows landed in the estate after promotion/merge. Per spec § 7.3,
        // `.structured` returns `content = ""` (no blob reads), so only `.full`
        // loads content bodies for content-equality assertions.
        let frame = RecallFrame(
            filterChain: [.userConfirmed],
            hydrationLevel: .full,
            ordering: .byCaptureTimeDesc
        )
        return try await kit.recall(handle, frame)
    }

    // MARK: - E-2: promotion into a non-parent estate is rejected

    /// Promoting a branch derived from estate A into a different estate B must
    /// throw `invalidPromotionTarget` — content must not silently cross estates.
    @Test
    func promoteIntoNonParentEstateThrows() async throws {
        let kit = GeniusLocusKit()
        let handleA = try await openEstate(in: kit, owner: "estate-A")
        let handleB = try await openEstate(in: kit, owner: "estate-B")

        let branch = try await kit.glkDeriveBranch(name: "cross-estate-branch", from: handleA)
        _ = try await captureInBranch(branch, content: "branch-row-A")

        do {
            try await kit.glkPromoteBranch(branch, replacing: handleB)
            Issue.record("expected glkPromoteBranch into a non-parent estate to throw invalidPromotionTarget")
        } catch let error as GeniusLocusKitError {
            guard case .invalidPromotionTarget = error else {
                Issue.record("expected GeniusLocusKitError.invalidPromotionTarget, got \(error)")
                return
            }
        }

        // Estate B must not have received the cross-estate content.
        let bRows = try await recallAll(kit: kit, handle: handleB)
        #expect(!bRows.contains(where: { $0.content == "branch-row-A" }),
            "rejected promotion must not leak branch content into the non-parent estate")
    }

    /// Cherry-pick merge into a non-parent estate must likewise throw.
    @Test
    func mergeIntoNonParentEstateThrows() async throws {
        let kit = GeniusLocusKit()
        let handleA = try await openEstate(in: kit, owner: "estate-A")
        let handleB = try await openEstate(in: kit, owner: "estate-B")

        let branch = try await kit.glkDeriveBranch(name: "cross-estate-merge", from: handleA)
        let row = try await captureInBranch(branch, content: "branch-row-to-merge")

        do {
            _ = try await kit.glkMergeDrawers([row.id], from: branch, into: handleB)
            Issue.record("expected glkMergeDrawers into a non-parent estate to throw invalidPromotionTarget")
        } catch let error as GeniusLocusKitError {
            guard case .invalidPromotionTarget = error else {
                Issue.record("expected GeniusLocusKitError.invalidPromotionTarget, got \(error)")
                return
            }
        }

        let bRows = try await recallAll(kit: kit, handle: handleB)
        #expect(!bRows.contains(where: { $0.content == "branch-row-to-merge" }),
            "rejected merge must not leak branch content into the non-parent estate")
    }

    // MARK: - Legitimate parent promotion still succeeds

    /// Promoting a branch back into the estate it was derived from is the
    /// legitimate path and must continue to succeed.
    @Test
    func legitimateParentPromotionSucceeds() async throws {
        let kit = GeniusLocusKit()
        let handleA = try await openEstate(in: kit, owner: "estate-A")
        _ = try await captureOne(kit: kit, handle: handleA, content: "original-parent-row")

        let branch = try await kit.glkDeriveBranch(name: "legit-branch", from: handleA)
        _ = try await captureInBranch(branch, content: "branch-row-that-promotes")

        try await kit.glkPromoteBranch(branch, replacing: handleA)

        let aRows = try await recallAll(kit: kit, handle: handleA)
        #expect(aRows.contains(where: { $0.content == "branch-row-that-promotes" }),
            "legitimate parent promotion must land the branch row in the parent estate")
        #expect(branch.status == .won)
    }

    /// The legitimate parent merge path must also continue to succeed.
    @Test
    func legitimateParentMergeSucceeds() async throws {
        let kit = GeniusLocusKit()
        let handleA = try await openEstate(in: kit, owner: "estate-A")

        let branch = try await kit.glkDeriveBranch(name: "legit-merge", from: handleA)
        let picked = try await captureInBranch(branch, content: "picked-row")

        let report = try await kit.glkMergeDrawers([picked.id], from: branch, into: handleA)

        #expect(report.merged.contains(picked.id))
        let aRows = try await recallAll(kit: kit, handle: handleA)
        #expect(aRows.contains(where: { $0.content == "picked-row" }),
            "legitimate parent merge must land the picked row in the parent estate")
        #expect(branch.status == .merged)
    }
}
