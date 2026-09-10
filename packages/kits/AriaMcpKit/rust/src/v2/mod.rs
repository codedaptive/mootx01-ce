//! ARIA v2 contract foundation.
//!
//! The selected surface exports this foundation unconditionally — the v2
//! path is the only dispatch path the running server takes; there is no
//! feature flag gating it.

pub mod call_chain;
pub mod coach;
pub mod codec;
pub mod capability_digest;
pub mod catalog;
pub mod cognition_catalog;
pub mod contradictions;
pub mod recall_lens;
pub mod core_memory;
pub mod data_mobility;
pub mod data_mobility_lower;
pub mod dream;
pub mod estate_diagnostics;
pub mod estate_diagnostics_provider;
pub mod estate_memory;
pub mod help;
pub mod monitoring_set;
pub mod memory_list;
pub mod memory_list_snapshot_provider;
pub mod memory_mutations;
pub mod knowledge_journal;
pub mod lens_lower;
pub mod operation;
pub mod orchestration;
pub mod orchestration_lower;
pub mod packets;
pub mod registry;
pub mod render;
pub mod transcript_recall;
