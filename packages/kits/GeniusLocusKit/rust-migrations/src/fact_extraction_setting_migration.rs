//! GLK estate-format 1.7 → 1.8 migration capsule.
//! Rust twin of Swift `FactExtractionSettingMigration.swift`.
//!
//! Root cause: fact extraction became a stored estate setting (manifest key
//! `fact_extraction`) with an opt-out model — on by default. Estates written
//! before format 1.8 carry no such row, so this capsule seeds it: `"on"`
//! when the key is absent, leaving any already-stored value untouched. The
//! setting's presence is then a stamped estate-format fact
//! (GENIUSLOCUSKIT_SPEC I-27).
//!
//! Migration steps (all idempotent):
//!   1. Seed `fact_extraction = "on"` only when the key is absent. An estate
//!      that already carries a value — including `"off"` — keeps it.
//!   2. Stamp the estate format V1_8.

use genius_locus_kit::coordinator::{EstateCoordinator, FactExtractionSetting};
use genius_locus_kit::estate_format::{EstateFormatStore, EstateFormatVersion};
use genius_locus_kit::handle::EstateHandle;
use std::sync::Arc;

/// Errors thrown by the fact-extraction-setting migration capsule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FactExtractionSettingMigrationError {
    /// The estate's storage backend could not be accessed.
    StorageUnavailable { reason: String },
    /// The setting could not be written.
    SettingWriteFailed { reason: String },
    /// The estate-format stamp could not be written.
    StampFailed { reason: String },
}

impl std::fmt::Display for FactExtractionSettingMigrationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::StorageUnavailable { reason } => write!(
                f,
                "fact-extraction-setting migration: storage unavailable — {reason}"
            ),
            Self::SettingWriteFailed { reason } => write!(
                f,
                "fact-extraction-setting migration: setting write failed — {reason}"
            ),
            Self::StampFailed { reason } => write!(
                f,
                "fact-extraction-setting migration: estate-format stamp failed — {reason}"
            ),
        }
    }
}

impl std::error::Error for FactExtractionSettingMigrationError {}

pub trait FactExtractionSettingMigrationExt {
    /// Run the GLK 1.7 → 1.8 fact-extraction-setting migration for an estate.
    ///
    /// Writes `fact_extraction = "on"` to the estate manifest when the key is
    /// absent (the on-by-default seed), then stamps the estate format V1_8.
    ///
    /// Safe to call on any estate at V1_7 or later: an estate that already
    /// carries a `fact_extraction` value keeps it, and the stamp is a no-op
    /// when the estate is already at V1_8.
    fn run_fact_extraction_setting_migration(
        &self,
        handle: &EstateHandle,
        now_millis: i64,
    ) -> Result<(), FactExtractionSettingMigrationError>;
}

impl FactExtractionSettingMigrationExt for EstateCoordinator {
    fn run_fact_extraction_setting_migration(
        &self,
        handle: &EstateHandle,
        now_millis: i64,
    ) -> Result<(), FactExtractionSettingMigrationError> {
        let storage = self.migration_storage(handle).ok_or_else(|| {
            FactExtractionSettingMigrationError::StorageUnavailable {
                reason: "no storage registered for estate".to_string(),
            }
        })?;

        // Step 1: seed `fact_extraction = "on"` only when the key is absent.
        // An estate that already carries a value — including "off" — keeps it.
        // meta() returns Ok(None) for an absent key, Ok(Some(_)) for a present one.
        // The read must propagate errors: collapsing a storage failure into
        // None would silently write "on" over an estate that holds "off".
        let estate = self.estate_for(handle).map_err(|e| {
            FactExtractionSettingMigrationError::StorageUnavailable {
                reason: format!("estate not open: {e:?}"),
            }
        })?;
        let existing = estate
            .meta(EstateCoordinator::FACT_EXTRACTION_META_KEY)
            .map_err(|e| FactExtractionSettingMigrationError::StorageUnavailable {
                reason: format!("fact_extraction key read failed: {e:?}"),
            })?;
        if existing.is_none() {
            estate
                .set_meta(
                    EstateCoordinator::FACT_EXTRACTION_META_KEY,
                    FactExtractionSetting::On.as_str(),
                )
                .map_err(|e| FactExtractionSettingMigrationError::SettingWriteFailed {
                    reason: format!("{e:?}"),
                })?;
        }

        // Step 2: advance the estate format to V1_8.
        EstateFormatStore::new(Arc::clone(&storage))
            .stamp(EstateFormatVersion::V1_8, now_millis)
            .map_err(|e| FactExtractionSettingMigrationError::StampFailed {
                reason: format!("{e:?}"),
            })
    }
}
