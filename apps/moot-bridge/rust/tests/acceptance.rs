//! acceptance.rs — the LIVE end-to-end acceptance proof for the Rust bridge twin.
//!
//! Drives the built `moot-bridge` binary over stdio against two SCRATCH backends
//! (MemPalace + mootx01) and asserts the same acceptance sequence as the Swift
//! `BridgeAcceptanceTests.swift`:
//!   initialize → tools/list (primary's tools + bridge tools present) → write
//!   (verify it landed in BOTH backends via each one's own read tool) → read
//!   (primary's answer) → bridge_set_primary to the other backend → read again
//!   (now the other backend answers) → bridge_status shows the swap.
//!
//! SAFETY: scratch backends only — temp palace + temp MOOTX01_DATA_DIR, torn
//! down per run. The test is SKIPPED (passes trivially) when the `mempalace-mcp`
//! / `mootx01` binaries are not on PATH, so the unit suite still runs everywhere.

use serde_json::Value;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

// No machine-specific path constant — local bin dir is derived from $HOME at
// runtime so the test is portable across developer machines and CI.

#[test]
fn full_bridge_session() {
    let Some(mempalace_mcp) = which("mempalace-mcp") else {
        eprintln!("skip: mempalace-mcp not on PATH");
        return;
    };
    let Some(mootx01_bin) = which("mootx01") else {
        eprintln!("skip: mootx01 not on PATH");
        return;
    };

    // --- Scratch backends + config -----------------------------------------
    let tmp = scratch_dir();
    let mp_dir = tmp.join("mp");
    let moot_dir = tmp.join("moot");
    std::fs::create_dir_all(&mp_dir).unwrap();
    std::fs::create_dir_all(&moot_dir).unwrap();
    let config_path = tmp.join("config.json");
    std::fs::write(&config_path, config_json(&mp_dir, &moot_dir)).unwrap();

    let token = format!("ACC_TOKEN_R_{}", std::process::id());

    // --- Drive the bridge over stdio -----------------------------------------
    let requests = vec![
        r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"acc","version":"0"}}}"#.to_string(),
        r#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#.to_string(),
        format!(r#"{{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{{"name":"mempalace_add_drawer","arguments":{{"wing":"scratch","room":"notes","content":"{token} the quick brown fox"}}}}}}"#),
        format!(r#"{{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{{"name":"mempalace_search","arguments":{{"query":"{token}"}}}}}}"#),
        r#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"bridge_set_primary","arguments":{"backend":"mootx01"}}}"#.to_string(),
        format!(r#"{{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{{"name":"moot_memory_search","arguments":{{"query":"{token}"}}}}}}"#),
        r#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"bridge_status","arguments":{}}}"#.to_string(),
    ];
    let responses = run_bridge_binary(&config_path, &requests);
    let by_id = index_by_id(&responses);

    // --- id2: tools/list carries primary's tools + the two bridge tools ------
    let tool_names = tool_list_names(by_id.get(&2).expect("id2 response"));
    assert!(tool_names.iter().any(|t| t == "mempalace_search"));
    assert!(tool_names.iter().any(|t| t == "mempalace_add_drawer"));
    assert!(tool_names.iter().any(|t| t == "bridge_set_primary"));
    assert!(tool_names.iter().any(|t| t == "bridge_status"));

    // --- id3: write succeeded on the primary -------------------------------
    let write_text = result_text(by_id.get(&3).expect("id3 response"));
    assert!(write_text.contains("drawer_id"), "write result: {write_text}");

    // --- id4: read from primary (MemPalace) finds the token ----------------
    let primary_read = result_text(by_id.get(&4).expect("id4 response"));
    assert!(primary_read.contains(&token));
    assert!(primary_read.contains("results")); // MemPalace jsonObjects shape

    // --- id5: bridge_set_primary confirms the swap ---------------------------
    let swap_text = result_text(by_id.get(&5).expect("id5 response"));
    assert!(swap_text.contains("mootx01"));

    // --- id6: read AFTER swap is answered by mootx01 -----------------------
    let secondary_read = result_text(by_id.get(&6).expect("id6 response"));
    assert!(secondary_read.contains(&token));
    assert!(secondary_read.contains("found")); // mootText shape proves mootx01
    assert!(secondary_read.contains("[scratch/notes]"));

    // --- id7: bridge_status reflects the swap --------------------------------
    let status_text = result_text(by_id.get(&7).expect("id7 response"));
    assert!(status_text.contains("primary:   mootx01"));
    assert!(status_text.contains("secondary: mempalace"));

    // --- The write landed in BOTH backends (each via its own read) ---------
    assert!(
        direct_has_token(&mempalace_mcp, &["--palace", mp_dir.to_str().unwrap()], &[],
                         "mempalace_search", &token),
        "write must have landed in MemPalace"
    );
    assert!(
        direct_has_token(&mootx01_bin, &["serve"],
                         &[("MOOTX01_DATA_DIR", moot_dir.to_str().unwrap())],
                         "moot_memory_search", &token),
        "write must have fanned out to mootx01"
    );

    let _ = std::fs::remove_dir_all(&tmp);
}

// MARK: - Harness

fn config_json(mp_dir: &PathBuf, moot_dir: &PathBuf) -> String {
    format!(
        r#"{{
  "backendA": {{
    "name": "mempalace",
    "command": "mempalace-mcp --palace {mp}",
    "verbMap": {{
      "write": "mempalace_add_drawer",
      "query": "mempalace_search",
      "constantArgs": {{ "wing": "scratch", "room": "notes" }},
      "resultFormat": {{ "kind": "jsonObjects", "contentKey": "text" }}
    }}
  }},
  "backendB": {{
    "name": "mootx01",
    "command": "MOOTX01_DATA_DIR={moot} mootx01 serve",
    "verbMap": {{
      "write": "moot_file_memory",
      "query": "moot_memory_search",
      "constantArgs": {{ "location": "scratch/notes" }},
      "resultFormat": {{ "kind": "mootText" }}
    }}
  }},
  "primary": "mempalace"
}}"#,
        mp = mp_dir.to_str().unwrap(),
        moot = moot_dir.to_str().unwrap()
    )
}

/// Runs the built moot-bridge binary, feeds it the requests, returns parsed lines.
fn run_bridge_binary(config_path: &PathBuf, requests: &[String]) -> Vec<Value> {
    let bin = bridge_binary_path();
    // Prepend $HOME/.local/bin so the bridge can launch mempalace-mcp / mootx01
    // even when PATH inside the test runner doesn't carry it.
    let local_bin = std::env::var("HOME")
        .map(|h| format!("{h}/.local/bin"))
        .unwrap_or_default();
    let path = format!("{local_bin}:{}", std::env::var("PATH").unwrap_or_default());
    let mut child = Command::new(bin)
        .args(["--config", config_path.to_str().unwrap()])
        .env("PATH", path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn moot-bridge");

    let mut stdin = child.stdin.take().unwrap();
    let payload = requests.join("\n") + "\n";
    stdin.write_all(payload.as_bytes()).unwrap();
    stdin.flush().unwrap();
    // Brief settle so the synchronous mirror fan-out completes before EOF.
    std::thread::sleep(Duration::from_millis(800));
    drop(stdin); // EOF → bridge shuts down

    let mut out = String::new();
    child.stdout.take().unwrap().read_to_string(&mut out).unwrap();
    let _ = child.wait();

    out.lines()
        .filter(|l| !l.trim().is_empty())
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect()
}

fn index_by_id(responses: &[Value]) -> HashMap<i64, Value> {
    let mut map = HashMap::new();
    for r in responses {
        if let Some(id) = r.get("id").and_then(|v| v.as_i64()) {
            map.insert(id, r.clone());
        }
    }
    map
}

fn tool_list_names(response: &Value) -> Vec<String> {
    response["result"]["tools"]
        .as_array()
        .map(|tools| {
            tools
                .iter()
                .filter_map(|t| t["name"].as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default()
}

fn result_text(response: &Value) -> String {
    response["result"]["content"]
        .as_array()
        .map(|blocks| {
            blocks
                .iter()
                .filter_map(|b| b["text"].as_str())
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

/// Drives a backend directly (not through the bridge): initialize + one search.
/// Returns true when the token appears in the backend's own read result.
fn direct_has_token(
    command: &str,
    args: &[&str],
    env: &[(&str, &str)],
    query_tool: &str,
    token: &str,
) -> bool {
    let mut cmd = Command::new(command);
    cmd.args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (k, v) in env {
        cmd.env(k, v);
    }
    let mut child = cmd.spawn().expect("spawn backend for direct read");
    let mut stdin = child.stdin.take().unwrap();
    let lines = format!(
        "{}\n{}\n",
        r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"v","version":"0"}}}"#,
        format!(
            r#"{{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{{"name":"{query_tool}","arguments":{{"query":"{token}"}}}}}}"#
        )
    );
    stdin.write_all(lines.as_bytes()).unwrap();
    stdin.flush().unwrap();
    std::thread::sleep(Duration::from_millis(500));
    drop(stdin);
    let mut out = String::new();
    child.stdout.take().unwrap().read_to_string(&mut out).unwrap();
    let _ = child.wait();
    out.contains(token)
}

fn bridge_binary_path() -> PathBuf {
    // CARGO_BIN_EXE_moot-bridge is set by cargo for integration tests targeting a
    // binary; fall back to the conventional debug path if absent.
    if let Ok(p) = std::env::var("CARGO_BIN_EXE_moot-bridge") {
        return PathBuf::from(p);
    }
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("target/debug/moot-bridge")
}

fn scratch_dir() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("moot-bridge-rs-acc-{}", uuid_like()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A unique-enough suffix without pulling in the uuid crate for a test path.
fn uuid_like() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap();
    format!("{}-{}", std::process::id(), now.as_nanos())
}

/// Resolves a binary on the standard local bin dir (derived from $HOME) or
/// PATH.  HOME-relative expansion avoids machine-specific absolute paths while
/// still finding binaries installed by standard packaging helpers.
fn which(name: &str) -> Option<String> {
    let local_bin = std::env::var("HOME")
        .map(|h| format!("{h}/.local/bin"))
        .unwrap_or_default();
    let mut dirs = if local_bin.is_empty() {
        vec![]
    } else {
        vec![local_bin]
    };
    if let Ok(path) = std::env::var("PATH") {
        dirs.extend(path.split(':').map(String::from));
    }
    for d in dirs {
        let p = format!("{d}/{name}");
        if std::path::Path::new(&p).exists() {
            return Some(p);
        }
    }
    None
}
