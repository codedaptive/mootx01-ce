//! Default-minter registration at estate open (DEFAULT-MINT-01).
//!
//! Bob ruling 2026-08-28: every production estate-open path registers the
//! platform default (Rust: the candle quantized recipe) ACTIVE, so the
//! dream-time adornment pass mints inline. Adams finding #1 required the
//! registration on ALL constructors, not just `new_sqlite`; the in-memory
//! constructor is the testable stand-in for the shared helper all three
//! call (`register_default_minter_non_fatal`).
//!
//! Also pins the never-retoggle contract at the registry level: a reopen
//! (second registration) must not reactivate a minter the operator
//! deactivated.

use aria_mcp::estate_registry::EstateRegistry;
use adornment_lib::QUANTIZED_RECIPE;

/// A fresh in-memory registry carries the platform default, registered
/// and active, with the composed recipe id as the row id.
#[test]
fn new_inmemory_registers_default_minter_active() {
    let reg = EstateRegistry::new_inmemory();
    let minters = reg
        .default
        .store
        .list_adornment_minters()
        .expect("list_adornment_minters");
    let default = minters
        .iter()
        .find(|m| m.id == QUANTIZED_RECIPE.id())
        .expect("platform default minter registered at open");
    assert!(default.is_active, "default minter must register ACTIVE");
    assert_eq!(default.name, QUANTIZED_RECIPE.id());
    assert_eq!(default.family, QUANTIZED_RECIPE.family);
}

/// Registration on reopen never retoggles activation: deactivate the
/// default, register again (the open-path upsert), and it stays off.
#[test]
fn reopen_registration_never_retoggles_deactivation() {
    let reg = EstateRegistry::new_inmemory();
    let store = &reg.default.store;
    let id = QUANTIZED_RECIPE.id();
    assert_eq!(
        store.set_adornment_minter_active(&id, false).expect("deactivate"),
        1
    );
    // The open-path upsert (same descriptor, is_active=true on the
    // descriptor) must NOT reactivate the row.
    store
        .register_adornment_minter(&QUANTIZED_RECIPE.descriptor(&id, true))
        .expect("re-register");
    let minters = store.list_adornment_minters().expect("list");
    let row = minters.iter().find(|m| m.id == id).expect("row present");
    assert!(
        !row.is_active,
        "operator deactivation must survive the reopen upsert"
    );
}
