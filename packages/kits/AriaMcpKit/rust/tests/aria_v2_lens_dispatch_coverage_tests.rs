//! Dispatch-surface coverage for 6 ARIA v2 lens operations not yet covered at
//! dispatch level in dispatch_tests.rs (moot_lens_rhythm is already present there
//! at line 5720). Exercises the production dispatch_tool path with the real
//! in-memory estate stack.
//!
//! Operations covered: moot_lens_anticipate, moot_lens_bias,
//! moot_lens_constellation, moot_lens_drift, moot_lens_latent_themes,
//! moot_lens_overlap (two-estate happy path + self-comparison error).
//!
//! Result shape: Rust lens handlers return text format (content[0].text).
//! The text prefix uniquely identifies which handler ran, so assertions on
//! the prefix discriminate against stub swaps.
//!
//! Helpers are declared locally because Rust integration test files are
//! independent binaries and cannot import from dispatch_tests.rs.

use std::collections::BTreeMap;

use aria_mcp::{
    dispatch::dispatch_tool,
    estate_registry::EstateRegistry,
    jsonrpc::{JSONRPCErrorCode, JsonValue},
    surfaced_recall_ledger::SurfacedRecallLedger,
};

// ---------------------------------------------------------------------------
// Test helpers — mirrors the helpers in dispatch_tests.rs
// ---------------------------------------------------------------------------

/// Builds a BTreeMap<String, JsonValue> argument map from key => value pairs.
macro_rules! args {
    () => { BTreeMap::new() };
    ( $( $k:expr => $v:expr ),+ $(,)? ) => {{
        let mut m = BTreeMap::new();
        $( m.insert($k.to_string(), JsonValue::from(serde_json::json!($v))); )+
        m
    }};
}

/// Extracts the text payload from content[0].text.
fn content_text(result: &serde_json::Value) -> &str {
    result["content"][0]["text"].as_str().unwrap_or("")
}

/// Returns true when the result carries isError:false.
fn is_success(result: &serde_json::Value) -> bool {
    result["isError"] == serde_json::json!(false)
}

/// Files a single memory into the default estate and returns its drawer ID.
/// `impatient: true` forces the write to land synchronously so immediately
/// subsequent lens calls can see the drawer.
fn file_one_memory(registry: &EstateRegistry, content: &str, location: &str) -> String {
    // Subject capped to 120 chars mirrors the dispatch_tests.rs pattern.
    let subject: String = content.chars().take(120).collect();
    let a = args![
        "content" => content,
        "subject" => subject.as_str(),
        "location" => location,
        "impatient" => true
    ];
    let result =
        dispatch_tool("moot_file_memory", &a, registry, &SurfacedRecallLedger::new())
            .expect("file_one_memory must succeed");
    assert!(is_success(&result), "file_memory should succeed; got: {result:?}");
    let text = content_text(&result);
    // "filed memory <id>\nroom: ..." — strip the prefix to recover the id.
    text.lines()
        .next()
        .and_then(|l| l.strip_prefix("filed memory "))
        .unwrap_or("")
        .to_owned()
}

// ---------------------------------------------------------------------------
// Happy paths
// ---------------------------------------------------------------------------

#[test]
fn lens_anticipate_over_estate_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    // Plant a memory so the anticipate lens has a non-empty corpus to reason over.
    file_one_memory(&registry, "anticipate lens coverage content", "lab");
    // targetKind is required by the schema.
    let result = dispatch_tool(
        "moot_lens_anticipate",
        &args!["targetKind" => "prose"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_lens_anticipate must not transport-fault");
    assert!(
        is_success(&result),
        "moot_lens_anticipate must be isError:false; got: {result:?}"
    );
    let text = content_text(&result);
    // "anticipate" prefix distinguishes this handler from every other lens.
    assert!(
        text.contains("anticipate"),
        "moot_lens_anticipate must return anticipate analysis text; got: {text}"
    );
}

#[test]
fn lens_bias_over_estate_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    // No required args for bias.
    let result = dispatch_tool(
        "moot_lens_bias",
        &args![],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_lens_bias must not transport-fault");
    assert!(
        is_success(&result),
        "moot_lens_bias must be isError:false; got: {result:?}"
    );
    let text = content_text(&result);
    // The bias handler produces a multi-line report that opens with "bias".
    assert!(
        text.contains("bias"),
        "moot_lens_bias must return bias report text; got: {text}"
    );
}

#[test]
fn lens_constellation_over_estate_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    // Plant content so the constellation graph has nodes to cluster.
    file_one_memory(&registry, "constellation lens coverage node", "work");
    // wing is required by the schema.
    let result = dispatch_tool(
        "moot_lens_constellation",
        &args!["wing" => "work"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_lens_constellation must not transport-fault");
    assert!(
        is_success(&result),
        "moot_lens_constellation must be isError:false; got: {result:?}"
    );
    let text = content_text(&result);
    // "constellation" prefix distinguishes this handler.
    assert!(
        text.contains("constellation"),
        "moot_lens_constellation must return constellation analysis text; got: {text}"
    );
}

#[test]
fn lens_drift_over_estate_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    // splitAt is required by the schema; ISO8601 string.
    let result = dispatch_tool(
        "moot_lens_drift",
        &args!["splitAt" => "2026-01-01T00:00:00Z"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_lens_drift must not transport-fault");
    assert!(
        is_success(&result),
        "moot_lens_drift must be isError:false; got: {result:?}"
    );
    let text = content_text(&result);
    // "drift:" prefix discriminates against every other lens handler.
    assert!(
        text.contains("drift"),
        "moot_lens_drift must return drift analysis text; got: {text}"
    );
}

#[test]
fn lens_latent_themes_over_estate_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    // No required args for latent_themes.
    let result = dispatch_tool(
        "moot_lens_latent_themes",
        &args![],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_lens_latent_themes must not transport-fault");
    assert!(
        is_success(&result),
        "moot_lens_latent_themes must be isError:false; got: {result:?}"
    );
    let text = content_text(&result);
    // "latent_themes" prefix distinguishes this handler.
    assert!(
        text.contains("latent_themes"),
        "moot_lens_latent_themes must return latent_themes analysis text; got: {text}"
    );
}

#[test]
fn lens_overlap_over_two_estates_succeeds() {
    // moot_lens_overlap requires a second estate (estateIDB); self-comparison is
    // rejected. register_inmemory wires a new in-memory estate into the shared
    // coordinator so the overlap lens can cross-address it.
    let mut registry = EstateRegistry::new_inmemory();
    let estate_b_id = registry.register_inmemory("estate-b-owner");
    // Plant content in the default estate to give the overlap lens a non-empty corpus.
    file_one_memory(&registry, "overlap lens coverage alpha content", "lab");
    let result = dispatch_tool(
        "moot_lens_overlap",
        &args!["estateIDB" => estate_b_id.to_string().as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_lens_overlap with two distinct estates must not transport-fault");
    assert!(
        is_success(&result),
        "moot_lens_overlap must be isError:false with two distinct estates; got: {result:?}"
    );
    let text = content_text(&result);
    // "mind_overlap:" prefix is unique to the overlap handler (see lens_tools.rs).
    assert!(
        text.contains("mind_overlap"),
        "moot_lens_overlap must return mind_overlap analysis text; got: {text}"
    );
}

// ---------------------------------------------------------------------------
// Error path
// ---------------------------------------------------------------------------

#[test]
fn lens_overlap_self_comparison_returns_invalid_params() {
    // Passing the default estate's UUID as estateIDB makes the lens compare an
    // estate with itself. The overlap handler rejects self-comparison as
    // meaningless (overlap=1.0 always) and returns Err(INVALID_PARAMS), which
    // is a transport fault — not isError:true.
    let registry = EstateRegistry::new_inmemory();
    let default_id = registry.default.estate_id.to_string();
    let err = dispatch_tool(
        "moot_lens_overlap",
        &args!["estateIDB" => default_id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect_err("self-comparison must be rejected with a transport fault");
    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "self-comparison error must be INVALID_PARAMS; got: {:?}",
        err.code
    );
}
