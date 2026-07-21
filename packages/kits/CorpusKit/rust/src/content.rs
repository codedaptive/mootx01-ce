//! The canonical content boundary (GLK shared-content 1.1, P1).
//! Rust twin of Swift `CorpusContent.swift`.
//!
//! The common indexing engine consumes CONTENT — identified rows with a
//! revision and digest — never storage. In standalone mode CorpusKit's own
//! `CorpusDocumentStore` owns the canonical rows (`corpus_documents`); in
//! attached mode GLK's LocusKit-backed adapter resolves the same surface
//! from Drawers and the canonical public identity is the Drawer ID.
//!
//! An upsert is idempotent on (id, revision, digest, index_version). The
//! worker loads the current record BY ID at work time, rejects a
//! revision/digest mismatch without advancing its checkpoint, replaces the
//! canonical ID's derived state, then advances `corpus_index_state`.
//! Content never rides queues or change batches — only identity, revision,
//! digest, and cursor.

use crate::error::CorpusKitError;
use substrate_kernel::sha256;

/// The canonical public content identity (Drawer ID in attached mode).
pub type CorpusContentId = String;

/// Deterministic content digest — lowercase SHA-256 hex over UTF-8 text.
/// Cross-port identical (Swift twin: `CorpusContentDigest.digest`).
pub fn content_digest(text: &str) -> String {
    sha256::hash(text.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// One canonical content row as the engine consumes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CorpusContentRecord {
    pub id: CorpusContentId,
    /// Monotonic per-ID revision, starting at 1. A changed text bumps the
    /// revision; re-putting identical text does not.
    pub revision: i64,
    /// `content_digest(text)` — the change-detection anchor.
    pub digest: String,
    /// The verbatim canonical text, resolved BY ID at work time. Never
    /// rides a queue payload or change feed.
    pub text: String,
}

/// One entry of the content change feed. Identity/revision/digest ONLY —
/// never text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CorpusContentChange {
    Upsert {
        id: CorpusContentId,
        revision: i64,
        digest: String,
    },
    Remove {
        id: CorpusContentId,
        revision: i64,
    },
}

impl CorpusContentChange {
    pub fn id(&self) -> &str {
        match self {
            CorpusContentChange::Upsert { id, .. } | CorpusContentChange::Remove { id, .. } => id,
        }
    }

    pub fn revision(&self) -> i64 {
        match self {
            CorpusContentChange::Upsert { revision, .. }
            | CorpusContentChange::Remove { revision, .. } => *revision,
        }
    }
}

/// One page of the change feed. `next_cursor` resumes enumeration exactly
/// after the last change; a page is stable — re-reading the same cursor
/// returns the same changes in the same order.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CorpusContentChangeBatch {
    pub changes: Vec<CorpusContentChange>,
    /// Opaque resume cursor; present iff `changes` is non-empty. None as
    /// `since` starts from the beginning of the feed.
    pub next_cursor: Option<String>,
}

impl CorpusContentChangeBatch {
    pub fn empty() -> Self {
        CorpusContentChangeBatch::default()
    }
}

/// The read surface the indexing engine consumes — declared by CorpusKit,
/// implemented by the standalone `CorpusDocumentStore` and by GLK's
/// LocusKit-backed adapter (composition: GLK owns the adapter; LocusKit
/// never depends on corpus-kit).
pub trait CorpusContentSource: Send + Sync {
    /// Resolve the CURRENT record for `id`, or None when the ID does not
    /// resolve to live content.
    fn record(&self, id: &str) -> Result<Option<CorpusContentRecord>, CorpusKitError>;

    /// Enumerate content changes after `cursor` (None = from the start),
    /// at most `limit` entries, in stable feed order.
    fn changes(
        &self,
        cursor: Option<&str>,
        limit: usize,
    ) -> Result<CorpusContentChangeBatch, CorpusKitError>;

    /// Every live content ID, in deterministic ascending ID order — the
    /// streaming order rebuilds use.
    fn active_content_ids(&self) -> Result<Vec<CorpusContentId>, CorpusKitError>;
}

/// The full canonical-content authority — the standalone-mode surface.
/// Nothing conforms to this on the attached path (the configuration
/// rejects it structurally).
pub trait CorpusContentStore: CorpusContentSource {
    /// Insert or update canonical content. Computes the digest, bumps the
    /// revision iff the text changed, journals an upsert change.
    /// Re-putting identical text is a no-op (idempotence anchor).
    fn put(
        &self,
        text: &str,
        id: &str,
        now_millis: i64,
    ) -> Result<CorpusContentRecord, CorpusKitError>;

    /// Remove canonical content and journal a remove change carrying the
    /// removed revision. Removing an absent ID is a no-op.
    fn remove(&self, id: &str, now_millis: i64) -> Result<(), CorpusKitError>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn digest_is_cross_port_stable() {
        // Frozen SHA-256 vectors — the Swift twin asserts the same strings.
        assert_eq!(
            content_digest(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            content_digest("hello"),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
    }
}
