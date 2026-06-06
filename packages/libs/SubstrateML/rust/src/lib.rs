//! substrate-ml — Layer 3 of the three-package SubstrateLib split
//! per DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md §6.
//!
//! ML-flavored math primitives — learning, graph algorithms,
//! feature extraction. Consumed exclusively by reasoning-layer
//! code (NeuronKit per the decision doc).

#![allow(dead_code)]
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
pub mod random_walks;
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

pub const VERSION: &str = "1.0.0-skeleton";
