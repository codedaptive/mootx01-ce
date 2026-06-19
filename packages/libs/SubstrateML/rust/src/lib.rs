//! substrate-ml — Layer 3 of the three-package SubstrateLib split
//! per DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md §6.
//!
//! ML-flavored math primitives — learning, graph algorithms,
//! feature extraction. Consumed exclusively by reasoning-layer
//! code (NeuronKit per the decision doc).

#![allow(clippy::needless_return)]
#![allow(clippy::too_many_arguments)]

pub mod anomaly;
pub mod apriori_mining;
pub mod association_rule_mining;
pub mod formal_concept_analysis;
pub mod concept_implications;
pub mod bradley_terry;
pub mod calibration;
pub mod community_detection;
pub mod composite_distance;
pub mod eigenvalue_centrality;
pub mod feature_extractors;
pub mod fft;
pub mod float_simhash;
pub mod info_theory;
pub mod lattice_distance;
pub mod moment_summary;
pub mod nmf;
// NMFDoubleFrobeniusSquared — the parked f64/Frobenius² NMF variant.
// PRODUCTION GATE: NOT for production use. Must pass substrate_math_performance
// benchmarking before any consumer wires to this. See the module header for the
// full gate contract and the motivation (Bob's ruling 2026-06-13).
pub mod nmf_double_frobenius_squared;
pub mod random_walks;
pub mod sampling;
pub mod shingle_similarity;
pub mod temporal_compression;

// Relocated 2026-05-29 (four-package split addendum): cold-path /
// federation / dreaming algorithms moved here from substrate-lib.
pub mod action_outcome;
pub mod audit_log_fold;
pub mod decay;
pub mod dp_or_reduce;
pub mod pairing;
pub mod partial_state_recall;
pub mod row_attribute_view;
pub mod tier_contribution;
pub mod tier_query;
pub mod temporal_causality_fold;

// VizGraph telemetry constants — metric names for the five graph-analytic
// algorithms. Parity with Swift's VizGraphSignals.swift.
pub mod viz_graph_signals;

// ADR-010 Decision B: deterministic one-sided Jacobi SVD.
// General math primitive for SubstrateML; consumed by CorpusKit's
// LsaProvider for LSA distributional embeddings. No platform SVD.
pub mod svd;

// Delta feature extraction per DISTILLATION_DESIGN.md §2.1.
// Rust port of DeltaFeatureExtractor.swift (Ds1). Parity to be verified in Dp1.
pub mod delta_feature_extractor;

// Type-specific exponential decay weighting per DISTILLATION_DESIGN.md §2.1.
// Rust port of TypedDecayWeighting.swift (Ds2). Parity to be verified in Dp1.
pub mod typed_decay_weighting;

// Core distillation scoring per DISTILLATION_DESIGN.md §2.1 and DISTILLATION_MATH_SSA.md §2–6.
// Rust port of DistillationScorer.swift (Ds3). Parity to be verified in Dp1.
pub mod distillation_scorer;

// Five-stage cold-path distillation algorithm per DISTILLATION_DESIGN.md §2.1,
// DISTILLATION_MATH_SSA.md §2–6, and DISTILLATION_MATH_DIFFUSION.md.
// Rust port of DistillationPipeline.swift (Ds4). Parity to be verified in Dp1.
pub mod distillation_pipeline;

pub const VERSION: &str = "1.0.0-skeleton";
