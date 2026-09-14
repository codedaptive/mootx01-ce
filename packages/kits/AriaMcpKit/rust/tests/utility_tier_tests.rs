//! PR-04 verification — Rust twin of `UtilityTierTests.swift`: the
//! estate-status subject-debt counter on a mixed fixture, and the
//! terse/verbose catalogue tiers.

use std::collections::BTreeMap;
mod test_support;
use test_support::SelectedV2Session;

use aria_mcp::{
    estate_registry::EstateRegistry,
    jsonrpc::JsonValue,
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
fn list_lenses_terse_default_and_verbose() {
    let registry = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());

    let terse = registry.call("moot_list_lenses", &args!())
        .expect("terse list_lenses must succeed");
    let terse_text = content_text(&terse).to_string();
    assert!(terse_text.contains("callable cognition tools."));
    assert!(terse_text.contains("(terse — pass verbose:true"));
    assert!(
        !terse_text.contains("(full schema)"),
        "terse mode must not include the full-schema listing"
    );

    let verbose = registry.call(
        "moot_list_lenses",
        &args!["verbose" => true],
    )
    .expect("verbose list_lenses must succeed");
    let verbose_text = content_text(&verbose);
    assert!(verbose_text.contains("callable cognition tools (full schema). Tools:"));
    assert!(
        !verbose_text.contains("(terse — pass verbose:true"),
        "verbose mode must not include the terse hint"
    );
    assert!(
        verbose_text.len() > terse_text.len(),
        "verbose must be larger than terse ({} vs {})",
        terse_text.len(),
        verbose_text.len()
    );
}

/// V2 structural path: `CognitionCatalogService.lenses()` must omit
/// `input_schema` and `output_schema` in terse mode and carry them in
/// verbose mode. Rust twin of the redirected Swift structural assertion in
/// `listLensesTerseDefaultAndVerbose` (UtilityTierTests.swift).
#[test]
fn cognition_catalog_service_v2_lenses_terse_omits_schemas() {
    use aria_mcp::v2::catalog::selected_registry;
    use aria_mcp::v2::cognition_catalog::{CognitionCatalogRequest, CognitionCatalogService};
    use std::collections::BTreeSet;
    use uuid::Uuid;

    let registry = selected_registry();
    let callable: BTreeSet<String> = registry
        .operations()
        .filter(|operation| operation.lens_lane_member)
        .map(|operation| operation.public_name.clone())
        .collect();
    assert!(!callable.is_empty(), "there must be at least one callable cognition tool");

    let service = CognitionCatalogService::new(Uuid::new_v4(), callable.clone());

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
    let expected: BTreeSet<String> = registry.operations()
        .filter(|operation| operation.lens_lane_member && callable.contains(&operation.public_name))
        .map(|operation| operation.public_name.clone())
        .collect();
    assert_eq!(
        terse.tools.iter().map(|tool| tool.name.clone()).collect::<BTreeSet<_>>(),
        expected,
        "lens row names must equal marked v2 registry entries intersected with callable names"
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
/// `skip_serializing_if = "Option::is_none"`; Swift omits through `if let
/// outputSchema = catalog.outputSchema` in the verbose row builder
/// (buildCatalogLookup path).
#[test]
fn cognition_catalog_v2_verbose_row_key_set_matches_swift() {
    use aria_mcp::v2::catalog::selected_registry;
    use aria_mcp::v2::cognition_catalog::{CognitionCatalogRequest, CognitionCatalogService};
    use std::collections::BTreeSet;
    use uuid::Uuid;

    let callable: BTreeSet<String> = selected_registry()
        .operations()
        .filter(|operation| operation.lens_lane_member)
        .map(|operation| operation.public_name.clone())
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
