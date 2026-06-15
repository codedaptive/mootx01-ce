//! Unit tests for the outbound MemPalace pump's pure cores — Rust leg.
//! Conformance-gated against the Swift `Palace*Tests` (same vectors, same
//! assertions). No live server; the live scratch-pump path is exercised by the
//! Swift integration test (guarded) and the manual probe documented in the
//! completion report.

use std::collections::{BTreeMap, HashMap};
use vault_kit::note_ir::{Block, FactIR, NoteIR, OccurredAt, SourceRef, WikiLink};
use vault_kit::palace_drift_detector::{self, PalaceDriftFinding, PalaceLiveTool};
use vault_kit::palace_payload_envelope::{self, EnvelopeDecodeError, PalaceEnvelopePayload};
use vault_kit::palace_pump_mapping;
use vault_kit::palace_response_parsing;

/// Build a richly-populated note exercising every lossy field.
fn full_note() -> NoteIR {
    let mut frontmatter = HashMap::new();
    frontmatter.insert("room".to_owned(), "research".to_owned());
    frontmatter.insert("udc".to_owned(), "314".to_owned());
    let mut scope = BTreeMap::new();
    scope.insert("agent".to_owned(), "nagatha".to_owned());
    let mut note = NoteIR::with_moot_id(
        "projects/alpha/notes/benzene",
        vec![Block::markdown("A study of benzene and its ring structure.")],
        frontmatter,
        vec![WikiLink::new("Benzene", Some("the ring".to_owned()), "Benzene|the ring")],
        vec!["chem".to_owned(), "aromatics".to_owned()],
        "projects/alpha/notes",
        Some(OccurredAt::new("2024-03-04T05:06:07.000Z")),
        Some(SourceRef::new("attach/diagram.png", "abc123", Some("image/png".to_owned()), Some(2048))),
        Some(uuid::Uuid::parse_str("12345678-1234-1234-1234-1234567890ab").unwrap()),
    );
    note.facts = vec![FactIR::new("benzene", "has-structure", "aromatic-ring")];
    note.path_components = vec![
        "projects".to_owned(),
        "alpha".to_owned(),
        "notes".to_owned(),
        "benzene".to_owned(),
    ];
    note.scope = scope;
    note.kind = "note".to_owned();
    note
}

#[test]
fn envelope_round_trips_every_lossy_field() {
    let note = full_note();
    let payload = PalaceEnvelopePayload::from_note(&note);
    let content = palace_payload_envelope::encode(&note.flattened_body(), &payload).unwrap();

    // Body prose is above the marker (searchable, human-first).
    assert!(content.starts_with("A study of benzene"));
    assert!(content.contains("<!-- MOOT-ENVELOPE v1"));

    let decoded = palace_payload_envelope::decode(&content).unwrap();
    assert_eq!(decoded.body, note.flattened_body());
    let recovered = decoded.payload.expect("payload present");
    assert_eq!(recovered, payload, "decode(encode(x)) == x for the payload");
    // Every lossy field survived.
    assert_eq!(recovered.frontmatter.get("udc").unwrap(), "314");
    assert_eq!(recovered.links.len(), 1);
    assert_eq!(recovered.tags, vec!["chem", "aromatics"]);
    assert_eq!(recovered.origin_date.unwrap().iso8601, "2024-03-04T05:06:07.000Z");
    assert_eq!(recovered.source.unwrap().byte_size, Some(2048));
    assert_eq!(
        recovered.moot_id.unwrap(),
        uuid::Uuid::parse_str("12345678-1234-1234-1234-1234567890ab").unwrap()
    );
    assert_eq!(recovered.facts.len(), 1);
    assert_eq!(recovered.path_components.len(), 4);
    assert_eq!(recovered.scope.get("agent").unwrap(), "nagatha");
}

#[test]
fn reconstruct_note_recovers_full_note() {
    let note = full_note();
    let args = palace_pump_mapping::make_args(&note).unwrap();
    let reconstructed = palace_payload_envelope::reconstruct_note(&args.content, "fallback").unwrap();
    assert_eq!(reconstructed.stable_source_key, note.stable_source_key);
    assert_eq!(reconstructed.flattened_body(), note.flattened_body());
    assert_eq!(reconstructed.facts, note.facts);
    assert_eq!(reconstructed.path_components, note.path_components);
    assert_eq!(reconstructed.scope, note.scope);
    assert_eq!(reconstructed.moot_id, note.moot_id);
}

#[test]
fn foreign_drawer_content_decodes_as_plain_prose() {
    let decoded = palace_payload_envelope::decode("just a normal drawer, no envelope").unwrap();
    assert_eq!(decoded.body, "just a normal drawer, no envelope");
    assert!(decoded.payload.is_none());
}

#[test]
fn unsupported_envelope_version_is_a_loud_error() {
    let bad = "body\n\n<!-- MOOT-ENVELOPE v99\n{}\nMOOT-ENVELOPE -->";
    match palace_payload_envelope::decode(bad) {
        Err(EnvelopeDecodeError::UnsupportedVersion(99)) => {}
        other => panic!("expected UnsupportedVersion(99), got {other:?}"),
    }
}

#[test]
fn unterminated_envelope_errors() {
    let bad = "body\n\n<!-- MOOT-ENVELOPE v1\n{ \"stableSourceKey\": \"x\" ";
    assert!(matches!(
        palace_payload_envelope::decode(bad),
        Err(EnvelopeDecodeError::Unterminated)
    ));
}

#[test]
fn arg_building_derives_wing_room_from_path_components() {
    let note = full_note();
    let args = palace_pump_mapping::make_args(&note).unwrap();
    // first component → wing; the rest joined with "/" → room.
    assert_eq!(args.wing, "projects");
    assert_eq!(args.room, "alpha/notes/benzene");
    assert_eq!(args.source_file, "projects/alpha/notes/benzene");
    assert_eq!(args.added_by, "mootx01-pump");
    assert!(args.content.contains("<!-- MOOT-ENVELOPE v1"));
}

#[test]
fn arg_building_falls_back_for_flat_and_empty_paths() {
    let flat = NoteIR::new(
        "k",
        vec![Block::markdown("c")],
        HashMap::new(),
        Vec::new(),
        Vec::new(),
        "",
        None,
        None,
    );
    let args = palace_pump_mapping::make_args(&flat).unwrap();
    assert_eq!(args.wing, "mootx01");
    assert_eq!(args.room, "general");

    let mut one = flat.clone();
    one.path_components = vec!["solo".to_owned()];
    let args1 = palace_pump_mapping::make_args(&one).unwrap();
    assert_eq!(args1.wing, "solo");
    assert_eq!(args1.room, "general");
}

#[test]
fn sanitize_collapses_unsafe_runs_to_single_hyphen() {
    assert_eq!(palace_pump_mapping::sanitize("My Project!! Name"), "My-Project-Name");
    assert_eq!(palace_pump_mapping::sanitize("  spaced  "), "spaced");
    assert_eq!(palace_pump_mapping::sanitize("keep_under-score"), "keep_under-score");
    assert_eq!(palace_pump_mapping::sanitize("***"), "");
}

#[test]
fn parse_add_drawer_id_handles_fresh_and_duplicate_shapes() {
    let fresh = vec![r#"{"success": true, "drawer_id": "drawer_w_r_abc", "wing": "w", "room": "r"}"#.to_owned()];
    assert_eq!(
        palace_response_parsing::parse_add_drawer_id(&fresh).unwrap(),
        "drawer_w_r_abc"
    );
    let dup = vec![r#"{"success": true, "reason": "already_exists", "drawer_id": "drawer_w_r_abc"}"#.to_owned()];
    assert_eq!(
        palace_response_parsing::parse_add_drawer_id(&dup).unwrap(),
        "drawer_w_r_abc"
    );
    // A non-JSON diagnostic block is skipped; missing id is an error.
    assert!(palace_response_parsing::parse_add_drawer_id(&["not json".to_owned()]).is_err());
}

#[test]
fn parse_get_drawer_extracts_id_and_full_content() {
    let block = vec![r#"{"drawer_id": "drawer_w_r_abc", "content": "the full verbatim body", "wing": "w", "room": "r", "metadata": {"filed_at": "2026-06-10T18:17:52"}}"#.to_owned()];
    let fetched = palace_response_parsing::parse_get_drawer(&block).unwrap();
    assert_eq!(fetched.drawer_id, "drawer_w_r_abc");
    assert_eq!(fetched.content, "the full verbatim body");
}

#[test]
fn drift_detector_passes_on_the_verified_live_surface() {
    // The full four-noun tools/list shape captured from mempalace-mcp v3.3.3:
    // the four write tools (one per noun) plus the read/verify tools.
    fn req(items: &[&str]) -> std::collections::BTreeSet<String> {
        items.iter().map(|s| s.to_string()).collect()
    }
    let live = vec![
        PalaceLiveTool {
            name: "mempalace_add_drawer".to_owned(),
            required_args: req(&["wing", "room", "content"]),
        },
        PalaceLiveTool {
            name: "mempalace_create_tunnel".to_owned(),
            required_args: req(&["source_wing", "source_room", "target_wing", "target_room"]),
        },
        PalaceLiveTool {
            name: "mempalace_kg_add".to_owned(),
            required_args: req(&["subject", "predicate", "object"]),
        },
        PalaceLiveTool {
            name: "mempalace_diary_write".to_owned(),
            required_args: req(&["agent_name", "entry"]),
        },
        PalaceLiveTool {
            name: "mempalace_get_drawer".to_owned(),
            required_args: req(&["drawer_id"]),
        },
        PalaceLiveTool {
            name: "mempalace_list_tunnels".to_owned(),
            required_args: Default::default(),
        },
        PalaceLiveTool {
            name: "mempalace_kg_query".to_owned(),
            required_args: req(&["entity"]),
        },
        PalaceLiveTool {
            name: "mempalace_diary_read".to_owned(),
            required_args: req(&["agent_name"]),
        },
        PalaceLiveTool {
            name: "mempalace_list_drawers".to_owned(),
            required_args: Default::default(),
        },
        PalaceLiveTool {
            name: "mempalace_search".to_owned(),
            required_args: req(&["query"]),
        },
    ];
    let findings = palace_drift_detector::diff(&live, &palace_drift_detector::expected_manifest());
    assert!(findings.is_empty(), "no drift on the verified surface: {findings:?}");
}

#[test]
fn drift_detector_flags_a_renamed_tool() {
    let live = vec![PalaceLiveTool {
        name: "mempalace_create_drawer".to_owned(), // renamed from add_drawer
        required_args: ["wing", "room", "content"].iter().map(|s| s.to_string()).collect(),
    }];
    let findings = palace_drift_detector::diff(&live, &palace_drift_detector::expected_manifest());
    assert!(findings.iter().any(|finding| matches!(
        finding,
        PalaceDriftFinding::ToolMissing { name } if name == "mempalace_add_drawer"
    )));
}

#[test]
fn drift_detector_flags_a_new_required_arg_the_pump_cannot_supply() {
    let live = vec![PalaceLiveTool {
        name: "mempalace_add_drawer".to_owned(),
        // MemPalace now requires an "owner_key" the pump does not send.
        required_args: ["wing", "room", "content", "owner_key"]
            .iter()
            .map(|s| s.to_string())
            .collect(),
    }];
    let findings = palace_drift_detector::diff(&live, &palace_drift_detector::expected_manifest());
    assert!(findings.iter().any(|finding| matches!(
        finding,
        PalaceDriftFinding::NewRequiredArgUnsupplied { tool, arg }
            if tool == "mempalace_add_drawer" && arg == "owner_key"
    )));
}

#[test]
fn live_tool_parse_reads_tools_list_payload() {
    let payload = br#"{"tools":[{"name":"mempalace_add_drawer","inputSchema":{"required":["wing","room","content"],"properties":{}}},{"name":"mempalace_get_drawer","inputSchema":{"required":["drawer_id"]}}]}"#;
    let tools = PalaceLiveTool::parse(payload).unwrap();
    assert_eq!(tools.len(), 2);
    assert_eq!(tools[0].name, "mempalace_add_drawer");
    assert!(tools[0].required_args.contains("wing"));
}
