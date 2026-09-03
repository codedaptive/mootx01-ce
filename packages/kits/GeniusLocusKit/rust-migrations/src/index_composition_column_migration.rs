//! GLK estate-format 1.1 → 1.2 migration capsule.
//! Rust twin of Swift `IndexCompositionColumnMigration.swift`.
//!
//! Root cause: CorpusIndexStateStore schema reached v3 with an addColumn
//! migration for `composition_policy TEXT NOT NULL DEFAULT ''`. Populated
//! estates opened CorpusKit only through the composite attached declaration,
//! which carries an empty migrations list. PersistenceKit records the bumped
//! composite version and has nothing to replay, so the column is never added.
//! Fresh estates get the column from CREATE TABLE. This capsule fixes
//! populated estates.
//!
//! Migration steps (all idempotent via PersistenceKit addColumn / CREATE IF NOT EXISTS):
//!   1. Apply `CorpusIndexStateStore::schema_declaration()` through its own ladder.
//!      This replays the v2→v3 migration: addColumn composition_policy.
//!   2. Apply `corpus_kit::attached_declaration()` so the composite version record
//!      ("CorpusKitAttached") is updated. No-op on tables.
//!   3. Stamp the estate format V1_2.

use corpus_kit::{attached_declaration, CorpusIndexStateStore};
use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::estate_format::{EstateFormatStore, EstateFormatVersion};
use genius_locus_kit::handle::EstateHandle;
use std::sync::Arc;

/// Errors thrown by the index-composition-column migration capsule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IndexCompositionColumnMigrationError {
    /// The estate's storage backend could not be accessed.
    StorageUnavailable { reason: String },
    /// A schema application step failed.
    SchemaApplicationFailed { target: String, reason: String },
    /// The estate-format stamp could not be written.
    StampFailed { reason: String },
}

impl std::fmt::Display for IndexCompositionColumnMigrationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::StorageUnavailable { reason } => {
                write!(f, "index-composition-column migration: storage unavailable — {reason}")
            }
            Self::SchemaApplicationFailed { target, reason } => {
                write!(
                    f,
                    "index-composition-column migration: schema application failed for {target} — {reason}"
                )
            }
            Self::StampFailed { reason } => {
                write!(f, "index-composition-column migration: estate-format stamp failed — {reason}")
            }
        }
    }
}

impl std::error::Error for IndexCompositionColumnMigrationError {}

/// Extension trait that adds the GLK 1.1 → 1.2 capsule to `EstateCoordinator`.
pub trait IndexCompositionColumnMigrationExt {
    /// Run (or resume) the 1.1 → 1.2 index-composition-column migration.
    ///
    /// Applies `CorpusIndexStateStore::schema_declaration()` through the
    /// component kit's own ladder (idempotent addColumn for composition_policy),
    /// then re-applies the attached composite declaration to update the composite
    /// version record, then stamps the estate format V1_2.
    ///
    /// Safe to call on any estate at V1_1 or later: the addColumn is idempotent
    /// and the stamp is a no-op when the estate is already at V1_2.
    fn run_index_composition_column_migration(
        &self,
        handle: &EstateHandle,
        now_millis: i64,
    ) -> Result<(), IndexCompositionColumnMigrationError>;
}

impl IndexCompositionColumnMigrationExt for EstateCoordinator {
    fn run_index_composition_column_migration(
        &self,
        handle: &EstateHandle,
        now_millis: i64,
    ) -> Result<(), IndexCompositionColumnMigrationError> {
        let storage = self
            .migration_storage(handle)
            .ok_or_else(|| IndexCompositionColumnMigrationError::StorageUnavailable {
                reason: "no storage registered for estate".to_string(),
            })?;

        // Step 1: apply the component kit's own schema ladder.
        // PersistenceKit's migrate() runs v2→v3 (addColumn composition_policy)
        // only when the stored kit version is below 3; idempotent otherwise.
        storage
            .migrate(&CorpusIndexStateStore::schema_declaration())
            .map_err(|e| IndexCompositionColumnMigrationError::SchemaApplicationFailed {
                target: "CorpusKitIndexState".to_string(),
                reason: format!("{e:?}"),
            })?;

        // Step 2: re-apply the attached composite declaration so PersistenceKit
        // updates the composite version record ("CorpusKitAttached"). The tables
        // and indices already exist — this is a version-record update only.
        storage
            .migrate(&attached_declaration())
            .map_err(|e| IndexCompositionColumnMigrationError::SchemaApplicationFailed {
                target: "CorpusKitAttached".to_string(),
                reason: format!("{e:?}"),
            })?;

        // Step 3: advance the estate format to V1_2.
        EstateFormatStore::new(Arc::clone(&storage))
            .stamp(EstateFormatVersion::V1_2, now_millis)
            .map_err(|e| IndexCompositionColumnMigrationError::StampFailed {
                reason: format!("{e:?}"),
            })?;

        Ok(())
    }
}
