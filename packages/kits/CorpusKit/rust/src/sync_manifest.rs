//! CorpusKitSync manifest helper. Per-estate sync manifest for RAG
//! content. Pairs with VectorKit's vectors-table sync (when both
//! enabled): chunks and their vectors travel together in the
//! same federation zone so they remain join-compatible across
//! devices.

use convergence_kit::{ConflictPolicy, SyncDirection, SyncManifest, SyncedTable};

pub struct CorpusKitSync;

impl CorpusKitSync {
    /// Build a SyncManifest for the chunks table in the given
    /// zone. Append-only conflict policy because chunks are
    /// content-addressed by id and never edited in place;
    /// duplicate inserts are idempotent.
    pub fn manifest(zone_identifier: impl Into<String>) -> SyncManifest {
        SyncManifest::new(
            "CorpusKit",
            1,
            zone_identifier,
            vec![SyncedTable::new("chunks", "id")
                .with_direction(SyncDirection::Bidirectional)
                .with_conflict_policy(ConflictPolicy::AppendOnly)],
        )
    }
}
