use locus_kit::drawer::Drawer;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::fact_extractor_model_store::{FactExtractorModelRow, FactExtractorModelStore};

const NOW: i64 = 1_700_000_000;
const PARENT: &str = "00000000-0000-4000-8000-000000000001";

fn row(recipe_id: &str) -> FactExtractorModelRow {
    FactExtractorModelRow {
        recipe_id: recipe_id.into(),
        provider_id: "test-provider".into(),
        model_id: "test-model".into(),
        model_version: "r1".into(),
        schema_version: "kgfact-extraction-v1".into(),
        extractor_kind: "closure".into(),
        maximum_input_characters: 16_384,
        maximum_facts_per_source: 16,
        is_active: false,
    }
}

fn drawer(id: &str) -> Drawer {
    let mut drawer = Drawer::new(
        id,
        "Jack's birthday is June 20th.",
        PARENT,
        "bilby",
        NOW,
        "test-v1",
    );
    drawer.udc_code = "001".into();
    drawer
}

#[test]
fn upsert_activate_and_read_one_active_recipe() {
    let store = InMemoryDrawerStore::new(NOW, None).expect("store");
    let registry = FactExtractorModelStore::new(store.storage().expect("storage"));
    assert_eq!(registry.active().unwrap(), None);
    registry.upsert(&row("apple-system-v1")).unwrap();
    registry.upsert(&row("nuextract-b1-q8-v1")).unwrap();
    assert_eq!(
        registry.active().unwrap(),
        None,
        "upsert never activates implicitly"
    );

    registry.activate("apple-system-v1").unwrap();
    assert_eq!(
        registry.active().unwrap().unwrap().recipe_id,
        "apple-system-v1"
    );
    registry.activate("nuextract-b1-q8-v1").unwrap();
    let active: Vec<String> = registry
        .all()
        .unwrap()
        .into_iter()
        .filter(|row| row.is_active)
        .map(|row| row.recipe_id)
        .collect();
    assert_eq!(active, vec!["nuextract-b1-q8-v1"]);

    let mut refreshed = row("nuextract-b1-q8-v1");
    refreshed.model_version = "r2".into();
    refreshed.is_active = true;
    registry.upsert(&refreshed).unwrap();
    assert_eq!(registry.active().unwrap().unwrap().model_version, "r2");
    assert!(registry.activate("missing").is_err());
    assert!(registry.upsert(&row("")).is_err());
}

#[test]
fn activation_and_content_writes_maintain_bit_28_debt() {
    let store = InMemoryDrawerStore::new(NOW, None).expect("store");
    let registry = FactExtractorModelStore::new(store.storage().expect("storage"));
    registry.upsert(&row("apple-system-v1")).unwrap();
    registry.upsert(&row("nuextract-b1-q8-v1")).unwrap();

    let ids = [
        "11111111-1111-4111-8111-111111111111",
        "22222222-2222-4222-8222-222222222222",
    ];
    for id in ids {
        store.add_drawer(&drawer(id), NOW).unwrap();
    }
    assert_eq!(store.count_fact_extraction_debt().unwrap(), 2);

    store.set_facts_extracted(ids[0]).unwrap();
    assert_eq!(store.count_fact_extraction_debt().unwrap(), 1);
    assert!(store
        .get_drawer(ids[0])
        .unwrap()
        .unwrap()
        .are_facts_extracted());

    let cleared = registry.activate("nuextract-b1-q8-v1").unwrap();
    assert_eq!(cleared, 1);
    assert_eq!(store.count_fact_extraction_debt().unwrap(), 2);

    store.set_facts_extracted(ids[0]).unwrap();
    store
        .expunge_gated(ids[0], "bilby", Some("derived fact erasure"), NOW + 1, true)
        .unwrap();
    assert!(
        !store
            .get_drawer(ids[0])
            .unwrap()
            .unwrap()
            .are_facts_extracted(),
        "destructive content writes clear bit 28"
    );
}
