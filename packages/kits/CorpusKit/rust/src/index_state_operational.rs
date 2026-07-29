//! Operational bitmap layout and accessors for `corpus_index_state`.
//!
//! Rust twin of Swift `CorpusIndexStateOperational.swift`.
//!
//! ## Bit layout
//!
//! bit  0     removed            — content is soft-deleted; derived state cleared.
//! bit  1     has_dense_text     — corpus_documents.dense_text IS NOT NULL.
//! bit  2     lexically_indexed  — BM25 checkpoint exists for this content.
//! bit  3     RESERVED           — passages.
//! bits 4–11  coverage_mask      — 8-bit slot mask; bit (4+K) = slot K covered.
//! bits 12–15 basis_generation   — 4-bit global-generation stamp; mismatch = uncovered.
//! bits 16–63 RESERVED           — growth reserve.
//!
//! ## Coverage mask registry (model_id → bit offset K)
//!
//! K=0  corpus-ri-v1         (RandomIndexing)
//! K=1  corpus-ppmi-v1       (PPMI)
//! K=2  corpus-lsa-v1        (LSA)
//! K=3  corpus-nmf-v1        (NMF)
//! K=4  corpus-fdc-v1        (FDC)
//! K=5  corpus-deterministic (Deterministic / FloatSimHash)
//! K=6  RESERVED (miniLM)
//! K=7  RESERVED (mpNet / embeddingGemma / nlEmbedding / nlContextual)

// MARK: - Bit constants

/// Bit 0: content is soft-deleted.
pub const INDEX_BIT_REMOVED: i64 = 1 << 0;

/// Bit 1: corpus_documents.dense_text IS NOT NULL.
pub const INDEX_BIT_HAS_DENSE_TEXT: i64 = 1 << 1;

/// Bit 2: BM25 checkpoint exists (lexically indexed).
pub const INDEX_BIT_LEXICALLY_INDEXED: i64 = 1 << 2;

// Bit 3 reserved (passages).

/// Coverage-mask shift (bits 4–11).
pub const INDEX_COVERAGE_MASK_SHIFT: u32 = 4;
/// Coverage-mask field width (8 bits).
pub const INDEX_COVERAGE_MASK_WIDTH: u32 = 8;
/// Full coverage-mask bitmask (0x0FF0 = bits 4–11).
pub const INDEX_COVERAGE_MASK: i64 = 0xFF << 4;

/// Basis-generation field shift (bits 12–15).
pub const INDEX_GENERATION_SHIFT: u32 = 12;
/// Basis-generation field width (4 bits).
pub const INDEX_GENERATION_WIDTH: u32 = 4;
/// Full generation-field bitmask (0xF000 = bits 12–15).
pub const INDEX_GENERATION_MASK: i64 = 0xF << 12;
/// Modulus for the 4-bit generation counter (values 0–15).
pub const INDEX_GENERATION_MODULUS: i64 = 16;

// MARK: - Coverage-mask registry

/// Maps a provider model_id to the coverage-mask bit offset K (0–7).
/// Returns None for unregistered providers — those fall back to the
/// corpus_provider_coverage side table.
pub fn coverage_mask_bit_offset(model_id: &str) -> Option<u32> {
    match model_id {
        "corpus-ri-v1"         => Some(0), // RandomIndexing
        "corpus-ppmi-v1"       => Some(1), // PPMI
        "corpus-lsa-v1"        => Some(2), // LSA
        "corpus-nmf-v1"        => Some(3), // NMF
        "corpus-fdc-v1"        => Some(4), // FDC
        "corpus-deterministic" => Some(5), // Deterministic / FloatSimHash
        // K=6 RESERVED (miniLM)
        // K=7 RESERVED (mpNet / embeddingGemma / nlEmbedding / nlContextual)
        _ => None,
    }
}

// MARK: - CorpusIndexState accessor helpers
//
// These are free functions that operate on the `operational_bitmap: i64`
// field of a CorpusIndexState. Rust does not have extension methods on foreign
// types; callers pass `state.operational_bitmap` directly.

/// True when the row represents soft-deleted content.
#[inline]
pub fn is_removed(bitmap: i64) -> bool {
    bitmap & INDEX_BIT_REMOVED != 0
}

/// True when the associated dense_text column is non-NULL.
#[inline]
pub fn has_dense_text(bitmap: i64) -> bool {
    bitmap & INDEX_BIT_HAS_DENSE_TEXT != 0
}

/// True when BM25 term frequencies and a checkpoint exist for this row.
#[inline]
pub fn is_lexically_indexed(bitmap: i64) -> bool {
    bitmap & INDEX_BIT_LEXICALLY_INDEXED != 0
}

/// The 8-bit coverage mask from bits 4–11.
#[inline]
pub fn coverage_mask(bitmap: i64) -> i64 {
    (bitmap >> INDEX_COVERAGE_MASK_SHIFT) & 0xFF
}

/// The 4-bit basis-generation stamp from bits 12–15.
#[inline]
pub fn basis_generation(bitmap: i64) -> i64 {
    (bitmap >> INDEX_GENERATION_SHIFT) & 0xF
}

/// True when coverage is complete under `config_mask` and generation matches.
#[inline]
pub fn is_fully_covered(bitmap: i64, config_mask: i64, current_generation: i64) -> bool {
    if basis_generation(bitmap) != current_generation {
        return false;
    }
    (coverage_mask(bitmap) & config_mask) == config_mask
}

/// Return a new bitmap value with the coverage bit for slot `slot_offset` (K)
/// set and the basis generation stamped.
///
/// **Accumulation semantics:** existing coverage bits from prior providers are
/// preserved (OR-ed in). After provider A stamps gen N the bitmap may carry
/// B and C's bits (set under gen N-1) at the new generation stamp. Callers of
/// `is_fully_covered` that require strict per-generation coverage must call
/// `clearing_coverage_and_generation` before this function. The backfill path
/// (which uses the authoritative `corpus_provider_coverage` side table) is
/// unaffected by this behavior.
pub fn setting_coverage_slot(bitmap: i64, slot_offset: u32, generation: i64) -> i64 {
    let slot_bit: i64 = 1 << (INDEX_COVERAGE_MASK_SHIFT + slot_offset);
    // OR-in the new slot bit (preserves other providers' bits); clear and re-stamp generation.
    let with_slot = bitmap | slot_bit;
    let cleared_gen = with_slot & !INDEX_GENERATION_MASK;
    let gen_field = (generation & (INDEX_GENERATION_MODULUS - 1)) << INDEX_GENERATION_SHIFT;
    cleared_gen | gen_field
}

/// Return a new bitmap value with coverage mask and generation cleared.
#[inline]
pub fn clearing_coverage_and_generation(bitmap: i64) -> i64 {
    bitmap & !(INDEX_COVERAGE_MASK | INDEX_GENERATION_MASK)
}

// MARK: - Bitmap construction helpers

/// Build the `operational_bitmap` for a fresh active-content checkpoint.
/// Sets `lexically_indexed=1`; all other bits start at 0.
#[inline]
pub fn fresh_checkpoint_bitmap() -> i64 {
    INDEX_BIT_LEXICALLY_INDEXED
}

/// Build the `operational_bitmap` for a soft-removed content row.
/// Sets `removed=1`; clears all other bits.
#[inline]
pub fn soft_removed_bitmap() -> i64 {
    INDEX_BIT_REMOVED
}

/// The feedCursorRowID sentinel always carries a zero bitmap.
pub const FEED_CURSOR_BITMAP: i64 = 0;
