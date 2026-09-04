//! Optional historical migration catalog for GeniusLocusKit.
//!
//! The default feature set is empty. Consumers select the oldest supported
//! estate-format floor; additive features compile only the contiguous capsules
//! from that floor to the current runtime.
//!
//! Geometry normalization is unconditional — it is a file-geometry concern, not
//! a schema concern, and runs on ANY plaintext estate with nonzero
//! reserved-bytes-per-page regardless of migration floor.

// Geometry normalization: unconditional — format-agnostic, not gated on any
// migration trait because the SQLCipher attachFunc heuristic bug affects any
// plaintext estate created by Apple's SEE-provisioned sqlite3 regardless of
// the estate's schema version.
mod geometry_normalization;
pub use geometry_normalization::*;

#[cfg(feature = "migration-v1-0-to-v1-1")]
mod shared_content_migration;

#[cfg(feature = "migration-v1-0-to-v1-1")]
pub use shared_content_migration::*;

#[cfg(feature = "migration-v1-0-to-v1-1")]
mod distillation_storage_migration;

#[cfg(feature = "migration-v1-0-to-v1-1")]
pub use distillation_storage_migration::*;

// GLK 1.1 → 1.2 capsule: applies composition_policy column to corpus_index_state
// on estates created before corpus_index_state reached schema version 3 (parity with the Swift GLKMigrationV1_1ToV1_2 target).
#[cfg(feature = "migration-v1-1-to-v1-2")]
mod index_composition_column_migration;

#[cfg(feature = "migration-v1-1-to-v1-2")]
pub use index_composition_column_migration::*;

// GLK 1.2 → 1.3 capsule: applies the drawers distilled_source_digest column
// (LocusKit schema v18) on estates written before the column existed (parity
// with the Swift GLKMigrationV1_2ToV1_3 target).
#[cfg(feature = "migration-v1-2-to-v1-3")]
mod distilled_source_digest_column_migration;

#[cfg(feature = "migration-v1-2-to-v1-3")]
pub use distilled_source_digest_column_migration::*;

// GLK 1.3 → 1.4 capsule: stores the index composition setting (manifest key
// index_composition_policy) on estates written before the setting existed
// (parity with the Swift GLKMigrationV1_3ToV1_4 target).
#[cfg(feature = "migration-v1-3-to-v1-4")]
mod index_composition_setting_migration;

#[cfg(feature = "migration-v1-3-to-v1-4")]
pub use index_composition_setting_migration::*;

// GLK 1.4 → 1.5 capsule: moves the vector tier's schema-version ledger rows
// from their SynapseKit ids to their SynapseKit ids on populated estates
// (parity with the Swift GLKMigrationV1_4ToV1_5 target).
#[cfg(feature = "migration-v1-4-to-v1-5")]
mod storage_ledger_kit_id_migration;

#[cfg(feature = "migration-v1-4-to-v1-5")]
pub use storage_ledger_kit_id_migration::*;

use genius_locus_kit::estate_format::EstateFormatVersion;

/// The compiled historical chain, run in format order. Every capsule reads
/// its own persisted state and is idempotent, so the chain is safe to run on
/// an estate at any compiled stamp; capsules whose work is already done
/// return without touching the estate. Mirrors the Swift
/// `GLKMigrationCatalog.prepare` dispatch: the 1.4 -> 1.5 ledger rewrite
/// first (the 1.0 -> 1.1 capsule opens the vector store, whose ladder must
/// find its row under the new id), then 1.0 -> 1.1 (distillation storage
/// then shared content, which stamps 1.1), then 1.1 -> 1.2 (index composition
/// column, which stamps 1.2), then 1.2 -> 1.3 (distilled source digest column,
/// which stamps 1.3), then 1.3 -> 1.4 (index composition setting, which
/// stamps 1.4), then the 1.4 -> 1.5 stamp (storage ledger kit ids, which
/// stamps 1.5 only once every older capsule has stamped its own format).
pub trait MigrationChainExt {
    /// Run every compiled capsule for `handle`, oldest first. `models` is the
    /// embedding ensemble the shared-content capsule rebuilds the derived
    /// lanes with; it is unused when that capsule is not compiled.
    fn run_migration_chain(
        &mut self,
        handle: &genius_locus_kit::handle::EstateHandle,
        now_millis: i64,
        models: Vec<corpus_kit::EmbeddingModelConfig>,
    ) -> Result<(), String>;
}

impl MigrationChainExt for genius_locus_kit::coordinator::EstateCoordinator {
    fn run_migration_chain(
        &mut self,
        handle: &genius_locus_kit::handle::EstateHandle,
        now_millis: i64,
        models: Vec<corpus_kit::EmbeddingModelConfig>,
    ) -> Result<(), String> {
        #[cfg(feature = "migration-v1-4-to-v1-5")]
        {
            // Step 1 of the 1.4 -> 1.5 capsule, ahead of the chain: move the
            // vector tier's ledger rows to their SynapseKit ids so no capsule
            // below, and no store wired after this call, opens under the old
            // id and replays the vector ladder (I-24). Idempotent; stamps
            // nothing.
            self.rewrite_storage_ledger_kit_ids(handle)
                .map_err(|error| format!("storage-ledger-kit-id rewrite: {error:?}"))?;
        }
        #[cfg(feature = "migration-v1-0-to-v1-1")]
        {
            self.run_shared_content_migration(handle, now_millis, models)
                .map_err(|error| format!("shared-content migration: {error:?}"))?;
        }
        #[cfg(not(feature = "migration-v1-0-to-v1-1"))]
        let _ = models;
        #[cfg(feature = "migration-v1-1-to-v1-2")]
        {
            self.run_index_composition_column_migration(handle, now_millis)
                .map_err(|error| format!("index-composition-column migration: {error:?}"))?;
        }
        #[cfg(feature = "migration-v1-2-to-v1-3")]
        {
            self.run_distilled_source_digest_column_migration(handle, now_millis)
                .map_err(|error| format!("distilled-source-digest-column migration: {error:?}"))?;
        }
        #[cfg(feature = "migration-v1-3-to-v1-4")]
        {
            self.run_index_composition_setting_migration(handle, now_millis)
                .map_err(|error| format!("index-composition-setting migration: {error:?}"))?;
        }
        #[cfg(feature = "migration-v1-4-to-v1-5")]
        {
            // Step 2 of the 1.4 -> 1.5 capsule: the rewrite again (a no-op
            // after the call at the top of the chain) and the V1_5 stamp,
            // written only now that every older capsule has stamped its own
            // format.
            self.run_storage_ledger_kit_id_migration(handle, now_millis)
                .map_err(|error| format!("storage-ledger-kit-id migration: {error:?}"))?;
        }
        Ok(())
    }
}

/// Returns the lowest estate format version this build can migrate from,
/// or `None` when no historical capsules are compiled.
pub fn compiled_floor() -> Option<EstateFormatVersion> {
    #[cfg(feature = "migration-v1-0-to-v1-1")]
    {
        // Floor covers the 1.0→1.1, 1.1→1.2, 1.2→1.3, 1.3→1.4, and 1.4→1.5 capsules.
        return Some(EstateFormatVersion::V1_0);
    }
    #[cfg(all(
        feature = "migration-v1-1-to-v1-2",
        not(feature = "migration-v1-0-to-v1-1")
    ))]
    {
        // Floor covers the 1.1→1.2, 1.2→1.3, 1.3→1.4, and 1.4→1.5 capsules.
        return Some(EstateFormatVersion::V1_1);
    }
    #[cfg(all(
        feature = "migration-v1-2-to-v1-3",
        not(feature = "migration-v1-1-to-v1-2"),
        not(feature = "migration-v1-0-to-v1-1")
    ))]
    {
        // Floor covers the 1.2→1.3, 1.3→1.4, and 1.4→1.5 capsules.
        return Some(EstateFormatVersion::V1_2);
    }
    #[cfg(all(
        feature = "migration-v1-3-to-v1-4",
        not(feature = "migration-v1-2-to-v1-3"),
        not(feature = "migration-v1-1-to-v1-2"),
        not(feature = "migration-v1-0-to-v1-1")
    ))]
    {
        // Floor covers the 1.3→1.4 and 1.4→1.5 capsules.
        return Some(EstateFormatVersion::V1_3);
    }
    #[cfg(all(
        feature = "migration-v1-4-to-v1-5",
        not(feature = "migration-v1-3-to-v1-4"),
        not(feature = "migration-v1-2-to-v1-3"),
        not(feature = "migration-v1-1-to-v1-2"),
        not(feature = "migration-v1-0-to-v1-1")
    ))]
    {
        // Only the 1.4→1.5 capsule is compiled.
        return Some(EstateFormatVersion::V1_4);
    }
    #[cfg(all(
        not(feature = "migration-v1-0-to-v1-1"),
        not(feature = "migration-v1-1-to-v1-2"),
        not(feature = "migration-v1-2-to-v1-3"),
        not(feature = "migration-v1-3-to-v1-4"),
        not(feature = "migration-v1-4-to-v1-5")
    ))]
    {
        None
    }
}
