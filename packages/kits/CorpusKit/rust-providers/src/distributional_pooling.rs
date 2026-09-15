//! The ONE pooling function that turns a bag of terms into a unit document
//! vector for the sparse-index distributional family (Random Indexing).
//! Documents at index time and queries at recall time go through this
//! same function, so the two sides of a cosine comparison are built the same
//! way — a document's own opening sentence lands on the document.
//!
//! Rust twin of Swift `DistributionalPooling` (CorpusKitProviders/
//! DistributionalPooling.swift). The composition, the accumulation order,
//! and every float operation are identical, so both ports produce the same
//! bits for the same basis and text.
//!
//! ## Why weighting and centring are both required
//!
//! A plain sum of every token's context vector is dominated by the terms
//! that appear in most documents: their context vectors are the largest (they
//! co-occur with everything) and they occur in every long text. Every
//! document therefore points at one shared direction — the corpus mean — and
//! pairwise cosines sit near 1 regardless of content (measured 0.999 for RI
//! on a 13,817 drawer estate). Two fixes, each necessary:
//!
//!   1. IDF weighting shrinks the contribution of a term that appears in many
//!      documents (a term in every document weighs exactly 0).
//!   2. Mean-direction removal subtracts whatever shared component survives
//!      the weighting. It is a projection, `u − (u·m̂) m̂`, not a translation:
//!      scale-free (a long document and a short query are treated
//!      identically) and it needs only the DIRECTION of the corpus mean.
//!
//! ## The pooling function
//!
//!   pool(terms):
//!     1. distinct(terms), ordered by UTF-8 bytes — a set function of the bag.
//!     2. raw = Σ idf(t) · vector(t) over the distinct terms that have a
//!        vector (OOV terms and idf-0 terms contribute nothing).
//!     3. u = l2_normalize(raw)
//!     4. v = u − (u · m̂) m̂
//!     5. result = l2_normalize(v); an all-zero result is "no signal" (None).
//!
//! ## The corpus-mean direction
//!
//!   m = Σ_t df(t) · idf(t) · vector(t), keys in UTF-8 order;  m̂ = l2_normalize(m)
//!
//! Under the binary term weighting the pooling uses, Σ_d raw_d equals this
//! sum exactly, so m̂ IS the direction of the mean raw document vector — and
//! it is a closed form over the maintained counts (df, N) and the vector
//! table, which is what lets the counts path fit the same bytes as the
//! corpus path without a second pass over the documents.

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// L2 normalisation and the dot product come from
// substrate_kernel::float_vec_ops. Only the composition lives here.
// ─────────────────────────────────────────────────────────────────

use std::collections::HashMap;
use substrate_kernel::float_vec_ops;

/// Pool a bag of terms into a unit vector — the same function for a
/// document and for a query.
///
/// - `terms`: the keyword tokens of the text (order and repetition are
///   irrelevant — reduced to a UTF-8-ordered set).
/// - `vectors`: term → context vector, every vector `dimension` long.
/// - `idf`: term → smoothed IDF weight fitted at training time.
/// - `mean_direction`: the unit corpus-mean direction fitted at training
///   time (`dimension` long), or empty to skip centring.
///
/// Returns `(vector, hits)`: the pooled unit vector, or `None` when nothing
/// contributed or the result collapsed to zero; and how many distinct terms
/// had a context vector (0 means every term was OOV — a vocabulary miss).
pub fn pool(
    terms: &[String],
    vectors: &HashMap<String, Vec<f32>>,
    idf: &HashMap<String, f32>,
    mean_direction: &[f32],
    dimension: usize,
) -> (Option<Vec<f32>>, usize) {
    let mut distinct: Vec<&str> = terms.iter().map(String::as_str).collect();
    distinct.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
    distinct.dedup();
    let mut sum = vec![0.0f32; dimension];
    let mut hits = 0usize;
    for term in distinct {
        let Some(cv) = vectors.get(term) else { continue };
        if cv.len() != dimension {
            continue;
        }
        hits += 1;
        // idf == 0 (a term in every document) or no fitted weight: adding
        // 0·cv leaves the sum unchanged, so skip the loop.
        let weight = match idf.get(term) {
            Some(&w) if w > 0.0 => w,
            _ => continue,
        };
        for d in 0..dimension {
            sum[d] += weight * cv[d];
        }
    }
    if hits == 0 {
        return (None, 0);
    }
    let unit = float_vec_ops::l2_normalize(sum);
    let centred = remove_mean_direction(&unit, mean_direction);
    let result = float_vec_ops::l2_normalize(centred);
    if result.iter().all(|&x| x == 0.0) {
        (None, hits)
    } else {
        (Some(result), hits)
    }
}

/// Remove the component of `unit` along the unit direction `mean_direction`:
/// `unit − (unit · m̂) m̂`. Returns `unit` unchanged when no mean direction is
/// fitted (empty) or its length does not match.
pub fn remove_mean_direction(unit: &[f32], mean_direction: &[f32]) -> Vec<f32> {
    if mean_direction.is_empty() || mean_direction.len() != unit.len() {
        return unit.to_vec();
    }
    let projection = float_vec_ops::dot(unit, mean_direction);
    let mut out = unit.to_vec();
    for d in 0..out.len() {
        out[d] -= projection * mean_direction[d];
    }
    out
}

/// Fit the unit corpus-mean direction from the vector table and the
/// maintained document frequencies:
/// `m̂ = l2_normalize(Σ_t df(t)·idf(t)·vector(t))`, keys in UTF-8 order.
///
/// Returns an empty vector when nothing contributed (no terms, or every term
/// has df 0 or idf 0), which `pool` treats as "no centring".
pub fn mean_direction(
    vectors: &HashMap<String, Vec<f32>>,
    idf: &HashMap<String, f32>,
    document_frequency: impl Fn(&str) -> usize,
    dimension: usize,
) -> Vec<f32> {
    let mut ordered: Vec<&String> = vectors.keys().collect();
    ordered.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
    let mut sum = vec![0.0f32; dimension];
    for term in ordered {
        let cv = &vectors[term];
        if cv.len() != dimension {
            continue;
        }
        let weight = match idf.get(term.as_str()) {
            Some(&w) if w > 0.0 => w,
            _ => continue,
        };
        let df = document_frequency(term.as_str());
        if df == 0 {
            continue;
        }
        // (df as f32) * idf first, then scaled into the accumulator — the
        // same two-step product as the Swift port.
        let coefficient = (df as f32) * weight;
        for d in 0..dimension {
            sum[d] += coefficient * cv[d];
        }
    }
    let unit = float_vec_ops::l2_normalize(sum);
    if unit.iter().any(|&x| x != 0.0) {
        unit
    } else {
        Vec::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn table() -> HashMap<String, Vec<f32>> {
        let mut m = HashMap::new();
        m.insert("a".to_string(), vec![1.0, 0.0, 0.0]);
        m.insert("b".to_string(), vec![0.0, 1.0, 0.0]);
        m.insert("c".to_string(), vec![0.0, 0.0, 1.0]);
        m
    }

    fn weights() -> HashMap<String, f32> {
        let mut m = HashMap::new();
        m.insert("a".to_string(), 1.0);
        m.insert("b".to_string(), 0.5);
        m.insert("c".to_string(), 0.0); // a term in every document weighs nothing
        m
    }

    #[test]
    fn pooling_is_a_set_function_of_the_bag() {
        let v = table();
        let w = weights();
        let x = pool(&["a".into(), "b".into(), "a".into()], &v, &w, &[], 3);
        let y = pool(&["b".into(), "a".into()], &v, &w, &[], 3);
        assert_eq!(x, y, "order and repetition must not change the pooled vector");
    }

    #[test]
    fn idf_zero_term_contributes_nothing_but_counts_as_a_hit() {
        let v = table();
        let w = weights();
        let (only_c, hits) = pool(&["c".into()], &v, &w, &[], 3);
        assert_eq!(hits, 1);
        assert!(only_c.is_none(), "an all-zero pooled vector is no signal");
    }

    #[test]
    fn oov_only_is_zero_hits() {
        let (vec, hits) = pool(&["zzz".into()], &table(), &weights(), &[], 3);
        assert_eq!(hits, 0);
        assert!(vec.is_none());
    }

    #[test]
    fn mean_direction_removal_is_a_projection() {
        let unit = vec![0.6f32, 0.8, 0.0];
        let m = vec![1.0f32, 0.0, 0.0];
        let out = remove_mean_direction(&unit, &m);
        assert_eq!(out, vec![0.0, 0.8, 0.0]);
        assert_eq!(remove_mean_direction(&unit, &[]), unit, "no mean → unchanged");
    }
}
