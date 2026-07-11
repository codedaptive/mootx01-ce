//! Latent themes — soft topic factors (SPEC § 7.2, Lens 2 Topics). Given which
//! labels co-occur, NMF factors them into k latent themes; each label gets a
//! soft loading vector → mixed-membership reasoning, not a hard bucket.
//! Surfaces the GeniusLocusKit matrix-tier MatrixNMF; owns no math (I-17).
//! Deterministic for a fixed seed (B-5); total over edge inputs (I-18, B-8).
//!
//! Type boundary note: MatrixNMF (GLK) delegates to the canonical substrate
//! NMFAlternatingLeastSquares and returns f32 factors. NeuronKit's public
//! ThemeLoading.loadings and LatentThemes.reconstruction_error are f64 for
//! API stability; f32 values are widened to f64 at this boundary. Widening
//! preserves the substrate's bit-exact values with no additional rounding.

use std::collections::HashMap;

use genius_locus_kit::MatrixNMF;

/// One label's soft membership across the latent themes.
#[derive(Clone, Debug, PartialEq)]
pub struct ThemeLoading {
    pub label: String,
    pub loadings: Vec<f64>,   // widened from f32 at the NeuronKit boundary
    pub dominant_theme: usize,
}

/// The latent-theme factorization of a label co-occurrence.
#[derive(Clone, Debug, PartialEq)]
pub struct LatentThemes {
    pub k: usize,
    pub loadings: Vec<ThemeLoading>,
    pub reconstruction_error: f64,  // widened from f32 at the NeuronKit boundary
}

/// Upper bound on distinct labels the dense n×n factorization will accept.
/// n=4096 ⇒ a 4096² × 8B ≈ 128 MB matrix worst case; beyond this the O(n²)
/// allocation becomes a local-DoS vector, so an over-cap input degrades to an
/// empty factorization. Mirrors the Swift `maxLatentThemeLabels`.
pub const MAX_LATENT_THEME_LABELS: usize = 4096;

/// Factor the symmetric co-occurrence over `labels` into `k` latent themes.
/// `cooccurrence` is sparse — `(label_a, label_b, weight)` — and treated as
/// symmetric; pairs whose endpoints are not in `labels` are ignored. `k` is
/// clamped to the label count. Each label gets a soft loading vector and its
/// dominant theme (argmax). Deterministic for a fixed `seed`. No labels,
/// `k == 0`, or more than `MAX_LATENT_THEME_LABELS` labels ⇒ empty
/// factorization (C-16).
pub fn latent_themes(
    labels: &[String],
    cooccurrence: &[(String, String, f64)],
    k: usize,
    seed: u64,
) -> LatentThemes {
    let n = labels.len();
    // DoS ceiling: the dense n×n co-occurrence matrix below is O(n²) memory
    // (n=10_000 ⇒ 800 MB; larger inputs OOM the process). Treat an over-cap
    // label count as a degenerate input ⇒ empty factorization, consistent with
    // the n==0 / k==0 C-16 contract. A real estate's distinct field-value labels
    // never approach MAX_LATENT_THEME_LABELS; the ceiling only bounds a
    // pathological/adversarial local caller.
    if n == 0 || k == 0 || n > MAX_LATENT_THEME_LABELS {
        return LatentThemes {
            k: 0,
            loadings: Vec::new(),
            reconstruction_error: 0.0,
        };
    }

    let effective_k = k.min(n);

    // Build the dense symmetric n×n co-occurrence matrix (row-major). The matrix
    // is the primitive's input; the lens only shapes it.
    let index: HashMap<&str, usize> = labels
        .iter()
        .enumerate()
        .map(|(i, s)| (s.as_str(), i))
        .collect();

    let mut matrix = vec![0.0f64; n * n];
    for (a, b, weight) in cooccurrence {
        if let (Some(&i), Some(&j)) = (index.get(a.as_str()), index.get(b.as_str())) {
            matrix[i * n + j] += weight;
            if i != j {
                matrix[j * n + i] += weight; // symmetric
            }
        }
    }

    // MatrixNMF delegates to the canonical substrate NMFAlternatingLeastSquares
    // (f32, RMS error). Loadings and reconstruction error are f32; widened to f64
    // here at the NeuronKit public-API boundary.
    let factorization = MatrixNMF::factorize(
        &matrix,
        n,
        n,
        effective_k,
        seed,
        MatrixNMF::DEFAULT_MAX_ITERATIONS,
        MatrixNMF::DEFAULT_TOLERANCE,
    );

    let loadings = labels
        .iter()
        .enumerate()
        .map(|(row, label)| {
            // Widen f32 loadings to f64 at the NeuronKit boundary.
            let vector: Vec<f64> = factorization
                .loadings_for_row(row)
                .iter()
                .map(|&v| v as f64)
                .collect();
            let dominant = vector
                .iter()
                .enumerate()
                .max_by(|a, b| a.1.partial_cmp(b.1).unwrap_or(std::cmp::Ordering::Equal))
                .map(|(idx, _)| idx)
                .unwrap_or(0);
            ThemeLoading {
                label: label.clone(),
                loadings: vector,
                dominant_theme: dominant,
            }
        })
        .collect();

    LatentThemes {
        k: effective_k,
        loadings,
        // Widen f32 RMS error to f64 at the NeuronKit boundary.
        reconstruction_error: factorization.reconstruction_error as f64,
    }
}

#[cfg(test)]
mod tests {
    // Tests assert SPEC § 7.2's claims about latent themes: co-occurring labels
    // share a latent theme, k is clamped to the label count, the factorization
    // is deterministic for a fixed seed, and the surface is total over edge
    // inputs.
    use super::*;

    fn labels(xs: &[&str]) -> Vec<String> {
        xs.iter().map(|s| s.to_string()).collect()
    }
    fn cooc(xs: &[(&str, &str, f64)]) -> Vec<(String, String, f64)> {
        xs.iter()
            .map(|(a, b, w)| (a.to_string(), b.to_string(), *w))
            .collect()
    }

    #[test]
    fn co_occurring_labels_share_a_theme() {
        let lab = labels(&["a1", "a2", "a3", "b1", "b2", "b3"]);
        let c = cooc(&[
            ("a1", "a2", 5.0),
            ("a1", "a3", 5.0),
            ("a2", "a3", 5.0),
            ("b1", "b2", 5.0),
            ("b1", "b3", 5.0),
            ("b2", "b3", 5.0),
        ]);
        let themes = latent_themes(&lab, &c, 2, 42);
        assert_eq!(themes.k, 2);
        assert_eq!(themes.loadings.len(), 6);
        let dom: HashMap<&str, usize> = themes
            .loadings
            .iter()
            .map(|l| (l.label.as_str(), l.dominant_theme))
            .collect();
        assert!(
            dom["a1"] == dom["a2"] && dom["a2"] == dom["a3"],
            "a-cluster shares a theme"
        );
        assert!(
            dom["b1"] == dom["b2"] && dom["b2"] == dom["b3"],
            "b-cluster shares a theme"
        );
        assert_ne!(dom["a1"], dom["b1"], "the two clusters separate");
    }

    #[test]
    fn k_clamped_to_label_count() {
        let themes = latent_themes(&labels(&["x", "y"]), &cooc(&[("x", "y", 1.0)]), 99, 7);
        assert!(themes.k <= 2);
    }

    #[test]
    fn deterministic_for_fixed_seed() {
        let lab = labels(&["a1", "a2", "b1", "b2"]);
        let c = cooc(&[("a1", "a2", 3.0), ("b1", "b2", 3.0)]);
        assert_eq!(
            latent_themes(&lab, &c, 2, 123),
            latent_themes(&lab, &c, 2, 123)
        );
    }

    #[test]
    fn total_over_edge_inputs() {
        let empty = latent_themes(&[], &[], 3, 1);
        assert_eq!(empty.k, 0);
        assert!(empty.loadings.is_empty());
        let zero_k = latent_themes(&labels(&["x", "y"]), &[], 0, 1);
        assert_eq!(zero_k.k, 0);
        assert!(zero_k.loadings.is_empty());
    }
}
