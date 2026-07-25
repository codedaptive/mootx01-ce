//! reduced_vocab.rs — shared IDF-reduced vocabulary selection for the dense
//! distributional-factorization providers (LSA, NMF). shared reduced embedding vocabulary.
//!
//! Rust port of Swift's `CorpusKitProviders/ReducedVocab.swift`.
//!
//! ## Why this exists
//!
//! LSA/NMF build a DENSE `docs × vocab` matrix and factor it. On a real corpus
//! the vocabulary is tens of thousands of distinct terms, so the fixed-sweep
//! factorization is ~10^15 ops — infeasible, and it hangs the encode drain.
//! This picks a deterministic top-K informative sub-vocabulary so the factored
//! matrix is `docs × K` (feasible). Both dense providers consume ONE reduced
//! vocab; `K` is an optimizer knob.
//!
//! ## Determinism (cross-port bit-identity)
//!
//! The kept set and column order depend ONLY on `(df, term)`: candidates are
//! fully sorted by df DESCENDING then term ascending. Rust `&str` Ord is
//! UTF-8-byte lexicographic, which matches Swift's `Array(term.utf8)` compare —
//! so the selection is byte-identical to the Swift port.

use std::collections::HashMap;

/// Default reduced-vocabulary cap K. Mirrors Swift `defaultReducedVocabCap`.
/// Dense SVD/ALS cost scales as ~K²·numDocs; 512 keeps a large-corpus reindex
/// in the seconds range while far exceeding the providers' rank (LSA 64/NMF 32).
pub const DEFAULT_REDUCED_VOCAB_CAP: usize = 512;

/// A frozen reduced vocabulary: the ordered kept terms plus the maps to remap
/// full-vocab TF rows to reduced columns at train time and query terms to
/// reduced columns at projection time.
pub struct ReducedVocabulary {
    /// Kept terms in reduced-column order (column i == `kept_terms[i]`).
    pub kept_terms: Vec<String>,
    /// term → reduced column — the projection / serialization map.
    pub term_to_column: HashMap<String, usize>,
    /// full-vocab index → reduced column — remaps TF rows at train time.
    pub full_index_to_column: HashMap<usize, usize>,
}

impl ReducedVocabulary {
    /// Number of reduced columns.
    pub fn size(&self) -> usize {
        self.kept_terms.len()
    }
}

/// Select the shared reduced vocabulary from maintained term-document counts.
///
/// No-op when the full vocab already fits `cap` (small estates and every
/// conformance fixture train an unchanged basis). Above `cap`: drop hapax
/// (`df < 2`) and rank the remainder by document frequency DESCENDING,
/// tie-broken by UTF-8 byte order of the term; keep the top `cap`.
pub fn select_reduced_vocabulary(
    vocab: &HashMap<String, usize>,
    df_counts: &HashMap<usize, usize>,
    _document_count: usize,
    cap: usize,
) -> ReducedVocabulary {
    let full_size = vocab.len();

    // No-op below the cap: keep the FULL vocabulary in its existing column
    // order, so estates whose vocab already fits K (incl. all conformance
    // fixtures) train a byte-identical basis to the pre-shared reduced embedding vocabulary behavior.
    if full_size <= cap.max(1) {
        let mut kept_terms: Vec<String> = vec![String::new(); full_size];
        for (term, &idx) in vocab {
            if idx < full_size {
                kept_terms[idx] = term.clone();
            }
        }
        let mut identity: HashMap<usize, usize> = HashMap::with_capacity(full_size);
        for i in 0..full_size {
            identity.insert(i, i);
        }
        return ReducedVocabulary {
            kept_terms,
            term_to_column: vocab.clone(),
            full_index_to_column: identity,
        };
    }

    // Above the cap: drop hapax, then rank by (df desc, term utf8 asc), top-K.
    let mut candidates: Vec<(&str, usize, usize)> = Vec::with_capacity(full_size);
    for (term, &full_index) in vocab {
        let df = *df_counts.get(&full_index).unwrap_or(&0);
        if df >= 2 {
            candidates.push((term.as_str(), full_index, df));
        }
    }
    // df descending, then term bytes ascending — a strict total order
    // (terms are unique) independent of HashMap iteration order.
    candidates.sort_by(|a, b| b.2.cmp(&a.2).then_with(|| a.0.cmp(b.0)));

    let kept_count = cap.min(candidates.len());
    let mut kept_terms = Vec::with_capacity(kept_count);
    let mut term_to_column = HashMap::with_capacity(kept_count);
    let mut full_index_to_column = HashMap::with_capacity(kept_count);
    for (col, &(term, full_index, _df)) in candidates.iter().take(kept_count).enumerate() {
        kept_terms.push(term.to_string());
        term_to_column.insert(term.to_string(), col);
        full_index_to_column.insert(full_index, col);
    }
    ReducedVocabulary {
        kept_terms,
        term_to_column,
        full_index_to_column,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build (vocab, df) for `n` terms "t000".. with df[i] = i+1.
    fn synthetic(n: usize) -> (HashMap<String, usize>, HashMap<usize, usize>) {
        let mut vocab = HashMap::new();
        let mut df = HashMap::new();
        for i in 0..n {
            vocab.insert(format!("t{:04}", i), i);
            df.insert(i, i + 1); // df = 1,2,3,... (t0000 is hapax)
        }
        (vocab, df)
    }

    #[test]
    fn no_op_below_cap_keeps_full_vocab_in_order() {
        let (vocab, df) = synthetic(10);
        let r = select_reduced_vocabulary(&vocab, &df, 100, 2000);
        assert_eq!(r.size(), 10);
        for i in 0..10 {
            assert_eq!(r.kept_terms[i], format!("t{:04}", i));
            assert_eq!(r.term_to_column[&format!("t{:04}", i)], i);
            assert_eq!(r.full_index_to_column[&i], i);
        }
    }

    #[test]
    fn above_cap_drops_hapax_and_keeps_top_df() {
        // 100 terms, df = 1..100; cap 10 → keep the 10 highest-df non-hapax.
        let (vocab, df) = synthetic(100);
        let r = select_reduced_vocabulary(&vocab, &df, 100, 10);
        assert_eq!(r.size(), 10);
        // Highest df is t0099 (df=100) → column 0; t0090 (df=91) → column 9.
        assert_eq!(r.kept_terms[0], "t0099");
        assert_eq!(r.kept_terms[9], "t0090");
        // Hapax t0000 (df=1) must be excluded.
        assert!(!r.term_to_column.contains_key("t0000"));
    }

    #[test]
    fn deterministic_regardless_of_map_order() {
        let (vocab, df) = synthetic(100);
        let a = select_reduced_vocabulary(&vocab, &df, 100, 25);
        let b = select_reduced_vocabulary(&vocab, &df, 100, 25);
        assert_eq!(a.kept_terms, b.kept_terms);
    }
}
