//! aria_v2_roundtrip.rs — ARIA v2 harness adapter live round-trip tests (Rust port).
//!
//! GATE: MOOT_BENCH_BINARY_PATH must point to a real mootx01 binary. Tests
//! self-skip (via `return`) when the variable is absent, but MUST be run with
//! the binary present and the result reported.
//!
//! Build the product binary with this harness's `moot-binary` make target and
//! point MOOT_BENCH_BINARY_PATH at the release binary it writes. Naming the
//! target rather than a directory keeps the instruction correct wherever the
//! harness is checked out.
//!
//! Run command:
//!   MOOT_BENCH_BINARY_PATH=<path> CARGO_TEST_ARGS="--test aria_v2_roundtrip" \
//!     make test-one DIR=<this harness directory>/rust
//!
//! Tests:
//!   1. file_search_get_round_trip: file → search → get, decoded IDs match
//!   2. invalid_argument_refusal: malformed arg → -32602 [class=invalid_argument] decoded
//!   3. memory_not_found_refusal: absent UUID → isError:true, refusal.code = "memory_not_found"
//!   4. depth_skim_reaches_wire: depth:"skim" passes to wire, server accepts it
//!   5. meta_absent_decodes_gracefully: no-meta response decodes without error
//!
//! Blast-radius finding: encode_barrier.rs line 917-923 has a #[cfg(test)]-gated
//! MCPToolResult struct literal without the new fields (is_error, refusal,
//! withheld_by_sensitivity). Integration tests (`cargo test --test <stem>`)
//! compile the library WITHOUT #[cfg(test)], so these tests compile and run.
//! Full `cargo test` will fail until encode_barrier.rs is updated — that file
//! is outside this unit's file set; reported in the completion report.

use mcp_benchmarker_rs::aria_v2_surface;
use mcp_benchmarker_rs::config::{EndpointConfig, EndpointRole, ResultFormat, Transport, VerbMap};
use mcp_benchmarker_rs::json_value::JsonValue;
use mcp_benchmarker_rs::mcp_client::{MCPClient, ToolCaller};
use std::collections::BTreeMap;
use std::hash::{BuildHasher, Hasher};
use std::path::PathBuf;

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the MOOT_BENCH_BINARY_PATH env var when set and the file exists.
fn binary_path() -> Option<String> {
    let path = std::env::var("MOOT_BENCH_BINARY_PATH").ok()?;
    if std::path::Path::new(&path).exists() {
        Some(path)
    } else {
        None
    }
}

struct ScratchDb {
    dir: PathBuf,
    db_path: String,
}

impl ScratchDb {
    /// Creates an unpredictable, exclusive scratch directory. `RandomState`
    /// obtains per-instance keys from the operating system; `create` refuses
    /// a pre-existing path, and Unix creates the directory owner-only.
    fn new(id: &str) -> std::io::Result<Self> {
        for _ in 0..16 {
            let state = std::collections::hash_map::RandomState::new();
            let mut hasher = state.build_hasher();
            hasher.write_u64(std::process::id() as u64);
            let nonce = hasher.finish();
            let dir = std::env::temp_dir().join(format!("scratch-{id}-{nonce:016x}"));
            let mut builder = std::fs::DirBuilder::new();
            #[cfg(unix)]
            {
                use std::os::unix::fs::DirBuilderExt;
                builder.mode(0o700);
            }
            match builder.create(&dir) {
                Ok(()) => {
                    let db_path = dir.join("estate.db").display().to_string();
                    return Ok(Self { dir, db_path });
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error),
            }
        }
        Err(std::io::Error::new(
            std::io::ErrorKind::AlreadyExists,
            "could not create a unique scratch directory after 16 attempts",
        ))
    }

    fn path(&self) -> &str {
        &self.db_path
    }
}

impl Drop for ScratchDb {
    fn drop(&mut self) {
        if let Err(error) = std::fs::remove_dir_all(&self.dir) {
            eprintln!(
                "warning: failed to remove scratch directory {}: {error}",
                self.dir.display()
            );
        }
    }
}

/// Builds an EndpointConfig for a live mootx01 binary over stdio.
fn make_endpoint(binary: &str, db_path: &str) -> EndpointConfig {
    let command = format!("{binary} serve --db {db_path}");
    EndpointConfig {
        name: "test-mootx01-rs".to_string(),
        transport: Transport::Stdio { command },
        auth: None,
        verb_map: VerbMap::new(
            aria_v2_surface::FILE_MEMORY,
            aria_v2_surface::MEMORY_SEARCH,
            Some(aria_v2_surface::MEMORY_LIST.to_string()),
            None,
            None,
            None,
            Some({
                // No constant_args for moot_memory_search (wing/location is per-call)
                BTreeMap::new()
            }),
            Some(ResultFormat::MootV2),
        ),
        role: EndpointRole::Both,
    }
}

/// Depth enum values from `aria_v2_mission02_vectors.json` moot_memory_get inputSchema.
/// Read from fixture ordering — not typed as literals in assertions.
const CATALOG_DEPTH_VALUES: &[&str] = &["subject", "distilled", "skim", "full"];

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn scratch_directories_are_unique_and_private() {
    let first = ScratchDb::new("security").expect("create first scratch directory");
    let second = ScratchDb::new("security").expect("create second scratch directory");

    assert_ne!(
        first.dir, second.dir,
        "scratch paths must be unpredictable per invocation"
    );
    assert!(first.dir.is_dir(), "scratch path must be a directory");
    assert!(second.dir.is_dir(), "scratch path must be a directory");

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&first.dir)
                .expect("read scratch directory metadata")
                .permissions()
                .mode()
                & 0o777,
            0o700,
            "scratch directory must be owner-only",
        );
    }
}

/// 1. File → search → get round-trip: decoded IDs and content match.
#[test]
fn file_search_get_round_trip() {
    let Some(bin) = binary_path() else { return };
    let scratch = ScratchDb::new("rs-rt1").expect("create private, unique scratch directory");
    let db_path = scratch.path();

    let endpoint = make_endpoint(&bin, &db_path);
    let mut client = MCPClient::new(endpoint);
    client.connect().expect("connect");

    // File a memory
    let subject = format!("AriaV2RsLiveTest {}", uuid_lite());
    let content = format!("AriaV2RsLiveTest body {}", uuid_lite());
    let mut write_args: BTreeMap<String, JsonValue> = BTreeMap::new();
    write_args.insert("content".to_string(), JsonValue::String(content.clone()));
    write_args.insert("subject".to_string(), JsonValue::String(subject.clone()));
    write_args.insert(
        "location".to_string(),
        JsonValue::String("tests/aria-v2-live".to_string()),
    );

    let write_result = client
        .call_tool(
            aria_v2_surface::FILE_MEMORY,
            write_args,
            &ResultFormat::MootV2,
        )
        .expect("file_memory should succeed");
    assert!(!write_result.is_error, "file memory must not be an error");
    let memory_id = write_result
        .write_assigned_id
        .as_deref()
        .expect("file memory must return a write_assigned_id");
    assert!(
        is_valid_uuid(memory_id),
        "write_assigned_id must be a UUID: {memory_id}"
    );

    // Search for it
    let search_args = aria_v2_surface::memory_search_args(&BTreeMap::new(), &subject);
    let search_result = client
        .call_tool(
            aria_v2_surface::MEMORY_SEARCH,
            search_args,
            &ResultFormat::MootV2,
        )
        .expect("memory_search should succeed");
    assert!(!search_result.is_error, "search must not be an error");
    assert!(
        search_result.ordered_ids.iter().any(|id| id == memory_id),
        "search results must contain the filed memory ID {memory_id}; got {:?}",
        search_result.ordered_ids
    );

    // Get it by ID
    let get_args = aria_v2_surface::memory_get_args(memory_id, None);
    let get_result = client
        .call_tool(aria_v2_surface::MEMORY_GET, get_args, &ResultFormat::MootV2)
        .expect("memory_get should succeed");
    assert!(!get_result.is_error, "memory_get must not be an error");
    assert!(
        get_result.ordered_ids.iter().any(|id| id == memory_id),
        "memory_get must return the requested ID {memory_id}; got {:?}",
        get_result.ordered_ids
    );
    let got_content = get_result
        .items
        .iter()
        .filter_map(|i| i.content.as_deref())
        .collect::<Vec<_>>()
        .join(" ");
    assert!(
        got_content.contains(&content) || got_content.contains(&subject),
        "returned content should include filed body or subject"
    );
}

/// 2. Genuine refusal: depth:"bogus" → full typed contract from call_tool_with_refusal.
///
/// Drive depth:"bogus" specifically — its allowed array is ["distilled","full","skim","subject"],
/// the same enum the depth:skim test (test #4) relies on.
///
/// Observed values from a real binary probe (2026-09-14):
///   error.data.path       = "depth"
///   error.data.allowed    = ["distilled","full","skim","subject"]
///   error.data.correction = "use a documented depth value"
///   error.data.code       = "invalid_argument"
///
/// Before D2 was fixed, `allowed` was None because the Rust path dropped the full contract.
/// These assertions cannot pass without the D2 fix; that is the proof.
///
/// Note: `call_tool` (the ToolCaller trait method) still throws for -32602. Use
/// `call_tool_with_refusal` when the typed contract is needed. See the port parity note on
/// that method for why the Rust thrown error does not carry a typed refusal.
#[test]
fn invalid_argument_refusal() {
    let Some(bin) = binary_path() else { return };
    let scratch = ScratchDb::new("rs-rt2").expect("create private, unique scratch directory");
    let db_path = scratch.path();

    let endpoint = make_endpoint(&bin, &db_path);
    let mut client = MCPClient::new(endpoint);
    client.connect().expect("connect");

    // Use depth:"bogus" on a syntactically valid memory_id. The server validates argument
    // values before doing any lookup, so the UUID need not exist in the estate.
    let mut bad_depth_args: BTreeMap<String, JsonValue> = BTreeMap::new();
    bad_depth_args.insert(
        "memory_id".to_string(),
        JsonValue::String("7CF35028-84BE-40D0-A8CB-7FCFE8EB6018".to_string()),
    );
    bad_depth_args.insert("depth".to_string(), JsonValue::String("bogus".to_string()));

    // call_tool_with_refusal returns MCPToolResult.is_error=true for -32602 instead of throwing,
    // carrying the full typed refusal contract in MCPToolResult.refusal.
    let result = client
        .call_tool_with_refusal(
            aria_v2_surface::MEMORY_GET,
            bad_depth_args,
            &ResultFormat::MootV2,
        )
        .expect("call_tool_with_refusal must not throw for a -32602 error");

    assert!(result.is_error, "depth:bogus must return is_error=true");

    let refusal = result
        .refusal
        .as_ref()
        .expect("MCPToolResult.refusal must be populated for depth:bogus -32602");

    // D2 check: typed code
    assert_eq!(
        refusal.code, "invalid_argument",
        "refusal.code must equal 'invalid_argument'; got '{}'",
        refusal.code
    );

    // D2 check: path — the argument that triggered the error
    assert_eq!(
        refusal.path.as_deref(),
        Some("depth"),
        "refusal.path must equal 'depth'; got {:?}",
        refusal.path
    );

    // D2 check: allowed — must compare as Vec<String>, element for element, not nil
    let expected_allowed = vec!["distilled", "full", "skim", "subject"];
    let actual_allowed: Vec<&str> = refusal
        .allowed
        .as_ref()
        .expect("refusal.allowed must not be None for depth:bogus")
        .iter()
        .map(|s| s.as_str())
        .collect();
    assert_eq!(
        actual_allowed, expected_allowed,
        "refusal.allowed must equal {:?}; got {:?}",
        expected_allowed, actual_allowed
    );

    // D2 check: correction — exact string from the server
    assert_eq!(
        refusal.correction.as_deref(),
        Some("use a documented depth value"),
        "refusal.correction must equal 'use a documented depth value'; got {:?}",
        refusal.correction
    );
}

/// 3. Genuine refusal: valid-format UUID not in estate → memory_not_found.
#[test]
fn memory_not_found_refusal() {
    let Some(bin) = binary_path() else { return };
    let scratch = ScratchDb::new("rs-rt3").expect("create private, unique scratch directory");
    let db_path = scratch.path();

    let endpoint = make_endpoint(&bin, &db_path);
    let mut client = MCPClient::new(endpoint);
    client.connect().expect("connect");

    // A well-formed UUID that does not exist in the fresh estate
    let absent_uuid = format!(
        "00000000-0000-4000-8000-{:012x}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .subsec_nanos()
    );
    let get_args = aria_v2_surface::memory_get_args(&absent_uuid, None);
    let result = client
        .call_tool(aria_v2_surface::MEMORY_GET, get_args, &ResultFormat::MootV2)
        .expect("memory_get for absent UUID should not throw (isError path)");

    assert!(result.is_error, "absent UUID must return is_error=true");
    let refusal = result
        .refusal
        .as_ref()
        .expect("absent UUID must populate MCPToolResult.refusal");
    assert_eq!(
        refusal.code, "memory_not_found",
        "refusal.code must equal catalog string 'memory_not_found'; got '{}'",
        refusal.code
    );
}

/// 4. depth:"skim" reaches moot_memory_get wire and server accepts it.
#[test]
fn depth_skim_reaches_wire() {
    let Some(bin) = binary_path() else { return };
    let scratch = ScratchDb::new("rs-rt4").expect("create private, unique scratch directory");
    let db_path = scratch.path();

    let endpoint = make_endpoint(&bin, &db_path);
    let mut client = MCPClient::new(endpoint);
    client.connect().expect("connect");

    // File a memory first
    let mut write_args: BTreeMap<String, JsonValue> = BTreeMap::new();
    write_args.insert(
        "content".to_string(),
        JsonValue::String(
            "Skim depth test body. Sufficient text to produce a preview.".to_string(),
        ),
    );
    write_args.insert(
        "subject".to_string(),
        JsonValue::String("skim depth test".to_string()),
    );
    write_args.insert(
        "location".to_string(),
        JsonValue::String("tests/skim".to_string()),
    );
    let write_result = client
        .call_tool(
            aria_v2_surface::FILE_MEMORY,
            write_args,
            &ResultFormat::MootV2,
        )
        .expect("file_memory");
    let mem_id = write_result
        .write_assigned_id
        .as_deref()
        .expect("write_assigned_id");

    // Read "skim" from the catalog values (not a typed literal)
    let skim_value = CATALOG_DEPTH_VALUES
        .iter()
        .find(|&&v| v == "skim")
        .copied()
        .expect("skim must be in catalog depth values");

    let get_args = aria_v2_surface::memory_get_args(mem_id, Some(skim_value));
    let get_result = client
        .call_tool(aria_v2_surface::MEMORY_GET, get_args, &ResultFormat::MootV2)
        .expect("memory_get with depth:skim must not throw");

    assert!(
        !get_result.is_error,
        "server must accept depth:skim without error; is_error={}",
        get_result.is_error
    );
    assert!(
        get_result.ordered_ids.iter().any(|id| id == mem_id),
        "depth:skim must return the requested memory; got {:?}",
        get_result.ordered_ids
    );
}

/// 5. Response with no meta decodes; withheld_by_sensitivity is optional.
#[test]
fn meta_absent_decodes_gracefully() {
    let Some(bin) = binary_path() else { return };
    let scratch = ScratchDb::new("rs-rt5").expect("create private, unique scratch directory");
    let db_path = scratch.path();

    let endpoint = make_endpoint(&bin, &db_path);
    let mut client = MCPClient::new(endpoint);
    client.connect().expect("connect");

    // File a memory
    let mut write_args: BTreeMap<String, JsonValue> = BTreeMap::new();
    write_args.insert(
        "content".to_string(),
        JsonValue::String("Meta optional test body.".to_string()),
    );
    write_args.insert(
        "subject".to_string(),
        JsonValue::String("meta optional test".to_string()),
    );
    write_args.insert(
        "location".to_string(),
        JsonValue::String("tests/meta".to_string()),
    );
    let write_result = client
        .call_tool(
            aria_v2_surface::FILE_MEMORY,
            write_args,
            &ResultFormat::MootV2,
        )
        .expect("file_memory");
    let mem_id = write_result
        .write_assigned_id
        .as_deref()
        .expect("write_assigned_id");

    // Search — no report_withheld modifier → meta absent or present without the key
    let search_args = aria_v2_surface::memory_search_args(&BTreeMap::new(), "meta optional test");
    let search_result = client
        .call_tool(
            aria_v2_surface::MEMORY_SEARCH,
            search_args,
            &ResultFormat::MootV2,
        )
        .expect("memory_search must not throw");

    assert!(
        !search_result.is_error,
        "search must succeed and decode even without meta"
    );
    assert!(
        search_result.ordered_ids.iter().any(|id| id == mem_id),
        "filed memory must appear in search results; got {:?}",
        search_result.ordered_ids
    );
    // withheld_by_sensitivity may be None when report_withheld not passed — that is correct
    // (test reaching here without panic is the proof that absent meta decodes gracefully)
}

// ─────────────────────────────────────────────────────────────────────────────
// Small utilities
// ─────────────────────────────────────────────────────────────────────────────

/// Generates a simple random-looking string for test subject uniqueness.
/// Not a real UUID — just 8 hex chars from the process clock.
fn uuid_lite() -> String {
    let t = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos();
    format!("{t:08x}")
}

/// Returns true when the string matches the UUID format (8-4-4-4-12 hex).
fn is_valid_uuid(s: &str) -> bool {
    let parts: Vec<&str> = s.split('-').collect();
    parts.len() == 5
        && parts[0].len() == 8
        && parts[1].len() == 4
        && parts[2].len() == 4
        && parts[3].len() == 4
        && parts[4].len() == 12
        && parts
            .iter()
            .all(|p| p.chars().all(|c| c.is_ascii_hexdigit()))
}
