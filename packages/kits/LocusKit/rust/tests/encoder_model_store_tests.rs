//! The span-encoder registry (ENCODER_RERANK_CONTRACT §2). Twin of Swift
//! `EncoderModelStoreTests`.
//!
//! Failure modes pinned:
//!   1. `active()` is None on a fresh estate and returns the one row with
//!      is_active = 1 after activation; activating a second model demotes
//!      the first (never two active rows).
//!   2. `activate` clears bit 27 on every drawer that carried it, in the
//!      same call, so the duty re-encodes under the new model. A port that
//!      flips is_active without touching drawers leaves stale span rows
//!      described as current.
//!   3. Activating an unregistered id is refused.

use locus_kit::drawer::Drawer;
use locus_kit::drawer_operational::DrawerFeatureFlags;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::encoder_model_store::{EncoderModelRow, EncoderModelStore, Pooling};

const NOW: i64 = 1_700_000_000;
const TEST_PARENT: &str = "00000000-0000-4000-8000-000000000001";

fn spec(model_id: &str, window: i64) -> EncoderModelRow {
    EncoderModelRow {
        model_id: model_id.to_string(),
        model_version: "r1".to_string(),
        dim: 384,
        query_prefix: String::new(),
        doc_prefix: String::new(),
        pooling: Pooling::Mean,
        tokenizer_hash: "sha256-of-vocab".to_string(),
        window_words: window,
        overlap_divisor: 2,
        max_spans: 32,
        max_sequence: 256,
        is_active: false,
    }
}

fn sample_drawer(id: &str) -> Drawer {
    let mut d = Drawer::new(id, "content to span", TEST_PARENT, "bilby", NOW, "test-v1");
    d.udc_code = "001".to_string();
    d
}

#[test]
fn upsert_activate_and_read_back_the_single_active_row() {
    let store = InMemoryDrawerStore::new(NOW, None).expect("store");
    let registry = EncoderModelStore::new(store.storage().expect("storage"));
    assert_eq!(registry.active().unwrap(), None, "fresh estate: no active encoder");

    registry.upsert(&spec("minilm-l6-v2-w60", 60)).unwrap();
    registry.upsert(&spec("minilm-l6-v2-w150", 150)).unwrap();
    assert_eq!(registry.active().unwrap(), None, "upsert never activates by itself");
    assert_eq!(registry.all().unwrap().len(), 2);

    registry.activate("minilm-l6-v2-w60").unwrap();
    let active = registry.active().unwrap().expect("active");
    assert_eq!(active.model_id, "minilm-l6-v2-w60");
    assert!(active.is_active);
    assert_eq!(active.window_words, 60);
    assert_eq!(active.pooling, Pooling::Mean);

    registry.activate("minilm-l6-v2-w150").unwrap();
    let rows = registry.all().unwrap();
    let active_ids: Vec<&str> = rows.iter().filter(|r| r.is_active).map(|r| r.model_id.as_str()).collect();
    assert_eq!(active_ids, vec!["minilm-l6-v2-w150"], "exactly one active row after a switch");

    // An upsert of the active row keeps its identity and refreshes its fields.
    let mut refreshed = spec("minilm-l6-v2-w150", 150);
    refreshed.model_version = "r2".to_string();
    refreshed.is_active = true;
    registry.upsert(&refreshed).unwrap();
    assert_eq!(registry.active().unwrap().unwrap().model_version, "r2");

    assert!(registry.activate("bge-small-en-v15-w60").is_err(), "unregistered id is refused");
    assert!(registry.upsert(&spec("", 60)).is_err(), "empty model id is refused");
}

#[test]
fn activation_clears_bit_27_estate_wide() {
    let store = InMemoryDrawerStore::new(NOW, None).expect("store");
    let registry = EncoderModelStore::new(store.storage().expect("storage"));
    registry.upsert(&spec("minilm-l6-v2-w60", 60)).unwrap();
    registry.upsert(&spec("bge-small-en-v15-w60", 60)).unwrap();
    registry.activate("minilm-l6-v2-w60").unwrap();

    let ids = ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"];
    for id in ids {
        store.add_drawer(&sample_drawer(id), NOW).unwrap();
    }
    store.set_span_indexed(ids[0]).unwrap();
    assert_eq!(store.count_span_index_debt().unwrap(), 1, "one indexed, one still owed");

    let cleared = registry.activate("bge-small-en-v15-w60").unwrap();
    assert_eq!(cleared, 1, "only the drawer that carried bit 27 is written");
    for id in ids {
        let d = store.get_drawer(id).unwrap().unwrap();
        assert!(!d.is_span_indexed(), "{id}: bit 27 must clear on activation");
        assert_eq!(d.operational_bitmap & DrawerFeatureFlags::SPAN_INDEXED, 0);
    }
    assert_eq!(store.count_span_index_debt().unwrap(), 2, "the whole estate is owed again");
}
