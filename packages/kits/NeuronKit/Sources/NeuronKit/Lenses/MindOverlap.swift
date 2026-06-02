import SubstrateML
import SubstrateTypes

// MindOverlap — privacy-preserving estate overlap (SPEC § 7.7, Lens 9
// Federated): the NeuronKit reasoning surface over SubstrateML's
// DP-OR-reduce. Each estate reduces its fingerprints to ONE
// differentially-private aggregate; the two aggregates are compared.
// Neither side's individual memories are ever touched by the
// comparison — only the DP summaries, which is exactly what would
// cross a federation boundary. "Where two minds converge vs diverge,
// computed without either reading the other's content" — the moat.
// Surfaces the gated DP-OR-reduce + Hamming math; owns no math (I-17).
// CognitionKit sequences it (fingerprint each estate under a SHARED
// hyperplane family so the aggregates are comparable, then call these).

extension NeuronKit {
    /// Reduce a fingerprint set to one differentially-private
    /// OR-aggregate — the only artifact that need cross a federation
    /// boundary. Deterministic for a fixed `seed` (so two estates
    /// seeded alike produce comparable noise).
    public static func dpSummary(
        fingerprints: [Fingerprint256],
        epsilon: Double,
        delta: Double,
        kAnonymity: Int,
        seed: UInt64
    ) -> Fingerprint256 {
        DPORReduction.reduce(
            fingerprints: fingerprints,
            params: DPParameters(epsilon: epsilon, delta: delta, kAnonymity: kAnonymity),
            rngSeed: seed)
    }

    /// Overlap between two DP summaries: `1 − normalized Hamming` over
    /// the content blocks (structure 0, concept 1, channel 3) — 192
    /// bits. 1.0 = identical aggregates (convergent minds); → 0 as they
    /// diverge. Computed on the summaries ONLY — neither estate's
    /// individual fingerprints are read here.
    ///
    /// Block 2 (lineage-temporal) is DELIBERATELY excluded: it encodes
    /// per-row identity (a random lineage id per drawer), so it differs
    /// even between two estates holding the very same memory —
    /// comparing it across estates is both meaningless and
    /// nondeterministic. Cross-estate overlap is about what the estates
    /// are ABOUT and how they're structured, not which rows they minted.
    public static func summaryOverlap(
        _ a: Fingerprint256, _ b: Fingerprint256
    ) -> Double {
        let contentBlocks: Set<Int> = [
            FingerprintBlock.structure.rawValue,
            FingerprintBlock.concept.rawValue,
            FingerprintBlock.channel.rawValue,
        ]
        let hamming = PartialStateRecall.hammingBlocks(a, b, blocks: contentBlocks)
        return 1.0 - (Double(hamming) / 192.0)
    }
}
