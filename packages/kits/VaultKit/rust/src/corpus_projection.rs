//! Corpus projection for migration verification. Rust twin of Swift
//! `CorpusProjection.swift` (VK-ADAPT-01).
//!
//! data-movement privacy tiers retired GLK's flat import verb but kept the
//! substrate's recall-based migration verification and the in-product
//! fidelity benchmark, both of which consume the reference-corpus type
//! `ExternalCorpus`. This projection feeds them from the adapter
//! pipeline: adapter → `Vec<NoteIR>` → projection → `ExternalCorpus`.
//! vault-kit already depends on genius-locus-kit, so the dependency
//! direction is legal (no inversion).

use genius_locus_kit::{ExternalCorpus, ExternalEntry};

use crate::note_ir::NoteIR;

/// Build an `ExternalCorpus` from decoded notes.
///
/// Per-entry mapping is the inverse of `ExchangeAdapter`'s read
/// mapping: `stable_source_key` → `id`, `flattened_body()` → `content`,
/// `tags` → `tags`. Entry order follows `notes` order (the adapter emits
/// stable-source-key-sorted notes, so the projection is deterministic
/// end to end). Mirrors Swift `CorpusProjection.externalCorpus(name:notes:)`.
pub fn external_corpus(name: &str, notes: &[NoteIR]) -> ExternalCorpus {
    ExternalCorpus::new(
        name,
        notes
            .iter()
            .map(|note| {
                ExternalEntry::new(
                    note.stable_source_key.clone(),
                    note.flattened_body(),
                    note.tags.clone(),
                )
            })
            .collect(),
    )
}
