// BranchOps.swift
//
// Thin NeuronKit wrappers over the GeniusLocusKit actor's COW branch
// verbs (NEURONKIT_SPEC § 4.3). NeuronKit owns no branch state — it
// never stores (spec B-1); it forwards to the GLK actor, which is the
// mechanical layer that holds the branch registry and substrate.
// Keeping these as one-line forwards is deliberate: the substrate's
// invariants (parent never modified — I-15/C-10) live in GLK, and a
// fatter wrapper here would be a second place those guarantees could
// drift from.

import Foundation
import GeniusLocusKit
import LocusKit

public extension NeuronKit {

    /// Derive a COW branch of `estate`. Forwards to
    /// `GeniusLocusKit.glkDeriveBranch`. The parent is never modified
    /// (spec I-15 / C-10) — the guarantee lives in the substrate, not
    /// in this wrapper.
    ///
    /// - Returns: an active `BranchHandle` with `lineageDepth == 1`.
    static func deriveBranch(
        name: String,
        from estate: EstateHandle,
        in kit: GeniusLocusKit
    ) async throws -> any BranchHandle {
        try await kit.glkDeriveBranch(name: name, from: estate)
    }

    /// Promote `branch` into `estate`, transitioning it to `.won`.
    /// Forwards to `GeniusLocusKit.glkPromoteBranch`.
    static func promoteBranch(
        _ branch: any BranchHandle,
        replacing estate: EstateHandle,
        in kit: GeniusLocusKit
    ) async throws {
        try await kit.glkPromoteBranch(branch, replacing: estate)
    }

    /// Cherry-pick `drawerIDs` from `branch` into `estate`.
    /// Forwards to `GeniusLocusKit.glkMergeDrawers`.
    ///
    /// - Returns: a `MergeReport` whose `merged` lists the requested IDs
    ///   that were present in the branch; absent IDs land in `skipped`.
    @discardableResult
    static func mergeDrawers(
        _ drawerIDs: [DrawerID],
        from branch: any BranchHandle,
        into estate: EstateHandle,
        in kit: GeniusLocusKit
    ) async throws -> MergeReport {
        try await kit.glkMergeDrawers(drawerIDs, from: branch, into: estate)
    }
}
