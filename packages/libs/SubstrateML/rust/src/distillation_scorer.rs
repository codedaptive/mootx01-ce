// distillation_scorer.rs
//
// Core distillation scoring: SNR gate, structural (recurrence) threshold, PMI graph,
// dominant component selection, confidence score.
// Rust port of DistillationScorer.swift (Ds3). Parity conformance verified in Dp1.
//
// Per DISTILLATION_MATH_SSA.md §2–6.
//
// Critical: binary_entropy and PMI both use f32::log2, NOT f32::ln.
// Swift uses Foundation.log2 — the Rust port must match exactly on
// conformance vectors (f32::log2 produces the same bit pattern on
// the same IEEE 754 inputs).

use crate::typed_decay_weighting::DistillationFeatureType;

// MARK: - Types

/// A feature extracted from a cluster of memories, annotated with frequency
/// and structural metrics. The distillation pipeline operates on arrays of these.
///
/// Mirrors Swift ExtractedFeature in DistillationScorer.swift.
#[derive(Debug, Clone, PartialEq)]
pub struct ExtractedFeature {
    /// Semantic type of the feature (entity, relation, temporal, numerical).
    pub feature_type: DistillationFeatureType,
    /// Canonical grouping key — the STEMMED feature value. Morphological variants
    /// (migrate / migrates / migration) share one stem, so they accumulate one df
    /// and one fingerprint bit. Vocabulary dedup, the incidence matrix, df/PMI,
    /// and the feature fingerprint all key off `value`.
    pub value: String,
    /// Human-readable surface form rendered in the factoid prose (the original
    /// lowercased token, e.g. "migration" for the stem "migrat"). When several
    /// surface forms share a stem, the first-encountered surface is used. Defaults
    /// to `value` when no distinct surface is supplied.
    pub display: String,
    /// Fraction of cluster memories that contain this feature: df(f) = (1/M) × Σ X_{ij}.
    pub doc_frequency: f32,
    /// Temporally-weighted document frequency df_w, per §5. Equals doc_frequency
    /// when memory timestamps are unavailable (uniform weighting).
    pub weighted_doc_frequency: f32,
    /// Structural score σ(f) = df × (1 − H(df)), set by compute_structural_scores.
    /// Rewards features appearing often and consistently; near-zero for borderline features.
    pub structural_score: f32,
}

impl ExtractedFeature {
    /// Initialize with a document frequency; weighted_doc_frequency defaults to
    /// doc_frequency and structural_score defaults to 0 (populated by
    /// compute_structural_scores). `display` defaults to `value` — the surface
    /// form equals the grouping key when no distinct surface is supplied.
    ///
    /// Mirrors Swift `ExtractedFeature(type:value:docFrequency:)` (the
    /// `display: String? = nil` → `display ?? value` default).
    pub fn new(feature_type: DistillationFeatureType, value: impl Into<String>, doc_frequency: f32) -> Self {
        let value = value.into();
        let display = value.clone();
        Self {
            feature_type,
            value,
            display,
            doc_frequency,
            weighted_doc_frequency: doc_frequency,
            structural_score: 0.0,
        }
    }

    /// Initialize with a distinct human-readable `display` surface form that
    /// differs from the stemmed grouping `value`. Used by the HMM feature
    /// extractor: `value = stem(token)`, `display = lowercased token`.
    ///
    /// Mirrors Swift `ExtractedFeature(type:value:docFrequency:display:)`.
    pub fn new_with_display(
        feature_type: DistillationFeatureType,
        value: impl Into<String>,
        doc_frequency: f32,
        display: impl Into<String>,
    ) -> Self {
        Self {
            feature_type,
            value: value.into(),
            display: display.into(),
            doc_frequency,
            weighted_doc_frequency: doc_frequency,
            structural_score: 0.0,
        }
    }
}

/// Signal-to-noise ratio for a feature cluster, indicating distillation readiness.
/// Computed by compute_snr over all extracted features in a cluster.
///
/// Mirrors Swift DistillationSNR in DistillationScorer.swift.
#[derive(Debug, Clone, PartialEq)]
pub struct DistillationSNR {
    /// Ratio of structural signal to episodic noise. Distillation proceeds when snr >= 2.0.
    pub snr: f32,
    /// Total structural weight from threshold-passing (recurring) features: Σ σ(f) for f in V_thresh.
    pub structural_signal: f32,
    /// Total noise energy from sub-threshold features: Σ (1 − df(f)) for f not in V_thresh.
    pub episodic_noise: f32,
    /// True when snr >= 2.0 — the cluster is coherent enough to distill into a factoid.
    pub ready_to_distill: bool,
}

/// PMI-based feature coherence graph over the set of structural-threshold-passing features.
/// Edges exist between feature pairs whose PMI > 0 (co-occur more than chance).
///
/// Mirrors Swift FeatureGraph in DistillationScorer.swift.
#[derive(Debug, Clone)]
pub struct FeatureGraph {
    /// Threshold-passing features (V_thresh), indexed to match pmi_matrix positions.
    pub nodes: Vec<ExtractedFeature>,
    /// Symmetric PMI matrix; diagonal is 0. pmi_matrix[j][k] = PMI(f_j, f_k).
    /// Values are f32::NEG_INFINITY when joint probability is zero.
    pub pmi_matrix: Vec<Vec<f32>>,
    /// Connected components of the positive-PMI subgraph, each as an index list into nodes.
    /// Sorted by total weighted doc_frequency descending (max-weight component first).
    pub components: Vec<Vec<usize>>,
}

// MARK: - Scorer

/// Deterministic distillation scoring over extracted feature clusters.
/// All methods are pure functions — no I/O, no state, no randomness.
/// Per DISTILLATION_MATH_SSA.md §2–6.
pub struct DistillationScorer;

impl DistillationScorer {
    // MARK: - Binary Entropy

    /// Binary entropy H(p) = −p·log₂(p) − (1−p)·log₂(1−p).
    /// Returns 0 at the boundaries p=0 and p=1 (entropy of certainty;
    /// convention: 0·log₂(0) = 0). Uses log2 throughout — NOT log or ln.
    ///
    /// Matches Swift DistillationScorer.binaryEntropy exactly on IEEE 754 inputs.
    pub(crate) fn binary_entropy(p: f32) -> f32 {
        if p <= 0.0 || p >= 1.0 {
            return 0.0;
        }
        -(p * p.log2()) - ((1.0 - p) * (1.0 - p).log2())
    }

    // MARK: - Stage 2: Structural (recurrence) Threshold

    /// Structural threshold for INTRA-ITEM distillation: a feature is structural
    /// iff it RECURS — appears in at least 2 of the item's M units (sentences).
    /// τ_struct = 2 / M, i.e. `df ≥ 2/M` ⟺ count ≥ 2.
    ///
    /// This replaces the cross-memory majority vote (⌈(M+1)/2⌉/M). Distillation
    /// is intra-item: a single document is reduced from its own sentences, where
    /// the central entities recur across a MINORITY of sentences but dominate the
    /// one-off scaffolding tail. Requiring a majority discards the real core
    /// (`falcon` clears it; `database`/`migration`/`tables` do not) and the SNR
    /// gate then holds every prose item. "Recurs at least twice" is the correct
    /// intra-item rule — for one item, repetition is significance. Scale is
    /// handled upstream by the multi-level tree (bounded section units), so
    /// `count ≥ 2` never degrades to noise. (M=1 → τ=2.0, nothing recurs — an
    /// un-chunked single unit is correctly not distillable.)
    ///
    /// Mirrors Swift `DistillationScorer.structuralThreshold(M:)` exactly.
    pub fn structural_threshold(m: usize) -> f32 {
        2.0_f32 / m as f32
    }

    /// Split features into structural (recurring) and episodic (one-off) sets.
    /// The structural set forms V_thresh — the input to the PMI coherence stage.
    pub fn apply_structural_threshold(
        features: &[ExtractedFeature],
        m: usize,
    ) -> (Vec<ExtractedFeature>, Vec<ExtractedFeature>) {
        let tau = Self::structural_threshold(m);
        let mut passing = Vec::new();
        let mut failing = Vec::new();
        for f in features {
            if f.doc_frequency >= tau {
                passing.push(f.clone());
            } else {
                failing.push(f.clone());
            }
        }
        (passing, failing)
    }

    // MARK: - SNR Gate

    /// Compute cluster SNR per §3 to gate distillation readiness.
    ///
    /// structural_signal = Σ σ(f) for features with df ≥ τ_struct (recurring).
    /// episodic_noise    = Σ (1 − df(f)) for features below threshold (one-off tail).
    /// snr               = structural_signal / max(episodic_noise, 1e-6)
    /// ready_to_distill  = snr ≥ 2.0
    ///
    /// The 1e-6 floor prevents division by zero when all features are structural
    /// (no episodic features in the cluster).
    pub fn compute_snr(features: &[ExtractedFeature], m: usize) -> DistillationSNR {
        let tau = Self::structural_threshold(m);
        let mut structural_signal: f32 = 0.0;
        let mut episodic_noise: f32 = 0.0;

        for f in features {
            if f.doc_frequency >= tau {
                // σ(f) = df × (1 − H(df)) — structural weight contribution
                let sigma = f.doc_frequency * (1.0 - Self::binary_entropy(f.doc_frequency));
                structural_signal += sigma;
            } else {
                // (1 − df) — episodic noise contribution from sub-threshold feature
                episodic_noise += 1.0 - f.doc_frequency;
            }
        }

        let snr = structural_signal / episodic_noise.max(1e-6);
        DistillationSNR {
            snr,
            structural_signal,
            episodic_noise,
            ready_to_distill: snr >= 2.0,
        }
    }

    // MARK: - Stage 3: Structural Scores and PMI Graph

    /// Compute structural scores σ(f) = df × (1 − H(df)) for each feature in place.
    /// σ rewards features appearing often AND consistently — near 1.0 for universal features,
    /// near 0.0 for borderline-threshold features. Used for confidence weighting, not filtering.
    pub fn compute_structural_scores(features: &mut Vec<ExtractedFeature>) {
        for f in features.iter_mut() {
            let df = f.doc_frequency;
            f.structural_score = df * (1.0 - Self::binary_entropy(df));
        }
    }

    /// Build the PMI feature coherence graph over threshold-passing features per §4.
    ///
    /// PMI(f_j, f_k) = log₂(p(j∧k) / (p(j) × p(k))).
    /// An edge exists iff PMI > 0 — features co-occur more than their individual
    /// frequencies would predict, indicating semantic relatedness.
    ///
    /// Connected components are sorted by total weighted doc_frequency descending
    /// so components[0] is always the dominant semantic cluster.
    ///
    /// - `threshold_features`: V_thresh — features that passed the structural (recurrence) threshold.
    /// - `incidence_matrix`: Row i column j is true iff threshold_features[j] ∈ memory i.
    /// - `m`: Number of memories in the cluster.
    pub fn build_pmi_graph(
        threshold_features: &[ExtractedFeature],
        incidence_matrix: &[Vec<bool>],
        m: usize,
    ) -> FeatureGraph {
        let n = threshold_features.len();
        if n == 0 || m == 0 {
            return FeatureGraph {
                nodes: threshold_features.to_vec(),
                pmi_matrix: vec![],
                components: vec![],
            };
        }
        let m_f = m as f32;

        // Compute marginal probabilities p(j) = df(f_j) from incidence columns
        let mut p_marginal = vec![0.0_f32; n];
        for j in 0..n {
            let mut count: f32 = 0.0;
            for i in 0..m {
                if incidence_matrix[i][j] {
                    count += 1.0;
                }
            }
            p_marginal[j] = count / m_f;
        }

        // Compute PMI matrix and positive-edge adjacency
        let mut pmi = vec![vec![0.0_f32; n]; n];
        let mut adjacency = vec![vec![false; n]; n];

        for j in 0..n {
            for k in (j + 1)..n {
                // Joint probability: fraction of memories containing both features
                let mut joint_count: f32 = 0.0;
                for i in 0..m {
                    if incidence_matrix[i][j] && incidence_matrix[i][k] {
                        joint_count += 1.0;
                    }
                }
                let p_joint = joint_count / m_f;
                let p_product = p_marginal[j] * p_marginal[k];

                // PMI = log₂(p(j∧k) / (p(j)·p(k))); NEG_INFINITY when joint = 0
                let pmi_value: f32 = if p_joint > 0.0 && p_product > 0.0 {
                    (p_joint / p_product).log2()
                } else {
                    f32::NEG_INFINITY
                };

                pmi[j][k] = pmi_value;
                pmi[k][j] = pmi_value; // symmetric

                if pmi_value > 0.0 {
                    adjacency[j][k] = true;
                    adjacency[k][j] = true;
                }
            }
        }

        // Find connected components via DFS, then sort by total weighted doc_frequency
        let mut components = Self::find_connected_components(n, &adjacency);
        components.sort_by(|a, b| {
            let w_a: f32 = a.iter().map(|&i| threshold_features[i].weighted_doc_frequency).sum();
            let w_b: f32 = b.iter().map(|&i| threshold_features[i].weighted_doc_frequency).sum();
            w_b.partial_cmp(&w_a).unwrap_or(std::cmp::Ordering::Equal)
        });

        FeatureGraph {
            nodes: threshold_features.to_vec(),
            pmi_matrix: pmi,
            components,
        }
    }

    /// Return the features in the dominant (highest-weight) connected component (F* per §4.4).
    /// Isolated features — those with PMI ≤ 0 with all neighbors — form singleton components
    /// and are passed over when a larger coherent cluster exists.
    /// Returns an empty Vec when the graph has no components.
    pub fn select_dominant_component(graph: &FeatureGraph) -> Vec<ExtractedFeature> {
        match graph.components.first() {
            Some(dominant) => dominant.iter().map(|&i| graph.nodes[i].clone()).collect(),
            None => vec![],
        }
    }

    // MARK: - Stage 5: Confidence

    /// Compute factoid confidence per §6.2.
    ///
    /// conf(F*) = mean_df(F*) × coherence_ratio(F*)
    ///
    /// mean_df(F*) = mean document frequency of selected features.
    /// coherence_ratio = |F*| / |V_thresh| — penalizes fragmented V_thresh.
    ///
    /// A cluster where all threshold-passing features cluster together scores
    /// conf = mean_df, while fragmented V_thresh (many isolated nodes) drives
    /// coherence_ratio toward 0.
    pub fn compute_confidence(
        selected: &[ExtractedFeature],
        all_threshold: &[ExtractedFeature],
    ) -> f32 {
        if selected.is_empty() || all_threshold.is_empty() {
            return 0.0;
        }
        let mean_df: f32 = selected.iter().map(|f| f.doc_frequency).sum::<f32>()
            / selected.len() as f32;
        let coherence_ratio = selected.len() as f32 / all_threshold.len() as f32;
        mean_df * coherence_ratio
    }

    // MARK: - Private helpers

    /// DFS-based connected component discovery over a symmetric adjacency matrix.
    /// O(n²) for n nodes — acceptable for |V_thresh| ≤ 150.
    fn find_connected_components(node_count: usize, adjacency: &[Vec<bool>]) -> Vec<Vec<usize>> {
        let mut visited = vec![false; node_count];
        let mut components: Vec<Vec<usize>> = Vec::new();

        for start in 0..node_count {
            if visited[start] {
                continue;
            }
            let mut component: Vec<usize> = Vec::new();
            let mut stack = vec![start];
            while let Some(node) = stack.pop() {
                if visited[node] {
                    continue;
                }
                visited[node] = true;
                component.push(node);
                for neighbor in 0..node_count {
                    if !visited[neighbor] && adjacency[node][neighbor] {
                        stack.push(neighbor);
                    }
                }
            }
            components.push(component);
        }
        components
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::typed_decay_weighting::DistillationFeatureType;

    // MARK: - binary_entropy

    #[test]
    fn binary_entropy_zero_returns_zero() {
        assert_eq!(DistillationScorer::binary_entropy(0.0), 0.0);
    }

    #[test]
    fn binary_entropy_one_returns_zero() {
        assert_eq!(DistillationScorer::binary_entropy(1.0), 0.0);
    }

    #[test]
    fn binary_entropy_half_returns_one() {
        // H(0.5) = -(0.5 · log₂(0.5)) × 2 = 1.0
        let h = DistillationScorer::binary_entropy(0.5);
        assert!((h - 1.0).abs() < 1e-5, "got {h}");
    }

    // MARK: - structural_threshold (τ_struct = 2 / M)

    #[test]
    fn structural_threshold_m3() {
        // 2/3 ≈ 0.667 — a feature recurring in ≥2 of 3 units passes.
        let tau = DistillationScorer::structural_threshold(3);
        let expected = 2.0_f32 / 3.0_f32;
        assert!((tau - expected).abs() < 1e-5, "got {tau}");
    }

    #[test]
    fn structural_threshold_m4() {
        // 2/4 = 0.5 — recurs in ≥2 of 4 units.
        let tau = DistillationScorer::structural_threshold(4);
        assert!((tau - 0.5_f32).abs() < 1e-5, "got {tau}");
    }

    #[test]
    fn structural_threshold_m5() {
        // 2/5 = 0.4 — recurs in ≥2 of 5 units.
        let tau = DistillationScorer::structural_threshold(5);
        assert!((tau - 0.4_f32).abs() < 1e-5, "got {tau}");
    }

    #[test]
    fn structural_threshold_m1_is_two() {
        // M=1 → τ=2.0: nothing recurs, a single un-chunked unit is not distillable.
        let tau = DistillationScorer::structural_threshold(1);
        assert!((tau - 2.0_f32).abs() < 1e-5, "got {tau}");
    }

    // MARK: - apply_structural_threshold

    #[test]
    fn apply_structural_threshold_splits_correctly() {
        let m = 5;
        let tau = DistillationScorer::structural_threshold(m); // 0.4
        let features = vec![
            ExtractedFeature::new(DistillationFeatureType::Entity,   "A", 0.8), // passes
            ExtractedFeature::new(DistillationFeatureType::Relation, "B", 0.2), // fails (1 of 5)
            ExtractedFeature::new(DistillationFeatureType::Temporal, "C", 0.4), // passes (== τ, 2 of 5)
        ];
        let (passing, failing) = DistillationScorer::apply_structural_threshold(&features, m);
        assert_eq!(passing.len(), 2);
        assert_eq!(failing.len(), 1);
        assert!(passing.iter().all(|f| f.doc_frequency >= tau));
        assert!(failing.iter().all(|f| f.doc_frequency < tau));
    }

    // MARK: - compute_snr

    #[test]
    fn compute_snr_pure_structural_cluster_ready_to_distill() {
        // M=3, all 3 features appear in all 3 memories (df=1.0)
        // σ(1.0) = 1.0 × (1 − H(1.0)) = 1.0; structuralSignal = 3.0; noise ≈ 0
        let features = vec![
            ExtractedFeature::new(DistillationFeatureType::Entity,   "A", 1.0),
            ExtractedFeature::new(DistillationFeatureType::Entity,   "B", 1.0),
            ExtractedFeature::new(DistillationFeatureType::Relation, "C", 1.0),
        ];
        let snr = DistillationScorer::compute_snr(&features, 3);
        assert!(snr.ready_to_distill);
        assert!(snr.snr >= 2.0);
        assert!(snr.structural_signal > 0.0);
        assert_eq!(snr.episodic_noise, 0.0);
    }

    #[test]
    fn compute_snr_all_noise_cluster_not_ready_to_distill() {
        // M=5, threshold=0.6; all features at df=0.2 (each in 1 of 5 memories)
        // No structural signal; all episodic
        let features = vec![
            ExtractedFeature::new(DistillationFeatureType::Entity,    "A", 0.2),
            ExtractedFeature::new(DistillationFeatureType::Temporal,  "B", 0.2),
            ExtractedFeature::new(DistillationFeatureType::Numerical, "C", 0.2),
        ];
        let snr = DistillationScorer::compute_snr(&features, 5);
        assert!(!snr.ready_to_distill);
        assert!(snr.snr < 2.0);
        assert_eq!(snr.structural_signal, 0.0);
        assert!(snr.episodic_noise > 0.0);
    }

    // MARK: - compute_structural_scores

    #[test]
    fn compute_structural_scores_sets_score_on_features() {
        // σ(1.0) = 1.0 × (1 − H(1.0)) = 1.0 × 1.0 = 1.0
        let mut features = vec![ExtractedFeature::new(DistillationFeatureType::Entity, "A", 1.0)];
        DistillationScorer::compute_structural_scores(&mut features);
        assert!((features[0].structural_score - 1.0).abs() < 1e-5, "got {}", features[0].structural_score);
    }

    #[test]
    fn compute_structural_scores_half_df_low_score() {
        // σ(0.5) = 0.5 × (1 − H(0.5)) = 0.5 × (1 − 1.0) = 0.0
        let mut features = vec![ExtractedFeature::new(DistillationFeatureType::Entity, "A", 0.5)];
        DistillationScorer::compute_structural_scores(&mut features);
        assert!((features[0].structural_score - 0.0).abs() < 1e-5, "got {}", features[0].structural_score);
    }

    // MARK: - build_pmi_graph

    #[test]
    fn build_pmi_graph_edge_exists_when_co_occurrence_above_chance() {
        // M=4; features A and B both appear in memories {0,1,2}
        // p(A) = p(B) = 3/4, p(A∧B) = 3/4
        // PMI = log₂(0.75 / (0.75 × 0.75)) = log₂(4/3) > 0 → edge exists
        let features = vec![
            ExtractedFeature::new(DistillationFeatureType::Entity, "A", 0.75),
            ExtractedFeature::new(DistillationFeatureType::Entity, "B", 0.75),
        ];
        let incidence: Vec<Vec<bool>> = vec![
            vec![true,  true ],
            vec![true,  true ],
            vec![true,  true ],
            vec![false, false],
        ];
        let graph = DistillationScorer::build_pmi_graph(&features, &incidence, 4);
        assert!(graph.pmi_matrix[0][1] > 0.0, "expected positive PMI, got {}", graph.pmi_matrix[0][1]);
        assert_eq!(graph.components.len(), 1);
    }

    #[test]
    fn build_pmi_graph_no_edge_when_independent() {
        // M=4; feature A in memories {0,1}, feature B in memories {2,3}
        // p(A∧B) = 0 → PMI = -infinity → no edge
        let features = vec![
            ExtractedFeature::new(DistillationFeatureType::Entity, "A", 0.5),
            ExtractedFeature::new(DistillationFeatureType::Entity, "B", 0.5),
        ];
        let incidence: Vec<Vec<bool>> = vec![
            vec![true,  false],
            vec![true,  false],
            vec![false, true ],
            vec![false, true ],
        ];
        let graph = DistillationScorer::build_pmi_graph(&features, &incidence, 4);
        assert!(graph.pmi_matrix[0][1] <= 0.0, "expected non-positive PMI, got {}", graph.pmi_matrix[0][1]);
        assert_eq!(graph.components.len(), 2);
    }

    // MARK: - select_dominant_component

    #[test]
    fn select_dominant_component_returns_highest_weight_component() {
        // Two components: {0} weight=0.25, {1,2} weight=1.5 (dominant)
        // Feature 0 never co-occurs with 1 or 2; features 1 and 2 always co-occur.
        let features = vec![
            ExtractedFeature::new(DistillationFeatureType::Entity, "low",   0.25),
            ExtractedFeature::new(DistillationFeatureType::Entity, "highA", 0.75),
            ExtractedFeature::new(DistillationFeatureType::Entity, "highB", 0.75),
        ];
        let incidence: Vec<Vec<bool>> = vec![
            vec![false, true,  true ],
            vec![false, true,  true ],
            vec![false, true,  true ],
            vec![true,  false, false],
        ];
        let graph = DistillationScorer::build_pmi_graph(&features, &incidence, 4);
        let dominant = DistillationScorer::select_dominant_component(&graph);
        assert_eq!(dominant.len(), 2);
        assert!(dominant.iter().all(|f| (f.doc_frequency - 0.75).abs() < 1e-5));
    }

    // MARK: - compute_confidence

    #[test]
    fn compute_confidence_full_coherence_returns_one() {
        // All threshold features are selected: mean_df=1.0, coherence_ratio=1.0 → conf=1.0
        let features = vec![
            ExtractedFeature::new(DistillationFeatureType::Entity, "A", 1.0),
            ExtractedFeature::new(DistillationFeatureType::Entity, "B", 1.0),
        ];
        let confidence = DistillationScorer::compute_confidence(&features, &features);
        assert!((confidence - 1.0).abs() < 1e-5, "got {confidence}");
    }

    #[test]
    fn compute_confidence_partial_coherence_penalized_by_ratio() {
        // 2 selected out of 4 threshold features; mean_df=0.8
        // conf = 0.8 × (2/4) = 0.4
        let all_threshold: Vec<ExtractedFeature> = (0..4)
            .map(|i| ExtractedFeature::new(DistillationFeatureType::Entity, format!("{i}"), 0.8))
            .collect();
        let selected: Vec<ExtractedFeature> = all_threshold.iter().take(2).cloned().collect();
        let confidence = DistillationScorer::compute_confidence(&selected, &all_threshold);
        assert!((confidence - 0.4).abs() < 1e-5, "got {confidence}");
    }

    #[test]
    fn compute_confidence_empty_selected_returns_zero() {
        let all_threshold = vec![ExtractedFeature::new(DistillationFeatureType::Entity, "A", 1.0)];
        let confidence = DistillationScorer::compute_confidence(&[], &all_threshold);
        assert_eq!(confidence, 0.0);
    }
}
