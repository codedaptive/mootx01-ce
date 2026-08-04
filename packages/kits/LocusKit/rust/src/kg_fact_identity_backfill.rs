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

// ---------------------------------------------------------------------------
// Tests — mirrors Swift `KGFactIdentityBackfillTests` case-for-case.
// The foreign-key resolver here is a test double keyed to fixed UUIDs —
// locus-kit must not depend on vault-kit. The REAL resolver
// (`DrawerMapping::lineage_id`) is injected by `mootx01 upgrade` and
// exercised end-to-end by vault-kit's re-import-after-backfill tests.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use persistence_kit::storage::{BackendConfiguration, EstateConfiguration};
    use persistence_kit::sqlite::SqliteStorage;

    use crate::drawer::Drawer;
    use crate::drawer_store::DrawerStore;
    use crate::drawer_store_inmemory::InMemoryDrawerStore;
    use crate::kg_fact::KGFact;

    const NOW: i64 = 1_700_000_000_000;

    /// The lineage the fake resolver mints for the one palace key the
    /// tests use — the estate-side drawer carries it, so rule B resolves.
    fn palace_lineage() -> Uuid {
        Uuid::parse_str("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE").unwrap()
    }

    fn palace_resolver(key: &str) -> Uuid {
        if key == "drawer_alpha_0001" {
            palace_lineage()
        } else {
            Uuid::nil()
        }
    }

    fn null_resolver(_key: &str) -> Uuid {
        Uuid::nil()
    }

    fn fact(id: &str, source: &str) -> KGFact {
        KGFact::new(
            id.to_string(),
            "s".to_string(),
            "p".to_string(),
            "o".to_string(),
            source.to_string(),
            NOW,
        )
    }

    fn drawer(id_label: &str) -> Drawer {
        // Deterministic UUID-shaped id from the label (drawer row ids are
        // UUID strings; the v4 hex alphabet only needs stable digits).
        let mut hex = String::new();
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        for b in id_label.bytes() {
            h ^= u64::from(b);
            h = h.wrapping_mul(0x1000_0000_01b3);
        }
        for i in 0..32 {
            hex.push(char::from_digit(((h >> (i % 16 * 4)) & 0xF) as u32, 16).unwrap());
        }
        let id = format!(
            "{}-{}-{}-{}-{}",
            &hex[0..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..32]
        );
        Drawer::new(&id, "content", "test-parent", "bilby", NOW, "test-v1")
    }

    /// Elevated sensitivity at bits 6–11 of the adjective bitmap
    /// (scale-gapped raw 16) — a legal composition the write gate accepts.
    const ELEVATED_ADJECTIVE: i64 = 16 << 6;

    #[test]
    fn every_class_lands_in_its_own_column_and_second_run_is_idempotent() {
        let store = InMemoryDrawerStore::new(NOW, None).unwrap();

        // Local anchor drawer with nonzero bitmaps (inheritance source).
        let mut anchor = drawer("anchor-drawer");
        anchor.adjective_bitmap = ELEVATED_ADJECTIVE;
        anchor.provenance = 5;
        let anchor_id = anchor.id.clone();
        store.add_drawer(&anchor, NOW).unwrap();
        // The imported drawer the palace key resolves to (rule B evidence).
        let mut imported = drawer("imported-drawer");
        imported.lineage_id = palace_lineage();
        store.add_drawer(&imported, NOW).unwrap();

        // Host identities — one per compiled-in value.
        store.add_kg_fact(&fact("f-moot", "mootx01")).unwrap();
        store.add_kg_fact(&fact("f-aria", "aria-mcp-server")).unwrap();
        store.add_kg_fact(&fact("f-aria-old", "aria-mcp")).unwrap();
        store.add_kg_fact(&fact("f-gw", "Gateway")).unwrap();
        // Foreign palace key (pre-KH Swift importer shape).
        store.add_kg_fact(&fact("f-palace", "drawer_alpha_0001")).unwrap();
        // Triple id (pre-KH Rust importer shape): main fact plus its
        // temporal sibling, both carrying the triple's own id.
        store.add_kg_fact(&fact("f-triple", "t_fleet_0001")).unwrap();
        let mut temporal = fact("f-triple-temporal", "t_fleet_0001");
        temporal.subject = "t_fleet_0001".to_string();
        temporal.predicate = "temporal:valid_from".to_string();
        temporal.object = "2020-01-01".to_string();
        store.add_kg_fact(&temporal).unwrap();
        // Genuine local anchor, pre-KH verb-default bitmaps (all zero).
        store.add_kg_fact(&fact("f-local", &anchor_id)).unwrap();
        // Unclassifiable: matches no rule.
        store.add_kg_fact(&fact("f-mystery", "mystery-999")).unwrap();

        let storage: &Arc<dyn Storage> = store.storage();
        let report = run(storage.as_ref(), &palace_resolver).unwrap();

        assert_eq!(report.scanned, 9);
        assert_eq!(report.host_identities, 4);
        assert_eq!(report.foreign_palace_keys, 1);
        assert_eq!(report.triple_ids, 2);
        assert_eq!(report.local_drawer_ids, 1);
        assert_eq!(report.inheritance_applied, 1);
        assert_eq!(report.unclassified, 1);

        let get = |id: &str| store.get_kg_fact(id).unwrap().unwrap();
        for id in ["f-moot", "f-aria", "f-aria-old", "f-gw"] {
            let f = get(id);
            assert!(!f.added_by.is_empty() && f.source_drawer_id.is_empty());
        }
        let palace = get("f-palace");
        assert_eq!(palace.foreign_source_key, "drawer_alpha_0001");
        assert!(palace.source_drawer_id.is_empty());
        let triple = get("f-triple");
        assert_eq!(triple.foreign_record_id, "t_fleet_0001");
        assert!(triple.source_drawer_id.is_empty());
        // Local anchor kept, sensitivity inherited from the drawer.
        let local = get("f-local");
        assert_eq!(local.source_drawer_id, anchor_id);
        assert_eq!(local.adjective_bitmap, ELEVATED_ADJECTIVE);
        assert_eq!(local.provenance_bitmap, 5);
        // Unclassifiable untouched.
        let mystery = get("f-mystery");
        assert_eq!(mystery.source_drawer_id, "mystery-999");
        assert!(mystery.added_by.is_empty());

        // Second run: moved rows have left the scan set; what remains is
        // the local anchor (inheritance already applied, does not fire
        // again) and the mystery row. Nothing changes.
        let before = store.all_kg_facts_including_retired().unwrap();
        let second = run(storage.as_ref(), &palace_resolver).unwrap();
        assert_eq!(second.scanned, 2);
        assert_eq!(second.local_drawer_ids, 1);
        assert_eq!(second.unclassified, 1);
        assert_eq!(second.host_identities, 0);
        assert_eq!(second.inheritance_applied, 0);
        let after = store.all_kg_facts_including_retired().unwrap();
        assert_eq!(after, before, "a second run must change nothing");
    }

    #[test]
    fn multi_match_stays_put() {
        let store = InMemoryDrawerStore::new(NOW, None).unwrap();
        let mut imported = drawer("imported-drawer");
        imported.lineage_id = palace_lineage();
        store.add_drawer(&imported, NOW).unwrap();

        // "t_ambiguous_0001" is BOTH a temporal subject (rule C) and — via
        // this test's resolver — a key resolving to an existing lineage
        // (rule B). Two matches → the value must not move.
        store.add_kg_fact(&fact("f-ambiguous", "t_ambiguous_0001")).unwrap();
        let mut temporal = fact("f-ambiguous-temporal", "");
        temporal.subject = "t_ambiguous_0001".to_string();
        temporal.predicate = "temporal:valid_to".to_string();
        store.add_kg_fact(&temporal).unwrap();

        let ambiguous_resolver = |key: &str| -> Uuid {
            if key == "t_ambiguous_0001" {
                palace_lineage()
            } else {
                Uuid::nil()
            }
        };
        let storage: &Arc<dyn Storage> = store.storage();
        let report = run(storage.as_ref(), &ambiguous_resolver).unwrap();

        assert_eq!(report.scanned, 1);
        assert_eq!(report.unclassified, 1);
        let f = store.get_kg_fact("f-ambiguous").unwrap().unwrap();
        assert_eq!(
            f.source_drawer_id, "t_ambiguous_0001",
            "a multi-match value must never be moved on a guess"
        );
    }

    #[test]
    fn nonzero_bitmaps_are_never_clobbered() {
        let store = InMemoryDrawerStore::new(NOW, None).unwrap();
        let mut anchor = drawer("anchor-drawer");
        anchor.adjective_bitmap = 32 << 6; // restricted sensitivity, legal
        anchor.provenance = 7;
        let anchor_id = anchor.id.clone();
        store.add_drawer(&anchor, NOW).unwrap();

        // A retired fact (RowState withdrawn raw = 18): its bitmap is real
        // state, not the pre-KH default — inheritance must not touch it.
        let mut retired = fact("f-retired", &anchor_id);
        retired.adjective_bitmap = 18;
        store.add_kg_fact(&retired).unwrap();

        let storage: &Arc<dyn Storage> = store.storage();
        let report = run(storage.as_ref(), &null_resolver).unwrap();

        assert_eq!(report.local_drawer_ids, 1);
        assert_eq!(report.inheritance_applied, 0);
        let f = store.get_kg_fact("f-retired").unwrap().unwrap();
        assert_eq!(f.adjective_bitmap, 18);
        assert_eq!(f.provenance_bitmap, 0);
    }

    #[test]
    fn retired_facts_are_still_migrated() {
        let store = InMemoryDrawerStore::new(NOW, None).unwrap();
        store.add_kg_fact(&fact("f-retired-host", "mootx01")).unwrap();
        store.withdraw_kg_fact("f-retired-host", NOW).unwrap();

        let storage: &Arc<dyn Storage> = store.storage();
        let report = run(storage.as_ref(), &null_resolver).unwrap();

        assert_eq!(report.host_identities, 1);
        let f = store.get_kg_fact("f-retired-host").unwrap().unwrap();
        assert_eq!(f.added_by, "mootx01");
        assert!(f.source_drawer_id.is_empty());
        // Retirement state preserved through the move.
        assert_eq!(f.adjective_bitmap & 0x3F, 18);
    }

    /// The schema leg: a pre-MXE-KH (v12) SQLite estate whose `kg_facts`
    /// table lacks the identity trio gains the columns through the
    /// v12 → v13 ladder entry when the backfill opens it, and its rows
    /// migrate. Without the ladder entry this run dies with "no such
    /// column: addedBy" (Smythe CRITICAL-1, the gap MXE-KH shipped).
    #[test]
    fn v12_estate_gains_columns_and_migrates() {
        let path = std::env::temp_dir().join(format!(
            "locuskit-kgbackfill-migration-{}.sqlite",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);

        // The v12 shape: identical to the live declaration except
        // `kg_facts` lacks the identity trio and the ladder is empty, so
        // opening records exactly version 12 the way a pre-KH estate on
        // disk is recorded.
        let mut v12 = schema();
        v12.version = 12;
        v12.migrations.clear();
        let trio = ["addedBy", "foreignSourceKey", "foreignRecordID"];
        for table in v12.tables.iter_mut().filter(|t| t.name == "kg_facts") {
            table.columns.retain(|c| !trio.contains(&c.name.as_str()));
        }

        {
            let config = EstateConfiguration::new(
                Uuid::new_v4(),
                BackendConfiguration::Sqlite {
                    path: path.display().to_string(),
                    busy_timeout_secs: 5.0,
                },
            );
            let storage = SqliteStorage::new(config).unwrap();
            storage.open(&v12).unwrap();
            let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
            values.insert("id".into(), TypedValue::Text("f-host".into()));
            values.insert("subject".into(), TypedValue::Text("fleet".into()));
            values.insert("predicate".into(), TypedValue::Text("works_with".into()));
            values.insert("object".into(), TypedValue::Text("skippy".into()));
            values.insert("sourceDrawerID".into(), TypedValue::Text("mootx01".into()));
            values.insert("adjectiveBitmap".into(), TypedValue::Bitmap(0));
            values.insert("operationalBitmap".into(), TypedValue::Bitmap(0));
            values.insert("provenanceBitmap".into(), TypedValue::Bitmap(0));
            values.insert("filedAt".into(), TypedValue::Timestamp(NOW));
            storage.row_store().insert("kg_facts", values).unwrap();
            storage.close();
        }

        let config = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: path.display().to_string(),
                busy_timeout_secs: 5.0,
            },
        );
        let storage = SqliteStorage::new(config).unwrap();
        let report = run(&storage, &null_resolver).unwrap();

        assert_eq!(report.scanned, 1);
        assert_eq!(report.host_identities, 1);
        assert_eq!(report.unclassified, 0);
        let rows = storage
            .row_store()
            .query("kg_facts", None, &[], None, None)
            .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(text_value(&rows[0], "addedBy"), "mootx01");
        assert!(text_value(&rows[0], "sourceDrawerID").is_empty());
        storage.close();
        let _ = std::fs::remove_file(&path);
    }
}
