//! LatentThemes — soft topic factors over a co-occurrence matrix: the
//! NeuronKit reasoning surface over GLK's gated `MatrixNMF` (Lens 2, Topics).
//! Given which labels co-occur (field-value coordinates, or any co-occurring
//! tokens), NMF factors them into `k` latent themes; each label gets a soft
//! loading vector → mixed-membership reasoning ("this is 60% theme A, 30%
//! theme C"), not a hard single bucket.
//!
//! Layer discipline: the NMF math lives in GLK's matrix tier
//! (`genius_locus_kit::MatrixNMF`, deterministic SplitMix64 seeding); this
//! module shapes a sparse co-occurrence into the dense matrix it consumes and
//! turns the factorization into per-label theme loadings. CognitionKit
//! sequences it; the estate supplies the co-occurrence. The second
//! "surface-then-sequence" lens (after Keystones).

use std::collections::BTreeMap;

use genius_locus_kit::MatrixNMF;

/// One label's soft membership across the `k` latent themes.
#[derive(Clone, Debug, PartialEq)]
pub struct ThemeLoading {
    pub label: String,
    /// Length-`k` non-negative loadings (the W row for this label).
    pub loadings: Vec<f64>,
    /// Index of the strongest theme (argmax of `loadings`).
    pub dominant_theme: usize,
}

/// The latent-theme factorization of a co-occurrence matrix.
#[derive(Clone, Debug, PartialEq)]
pub struct LatentThemes {
    /// Effective theme count (clamped to the label count).
    pub k: usize,
    /// One loading vector per label, in `labels` order.
    pub loadings: Vec<ThemeLoading>,
    /// NMF reconstruction error at convergence (lower = better fit).
    pub reconstruction_error: f64,
}

/// Factor the symmetric co-occurrence over `labels` into `k` latent themes.
///
/// `cooccurrence` is sparse — `(label_a, label_b, weight)` — and treated as
/// symmetric (co-occurrence is undirected); pairs whose endpoints are not in
/// `labels` are ignored. `k` is clamped to the label count. Deterministic for
/// a fixed `seed` (GLK's `MatrixNMF` seeds W/H via SplitMix64).
pub fn latent_themes(
    labels: &[String],
    cooccurrence: &[(String, String, f64)],
    k: usize,
    seed: u64,
) -> LatentThemes {
    let n = labels.len();
    if n == 0 || k == 0 {
        return LatentThemes { k: 0, loadings: Vec::new(), reconstruction_error: 0.0 };
    }

    let index: BTreeMap<&str, usize> =
        labels.iter().enumerate().map(|(i, s)| (s.as_str(), i)).collect();

    // Dense symmetric n×n co-occurrence matrix (row-major), as MatrixNMF wants.
    let mut o = vec![0.0_f64; n * n];
    for (a, b, w) in cooccurrence {
        if let (Some(&i), Some(&j)) = (index.get(a.as_str()), index.get(b.as_str())) {
            o[i * n + j] += *w;
            if i != j {
                o[j * n + i] += *w; // symmetric
            }
        }
    }

    let k_eff = k.min(n);
    let f = MatrixNMF::factorize(
        &o,
        n,
        n,
        k_eff,
        seed,
        MatrixNMF::DEFAULT_MAX_ITERATIONS,
        MatrixNMF::DEFAULT_TOLERANCE,
    );

    let loadings: Vec<ThemeLoading> = labels
        .iter()
        .enumerate()
        .map(|(i, label)| {
            let l = f.loadings_for_row(i);
            let dominant_theme = l
                .iter()
                .enumerate()
                .max_by(|a, b| a.1.partial_cmp(b.1).unwrap_or(std::cmp::Ordering::Equal))
                .map(|(idx, _)| idx)
                .unwrap_or(0);
            ThemeLoading { label: label.clone(), loadings: l, dominant_theme }
        })
        .collect();

    LatentThemes { k: k_eff, loadings, reconstruction_error: f.reconstruction_error }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn labels(xs: &[&str]) -> Vec<String> {
        xs.iter().map(|s| s.to_string()).collect()
    }
    fn co(xs: &[(&str, &str, f64)]) -> Vec<(String, String, f64)> {
        xs.iter().map(|(a, b, w)| (a.to_string(), b.to_string(), *w)).collect()
    }

    fn dominant(themes: &LatentThemes, label: &str) -> usize {
        themes.loadings.iter().find(|t| t.label == label).unwrap().dominant_theme
    }

    // LT-1: two disjoint, balanced co-occurrence triangles (A1-A2-A3 mutually;
    // B1-B2-B3 mutually; ZERO cross-clique) factor into two separable themes.
    // Each clique's labels share a dominant theme, and the two cliques' themes
    // differ — mixed-membership structure recovered from raw co-occurrence.
    #[test]
    fn lt1_disjoint_cliques_separate_into_themes() {
        let ls = labels(&["A1", "A2", "A3", "B1", "B2", "B3"]);
        let g = co(&[
            ("A1", "A2", 5.0),
            ("A1", "A3", 5.0),
            ("A2", "A3", 5.0),
            ("B1", "B2", 5.0),
            ("B1", "B3", 5.0),
            ("B2", "B3", 5.0),
        ]);
        let t = latent_themes(&ls, &g, 2, 0xC0FFEE);
        assert_eq!(t.k, 2);
        let a = dominant(&t, "A1");
        assert_eq!(dominant(&t, "A2"), a, "A-clique shares a theme");
        assert_eq!(dominant(&t, "A3"), a, "A-clique shares a theme");
        let b = dominant(&t, "B1");
        assert_eq!(dominant(&t, "B2"), b, "B-clique shares a theme");
        assert_eq!(dominant(&t, "B3"), b, "B-clique shares a theme");
        assert_ne!(a, b, "the two cliques land on different latent themes");
    }

    // LT-2: deterministic — same labels, co-occurrence, k, seed ⇒ identical
    // loadings across runs (SplitMix64 seeding).
    #[test]
    fn lt2_is_deterministic() {
        let ls = labels(&["x", "y", "z"]);
        let g = co(&[("x", "y", 3.0), ("y", "z", 2.0)]);
        let a = latent_themes(&ls, &g, 2, 42);
        let b = latent_themes(&ls, &g, 2, 42);
        assert_eq!(a, b);
    }

    // LT-3: guarded edges — empty labels or k=0 yield an empty result; k is
    // clamped to the label count.
    #[test]
    fn lt3_guards() {
        assert!(latent_themes(&[], &[], 3, 1).loadings.is_empty());
        assert!(latent_themes(&labels(&["a"]), &[], 0, 1).loadings.is_empty());
        let t = latent_themes(&labels(&["a", "b"]), &co(&[("a", "b", 1.0)]), 9, 1);
        assert_eq!(t.k, 2, "k clamped to label count");
    }
}
