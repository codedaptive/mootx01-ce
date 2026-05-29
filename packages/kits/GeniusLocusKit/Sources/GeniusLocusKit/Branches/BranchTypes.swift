import Foundation
import LocusKit

// MARK: - Branch identity

/// Unique identifier for a COW branch. Minted by `glkDeriveBranch` and
/// opaque to callers; stable for the lifetime of the branch.
public typealias BranchID = UUID

/// Drawer identifier — mirrors `RowID` from LocusKit, promoted to its own
/// alias so branch-surface APIs name their parameter types explicitly.
public typealias DrawerID = RowID

// MARK: - BranchStatus

/// Lifecycle state of a COW branch.
///
/// Valid transitions: `.active → .won | .merged | .discarded`.
/// All terminal states preserve the branch estate's rows for audit
/// trail access (spec I-15 — parent is never modified; audit trail
/// is retained even after a branch reaches a terminal state).
public enum BranchStatus: String, Sendable, Codable, Equatable {
    /// Branch is open and accepting captures.
    case active
    /// Branch was fully promoted into the parent via `glkPromoteBranch`.
    case won
    /// One or more drawers were selectively merged into the parent
    /// via `glkMergeDrawers`.
    case merged
    /// Branch was discarded without any promotion.
    case discarded
}

// MARK: - BranchScore

/// Scoring metadata for a branch — used by the Brain layer to rank
/// competing branches before promotion. Fields are advisory; the
/// substrate does not enforce or derive them automatically.
public struct BranchScore: Sendable {
    /// A 0.0–1.0 score reflecting the net signal quality of drawers
    /// in the branch relative to those in the parent.
    public let quality: Double
    /// Count of drawers present in the branch but not the parent.
    public let newDrawerCount: Int

    public init(quality: Double, newDrawerCount: Int) {
        self.quality = quality
        self.newDrawerCount = newDrawerCount
    }
}

// MARK: - DifferentialReport

/// Report describing how a branch's content differs from its parent
/// over a given time period. Produced by `BranchHandle.compareToParent`.
public struct DifferentialReport: Sendable {
    /// Branch-estate IDs of drawers added after the branch was derived —
    /// present in the branch but not in the derivation snapshot.
    public let newInBranch: [DrawerID]
    /// Branch-estate IDs of drawers whose content has been modified
    /// since derivation. Not tracked in the current implementation;
    /// always empty (modification detection requires content hashing,
    /// which ships in a later sub-mission).
    public let modifiedInBranch: [DrawerID]
    /// Snapshot IDs of drawers that were copied at derivation but are
    /// no longer present in the branch.
    public let withdrawnInBranch: [DrawerID]
    /// Time window this report covers.
    public let period: DateInterval

    public init(
        newInBranch: [DrawerID],
        modifiedInBranch: [DrawerID],
        withdrawnInBranch: [DrawerID],
        period: DateInterval
    ) {
        self.newInBranch = newInBranch
        self.modifiedInBranch = modifiedInBranch
        self.withdrawnInBranch = withdrawnInBranch
        self.period = period
    }
}

// MARK: - MergeReport

/// Report returned by `glkMergeDrawers` describing the outcome of a
/// selective merge from a branch into the parent estate.
public struct MergeReport: Sendable {
    /// Branch-estate IDs of drawers that were successfully merged into
    /// the parent. A new drawer is created in the parent for each; the
    /// branch-estate ID is preserved here for correlation.
    public let merged: [DrawerID]
    /// Branch-estate IDs of drawers that could not be merged due to
    /// conflicts with existing parent content. Reserved for future use;
    /// always empty in the current implementation.
    public let conflicts: [DrawerID]
    /// Branch-estate IDs that were requested but skipped — not found
    /// in the branch or already in a terminal state.
    public let skipped: [DrawerID]

    public init(merged: [DrawerID], conflicts: [DrawerID], skipped: [DrawerID]) {
        self.merged = merged
        self.conflicts = conflicts
        self.skipped = skipped
    }
}
