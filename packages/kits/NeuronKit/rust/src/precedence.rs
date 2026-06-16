// precedence.rs
//
// Precedence lens — ranks the strongest antecedent field-value coordinates
// for a given target from a pre-folded T-matrix (NEURONKIT_SPEC.md
// § 8.2, Lens 3 Prediction).
//
// Input is pre-folded T-matrix entries already computed by GeniusLocusKit and
// handed by CognitionKit. The lens shapes (filter → sort → take) to produce
// a ranked antecedent list; it calls no fold primitive itself, preserving
// I-18 (no estate touch). Owns no math (I-17). Pure, stateless (I-18, B-5).
// Total over edge inputs (B-8, C-16).

use substrate_ml::temporal_causality_fold::{TemporalCausalityKey, TemporalFieldCoord};

/// One antecedent ranked by co-occurrence count.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AntecedentRank {
    /// Antecedent field-value coordinate that precedes the target.
    pub source: TemporalFieldCoord,
    /// Log-spaced lag bucket in minutes for this pair.
    pub lag_bucket: i32,
    /// Observation count from the T-matrix for this (source → target, lag) triple.
    pub count: i64,
}

/// Ranks the strongest antecedents for a target field-value coordinate.
///
/// Returns empty when `pairs` is empty, `k` == 0, or no pair targets
/// `target` (B-8).
pub fn precedence(
    pairs: &[(TemporalCausalityKey, i64)],
    target: &TemporalFieldCoord,
    k: usize,
) -> Vec<AntecedentRank> {
    if k == 0 || pairs.is_empty() {
        return vec![];
    }
    let mut filtered: Vec<(&TemporalCausalityKey, i64)> = pairs
        .iter()
        .filter(|(key, _)| &key.target == target)
        .map(|(key, count)| (key, *count))
        .collect();
    filtered.sort_by(|a, b| b.1.cmp(&a.1));
    filtered.truncate(k);
    filtered
        .into_iter()
        .map(|(key, count)| AntecedentRank {
            source: key.source.clone(),
            lag_bucket: key.lag_bucket,
            count,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn coord(field: &str, value: &str) -> TemporalFieldCoord {
        TemporalFieldCoord::new(field, value)
    }

    fn key(src: TemporalFieldCoord, tgt: TemporalFieldCoord, lag: i32) -> TemporalCausalityKey {
        TemporalCausalityKey::new(src, tgt, lag)
    }

    #[test]
    fn empty_pairs_yields_empty() {
        let tgt = coord("status", "string:active");
        assert!(precedence(&[], &tgt, 5).is_empty());
    }

    #[test]
    fn k_zero_yields_empty() {
        let tgt = coord("status", "string:active");
        let src = coord("type", "string:note");
        let pairs = vec![(key(src, tgt.clone(), 1), 10i64)];
        assert!(precedence(&pairs, &tgt, 0).is_empty());
    }

    #[test]
    fn no_matching_target_yields_empty() {
        let tgt = coord("status", "string:active");
        let other = coord("status", "string:archived");
        let src = coord("type", "string:note");
        let pairs = vec![(key(src, other, 1), 10i64)];
        assert!(precedence(&pairs, &tgt, 5).is_empty());
    }

    #[test]
    fn filters_by_target_coord() {
        let tgt = coord("status", "string:active");
        let other = coord("status", "string:archived");
        let src1 = coord("type", "string:note");
        let src2 = coord("type", "string:task");
        let pairs = vec![
            (key(src1.clone(), tgt.clone(), 1), 5i64),
            (key(src2, other, 1), 20i64),
        ];
        let result = precedence(&pairs, &tgt, 5);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].source, src1);
    }

    #[test]
    fn sorted_by_count_descending() {
        let tgt = coord("status", "string:active");
        let pairs = vec![
            (key(coord("c", "v:3"), tgt.clone(), 1), 5i64),
            (key(coord("a", "v:1"), tgt.clone(), 1), 100i64),
            (key(coord("b", "v:2"), tgt.clone(), 1), 30i64),
        ];
        let result = precedence(&pairs, &tgt, 5);
        let counts: Vec<i64> = result.iter().map(|r| r.count).collect();
        let mut sorted = counts.clone();
        sorted.sort_by(|a, b| b.cmp(a));
        assert_eq!(counts, sorted);
        assert_eq!(result[0].source, coord("a", "v:1"));
    }

    #[test]
    fn capped_to_k() {
        let tgt = coord("status", "string:active");
        let pairs: Vec<_> = (0..10)
            .map(|i| (key(coord("f", &format!("v:{}", i)), tgt.clone(), 1), i as i64 + 1))
            .collect();
        let result = precedence(&pairs, &tgt, 3);
        assert_eq!(result.len(), 3);
    }

    #[test]
    fn lag_bucket_preserved() {
        let tgt = coord("status", "string:active");
        let src = coord("type", "string:note");
        let pairs = vec![(key(src, tgt.clone(), 16), 7i64)];
        let result = precedence(&pairs, &tgt, 5);
        assert_eq!(result[0].lag_bucket, 16);
    }

    #[test]
    fn deterministic() {
        let tgt = coord("status", "string:active");
        let pairs = vec![
            (key(coord("a", "v:1"), tgt.clone(), 1), 42i64),
            (key(coord("b", "v:2"), tgt.clone(), 1), 17i64),
        ];
        let r1 = precedence(&pairs, &tgt, 5);
        let r2 = precedence(&pairs, &tgt, 5);
        assert_eq!(r1, r2);
    }

    // C-17 fidelity: count in output equals count from input pair — the lens
    // does no arithmetic on count values, only filters and sorts.
    #[test]
    fn c17_fidelity_count_passes_through_unchanged() {
        let tgt = coord("status", "string:active");
        let src = coord("type", "string:note");
        let input_count: i64 = 42;
        let pairs = vec![(key(src, tgt.clone(), 1), input_count)];
        let result = precedence(&pairs, &tgt, 1);
        assert_eq!(result[0].count, input_count,
            "lens must pass count through unchanged — it owns no math");
    }
}
