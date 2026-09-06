//! GLK estate-format 1.5 → 1.6 migration capsule.
//! Rust twin of Swift `IndexCompositionColumnDropMigration.swift`.
//!
//! Root cause: `corpus_index_state.composition_policy` (CorpusKit checkpoint
//! schema v3) carried the index composition policy id, a knob that retired
//! when every id came to compose the same document. The column was left
//! declared because populated estates carry it; Bob ruled it dropped.
//! CorpusKit's checkpoint ladder drops it at v4, but a populated estate opens
//! CorpusKit only through the composite estate declarations, which carry no
//! migrations, so the ladder never runs at serve open. This capsule replays
//! the checkpoint ladder on the estate storage through
//! `Storage::migrate(&CorpusIndexStateStore::schema_declaration())` and
//! stamps the estate format V1_6 (GENIUSLOCUSKIT_SPEC I-25).
//!
//! Why the replay is safe on every estate shape:
//!   - An estate whose ledger records `CorpusKitIndexState` at v3 (a 1.0
//!     estate the shared-content capsule walked) replays v3 → v4: the drop.
//!   - An estate with no `CorpusKitIndexState` row (created through the
//!     composite declarations) is treated as fresh: PersistenceKit creates
//!     the tables at the v4 layout with IF NOT EXISTS (the existing table is
//!     left as it is) and replays the ladder from version 0; AddColumn skips
//!     the columns already present, and the v3 → v4 drop removes the column.
//!   - A second run finds the column gone; PersistenceKit DropColumn is
//!     idempotent (the AddColumn rule in reverse), so the run is a no-op.
//!
//! Placement in the chain: LAST. The 1.4 → 1.5 capsule stamps V1_5 before
//! this one runs, so a crash mid-chain never leaves an estate stamped V1_6
//! with an older capsule's work undone. `run_migration_chain` calls
//! `run_index_composition_column_drop_migration` after the 1.4 → 1.5 stamp;
//! the capsule runs before `wire_substores`, which is where the engine opens
//! the composite declaration over the migrated table.
//!
//! Migration steps (all idempotent):
//!   1. Replay CorpusKit's checkpoint ladder to v4 on the estate storage.
//!   2. Stamp the estate format V1_6.

use corpus_kit::index_state_store::CorpusIndexStateStore;
use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::estate_format::{EstateFormatStore, EstateFormatVersion};
use genius_locus_kit::handle::EstateHandle;
use std::sync::Arc;

/// What the capsule left behind.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct IndexCompositionColumnDropMigrationReport {
    /// The `CorpusKitIndexState` ledger version after the replay: the
    /// checkpoint schema version whose layout has no `composition_policy`.
    pub checkpoint_schema_version: i32,
    /// The estate format the capsule stamped.
    pub format: EstateFormatVersion,
}

/// Errors thrown by the index-composition column-drop migration capsule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IndexCompositionColumnDropMigrationError {
    /// The estate's storage backend could not be accessed.
    StorageUnavailable { reason: String },
    /// CorpusKit's checkpoint ladder could not be replayed or its ledger read.
    LadderFailed { reason: String },
    /// The estate-format stamp could not be written.
    StampFailed { reason: String },
}

impl std::fmt::Display for IndexCompositionColumnDropMigrationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::StorageUnavailable { reason } => write!(
                f,
                "index-composition column-drop migration: storage unavailable — {reason}"
            ),
            Self::LadderFailed { reason } => write!(
                f,
                "index-composition column-drop migration: checkpoint ladder failed — {reason}"
            ),
            Self::StampFailed { reason } => write!(
                f,
                "index-composition column-drop migration: estate-format stamp failed — {reason}"
            ),
        }
    }
}

impl std::error::Error for IndexCompositionColumnDropMigrationError {}

/// Extension trait that adds the GLK 1.5 → 1.6 capsule to `EstateCoordinator`.
pub trait IndexCompositionColumnDropMigrationExt {
    /// Run the 1.5 → 1.6 index-composition column-drop migration: replay
    /// CorpusKit's checkpoint ladder (v4 drops
    /// `corpus_index_state.composition_policy`) on the estate storage, then
    /// stamp V1_6.
    ///
    /// Safe to call on any estate at V1_5 or later: the replay is a no-op once
    /// the column is gone and the stamp is a no-op when the estate is already
    /// at V1_6. Returns the checkpoint ledger version after the replay and
    /// the stamped format.
    fn run_index_composition_column_drop_migration(
        &self,
        handle: &EstateHandle,
        now_millis: i64,
    ) -> Result<IndexCompositionColumnDropMigrationReport, IndexCompositionColumnDropMigrationError>;
}

impl IndexCompositionColumnDropMigrationExt for EstateCoordinator {
    fn run_index_composition_column_drop_migration(
        &self,
        handle: &EstateHandle,
        now_millis: i64,
    ) -> Result<IndexCompositionColumnDropMigrationReport, IndexCompositionColumnDropMigrationError> {
        let storage = self.migration_storage(handle).ok_or_else(|| {
            IndexCompositionColumnDropMigrationError::StorageUnavailable {
                reason: "no storage registered for estate".to_string(),
            }
        })?;

        // Step 1: the checkpoint ladder to v4 (idempotent).
        let declaration = CorpusIndexStateStore::schema_declaration();
        storage
            .migrate(&declaration)
            .map_err(|e| IndexCompositionColumnDropMigrationError::LadderFailed {
                reason: format!("{e:?}"),
            })?;
        let checkpoint_schema_version = storage
            .current_schema_version_for(&declaration.kit_id)
            .map_err(|e| IndexCompositionColumnDropMigrationError::LadderFailed {
                reason: format!("checkpoint ledger read failed: {e:?}"),
            })?;

        // Step 2: advance the estate format to V1_6.
        EstateFormatStore::new(Arc::clone(&storage))
            .stamp(EstateFormatVersion::V1_6, now_millis)
            .map_err(|e| IndexCompositionColumnDropMigrationError::StampFailed {
                reason: format!("{e:?}"),
            })?;
        Ok(IndexCompositionColumnDropMigrationReport {
            checkpoint_schema_version,
            format: EstateFormatVersion::V1_6,
        })
    }
}
