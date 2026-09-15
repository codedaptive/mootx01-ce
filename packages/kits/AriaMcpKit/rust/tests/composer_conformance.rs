//! composer_conformance.rs
//!
//! Central conformance suite for the Rust result_composer — ARIA_MCP_INTERFACE
//! §11 grammar. Reads the SAME physical fixture as the Swift port at:
//!   `packages/kits/AriaMcpKit/Tests/Conformance/composer_fixtures.json`
//! (CARGO_MANIFEST_DIR resolves to `packages/kits/AriaMcpKit/rust/`; the
//! fixture is one level up at `../Tests/Conformance/`).
//!
//! Both the text payload and the structuredContent JSON are compared
//! byte-identically to the golden values in the fixture. A discrepancy
//! in either port must be resolved by updating the fixture — both ports
//! change together.
//!
//! Row format (ENC-W6B): uuid · subject · bestSpan · sscFacts · eventTime · score (S1)
//!                       uuid · subject · bestSpan · sscFacts · eventTime (S2)
//! activeAdornments, firstSentence, and ssc (object) are removed from the row schema.

use std::path::Path;

use aria_mcp::result_composer::{
    self,
    BatchGetEntry, CandidateRowData, ControlSignals, EdgeRow,
    FactSearchRow, FactTimelineRow, FederatedSection, FullRecordData, FullRecordTunnel,
    SynthesisData, TabularCellValue, TabularColumnStats, TabularQueryData,
    TabularStatsData, TemporalCapability,
};

// ─── fixture loading ──────────────────────────────────────────────────────────

fn fixture_path() -> std::path::PathBuf {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR")
        .expect("CARGO_MANIFEST_DIR must be set during cargo test");
    Path::new(&manifest_dir)
        .parent()                               // AriaMcpKit/
        .expect("parent of rust/ must exist")
        .join("Tests/Conformance/composer_fixtures.json")
}

fn load_cases() -> Vec<serde_json::Value> {
    let path = fixture_path();
    let data = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read fixture at {}: {}", path.display(), e));
    let root: serde_json::Value = serde_json::from_str(&data)
        .expect("composer_fixtures.json must be valid JSON");
    root["cases"]
        .as_array()
        .expect("fixture must have a 'cases' array")
        .clone()
}

// ─── decoding helpers ─────────────────────────────────────────────────────────

/// Decode one CandidateRowData from a fixture row JSON object.
/// Row format (ENC-W6B): uuid · subject · bestSpan · sscFacts · eventTime · score (S1).
fn decode_candidate_row(json: &serde_json::Value) -> CandidateRowData {
    let id = json["id"].as_str().unwrap_or("").to_string();
    let subject = json["subject"].as_str().map(|s| s.to_string());
    let best_span = json["bestSpan"].as_str().map(|s| s.to_string());
    let ssc_facts = json["sscFacts"].as_str().map(|s| s.to_string());
    let event_time = json["eventTime"].as_str().unwrap_or("").to_string();
    let score = json["score"].as_f64();

    CandidateRowData {
        id,
        subject,
        best_span,
        ssc_facts,
        event_time,
        score,
        room: json["room"].as_str().map(|s| s.to_string()),
        retrieval_source: json["retrievalSource"].as_str().map(|s| s.to_string()),
        distilled: json["distilled"].as_str().map(|s| s.to_string()),
        representation: json["representation"].as_str().map(|s| s.to_string()),
        tier: json["tier"].as_str().map(|s| s.to_string()),
        estate_id: json["estateID"].as_str().map(|s| s.to_string()),
        content: json["content"].as_str().map(|s| s.to_string()),
        extents: json["extents"].as_array().map(|arr| {
            arr.iter().filter_map(|e| e.as_str().map(|s| s.to_string())).collect()
        }),
        exemplars: json["exemplars"].as_array().map(|arr| {
            arr.iter().filter_map(|e| e.as_str().map(|s| s.to_string())).collect()
        }),
    }
}

/// Decode a ControlSignals from a fixture control JSON object.
fn decode_control_signals(json: &serde_json::Value) -> ControlSignals {
    let temporal_capability = if json["temporalCapability"].is_object() {
        let tc = &json["temporalCapability"];
        Some(TemporalCapability {
            mode: tc["mode"].as_str().unwrap_or("").to_string(),
            source: tc["source"].as_str().unwrap_or("").to_string(),
            grab: tc["grab"].as_str().unwrap_or("").to_string(),
            from: tc["from"].as_str().unwrap_or("").to_string(),
            to: tc["to"].as_str().unwrap_or("").to_string(),
            widened_days: tc["widenedDays"].as_i64(),
        })
    } else {
        None
    };

    ControlSignals {
        discrimination: json["discrimination"].as_str().map(|s| s.to_string()),
        temporal_narration: json["temporalNarration"].as_str().map(|s| s.to_string()),
        temporal_capability,
        walk_stage: json["walkStage"].as_str().map(|s| s.to_string()),
        walk_stopped_early: if json["walkStoppedEarly"].is_null() {
            None
        } else {
            json["walkStoppedEarly"].as_bool()
        },
        degraded: json["degraded"].as_bool().unwrap_or(false),
        tie_note: json["tieNote"].as_bool().unwrap_or(false),
        hint: json["hint"].as_str().map(|s| s.to_string()),
    }
}

/// Decode a S6 cell value from a JSON value.
/// null → None; integer → Integer; float → Float; bool → Bool; string → Text.
fn decode_s6_cell(v: &serde_json::Value) -> Option<TabularCellValue> {
    match v {
        serde_json::Value::Null => None,
        serde_json::Value::Bool(b) => Some(TabularCellValue::Bool(*b)),
        serde_json::Value::Number(n) => {
            // Prefer integer if the number is an exact integer.
            if let Some(i) = n.as_i64() {
                // Distinguish integer vs float: if the JSON number has a decimal
                // component (i.e. as_f64 ≠ i as f64, or the original JSON text
                // has a '.'), use Float. Otherwise Integer.
                let as_f = n.as_f64().unwrap_or(0.0);
                if (i as f64) == as_f && !format!("{}", v).contains('.') {
                    Some(TabularCellValue::Integer(i))
                } else {
                    Some(TabularCellValue::Float(as_f))
                }
            } else if let Some(f) = n.as_f64() {
                Some(TabularCellValue::Float(f))
            } else {
                None
            }
        }
        serde_json::Value::String(s) => Some(TabularCellValue::Text(s.clone())),
        _ => None,
    }
}

// ─── per-shape verification ───────────────────────────────────────────────────

fn verify_case(tc: &serde_json::Value) {
    let name = tc["name"].as_str().unwrap_or("unknown");
    let shape = tc["shape"].as_str().unwrap_or("");

    match shape {

        // ── S1 ranked surface ────────────────────────────────────────────────

        "s1" => {
            let rows: Vec<CandidateRowData> = tc["rows"]
                .as_array().unwrap_or(&vec![])
                .iter()
                .map(decode_candidate_row)
                .collect();
            let control = decode_control_signals(&tc["control"]);
            let result = result_composer::render_s1_surface(&rows, &control);
            let expected_text = tc["expectedText"].as_str().unwrap_or("");
            assert_eq!(result.text, expected_text, "[{}] S1 text mismatch", name);
            if !tc["expectedStructured"].is_null() && tc["expectedStructured"].is_object() {
                let got = result.structured.as_ref().expect("S1 must have structured output");
                assert_eq!(got, &tc["expectedStructured"],
                    "[{}] S1 structured mismatch", name);
            }
        }

        // ── S1 empty ─────────────────────────────────────────────────────────

        "s1_empty" => {
            let hint = tc["hint"].as_str();
            let result = result_composer::render_empty_s1(hint);
            let expected_text = tc["expectedText"].as_str().unwrap_or("");
            assert_eq!(result.text, expected_text, "[{}] S1 empty text mismatch", name);
        }

        // ── S1 cap line ───────────────────────────────────────────────────────

        "s1_cap" => {
            let limit = tc["capLimit"].as_u64().unwrap_or(0) as usize;
            let narrowing_arg = tc["narrowingArg"].as_str().unwrap_or("");
            let cap_line = result_composer::render_cap_line(limit, narrowing_arg);
            let expected = tc["expectedCapLine"].as_str().unwrap_or("");
            assert_eq!(cap_line, expected, "[{}] cap line format mismatch", name);
        }

        // ── S2 listing ────────────────────────────────────────────────────────

        "s2_listing" => {
            let wing = tc["wing"].as_str().unwrap_or("");
            let room = tc["room"].as_str().unwrap_or("");
            let rows: Vec<CandidateRowData> = tc["rows"]
                .as_array().unwrap_or(&vec![])
                .iter()
                .map(decode_candidate_row)
                .collect();
            let result = result_composer::render_s2_listing(wing, room, &rows);
            let expected_text = tc["expectedText"].as_str().unwrap_or("");
            assert_eq!(result.text, expected_text, "[{}] S2 listing text mismatch", name);
        }

        // ── S2 batch get ──────────────────────────────────────────────────────

        "s2_batch" => {
            let requested_count = tc["requestedCount"].as_u64().unwrap_or(0) as usize;
            let raw_rows = tc["rows"].as_array().unwrap_or(&vec![]).clone();
            let mut entries: Vec<BatchGetEntry> = Vec::new();
            let mut resolved = 0usize;
            for row_json in &raw_rows {
                let found = row_json["found"].as_bool().unwrap_or(false);
                if found {
                    entries.push(BatchGetEntry::Found(decode_candidate_row(row_json)));
                    resolved += 1;
                } else {
                    entries.push(BatchGetEntry::NotFound(
                        row_json["id"].as_str().unwrap_or("").to_string()
                    ));
                }
            }
            let result = result_composer::render_s2_batch_get(&entries, resolved, requested_count);
            let expected_text = tc["expectedText"].as_str().unwrap_or("");
            assert_eq!(result.text, expected_text, "[{}] S2 batch text mismatch", name);
        }

        // ── S2 empty listing ──────────────────────────────────────────────────

        "s2_listing_empty" => {
            let wing = tc["wing"].as_str().unwrap_or("");
            let room = tc["room"].as_str().unwrap_or("");
            let result = result_composer::render_empty_s2_listing(wing, room);
            let expected_text = tc["expectedText"].as_str().unwrap_or("");
            assert_eq!(result.text, expected_text, "[{}] S2 empty listing text mismatch", name);
        }

        // ── S3 full record ────────────────────────────────────────────────────

        "s3" => {
            let rec = &tc["record"];
            let tunnels: Vec<FullRecordTunnel> = rec["tunnels"]
                .as_array().unwrap_or(&vec![])
                .iter()
                .map(|t| FullRecordTunnel {
                    is_outgoing: t["direction"].as_str().unwrap_or("") == "outgoing",
                    other_id: t["targetID"].as_str().unwrap_or("").to_string(),
                    label: t["label"].as_str().unwrap_or("").to_string(),
                })
                .collect();
            let record = FullRecordData {
                id: rec["id"].as_str().unwrap_or("").to_string(),
                room: rec["room"].as_str().unwrap_or("").to_string(),
                wing: rec["wing"].as_str().unwrap_or("").to_string(),
                subject: rec["subject"].as_str().map(|s| s.to_string()),
                filed_at: rec["filedAt"].as_str().unwrap_or("").to_string(),
                event_time: rec["eventTime"].as_str().unwrap_or("").to_string(),
                state: rec["state"].as_str().unwrap_or("").to_string(),
                trust: rec["trust"].as_str().unwrap_or("").to_string(),
                sensitivity: rec["sensitivity"].as_str().unwrap_or("").to_string(),
                exportability: rec["exportability"].as_str().unwrap_or("").to_string(),
                confirmation: rec["confirmation"].as_str().unwrap_or("").to_string(),
                lineage_id: rec["lineageID"].as_str().unwrap_or("").to_string(),
                tunnels,
                content: rec["content"].as_str().unwrap_or("").to_string(),
            };
            let result = result_composer::render_s3_record(&record);
            let expected_text = tc["expectedText"].as_str().unwrap_or("");
            assert_eq!(result.text, expected_text, "[{}] S3 text mismatch", name);
        }

        // ── S4 fact search ────────────────────────────────────────────────────

        "s4_search" => {
            let facts: Vec<FactSearchRow> = tc["facts"]
                .as_array().unwrap_or(&vec![])
                .iter()
                .map(|f| FactSearchRow {
                    fact_id: f["factID"].as_str().unwrap_or("").to_string(),
                    subject: f["subject"].as_str().unwrap_or("").to_string(),
                    predicate: f["predicate"].as_str().unwrap_or("").to_string(),
                    object: f["object"].as_str().unwrap_or("").to_string(),
                    source_drawer_id: if f["sourceDrawerID"].is_null() {
                        None
                    } else {
                        f["sourceDrawerID"].as_str().map(|s| s.to_string())
                    },
                    filed_at: f["filedAt"].as_str().unwrap_or("").to_string(),
                })
                .collect();
            let result = result_composer::render_s4_fact_search(&facts);
            let expected_text = tc["expectedText"].as_str().unwrap_or("");
            assert_eq!(result.text, expected_text, "[{}] S4 search text mismatch", name);
        }

        // ── S4 fact timeline ──────────────────────────────────────────────────

        "s4_timeline" => {
            let facts: Vec<FactTimelineRow> = tc["facts"]
                .as_array().unwrap_or(&vec![])
                .iter()
                .map(|f| FactTimelineRow {
                    filed_at: f["filedAt"].as_str().unwrap_or("").to_string(),
                    lifecycle: f["lifecycle"].as_str().unwrap_or("").to_string(),
                    fact_id: f["factID"].as_str().unwrap_or("").to_string(),
                    subject: f["subject"].as_str().unwrap_or("").to_string(),
                    predicate: f["predicate"].as_str().unwrap_or("").to_string(),
                    object: f["object"].as_str().unwrap_or("").to_string(),
                    source_drawer_id: if f["sourceDrawerID"].is_null() {
                        None
                    } else {
                        f["sourceDrawerID"].as_str().map(|s| s.to_string())
                    },
                })
                .collect();
            let result = result_composer::render_s4_fact_timeline(&facts);
            let expected_text = tc["expectedText"].as_str().unwrap_or("");
            assert_eq!(result.text, expected_text, "[{}] S4 timeline text mismatch", name);
        }

        // ── S5 edge rows ──────────────────────────────────────────────────────

        "s5" => {
            let direction = tc["direction"].as_str().unwrap_or("outgoing");
            let edges: Vec<EdgeRow> = tc["edges"]
                .as_array().unwrap_or(&vec![])
                .iter()
                .map(|e| EdgeRow {
                    tunnel_id: e["tunnelID"].as_str().unwrap_or("").to_string(),
                    kind_label: e["kindLabel"].as_str().unwrap_or("").to_string(),
                    lifecycle: if e["lifecycle"].is_null() {
                        None
                    } else {
                        e["lifecycle"].as_str().map(|s| s.to_string())
                    },
                    far_endpoint: decode_candidate_row(&e["farEndpoint"]),
                })
                .collect();
            let result = result_composer::render_s5_edges(direction, &edges);
            let expected_text = tc["expectedText"].as_str().unwrap_or("");
            assert_eq!(result.text, expected_text, "[{}] S5 text mismatch", name);
        }

        // ── S6 tabular query ──────────────────────────────────────────────────

        "s6_query" => {
            let columns: Vec<String> = tc["columns"]
                .as_array().unwrap_or(&vec![])
                .iter()
                .filter_map(|c| c.as_str().map(|s| s.to_string()))
                .collect();
            let rows: Vec<Vec<Option<TabularCellValue>>> = tc["rows"]
                .as_array().unwrap_or(&vec![])
                .iter()
                .map(|row| {
                    row.as_array().unwrap_or(&vec![])
                        .iter()
                        .map(decode_s6_cell)
                        .collect()
                })
                .collect();
            let data = TabularQueryData {
                dataset_id: tc["datasetID"].as_str().unwrap_or("").to_string(),
                dataset_name: tc["datasetName"].as_str().unwrap_or("").to_string(),
                returned: tc["returned"].as_u64().unwrap_or(0) as usize,
                total: tc["total"].as_u64().map(|n| n as usize),
                limit: tc["limit"].as_u64().unwrap_or(0) as usize,
                order_column: tc["orderCol"].as_str().unwrap_or("").to_string(),
                order_direction: tc["orderDir"].as_str().unwrap_or("").to_string(),
                columns,
                rows,
            };
            let result = result_composer::render_s6_query(&data);
            let expected_text = tc["expectedText"].as_str().unwrap_or("");
            assert_eq!(result.text, expected_text, "[{}] S6 query text mismatch", name);
        }

        // ── S6 dataset stats ──────────────────────────────────────────────────

        "s6_stats" => {
            let col_stats: Vec<TabularColumnStats> = tc["columns"]
                .as_array().unwrap_or(&vec![])
                .iter()
                .map(|c| TabularColumnStats {
                    name: c["name"].as_str().unwrap_or("").to_string(),
                    count: c["count"].as_u64().unwrap_or(0) as usize,
                    nulls: c["nulls"].as_u64().unwrap_or(0) as usize,
                    distinct: c["distinct"].as_u64().unwrap_or(0) as usize,
                    min: if c["min"].is_null() { None } else { c["min"].as_str().map(|s| s.to_string()) },
                    max: if c["max"].is_null() { None } else { c["max"].as_str().map(|s| s.to_string()) },
                    mean: if c["mean"].is_null() { None } else { c["mean"].as_str().map(|s| s.to_string()) },
                    stddev: if c["stddev"].is_null() { None } else { c["stddev"].as_str().map(|s| s.to_string()) },
                })
                .collect();
            let data = TabularStatsData {
                dataset_id: tc["datasetID"].as_str().unwrap_or("").to_string(),
                dataset_name: tc["datasetName"].as_str().unwrap_or("").to_string(),
                total_rows: tc["totalRows"].as_u64().unwrap_or(0) as usize,
                total_columns: tc["totalCols"].as_u64().unwrap_or(0) as usize,
                columns: col_stats,
            };
            let result = result_composer::render_s6_stats(&data);
            let expected_text = tc["expectedText"].as_str().unwrap_or("");
            assert_eq!(result.text, expected_text, "[{}] S6 stats text mismatch", name);
        }

        // ── Grounded synthesis ────────────────────────────────────────────────

        "synthesis" | "synthesis_whole_estate" => {
            let rows: Vec<CandidateRowData> = tc["rows"]
                .as_array().unwrap_or(&vec![])
                .iter()
                .map(decode_candidate_row)
                .collect();
            let control = decode_control_signals(&tc["control"]);
            let cue_terms: Option<Vec<String>> = if tc["cueTerms"].is_null() {
                None
            } else {
                tc["cueTerms"].as_array().map(|arr| {
                    arr.iter().filter_map(|e| e.as_str().map(|s| s.to_string())).collect()
                })
            };
            let summary = tc["summary"].as_str().unwrap_or("").to_string();
            let data = SynthesisData {
                drawer_count: tc["drawerCount"].as_u64().unwrap_or(0) as usize,
                cue_terms,
                summary,
                rows,
                control,
            };
            let result = result_composer::render_synthesis(&data);
            let expected_text = tc["expectedText"].as_str().unwrap_or("");
            assert_eq!(result.text, expected_text, "[{}] synthesis text mismatch", name);
            // Verify top-level keys if provided.
            if let Some(top_level) = tc.get("expectedStructuredTopLevel") {
                let got = result.structured.as_ref().expect("synthesis must have structured");
                if let Some(exp_cues) = top_level.get("cues") {
                    assert_eq!(got["cues"], *exp_cues, "[{}] synthesis cues mismatch", name);
                }
                if let Some(exp_summary) = top_level.get("summary") {
                    assert_eq!(got["summary"], *exp_summary, "[{}] synthesis summary mismatch", name);
                }
            }
        }

        // ── Vague recall ──────────────────────────────────────────────────────

        "vague" => {
            let summaries: Vec<CandidateRowData> = tc["summaries"]
                .as_array().unwrap_or(&vec![])
                .iter()
                .map(decode_candidate_row)
                .collect();
            let originals: Vec<CandidateRowData> = tc["originals"]
                .as_array().unwrap_or(&vec![])
                .iter()
                .map(decode_candidate_row)
                .collect();
            let control = decode_control_signals(&tc["control"]);
            let result = result_composer::render_vague_recall(&summaries, &originals, &control);
            let expected_text = tc["expectedText"].as_str().unwrap_or("");
            assert_eq!(result.text, expected_text, "[{}] vague recall text mismatch", name);
        }

        // ── Distilled recall ──────────────────────────────────────────────────

        "distilled" => {
            let rows: Vec<CandidateRowData> = tc["rows"]
                .as_array().unwrap_or(&vec![])
                .iter()
                .map(decode_candidate_row)
                .collect();
            let control = decode_control_signals(&tc["control"]);
            let result = result_composer::render_distilled_recall(&rows, &control);
            let expected_text = tc["expectedText"].as_str().unwrap_or("");
            assert_eq!(result.text, expected_text, "[{}] distilled recall text mismatch", name);
        }

        // ── Federated recall ──────────────────────────────────────────────────

        "federated" => {
            let sections: Vec<FederatedSection> = tc["estates"]
                .as_array().unwrap_or(&vec![])
                .iter()
                .map(|e| FederatedSection {
                    estate_name: e["estateName"].as_str().unwrap_or("").to_string(),
                    estate_id: e["estateID"].as_str().unwrap_or("").to_string(),
                    rows: e["rows"]
                        .as_array().unwrap_or(&vec![])
                        .iter()
                        .map(decode_candidate_row)
                        .collect(),
                    control: decode_control_signals(&e["control"]),
                })
                .collect();
            let result = result_composer::render_federated_recall(&sections);
            let expected_text = tc["expectedText"].as_str().unwrap_or("");
            assert_eq!(result.text, expected_text, "[{}] federated recall text mismatch", name);
        }

        // ── Structured parity — forbidden keys ────────────────────────────────

        "s1_structured_parity" => {
            // Verifies absent optional fields are ABSENT (not null) from structured JSON.
            let rows: Vec<CandidateRowData> = tc["rows"]
                .as_array().unwrap_or(&vec![])
                .iter()
                .map(decode_candidate_row)
                .collect();
            let result = result_composer::render_s1_surface(&rows, &ControlSignals::default());
            // Collect forbidden keys as owned Strings to avoid temporary value borrow.
            let empty_arr: Vec<serde_json::Value> = vec![];
            let forbidden_keys: Vec<String> = tc["forbiddenKeys"]
                .as_array().unwrap_or(&empty_arr)
                .iter()
                .filter_map(|k| k.as_str().map(|s| s.to_string()))
                .collect();
            let structured = result.structured.expect("S1 must have structured output");
            // The first result row must not have any of the forbidden keys.
            let first_row = &structured["results"][0];
            for key in &forbidden_keys {
                assert!(
                    first_row.get(key.as_str()).is_none(),
                    "[{}] forbidden key '{}' must be absent from structured row; got: {:?}",
                    name, key, first_row
                );
            }
        }

        other => {
            panic!("[{}] unknown fixture shape '{}' — update composer_conformance.rs", name, other);
        }
    }
}

// ─── test entry point ─────────────────────────────────────────────────────────

/// Drives every fixture case through the Rust result_composer and verifies
/// both the text payload and structuredContent against the golden values in
/// Tests/Conformance/composer_fixtures.json.
///
/// Each shape maps to one arm in `verify_case`. An unknown shape panics
/// with a descriptive message so the fixture and this file stay in sync.
#[test]
fn all_fixture_cases() {
    let cases = load_cases();
    assert!(!cases.is_empty(), "fixture must have at least one case");
    for tc in &cases {
        verify_case(tc);
    }
}

// ─── column-structure gate (ENC-W6B) ─────────────────────────────────────────

/// Pins the six-column S1 and five-column S2 row grammar by position.
///
/// Uses distinct, recognisable literals that contain no U+00B7 separator so
/// that a split on " · " gives exactly the expected field count and the exact
/// value at every index. The score literal "0.8500" is written by hand to pin
/// the %.4f format — the test must not compute it with the same expression
/// the emitter uses.
///
/// A re-added adornment column at index 4 would shift eventTime to index 5
/// and fail both the count assertion and the positional assertion for [4].
#[test]
fn s1_row_has_six_columns_with_event_time_at_index_four() {
    let id         = "11111111-1111-1111-1111-111111111111".to_string();
    let subject    = "SUBJECT-LITERAL".to_string();
    let best_span  = "BESTSPAN-LITERAL".to_string();
    let ssc_facts  = "SSCFACTS-LITERAL".to_string();
    let event_time = "2026-09-14T12:00:00Z".to_string();
    let score      = 0.85_f64;

    let row = CandidateRowData {
        id: id.clone(),
        subject: Some(subject.clone()),
        best_span: Some(best_span.clone()),
        ssc_facts: Some(ssc_facts.clone()),
        event_time: event_time.clone(),
        score: Some(score),
        room: None,
        retrieval_source: None,
        distilled: None,
        representation: None,
        tier: None,
        estate_id: None,
        content: None,
        extents: None,
        exemplars: None,
    };

    // S1: six columns
    let s1 = result_composer::render_s1_row(&row);
    let sep = " \u{00B7} ";
    let s1_fields: Vec<&str> = s1.split(sep).collect();
    assert_eq!(s1_fields.len(), 6,
        "S1 row must have exactly 6 columns; got {}: {}", s1_fields.len(), s1);
    assert_eq!(s1_fields[0], id,        "S1[0] must be the UUID");
    assert_eq!(s1_fields[1], subject,   "S1[1] must be the subject");
    assert_eq!(s1_fields[2], best_span, "S1[2] must be bestSpan");
    assert_eq!(s1_fields[3], ssc_facts, "S1[3] must be sscFacts");
    assert_eq!(s1_fields[4], event_time, "S1[4] must be eventTime (not an adornment)");
    assert_eq!(s1_fields[5], "0.8500",  "S1[5] must be score formatted to %.4f");

    // S2: five columns, no score
    let s2 = result_composer::render_s2_row(&row);
    let s2_fields: Vec<&str> = s2.split(sep).collect();
    assert_eq!(s2_fields.len(), 5,
        "S2 row must have exactly 5 columns; got {}: {}", s2_fields.len(), s2);
    assert_eq!(s2_fields[0], id,         "S2[0] must be the UUID");
    assert_eq!(s2_fields[1], subject,    "S2[1] must be the subject");
    assert_eq!(s2_fields[2], best_span,  "S2[2] must be bestSpan");
    assert_eq!(s2_fields[3], ssc_facts,  "S2[3] must be sscFacts");
    assert_eq!(s2_fields[4], event_time, "S2[4] must be eventTime (not an adornment)");
}
