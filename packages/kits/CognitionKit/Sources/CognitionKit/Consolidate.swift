// Consolidate.swift
//
// Recipe that triggers a distillation sweep on demand.
// Used by moot_consolidate tool and at session boundaries.
//
// Layer discipline B-1/B-2: pure sequencing. Delegates all sweep work to
// GeniusLocusKit.runDistillationSweep, which owns the cluster query, the
// per-cluster distillation loop, and all storage mutations.
//
// GLK call sequence:
//   1. kit.runDistillationSweep(handle:distillFn:now:clusterID:includeHeld:)
//      → queries clusters by status (open; optionally also held), optionally
//        filtered to a single clusterID. Runs distillFn per eligible cluster,
//        captures factoid drawers, writes _distilled_from tunnels, updates
//        cluster status rows. Returns factoid count (Int).
//   2. kit.heldClusterIDs(handle:)   — queries memory_clusters status='held'
//   3. kit.failedClusterIDs(handle:) — queries memory_clusters status='failed'
//      → populate Output.heldClusterIDs and Output.failedClusterIDs.
//
// RecipeCatalog registration: deferred to the Dc4 mission.

import Foundation
import GeniusLocusKit
import NeuronKit
import SubstrateML

/// Compact working memory by distilling open clusters into factoids on demand.
///
/// Calls GeniusLocusKit's distillation sweep, which processes eligible clusters
/// (member_count ≥ 3, status = open; or also held when `includeHeld` is true),
/// runs the distillation pipeline per cluster, and persists produced factoids as
/// ordinary drawers in room `_distilled`.
///
/// Named `consolidate` for use as `moot_consolidate` in AriaMcpKit.
public struct Consolidate: Recipe {

    // MARK: - Input

    /// Parameters controlling the consolidation sweep.
    public struct Input: Sendable {
        /// Target a specific cluster by UUID. `nil` sweeps all ready clusters.
        public let clusterID: String?

        /// When `true`, include SNR-gated held clusters in the sweep so they
        /// get another distillation attempt now that more members may have arrived.
        public let includeHeld: Bool

        public init(clusterID: String? = nil, includeHeld: Bool = false) {
            self.clusterID = clusterID
            self.includeHeld = includeHeld
        }
    }

    // MARK: - Output

    /// Result of the consolidation sweep.
    public struct Output: Sendable {
        /// Number of distilled factoid drawers produced this sweep.
        public let factoidsProduced: Int

        /// Cluster UUIDs with `status = 'held'` after the sweep — those that
        /// were gated by the SNR threshold (SNR < 2.0).
        public let heldClusterIDs: [String]

        /// Cluster UUIDs with `status = 'failed'` after the sweep — those where
        /// confidence fell below the 0.4 threshold or a pipeline error occurred.
        public let failedClusterIDs: [String]

        public init(
            factoidsProduced: Int,
            heldClusterIDs: [String],
            failedClusterIDs: [String]
        ) {
            self.factoidsProduced = factoidsProduced
            self.heldClusterIDs = heldClusterIDs
            self.failedClusterIDs = failedClusterIDs
        }
    }

    // MARK: - Recipe metadata

    public let name = "consolidate"
    public let version = "1.0.0"
    public let description =
        "Compact working memory by distilling open clusters into factoids. " +
        "Calls the GLK distillation sweep, which processes all ready clusters " +
        "(member_count ≥ 3, status = open) and persists each factoid as a " +
        "drawer in room `_distilled`."

    // The sweep routes through NeuronKit.distillCluster (one door), which uses
    // the production HMM-tagger feature extractor. requiredCapabilities is empty:
    // the HMM extractor is deterministic and needs no external capability gate.
    public let requiredCapabilities: [NeuronKitCapability] = []

    public init() {}

    // MARK: - run

    public func run(
        input: Input,
        estate: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Output {
        try await run(input: input, estate: estate, kit: kit,
                      extractFeatures: NeuronKit.hmmFeatureExtractor,
                      now: Date())
    }

    /// Internal overload that accepts an explicit feature extractor and optional clock value.
    ///
    /// `now` is threaded in as a parameter so the sweep's `filed_at` and
    /// `updated_at` timestamps are deterministic in tests. Defaults to `Date()`
    /// when callers (e.g. integration tests) do not need deterministic timestamps.
    ///
    /// This seam exists for test isolation: CognitionKit integration tests inject
    /// `DistillationPipeline.defaultExtractor` and a fixed `now` so their fixture
    /// sentences produce deterministic outputs independent of the HMM tagger's SNR
    /// response to synthetic sentences. Production callers always use the public
    /// `run` overload, which wires `NeuronKit.hmmFeatureExtractor` and `Date()`.
    func run(
        input: Input,
        estate: EstateHandle,
        kit: GeniusLocusKit,
        extractFeatures: @escaping DistillationPipeline.FeatureExtractor,
        now: Date = Date()
    ) async throws -> Output {
        // One extractor, one door: the caller-supplied extractor (production:
        // NeuronKit.hmmFeatureExtractor) is passed to DistillationPipeline.run.
        // GLK requires a distillFn of type (DistillationInput → DistillationOutput).
        //
        // DistillationOutput does not expose a public initialiser, so we cannot
        // construct it here from NeuronKit.distillCluster's lens result —
        // DistillationPipeline.run is the correct seam for GLK integration.
        // Intra-item distillation: each stored item is reduced from its own
        // sentences. intraItem:true turns off the cross-memory consensus
        // machinery (SNR "wait for growth" hold, PMI single-theme pruning) that
        // would otherwise discard a single item's recurring content.
        let distillFn: @Sendable (DistillationInput) -> DistillationOutput = {
            DistillationPipeline.run(input: $0, extractFeatures: extractFeatures, intraItem: true)
        }

        // Per-item distillation: each stored item is reduced from its OWN chunks
        // (the corrected intra-item model — distillation §1, sub-quadratic sparse
        // selection over one corpus). This does NOT read memory_clusters; it
        // sweeps active, not-yet-distilled items and produces one factoid per
        // item that carries enough intra-item recurrence. Cross-memory clustering
        // is not the distillation grain — held/failed cluster lists no longer
        // apply, so they are empty.
        let factoidsProduced = try await kit.distillItemsSweep(
            handle: estate,
            distillFn: distillFn,
            now: now,
            limit: nil
        )

        return Output(
            factoidsProduced: factoidsProduced,
            heldClusterIDs: [],
            failedClusterIDs: []
        )
    }
}
