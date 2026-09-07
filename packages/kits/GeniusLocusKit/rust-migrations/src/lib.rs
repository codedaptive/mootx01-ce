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

// GLK 1.4 → 1.5 capsule: moves the vector tier's schema-version ledger rows
// from their SynapseKit ids to their SynapseKit ids on populated estates
// (parity with the Swift GLKMigrationV1_4ToV1_5 target).
#[cfg(feature = "migration-v1-4-to-v1-5")]
mod storage_ledger_kit_id_migration;

#[cfg(feature = "migration-v1-4-to-v1-5")]
pub use storage_ledger_kit_id_migration::*;

// GLK 1.5 → 1.6 capsule: drops the retired corpus_index_state.composition_policy
// column from populated estates by replaying CorpusKit's checkpoint ladder
// (parity with the Swift GLKMigrationV1_5ToV1_6 target).
#[cfg(feature = "migration-v1-5-to-v1-6")]
mod index_composition_column_drop_migration;

#[cfg(feature = "migration-v1-5-to-v1-6")]
pub use index_composition_column_drop_migration::*;

// GLK 1.6 → 1.7 capsule: vacuums the whole-record float rows and the
// hnsw_graph rows from populated estates, rebuilds the binary sidecar and
// releases the float representation claim (parity with the Swift
// GLKMigrationV1_6ToV1_7 target).
#[cfg(feature = "migration-v1-6-to-v1-7")]
mod whole_record_float_vacuum_migration;

#[cfg(feature = "migration-v1-6-to-v1-7")]
pub use whole_record_float_vacuum_migration::*;

use genius_locus_kit::estate_format::EstateFormatVersion;

/// The compiled historical chain, run in format order. Every capsule reads
/// its own persisted state and is idempotent, so the chain is safe to run on
/// an estate at any compiled stamp; capsules whose work is already done
/// return without touching the estate. Mirrors the Swift
/// `GLKMigrationCatalog.prepare` dispatch: the 1.4 -> 1.5 ledger rewrite
/// first (the 1.0 -> 1.1 capsule opens the vector store, whose ladder must
/// find its row under the new id), then 1.0 -> 1.1 (shared content, which
/// stamps 1.1), then the 1.4 -> 1.5 stamp (storage ledger kit ids, which
/// stamps 1.5 only once every older capsule has stamped its own format),
/// then 1.5 -> 1.6 (the composition_policy column drop), then 1.6 -> 1.7
/// (the whole-record float vacuum, which writes the final stamp). No capsule
/// separates the 1.1, 1.2, 1.3 and 1.4 stamps: the
/// 1.1 -> 1.2 column is added by CorpusKit's own ladder at open, the
/// 1.2 -> 1.3 column was removed by schema v19, and the 1.3 -> 1.4 setting
/// retired with the index composition policy; the 1.4 -> 1.5 capsule runs
/// directly on any of them.
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
        #[cfg(feature = "migration-v1-4-to-v1-5")]
        {
            // Step 2 of the 1.4 -> 1.5 capsule: the rewrite again (a no-op
            // after the call at the top of the chain) and the V1_5 stamp,
            // written only now that every older capsule has stamped its own
            // format.
            self.run_storage_ledger_kit_id_migration(handle, now_millis)
                .map_err(|error| format!("storage-ledger-kit-id migration: {error:?}"))?;
        }
        #[cfg(feature = "migration-v1-5-to-v1-6")]
        {
            // The 1.5 -> 1.6 capsule: replay CorpusKit's checkpoint ladder
            // (v4 drops corpus_index_state.composition_policy) and write the
            // V1_6 stamp (I-25).
            self.run_index_composition_column_drop_migration(handle, now_millis)
                .map_err(|error| format!("index-composition column-drop migration: {error:?}"))?;
        }
        #[cfg(feature = "migration-v1-6-to-v1-7")]
        {
            // The 1.6 -> 1.7 capsule: vacuum the whole-record float rows and
            // the hnsw_graph rows, rebuild the binary sidecar, release the
            // float representation claim and write the V1_7 stamp, the last
            // write of the chain (I-26).
            self.run_whole_record_float_vacuum_migration(handle, now_millis)
                .map_err(|error| format!("whole-record float vacuum migration: {error:?}"))?;
        }
        Ok(())
    }
}

/// Returns the lowest estate format version this build can migrate from,
/// or `None` when no historical capsules are compiled.
pub fn compiled_floor() -> Option<EstateFormatVersion> {
    #[cfg(feature = "migration-v1-0-to-v1-1")]
    {
        // Floor covers the 1.0→1.1, 1.4→1.5, 1.5→1.6 and 1.6→1.7 capsules.
        return Some(EstateFormatVersion::V1_0);
    }
    #[cfg(all(
        feature = "migration-v1-4-to-v1-5",
        not(feature = "migration-v1-0-to-v1-1")
    ))]
    {
        // The 1.4→1.5, 1.5→1.6 and 1.6→1.7 capsules are compiled. They serve
        // every stamp from 1.1 up: nothing separates 1.1, 1.2, 1.3 and 1.4
        // any more.
        return Some(EstateFormatVersion::V1_1);
    }
    #[cfg(all(
        feature = "migration-v1-5-to-v1-6",
        not(feature = "migration-v1-4-to-v1-5"),
        not(feature = "migration-v1-0-to-v1-1")
    ))]
    {
        // The 1.5→1.6 column-drop and 1.6→1.7 vacuum capsules are compiled.
        return Some(EstateFormatVersion::V1_5);
    }
    #[cfg(all(
        feature = "migration-v1-6-to-v1-7",
        not(feature = "migration-v1-5-to-v1-6"),
        not(feature = "migration-v1-4-to-v1-5"),
        not(feature = "migration-v1-0-to-v1-1")
    ))]
    {
        // Only the 1.6→1.7 whole-record float vacuum capsule is compiled.
        return Some(EstateFormatVersion::V1_6);
    }
    #[cfg(all(
        not(feature = "migration-v1-0-to-v1-1"),
        not(feature = "migration-v1-4-to-v1-5"),
        not(feature = "migration-v1-5-to-v1-6"),
        not(feature = "migration-v1-6-to-v1-7")
    ))]
    {
        None
    }
}
