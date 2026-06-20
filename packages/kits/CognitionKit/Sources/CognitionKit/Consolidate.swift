// Consolidate.swift
//
// Recipe that triggers a per-item distillation sweep on demand.
// Used by moot_consolidate tool and at session boundaries.
//
// Layer discipline B-1/B-2: pure sequencing. Delegates all sweep work to
// GeniusLocusKit.distillItemsSweep, which iterates active not-yet-distilled
// items, applies the injected distillFn, and captures factoid drawers.
//
// GLK call:
//   kit.distillItemsSweep(handle:distillFn:now:limit:)
//      → sweeps active, not-yet-distilled items. Runs distillFn per eligible
//        item, captures factoid drawers in "_distilled", writes _distilled_from
//        tunnels. Returns factoid count (Int).
//
// RecipeCatalog registration: deferred to the Dc4 mission.

import Foundation
import GeniusLocusKit
import NeuronKit
import SubstrateML

/// Compact working memory by distilling active items into factoids on demand.
///
/// Calls GeniusLocusKit's per-item distillation sweep, which processes active
/// not-yet-distilled items long enough to form a usable intra-item feature
/// matrix, runs the distillation pipeline per item, and persists produced
/// factoids as ordinary drawers in room `_distilled`.
///
/// Named `consolidate` for use as `moot_consolidate` in AriaMcpKit.
public struct Consolidate: Recipe {

    // MARK: - Input

    /// Parameters controlling the consolidation sweep.
    public struct Input: Sendable {
        /// Reserved for future per-item filtering (e.g. limit by room or tag).
        /// Currently unused — the sweep processes all eligible items.
        public let clusterID: String?

        /// Reserved for future use. Currently unused in the per-item model.
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

        public init(factoidsProduced: Int) {
            self.factoidsProduced = factoidsProduced
        }
    }

    // MARK: - Recipe metadata

    public let name = "consolidate"
    public let version = "1.0.0"
    public let description =
        "Compact working memory by distilling active items into factoids. " +
        "Calls the GLK per-item distillation sweep, which processes all " +
        "eligible items and persists each factoid as a drawer in room `_distilled`."

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
        // (the intra-item model — distillation §1, sub-quadratic sparse
        // selection over one corpus). Sweeps active, not-yet-distilled items
        // and produces one factoid per item that carries enough intra-item
        // recurrence (M ≥ 3 sentences, non-zero dominant component F*).
        let factoidsProduced = try await kit.distillItemsSweep(
            handle: estate,
            distillFn: distillFn,
            now: now,
            limit: nil
        )

        return Output(factoidsProduced: factoidsProduced)
    }
}
