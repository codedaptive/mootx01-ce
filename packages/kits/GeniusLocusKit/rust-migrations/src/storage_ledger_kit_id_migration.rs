//! GLK estate-format 1.4 → 1.5 migration capsule.
//! Rust twin of Swift `StorageLedgerKitIDMigration.swift`.
//!
//! Root cause: the vector tier was renamed VectorKit → SynapseKit (the old
//! name collided with Apple's MapKit VectorKit framework), and the tier's two
//! kit ids are stored values: one row each in PersistenceKit's schema-version
//! ledger in every populated estate. A store that finds no ledger row under
//! its declared id treats the estate as version 0 and replays its ladder from
//! the start; the vector store's v5→v6 step drops and recreates `vectors`.
//! This capsule moves both rows to their new ids through
//! `Storage::rename_schema_kit` (PERSISTENCEKIT_SPEC I-7a), keeping version
//! and applied-at, then stamps the estate format V1_5 (GENIUSLOCUSKIT_SPEC
//! I-24).
//!
//! Placement in the chain: the rewrite runs BEFORE every older capsule (the
//! 1.0→1.1 capsule opens the vector store) and the V1_5 stamp is written
//! LAST, after the 1.3→1.4 capsule has stamped V1_4, so a crash mid-chain
//! never leaves an estate stamped V1_5 with an older capsule's work undone.
//! `run_migration_chain` calls `rewrite_storage_ledger_kit_ids` first and
//! `run_storage_ledger_kit_id_migration` last. Both run before
//! `wire_substores`, which is where the renamed store opens.
//!
//! The (old, new) pairs are frozen history: the capsule rewrites exactly
//! these ids whatever the store declares later. A later rename needs its own
//! capsule.
//!
//! Migration steps (all idempotent):
//!   1. Rewrite each ledger pair in `STORAGE_LEDGER_KIT_ID_RENAMES`; a pair
//!      with no old row is a no-op, a pair with rows under both ids is
//!      reported and left as it is.
//!   2. Stamp the estate format V1_5.

use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::estate_format::{EstateFormatStore, EstateFormatVersion};
use genius_locus_kit::handle::EstateHandle;
use persistence_kit::{SchemaKitRenameOutcome, Storage};
use std::sync::Arc;

/// One (old, new) kit-id pair the 1.4 → 1.5 capsule rewrites in the
/// schema-version ledger.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StorageLedgerKitIdRename {
    /// The ledger id the row carries before the capsule runs.
    pub from: &'static str,
    /// The ledger id the row carries afterwards.
    pub to: &'static str,
}

/// The two ledger pairs the capsule rewrites.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StorageLedgerKitIdRenames {
    /// The vector store's row: `VectorKit` → `SynapseKit`.
    pub vector_store: StorageLedgerKitIdRename,
    /// The representation-claims ledger's row: `VectorKitClaims` → `SynapseKitClaims`.
    pub representation_claims: StorageLedgerKitIdRename,
}

/// The pairs, as frozen literals: these never follow a later rename of the
/// vector tier.
pub const STORAGE_LEDGER_KIT_ID_RENAMES: StorageLedgerKitIdRenames = StorageLedgerKitIdRenames {
    vector_store: StorageLedgerKitIdRename {
        from: "VectorKit",
        to: "SynapseKit",
    },
    representation_claims: StorageLedgerKitIdRename {
        from: "VectorKitClaims",
        to: "SynapseKitClaims",
    },
};

/// What the capsule found and did for each pair.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StorageLedgerKitIdMigrationReport {
    /// The vector store's row.
    pub vector_store: SchemaKitRenameOutcome,
    /// The representation-claims ledger's row.
    pub representation_claims: SchemaKitRenameOutcome,
}

/// Errors thrown by the storage-ledger kit-id migration capsule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StorageLedgerKitIdMigrationError {
    /// The estate's storage backend could not be accessed.
    StorageUnavailable { reason: String },
    /// The ledger row for `kit_id` could not be read or moved.
    RenameFailed { kit_id: String, reason: String },
    /// The estate-format stamp could not be written.
    StampFailed { reason: String },
}

impl std::fmt::Display for StorageLedgerKitIdMigrationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::StorageUnavailable { reason } => {
                write!(f, "storage-ledger kit-id migration: storage unavailable — {reason}")
            }
            Self::RenameFailed { kit_id, reason } => write!(
                f,
                "storage-ledger kit-id migration: ledger rename of {kit_id} failed — {reason}"
            ),
            Self::StampFailed { reason } => {
                write!(f, "storage-ledger kit-id migration: estate-format stamp failed — {reason}")
            }
        }
    }
}

impl std::error::Error for StorageLedgerKitIdMigrationError {}

/// Extension trait that adds the GLK 1.4 → 1.5 capsule to `EstateCoordinator`.
pub trait StorageLedgerKitIdMigrationExt {
    /// Move the vector tier's schema-version ledger rows to their SynapseKit
    /// ids without stamping anything (step 1 of the capsule).
    ///
    /// Safe to call on any estate at any format: a pair with no row under
    /// the old id is a no-op, and a pair with rows under both ids is left as
    /// it is and reported. `run_migration_chain` calls this first, before
    /// the 1.0 → 1.1 capsule opens the vector store.
    fn rewrite_storage_ledger_kit_ids(
        &self,
        handle: &EstateHandle,
    ) -> Result<StorageLedgerKitIdMigrationReport, StorageLedgerKitIdMigrationError>;

    /// Run the 1.4 → 1.5 storage-ledger kit-id migration: the rewrite (a
    /// no-op when it already ran earlier in the chain), then the V1_5 stamp.
    ///
    /// Safe to call on any estate at V1_4 or later: the stamp is a no-op when
    /// the estate is already at V1_5. Returns the outcomes this call found.
    fn run_storage_ledger_kit_id_migration(
        &self,
        handle: &EstateHandle,
        now_millis: i64,
    ) -> Result<StorageLedgerKitIdMigrationReport, StorageLedgerKitIdMigrationError>;
}

/// One pair through `Storage::rename_schema_kit`. Rows under both ids mean a
/// post-rename runtime already opened this estate under the new id, or the
/// old row was restored by hand; the capsule leaves both rows and the
/// operator decides.
fn rename(
    storage: &dyn Storage,
    pair: StorageLedgerKitIdRename,
) -> Result<SchemaKitRenameOutcome, StorageLedgerKitIdMigrationError> {
    storage
        .rename_schema_kit(pair.from, pair.to)
        .map_err(|e| StorageLedgerKitIdMigrationError::RenameFailed {
            kit_id: pair.from.to_string(),
            reason: format!("{e:?}"),
        })
}

impl StorageLedgerKitIdMigrationExt for EstateCoordinator {
    fn rewrite_storage_ledger_kit_ids(
        &self,
        handle: &EstateHandle,
    ) -> Result<StorageLedgerKitIdMigrationReport, StorageLedgerKitIdMigrationError> {
        let storage = self
            .migration_storage(handle)
            .ok_or_else(|| StorageLedgerKitIdMigrationError::StorageUnavailable {
                reason: "no storage registered for estate".to_string(),
            })?;
        let pairs = STORAGE_LEDGER_KIT_ID_RENAMES;
        let vector_store = rename(storage.as_ref(), pairs.vector_store)?;
        let representation_claims = rename(storage.as_ref(), pairs.representation_claims)?;
        Ok(StorageLedgerKitIdMigrationReport {
            vector_store,
            representation_claims,
        })
    }

    fn run_storage_ledger_kit_id_migration(
        &self,
        handle: &EstateHandle,
        now_millis: i64,
    ) -> Result<StorageLedgerKitIdMigrationReport, StorageLedgerKitIdMigrationError> {
        // Step 1: the rewrite (idempotent).
        let report = self.rewrite_storage_ledger_kit_ids(handle)?;

        // Step 2: advance the estate format to V1_5.
        let storage = self
            .migration_storage(handle)
            .ok_or_else(|| StorageLedgerKitIdMigrationError::StorageUnavailable {
                reason: "no storage registered for estate".to_string(),
            })?;
        EstateFormatStore::new(Arc::clone(&storage))
            .stamp(EstateFormatVersion::V1_5, now_millis)
            .map_err(|e| StorageLedgerKitIdMigrationError::StampFailed {
                reason: format!("{e:?}"),
            })?;
        Ok(report)
    }
}
