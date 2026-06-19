// Consolidate.swift
//
// Recipe that triggers a distillation sweep on demand.
// Used by moot_consolidate tool and at session boundaries.
//
// Layer discipline B-1/B-2: pure sequencing. Delegates all sweep work to
// GeniusLocusKit.runDistillationSweep, which owns the cluster query, the
// per-cluster distillation loop, and all storage mutations.
//
// GLK call sequence (one call):
//   1. kit.runDistillationSweep(handle:distillFn:now:)
//      → queries open clusters with member_count ≥ 3, runs distillFn per
//        cluster, captures factoid drawers, writes _distilled_from tunnels,
//        updates cluster status rows.
//      → returns factoid count (Int)
//
// API gap note: the spec references runDistillationCycle(estate:clusterID:
// includeHeld:). DG5 implemented runDistillationSweep(handle:distillFn:now:),
// which sweeps all eligible open clusters and does not accept per-cluster
// filtering or includeHeld. The Input fields clusterID and includeHeld are
// accepted but cannot be forwarded until a future GLK enhancement surfaces
// that capability. heldClusterIDs and failedClusterIDs are not queryable via
// the current public GLK API and return [] until that surface lands.
//
// RecipeCatalog registration: deferred to the Dc4 mission.

import Foundation
import GeniusLocusKit
import SubstrateML

/// Compact working memory by distilling open clusters into factoids on demand.
///
/// Calls GeniusLocusKit's distillation sweep, which processes all open clusters
/// with member_count ≥ 3, runs the distillation pipeline per cluster, and
/// persists produced factoids as ordinary drawers in room `_distilled`.
///
/// Named `consolidate` for use as `moot_consolidate` in AriaMcpKit.
public struct Consolidate: Recipe {

    // MARK: - Input

    /// Parameters controlling the consolidation sweep.
    public struct Input: Sendable {
        /// Target a specific cluster by UUID. `nil` sweeps all ready clusters.
        ///
        /// Note: per-cluster targeting is accepted as input but the current GLK
        /// sweep API processes all eligible open clusters. Single-cluster
        /// targeting requires a future GLK API enhancement.
        public let clusterID: String?

        /// When `true`, include SNR-gated held clusters in the sweep.
        ///
        /// Note: GLK's runDistillationSweep currently sweeps only `status = open`
        /// clusters. includeHeld is accepted but does not yet alter GLK behaviour.
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

        /// Cluster UUIDs that were gated by the SNR threshold (status = held).
        ///
        /// Returned as [] until GLK exposes a public cluster status query API.
        public let heldClusterIDs: [String]

        /// Cluster UUIDs that failed distillation (confidence below threshold
        /// or pipeline error).
        ///
        /// Returned as [] until GLK exposes a public cluster status query API.
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

    // The sweep uses DistillationPipeline (SubstrateML) directly — no NeuronKit
    // reasoning calls. requiredCapabilities is empty.
    public let requiredCapabilities: [NeuronKitCapability] = []

    public init() {}

    // MARK: - run

    public func run(
        input: Input,
        estate: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Output {
        // The distillFn bridges CognitionKit to SubstrateML: wraps
        // DistillationPipeline.run with the capitalization-heuristic stub
        // extractor (test-safe, no EideticLib dependency). Production callers
        // can supply the HMM tagger via Input in a future enhancement.
        let distillFn: @Sendable (DistillationInput) -> DistillationOutput = {
            DistillationPipeline.run(
                input: $0,
                extractFeatures: DistillationPipeline.defaultExtractor)
        }

        // Operational recipe: `now` is the wall-clock time of this sweep.
        // Correct semantic — factoid filed_at and cluster updated_at should
        // reflect when the sweep actually ran, not a caller-supplied timestamp.
        let now = Date()

        let factoidsProduced = try await kit.runDistillationSweep(
            handle: estate,
            distillFn: distillFn,
            now: now)

        // heldClusterIDs and failedClusterIDs cannot be queried via the current
        // public GLK API; returned as [] until GLK surfaces cluster status reads.
        return Output(
            factoidsProduced: factoidsProduced,
            heldClusterIDs: [],
            failedClusterIDs: [])
    }
}
