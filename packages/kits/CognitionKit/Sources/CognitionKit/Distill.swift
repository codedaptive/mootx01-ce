// Distill.swift
//
// Recipe that triggers the per-item distillation sweep on demand —
// SPEC_DISTILLATION_STORAGE §3/§7.1. Registered name: `distill`; the MCP
// surface lists it as `moot_distill`. The `moot_consolidate` name no longer
// dispatches here (§3 Phase 2); it reserves for the multi-item
// consolidation feature.
//
// Layer discipline B-1/B-2: pure sequencing. Delegates all sweep work to
// GeniusLocusKit.distillItemsSweep, which distills every active drawer
// with non-empty content whose representation is NULL (or produced under
// a stale pipeline contract) — writing the four representation columns on
// each SOURCE row plus its distillation-features-v1 lane entry (§7.2).
// No factoid drawers, no tunnels (§11).
//
// RecipeCatalog registration: present.

import Foundation
import GeniusLocusKit
import NeuronKit
import SubstrateML

/// Distill working memory: populate the on-row distilled representation
/// of every eligible item (SPEC §7.1 sweep — the `moot_distill` tool).
public struct Distill: Recipe {

    // MARK: - Input

    /// Parameters controlling the distillation sweep.
    public struct Input: Sendable {
        /// Optional cluster scope filter — accepted for API stability, intentionally
        /// unused by the per-item sweep.
        ///
        /// Why not implemented: the sweep reduces EACH stored item from its OWN
        /// sentences. A cluster filter would restrict which items are swept; that
        /// restriction belongs to the sweep layer (GLK), whose current contract is
        /// estate-wide. When a scoped sweep is added to GLK, this parameter will
        /// wire through. Until then it is accepted so callers can pass it without
        /// breakage.
        ///
        /// Parity: Rust `DistillInput.cluster_id` carries the same no-op contract.
        public let clusterID: String?

        /// When `true`, include held/withdrawn items in the sweep. Accepted for
        /// API stability; intentionally unused (the sweep skips only tombstoned
        /// rows today). Parity: Rust `DistillInput.include_held`.
        public let includeHeld: Bool

        public init(clusterID: String? = nil, includeHeld: Bool = false) {
            self.clusterID = clusterID
            self.includeHeld = includeHeld
        }
    }

    // MARK: - Output

    /// Result of the distillation sweep.
    public struct Output: Sendable {
        /// Count of drawer rows whose representation columns were populated
        /// this sweep (SPEC §3 — factoid drawers no longer exist, so the
        /// production metric is items distilled).
        public let itemsDistilled: Int

        public init(itemsDistilled: Int) {
            self.itemsDistilled = itemsDistilled
        }
    }

    // MARK: - Recipe metadata

    public let name = "distill"
    public let version = "2.0.0"
    public let description =
        "Distill working memory: populate the on-row distilled representation "
        + "(token-economical prose) of every active item whose representation "
        + "is missing or stale. Idempotent by the NULL predicate."

    // The sweep runs the p1 contract (GeniusLocusKit.defaultDistillFn — the
    // intra-item pipeline with the contract-pinned default extractor, which
    // is deterministic and bit-identical on both legs). No external
    // capability gate.
    public let requiredCapabilities: [NeuronKitCapability] = []

    public init() {}

    // MARK: - run

    public func run(
        input: Input,
        estate: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Output {
        try await run(input: input, estate: estate, kit: kit, now: Date())
    }

    /// Internal overload with an explicit clock so tests stamp
    /// `distilled_at` deterministically. Production callers use the public
    /// overload (the recipe boundary is where wall-clock "now" enters).
    ///
    /// The distillation function is NOT injectable here: the p1 contract
    /// (§5.3 rule 6) pins ONE function — `GeniusLocusKit.defaultDistillFn`
    /// — for every production write path, so sweep and drain-stage
    /// renderings are byte-identical. Test scaffolds that need a stub
    /// register it on the kit via `registerDistillationFunction` and call
    /// `distillItemsSweep` directly.
    func run(
        input: Input,
        estate: EstateHandle,
        kit: GeniusLocusKit,
        now: Date
    ) async throws -> Output {
        // input.clusterID and input.includeHeld are intentional no-ops at
        // this layer: accepted for API stability; the sweep is estate-wide.
        // See Input for the full rationale.
        let itemsDistilled = try await kit.distillItemsSweep(
            handle: estate,
            distillFn: GeniusLocusKit.defaultDistillFn,
            now: now,
            limit: nil
        )
        return Output(itemsDistilled: itemsDistilled)
    }
}
