//! Mission MXE-RT: per-term decomposition of RandomIndexing counts.
//!
//! Rust twin of the Swift `ProviderCountsDecomposition` suite.
//!
//! ## Why this is sufficient as a cross-port guarantee
//!
//! There is no shared byte fixture for the RICT *counts* blob — only the RIB1
//! *basis* blob is gated (`ri_basis_serialization_tests.rs`). That is adequate
//! here, because the guarantee chains:
//!
//!   1. `serialize_counts` and `serialize_basis` differ ONLY in their 4-byte
//!      magic; both write the vocabulary through `write_string_f32_vector_map`.
//!      The committed RIB1 fixture therefore already pins that map encoding —
//!      including the per-term `write_f32_array` bytes — as identical across
//!      the two ports.
//!   2. This suite and its Swift twin each assert BYTE TRANSPARENCY: a
//!      decompose → restore cycle reproduces that port's own counts blob
//!      exactly.
//!
//! (1) pins the two ports to the same bytes; (2) pins each port's
//! decomposition to those bytes. A dedicated RICT fixture would make the
//! chain direct rather than transitive and is worth adding, but its absence
//! does not leave the decomposition ungated.

use corpus_kit_providers::{RandomIndexingProvider, RI_PROJECTION_SEED, RI_WINDOW};

fn trained() -> RandomIndexingProvider {
    let mut p = RandomIndexingProvider::with_parameters(
        "random-indexing-v1", "1.1.0", RI_PROJECTION_SEED);
    for doc in [
        vec!["alpha", "beta", "gamma", "delta"],
        vec!["beta", "gamma", "epsilon"],
        vec!["gamma", "delta", "zeta", "eta", "theta"],
    ] {
        p.train(&doc, RI_WINDOW);
    }
    p
}

#[test]
fn decompose_round_trips_through_restore_from_parts() {
    let provider = trained();
    let original_blob = provider.serialize_counts();
    let (header, terms) = provider.decompose_counts();

    assert!(!terms.is_empty(), "fixture must actually train a vocabulary");

    // The header alone must still decode as a counts blob, yielding an empty
    // vocabulary rather than an error. This is what keeps the `counts` column
    // NOT NULL and readable by anything that ignores term rows — a NULL there
    // is read as "no counts, start from zero", i.e. silent statistics loss.
    let mut header_only = RandomIndexingProvider::with_parameters(
        "random-indexing-v1", "1.1.0", RI_PROJECTION_SEED);
    header_only
        .restore_counts(&header)
        .expect("the header alone must remain a decodable counts blob");

    // Full rehydration reproduces the original state, and re-serializing it
    // reproduces the original blob byte-for-byte.
    let mut restored = RandomIndexingProvider::with_parameters(
        "random-indexing-v1", "1.1.0", RI_PROJECTION_SEED);
    restored
        .restore_counts_from_parts(&header, &terms)
        .expect("restore from parts must succeed");
    assert_eq!(
        restored.serialize_counts(),
        original_blob,
        "a decompose/restore cycle must be byte-transparent to the blob format"
    );
}

#[test]
fn each_entry_is_one_terms_vector_not_the_map() {
    let provider = trained();
    let whole_blob = provider.serialize_counts().len();
    let (_, terms) = provider.decompose_counts();

    let widest = terms.iter().map(|(_, v)| v.len()).max().unwrap_or(0);
    assert!(
        widest < whole_blob,
        "a per-term entry must be strictly smaller than the whole serialized map"
    );
    // 2048 f32 plus the u32 count prefix — the bound that makes the 1e9 bind
    // ceiling unreachable regardless of vocabulary size (ee#49).
    assert_eq!(
        widest,
        2048 * 4 + 4,
        "expected one 2048-dimensional f32 vector per entry"
    );
}
