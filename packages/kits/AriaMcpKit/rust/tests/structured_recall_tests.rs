//! MXE-SS: the recall family (moot_memory_search, moot_memory_get,
//! moot_recall_shaped, moot_recall_precise) declares an outputSchema and
//! returns structuredContent — a typed twin of the text block carrying
//! id / room / content / subject per rendered row.
//!
//! Four contracts under test, in the mission's priority order:
//!   1. COMPATIBILITY — the text block keeps its exact pre-change bytes
//!      (header, dense rows, advisory).
//!   2. PARITY — structuredContent fields match the text block's values.
//!   3. REDACTION (the security test) — a provenance-gated drawer is
//!      redacted identically in both blocks; no structured field carries
//!      what the text withheld. Fails against a naive implementation that
//!      populates structured fields from unredacted values
//!      (PreciseMatch.content / Drawer.content are pre-redaction at the
//!      emission sites).
//!   4. SCHEMA — all four tools declare the SAME outputSchema with the
//!      same field names the Swift twin pins
//!      (StructuredRecallResultTests.recallFamilyDeclaresOneSharedOutputSchema).
//!
//! Swift peer: `Tests/AriaMCPTests/StructuredRecallResultTests.swift`.

use std::collections::BTreeMap;

use aria_mcp::{
    dispatch::dispatch_tool,
    estate_registry::EstateRegistry,
    jsonrpc::JsonValue,
    surfaced_recall_ledger::SurfacedRecallLedger,
    tool_list::build_tool_list_with_flags,
};

/// Redaction markers — byte-identical pins of dense_row's constants; the
/// structured block must carry exactly these strings for gated rows.
const RESTRICTED_MARKER: &str = "[sensitivity: restricted — content redacted]";
const SECRET_MARKER: &str = "[sensitivity: secret — content access requires explicit grant]";
const NO_SUBJECT_MARKER: &str = "(no subject)";

macro_rules! args {
    ( $( $k:expr => $v:expr ),+ $(,)? ) => {{
        let mut m = BTreeMap::new();
        $( m.insert($k.to_string(), JsonValue::from(serde_json::json!($v))); )+
        m
    }};
}

fn content_text(result: &serde_json::Value) -> &str {
    result["content"][0]["text"].as_str().unwrap_or("")
}

fn structured_results(result: &serde_json::Value) -> Vec<&serde_json::Value> {
    result["structuredContent"]["results"]
        .as_array()
        .map(|rows| rows.iter().collect())
        .unwrap_or_default()
}

fn row_for<'a>(rows: &[&'a serde_json::Value], id: &str) -> Option<&'a serde_json::Value> {
    rows.iter().find(|r| r["id"].as_str() == Some(id)).copied()
}

/// File a memory through the tool surface and return its id.
fn file_one(registry: &EstateRegistry, content: &str, subject: &str) -> String {
    let a = args![
        "content" => content,
        "subject" => subject,
        "location" => "structured-recall-tests"
    ];
    let result = dispatch_tool("moot_file_memory", &a, registry, &SurfacedRecallLedger::new())
        .expect("file_memory must succeed");
    content_text(&result)
        .lines()
        .next()
        .and_then(|l| l.strip_prefix("filed memory "))
        .expect("file_memory reply must lead with the filed id")
        .to_owned()
}

/// Seed via direct capture with a chosen PROVENANCE sensitivity (the axis
/// the redaction markers key on). The adjective axis stays at the
/// gate-admitting default so the row surfaces and reaches the rendering
/// code. Mirrors dispatch_tests::file_one_memory_with_provenance_sensitivity.
fn file_one_with_provenance(
    registry: &EstateRegistry,
    content: &str,
    subject: &str,
    sensitivity: locus_kit::provenance::Sensitivity,
) -> String {
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::estate_types::LatticeAnchor;
    use locus_kit::frames::CaptureFrame;

    let mut frame = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "structured-recall-tests",
        LatticeAnchor::udc("004"),
        "aria-mcp-tests",
        "default",
    );
    frame.provenance_sensitivity = sensitivity;
    frame.subject = Some(subject.to_string());

    let now = aria_mcp::dispatch::wall_now();
    let coord = registry.coord.lock().unwrap();
    let drawer = coord
        .capture(&registry.default.handle, frame, now)
        .expect("provenance-sensitive capture must succeed");
    drawer.id.clone()
}

// ---------------------------------------------------------------------------
// 1. Compatibility — the text block keeps its pre-change bytes
// ---------------------------------------------------------------------------

#[test]
fn search_text_block_keeps_pre_change_format() {
    let registry = EstateRegistry::new_inmemory_bare();
    let id = file_one(&registry, "ss-compat fixture body", "compat subject line");

    let a = args!["query" => "ss-compat fixture"];
    let result = dispatch_tool("moot_memory_search", &a, &registry, &SurfacedRecallLedger::new())
        .expect("search must succeed");

    let body = content_text(&result);
    let lines: Vec<&str> = body.lines().collect();
    assert_eq!(
        lines.first().copied(),
        Some("found 1 memory(s)"),
        "header must keep the pre-change byte format; got: {body}"
    );
    // The dense row keeps its five-field ` · `-separated shape and leads
    // with the id (the pre-change row format).
    let row_line = lines
        .iter()
        .find(|l| l.starts_with(&id))
        .expect("the seeded drawer's dense row must be present");
    assert_eq!(row_line.split(" · ").count(), 5, "five dense-row fields");
    assert!(row_line.contains("compat subject line"));
    // The advisory keeps its pre-change spelling and position (last line).
    assert_eq!(
        lines.last().copied(),
        Some(
            "sensitivity_advisory: a sensitivity tier gate is in effect — \
             run `mootx01 unlock private` to include restricted memories, \
             `mootx01 unlock secret` for secret memories."
        )
    );
    // The envelope keeps isError and the single text content block.
    assert_eq!(result["isError"], serde_json::json!(false));
    assert_eq!(result["content"].as_array().map(|c| c.len()), Some(1));
}

// ---------------------------------------------------------------------------
// 2. Parity — structured fields match the text block's values
// ---------------------------------------------------------------------------

#[test]
fn search_structured_rows_match_text_rows() {
    let registry = EstateRegistry::new_inmemory_bare();
    let id = file_one(&registry, "ss-parity unique fixture body", "parity subject");

    let a = args!["query" => "ss-parity unique fixture"];
    let result = dispatch_tool("moot_memory_search", &a, &registry, &SurfacedRecallLedger::new())
        .expect("search must succeed");

    let rows = structured_results(&result);
    let row = row_for(&rows, &id).expect("the seeded drawer must have a structured row");
    assert_eq!(row["subject"].as_str(), Some("parity subject"));
    assert_eq!(row["room"].as_str(), Some("structured-recall-tests"));
    assert_eq!(row["content"].as_str(), Some("ss-parity unique fixture body"));
    // Text and structured cover the same rows.
    let body = content_text(&result);
    for r in &rows {
        assert!(
            body.contains(r["id"].as_str().unwrap()),
            "every structured row id must appear in the text block"
        );
    }
}

#[test]
fn memory_get_full_structured_row_matches_record() {
    let registry = EstateRegistry::new_inmemory_bare();
    let id = file_one(&registry, "ss-get verbatim body, byte for byte", "get subject");

    let a = args!["id" => id.as_str()];
    let result = dispatch_tool("moot_memory_get", &a, &registry, &SurfacedRecallLedger::new())
        .expect("get must succeed");

    let rows = structured_results(&result);
    assert_eq!(rows.len(), 1, "single-id get returns exactly one structured row");
    let row = rows[0];
    assert_eq!(row["id"].as_str(), Some(id.as_str()));
    assert_eq!(row["room"].as_str(), Some("structured-recall-tests"));
    assert_eq!(row["content"].as_str(), Some("ss-get verbatim body, byte for byte"));
    assert_eq!(row["subject"].as_str(), Some("get subject"));
    // The text block still carries the same values (parity, not replacement).
    let body = content_text(&result);
    assert!(body.contains("ss-get verbatim body, byte for byte"));
    assert!(body.contains("subject: get subject"));
}

#[test]
fn memory_get_depth_subject_omits_content() {
    let registry = EstateRegistry::new_inmemory_bare();
    let id = file_one(&registry, "ss-depth body must not travel", "depth subject");

    let a = args!["id" => id.as_str(), "depth" => "subject"];
    let result = dispatch_tool("moot_memory_get", &a, &registry, &SurfacedRecallLedger::new())
        .expect("get must succeed");

    let rows = structured_results(&result);
    let row = rows.first().expect("one structured row");
    assert!(
        row.get("content").is_none(),
        "depth:subject must omit content — the text carries no body at this tier"
    );
    assert_eq!(row["id"].as_str(), Some(id.as_str()));
    assert!(row.get("subject").is_some());
    assert!(
        !result.to_string().contains("ss-depth body must not travel"),
        "the body must not appear anywhere in the depth:subject envelope"
    );
}

#[test]
fn memory_get_batch_omits_not_found_rows_from_structured() {
    let registry = EstateRegistry::new_inmemory_bare();
    let id = file_one(&registry, "ss-batch present row", "batch subject");
    let absent = "00000000-0000-4000-8000-00000000ss00";

    let a = args!["ids" => [id.as_str(), absent], "depth" => "subject"];
    let result = dispatch_tool("moot_memory_get", &a, &registry, &SurfacedRecallLedger::new())
        .expect("batch get must succeed");

    assert!(content_text(&result).contains(&format!("not found: {absent}")));
    let rows = structured_results(&result);
    assert_eq!(rows.len(), 1, "only the found row is in the structured block");
    assert_eq!(rows[0]["id"].as_str(), Some(id.as_str()));
}

#[test]
fn shaped_and_precise_structured_rows_match_text() {
    let registry = EstateRegistry::new_inmemory_bare();
    let id = file_one(
        &registry,
        "the indemnity was 46 million marks",
        "indemnity figure",
    );

    for (tool, extra_preset) in [("moot_recall_precise", None), ("moot_recall_shaped", Some("balanced"))] {
        let mut a = args![
            "query" => "the indemnity was 46 million marks",
            "filter" => "unconfirmed"
        ];
        if let Some(preset) = extra_preset {
            a.insert("preset".to_string(), JsonValue::from(serde_json::json!(preset)));
        }
        let result = dispatch_tool(tool, &a, &registry, &SurfacedRecallLedger::new())
            .unwrap_or_else(|e| panic!("{tool} must succeed: {e:?}"));
        assert_eq!(result["isError"], serde_json::json!(false), "{tool} must succeed");
        let rows = structured_results(&result);
        assert!(!rows.is_empty(), "{tool} must carry structured rows");
        let row = row_for(&rows, &id)
            .unwrap_or_else(|| panic!("{tool}: the seeded row must appear"));
        assert_eq!(row["content"].as_str(), Some("the indemnity was 46 million marks"));
        assert_eq!(row["subject"].as_str(), Some("indemnity figure"));
        assert_eq!(row["room"].as_str(), Some("structured-recall-tests"));
        assert!(content_text(&result).contains(id.as_str()));
    }
}

// ---------------------------------------------------------------------------
// 3. Redaction parity (THE security test)
// ---------------------------------------------------------------------------

#[test]
fn search_redacts_structured_block_identically_to_text() {
    let registry = EstateRegistry::new_inmemory_bare();
    let id = file_one_with_provenance(
        &registry,
        "ss-redact classified payload details",
        "classified subject line",
        locus_kit::provenance::Sensitivity::Restricted,
    );

    let a = args!["query" => "ss-redact classified"];
    let result = dispatch_tool("moot_memory_search", &a, &registry, &SurfacedRecallLedger::new())
        .expect("search must succeed");

    // Text: marker in the subject slot (pre-existing behavior).
    assert!(content_text(&result).contains(RESTRICTED_MARKER));
    // Structured: SAME marker in subject and content; never the body.
    let rows = structured_results(&result);
    let row = row_for(&rows, &id).expect("the restricted row is admissible and must appear");
    assert_eq!(
        row["subject"].as_str(),
        Some(RESTRICTED_MARKER),
        "structured subject must carry the text's redaction marker"
    );
    assert_eq!(
        row["content"].as_str(),
        Some(RESTRICTED_MARKER),
        "structured content must carry the marker, never the body"
    );
    // The strongest form: the body appears nowhere in the whole envelope.
    let envelope = result.to_string();
    assert!(
        !envelope.contains("classified payload details"),
        "the redacted body must not appear anywhere in the reply"
    );
    assert!(
        !envelope.contains("classified subject line"),
        "the redacted subject must not appear anywhere in the reply"
    );
}

#[test]
fn precise_recall_redacts_structured_block_for_secret_rows() {
    let registry = EstateRegistry::new_inmemory_bare();
    let id = file_one_with_provenance(
        &registry,
        "the launch code is 46 million",
        "launch code memo",
        locus_kit::provenance::Sensitivity::Secret,
    );

    let a = args![
        "query" => "the launch code is 46 million",
        "filter" => "unconfirmed"
    ];
    let result = dispatch_tool("moot_recall_precise", &a, &registry, &SurfacedRecallLedger::new())
        .expect("precise recall must succeed");
    assert_eq!(result["isError"], serde_json::json!(false));

    let rows = structured_results(&result);
    let row = row_for(&rows, &id)
        .expect("the secret row is admissible (adjective normal) and must appear");
    assert_eq!(row["subject"].as_str(), Some(SECRET_MARKER));
    assert_eq!(
        row["content"].as_str(),
        Some(SECRET_MARKER),
        "PreciseMatch.content is pre-redaction — the marker switch must fire"
    );
    assert!(
        !result.to_string().contains("launch code"),
        "neither body nor subject of a secret row may appear in the reply"
    );
}

#[test]
fn memory_get_keeps_provenance_gate_in_both_blocks() {
    let registry = EstateRegistry::new_inmemory_bare();
    let gated = file_one_with_provenance(
        &registry,
        "ss-gated body",
        "gated subject",
        locus_kit::provenance::Sensitivity::Secret,
    );
    let visible = file_one(&registry, "ss-visible body", "visible subject");

    // Single id: not-found error, no result envelope at all.
    let a = args!["id" => gated.as_str()];
    let err = dispatch_tool("moot_memory_get", &a, &registry, &SurfacedRecallLedger::new())
        .expect_err("a provenance-gated row must be not-found by id");
    assert!(err.message.contains("Memory not found"));

    // Batch: text says "not found:", structured omits the row.
    let a = args!["ids" => [gated.as_str(), visible.as_str()], "depth" => "distilled"];
    let result = dispatch_tool("moot_memory_get", &a, &registry, &SurfacedRecallLedger::new())
        .expect("batch get must succeed");
    assert!(content_text(&result).contains(&format!("not found: {gated}")));
    let rows = structured_results(&result);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["id"].as_str(), Some(visible.as_str()));
    assert!(
        !result.to_string().contains("ss-gated body"),
        "the gated body must not appear anywhere in the reply"
    );
}

/// An opaque text row (id the by-id hydration refused) must be exactly as
/// opaque in the structured block: id + '(no subject)' only. Exercised at
/// the helper level — the same function every recall arm calls — because
/// manufacturing a recall hit whose drawer the frame refuses requires racing
/// the gate; the helper IS the contract.
#[test]
fn opaque_rows_carry_no_room_or_content() {
    let row = aria_mcp::interface_tools::opaque_structured_row("some-id");
    let json = serde_json::json!({
        "content": [{"type": "text", "text": ""}],
    });
    let _ = json; // silence unused in case of future edits
    let rendered = aria_mcp::interface_tools::structured_text_result("t", &[row]);
    let rows = structured_results(&rendered);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["id"].as_str(), Some("some-id"));
    assert_eq!(rows[0]["subject"].as_str(), Some(NO_SUBJECT_MARKER));
    assert!(rows[0].get("room").is_none(), "opaque rows carry no room");
    assert!(rows[0].get("content").is_none(), "opaque rows carry no content");
}

// ---------------------------------------------------------------------------
// 4. Schema — one schema, four tools, pinned field names (cross-port fixture)
// ---------------------------------------------------------------------------

#[test]
fn recall_family_declares_one_shared_output_schema() {
    let tools = build_tool_list_with_flags(true, false);
    let tools = tools.as_array().expect("tools array");
    let family = [
        "moot_memory_search",
        "moot_memory_get",
        "moot_recall_shaped",
        "moot_recall_precise",
    ];

    let mut schemas: Vec<&serde_json::Value> = Vec::new();
    for tool in tools {
        let name = tool["name"].as_str().unwrap_or("");
        match tool.get("outputSchema") {
            Some(schema) if family.contains(&name) => schemas.push(schema),
            Some(_) => panic!("{name} must not declare an output schema (out of scope)"),
            None => assert!(
                !family.contains(&name),
                "{name} must declare the shared recall-results schema"
            ),
        }
    }
    assert_eq!(schemas.len(), family.len(), "all four in-scope tools declare it");
    for schema in &schemas[1..] {
        assert_eq!(*schema, schemas[0], "one shared schema across the family");
    }

    // Field-name pin (cross-port fixture): the Swift twin asserts these same
    // names against ToolProjection.recallResultsOutputSchema.
    let items = &schemas[0]["properties"]["results"]["items"];
    let mut fields: Vec<&str> = items["properties"]
        .as_object()
        .expect("items properties")
        .keys()
        .map(|k| k.as_str())
        .collect();
    fields.sort_unstable();
    assert_eq!(fields, ["content", "id", "room", "subject"]);
    assert_eq!(items["required"], serde_json::json!(["id"]));
    assert_eq!(schemas[0]["required"], serde_json::json!(["results"]));
}
