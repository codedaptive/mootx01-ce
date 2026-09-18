// FingerprintLane.swift
//
// The per-item structural fingerprint lane: one `distillation-features-v1`
// SynapseKit entry keyed by the SOURCE drawer id. It is a search structure,
// not a rendering — the no-inference Hamming NN substrate read by the
// structural-fingerprint recall lane (RecallDirector Lane B), by VagueRecall,
// and by ConsolidationCycle's cluster detection.
//
// Writers: the encode rider (`wireCorpusRoomRollup`) after each drained batch
// and the hint-seeding path (`seedDefaultWings`) after it indexes a hint.
// Both call `writeStructuralFingerprint`, so the lane is populated exactly
// when a drawer becomes searchable in the corpus. ConsolidationCycle writes
// the lane for the vague items it creates through the same store call.
//
// Determinism: the fingerprint is a function of (content,
// `DistillationPipeline.defaultExtractor`) only — identical content gives an
// identical lane entry on both ports.
//
// NeuronKit is NOT a GeniusLocusKit dependency; DistillationInput and
// DistillationOutput come from SubstrateML, which IS one.

import EideticLib
import Foundation
import LocusKit
import SubstrateML
import SubstrateTypes
import SynapseKit

public extension GeniusLocusKit {

    /// The fixed SynapseKit lane for structural fingerprints. Keyed by the
    /// SOURCE drawer id. The string is a storage key shared with the Rust
    /// port (`DISTILLATION_LANE_MODEL_ID`) and with every estate already on
    /// disk, so it is never renamed.
    static var distillationLaneModelID: String { "distillation-features-v1" }

    /// The production fingerprint pipeline: the intra-item reduction with
    /// the contract-pinned default extractor. Its feature fingerprint feeds
    /// the `distillation-features-v1` lane; ConsolidationCycle also runs it
    /// over cross-item clusters and takes its rendered text.
    static var defaultDistillFn: @Sendable (SubstrateML.DistillationInput) -> DistillationOutput {
        {
            DistillationPipeline.run(
                input: $0,
                extractFeatures: DistillationPipeline.defaultExtractor,
                intraItem: true,
                renderText: false)
        }
    }

    /// Compute one drawer's structural fingerprint and replace its
    /// `distillation-features-v1` lane entry.
    ///
    /// Items with three or more sentences take the intra-item M×|V|
    /// reduction (`defaultDistillFn`) and store its OR-reduced feature
    /// fingerprint; shorter items use the `queryFingerprint` construction
    /// over the content, the same construction recall probes with. A zero
    /// fingerprint (no extracted features) writes nothing. VectorStore
    /// absence is non-fatal: the lane is simply dark, matching the estate's
    /// semantic-tier wiring.
    ///
    /// - Parameters:
    ///   - handle: the estate. Must be open.
    ///   - drawerID: the source item's drawer id.
    ///   - content: the item's text content.
    ///   - now: deterministic clock, stamped into the lane entry. Passed in,
    ///     never read here.
    /// - Returns: true when a lane entry was written.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` for a stale handle;
    ///   storage errors from the vector write.
    @discardableResult
    func writeStructuralFingerprint(
        handle: EstateHandle,
        drawerID: String,
        content: String,
        now: Date
    ) async throws -> Bool {
        guard storages[handle] != nil else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        guard !content.isEmpty, let vectorStore = vectorStores[handle] else { return false }

        // Same segmenter the corpus Chunker uses, so the reduction units are
        // consistent with the dense index.
        let sentences = EideticLib.sentences(content).map(String.init)
        let fingerprint: Fingerprint256
        if sentences.count >= 3 {
            // memoryTimestamps stays nil ON PURPOSE: one item's sentences
            // share the item's single timestamp — equal ages make
            // TypedDecayWeighting's weights cancel in the normalizer
            // (wdf ≡ df), so threading the timestamp is a mathematical no-op.
            // The decay branch is live in the CROSS-ITEM path
            // (ConsolidationCycle), which also consumes the rendered text.
            fingerprint = Self.defaultDistillFn(SubstrateML.DistillationInput(
                memoryContents: sentences,
                memoryTimestamps: nil,
                clusterID: drawerID,
                sourceIDs: [drawerID])).featureFingerprint
        } else {
            // With fewer than three units every feature has df = 1, every
            // pairwise PMI is 0 and the coherence graph fragments, so the
            // short item takes the probe construction instead.
            fingerprint = DistillationPipeline.queryFingerprint(
                query: content,
                extractFeatures: DistillationPipeline.defaultExtractor)
        }
        guard fingerprint != .zero else { return false }

        // addVector upserts on (itemID, modelID): a re-indexed drawer replaces
        // its entry rather than accumulating one per encode.
        try await vectorStore.addVector(
            itemID: drawerID,
            engram: fingerprint,
            modelID: Self.distillationLaneModelID,
            modelVersion: "1",
            filedAt: now)
        return true
    }
}

extension GeniusLocusKit {

    /// Compatibility entrypoint for complete source-preserving rendering.
    internal static func compactionRendering(of content: String) -> String {
        distilledRendering(of: content)
    }
}
