//! DistillationInput — Rust port of the per-record input contract from
//! distill_plus_converter.py.
//!
//! The two fields that every classification and reduction algorithm
//! operates on are the source text (``original``) and the enrichment
//! trailer appended by the production pipeline (``enrichment_trailer``).
//! All other JSONL fields are expected outputs, drawer metadata, or
//! harness-only configuration; this struct carries only the inputs.

use serde::{Deserialize, Serialize};

/// The two source inputs for every distillation candidate.
///
/// Mirrors the ``original`` and ``enrichment_trailer`` fields of each
/// oracle-vector JSONL row. The ``original`` field is the raw source
/// text the classifier and reducers operate on. The ``enrichment_trailer``
/// is the structured suffix appended by the production pipeline; it is
/// carried unchanged into the first three candidates and filtered for the
/// intent-span candidate.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DistillationInput {
    /// Raw source text. Unicode code points are the index unit — mirrors
    /// Python's ``len(original)`` which counts code points, not bytes.
    pub original: String,

    /// Structured enrichment trailer from the production pipeline.
    /// May be empty for records that were produced without an enrichment
    /// pass.
    pub enrichment_trailer: String,
}

impl DistillationInput {
    /// Construct a new DistillationInput from source and trailer text.
    pub fn new(original: impl Into<String>, enrichment_trailer: impl Into<String>) -> Self {
        Self {
            original: original.into(),
            enrichment_trailer: enrichment_trailer.into(),
        }
    }
}
