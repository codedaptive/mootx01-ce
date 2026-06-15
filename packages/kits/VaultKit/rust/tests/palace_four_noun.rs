//! Unit tests for the canonical four-noun palace pump's pure cores — Rust leg.
//! Conformance-gated against the Swift `PalaceFourNounTests`: the SAME item
//! vectors, the SAME expected canonical envelope bytes, so the per-noun mapping,
//! the generic versioned envelope, the drift manifest, and the per-noun response
//! parsing are proven byte-for-byte equivalent across the two ports.
//!
//! The cross-implementation guard is the EXPECTED-BYTES literal: each port
//! encodes the same `PalaceItem` and asserts the result equals the exact same
//! string. The bitmap fields are encoded as serde_json INTEGERS (`5`, not
//! `5.0`) to match Swift's JSONEncoder, which emits integer-valued numbers
//! without a fractional part — the cross-language number-format anchor.

use std::collections::BTreeMap;
use vault_kit::palace_drift_detector;
use vault_kit::palace_item::{PalaceItem, PalaceNoun};
use vault_kit::palace_payload_envelope;
use vault_kit::palace_pump_mapping;
use vault_kit::palace_response_parsing;

fn fields(pairs: &[(&str, serde_json::Value)]) -> BTreeMap<String, serde_json::Value> {
    pairs.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}

fn drawer_item() -> PalaceItem {
    PalaceItem::new(
        PalaceNoun::Drawer,
        "drawer_alpha_research_001",
        "A study of benzene.",
        fields(&[
            ("wing", serde_json::json!("alpha")),
            ("room", serde_json::json!("research")),
            ("content", serde_json::json!("A study of benzene.")),
        ]),
        fields(&[
            ("noun", serde_json::json!("drawer")),
            ("id", serde_json::json!("drawer_alpha_research_001")),
            ("lineageID", serde_json::json!("12345678-1234-1234-1234-1234567890AB")),
            ("adjectiveBitmap", serde_json::json!(5)),
            ("udcCode", serde_json::json!("314")),
        ]),
    )
}

fn tunnel_item() -> PalaceItem {
    PalaceItem::new(
        PalaceNoun::Tunnel,
        "tunnel_001",
        "tunnel: alpha/research → beta/notes [supersedes]",
        fields(&[
            ("source_wing", serde_json::json!("alpha")),
            ("source_room", serde_json::json!("research")),
            ("target_wing", serde_json::json!("beta")),
            ("target_room", serde_json::json!("notes")),
            ("label", serde_json::json!("supersedes")),
        ]),
        fields(&[
            ("noun", serde_json::json!("tunnel")),
            ("id", serde_json::json!("tunnel_001")),
            ("kind", serde_json::json!(2)),
            ("provenanceBitmap", serde_json::json!(1)),
        ]),
    )
}

fn fact_item() -> PalaceItem {
    PalaceItem::new(
        PalaceNoun::KgFact,
        "fact_001",
        "benzene → has-structure → aromatic-ring",
        fields(&[
            ("subject", serde_json::json!("benzene")),
            ("predicate", serde_json::json!("has-structure")),
            ("object", serde_json::json!("aromatic-ring")),
            ("valid_from", serde_json::json!("2024-03-04")),
        ]),
        fields(&[
            ("noun", serde_json::json!("kgFact")),
            ("id", serde_json::json!("fact_001")),
            ("sourceDrawerID", serde_json::json!("drawer_alpha_research_001")),
            ("filedAt", serde_json::json!("2024-03-04T05:06:07.000Z")),
        ]),
    )
}

fn diary_item() -> PalaceItem {
    PalaceItem::new(
        PalaceNoun::DiaryEntry,
        "diary_001",
        "Filed the benzene study.",
        fields(&[
            ("agent_name", serde_json::json!("nagatha")),
            ("topic", serde_json::json!("research")),
            ("entry", serde_json::json!("Filed the benzene study.")),
            ("wing", serde_json::json!("alpha")),
        ]),
        fields(&[
            ("noun", serde_json::json!("diaryEntry")),
            ("id", serde_json::json!("diary_001")),
            ("room", serde_json::json!("research")),
        ]),
    )
}

// --- per-noun mapping ---

#[test]
fn drawer_maps_to_add_drawer_with_envelope_in_content() {
    let call = palace_pump_mapping::call(&drawer_item()).unwrap();
    assert_eq!(call.tool, "mempalace_add_drawer");
    assert_eq!(call.arguments.get("wing").unwrap().as_str(), Some("alpha"));
    assert_eq!(call.arguments.get("added_by").unwrap().as_str(), Some("mootx01-pump"));
    let content = call.arguments.get("content").unwrap().as_str().unwrap();
    assert!(content.starts_with("A study of benzene."));
    assert!(content.contains("<!-- MOOT-ENVELOPE v1"));
}

#[test]
fn tunnel_maps_endpoints_native_and_envelope_rides_label() {
    let call = palace_pump_mapping::call(&tunnel_item()).unwrap();
    assert_eq!(call.tool, "mempalace_create_tunnel");
    assert_eq!(call.arguments.get("source_wing").unwrap().as_str(), Some("alpha"));
    assert_eq!(call.arguments.get("target_room").unwrap().as_str(), Some("notes"));
    let label = call.arguments.get("label").unwrap().as_str().unwrap();
    assert!(label.starts_with("supersedes"));
    assert!(label.contains("\"kind\":2"));
}

#[test]
fn fact_triple_stays_clean_and_envelope_rides_source_closet() {
    let call = palace_pump_mapping::call(&fact_item()).unwrap();
    assert_eq!(call.tool, "mempalace_kg_add");
    // The triple is the CLEAN native value.
    assert_eq!(call.arguments.get("object").unwrap().as_str(), Some("aromatic-ring"));
    assert_eq!(call.arguments.get("valid_from").unwrap().as_str(), Some("2024-03-04"));
    let closet = call.arguments.get("source_closet").unwrap().as_str().unwrap();
    assert!(closet.contains("<!-- MOOT-ENVELOPE v1"));
    assert!(closet.contains("\"sourceDrawerID\":\"drawer_alpha_research_001\""));
}

#[test]
fn fact_with_no_envelope_sends_no_source_closet() {
    let bare = PalaceItem::new(
        PalaceNoun::KgFact,
        "f2",
        "a → b → c",
        fields(&[
            ("subject", serde_json::json!("a")),
            ("predicate", serde_json::json!("b")),
            ("object", serde_json::json!("c")),
        ]),
        BTreeMap::new(),
    );
    let call = palace_pump_mapping::call(&bare).unwrap();
    assert!(call.arguments.get("source_closet").is_none());
}

#[test]
fn diary_maps_to_diary_write_with_envelope_in_entry() {
    let call = palace_pump_mapping::call(&diary_item()).unwrap();
    assert_eq!(call.tool, "mempalace_diary_write");
    assert_eq!(call.arguments.get("agent_name").unwrap().as_str(), Some("nagatha"));
    let entry = call.arguments.get("entry").unwrap().as_str().unwrap();
    assert!(entry.starts_with("Filed the benzene study."));
    assert!(entry.contains("<!-- MOOT-ENVELOPE v1"));
}

// --- generic envelope round-trip ---

#[test]
fn four_noun_envelope_round_trips_every_noun() {
    for item in [drawer_item(), tunnel_item(), fact_item(), diary_item()] {
        let encoded =
            palace_payload_envelope::encode_fields(&item.body, &item.envelope_fields).unwrap();
        let decoded = palace_payload_envelope::decode_fields(&encoded).unwrap();
        assert_eq!(decoded.body, item.body);
        assert_eq!(decoded.fields, item.envelope_fields); // decode(encode(x)) == x
    }
}

#[test]
fn empty_fields_emits_no_envelope() {
    let encoded = palace_payload_envelope::encode_fields("just prose", &BTreeMap::new()).unwrap();
    assert_eq!(encoded, "just prose");
    let decoded = palace_payload_envelope::decode_fields(&encoded).unwrap();
    assert_eq!(decoded.body, "just prose");
    assert!(decoded.fields.is_empty());
}

// --- CROSS-IMPLEMENTATION GUARD (exact canonical bytes, twins of the Swift) ---

const EXPECTED_DRAWER_ENVELOPE: &str = concat!(
    "A study of benzene.\n\n<!-- MOOT-ENVELOPE v1\n",
    "{\"adjectiveBitmap\":5,\"id\":\"drawer_alpha_research_001\",\"lineageID\":\"12345678-1234-1234-1234-1234567890AB\",\"noun\":\"drawer\",\"udcCode\":\"314\"}",
    "\nMOOT-ENVELOPE -->"
);

const EXPECTED_FACT_CLOSET: &str = concat!(
    "\n\n<!-- MOOT-ENVELOPE v1\n",
    "{\"filedAt\":\"2024-03-04T05:06:07.000Z\",\"id\":\"fact_001\",\"noun\":\"kgFact\",\"sourceDrawerID\":\"drawer_alpha_research_001\"}",
    "\nMOOT-ENVELOPE -->"
);

#[test]
fn canonical_bytes_match_shared_vector_drawer() {
    let encoded =
        palace_payload_envelope::encode_fields("A study of benzene.", &drawer_item().envelope_fields)
            .unwrap();
    assert_eq!(encoded, EXPECTED_DRAWER_ENVELOPE);
}

#[test]
fn canonical_bytes_match_shared_vector_fact_closet() {
    let encoded =
        palace_payload_envelope::encode_fields("", &fact_item().envelope_fields).unwrap();
    assert_eq!(encoded, EXPECTED_FACT_CLOSET);
}

// --- drift manifest ---

#[test]
fn drift_manifest_covers_all_four_noun_write_tools() {
    let manifest = palace_drift_detector::expected_manifest();
    let names: Vec<&str> = manifest.iter().map(|t| t.name.as_str()).collect();
    for tool in [
        "mempalace_add_drawer",
        "mempalace_create_tunnel",
        "mempalace_kg_add",
        "mempalace_diary_write",
    ] {
        assert!(names.contains(&tool), "manifest missing {tool}");
    }
    let kg = manifest.iter().find(|t| t.name == "mempalace_kg_add").unwrap();
    assert!(kg.supplied_args.contains("source_closet"));
}

#[test]
fn drift_is_clean_when_all_tools_present() {
    let manifest = palace_drift_detector::expected_manifest();
    let live: Vec<_> = manifest
        .iter()
        .map(|t| palace_drift_detector::PalaceLiveTool {
            name: t.name.clone(),
            required_args: t.required_args.clone(),
        })
        .collect();
    assert!(palace_drift_detector::diff(&live, &manifest).is_empty());
}

// --- per-noun response parsing ---

#[test]
fn parses_per_noun_assigned_id() {
    assert_eq!(palace_response_parsing::assigned_id_key(PalaceNoun::Drawer), "drawer_id");
    assert_eq!(palace_response_parsing::assigned_id_key(PalaceNoun::Tunnel), "id");
    assert_eq!(palace_response_parsing::assigned_id_key(PalaceNoun::KgFact), "triple_id");
    assert_eq!(palace_response_parsing::assigned_id_key(PalaceNoun::DiaryEntry), "entry_id");

    let tunnel_block = vec!["{\"success\":true,\"id\":\"tunnel_alpha_001\"}".to_owned()];
    assert_eq!(
        palace_response_parsing::parse_assigned_id(&tunnel_block, "id"),
        Some("tunnel_alpha_001".to_owned())
    );
    let dupe = vec!["{\"success\":true,\"reason\":\"already_exists\",\"triple_id\":\"t_42\"}".to_owned()];
    assert_eq!(
        palace_response_parsing::parse_assigned_id(&dupe, "triple_id"),
        Some("t_42".to_owned())
    );
    let none = vec!["{\"success\":false}".to_owned()];
    assert_eq!(palace_response_parsing::parse_assigned_id(&none, "entry_id"), None);
}
