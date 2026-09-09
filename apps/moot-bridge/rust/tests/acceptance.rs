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
//! SAFETY: scratch backends only — temp palace + a transient mootx01 estate
//! selected with `--db <dir>/<name>`, torn down per run.
//!
//! The test is SKIPPED (passes trivially) when `mempalace-mcp` is not on the
//! search path, and when no `mootx01` on it can serve `--db <dir>/<name>`.
//! Presence is not the question: a `mootx01` predating the estate catalog
//! reads that value as a bare estate NAME, serves something else, and the
//! post-swap read comes back empty — a red suite on any machine carrying an
//! older install, where the honest outcome is a skip. Each candidate is asked
//! what it can do, in search-path order, so a freshly built binary ahead on
//! PATH wins over an older install behind it.

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
    let Some(mootx01_bin) = which_capable("mootx01", serve_accepts_directory_and_name) else {
        match first_incapable_mootx01() {
            Some((path, version)) => eprintln!(
                "skip: mootx01 at {path} is {version}, which predates `--db <dir>/<name>` — \
                 live acceptance needs a catalog-era build ahead of it on PATH"
            ),
            None => eprintln!("skip: mootx01 not on PATH"),
        }
        return;
    };

    // --- Scratch backends + config -----------------------------------------
    let tmp = scratch_dir();
    let mp_dir = tmp.join("mp");
    let moot_dir = tmp.join("moot");
    std::fs::create_dir_all(&mp_dir).unwrap();
    std::fs::create_dir_all(&moot_dir).unwrap();
    let config_path = tmp.join("config.json");
    std::fs::write(&config_path, config_json(&mp_dir, &moot_dir, &mempalace_mcp, &mootx01_bin)).unwrap();

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
    // mootText shape proves mootx01 answered (not MemPalace JSON): the
    // "found N candidate ..." header and the one-line-per-hit rows.
    assert!(secondary_read.contains("found 1 candidate memory")); // mootText shape proves mootx01

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
        direct_has_token(&mootx01_bin, &["serve", "--db", &format!("{}/bridge", moot_dir.display())],
                         &[],
                         "moot_memory_search", &token),
        "write must have fanned out to mootx01"
    );

    // ...and landed at the location the secondary's `constantArgs` names. The
    // estate map is what proves it. The S1 search row is `uuid · subject ·
    // bestSpan · sscFacts · eventTime · score` (ARIA_MCP_SPEC §8.3) and
    // carries no location at all, so a `[scratch/notes]` substring of the
    // search reply asserts nothing; the map lists the room and its count.
    // After the M5-2 fix, constantArgs sends wing="scratch" + location="notes"
    // (a room called "notes" inside the wing "scratch"). The estate map renders
    // this as "scratch/" (wing header) + "    notes: 1" (room count line).
    // A bare "location": "scratch/notes" would produce room "scratch/notes"
    // under the default "Agentic Memory" wing — the bug this assertion detects.
    let estate_map = direct_tool_output(
        &mootx01_bin,
        &["serve", "--db", &format!("{}/bridge", moot_dir.display())],
        "moot_estate_map",
        "{}",
    );
    assert!(
        estate_map.contains("scratch/"),
        "mirrored write must land in wing 'scratch': {estate_map}"
    );
    assert!(
        estate_map.contains("notes: 1"),
        "mirrored write must land in room 'notes': {estate_map}"
    );

    let _ = std::fs::remove_dir_all(&tmp);
}

// MARK: - Harness

fn config_json(mp_dir: &PathBuf, moot_dir: &PathBuf, mempalace_bin: &str, mootx01_bin_path: &str) -> String {
    format!(
        r#"{{
  "backendA": {{
    "name": "mempalace",
    "command": "{mp_bin} --palace {mp}",
    "verbMap": {{
      "write": "mempalace_add_drawer",
      "query": "mempalace_search",
      "constantArgs": {{ "wing": "scratch", "room": "notes" }},
      "resultFormat": {{ "kind": "jsonObjects", "contentKey": "text" }}
    }}
  }},
  "backendB": {{
    "name": "mootx01",
    "command": "{moot_bin} serve --db {moot}/bridge",
    "verbMap": {{
      "write": "moot_file_memory",
      "query": "moot_memory_search",
      "subjectArg": "subject",
      "constantArgs": {{ "wing": "scratch", "location": "notes" }},
      "resultFormat": {{ "kind": "mootText" }}
    }}
  }},
  "primary": "mempalace"
}}"#,
        mp = mp_dir.to_str().unwrap(),
        moot = moot_dir.to_str().unwrap(),
        mp_bin = mempalace_bin,
        moot_bin = mootx01_bin_path
    )
}

/// Runs the built moot-bridge binary, feeds it the requests, returns parsed lines.
fn run_bridge_binary(config_path: &PathBuf, requests: &[String]) -> Vec<Value> {
    let bin = bridge_binary_path();
    // The child searches PATH first and $HOME/.local/bin as a FALLBACK — the
    // same order `binary_search_path` uses, so the binary the capability probe
    // approved is the binary the bridge launches. With the local bin dir
    // first, a freshly built mootx01 ahead on PATH was probed and then not
    // used, and the post-swap read came back empty against the older install.
    let path = binary_search_path().join(":");
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

/// Drives a backend directly with one argument-free tool call and returns its
/// raw stdout. `arguments_json` is the tool's `arguments` object verbatim.
fn direct_tool_output(command: &str, args: &[&str], tool: &str, arguments_json: &str) -> String {
    let mut child = Command::new(command)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn backend for direct tool call");
    let mut stdin = child.stdin.take().unwrap();
    let lines = format!(
        "{}\n{}\n",
        r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"v","version":"0"}}}"#,
        format!(
            r#"{{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{{"name":"{tool}","arguments":{arguments_json}}}}}"#
        )
    );
    stdin.write_all(lines.as_bytes()).unwrap();
    stdin.flush().unwrap();
    std::thread::sleep(Duration::from_millis(500));
    drop(stdin);
    let mut out = String::new();
    child.stdout.take().unwrap().read_to_string(&mut out).unwrap();
    let _ = child.wait();
    out
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

/// Every place a backend binary is looked for, in the order the bridge child
/// searches: PATH first, then the standard local bin dir derived from $HOME.
/// PATH leads so a freshly built binary placed ahead of an older install is
/// the one exercised — the same order `run_bridge_binary` gives the child, so
/// the probe and the run agree. HOME-relative expansion avoids
/// machine-specific absolute paths while still finding binaries installed by
/// standard packaging helpers.
fn binary_search_path() -> Vec<String> {
    let mut dirs: Vec<String> = std::env::var("PATH")
        .map(|p| p.split(':').map(String::from).collect())
        .unwrap_or_default();
    if let Ok(home) = std::env::var("HOME") {
        dirs.push(format!("{home}/.local/bin"));
    }
    dirs
}

/// Resolves a binary on the search path.
fn which(name: &str) -> Option<String> {
    binary_search_path()
        .into_iter()
        .map(|d| format!("{d}/{name}"))
        .find(|p| std::path::Path::new(p).exists())
}

/// The first binary on the search path that satisfies `capability`.
fn which_capable(name: &str, capability: fn(&str) -> bool) -> Option<String> {
    binary_search_path()
        .into_iter()
        .map(|d| format!("{d}/{name}"))
        .find(|p| std::path::Path::new(p).exists() && capability(p))
}

/// Runs `<binary> <arguments>` and returns its combined stdout + stderr, or
/// None when it could not be run. Used only to interrogate a candidate binary
/// about itself: no estate is opened and nothing is written.
fn probe_output(binary: &str, arguments: &[&str]) -> Option<String> {
    let out = Command::new(binary).args(arguments).output().ok()?;
    let mut text = String::from_utf8_lossy(&out.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&out.stderr));
    Some(text)
}

/// True when this `mootx01` documents the catalog-era transient selector in
/// `serve --help`, which is the flag shape the acceptance config uses. A
/// pre-catalog build documents `--db <db>` as "Named estate to serve" and has
/// no way to attach `<dir>/<name>`.
fn serve_accepts_directory_and_name(binary: &str) -> bool {
    probe_output(binary, &["serve", "--help"])
        .map(|help| help.contains("<dir>/<name>"))
        .unwrap_or(false)
}

/// The first mootx01 on the search path that is NOT catalog-era, with its
/// version, so the skip line names the binary the operator has to replace.
fn first_incapable_mootx01() -> Option<(String, String)> {
    for d in binary_search_path() {
        let p = format!("{d}/mootx01");
        if !std::path::Path::new(&p).exists() {
            continue;
        }
        if serve_accepts_directory_and_name(&p) {
            return None;
        }
        let version = probe_output(&p, &["--version"])
            .unwrap_or_default()
            .trim()
            .to_string();
        let version = if version.is_empty() { "version unknown".to_string() } else { version };
        return Some((p, version));
    }
    None
}
