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

/// V2 structural path: `CognitionCatalogService.lenses()` must omit
/// `input_schema` and `output_schema` in terse mode and carry them in
/// verbose mode. Rust twin of the redirected Swift structural assertion in
/// `listLensesTerseDefaultAndVerbose` (UtilityTierTests.swift).
#[test]
fn cognition_catalog_service_v2_lenses_terse_omits_schemas() {
    use aria_mcp::lens_tools::is_lens_tool;
    use aria_mcp::recipe_tools::is_recipe_tool;
    use aria_mcp::v2::catalog::selected_tools;
    use aria_mcp::v2::cognition_catalog::{CognitionCatalogRequest, CognitionCatalogService};
    use uuid::Uuid;

    // Build callable_tool_names from the same catalog the service reads so
    // the filter matches and we get at least one tool in the result.
    let catalog = selected_tools();
    let callable: std::collections::BTreeSet<String> = catalog
        .as_array()
        .expect("selected_tools must return an array")
        .iter()
        .filter_map(|t| {
            let name = t["name"].as_str()?;
            if is_recipe_tool(name) || is_lens_tool(name) {
                Some(name.to_owned())
            } else {
                None
            }
        })
        .collect();
    assert!(!callable.is_empty(), "there must be at least one callable cognition tool");

    let service = CognitionCatalogService::new(Uuid::new_v4(), callable);

    let terse = service
        .lenses(CognitionCatalogRequest { verbose: false, estate_id: None })
        .expect("terse lenses must succeed");
    assert!(!terse.tools.is_empty(), "terse result must have at least one tool");
    assert!(
        terse.tools[0].input_schema.is_none(),
        "terse mode must omit input_schema"
    );
    assert!(
        terse.tools[0].output_schema.is_none(),
        "terse mode must omit output_schema"
    );

    let verbose = service
        .lenses(CognitionCatalogRequest { verbose: true, estate_id: None })
        .expect("verbose lenses must succeed");
    assert!(!verbose.tools.is_empty(), "verbose result must have at least one tool");
    assert!(
        verbose.tools[0].input_schema.is_some(),
        "verbose mode must carry input_schema"
    );
    assert!(
        verbose.tools[0].output_schema.is_some(),
        "verbose mode must carry output_schema"
    );
}

/// V2 structural path: `CognitionCatalogService.recipes()` must omit
/// `required_capabilities` in terse mode and carry it in verbose mode.
/// Rust twin of the recipes half of the Swift structural assertions.
#[test]
fn cognition_catalog_service_v2_recipes_terse_omits_capabilities() {
    use aria_mcp::v2::cognition_catalog::{CognitionCatalogRequest, CognitionCatalogService};
    use uuid::Uuid;

    // callable_tool_names does not gate recipes (recipes() iterates
    // cognition_kit::recipe_catalog() directly), so an empty set is fine here.
    let service = CognitionCatalogService::new(
        Uuid::new_v4(),
        std::collections::BTreeSet::new(),
    );

    let terse = service
        .recipes(CognitionCatalogRequest { verbose: false, estate_id: None })
        .expect("terse recipes must succeed");
    assert!(!terse.recipes.is_empty(), "terse result must have at least one recipe");
    assert!(
        terse.recipes[0].required_capabilities.is_none(),
        "terse mode must omit required_capabilities"
    );

    let verbose = service
        .recipes(CognitionCatalogRequest { verbose: true, estate_id: None })
        .expect("verbose recipes must succeed");
    assert!(!verbose.recipes.is_empty(), "verbose result must have at least one recipe");
    assert!(
        verbose.recipes[0].required_capabilities.is_some(),
        "verbose mode must carry required_capabilities"
    );
}

/// Pins the EXACT serialized key set of a verbose `moot_list_lenses` row, so
/// the Rust and Swift ports are compared field for field rather than each port
/// being checked only against itself. The Swift twin is
/// `verboseLensRowKeySetIsExact` (Tests/AriaMCPTests/UtilityTierTests.swift).
///
/// `output_schema` is present when the tool declares one and the key is OMITTED
/// when it does not. Neither port may emit a null `output_schema`: absent in
/// one port and null in the other is a conformance failure. Rust omits through
/// `.get("outputSchema").filter(!is_null).cloned()` plus
/// `skip_serializing_if = "Option::is_none"`; Swift omits through the `if let`
/// in its verbose row builder.
#[test]
fn cognition_catalog_v2_verbose_row_key_set_matches_swift() {
    use aria_mcp::lens_tools::is_lens_tool;
    use aria_mcp::recipe_tools::is_recipe_tool;
    use aria_mcp::v2::catalog::selected_tools;
    use aria_mcp::v2::cognition_catalog::{CognitionCatalogRequest, CognitionCatalogService};
    use std::collections::BTreeSet;
    use uuid::Uuid;

    let catalog = selected_tools();
    let callable: BTreeSet<String> = catalog
        .as_array()
        .expect("selected_tools must return an array")
        .iter()
        .filter_map(|t| {
            let name = t["name"].as_str()?;
            if is_recipe_tool(name) || is_lens_tool(name) {
                Some(name.to_owned())
            } else {
                None
            }
        })
        .collect();
    assert!(!callable.is_empty(), "there must be at least one callable cognition tool");

    let service = CognitionCatalogService::new(Uuid::new_v4(), callable);

    let verbose = service
        .lenses(CognitionCatalogRequest { verbose: true, estate_id: None })
        .expect("verbose lenses must succeed");
    assert!(!verbose.tools.is_empty(), "the verbose row set must not be empty");

    for tool in &verbose.tools {
        let row = serde_json::to_value(tool).expect("a descriptor must serialize");
        let obj = row.as_object().expect("a row must serialize as an object");
        let keys: BTreeSet<&str> = obj.keys().map(String::as_str).collect();

        // All v2 catalog operations supply an output_schema (the descriptor
        // projection always has one). The expected key set is therefore fixed:
        // a conditional on whether output_schema is present would allow one
        // port to omit it silently while the other includes it, defeating
        // the cross-port agreement check.
        let expected: BTreeSet<&str> =
            ["name", "description", "input_schema", "output_schema"].into_iter().collect();
        // No port may ever emit a null output_schema.
        assert!(
            !obj.get("output_schema").is_some_and(serde_json::Value::is_null),
            "{}: output_schema must be omitted, never null",
            tool.name
        );
        assert_eq!(keys, expected, "{} verbose key set", tool.name);
    }

    // The terse row is the same key set minus both schemas.
    let terse = service
        .lenses(CognitionCatalogRequest { verbose: false, estate_id: None })
        .expect("terse lenses must succeed");
    for tool in &terse.tools {
        let row = serde_json::to_value(tool).expect("a descriptor must serialize");
        let obj = row.as_object().expect("a row must serialize as an object");
        let keys: BTreeSet<&str> = obj.keys().map(String::as_str).collect();
        let expected: BTreeSet<&str> = ["name", "description"].into_iter().collect();
        assert_eq!(keys, expected, "{} terse key set", tool.name);
    }
}
