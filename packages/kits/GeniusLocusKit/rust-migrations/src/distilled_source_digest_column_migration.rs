//! GLK estate-format 1.2 → 1.3 migration capsule.
//! Rust twin of Swift `DistilledSourceDigestColumnMigration.swift`.
//!
//! Root cause: LocusKit schema reached v18 with an addColumn migration for
//! `distilled_source_digest TEXT NULL` on the drawers table — the SHA-256 of
//! the complete original content that the stored distilled representation
//! was rendered from. A row whose digest is NULL or differs from the digest
//! of its content is stale by definition and regenerates on the next sweep,
//! so the column has to exist on every estate before the currency rule can
//! be evaluated. LocusKit replays its own ladder at every store open, but the
//! composite declaration that populated estates are also opened through
//! (`genius_locus_kit::hydration::composite_schema`) carries no migrations
//! and records only the bumped composite version. This capsule makes the
//! column's presence a stamped estate-format fact (I-22) by replaying the
//! component kit's own ladder and re-applying the composite version record.
//!
//! Migration steps (all idempotent via PersistenceKit addColumn / CREATE IF NOT EXISTS):
//!   1. Apply `locus_kit::schema::schema()` through its own ladder.
//!      This replays the v17→v18 migration: addColumn distilled_source_digest.
//!   2. Apply `genius_locus_kit::hydration::composite_schema()` so the composite
//!      version record ("GeniusLocusKit") is updated. No-op on tables.
//!   3. Stamp the estate format V1_3.

use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::estate_format::{EstateFormatStore, EstateFormatVersion};
use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::hydration::composite_schema;
use std::sync::Arc;

/// Errors thrown by the distilled-source-digest-column migration capsule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DistilledSourceDigestColumnMigrationError {
    /// The estate's storage backend could not be accessed.
    StorageUnavailable { reason: String },
    /// A schema application step failed.
    SchemaApplicationFailed { target: String, reason: String },
    /// The estate-format stamp could not be written.
    StampFailed { reason: String },
}

impl std::fmt::Display for DistilledSourceDigestColumnMigrationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::StorageUnavailable { reason } => {
                write!(f, "distilled-source-digest-column migration: storage unavailable — {reason}")
            }
            Self::SchemaApplicationFailed { target, reason } => {
                write!(
                    f,
                    "distilled-source-digest-column migration: schema application failed for {target} — {reason}"
                )
            }
            Self::StampFailed { reason } => {
                write!(f, "distilled-source-digest-column migration: estate-format stamp failed — {reason}")
            }
        }
    }
}

impl std::error::Error for DistilledSourceDigestColumnMigrationError {}

/// Extension trait that adds the GLK 1.2 → 1.3 capsule to `EstateCoordinator`.
pub trait DistilledSourceDigestColumnMigrationExt {
    /// Run (or resume) the 1.2 → 1.3 distilled-source-digest-column migration.
    ///
    /// Applies `locus_kit::schema::schema()` through the component kit's own
    /// ladder (idempotent addColumn for distilled_source_digest), then
    /// re-applies the composite declaration to update the composite version
    /// record, then stamps the estate format V1_3.
    ///
    /// Safe to call on any estate at V1_2 or later: the addColumn is
    /// idempotent and the stamp is a no-op when the estate is already at V1_3.
    fn run_distilled_source_digest_column_migration(
        &self,
        handle: &EstateHandle,
        now_millis: i64,
    ) -> Result<(), DistilledSourceDigestColumnMigrationError>;
}

impl DistilledSourceDigestColumnMigrationExt for EstateCoordinator {
    fn run_distilled_source_digest_column_migration(
        &self,
        handle: &EstateHandle,
        now_millis: i64,
    ) -> Result<(), DistilledSourceDigestColumnMigrationError> {
        let storage = self
            .migration_storage(handle)
            .ok_or_else(|| DistilledSourceDigestColumnMigrationError::StorageUnavailable {
                reason: "no storage registered for estate".to_string(),
            })?;

        // Step 1: apply the component kit's own schema ladder.
        // PersistenceKit's migrate() runs v17→v18 (addColumn
        // distilled_source_digest) only when the stored kit version is below
        // 18; idempotent otherwise.
        let locus_schema = locus_kit::schema::schema();
        storage
            .migrate(&locus_schema)
            .map_err(|e| DistilledSourceDigestColumnMigrationError::SchemaApplicationFailed {
                target: locus_schema.kit_id.clone(),
                reason: format!("{e:?}"),
            })?;

        // Step 2: re-apply the composite declaration so PersistenceKit updates
        // the composite version record ("GeniusLocusKit"). The tables and
        // indices already exist — this is a version-record update only.
        let composite = composite_schema();
        storage
            .migrate(&composite)
            .map_err(|e| DistilledSourceDigestColumnMigrationError::SchemaApplicationFailed {
                target: composite.kit_id.clone(),
                reason: format!("{e:?}"),
            })?;

        // Step 3: advance the estate format to V1_3.
        EstateFormatStore::new(Arc::clone(&storage))
            .stamp(EstateFormatVersion::V1_3, now_millis)
            .map_err(|e| DistilledSourceDigestColumnMigrationError::StampFailed {
                reason: format!("{e:?}"),
            })?;

        Ok(())
    }
}
