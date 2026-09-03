//! GLK estate-format 1.3 → 1.4 migration capsule.
//! Rust twin of Swift `IndexCompositionSettingMigration.swift`.
//!
//! Root cause: the index composition policy (which text each search index
//! lane is built from) became a stored estate setting, LocusKit manifest key
//! `index_composition_policy`, read by GeniusLocusKit at every open. Estates
//! written before format 1.4 carry no such row, so this capsule seeds it:
//! the creation-time seed, `MOOT_INDEX_COMPOSITION` when it is set to a valid
//! policy id at upgrade time, else `IndexCompositionPolicy::current()`, the
//! policy their rows were built under. The setting's presence then becomes a
//! stamped estate-format fact (I-23). No table, column, or row of the index
//! changes.
//!
//! Migration steps (all idempotent):
//!   1. Seed the setting when absent through
//!      `EstateCoordinator::seed_index_composition_policy_if_absent`; a
//!      stored setting is left untouched.
//!   2. Stamp the estate format V1_4.

use corpus_kit::index_composition_policy::IndexCompositionPolicy;
use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::estate_format::{EstateFormatStore, EstateFormatVersion};
use genius_locus_kit::handle::EstateHandle;
use std::sync::Arc;

/// Errors thrown by the index-composition-setting migration capsule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IndexCompositionSettingMigrationError {
    /// The estate's storage backend could not be accessed.
    StorageUnavailable { reason: String },
    /// The setting could not be read or written.
    SettingWriteFailed { reason: String },
    /// The estate-format stamp could not be written.
    StampFailed { reason: String },
}

impl std::fmt::Display for IndexCompositionSettingMigrationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::StorageUnavailable { reason } => {
                write!(f, "index-composition-setting migration: storage unavailable — {reason}")
            }
            Self::SettingWriteFailed { reason } => {
                write!(f, "index-composition-setting migration: setting write failed — {reason}")
            }
            Self::StampFailed { reason } => {
                write!(f, "index-composition-setting migration: estate-format stamp failed — {reason}")
            }
        }
    }
}

impl std::error::Error for IndexCompositionSettingMigrationError {}

/// Extension trait that adds the GLK 1.3 → 1.4 capsule to `EstateCoordinator`.
pub trait IndexCompositionSettingMigrationExt {
    /// Run (or resume) the 1.3 → 1.4 index-composition-setting migration.
    ///
    /// Stores the index composition setting when the estate carries none
    /// (the creation-time seed: `MOOT_INDEX_COMPOSITION` when set to a valid
    /// policy id, else `current()`), then stamps the estate format V1_4.
    ///
    /// Safe to call on any estate at V1_3 or later: a stored setting is left
    /// untouched and the stamp is a no-op when the estate is already at V1_4.
    /// Returns the policy the estate runs under.
    fn run_index_composition_setting_migration(
        &self,
        handle: &EstateHandle,
        now_millis: i64,
    ) -> Result<IndexCompositionPolicy, IndexCompositionSettingMigrationError>;
}

impl IndexCompositionSettingMigrationExt for EstateCoordinator {
    fn run_index_composition_setting_migration(
        &self,
        handle: &EstateHandle,
        now_millis: i64,
    ) -> Result<IndexCompositionPolicy, IndexCompositionSettingMigrationError> {
        let storage = self
            .migration_storage(handle)
            .ok_or_else(|| IndexCompositionSettingMigrationError::StorageUnavailable {
                reason: "no storage registered for estate".to_string(),
            })?;

        // Step 1: seed the setting when absent. The seed reads the process
        // environment once, here, at upgrade time.
        let policy = self
            .seed_index_composition_policy_if_absent(handle)
            .map_err(|e| IndexCompositionSettingMigrationError::SettingWriteFailed {
                reason: format!("{e:?}"),
            })?;

        // Step 2: advance the estate format to V1_4.
        EstateFormatStore::new(Arc::clone(&storage))
            .stamp(EstateFormatVersion::V1_4, now_millis)
            .map_err(|e| IndexCompositionSettingMigrationError::StampFailed {
                reason: format!("{e:?}"),
            })?;

        Ok(policy)
    }
}
