//! unit.rs — pure-logic tests for the Rust bridge twin: config decode, classify,
//! translate, stats. Mirrors the Swift `BridgeUnitTests.swift` assertions so the
//! two verticals are proven on the same fixtures and behaviour.

use moot_bridge::config::{ConfigError, BridgeConfig, ResultFormat, VerbMap};
use moot_bridge::bridge::{BridgeCallType, BridgeServer};
use serde_json::{json, Value};
use std::collections::BTreeMap;

// MARK: - Config

#[test]
fn minimal_config_decodes() {
    let json = r#"
    {
      "backendA": {
        "name": "mempalace",
        "command": "mempalace-mcp --palace /tmp/x",
        "verbMap": {
          "write": "mempalace_add_drawer",
          "query": "mempalace_search",
          "constantArgs": { "wing": "scratch", "room": "notes" },
          "resultFormat": { "kind": "jsonObjects", "contentKey": "text" }
        }
      },
      "backendB": {
        "name": "mootx01",
        "command": "mootx01 serve",
        "verbMap": {
          "write": "moot_file_memory",
          "query": "moot_memory_search",
          "constantArgs": { "location": "scratch/notes" },
          "resultFormat": { "kind": "mootText" }
        }
      },
      "primary": "mempalace"
    }"#;
    let config = BridgeConfig::parse_str(json).expect("config decodes");
    assert_eq!(config.backend_a.name, "mempalace");
    assert_eq!(config.backend_b.name, "mootx01");
    assert_eq!(config.primary, "mempalace");
    assert_eq!(config.backend_a.verb_map.write, "mempalace_add_drawer");
    assert_eq!(
        config.backend_a.verb_map.constant_args.get("wing"),
        Some(&"scratch".to_string())
    );
    assert_eq!(
        config.backend_a.verb_map.result_format,
        ResultFormat::JsonObjects { id_key: None, content_key: "text".to_string() }
    );
    assert_eq!(config.backend_b.verb_map.result_format, ResultFormat::MootText);
}

#[test]
fn unknown_primary_rejected() {
    let json = r#"
    {
      "backendA": { "name": "a", "command": "x", "verbMap": { "write": "w", "query": "q" } },
      "backendB": { "name": "b", "command": "y", "verbMap": { "write": "w", "query": "q" } },
      "primary": "c"
    }"#;
    assert_eq!(
        BridgeConfig::parse_str(json),
        Err(ConfigError::UnknownPrimary("c".to_string()))
    );
}

#[test]
fn missing_write_verb_rejected() {
    let json = r#"
    {
      "backendA": { "name": "a", "command": "x", "verbMap": { "query": "q" } },
      "backendB": { "name": "b", "command": "y", "verbMap": { "write": "w", "query": "q" } },
      "primary": "a"
    }"#;
    assert_eq!(
        BridgeConfig::parse_str(json),
        Err(ConfigError::MissingField("verbMap.write".to_string()))
    );
}

// MARK: - Classify

fn moot_verbs() -> VerbMap {
    serde_json::from_str(r#"{ "write": "moot_file_memory", "query": "moot_memory_search" }"#).unwrap()
}

#[test]
fn write_tool_classifies_write() {
    assert_eq!(
        BridgeServer::classify_call("moot_file_memory", &moot_verbs()),
        Some(BridgeCallType::Write)
    );
}

#[test]
fn query_tool_classifies_query() {
    assert_eq!(
        BridgeServer::classify_call("moot_memory_search", &moot_verbs()),
        Some(BridgeCallType::Query)
    );
}

#[test]
fn unknown_tool_is_unclassifiable() {
    assert_eq!(BridgeServer::classify_call("moot_lens_drift", &moot_verbs()), None);
}

// MARK: - Translate

fn mempalace_verbs() -> VerbMap {
    let mut constant = BTreeMap::new();
    constant.insert("wing".to_string(), "scratch".to_string());
    constant.insert("room".to_string(), "notes".to_string());
    VerbMap {
        write: "mempalace_add_drawer".to_string(),
        query: "mempalace_search".to_string(),
        content_arg: "content".to_string(),
        query_arg: "query".to_string(),
        constant_args: constant,
        result_format: ResultFormat::JsonObjects { id_key: None, content_key: "text".to_string() },
    }
}

fn mootx01_verbs() -> VerbMap {
    let mut constant = BTreeMap::new();
    constant.insert("location".to_string(), "scratch/notes".to_string());
    VerbMap {
        write: "moot_file_memory".to_string(),
        query: "moot_memory_search".to_string(),
        content_arg: "content".to_string(),
        query_arg: "query".to_string(),
        constant_args: constant,
        result_format: ResultFormat::MootText,
    }
}

#[test]
fn write_translates_to_secondary_tool() {
    let client_call: Value = serde_json::from_str(
        r#"{"jsonrpc":"2.0","id":42,"method":"tools/call",
            "params":{"name":"mempalace_add_drawer",
                      "arguments":{"wing":"scratch","room":"notes","content":"hello bridge"}}}"#,
    )
    .unwrap();
    let out_str = BridgeServer::translate_call(
        Some(&client_call),
        BridgeCallType::Write,
        &mempalace_verbs(),
        &mootx01_verbs(),
        7,
    )
    .expect("translate yields a call");
    let out: Value = serde_json::from_str(&out_str).unwrap();
    // Fresh, disjoint id — never the client's 42.
    assert_eq!(out["id"], json!(7));
    assert_eq!(out["params"]["name"], json!("moot_file_memory"));
    assert_eq!(out["params"]["arguments"]["content"], json!("hello bridge"));
    assert_eq!(out["params"]["arguments"]["location"], json!("scratch/notes"));
    // The primary-only constantArgs (wing/room) are NOT leaked to mootx01.
    assert!(out["params"]["arguments"].get("wing").is_none());
    assert!(out["params"]["arguments"].get("room").is_none());
}

#[test]
fn write_translates_reverse_direction() {
    let client_call: Value = serde_json::from_str(
        r#"{"jsonrpc":"2.0","id":1,"method":"tools/call",
            "params":{"name":"moot_file_memory",
                      "arguments":{"content":"reverse content","location":"scratch/notes"}}}"#,
    )
    .unwrap();
    let out_str = BridgeServer::translate_call(
        Some(&client_call),
        BridgeCallType::Write,
        &mootx01_verbs(),
        &mempalace_verbs(),
        3,
    )
    .expect("translate yields a call");
    let out: Value = serde_json::from_str(&out_str).unwrap();
    assert_eq!(out["params"]["name"], json!("mempalace_add_drawer"));
    assert_eq!(out["params"]["arguments"]["content"], json!("reverse content"));
    assert_eq!(out["params"]["arguments"]["wing"], json!("scratch"));
    assert_eq!(out["params"]["arguments"]["room"], json!("notes"));
}

#[test]
fn write_without_content_returns_none() {
    let client_call: Value = serde_json::from_str(
        r#"{"jsonrpc":"2.0","id":1,"method":"tools/call",
            "params":{"name":"mempalace_add_drawer","arguments":{"wing":"scratch","room":"notes"}}}"#,
    )
    .unwrap();
    assert!(BridgeServer::translate_call(
        Some(&client_call),
        BridgeCallType::Write,
        &mempalace_verbs(),
        &mootx01_verbs(),
        1,
    )
    .is_none());
}

// MARK: - Bridge tool schemas

#[test]
fn set_primary_schema_shape() {
    let schema = BridgeServer::bridge_set_primary_schema();
    assert_eq!(schema["name"], json!("bridge_set_primary"));
    assert_eq!(schema["inputSchema"]["required"], json!(["backend"]));
}

#[test]
fn status_schema_shape() {
    let schema = BridgeServer::bridge_status_schema();
    assert_eq!(schema["name"], json!("bridge_status"));
    assert_eq!(schema["inputSchema"]["type"], json!("object"));
}

// MARK: - Stats

#[test]
fn latency_and_failure_accumulate() {
    use moot_bridge::stats::BridgeStats;
    let mut stats = BridgeStats::new();
    stats.record_latency(0.010, "mempalace.tools/call");
    stats.record_latency(0.020, "mempalace.tools/call");
    stats.record_latency(0.005, "mootx01.tools/call.mirror");
    stats.record_secondary_failure();
    let snap = stats.snapshot();
    // BTreeMap sorts: mempalace.* before mootx01.*
    assert_eq!(snap.series.len(), 2);
    assert_eq!(snap.series[0].label, "mempalace.tools/call");
    assert_eq!(snap.series[0].total_count, 2);
    assert!((snap.series[0].mean - 0.015).abs() < 1e-9);
    assert_eq!(snap.secondary_failure_count, 1);
}
