//! Unit tests for the Anthropic memory_20250818 tool adapter (M-MEMTOOL-1).
//!
//! Covers the env gate (disabled → refusal) and a happy-path exercise of
//! each of the six commands: view (directory and file), create, str_replace,
//! insert, delete, and rename. Also covers the tool-list projection (the
//! `memory` tool appears when MOOTX01_MEMORY_TOOL=1 and is absent otherwise).
//!
//! The sensitivity gate (restricted/secret drawers hidden) and the elevated-tier
//! preservation on edit are tested in `dispatch_tests.rs` — those three tests
//! live there because they were the first memory-tool tests written and relied on
//! the dispatch helpers already established in that file.
//!
//! # Env-var serialization
//!
//! All tests that read `MOOTX01_MEMORY_TOOL` hold `mem_lock()` to prevent
//! concurrent env-var mutations under the parallel test runner.

use std::collections::BTreeMap;
use aria_mcp::{
    dispatch::{dispatch_tool, wall_now},
    estate_registry::EstateRegistry,
    jsonrpc::JsonValue,
    surfaced_recall_ledger::SurfacedRecallLedger,
    tool_list::{build_tool_list_with_flags, vault_enabled},
};
use locus_kit::{
    adjectives::AdjectiveSensitivity,
    drawer_operational::CaptureChannel,
    estate_types::LatticeAnchor,
    frames::CaptureFrame,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

macro_rules! args {
    () => { BTreeMap::new() };
    ( $( $k:expr => $v:expr ),+ $(,)? ) => {{
        let mut m = BTreeMap::new();
        $( m.insert($k.to_string(), JsonValue::from(serde_json::json!($v))); )+
        m
    }};
}

fn text(result: &serde_json::Value) -> &str {
    result["content"][0]["text"].as_str().unwrap_or("")
}

fn is_error(result: &serde_json::Value) -> bool {
    result["isError"] == serde_json::json!(true)
}

/// Serialize all tests that mutate MOOTX01_MEMORY_TOOL so their env writes
/// do not race each other under the parallel test runner.
fn mem_lock() -> std::sync::MutexGuard<'static, ()> {
    static MEM: std::sync::Mutex<()> = std::sync::Mutex::new(());
    MEM.lock().unwrap_or_else(|e| e.into_inner())
}

/// Enable the memory tool and dispatch a single call, then restore the env.
fn with_memory_enabled<F>(f: F)
where
    F: FnOnce(&EstateRegistry, &SurfacedRecallLedger),
{
    let _guard = mem_lock();
    std::env::set_var("MOOTX01_MEMORY_TOOL", "1");
    let registry = EstateRegistry::new_inmemory_bare();
    let ledger = SurfacedRecallLedger::new();
    f(&registry, &ledger);
    // Always restore — even if f() panics this runs via drop on the guard,
    // but the env var must be cleared after the test body explicitly.
    std::env::remove_var("MOOTX01_MEMORY_TOOL");
}

/// Seed a drawer directly into the `memories` wing at the given room path
/// (the room is the tail after "/memories/", e.g. "foo.txt").
fn seed_memory_file(
    registry: &EstateRegistry,
    room: &str,
    content: &str,
    sensitivity: AdjectiveSensitivity,
) {
    let mut frame = CaptureFrame::new(
        content,
        CaptureChannel::Actuator,
        room,
        LatticeAnchor::udc("000"),
        "aria-mcp-tests",
        "default",
    );
    frame.wing = Some("memories".to_string());
    frame.sensitivity = sensitivity;
    let now = wall_now();
    let coord = registry.coord.lock().unwrap();
    coord
        .capture(&registry.default.handle, frame, now)
        .expect("seed_memory_file: capture must succeed");
}

fn call(
    name: &str,
    a: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
    ledger: &SurfacedRecallLedger,
) -> serde_json::Value {
    dispatch_tool(name, a, registry, ledger).expect("dispatch must not throw")
}

// ---------------------------------------------------------------------------
// Env gate
// ---------------------------------------------------------------------------

/// Mirror of Swift `MemoryToolAdapterSensitivityTests.disabledMemoryToolRefusesDispatch`.
#[test]
fn env_gate_absent_refuses_dispatch() {
    let _guard = mem_lock();
    std::env::remove_var("MOOTX01_MEMORY_TOOL");
    let registry = EstateRegistry::new_inmemory_bare();
    let result = dispatch_tool(
        "memory",
        &args! {"command" => "view", "path" => "/memories"},
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("dispatch must return a tool result, not a transport error");
    let t = text(&result);
    assert!(
        t.contains("disabled"),
        "absent MOOTX01_MEMORY_TOOL must produce a disabled refusal; got: {t}"
    );
    assert!(is_error(&result), "refusal must be isError:true; got: {result:?}");
    // Restore for tests sharing the process.
    std::env::remove_var("MOOTX01_MEMORY_TOOL");
}

// ---------------------------------------------------------------------------
// Tool list projection
// ---------------------------------------------------------------------------

/// When MOOTX01_MEMORY_TOOL=1, the `memory` tool appears first in the list
/// (mirroring Swift ToolProjection.tools() which prepends memoryAdapterTools()).
/// When disabled, it is absent and the base counts (71/65) are unchanged.
#[test]
fn memory_tool_in_list_when_enabled_absent_when_disabled() {
    // Disabled: `memory` must not appear in the baseline list.
    let base = build_tool_list_with_flags(vault_enabled(), false);
    let base_arr = base.as_array().expect("must be array");
    assert!(
        !base_arr.iter().any(|t| t["name"] == "memory"),
        "`memory` must be absent from the baseline tool list"
    );
    let base_count = base_arr.len();

    // Enabled: `memory` must appear and the count must be base + 1.
    let enabled = build_tool_list_with_flags(vault_enabled(), true);
    let enabled_arr = enabled.as_array().expect("must be array");
    assert!(
        enabled_arr.iter().any(|t| t["name"] == "memory"),
        "`memory` must appear in the tool list when memory_on=true"
    );
    assert_eq!(
        enabled_arr.len(),
        base_count + 1,
        "enabling the memory tool must add exactly 1 to the tool count"
    );

    // The `memory` tool must be the first entry (mirrors Swift prepend order).
    assert_eq!(
        enabled_arr[0]["name"].as_str(),
        Some("memory"),
        "`memory` must be the first tool when memory_on=true"
    );

    // Schema must carry `command` as a required field.
    let schema = &enabled_arr[0]["inputSchema"];
    let required = schema["required"].as_array().expect("required must be array");
    let has_command = required.iter().any(|v| v.as_str() == Some("command"));
    assert!(has_command, "`command` must be in the required fields of the memory tool schema");
}

// ---------------------------------------------------------------------------
// Command: view (directory listing)
// ---------------------------------------------------------------------------

#[test]
fn view_root_lists_files() {
    with_memory_enabled(|registry, ledger| {
        seed_memory_file(registry, "alpha.txt", "alpha content", AdjectiveSensitivity::Normal);
        seed_memory_file(registry, "beta.txt", "beta content", AdjectiveSensitivity::Normal);

        let result = call("memory", &args! {"command" => "view", "path" => "/memories"}, registry, ledger);
        let t = text(&result);
        assert!(!is_error(&result), "view /memories must succeed; got: {t}");
        assert!(t.contains("/memories/alpha.txt"), "{t}");
        assert!(t.contains("/memories/beta.txt"), "{t}");
        assert!(
            t.contains("Here're the files and directories"),
            "must use the canonical listing header; got: {t}"
        );
    });
}

// ---------------------------------------------------------------------------
// Command: view (file content with line numbers)
// ---------------------------------------------------------------------------

#[test]
fn view_file_returns_numbered_content() {
    with_memory_enabled(|registry, ledger| {
        seed_memory_file(registry, "notes.txt", "line one\nline two\nline three", AdjectiveSensitivity::Normal);

        let result = call("memory", &args! {"command" => "view", "path" => "/memories/notes.txt"}, registry, ledger);
        let t = text(&result);
        assert!(!is_error(&result), "view of existing file must succeed; got: {t}");
        assert!(t.contains("line one"), "{t}");
        assert!(t.contains("line two"), "{t}");
        // Line numbers must be present (format: "     1\t").
        assert!(t.contains("1\t"), "output must include line numbers; got: {t}");
        assert!(
            t.contains("Here's the content of /memories/notes.txt with line numbers:"),
            "must use canonical content header; got: {t}"
        );
    });
}

#[test]
fn view_nonexistent_path_returns_does_not_exist() {
    with_memory_enabled(|registry, ledger| {
        let result = call("memory", &args! {"command" => "view", "path" => "/memories/ghost.txt"}, registry, ledger);
        let t = text(&result);
        assert!(!is_error(&result), "view of missing path must be a text result, not a transport error; got: {t}");
        assert!(t.contains("does not exist"), "{t}");
    });
}

// ---------------------------------------------------------------------------
// Command: create
// ---------------------------------------------------------------------------

#[test]
fn create_makes_file_readable() {
    with_memory_enabled(|registry, ledger| {
        let result = call(
            "memory",
            &args! {
                "command" => "create",
                "path" => "/memories/new.txt",
                "file_text" => "hello world"
            },
            registry,
            ledger,
        );
        let t = text(&result);
        assert!(!is_error(&result), "create must succeed; got: {t}");
        assert!(t.contains("File created successfully"), "{t}");
        assert!(t.contains("/memories/new.txt"), "{t}");

        // Verify the file is readable via view.
        let view = call("memory", &args! {"command" => "view", "path" => "/memories/new.txt"}, registry, ledger);
        assert!(text(&view).contains("hello world"), "created file must be readable; got: {}", text(&view));
    });
}

#[test]
fn create_refuses_duplicate() {
    with_memory_enabled(|registry, ledger| {
        seed_memory_file(registry, "exists.txt", "already here", AdjectiveSensitivity::Normal);

        let result = call(
            "memory",
            &args! {"command" => "create", "path" => "/memories/exists.txt", "file_text" => "new content"},
            registry,
            ledger,
        );
        let t = text(&result);
        assert!(t.contains("already exists"), "creating over an existing file must be refused; got: {t}");
    });
}

// ---------------------------------------------------------------------------
// Command: str_replace
// ---------------------------------------------------------------------------

#[test]
fn str_replace_replaces_unique_occurrence() {
    with_memory_enabled(|registry, ledger| {
        seed_memory_file(registry, "doc.txt", "the quick brown fox", AdjectiveSensitivity::Normal);

        let result = call(
            "memory",
            &args! {
                "command" => "str_replace",
                "path" => "/memories/doc.txt",
                "old_str" => "quick brown",
                "new_str" => "slow red"
            },
            registry,
            ledger,
        );
        let t = text(&result);
        assert!(!is_error(&result), "str_replace must succeed; got: {t}");
        assert!(t.contains("edited"), "{t}");

        // File content must reflect the replacement.
        let view = call("memory", &args! {"command" => "view", "path" => "/memories/doc.txt"}, registry, ledger);
        assert!(text(&view).contains("slow red"), "replacement must be visible; got: {}", text(&view));
        assert!(!text(&view).contains("quick brown"), "old text must be gone; got: {}", text(&view));
    });
}

#[test]
fn str_replace_refuses_absent_old_str() {
    with_memory_enabled(|registry, ledger| {
        seed_memory_file(registry, "doc.txt", "hello", AdjectiveSensitivity::Normal);

        let result = call(
            "memory",
            &args! {
                "command" => "str_replace",
                "path" => "/memories/doc.txt",
                "old_str" => "not present",
                "new_str" => "replacement"
            },
            registry,
            ledger,
        );
        let t = text(&result);
        assert!(
            t.contains("did not appear verbatim"),
            "str_replace with absent old_str must report no match; got: {t}"
        );
    });
}

#[test]
fn str_replace_refuses_ambiguous_old_str() {
    with_memory_enabled(|registry, ledger| {
        seed_memory_file(registry, "dup.txt", "aa bb aa", AdjectiveSensitivity::Normal);

        let result = call(
            "memory",
            &args! {
                "command" => "str_replace",
                "path" => "/memories/dup.txt",
                "old_str" => "aa",
                "new_str" => "xx"
            },
            registry,
            ledger,
        );
        let t = text(&result);
        assert!(
            t.contains("Multiple occurrences"),
            "str_replace with duplicate old_str must be refused; got: {t}"
        );
    });
}

// ---------------------------------------------------------------------------
// Command: insert
// ---------------------------------------------------------------------------

#[test]
fn insert_after_line_zero_prepends() {
    with_memory_enabled(|registry, ledger| {
        seed_memory_file(registry, "list.txt", "line A\nline B", AdjectiveSensitivity::Normal);

        let result = call(
            "memory",
            &args! {
                "command" => "insert",
                "path" => "/memories/list.txt",
                "insert_line" => 0,
                "insert_text" => "line ZERO"
            },
            registry,
            ledger,
        );
        let t = text(&result);
        assert!(!is_error(&result), "insert at line 0 must succeed; got: {t}");
        assert!(t.contains("edited"), "{t}");

        let view = call("memory", &args! {"command" => "view", "path" => "/memories/list.txt"}, registry, ledger);
        let content = text(&view);
        // "line ZERO" must appear before "line A".
        let zero_pos = content.find("line ZERO").expect("inserted text must be present");
        let a_pos = content.find("line A").expect("original line A must be present");
        assert!(zero_pos < a_pos, "prepended text must come before original content; content: {content}");
    });
}

#[test]
fn insert_out_of_range_returns_error() {
    with_memory_enabled(|registry, ledger| {
        seed_memory_file(registry, "short.txt", "one line", AdjectiveSensitivity::Normal);

        let result = call(
            "memory",
            &args! {
                "command" => "insert",
                "path" => "/memories/short.txt",
                "insert_line" => 999,
                "insert_text" => "too far"
            },
            registry,
            ledger,
        );
        let t = text(&result);
        assert!(
            t.contains("Invalid `insert_line`"),
            "out-of-range insert_line must produce a range error; got: {t}"
        );
    });
}

// ---------------------------------------------------------------------------
// Command: delete
// ---------------------------------------------------------------------------

#[test]
fn delete_removes_file() {
    with_memory_enabled(|registry, ledger| {
        seed_memory_file(registry, "gone.txt", "to be deleted", AdjectiveSensitivity::Normal);

        let result = call(
            "memory",
            &args! {"command" => "delete", "path" => "/memories/gone.txt"},
            registry,
            ledger,
        );
        let t = text(&result);
        assert!(!is_error(&result), "delete of existing file must succeed; got: {t}");
        assert!(t.contains("Successfully deleted"), "{t}");

        // File must no longer be viewable.
        let view = call("memory", &args! {"command" => "view", "path" => "/memories/gone.txt"}, registry, ledger);
        assert!(text(&view).contains("does not exist"), "deleted file must not be viewable; got: {}", text(&view));
    });
}

#[test]
fn delete_refuses_nonexistent_path() {
    with_memory_enabled(|registry, ledger| {
        let result = call(
            "memory",
            &args! {"command" => "delete", "path" => "/memories/never.txt"},
            registry,
            ledger,
        );
        let t = text(&result);
        assert!(t.contains("does not exist"), "deleting a nonexistent path must error; got: {t}");
    });
}

#[test]
fn delete_refuses_root() {
    with_memory_enabled(|registry, ledger| {
        let result = call(
            "memory",
            &args! {"command" => "delete", "path" => "/memories"},
            registry,
            ledger,
        );
        let t = text(&result);
        assert!(
            t.contains("Cannot delete the memory root"),
            "deleting /memories must be refused; got: {t}"
        );
    });
}

// ---------------------------------------------------------------------------
// Command: rename
// ---------------------------------------------------------------------------

#[test]
fn rename_moves_content_to_new_path() {
    with_memory_enabled(|registry, ledger| {
        seed_memory_file(registry, "original.txt", "file content", AdjectiveSensitivity::Normal);

        let result = call(
            "memory",
            &args! {
                "command" => "rename",
                "old_path" => "/memories/original.txt",
                "new_path" => "/memories/renamed.txt"
            },
            registry,
            ledger,
        );
        let t = text(&result);
        assert!(!is_error(&result), "rename must succeed; got: {t}");
        assert!(t.contains("Successfully renamed"), "{t}");
        assert!(t.contains("/memories/original.txt"), "{t}");
        assert!(t.contains("/memories/renamed.txt"), "{t}");

        // Old path must be gone; new path must carry the content.
        let old_view = call("memory", &args! {"command" => "view", "path" => "/memories/original.txt"}, registry, ledger);
        assert!(text(&old_view).contains("does not exist"), "old path must be gone after rename; got: {}", text(&old_view));

        let new_view = call("memory", &args! {"command" => "view", "path" => "/memories/renamed.txt"}, registry, ledger);
        assert!(text(&new_view).contains("file content"), "new path must carry original content; got: {}", text(&new_view));
    });
}

#[test]
fn rename_refuses_collision_at_destination() {
    with_memory_enabled(|registry, ledger| {
        seed_memory_file(registry, "src.txt", "source content", AdjectiveSensitivity::Normal);
        seed_memory_file(registry, "dst.txt", "destination content", AdjectiveSensitivity::Normal);

        let result = call(
            "memory",
            &args! {
                "command" => "rename",
                "old_path" => "/memories/src.txt",
                "new_path" => "/memories/dst.txt"
            },
            registry,
            ledger,
        );
        let t = text(&result);
        assert!(
            t.contains("already exists"),
            "rename to an occupied destination must be refused; got: {t}"
        );
    });
}

// ---------------------------------------------------------------------------
// Path security gate
// ---------------------------------------------------------------------------

#[test]
fn traversal_in_path_is_rejected() {
    with_memory_enabled(|registry, _ledger| {
        // `..` traversal must be caught by validate_path, returning an INVALID_PARAMS
        // JSON-RPC error (not an isError tool result).
        let err = dispatch_tool(
            "memory",
            &args! {"command" => "view", "path" => "/memories/../etc/passwd"},
            registry,
            &SurfacedRecallLedger::new(),
        );
        assert!(
            err.is_err(),
            "path traversal must return a transport-level INVALID_PARAMS error, not a tool result"
        );
    });
}

#[test]
fn path_not_under_memories_is_rejected() {
    with_memory_enabled(|registry, _ledger| {
        let err = dispatch_tool(
            "memory",
            &args! {"command" => "view", "path" => "/etc/passwd"},
            registry,
            &SurfacedRecallLedger::new(),
        );
        assert!(err.is_err(), "/etc/passwd must produce INVALID_PARAMS; got: {err:?}");
    });
}

// ---------------------------------------------------------------------------
// Missing-argument parity: absent required args return isError:false textResult
// ---------------------------------------------------------------------------

/// Missing 'command' must return a textResult (isError:false), not a JSON-RPC
/// protocol error. Parity with Swift's guard-else return.
#[test]
fn missing_command_returns_text_result_not_transport_error() {
    with_memory_enabled(|registry, ledger| {
        // dispatch_tool must not throw; the result must be a text result.
        let result = call("memory", &args! {}, registry, ledger);
        let t = text(&result);
        assert!(!is_error(&result), "missing command must be isError:false; got: {result:?}");
        assert!(
            t.contains("missing or invalid 'command'"),
            "must report missing command; got: {t}"
        );
    });
}

/// Missing 'file_text' in create must return textResult (isError:false).
#[test]
fn create_missing_file_text_returns_text_result() {
    with_memory_enabled(|registry, ledger| {
        let result = call(
            "memory",
            &args! {"command" => "create", "path" => "/memories/x.txt"},
            registry,
            ledger,
        );
        let t = text(&result);
        assert!(!is_error(&result), "missing file_text must be isError:false; got: {result:?}");
        assert!(t.contains("missing 'file_text'"), "must name the missing param; got: {t}");
    });
}

/// Missing 'old_str' in str_replace must return textResult (isError:false).
#[test]
fn str_replace_missing_old_str_returns_text_result() {
    with_memory_enabled(|registry, ledger| {
        seed_memory_file(registry, "sr.txt", "hello", AdjectiveSensitivity::Normal);
        let result = call(
            "memory",
            &args! {"command" => "str_replace", "path" => "/memories/sr.txt"},
            registry,
            ledger,
        );
        let t = text(&result);
        assert!(!is_error(&result), "missing old_str must be isError:false; got: {result:?}");
        assert!(t.contains("missing 'old_str'"), "must name the missing param; got: {t}");
    });
}

/// Missing 'insert_line' in insert must return textResult (isError:false), not
/// silently prepend (the old default-0 behavior).
#[test]
fn insert_missing_insert_line_returns_text_result() {
    with_memory_enabled(|registry, ledger| {
        seed_memory_file(registry, "il.txt", "line A", AdjectiveSensitivity::Normal);
        let result = call(
            "memory",
            &args! {
                "command" => "insert",
                "path" => "/memories/il.txt",
                "insert_text" => "new line"
            },
            registry,
            ledger,
        );
        let t = text(&result);
        assert!(!is_error(&result), "missing insert_line must be isError:false; got: {result:?}");
        assert!(t.contains("missing 'insert_line'"), "must name the missing param; got: {t}");
    });
}

/// Missing 'insert_text' in insert must return textResult (isError:false).
#[test]
fn insert_missing_insert_text_returns_text_result() {
    with_memory_enabled(|registry, ledger| {
        seed_memory_file(registry, "it.txt", "line A", AdjectiveSensitivity::Normal);
        let result = call(
            "memory",
            &args! {
                "command" => "insert",
                "path" => "/memories/it.txt",
                "insert_line" => 0
            },
            registry,
            ledger,
        );
        let t = text(&result);
        assert!(!is_error(&result), "missing insert_text must be isError:false; got: {result:?}");
        assert!(t.contains("missing 'insert_text'"), "must name the missing param; got: {t}");
    });
}

// ---------------------------------------------------------------------------
// Root-directory protection: isError must be false (textResult), not true
// ---------------------------------------------------------------------------

/// Deleting /memories must refuse with isError:false (textResult), not isError:true.
/// Contract §4.5. Parity with Swift's Self.textResult.
#[test]
fn delete_root_refusal_is_not_error() {
    with_memory_enabled(|registry, ledger| {
        let result = call(
            "memory",
            &args! {"command" => "delete", "path" => "/memories"},
            registry,
            ledger,
        );
        assert!(
            !is_error(&result),
            "delete-root refusal must be isError:false (textResult), not error_result; got: {result:?}"
        );
        let t = text(&result);
        assert!(t.contains("Cannot delete the memory root"), "must name the refusal reason; got: {t}");
    });
}

/// Renaming /memories must refuse with isError:false (textResult), not isError:true.
/// Contract §4.6. Parity with Swift's Self.textResult.
#[test]
fn rename_root_refusal_is_not_error() {
    with_memory_enabled(|registry, ledger| {
        let result = call(
            "memory",
            &args! {
                "command" => "rename",
                "old_path" => "/memories",
                "new_path" => "/memories/moved"
            },
            registry,
            ledger,
        );
        assert!(
            !is_error(&result),
            "rename-root refusal must be isError:false (textResult), not error_result; got: {result:?}"
        );
        let t = text(&result);
        assert!(t.contains("Cannot rename the memory root"), "must name the refusal reason; got: {t}");
    });
}

// ---------------------------------------------------------------------------
// view_range: string and array forms
// ---------------------------------------------------------------------------

/// view_range as "start,end" string slices to the requested line window.
#[test]
fn view_range_string_slices_lines() {
    with_memory_enabled(|registry, ledger| {
        seed_memory_file(
            registry,
            "range.txt",
            "line 1\nline 2\nline 3\nline 4\nline 5",
            AdjectiveSensitivity::Normal,
        );
        let result = call(
            "memory",
            &args! {
                "command" => "view",
                "path" => "/memories/range.txt",
                "view_range" => "2,4"
            },
            registry,
            ledger,
        );
        let t = text(&result);
        assert!(!is_error(&result), "view with view_range must succeed; got: {t}");
        assert!(t.contains("line 2"), "line 2 must be present; got: {t}");
        assert!(t.contains("line 4"), "line 4 must be present; got: {t}");
        assert!(!t.contains("line 1"), "line 1 must be excluded; got: {t}");
        assert!(!t.contains("line 5"), "line 5 must be excluded; got: {t}");
        // Line numbers must start at 2, not 1 (startOffset carried through).
        assert!(t.contains("     2\t"), "line numbers must start at 2; got: {t}");
    });
}

/// view_range as [start, end] integer array slices to the requested window.
#[test]
fn view_range_array_slices_lines() {
    with_memory_enabled(|registry, ledger| {
        seed_memory_file(
            registry,
            "range_arr.txt",
            "alpha\nbeta\ngamma\ndelta",
            AdjectiveSensitivity::Normal,
        );
        // Pass as a JSON array. The args! macro wraps via serde_json::json!,
        // so [3, -1] produces an Array([Integer(3), Integer(-1)]).
        let mut a = BTreeMap::new();
        a.insert("command".to_string(), JsonValue::from(serde_json::json!("view")));
        a.insert("path".to_string(), JsonValue::from(serde_json::json!("/memories/range_arr.txt")));
        a.insert(
            "view_range".to_string(),
            JsonValue::Array(vec![
                JsonValue::Integer(3),
                JsonValue::Integer(-1),
            ]),
        );
        let result = call("memory", &a, registry, ledger);
        let t = text(&result);
        assert!(!is_error(&result), "view with array view_range must succeed; got: {t}");
        assert!(t.contains("gamma"), "gamma (line 3) must be present; got: {t}");
        assert!(t.contains("delta"), "delta (line 4, EOF) must be present; got: {t}");
        assert!(!t.contains("alpha"), "alpha must be excluded; got: {t}");
        assert!(!t.contains("beta"), "beta must be excluded; got: {t}");
        // Line numbers must start at 3.
        assert!(t.contains("     3\t"), "line numbers must start at 3; got: {t}");
    });
}
