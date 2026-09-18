//! GLK estate-format 1.8 → 1.9 migration capsule.
//! Rust twin of Swift `PreferenceSeedMigration.swift`.
//!
//! Root cause: the five remaining estate preferences (`consolidation`,
//! `contradiction_sweep`, `cross_encoder_routing`, `maintenance`,
//! `adaptive_recall`) follow the same opt-out model as `fact_extraction` —
//! on by default — and the recall rating ledger (`recall_ratings`) became a
//! stored estate table. Estates written before format 1.9 carry neither, so
//! this capsule seeds each absent preference as `"on"`, leaving any
//! already-stored value untouched, and creates the empty rating table. Both
//! then become stamped estate-format facts (GENIUSLOCUSKIT_SPEC I-28).
//!
//! Migration steps (all idempotent):
//!   1. Seed each preference when absent: for every `EstatePreferenceKey`
//!      except `FactExtraction` (seeded by the 1.7 → 1.8 capsule), write
//!      `"on"` only when the manifest carries no value for the key.
//!   2. Create the `recall_ratings` table when absent by applying LocusKit's
//!      `recall_rating::recall_ratings_schema()` — the one declaration of the
//!      table, the same value `DrawerStoreCore` applies on first use on a
//!      fresh estate — through the storage schema ladder.
//!   3. Stamp the estate format V1_9.

use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::estate_format::{EstateFormatStore, EstateFormatVersion};
use genius_locus_kit::estate_preference::{EstatePreferenceKey, EstatePreferenceValue};
use genius_locus_kit::handle::EstateHandle;
use persistence_kit::SchemaDeclaration;
use std::sync::Arc;

/// The capsule's handle on the recall rating ledger's schema. The table is
/// declared once, in LocusKit (`recall_rating::recall_ratings_schema`); this
/// is the same value, so the capsule and `DrawerStoreCore`'s first-use
/// creation apply an identical kit id, version and column set and `migrate`
/// is a no-op once either has created the table.
pub fn recall_ratings_schema_declaration() -> SchemaDeclaration {
    locus_kit::recall_rating::recall_ratings_schema()
}

/// The preference keys the 1.8 → 1.9 capsule seeds: every key except
/// `FactExtraction` (seeded by the 1.7 → 1.8 capsule) and `FactExtractor`
/// (absent reads as `Nuextract`; no seeding capsule for the extractor choice).
pub fn preference_seed_keys() -> Vec<EstatePreferenceKey> {
    EstatePreferenceKey::ALL
        .into_iter()
        .filter(|key| {
            // The switches that default on. `fact_extraction` has its own
            // capsule, `fact_extractor` is an engine choice, and the chest
            // switches (ADR-027) default off and are never seeded.
            *key != EstatePreferenceKey::FactExtraction
                && key.default_value() == EstatePreferenceValue::On
        })
        .collect()
}

/// Errors thrown by the preference-seed migration capsule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PreferenceSeedMigrationError {
    /// The estate's storage backend could not be accessed.
    StorageUnavailable { reason: String },
    /// A preference could not be written.
    SettingWriteFailed { reason: String },
    /// The `recall_ratings` table could not be created.
    TableCreateFailed { reason: String },
    /// The estate-format stamp could not be written.
    StampFailed { reason: String },
}

impl std::fmt::Display for PreferenceSeedMigrationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::StorageUnavailable { reason } => write!(
                f,
                "preference-seed migration: storage unavailable — {reason}"
            ),
            Self::SettingWriteFailed { reason } => write!(
                f,
                "preference-seed migration: setting write failed — {reason}"
            ),
            Self::TableCreateFailed { reason } => write!(
                f,
                "preference-seed migration: recall_ratings table create failed — {reason}"
            ),
            Self::StampFailed { reason } => write!(
                f,
                "preference-seed migration: estate-format stamp failed — {reason}"
            ),
        }
    }
}

impl std::error::Error for PreferenceSeedMigrationError {}

pub trait PreferenceSeedMigrationExt {
    /// Run the GLK 1.8 → 1.9 preference-seed migration for an estate.
    ///
    /// Writes `"on"` to the estate manifest for each of the five seeded
    /// preference keys whose value is absent (the on-by-default seed),
    /// creates the `recall_ratings` table when absent, then stamps the
    /// estate format V1_9.
    ///
    /// Safe to call on any estate at V1_8 or later: an estate that already
    /// carries a value for a key keeps it, the table creation is a no-op once
    /// the table exists, and the stamp is a no-op when the estate is already
    /// at V1_9.
    fn run_preference_seed_migration(
        &self,
        handle: &EstateHandle,
        now_millis: i64,
    ) -> Result<(), PreferenceSeedMigrationError>;
}

impl PreferenceSeedMigrationExt for EstateCoordinator {
    fn run_preference_seed_migration(
        &self,
        handle: &EstateHandle,
        now_millis: i64,
    ) -> Result<(), PreferenceSeedMigrationError> {
        let storage = self.migration_storage(handle).ok_or_else(|| {
            PreferenceSeedMigrationError::StorageUnavailable {
                reason: "no storage registered for estate".to_string(),
            }
        })?;

        // Step 1: seed each key as "on" only when the key is absent. An
        // estate that already carries a value — including "off" — keeps it.
        // meta() returns Ok(None) for an absent key, Ok(Some(_)) for a present
        // one. The read must propagate errors: collapsing a storage failure
        // into None would silently write "on" over an estate that holds "off".
        let estate = self.estate_for(handle).map_err(|e| {
            PreferenceSeedMigrationError::StorageUnavailable {
                reason: format!("estate not open: {e:?}"),
            }
        })?;
        for key in preference_seed_keys() {
            let existing = estate.meta(key.as_str()).map_err(|e| {
                PreferenceSeedMigrationError::StorageUnavailable {
                    reason: format!("{} key read failed: {e:?}", key.as_str()),
                }
            })?;
            if existing.is_none() {
                self.provision_preference(handle, key, EstatePreferenceValue::On)
                    .map_err(|e| PreferenceSeedMigrationError::SettingWriteFailed {
                        reason: format!("{}: {e:?}", key.as_str()),
                    })?;
            }
        }

        // Step 2: the rating table. The schema ladder creates it when absent
        // and leaves it untouched when the ledger already records version 1.
        storage
            .migrate(&recall_ratings_schema_declaration())
            .map_err(|e| PreferenceSeedMigrationError::TableCreateFailed {
                reason: format!("{e:?}"),
            })?;

        // Step 3: advance the estate format to V1_9.
        EstateFormatStore::new(Arc::clone(&storage))
            .stamp(EstateFormatVersion::V1_9, now_millis)
            .map_err(|e| PreferenceSeedMigrationError::StampFailed {
                reason: format!("{e:?}"),
            })
    }
}
