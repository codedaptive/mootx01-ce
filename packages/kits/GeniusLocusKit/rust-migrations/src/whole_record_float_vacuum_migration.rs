//! GLK estate-format 1.6 → 1.7 migration capsule.
//! Rust twin of Swift `WholeRecordFloatVacuumMigration.swift`.
//!
//! Root cause: the whole-record dense float lane left the default build
//! (ruling 2026-09-07; GENIUSLOCUSKIT_SPEC 3.6.0). A populated estate still
//! carries the rows that lane read: one `vectors` row of kind 1 (a float32
//! payload at vector_index 1) per indexed unit and model, and the
//! `hnsw_graph` rows of the float lane's approximate index. Nothing in the
//! default product reads either any more. The corpus-kit engine also still
//! held its representation claim on vector_index 1, and
//! `reconcile_configured_providers` would keep it alive. Bob ruled the rows
//! vacuumed by `mootx01 upgrade` rather than left for a later reclaim.
//!
//! What the capsule does (SYNAPSEKIT_SPEC `reclaim_whole_record_float_rows`;
//! GENIUSLOCUSKIT_SPEC I-26):
//!   1. Delete every `vectors` row of kind 1 and every `hnsw_graph` row, then
//!      rebuild the resident binary index and the `.vec` sidecar from the
//!      surviving rows so the sidecar's live count and generation match the
//!      serving table. Kind 0 (binary fingerprints) and kind 2 (Arctic spans)
//!      are never touched.
//!   2. Release the corpus-kit consumer's representation claims on
//!      vector_index 1 so the engine's reconcile, whose default-build lane
//!      list is `[0]`, finds its claims equal to its desires and re-creates
//!      nothing.
//!   3. Stamp the estate format V1_7.
//!
//! The lane is now always live. An
//! audition estate whose manifest names a whole-record provider (an
//! `embedding_provider` value that is present, non-empty and not the span
//! encoder) keeps its rows: the capsule stamps V1_7 without deleting
//! anything, so the format still records that the vacuum decision was taken
//! once. Every other estate is vacuumed under either build.
//!
//! Placement in the chain: LAST. The 1.5 → 1.6 capsule stamps V1_6 before
//! this one runs, so a crash mid-chain never leaves an estate stamped V1_7
//! with an older capsule's work undone. `run_migration_chain` calls
//! `run_whole_record_float_vacuum_migration` after the 1.5 → 1.6 stamp and
//! before `wire_substores`, which is where the engine would otherwise
//! reconcile its claims over the rows.
//!
//! Idempotent: a vacuumed estate deletes nothing, releases nothing and
//! rewrites an identical sidecar; the stamp is a no-op at V1_7. A fresh
//! estate is stamped current by the registry without running the capsule
//! and is born without the rows.

use corpus_kit::CLAIMS_CONSUMER;
use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::estate_format::{EstateFormatStore, EstateFormatVersion};
use genius_locus_kit::handle::EstateHandle;
use std::sync::Arc;
use synapsekit::{VectorRepresentationClaims, VectorStore};

/// What the capsule left behind.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WholeRecordFloatVacuumMigrationReport {
    /// `vectors` rows of kind 1 deleted by this run.
    pub float_rows: usize,
    /// `hnsw_graph` rows deleted by this run.
    pub graph_rows: usize,
    /// corpus-kit representation claims on vector_index 1 released by this run.
    pub claims_released: usize,
    /// True when the rows were vacuumed (every default-build run); false when
    /// whole-record lane found a whole-record provider named in
    /// the manifest and left an audition estate's rows in place.
    pub vacuumed: bool,
    /// The estate format the capsule stamped.
    pub format: EstateFormatVersion,
}

/// Errors thrown by the whole-record float vacuum migration capsule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WholeRecordFloatVacuumMigrationError {
    /// The estate's storage backend could not be accessed.
    StorageUnavailable { reason: String },
    /// The float or graph rows could not be deleted or the sidecar rebuilt.
    VacuumFailed { reason: String },
    /// The representation claim on vector_index 1 could not be released.
    ClaimReleaseFailed { reason: String },
    /// The estate-format stamp could not be written.
    StampFailed { reason: String },
}

impl std::fmt::Display for WholeRecordFloatVacuumMigrationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::StorageUnavailable { reason } => write!(
                f,
                "whole-record float vacuum migration: storage unavailable — {reason}"
            ),
            Self::VacuumFailed { reason } => {
                write!(f, "whole-record float vacuum migration: vacuum failed — {reason}")
            }
            Self::ClaimReleaseFailed { reason } => write!(
                f,
                "whole-record float vacuum migration: claim release failed — {reason}"
            ),
            Self::StampFailed { reason } => write!(
                f,
                "whole-record float vacuum migration: estate-format stamp failed — {reason}"
            ),
        }
    }
}

impl std::error::Error for WholeRecordFloatVacuumMigrationError {}

/// Extension trait that adds the GLK 1.6 → 1.7 capsule to `EstateCoordinator`.
pub trait WholeRecordFloatVacuumMigrationExt {
    /// Run the 1.6 → 1.7 whole-record float vacuum migration: delete the
    /// whole-record float rows (`vectors` kind 1) and the `hnsw_graph` rows,
    /// rebuild the binary sidecar from the surviving rows, release the
    /// corpus-kit claims on vector_index 1, then stamp V1_7.
    ///
    /// Safe to call on any estate at V1_6 or later: a vacuumed estate deletes
    /// nothing and the stamp is a no-op at V1_7. Returns the row and claim
    /// counts and the stamped format.
    fn run_whole_record_float_vacuum_migration(
        &self,
        handle: &EstateHandle,
        now_millis: i64,
    ) -> Result<WholeRecordFloatVacuumMigrationReport, WholeRecordFloatVacuumMigrationError>;
}

impl WholeRecordFloatVacuumMigrationExt for EstateCoordinator {
    fn run_whole_record_float_vacuum_migration(
        &self,
        handle: &EstateHandle,
        now_millis: i64,
    ) -> Result<WholeRecordFloatVacuumMigrationReport, WholeRecordFloatVacuumMigrationError> {
        let storage = self.migration_storage(handle).ok_or_else(|| {
            WholeRecordFloatVacuumMigrationError::StorageUnavailable {
                reason: "no storage registered for estate".to_string(),
            }
        })?;

        {
            // The audition build: an estate provisioned with a whole-record
            // provider keeps its float rows. The span encoder is a rerank
            // stage, never a whole-record provider, so "encoder" vacuums like
            // the default ensemble does.
            if let Ok(Some(provisioned)) = self.provisioned_embedding_provider(handle) {
                if !provisioned.is_empty()
                    && provisioned != EstateCoordinator::ENCODER_PROVIDER_ID
                {
                    EstateFormatStore::new(Arc::clone(&storage))
                        .stamp(EstateFormatVersion::V1_7, now_millis)
                        .map_err(|e| WholeRecordFloatVacuumMigrationError::StampFailed {
                            reason: format!("{e:?}"),
                        })?;
                    return Ok(WholeRecordFloatVacuumMigrationReport {
                        float_rows: 0,
                        graph_rows: 0,
                        claims_released: 0,
                        vacuumed: false,
                        format: EstateFormatVersion::V1_7,
                    });
                }
            }
        }

        // Step 1: the rows and the sidecar. The store is opened on the estate
        // storage with the conventional sidecar path so the rebuild rewrites
        // the file `serve` will load. Both SynapseKit declarations are brought
        // to their current ladder position first (SYNAPSEKIT_SPEC I-10: the
        // ledger preparation before every migrate), so an estate that never
        // registered the vector tier or the claims ledger gains the tables
        // empty rather than failing the delete.
        let vacuum_err = |e: String| WholeRecordFloatVacuumMigrationError::VacuumFailed { reason: e };
        VectorStore::prepare_schema_ledger(storage.as_ref()).map_err(|e| vacuum_err(format!("{e:?}")))?;
        storage
            .migrate(&VectorStore::schema_declaration())
            .map_err(|e| vacuum_err(format!("{e:?}")))?;
        VectorRepresentationClaims::prepare_schema_ledger(storage.as_ref())
            .map_err(|e| vacuum_err(format!("{e:?}")))?;
        storage
            .migrate(&VectorRepresentationClaims::schema_declaration())
            .map_err(|e| vacuum_err(format!("{e:?}")))?;
        let vectors = VectorStore::new(
            Arc::clone(&storage),
            VectorStore::default_sidecar_path(&storage),
        );
        let (float_rows, graph_rows) = vectors
            .reclaim_whole_record_float_rows()
            .map_err(|e| WholeRecordFloatVacuumMigrationError::VacuumFailed {
                reason: format!("{e:?}"),
            })?;

        // Step 2: the representation claim on the float lane.
        let claims = VectorRepresentationClaims::new(Arc::clone(&storage));
        let mut claims_released = 0usize;
        let held = claims.claims(CLAIMS_CONSUMER).map_err(|e| {
            WholeRecordFloatVacuumMigrationError::ClaimReleaseFailed {
                reason: format!("{e:?}"),
            }
        })?;
        for key in held.iter().filter(|key| key.vector_index == 1) {
            claims.release_claim(CLAIMS_CONSUMER, key).map_err(|e| {
                WholeRecordFloatVacuumMigrationError::ClaimReleaseFailed {
                    reason: format!("{e:?}"),
                }
            })?;
            claims_released += 1;
        }

        // Step 3: advance the estate format to V1_7.
        EstateFormatStore::new(Arc::clone(&storage))
            .stamp(EstateFormatVersion::V1_7, now_millis)
            .map_err(|e| WholeRecordFloatVacuumMigrationError::StampFailed {
                reason: format!("{e:?}"),
            })?;
        Ok(WholeRecordFloatVacuumMigrationReport {
            float_rows,
            graph_rows,
            claims_released,
            vacuumed: true,
            format: EstateFormatVersion::V1_7,
        })
    }
}
