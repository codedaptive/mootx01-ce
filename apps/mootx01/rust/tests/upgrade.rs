#[test]
fn convergence_runs_ssc_facts_after_identity_before_projection_and_second_run_is_no_op() {
    let src = include_str!("../src/commands/upgrade.rs");
    let convergence_start = src.find("fn run_convergence").expect("convergence function");
    let convergence_end = src[convergence_start..]
        .find("/// Schema upgrade")
        .map(|offset| convergence_start + offset)
        .expect("schema upgrade follows convergence");
    let convergence = &src[convergence_start..convergence_end];
    let identity_at = convergence
        .find("run_kg_fact_identity_backfill(record)")
        .expect("identity backfill in convergence");
    let facts_at = convergence
        .find("run_ssc_facts_backfill(record)")
        .expect("ssc facts backfill in convergence");
    let projection_at = convergence
        .find("run_search_projection_backfill(record)")
        .expect("search projection backfill in convergence");
    assert!(
        identity_at < facts_at && facts_at < projection_at,
        "convergence must run kg_facts identity -> SSC facts -> search projection"
    );

    let facts_start = src.find("fn run_ssc_facts_backfill").expect("ssc facts function");
    let facts_end = src[facts_start..]
        .find("/// Returns `true` on success or when there is nothing to reclaim")
        .map(|offset| facts_start + offset)
        .expect("shared-content reclaim follows SSC facts");
    let facts = &src[facts_start..facts_end];
    assert!(
        facts.contains("if written > 0"),
        "the first convergence run rebuilds derived lanes only when facts were written"
    );
    assert!(
        facts.contains("Ok(0)"),
        "the second convergence run must be an SSC-facts no-op"
    );
}

#[test]
fn current_schema_upgrade_opens_declared_schema_for_ledger_convergence() {
    let src = include_str!("../src/commands/upgrade.rs");
    let upgrade_start = src.find("fn run_schema_upgrade").expect("schema upgrade function");
    let upgrade_end = src[upgrade_start..]
        .find("/// MXE-MI:")
        .map(|offset| upgrade_start + offset)
        .expect("schema upgrade boundary");
    let upgrade = &src[upgrade_start..upgrade_end];
    let current = upgrade
        .find("SchemaUpgradePath::Current =>")
        .expect("current schema branch");
    let current_open = upgrade[current..]
        .find("storage.open(&schema::schema())")
        .expect("current schema branch must open declared schema");
    assert!(current_open > 0, "current schema upgrade must reach the ledger convergence seam");
}

/// The retired-model set exactly as `commands/upgrade.rs` declares it, read
/// off the source so the test drives the store with the set the command
/// ships rather than a copy that could drift.
fn shipped_retired_model_ids() -> Vec<String> {
    let src = include_str!("../src/commands/upgrade.rs");
    let marker = "const RETIRED_DENSE_FAMILY_MODEL_IDS: [&str; ";
    let at = src.find(marker).expect("upgrade.rs declares RETIRED_DENSE_FAMILY_MODEL_IDS");
    let rest = &src[at..];
    let open = rest.find("= [").expect("array literal") + 3;
    let close = rest[open..].find(']').expect("array literal closes") + open;
    rest[open..close]
        .split(',')
        .map(|s| s.trim().trim_matches('"').to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// `mootx01 upgrade` reclaims the vector rows of the retired audition families
/// through `VectorStore::reclaim_retired_vector_rows`. LSA is the second
/// signal of the default ensemble, so every populated estate carries live
/// `lsa-v1` float rows and the reclaim must leave them in place. A set that
/// names `lsa-v1` fails on the surviving-row assertion, not on the count.
#[test]
fn live_lsa_rows_survive_the_upgrade_reclaim_while_a_ppmi_row_goes() {
    use persistence_kit::predicate::StoragePredicate;
    use persistence_kit::types::TypedValue;
    use persistence_kit::{inmemory::InMemoryStorage, Storage};
    use std::sync::Arc;
    use synapsekit::engine::payload::VectorPayload;
    use synapsekit::VectorStore;

    let retired = shipped_retired_model_ids();
    assert!(
        retired.iter().any(|id| id == "ppmi-v1"),
        "precondition: the shipped set retires ppmi-v1; got {retired:?}"
    );
    let retired_refs: Vec<&str> = retired.iter().map(String::as_str).collect();

    const FILED_AT: i64 = 1_700_000_000;
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(uuid::Uuid::new_v4()));
    storage.open(&VectorStore::schema_declaration()).expect("open vector schema");
    let store = VectorStore::new(Arc::clone(&storage), None);

    // Seed: two live LSA float rows beside one retired-family row.
    let f = |v: &[f32]| VectorPayload::from_f32(v);
    store.add_payload("drawer-a", 1, &f(&[1.0, 0.0, 0.0, 0.0]), "lsa-v1", "1.1.0", FILED_AT).unwrap();
    store.add_payload("drawer-b", 1, &f(&[0.0, 1.0, 0.0, 0.0]), "lsa-v1", "1.1.0", FILED_AT).unwrap();
    store.add_payload("drawer-a", 1, &f(&[0.0, 0.0, 1.0, 0.0]), "ppmi-v1", "1.1.0", FILED_AT).unwrap();

    let (retired_rows, _non_serving) = store
        .reclaim_retired_vector_rows(&retired_refs)
        .expect("reclaim");

    let survivors: Vec<String> = storage
        .row_store()
        .query_projected("vectors", &["model_id"], Some(&StoragePredicate::IsTrue), &[], None, None)
        .expect("query vectors")
        .iter()
        .filter_map(|row| match row.get("model_id") {
            Some(TypedValue::Text(id)) => Some(id.clone()),
            _ => None,
        })
        .collect();

    assert_eq!(retired_rows, 1, "only the ppmi-v1 row is retired");
    assert_eq!(
        survivors.iter().filter(|id| *id == "lsa-v1").count(),
        2,
        "both live lsa-v1 rows survive the reclaim; rows left: {survivors:?}"
    );
    assert!(
        !survivors.iter().any(|id| id == "ppmi-v1"),
        "the ppmi-v1 row is gone; rows left: {survivors:?}"
    );
}
