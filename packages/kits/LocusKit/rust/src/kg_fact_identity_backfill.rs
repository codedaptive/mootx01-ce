//! kg_fact_identity_backfill.rs
//!
//! MXE-MI: one-shot, re-runnable backfill that moves pre-MXE-KH
//! `kg_facts.sourceDrawerID` values into the identity column each value
//! actually belongs in (`addedBy`, `foreignSourceKey`, `foreignRecordID`).
//! Mirrors Swift `KGFactIdentityBackfill.swift` rule-for-rule: identical
//! classification, identical per-class counts for the same input.
//!
//! Run ONLY by `mootx01 upgrade` — Bob's ruling makes upgrade the sole
//! migration vehicle: no detection or prompting lives anywhere else (not
//! serve, not install, not the App, not an MCP tool).
//!
//! Design invariant, inherited from the estate encryption migration:
//!
//!   EVERY FAILURE PATH LEAVES A WORKING ESTATE AT THE CANONICAL PATH.
//!
//! Met without a clone → verify → swap shape because a column backfill
//! has no half-written-file hazard: every move is one per-row UPDATE
//! that sets the target column and clears `sourceDrawerID` together, so
//! each row is always in exactly one of two readable shapes and the
//! palace dedup anchor serves both (its fallback ladder reads
//! `foreign_record_id` then `source_drawer_id` when earlier columns are
//! empty). A crash mid-run is completed by the next run; a second run
//! over a migrated estate changes nothing because migrated rows leave
//! the scan set and class-A inheritance only fires on the all-zero
//! pre-KH bitmap shape.
//!
//! Classification is deterministic, never heuristic: a value moves only
//! when EXACTLY ONE of the four evidence rules matches. Zero matches or
//! multiple matches leave the row in place, counted — a misfiled
//! identity is worse than an unmigrated one, because the unmigrated one
//! is still findable.

use std::collections::{BTreeMap, HashMap, HashSet};

use persistence_kit::predicate::StoragePredicate;
use persistence_kit::storage::Storage;
use persistence_kit::types::{Column, StorageRow, TypedValue};
use uuid::Uuid;

use crate::error::LocusKitError;
use crate::schema::schema;

/// Per-class row counts from one backfill run — the audit trail the
/// mission requires. Every scanned row lands in exactly one bucket;
/// `inheritance_applied` is a subset annotation on `local_drawer_ids`,
/// not a bucket. Mirrors Swift `KGFactIdentityBackfillReport`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct KGFactIdentityBackfillReport {
    /// Rows whose `sourceDrawerID` was non-empty (the scan set).
    pub scanned: usize,
    /// Class A: resolves against this estate's `drawers.id` — left as is.
    pub local_drawer_ids: usize,
    /// Class-A rows whose all-zero pre-KH bitmaps were backfilled with
    /// the source drawer's bitmaps (MXE-KH inheritance, retroactive).
    pub inheritance_applied: usize,
    /// Class D: a known MCP host identity, moved to `addedBy`.
    pub host_identities: usize,
    /// Class B: a foreign palace stable source key, moved to
    /// `foreignSourceKey`.
    pub foreign_palace_keys: usize,
    /// Class C: an imported triple's own id, moved to `foreignRecordID`.
    pub triple_ids: usize,
    /// Zero rules matched, more than one matched, or the target column
    /// was unexpectedly occupied — left in place, counted.
    pub unclassified: usize,
}

/// Every host identity ever compiled into a production
/// `serverIdentity`/`server_identity`. CLOSED by code audit, never
/// guessed by string shape:
///   - "mootx01"         — every Rust entry point since PAR-MCP-2, and
///                         Swift `ServeCommand`.
///   - "aria-mcp-server" — the Swift standalone server and the
///                         `ToolDispatcher` default parameter.
///   - "aria-mcp"        — the Rust standalone server's banner before
///                         PAR-MCP-2 corrected it to "mootx01"; estates
///                         written by that build carry it.
///   - "Gateway"         — the App's `MootBridge.attachSQLite` default
///                         `serverName`, forwarded verbatim as the host
///                         identity for disk estates served through the
///                         App gateway.
pub const KNOWN_HOST_IDENTITIES: [&str; 4] =
    ["mootx01", "aria-mcp-server", "aria-mcp", "Gateway"];

/// Run the backfill against `storage`.
///
/// Opening the storage applies the LocusKit schema ladder first — the
/// v12 → v13 migration adds the three identity columns to estates that
/// predate them, which is why this routes through the substrate open
/// path and never raw SQLite.
///
/// `resolve_foreign_key` maps a candidate stable source key to the
/// lineage id a palace import would have minted for it. The caller
/// injects VaultKit's `DrawerMapping::lineage_id_for_stable_source_key`
/// — injected because LocusKit sits below VaultKit and must not import
/// it.
pub fn run(
    storage: &dyn Storage,
    resolve_foreign_key: &dyn Fn(&str) -> Uuid,
) -> Result<KGFactIdentityBackfillReport, LocusKitError> {
    // Apply the schema ladder (v12 → v13 addColumn on a pre-KH estate)
    // before any row below is read or written.
    storage.open(&schema()).map_err(storage_err)?;
    let rows = storage.row_store();

    // Evidence 1 — the drawers table, ALL lifecycle states. A withdrawn
    // drawer's id is still a genuine local drawer id; no state predicate
    // belongs here.
    let drawer_rows = rows
        .query("drawers", None, &[], None, None)
        .map_err(storage_err)?;
    let mut drawer_bitmaps: HashMap<String, (i64, i64)> = HashMap::new();
    let mut lineage_set: HashSet<Uuid> = HashSet::new();
    for row in &drawer_rows {
        let id = text_value(row, "id");
        if !id.is_empty() {
            drawer_bitmaps.insert(
                id,
                (bitmap_value(row, "adjectiveBitmap"), bitmap_value(row, "provenance")),
            );
        }
        if let Ok(lineage) = Uuid::parse_str(&text_value(row, "lineageID")) {
            lineage_set.insert(lineage);
        }
    }

    // Evidence 2 — every fact, retired included: a retired fact's
    // misfiled identity is still a misfiled identity.
    let fact_rows = rows
        .query("kg_facts", None, &[], None, None)
        .map_err(storage_err)?;

    // Evidence 3 — triple ids. The importer files temporal-validity
    // siblings with `subject = <triple id>` and `predicate =
    // "temporal:…"`; nothing else ever writes a `temporal:` subject.
    let temporal_subjects: HashSet<String> = fact_rows
        .iter()
        .filter(|r| text_value(r, "predicate").starts_with("temporal:"))
        .map(|r| text_value(r, "subject"))
        .collect();

    let mut report = KGFactIdentityBackfillReport::default();
    for row in &fact_rows {
        let value = text_value(row, "sourceDrawerID");
        if value.is_empty() {
            continue;
        }
        report.scanned += 1;

        // Evaluate ALL FOUR rules; act only on exactly one match.
        let is_local_drawer = drawer_bitmaps.contains_key(&value);
        let is_host_identity = KNOWN_HOST_IDENTITIES.contains(&value.as_str());
        let is_foreign_key = lineage_set.contains(&resolve_foreign_key(&value));
        let is_triple_id = temporal_subjects.contains(&value);
        let matches = [is_local_drawer, is_host_identity, is_foreign_key, is_triple_id]
            .iter()
            .filter(|m| **m)
            .count();
        if matches != 1 {
            report.unclassified += 1;
            continue;
        }

        let fact_id = text_value(row, "id");
        if is_local_drawer {
            // Class A: correct where it is. Retro-apply MXE-KH's
            // inheritance ONLY to the pre-KH verb-default shape (both
            // bitmaps zero) — nonzero bitmaps carry real state
            // (retired, elevated, …) and are never clobbered.
            report.local_drawer_ids += 1;
            let (drawer_adj, drawer_prov) = drawer_bitmaps[&value];
            let fact_adj = bitmap_value(row, "adjectiveBitmap");
            let fact_prov = bitmap_value(row, "provenanceBitmap");
            if fact_adj == 0 && fact_prov == 0 && (drawer_adj != 0 || drawer_prov != 0) {
                let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
                values.insert("adjectiveBitmap".to_string(), TypedValue::Bitmap(drawer_adj));
                values.insert("provenanceBitmap".to_string(), TypedValue::Bitmap(drawer_prov));
                rows.update("kg_facts", values, &fact_id_predicate(&fact_id))
                    .map_err(storage_err)?;
                report.inheritance_applied += 1;
            }
            continue;
        }

        // Classes B/C/D move the value. The target must be empty: no
        // writer ever produced a row with both `sourceDrawerID` and an
        // identity column populated, so an occupied target means
        // evidence this rule set does not cover — leave it.
        let target_column = if is_host_identity {
            if !text_value(row, "addedBy").is_empty() {
                report.unclassified += 1;
                continue;
            }
            report.host_identities += 1;
            "addedBy"
        } else if is_foreign_key {
            if !text_value(row, "foreignSourceKey").is_empty() {
                report.unclassified += 1;
                continue;
            }
            report.foreign_palace_keys += 1;
            "foreignSourceKey"
        } else {
            if !text_value(row, "foreignRecordID").is_empty() {
                report.unclassified += 1;
                continue;
            }
            report.triple_ids += 1;
            "foreignRecordID"
        };
        // One UPDATE per row: target set and `sourceDrawerID` cleared
        // together, so the row is never in a half-moved state and a
        // re-run never sees it again.
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert(target_column.to_string(), TypedValue::Text(value.clone()));
        values.insert("sourceDrawerID".to_string(), TypedValue::Text(String::new()));
        rows.update("kg_facts", values, &fact_id_predicate(&fact_id))
            .map_err(storage_err)?;
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

/// Map a substrate fault to the kit error the caller reports. The
/// message names the operation context; storage details ride along.
fn storage_err(e: persistence_kit::error::StorageError) -> LocusKitError {
    LocusKitError::DatabaseUnavailable(format!("kg_fact identity backfill: {e}"))
}

/// TEXT read-back tolerant of `Text`/`Uuid` (SQLite stores UUIDs as
/// TEXT; InMemory round-trips the typed value). Mirrors the Swift
/// helper.
fn text_value(row: &StorageRow, name: &str) -> String {
    match row.get(name) {
        Some(TypedValue::Text(s)) => s.clone(),
        Some(TypedValue::Uuid(u)) => u.to_string(),
        _ => String::new(),
    }
}

/// Bitmap read-back tolerant of `Bitmap`/`Int` (SQLite reads integers
/// back as `Int`; InMemory preserves `Bitmap`). Mirrors the Swift
/// helper.
fn bitmap_value(row: &StorageRow, name: &str) -> i64 {
    match row.get(name) {
        Some(TypedValue::Bitmap(i)) | Some(TypedValue::Int(i)) => *i,
        _ => 0,
    }
}
