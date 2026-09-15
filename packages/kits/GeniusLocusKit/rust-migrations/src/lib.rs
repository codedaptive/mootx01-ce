//! Optional historical migration catalog for GeniusLocusKit.
//!
//! The default feature set is empty. Consumers select the oldest supported
//! estate-format floor; additive features compile only the contiguous capsules
//! from that floor to the current runtime.
//!
//! Geometry normalization is unconditional — it is a file-geometry concern, not
//! a schema concern, and runs on ANY plaintext estate with nonzero
//! reserved-bytes-per-page regardless of migration floor.
//!
//! Layout capsules: none, on purpose. The Swift umbrella carries two
//! (`GLKMigrationFlatLayoutToCatalog`, `GLKMigrationAppContainerToCatalog`)
//! because pre-catalog Swift installs kept their estate flat in the
//! configuration directory or in the Apple app container. No pre-catalog Rust
//! install ever had a flat layout: every Rust estate this port has written
//! lived under `<data directory>/databases/<name>/` (the shape the catalog
//! records as `<defaultLocation>/<name>/`), so there is nothing for a Rust
//! layout capsule to move (ruling R3, 2026-09-08; recorded in
//! ESTATE_CATALOG_S8_BLAST_RADIUS.md).
//!
//! Base-directory capsule: one, Rust only. The layout inside the base did not
//! move on this port, but on Windows the base ITSELF did, from
//! `%LOCALAPPDATA%\MOOTx01` to `%LOCALAPPDATA%\com.mootx01.ce`.
//! `windows_base_directory_adoption` moves the old base's whole content into
//! the new one before the catalog opens (ruling R4, 2026-09-08). The Swift
//! port needs no twin: its Apple base is `com.mootx01.ce` before the catalog
//! and after it. So the capsule sets of the two ports differ by the two
//! Swift-only layout steps and this one Rust-only base-directory step.

// Geometry normalization: unconditional — format-agnostic, not gated on any
// migration trait because the SQLCipher attachFunc heuristic bug affects any
// plaintext estate created by Apple's SEE-provisioned sqlite3 regardless of
// the estate's schema version.
mod estate_manifest_refresh;
pub use estate_manifest_refresh::*;

// Windows base-directory adoption: unconditional, for the same reason
// geometry normalization is. The old base can hold an estate of any format,
// so gating it on a migration floor would strand the machines furthest
// behind. It runs before the catalog opens, not inside the chain.
mod windows_base_directory_adoption;
pub use windows_base_directory_adoption::*;

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

// GLK 1.7 → 1.8 capsule: seeds `fact_extraction = "on"` on populated
// estates that carry no value for the key, making the on-by-default contract
// explicit and enabling controlled opt-out (parity with the Swift
// GLKMigrationV1_7ToV1_8 target).
#[cfg(feature = "migration-v1-7-to-v1-8")]
mod fact_extraction_setting_migration;

#[cfg(feature = "migration-v1-7-to-v1-8")]
pub use fact_extraction_setting_migration::*;

use genius_locus_kit::estate_format::{EstateFormatError, EstateFormatStore, EstateFormatVersion};
use std::sync::Arc;

/// Why `run_migration_chain` refused or failed. Mirrors the Swift
/// `GLKMigrationCatalogError` cases; `Capsule` and `Storage` carry the
/// capsule's own error text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MigrationChainError {
    /// The persisted estate format is older than the oldest capsule this
    /// build compiled; no chain reaches it.
    BelowCompiledFloor {
        found: EstateFormatVersion,
        floor: EstateFormatVersion,
    },
    /// The persisted estate format is newer than this runtime; a newer
    /// build owns that layout.
    UnsupportedFuture {
        found: EstateFormatVersion,
        current: EstateFormatVersion,
    },
    /// The estate is historical and this build compiled no chain that
    /// reaches the current format.
    NoHistoricalMigrationsCompiled {
        found: EstateFormatVersion,
        current: EstateFormatVersion,
    },
    /// The estate-format read or stamp failed.
    Storage(String),
    /// A compiled capsule failed; the text names the capsule and its error.
    Capsule(String),
}

impl std::fmt::Display for MigrationChainError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BelowCompiledFloor { found, floor } => write!(
                f,
                "estate format {found} is below this build's compiled migration floor {floor}"
            ),
            Self::UnsupportedFuture { found, current } => {
                write!(f, "estate format {found} is newer than this GLK {current} runtime")
            }
            Self::NoHistoricalMigrationsCompiled { found, current } => write!(
                f,
                "this GLK {current} build contains no historical migration capsules for estate format {found}"
            ),
            Self::Storage(reason) => write!(f, "estate-format store: {reason}"),
            Self::Capsule(reason) => write!(f, "{reason}"),
        }
    }
}

impl std::error::Error for MigrationChainError {}

impl From<EstateFormatError> for MigrationChainError {
    fn from(error: EstateFormatError) -> Self {
        Self::Storage(format!("{error:?}"))
    }
}

/// The compiled historical chain, run in format order from the persisted
/// estate format. Mirrors the Swift `GLKMigrationCatalog.prepare` dispatch:
///
/// 1. Read the stamp. An unstamped estate is a fresh bare open: it is
///    stamped current and no capsule runs. A current estate returns at
///    once. A stamp above `CURRENT` is refused (`UnsupportedFuture`); a
///    stamp below `compiled_floor()` is refused (`BelowCompiledFloor`); a
///    historical stamp in a build whose chain does not reach the current
///    format is refused (`NoHistoricalMigrationsCompiled`). A refusal
///    writes nothing.
/// 2. Dispatch from the detected version: the 1.4 -> 1.5 ledger rewrite
///    first (the 1.0 -> 1.1 capsule opens the vector store, whose ladder
///    must find its row under the new id), then 1.0 -> 1.1 (shared content,
///    which stamps 1.1) for a stamp below 1.1, then the 1.4 -> 1.5 stamp
///    (storage ledger kit ids) for a stamp below 1.5, then 1.5 -> 1.6 (the
///    composition_policy column drop, which stamps 1.6) for a stamp below
///    1.6, then 1.6 -> 1.7 (the whole-record float vacuum, which stamps 1.7)
///    for a stamp below 1.7, then 1.7 -> 1.8 (the fact-extraction-setting
///    seed, which writes the final stamp). No capsule separates the 1.1, 1.2,
///    1.3 and 1.4 stamps: the 1.1 -> 1.2 column is added by CorpusKit's own
///    ladder at open, the 1.2 -> 1.3 column was removed by schema v19, and
///    the 1.3 -> 1.4 setting retired with the index composition policy; the
///    1.4 -> 1.5 capsule runs directly on any of them.
///
/// Every capsule is idempotent, so a chain interrupted after a capsule's
/// stamp resumes from that stamp on the next call.
pub trait MigrationChainExt {
    /// Run the compiled capsules the persisted format calls for. `models`
    /// is the embedding ensemble the shared-content capsule rebuilds the
    /// derived lanes with; it is unused when that capsule is not compiled
    /// or not needed.
    fn run_migration_chain(
        &mut self,
        handle: &genius_locus_kit::handle::EstateHandle,
        now_millis: i64,
        models: Vec<corpus_kit::EmbeddingModelConfig>,
    ) -> Result<(), MigrationChainError>;
}

impl MigrationChainExt for genius_locus_kit::coordinator::EstateCoordinator {
    fn run_migration_chain(
        &mut self,
        handle: &genius_locus_kit::handle::EstateHandle,
        now_millis: i64,
        models: Vec<corpus_kit::EmbeddingModelConfig>,
    ) -> Result<(), MigrationChainError> {
        let storage = self.migration_storage(handle).ok_or_else(|| {
            MigrationChainError::Storage("no storage registered for estate".to_string())
        })?;
        let format_store = EstateFormatStore::new(Arc::clone(&storage));
        let found = match format_store.read_if_present()? {
            Some(found) => found,
            None => {
                // Fresh estate (no stamp): created by a bare open without
                // `provision`. Stamp current; no historical capsule applies.
                format_store.stamp(EstateFormatVersion::CURRENT, now_millis)?;
                return Ok(());
            }
        };
        if found == EstateFormatVersion::CURRENT {
            return Ok(());
        }
        if found > EstateFormatVersion::CURRENT {
            return Err(MigrationChainError::UnsupportedFuture {
                found,
                current: EstateFormatVersion::CURRENT,
            });
        }
        match compiled_floor() {
            Some(floor) if found < floor => {
                return Err(MigrationChainError::BelowCompiledFloor { found, floor });
            }
            Some(_) => {}
            None => {
                return Err(MigrationChainError::NoHistoricalMigrationsCompiled {
                    found,
                    current: EstateFormatVersion::CURRENT,
                });
            }
        }
        run_compiled_chain(self, handle, now_millis, models, found)
    }
}

/// The capsule dispatch behind `run_migration_chain`, entered only for a
/// historical stamp between the compiled floor and the current format. The
/// gate is the last capsule in the chain: a build without it cannot reach
/// the current format, whatever older capsules it compiled.
#[cfg(feature = "migration-v1-7-to-v1-8")]
fn run_compiled_chain(
    coordinator: &mut genius_locus_kit::coordinator::EstateCoordinator,
    handle: &genius_locus_kit::handle::EstateHandle,
    now_millis: i64,
    models: Vec<corpus_kit::EmbeddingModelConfig>,
    found: EstateFormatVersion,
) -> Result<(), MigrationChainError> {
    #[cfg(feature = "migration-v1-4-to-v1-5")]
    {
        // Step 1 of the 1.4 -> 1.5 capsule, ahead of the chain: move the
        // vector tier's ledger rows to their SynapseKit ids so no capsule
        // below, and no store wired after this call, opens under the old
        // id and replays the vector ladder (I-24). Idempotent; stamps
        // nothing.
        coordinator.rewrite_storage_ledger_kit_ids(handle).map_err(|error| {
            MigrationChainError::Capsule(format!("storage-ledger-kit-id rewrite: {error:?}"))
        })?;
    }
    #[cfg(feature = "migration-v1-0-to-v1-1")]
    if found < EstateFormatVersion::V1_1 {
        coordinator.run_shared_content_migration(handle, now_millis, models)
            .map_err(|error| {
                MigrationChainError::Capsule(format!("shared-content migration: {error:?}"))
            })?;
    }
    #[cfg(not(feature = "migration-v1-0-to-v1-1"))]
    let _ = models;
    // A build that compiles the 1.6 -> 1.7 capsule alone dispatches nothing
    // on `found`: the one capsule always applies below CURRENT.
    #[cfg(not(feature = "migration-v1-5-to-v1-6"))]
    let _ = found;
    #[cfg(feature = "migration-v1-4-to-v1-5")]
    if found < EstateFormatVersion::V1_5 {
        // Step 2 of the 1.4 -> 1.5 capsule: the rewrite again (a no-op
        // after the call at the top of the chain) and the V1_5 stamp,
        // written only now that every older capsule has stamped its own
        // format.
        coordinator.run_storage_ledger_kit_id_migration(handle, now_millis)
            .map_err(|error| {
                MigrationChainError::Capsule(format!(
                    "storage-ledger-kit-id migration: {error:?}"
                ))
            })?;
    }
    #[cfg(feature = "migration-v1-5-to-v1-6")]
    if found < EstateFormatVersion::V1_6 {
        // The 1.5 -> 1.6 capsule: replay CorpusKit's checkpoint ladder (v4
        // drops corpus_index_state.composition_policy) and write the V1_6
        // stamp (I-25).
        coordinator.run_index_composition_column_drop_migration(handle, now_millis)
            .map_err(|error| {
                MigrationChainError::Capsule(format!(
                    "index-composition column-drop migration: {error:?}"
                ))
            })?;
    }
    // The 1.6 -> 1.7 capsule: vacuum the whole-record float rows and the
    // hnsw_graph rows, rebuild the binary sidecar, release the float
    // representation claim and write the V1_7 stamp (I-26).
    #[cfg(feature = "migration-v1-6-to-v1-7")]
    if found < EstateFormatVersion::V1_7 {
        coordinator.run_whole_record_float_vacuum_migration(handle, now_millis)
            .map_err(|error| {
                MigrationChainError::Capsule(format!(
                    "whole-record float vacuum migration: {error:?}"
                ))
            })?;
    }
    // The 1.7 -> 1.8 capsule: seed `fact_extraction = "on"` when absent and
    // write the V1_8 stamp, the last write of the chain (I-27). `found` is
    // below CURRENT here, so the capsule always applies.
    coordinator.run_fact_extraction_setting_migration(handle, now_millis)
        .map_err(|error| {
            MigrationChainError::Capsule(format!(
                "fact-extraction-setting migration: {error:?}"
            ))
        })?;
    Ok(())
}

/// No compiled chain reaches the current format, so a historical estate
/// cannot be served by this build (the Swift catalog's
/// `noHistoricalMigrationsCompiled` branch).
#[cfg(not(feature = "migration-v1-7-to-v1-8"))]
fn run_compiled_chain(
    _coordinator: &mut genius_locus_kit::coordinator::EstateCoordinator,
    _handle: &genius_locus_kit::handle::EstateHandle,
    _now_millis: i64,
    _models: Vec<corpus_kit::EmbeddingModelConfig>,
    found: EstateFormatVersion,
) -> Result<(), MigrationChainError> {
    Err(MigrationChainError::NoHistoricalMigrationsCompiled {
        found,
        current: EstateFormatVersion::CURRENT,
    })
}

/// Returns the lowest estate format version this build can migrate from,
/// or `None` when no historical capsules are compiled.
pub fn compiled_floor() -> Option<EstateFormatVersion> {
    #[cfg(feature = "migration-v1-0-to-v1-1")]
    {
        // Floor covers the 1.0→1.1, 1.4→1.5, 1.5→1.6, 1.6→1.7 and 1.7→1.8 capsules.
        return Some(EstateFormatVersion::V1_0);
    }
    #[cfg(all(
        feature = "migration-v1-4-to-v1-5",
        not(feature = "migration-v1-0-to-v1-1")
    ))]
    {
        // The 1.4→1.5, 1.5→1.6, 1.6→1.7 and 1.7→1.8 capsules are compiled. They
        // serve every stamp from 1.1 up: nothing separates 1.1, 1.2, 1.3 and 1.4
        // any more.
        return Some(EstateFormatVersion::V1_1);
    }
    #[cfg(all(
        feature = "migration-v1-5-to-v1-6",
        not(feature = "migration-v1-4-to-v1-5"),
        not(feature = "migration-v1-0-to-v1-1")
    ))]
    {
        // The 1.5→1.6 column-drop, 1.6→1.7 vacuum and 1.7→1.8 seed capsules are compiled.
        return Some(EstateFormatVersion::V1_5);
    }
    #[cfg(all(
        feature = "migration-v1-6-to-v1-7",
        not(feature = "migration-v1-5-to-v1-6"),
        not(feature = "migration-v1-4-to-v1-5"),
        not(feature = "migration-v1-0-to-v1-1")
    ))]
    {
        // The 1.6→1.7 vacuum and 1.7→1.8 seed capsules are compiled.
        return Some(EstateFormatVersion::V1_6);
    }
    #[cfg(all(
        feature = "migration-v1-7-to-v1-8",
        not(feature = "migration-v1-6-to-v1-7"),
        not(feature = "migration-v1-5-to-v1-6"),
        not(feature = "migration-v1-4-to-v1-5"),
        not(feature = "migration-v1-0-to-v1-1")
    ))]
    {
        // Only the 1.7→1.8 fact-extraction-setting seed capsule is compiled.
        return Some(EstateFormatVersion::V1_7);
    }
    #[cfg(all(
        not(feature = "migration-v1-0-to-v1-1"),
        not(feature = "migration-v1-4-to-v1-5"),
        not(feature = "migration-v1-5-to-v1-6"),
        not(feature = "migration-v1-6-to-v1-7"),
        not(feature = "migration-v1-7-to-v1-8")
    ))]
    {
        None
    }
}
