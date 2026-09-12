//! kg_fact_search_projection_backfill.rs
//!
//! One-shot, re-runnable backfill that populates `kg_facts.searchProjection`
//! and `kg_facts.searchProjectionVersion` for rows the v19 → v20 migration
//! added those columns to. Mirrors Swift `KGFactSearchProjectionBackfill.swift`
//! rule-for-rule: identical scan logic, identical row counts for the same input.
//!
//! Run ONLY by `mootx01 upgrade` — Bob's ruling makes upgrade the sole
//! migration vehicle: no detection or prompting lives anywhere else (not
//! serve, not install, not the App, not an MCP tool).
//!
//! Design invariant, inherited from the estate encryption migration:
//!
//!   EVERY FAILURE PATH LEAVES A WORKING ESTATE AT THE CANONICAL PATH.
//!
//! Met without a clone → verify → swap shape because filling two columns is
//! per-row atomic: each UPDATE sets searchProjection and
//! searchProjectionVersion together, so the row is always in one of two
//! readable shapes. A crash mid-run is completed by the next run.
//! Idempotence: rows whose searchProjectionVersion already equals the target
//! version are skipped — a second run over a fully-projected estate reports
//! scanned: 0.
//!
//! Alias note: the build function is called with aliases:[] for all backfilled
//! rows. The aliases a fresh extraction would have computed are not stored in
//! any column and cannot be recovered. A backfilled fact matches subject,
//! predicate, and object tokens but not alias synonyms — it ranks slightly
//! below a freshly extracted fact but is no longer invisible to recall.

use std::collections::BTreeMap;

use persistence_kit::predicate::StoragePredicate;
use persistence_kit::storage::Storage;
use persistence_kit::types::{Column, StorageRow, TypedValue};

use crate::error::LocusKitError;
use crate::schema::schema;

/// Per-row counts from one backfill run. Mirrors Swift
/// `KGFactSearchProjectionBackfillReport`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct KGFactSearchProjectionBackfillReport {
    /// Rows examined (searchProjectionVersion differed from the target version).
    pub scanned: usize,
    /// Rows updated (projection written successfully).
    pub updated: usize,
}

/// Run the backfill against `storage`.
///
/// Opening the storage applies the LocusKit schema ladder first — the
/// v19 → v20 hop adds the searchProjection columns to estates that predate
/// them.
///
/// `build_projection` given (subject, predicate, object) returns the
/// search-projection string. The caller injects
/// `FactSearchProjection::build` from fact-extraction-kit — injected
/// because locus-kit sits below fact-extraction-kit and must not depend on it.
///
/// `projection_version` is the version token that marks a row as already
/// projected. The caller injects `FactSearchProjection::VERSION` from
/// fact-extraction-kit — same layering rationale as above.
pub fn run(
    storage: &dyn Storage,
    build_projection: &dyn Fn(&str, &str, &str) -> String,
    projection_version: &str,
) -> Result<KGFactSearchProjectionBackfillReport, LocusKitError> {
    // Apply the schema ladder (the v19 → v20 addColumn hop on a pre-v20 estate)
    // before any row below is read or written.
    storage.open(&schema()).map_err(storage_err)?;
    let rows = storage.row_store();

    // Every fact, retired included: a retired fact's missing projection is
    // still a missing projection.
    let fact_rows = rows
        .query("kg_facts", None, &[], None, None)
        .map_err(storage_err)?;

    let mut report = KGFactSearchProjectionBackfillReport::default();
    for row in &fact_rows {
        // Idempotence: skip rows that already carry the current version.
        if text_value(row, "searchProjectionVersion") == projection_version {
            continue;
        }
        report.scanned += 1;

        let subject   = text_value(row, "subject");
        let predicate = text_value(row, "predicate");
        let object    = text_value(row, "object");
        let fact_id   = text_value(row, "id");

        // Build the projection with empty aliases — aliases are derived at
        // extraction time and are not stored anywhere; we cannot recover them.
        // Passing an empty list means the backfilled fact matches s/p/o tokens
        // but not alias synonyms.
        let projection = build_projection(&subject, &predicate, &object);

        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert("searchProjection".to_string(), TypedValue::Text(projection));
        values.insert(
            "searchProjectionVersion".to_string(),
            TypedValue::Text(projection_version.to_string()),
        );
        rows.update("kg_facts", values, &fact_id_predicate(&fact_id))
            .map_err(storage_err)?;
        report.updated += 1;
    }
    Ok(report)
}

/// Predicate selecting one kg_facts row by primary key.
fn fact_id_predicate(fact_id: &str) -> StoragePredicate {
    StoragePredicate::Eq(
        Column::new("kg_facts", "id"),
        TypedValue::Text(fact_id.to_string()),
    )
}

/// Map a substrate fault to the kit error the caller reports.
fn storage_err(e: persistence_kit::error::StorageError) -> LocusKitError {
    LocusKitError::DatabaseUnavailable(format!("kg_fact search-projection backfill: {e}"))
}

/// TEXT read-back tolerant of `Text`/`Uuid`. Mirrors the Swift helper and
/// the pattern in kg_fact_identity_backfill.rs.
fn text_value(row: &StorageRow, name: &str) -> String {
    match row.get(name) {
        Some(TypedValue::Text(s)) => s.clone(),
        Some(TypedValue::Uuid(u)) => u.to_string(),
        _ => String::new(),
    }
}
