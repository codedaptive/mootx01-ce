//! Normalized adornment store tests (ADORN-STORE-02 v17).
//!
//! Contract (LOCUSKIT_INTERFACE 2.0.1):
//!   - `list_adornment_minters` returns minters ordered by name.
//!   - `register_adornment_minter` is idempotent when configuration matches;
//!     fails on a configuration change; never retoggles activation.
//!   - `set_adornment_minter_active` toggles one minter; returns 0 for unknown.
//!   - `set_active_adornment_minters` atomically replaces the active set.
//!   - `adornment_debt_batch` pages (drawer, minter) pairs missing an adornment row.
//!   - `put_adornment` inserts or replaces one row; rejects empty fields.
//!   - `adornments` returns all rows for one drawer ordered by minter_id.
//!   - `active_adornments` filters by active minters only.
//!   - Fresh captures and superseding drawers start bare (no adornment rows, bits 27-30 FREE).
//!   - Expunge deletes adornment rows for the tombstoned drawer.
//!
//! Uses `InMemoryDrawerStore` (SQLite/Postgres wrappers delegate to the same core).

use adornment_lib::{AdornmentMinterDescriptor, StoredAdornment};
use locus_kit::drawer::Drawer;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use std::collections::BTreeMap;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000;
const TEST_PARENT: &str = "00000000-0000-4000-8000-000000000001";

fn new_store() -> InMemoryDrawerStore {
    InMemoryDrawerStore::new(NOW, None).expect("store init")
}

fn make_id() -> String {
    Uuid::new_v4().to_string()
}

/// Construct a minimal `AdornmentMinterDescriptor` for testing.
fn make_minter(id: &str, name: &str) -> AdornmentMinterDescriptor {
    AdornmentMinterDescriptor {
        id: id.to_string(),
        name: name.to_string(),
        family: "test-family".to_string(),
        model_id: "model-001".to_string(),
        model_version: "1.0".to_string(),
        prompt_digest: "abc123".to_string(),
        parameters: BTreeMap::new(),
        is_active: true,
    }
}

/// Build a minimal valid `Drawer` for testing.
fn sample_drawer(id: &str) -> Drawer {
    let mut d = Drawer::new(
        id,
        "The quarterly planning meeting moved to Thursday. Sarah sends invites Monday.",
        TEST_PARENT,
        "bilby",
        NOW,
        "test-v1",
    );
    d.udc_code = "001".to_string();
    d
}

/// Capture one drawer and return its id.
fn capture_one(store: &InMemoryDrawerStore) -> String {
    let id = make_id();
    store.add_drawer(&sample_drawer(&id), NOW).expect("add_drawer");
    id
}

// ─── list_adornment_minters ─────────────────────────────────────────────────

/// Empty list on fresh store.
#[test]
fn test_list_adornment_minters_empty() {
    let store = new_store();
    let list = store.list_adornment_minters().expect("list");
    assert!(list.is_empty());
}

/// Returns minters in name-ascending order.
#[test]
fn test_list_adornment_minters_ordered_by_name() {
    let store = new_store();
    store.register_adornment_minter(&make_minter("m-b", "Bravo")).expect("register b");
    store.register_adornment_minter(&make_minter("m-a", "Alpha")).expect("register a");
    store.register_adornment_minter(&make_minter("m-c", "Charlie")).expect("register c");
    let list = store.list_adornment_minters().expect("list");
    assert_eq!(list.len(), 3);
    assert_eq!(list[0].name, "Alpha");
    assert_eq!(list[1].name, "Bravo");
    assert_eq!(list[2].name, "Charlie");
}

// ─── register_adornment_minter ──────────────────────────────────────────────

/// Round-trip: fields survive insert.
#[test]
fn test_register_adornment_minter_round_trip() {
    let store = new_store();
    let mut params = BTreeMap::new();
    params.insert("key".to_string(), "value".to_string());
    let m = AdornmentMinterDescriptor {
        id: "m-1".to_string(),
        name: "TestMinter".to_string(),
        family: "fam".to_string(),
        model_id: "gpt-4o".to_string(),
        model_version: "2024-01".to_string(),
        prompt_digest: "deadbeef".to_string(),
        parameters: params.clone(),
        is_active: true,
    };
    store.register_adornment_minter(&m).expect("register");
    let list = store.list_adornment_minters().expect("list");
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].id, "m-1");
    assert_eq!(list[0].name, "TestMinter");
    assert_eq!(list[0].parameters, params);
    assert!(list[0].is_active);
}

/// Re-registering the identical configuration is an idempotent no-op.
#[test]
fn test_register_adornment_minter_idempotent() {
    let store = new_store();
    let m1 = make_minter("m-1", "Original");
    store.register_adornment_minter(&m1).expect("first insert");
    store.register_adornment_minter(&m1).expect("identical re-registration is a no-op");
    let list = store.list_adornment_minters().expect("list");
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].name, "Original");
}

/// A same-id configuration change is REJECTED (LOCUSKIT_SPEC
/// § ADORNMENT_STORE: configuration is immutable; a change requires a
/// NEW minter id).
#[test]
fn test_register_adornment_minter_config_change_rejected() {
    let store = new_store();
    store
        .register_adornment_minter(&make_minter("m-1", "Original"))
        .expect("first insert");
    let changed = AdornmentMinterDescriptor {
        name: "Updated".to_string(),
        ..make_minter("m-1", "Original")
    };
    let err = store.register_adornment_minter(&changed);
    assert!(err.is_err(), "configuration change must be rejected");
    let list = store.list_adornment_minters().expect("list");
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].name, "Original", "stored row must be untouched");
}

/// Registration never retoggles `is_active` on an existing row —
/// activation belongs exclusively to the activation setters.
#[test]
fn test_register_adornment_minter_never_retoggles_activation() {
    let store = new_store();
    store
        .register_adornment_minter(&make_minter("m-1", "Original"))
        .expect("first insert");
    // Same configuration, different initial-state flag: must be accepted
    // as idempotent AND must not change the stored activation.
    let redeclared = AdornmentMinterDescriptor {
        is_active: false,
        ..make_minter("m-1", "Original")
    };
    store
        .register_adornment_minter(&redeclared)
        .expect("identical configuration re-registration");
    let list = store.list_adornment_minters().expect("list");
    assert_eq!(list.len(), 1);
    assert!(list[0].is_active, "activation flag must be untouched");
}

/// Empty id is rejected.
#[test]
fn test_register_adornment_minter_empty_id_rejected() {
    let store = new_store();
    let m = make_minter("", "Empty");
    assert!(store.register_adornment_minter(&m).is_err());
}

// ─── set_adornment_minter_active ────────────────────────────────────────────

/// Toggle active flag round-trip.
#[test]
fn test_set_adornment_minter_active() {
    let store = new_store();
    store.register_adornment_minter(&make_minter("m-1", "M1")).expect("register");
    let n = store.set_adornment_minter_active("m-1", false).expect("deactivate");
    assert_eq!(n, 1);
    let list = store.list_adornment_minters().expect("list");
    assert!(!list[0].is_active);
    store.set_adornment_minter_active("m-1", true).expect("reactivate");
    let list = store.list_adornment_minters().expect("list");
    assert!(list[0].is_active);
}

/// Unknown id returns 0.
#[test]
fn test_set_adornment_minter_active_unknown_returns_zero() {
    let store = new_store();
    let n = store.set_adornment_minter_active("no-such-id", true).expect("call");
    assert_eq!(n, 0);
}

// ─── set_active_adornment_minters ───────────────────────────────────────────

/// Atomically set active set — excluded minter is deactivated.
#[test]
fn test_set_active_adornment_minters() {
    let store = new_store();
    store.register_adornment_minter(&make_minter("m-1", "M1")).expect("reg");
    store.register_adornment_minter(&make_minter("m-2", "M2")).expect("reg");
    store.register_adornment_minter(&make_minter("m-3", "M3")).expect("reg");
    store.set_active_adornment_minters(&["m-1", "m-3"]).expect("set active");
    let list = store.list_adornment_minters().expect("list");
    let active: Vec<&str> = list.iter().filter(|m| m.is_active).map(|m| m.id.as_str()).collect();
    assert!(active.contains(&"m-1"), "m-1 should be active");
    assert!(!active.contains(&"m-2"), "m-2 should be inactive");
    assert!(active.contains(&"m-3"), "m-3 should be active");
}

/// Unknown id in list causes error.
#[test]
fn test_set_active_adornment_minters_unknown_fails() {
    let store = new_store();
    store.register_adornment_minter(&make_minter("m-1", "M1")).expect("reg");
    assert!(store.set_active_adornment_minters(&["m-1", "m-unknown"]).is_err());
}

// ─── put_adornment / adornments ─────────────────────────────────────────────

/// Insert then retrieve.
#[test]
fn test_put_and_get_adornment() {
    let store = new_store();
    let drawer_id = capture_one(&store);
    store.register_adornment_minter(&make_minter("m-1", "M1")).expect("reg");
    let a = StoredAdornment {
        drawer_id: drawer_id.clone(),
        minter_id: "m-1".to_string(),
        text: "short label".to_string(),
    };
    let n = store.put_adornment(&a).expect("put");
    assert_eq!(n, 1);
    let rows = store.adornments(&drawer_id).expect("adornments");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].text, "short label");
}

/// Second put on same (drawer, minter) pair replaces the row.
#[test]
fn test_put_adornment_replaces_existing() {
    let store = new_store();
    let drawer_id = capture_one(&store);
    store.register_adornment_minter(&make_minter("m-1", "M1")).expect("reg");
    let a1 = StoredAdornment {
        drawer_id: drawer_id.clone(),
        minter_id: "m-1".to_string(),
        text: "first".to_string(),
    };
    let a2 = StoredAdornment {
        drawer_id: drawer_id.clone(),
        minter_id: "m-1".to_string(),
        text: "second".to_string(),
    };
    store.put_adornment(&a1).expect("first put");
    store.put_adornment(&a2).expect("second put");
    let rows = store.adornments(&drawer_id).expect("adornments");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].text, "second");
}

/// Empty text is rejected.
#[test]
fn test_put_adornment_empty_text_rejected() {
    let store = new_store();
    let drawer_id = capture_one(&store);
    let a = StoredAdornment {
        drawer_id: drawer_id.clone(),
        minter_id: "m-1".to_string(),
        text: String::new(),
    };
    assert!(store.put_adornment(&a).is_err());
}

// ─── active_adornments ──────────────────────────────────────────────────────

/// active_adornments returns only rows for active minters.
#[test]
fn test_active_adornments_filters_inactive() {
    let store = new_store();
    let d1 = capture_one(&store);
    store.register_adornment_minter(&make_minter("m-active", "Active")).expect("reg");
    store.register_adornment_minter(&make_minter("m-inactive", "Inactive")).expect("reg");
    store.set_adornment_minter_active("m-inactive", false).expect("deactivate");
    store.put_adornment(&StoredAdornment {
        drawer_id: d1.clone(),
        minter_id: "m-active".to_string(),
        text: "label-a".to_string(),
    }).expect("put active");
    store.put_adornment(&StoredAdornment {
        drawer_id: d1.clone(),
        minter_id: "m-inactive".to_string(),
        text: "label-b".to_string(),
    }).expect("put inactive");
    let map = store.active_adornments(&[&d1]).expect("active_adornments");
    let rows = map.get(&d1).expect("d1 in map");
    assert_eq!(rows.len(), 1, "only the active minter row");
    assert_eq!(rows[0].minter_id, "m-active");
}

/// Sensitivity gate (codex finding 2026-08-26): adornment text is a
/// content-derived pre-minted claim, so restricted/secret drawers must
/// contribute NO adornments to the composition read — otherwise the render
/// layers' subject/first_sentence redaction is bypassed through the
/// adornment column. Twin of the Swift AdornmentStoreTests gate test.
#[test]
fn test_active_adornments_gates_sensitive_drawers() {
    let store = new_store();
    store.register_adornment_minter(&make_minter("m1", "Minter")).expect("reg");
    // provenance bits 30-35 carry the sensitivity raw (cookbook 2.5):
    // Restricted = 32, Secret = 48.
    let restricted_id = make_id();
    let mut restricted = sample_drawer(&restricted_id);
    restricted.provenance = 32i64 << 30;
    store.add_drawer(&restricted, NOW).expect("add restricted");
    let secret_id = make_id();
    let mut secret = sample_drawer(&secret_id);
    secret.provenance = 48i64 << 30;
    store.add_drawer(&secret, NOW).expect("add secret");
    let normal_id = capture_one(&store);
    for id in [&restricted_id, &secret_id, &normal_id] {
        store.put_adornment(&StoredAdornment {
            drawer_id: id.clone(),
            minter_id: "m1".to_string(),
            text: format!("claim-{id}"),
        }).expect("put");
    }
    let map = store
        .active_adornments(&[&restricted_id, &secret_id, &normal_id])
        .expect("active_adornments");
    assert!(map.get(&restricted_id).is_none(), "restricted drawer leaked an adornment");
    assert!(map.get(&secret_id).is_none(), "secret drawer leaked an adornment");
    assert_eq!(map.get(&normal_id).expect("normal in map").len(), 1);
}

// ─── adornment_debt_batch ────────────────────────────────────────────────────

/// Fresh capture has no adornment row → appears in debt batch.
#[test]
fn test_adornment_debt_batch_fresh_capture() {
    let store = new_store();
    let d1 = capture_one(&store);
    store.register_adornment_minter(&make_minter("m-1", "M1")).expect("reg");
    let debt = store.adornment_debt_batch(10, None).expect("debt");
    assert_eq!(debt.len(), 1);
    assert_eq!(debt[0].drawer.id, d1);
    assert_eq!(debt[0].minter.id, "m-1");
}

/// After putting an adornment, the (drawer, minter) pair leaves the debt batch.
#[test]
fn test_adornment_debt_batch_clears_after_put() {
    let store = new_store();
    let d1 = capture_one(&store);
    store.register_adornment_minter(&make_minter("m-1", "M1")).expect("reg");
    store.put_adornment(&StoredAdornment {
        drawer_id: d1.clone(),
        minter_id: "m-1".to_string(),
        text: "label".to_string(),
    }).expect("put");
    let debt = store.adornment_debt_batch(10, None).expect("debt");
    assert!(debt.is_empty(), "no debt after adornment put");
}

/// Inactive minters do not generate debt.
#[test]
fn test_adornment_debt_batch_ignores_inactive_minters() {
    let store = new_store();
    let _d1 = capture_one(&store);
    store.register_adornment_minter(&make_minter("m-inactive", "Inactive")).expect("reg");
    store.set_adornment_minter_active("m-inactive", false).expect("deactivate");
    let debt = store.adornment_debt_batch(10, None).expect("debt");
    assert!(debt.is_empty(), "inactive minter generates no debt");
}

/// Regression guard (MINT-DEBT-WINDOW, 2026-08-27): a debt fetch that scans
/// only the first `limit × active_minters` drawers in filedAt order returns
/// empty once that prefix is fully minted, hiding real debt further down —
/// the drain loop then falsely concludes the estate is complete. The fetch
/// must keep scanning until the batch fills or the drawer table is
/// exhausted. Twin of Swift `adornmentDebtBatchScansPastMintedPrefix`.
#[test]
fn test_adornment_debt_batch_scans_past_minted_prefix() {
    let store = new_store();
    store.register_adornment_minter(&make_minter("m-1", "M1")).expect("reg");
    // 12 drawers; identical filedAt so scan order falls to id ASC, and the
    // fixed zero-padded UUIDs make that order match the numeric order.
    let uid = |i: u32| format!("00000000-0000-4000-8000-0000000000{i:02}");
    for i in 1..=12 {
        store.add_drawer(&sample_drawer(&uid(i)), NOW).expect("add_drawer");
    }
    // Mint the oldest 10 — more than limit × minters (4 × 1), so the whole
    // first scan window is already complete.
    for i in 1..=10 {
        store
            .put_adornment(&StoredAdornment {
                drawer_id: uid(i),
                minter_id: "m-1".to_string(),
                text: "adorned".to_string(),
            })
            .expect("put");
    }
    let debt = store.adornment_debt_batch(4, None).expect("debt");
    // The two unminted drawers past the minted prefix MUST surface.
    assert_eq!(debt.len(), 2, "debt beyond the minted prefix must surface");
    let ids: std::collections::BTreeSet<String> =
        debt.iter().map(|d| d.drawer.id.clone()).collect();
    assert!(ids.contains(&uid(11)) && ids.contains(&uid(12)), "got {ids:?}");
}

// ─── bitmap hygiene (ADORN-STORE-02 v17) ────────────────────────────────────

/// Fresh capture does NOT set bits 27-30 (they are FREE in v17).
#[test]
fn test_fresh_capture_bits_27_30_free() {
    let store = new_store();
    let id = capture_one(&store);
    let drawers = store.all_drawers().expect("all_drawers");
    let d = drawers.iter().find(|x| x.id == id).expect("find drawer");
    // Bits 27-30 must all be zero.
    let bits_27_30: i64 = 0b1111_i64 << 27;
    assert_eq!(
        d.operational_bitmap & bits_27_30,
        0,
        "bits 27-30 must be FREE on fresh capture (got bitmap {:#b})",
        d.operational_bitmap
    );
}
