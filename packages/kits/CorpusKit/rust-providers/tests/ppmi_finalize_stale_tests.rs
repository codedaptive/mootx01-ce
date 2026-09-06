#![cfg(feature = "dense-families")]
// Dense-family test — compiled only when --features dense-families.
// Off by default (plan 70BC55F3, 2026-09-05). See Cargo.toml.
//! Regression tests for the stale-vectors defect (finding D).
//!
//! The invariant: after `finalize()` the ppmi_vectors map must exactly
//! reflect the CURRENT counts state. If counts are empty — because all
//! content was deleted, or because `restore_counts` restored an empty
//! blob — then `ppmi_vectors` must be empty too. A term that was present
//! before the reset must not return a non-zero embedding after the reset.
//!
//! `embed_float` signals "no trained basis" by returning `Ok(vec![])`.
//! That is the post-reset expected result for every term.

use corpus_kit_providers::PpmiProvider;
use synapsekit::EmbeddingProvider;

/// Returns a serialised empty-counts blob that decodes cleanly through
/// `restore_counts`, matching the real production path (countsRestore
/// publishes an empty blob when all sources are removed).
fn empty_counts_blob() -> Vec<u8> {
    // Build a provider, never train it, serialise its counts. The result
    // is a valid blob with total_pairs = 0 and an empty co_count map.
    PpmiProvider::new().serialize_counts()
}

/// Build a small trained-and-finalised provider on the canonical
/// mini-corpus (mirrors `build_trained_provider` in the in-file tests).
fn build_trained_provider() -> PpmiProvider {
    let corpus: Vec<Vec<&str>> = vec![
        vec!["car", "engine", "drive", "road", "vehicle"],
        vec!["vehicle", "road", "transport", "car", "fuel"],
        vec!["engine", "fuel", "combustion", "power", "car"],
        vec!["dog", "bark", "run", "fetch", "animal"],
        vec!["animal", "run", "cat", "dog", "pet"],
    ];
    let mut provider = PpmiProvider::new();
    for doc in &corpus {
        provider.train(doc, corpus_kit_providers::PPMI_WINDOW);
    }
    provider.finalize();
    provider
}

/// Helper: return the L2-norm of the float vector for `term`.
/// `embed_float` returns `Ok(vec![])` when the basis is empty (structural
/// opt-out) and a non-empty vec when the term has a live embedding entry.
fn embed_norm(provider: &PpmiProvider, term: &str) -> f32 {
    match provider.embed_float(term) {
        Ok(v) => {
            let sq: f32 = v.iter().map(|x| x * x).sum();
            sq.sqrt()
        }
        Err(_) => 0.0,
    }
}

/// Core invariant: train, finalize (corpus term embeds non-zero),
/// then restore from an empty counts blob and finalize again — the term
/// must now produce an empty vector (structural opt-out path).
///
/// This is the Rust twin of
/// `testFinalizeAfterRestoreFromEmptyCountsClearsVectors` in
/// PpmiProviderTests.swift.
#[test]
fn finalize_after_empty_counts_restore_clears_vectors() {
    let mut provider = build_trained_provider();

    // Confirm that a corpus term embeds to a nonzero vector after the
    // initial train+finalize.
    let norm_before = embed_norm(&provider, "car");
    assert!(
        norm_before > 0.0,
        "expected nonzero embedding for 'car' after training, got {norm_before}"
    );

    // Restore from an empty counts blob — this is the production path
    // exercised when all content has been deleted and countsRestore
    // publishes an empty snapshot.
    let empty = empty_counts_blob();
    provider
        .restore_counts(&empty)
        .expect("empty counts blob must decode without error");

    // Finalize over the now-empty counts state.
    provider.finalize();

    // After finalize over empty counts, embed_float signals "no trained
    // basis" by returning Ok(vec![]) — norm is zero, no stale vectors remain.
    let norm_after = embed_norm(&provider, "car");
    assert_eq!(
        norm_after, 0.0,
        "expected zero embedding for 'car' after restore from empty counts + finalize, \
         got {norm_after} — stale vectors were not cleared"
    );

    // Also confirm the structural opt-out path: embed_float returns an
    // empty vec, not a vocabMiss error.
    let result = provider.embed_float("car").expect("embed_float must not error on cleared basis");
    assert!(
        result.is_empty(),
        "embed_float('car') must return Ok(vec![]) after empty-counts finalize, \
         got a non-empty vec of length {}", result.len()
    );
}

/// Variant: restore from empty counts, finalize, then confirm that a
/// multi-term query that would have matched corpus content also returns
/// the empty structural opt-out vec.
#[test]
fn finalize_after_empty_counts_restore_clears_multi_term_query() {
    let mut provider = build_trained_provider();

    // Sanity: "dog animal" should embed before the reset.
    assert!(
        embed_norm(&provider, "dog animal") > 0.0,
        "expected nonzero embedding for 'dog animal' before reset"
    );

    let empty = empty_counts_blob();
    provider
        .restore_counts(&empty)
        .expect("empty counts blob must decode without error");
    provider.finalize();

    let result = provider
        .embed_float("dog animal")
        .expect("embed_float must not error on cleared basis");
    assert!(
        result.is_empty(),
        "embed_float('dog animal') must return Ok(vec![]) after empty-counts finalize"
    );
}
