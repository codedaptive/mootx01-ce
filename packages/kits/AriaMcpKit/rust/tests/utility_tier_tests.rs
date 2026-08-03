//! PR-04 verification — Rust twin of `UtilityTierTests.swift`: the
//! estate-status subject-debt counter on a mixed fixture, and the
//! terse/verbose catalogue tiers.

use std::collections::BTreeMap;

use aria_mcp::{
    dispatch::dispatch_tool,
    estate_registry::EstateRegistry,
    jsonrpc::JsonValue,
    surfaced_recall_ledger::SurfacedRecallLedger,
};

macro_rules! args {
    () => { BTreeMap::new() };
    ( $( $k:expr => $v:expr ),+ $(,)? ) => {{
        let mut m = BTreeMap::new();
        $( m.insert($k.to_string(), JsonValue::from(serde_json::json!($v))); )+
        m
    }};
}

fn content_text(result: &serde_json::Value) -> &str {
    result["content"][0]["text"].as_str().unwrap_or("")
}

#[test]
fn estate_status_shows_subject_debt_on_mixed_fixture() {
    // Bare registry: no seeded charter hints, so the counts are exactly
    // the fixture's (the seeded registry's hints carry seed-v1 subjects
    // and would shift N and M equally — bare keeps the arithmetic legible).
    let registry = EstateRegistry::new_inmemory_bare();
    let ledger = SurfacedRecallLedger::new();

    for i in 1..=2 {
        let content = format!("Fixture row {i} with a subject.");
        let subject = format!("Fixture row {i}: has a subject.");
        let r = dispatch_tool(
            "moot_file_memory",
            &args!["content" => content.as_str(), "subject" => subject.as_str(),
                   "location" => "debt-tests"],
            &registry,
            &ledger,
        )
        .expect("file_memory must succeed");
        assert_eq!(r["isError"], serde_json::json!(false));
    }
    // One subject-less row through the direct seam (intake shape).
    {
        use locus_kit::default_wings::DEFAULT_WING_NAME;
        use locus_kit::drawer_operational::CaptureChannel;
        use locus_kit::estate_types::LatticeAnchor;
        use locus_kit::frames::CaptureFrame;
        let mut frame = CaptureFrame::new(
            "Imported fixture row without a subject.",
            CaptureChannel::Actuator,
            "debt-tests",
            LatticeAnchor::udc("000"),
            "utility-tier-tests",
            "default",
        );
        frame.wing = Some(DEFAULT_WING_NAME.to_string());
        let now = aria_mcp::dispatch::wall_now();
        let coord = registry.coord.lock().unwrap();
        coord
            .capture(&registry.default.handle, frame, now)
            .expect("direct capture must succeed");
    }

    let status = dispatch_tool(
        "moot_estate_status",
        &args!(),
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("estate_status must succeed");
    let body = content_text(&status);
    assert!(
        body.contains("subjects: 2/3 (1 missing)"),
        "debt counter must reflect the mixed fixture; got: {body}"
    );
    // Over-filtering control (MXE-XU): every row here is normal sensitivity,
    // so the sensitivity ceiling removes nothing and the counts are identical
    // to what they were before the ceiling was applied to them. An estate with
    // no restricted rows must read the same after the fix as before it.
    assert!(
        body.contains("memories: 3 active (3 total)"),
        "ceiling must not drop rows on an estate with no restricted rows; got: {body}"
    );
}

/// MXE-XU — every drawer-derived aggregate on this surface reads the
/// sensitivity-filtered set, not the raw cluster-A set.
///
/// The fixture holds one visible subject-bearing row plus two restricted rows
/// — one carrying a subject, one not — filed into a wing of their own. Before
/// the fix this reported `memories: 3 active (3 total)` and
/// `subjects: 2/3 (1 missing)`: an ungranted caller learned that live rows
/// were hidden from it, how many, and how many of those carried a subject.
/// `wings:` was already filtered; it is the control that proves the fix closes
/// the leak without over-reaching. Rust twin of
/// `estateStatusAggregatesExcludeRestrictedRows`.
#[test]
fn estate_status_aggregates_exclude_restricted_rows() {
    const HIDDEN_WING: &str = "Ceiling Hidden Wing";

    let registry = EstateRegistry::new_inmemory_bare();
    let ledger = SurfacedRecallLedger::new();

    // One normal-sensitivity, subject-bearing row in the default wing.
    let visible_row = dispatch_tool(
        "moot_file_memory",
        &args!["content" => "Visible row with a subject.",
               "subject" => "Visible row: carries a subject.",
               "location" => "ceiling-tests"],
        &registry,
        &ledger,
    )
    .expect("file_memory must succeed");
    assert_eq!(visible_row["isError"], serde_json::json!(false));

    // One restricted row WITH a subject, in a wing of its own.
    let restricted_row = dispatch_tool(
        "moot_file_memory",
        &args!["content" => "Restricted row with a subject.",
               "subject" => "Restricted row: carries a subject.",
               "location" => "ceiling-hidden",
               "wing" => HIDDEN_WING,
               "sensitivity" => "restricted"],
        &registry,
        &ledger,
    )
    .expect("file_memory with sensitivity=restricted must succeed");
    assert_eq!(restricted_row["isError"], serde_json::json!(false));

    // …and one restricted row WITHOUT a subject. The ARIA boundary requires a
    // subject, so subject debt is seeded through the direct capture seam, as
    // the mixed-fixture test above does.
    {
        use locus_kit::adjectives::AdjectiveSensitivity;
        use locus_kit::drawer_operational::CaptureChannel;
        use locus_kit::estate_types::LatticeAnchor;
        use locus_kit::frames::CaptureFrame;
        let mut frame = CaptureFrame::new(
            "Restricted row without a subject.",
            CaptureChannel::Actuator,
            "ceiling-hidden",
            LatticeAnchor::udc("000"),
            "utility-tier-tests",
            "default",
        );
        frame.wing = Some(HIDDEN_WING.to_string());
        frame.sensitivity = AdjectiveSensitivity::Restricted;
        let now = aria_mcp::dispatch::wall_now();
        let coord = registry.coord.lock().unwrap();
        coord
            .capture(&registry.default.handle, frame, now)
            .expect("direct capture must succeed");
    }

    let status = dispatch_tool(
        "moot_estate_status",
        &args!(),
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("estate_status must succeed");
    let body = content_text(&status);

    // The subject counter sees one eligible row, and it bears a subject.
    assert!(
        body.contains("subjects: 1/1 (0 missing)"),
        "subject counter must count only sensitivity-visible rows; got: {body}"
    );
    // The memories counts move with the same set — a count that tracks the
    // restricted population is the same leak in scalar form.
    assert!(
        body.contains("memories: 1 active (1 total)"),
        "memory counts must exclude restricted rows; got: {body}"
    );
    // Already-correct neighbour: the restricted rows' wing must not be named,
    // and the default wing must still be.
    assert!(
        !body.contains(HIDDEN_WING),
        "wing listing must not name a wing known only from restricted rows; got: {body}"
    );
    assert!(
        body.contains(&format!("wings: {}", locus_kit::default_wings::DEFAULT_WING_NAME)),
        "the visible row's wing must still be listed; got: {body}"
    );
}

#[test]
fn list_lenses_terse_default_and_verbose() {
    let registry = EstateRegistry::new_inmemory_bare();
    let ledger = SurfacedRecallLedger::new();

    let terse = dispatch_tool("moot_list_lenses", &args!(), &registry, &ledger)
        .expect("terse list_lenses must succeed");
    let terse_text = content_text(&terse).to_string();
    assert!(terse_text.contains("cognition tools"));
    assert!(terse_text.contains("(terse — pass verbose:true"));
    assert!(
        !terse_text.contains("Required: "),
        "terse mode must not include the required-args blocks"
    );

    let verbose = dispatch_tool(
        "moot_list_lenses",
        &args!["verbose" => true],
        &registry,
        &ledger,
    )
    .expect("verbose list_lenses must succeed");
    let verbose_text = content_text(&verbose);
    assert!(verbose_text.contains("Required: "));
    assert!(
        verbose_text.len() > terse_text.len(),
        "verbose must be larger than terse ({} vs {})",
        terse_text.len(),
        verbose_text.len()
    );

    let terse_recipes = dispatch_tool("moot_list_recipes", &args!(), &registry, &ledger)
        .expect("terse list_recipes must succeed");
    assert!(content_text(&terse_recipes).contains("recipe(s)"));
    assert!(content_text(&terse_recipes).contains("(terse — pass verbose:true"));
    let verbose_recipes = dispatch_tool(
        "moot_list_recipes",
        &args!["verbose" => true],
        &registry,
        &ledger,
    )
    .expect("verbose list_recipes must succeed");
    assert!(content_text(&verbose_recipes).contains("requires: "));
}
