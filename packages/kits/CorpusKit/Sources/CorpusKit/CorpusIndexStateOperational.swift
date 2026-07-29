// CorpusIndexStateOperational.swift
//
// Operational bitmap layout and accessors for corpus_index_state.
//
// ## Design tenet
//
// Every new per-row boolean or small-enum lifecycle flag on
// corpus_index_state enters as a bit allocation here. No new column is
// added to the schema once this column exists; the 64-bit growth reserve
// absorbs new flags at zero schema-migration cost. This is the same
// discipline LocusKit's Drawer.operationalBitmap applies across hundreds
// of content rows — open bitmap space means features without migration
// overhead.
//
// ## Bit layout (see also CorpusKit/docs/BITMAP_LAYOUT.md)
//
// bit  0     removed            — content is soft-deleted; derived state cleared.
// bit  1     has_dense_text     — corpus_documents.dense_text IS NOT NULL.
// bit  2     lexically_indexed  — BM25 checkpoint exists for this content.
// bit  3     RESERVED           — passages participation (CORPUSKIT_STANDALONE_PASSAGES).
// bits 4–11  coverage_mask      — 8-bit slot mask; bit (4+K) = slot K covered.
// bits 12–15 basis_generation   — 4-bit global-generation stamp; mismatch = uncovered.
// bits 16–63 RESERVED           — growth reserve; extend BITMAP_LAYOUT.md before use.
//
// ## Coverage mask registry (modelID → coverage-mask bit offset K, bit position = 4+K)
//
// K=0  corpus-ri-v1         (RandomIndexing)
// K=1  corpus-ppmi-v1       (PPMI)
// K=2  corpus-lsa-v1        (LSA)
// K=3  corpus-nmf-v1        (NMF)
// K=4  corpus-fdc-v1        (FDC)
// K=5  corpus-deterministic (Deterministic / FloatSimHash)
// K=6  RESERVED             (miniLM)
// K=7  RESERVED             (mpNet / embeddingGemma / nlEmbedding / nlContextual)
//
// Slots beyond K=7 fall back to the corpus_provider_coverage side table
// (hybrid: bitmap-accelerated for the common 8 slots, table-backed for overflow).
//
// ## Basis generation semantics
//
// The global generation counter (0–15) is stored in corpus_bitmap_generation.
// Each basis retrain increments it. A content row's coverage_mask is valid
// ONLY when its 4-bit basis_generation matches the current global generation;
// a mismatch reads as "uncovered" (no estate-wide write on retrain).
// Lazy rewrite: when backfill re-covers a content row under the new basis,
// it stamps the new coverage bits AND the new generation in the same
// transaction. Wraparound at 16: a rare full-sweep clears all coverage bits
// and resets all generation stamps to 0 (see CoverageSweep in BITMAP_LAYOUT.md).
//
// Rust twin: rust/src/index_state_operational.rs

import SubstrateKernel

// MARK: - Bit constants

/// Bit 0: content is soft-deleted. Derived state (BM25, vectors, coverage)
/// has been cleared. Set by the engine's remove path; cleared on re-ingest.
/// The corpus_index_state row is RETAINED as a tombstone so the active-content
/// filter (WHERE removed = 0) can distinguish removed from never-indexed rows.
internal let indexBitRemoved: Int64 = 1 << 0

/// Bit 1: corpus_documents.dense_text IS NOT NULL for this content row.
/// Cross-table cache — maintained by the engine in the same write path that
/// sets or clears dense_text on corpus_documents. Skew-impossible: the engine
/// orchestrates both stores and both writes travel together.
internal let indexBitHasDenseText: Int64 = 1 << 1

/// Bit 2: content has been structurally indexed (BM25 checkpoint exists).
/// Set in the same transaction as the index-state checkpoint advance;
/// cleared (to 0) when the remove path soft-deletes the row.
/// The feedCursorRowID sentinel row always carries this bit = 0.
internal let indexBitLexicallyIndexed: Int64 = 1 << 2

// Bit 3 is RESERVED for passages participation (CORPUSKIT_STANDALONE_PASSAGES).
// Do not allocate until that feature compiles into this build.

/// Coverage-mask field: 8 bits at positions 4–11 (one bit per registered slot).
/// Bit (4 + K) is set when slot K has been covered under the current basis
/// generation. See the registry in BITMAP_LAYOUT.md for the modelID → K mapping.
internal let indexCoverageMaskShift: Int = 4
internal let indexCoverageMaskWidth: Int = 8
/// Full coverage-mask bitmask (0x0FF0 = bits 4–11).
internal let indexCoverageMask: Int64 = 0xFF << 4

/// Basis-generation sub-field: 4 bits at positions 12–15 (values 0–15).
/// Stamps the global generation counter at the time coverage was written.
/// A mismatch with the current global generation reads as uncovered — no
/// estate-wide write needed on retrain.
internal let indexGenerationShift: Int = 12
internal let indexGenerationWidth: Int = 4
/// Full generation-field bitmask (0xF000 = bits 12–15).
internal let indexGenerationMask: Int64 = 0xF << 12
/// Maximum value before wraparound (4 bits = 0–15).
internal let indexGenerationModulus: Int64 = 16

// MARK: - Coverage-mask registry

/// Maps a provider modelID to the coverage-mask bit offset K (0–7, where
/// the actual bit position is 4 + K). Returns nil for unregistered providers —
/// those fall back to the corpus_provider_coverage side table.
///
/// The registry is stable: entries are NEVER reassigned. A new provider
/// gains the next free K value and its mapping is added here and documented
/// in BITMAP_LAYOUT.md before the provider ships.
internal func coverageMaskBitOffset(for modelID: String) -> Int? {
    // K=0  corpus-ri-v1         (RandomIndexing)
    // K=1  corpus-ppmi-v1       (PPMI)
    // K=2  corpus-lsa-v1        (LSA)
    // K=3  corpus-nmf-v1        (NMF)
    // K=4  corpus-fdc-v1        (FDC)
    // K=5  corpus-deterministic (Deterministic / FloatSimHash)
    // K=6  RESERVED (miniLM)
    // K=7  RESERVED (mpNet / embeddingGemma / nlEmbedding / nlContextual)
    switch modelID {
    case "corpus-ri-v1":          return 0
    case "corpus-ppmi-v1":        return 1
    case "corpus-lsa-v1":         return 2
    case "corpus-nmf-v1":         return 3
    case "corpus-fdc-v1":         return 4
    case "corpus-deterministic":  return 5
    default:
        // Unregistered provider — falls back to corpus_provider_coverage.
        return nil
    }
}

// MARK: - CorpusIndexState accessors

public extension CorpusIndexState {

    /// True when this row represents soft-deleted content.
    /// Derived state (BM25, vectors, coverage) has been cleared.
    /// Active-content queries filter this out: `removed == false`.
    var isRemoved: Bool { operationalBitmap & indexBitRemoved != 0 }

    /// True when the associated corpus_documents row has a non-nil
    /// dense_text column (cached cross-table; maintained by the engine).
    var hasDenseText: Bool { operationalBitmap & indexBitHasDenseText != 0 }

    /// True when BM25 term frequencies and a checkpoint exist for this
    /// content row. The feedCursorRowID sentinel always returns false.
    var isLexicallyIndexed: Bool { operationalBitmap & indexBitLexicallyIndexed != 0 }

    /// The 8-bit coverage mask from bits 4–11.
    /// Bit K (of the 8-bit field) is set when slot K is covered.
    var coverageMask: Int64 {
        BitField.extractField(operationalBitmap,
                              shift: indexCoverageMaskShift,
                              width: indexCoverageMaskWidth)
    }

    /// The 4-bit basis-generation stamp from bits 12–15.
    /// Valid when it matches the current global generation counter.
    var basisGeneration: Int64 {
        BitField.extractField(operationalBitmap,
                              shift: indexGenerationShift,
                              width: indexGenerationWidth)
    }

    /// True when the coverage mask is complete under `configMask` and
    /// the generation stamp matches `currentGeneration`.
    ///
    /// `configMask` is the 8-bit mask of expected slot bits (e.g. 0b11111 for
    /// five slots). The check is:
    ///   `(coverage_mask & configMask) == configMask AND generation == current`
    /// A generation mismatch reads as uncovered regardless of mask bits.
    func isFullyCovered(configMask: Int64, currentGeneration: Int64) -> Bool {
        guard basisGeneration == currentGeneration else { return false }
        return (coverageMask & configMask) == configMask
    }

    /// Return a new bitmap value with the coverage bit for `slotOffset` (K)
    /// set and the basis generation stamped to `generation`. Used by the
    /// engine's coverage write path.
    func settingCoverageSlot(_ slotOffset: Int, generation: Int64) -> Int64 {
        let slotBit: Int64 = 1 << (indexCoverageMaskShift + slotOffset)
        // Set the slot coverage bit; stamp the generation field.
        let withSlot = operationalBitmap | slotBit
        let clearedGen = withSlot & ~indexGenerationMask
        let genField = (generation & (indexGenerationModulus - 1)) << indexGenerationShift
        return clearedGen | genField
    }

    /// Return a new bitmap value with coverage mask and generation cleared
    /// (all bits 4–15 zeroed). Used by the recompose path when lazy-refresh
    /// must reset before re-stamping.
    func clearingCoverageAndGeneration() -> Int64 {
        operationalBitmap & ~(indexCoverageMask | indexGenerationMask)
    }
}

// MARK: - Bitmap construction helpers

/// Build the `operationalBitmap` for a fresh active-content checkpoint.
/// Sets `lexically_indexed=1`; all other bits start at 0.
internal func freshCheckpointBitmap() -> Int64 {
    indexBitLexicallyIndexed
}

/// Build the `operationalBitmap` for a soft-removed content row.
/// Sets `removed=1`; clears `lexically_indexed`, `has_dense_text`,
/// coverage mask, and generation stamp.
internal func softRemovedBitmap() -> Int64 {
    indexBitRemoved
}

/// Build the `operationalBitmap` for a re-ingested content row (remove
/// cleared, lexically_indexed set, coverage reset to 0).
internal func reIngestBitmap() -> Int64 {
    indexBitLexicallyIndexed
}

/// The feedCursorRowID sentinel always carries a zero bitmap: no lifecycle
/// bits, no coverage, no generation.
internal let feedCursorBitmap: Int64 = 0
