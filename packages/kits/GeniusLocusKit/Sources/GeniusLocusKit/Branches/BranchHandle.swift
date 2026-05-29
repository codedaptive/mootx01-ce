import Foundation
import LocusKit

/// Read-write handle to a COW branch estate.
///
/// A branch is a logical copy of a parent estate at derivation time.
/// The parent is NEVER modified by any branch operation — spec invariant
/// I-15. Rows captured into a branch are isolated until explicitly
/// promoted into the parent via `glkPromoteBranch` or
/// `glkMergeDrawers` on the `GeniusLocusKit` verb surface.
///
/// Conforming types are `AnyObject` (reference semantics) so that
/// multiple callers sharing the same handle observe consistent status
/// transitions without copying.
public protocol BranchHandle: Sendable, AnyObject {

    /// Stable identifier minted at derivation time.
    var branchID: BranchID { get }

    /// Human-readable label supplied by the caller at derivation.
    var name: String { get }

    /// Current lifecycle status. Synchronous — the concrete
    /// implementation backs this with a lock rather than actor
    /// isolation so callers in any concurrency context can read it
    /// without `await`.
    var status: BranchStatus { get }

    /// Generation depth: 1 for a branch derived directly from an
    /// estate handle, 2 for a branch derived from another branch, etc.
    var lineageDepth: Int { get }

    /// Capture a new drawer into this branch estate only.
    ///
    /// - Returns: the stored `Drawer` with a generated ID.
    /// - Throws: if the underlying estate write fails.
    func capture(_ frame: CaptureFrame) async throws -> Drawer

    /// Recall drawers from this branch estate.
    ///
    /// Drains the underlying `RecallStream` fully and returns a
    /// materialized array — matching the shape of `GeniusLocusKit.recall`.
    func recall(_ frame: RecallFrame) async throws -> [Drawer]

    /// Transition this branch to `.discarded`.
    ///
    /// After discarding, `recall` still works (rows are retained for
    /// audit trail purposes, satisfying I-15's no-data-loss posture).
    func discard() async throws

    /// Compare this branch to its parent over the supplied interval.
    ///
    /// - Returns: a `DifferentialReport` listing drawers added,
    ///   modified, or withdrawn in the branch since derivation.
    func compareToParent(over interval: DateInterval) async throws -> DifferentialReport
}
