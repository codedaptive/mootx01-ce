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
