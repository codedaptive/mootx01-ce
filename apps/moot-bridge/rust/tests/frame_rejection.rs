//! frame_rejection.rs — the regression proof for MXE-MB (Rust twin of
//! `BridgeFrameRejectionTests.swift`).
//!
//! A malformed client line used to be indistinguishable from a valid id-less
//! notification: both produced `None` for `id`, so both took the notification
//! branch and the raw bytes were written to BOTH backends. A JSON-RPC backend
//! answers a malformed frame with a parseError; that response was never read, so
//! the NEXT send_and_receive consumed it instead of its own result and every
//! response after that was skewed by one for the life of the process.
//!
//! Two layers of proof here:
//!
//!   1. `BridgeServer::classify_frame` unit tests — the three-way split itself,
//!      and the parseError/invalidRequest distinction, with no process and no I/O.
//!
//!   2. A wired suite that drives the real `run_bridge` loop against two STUB
//!      backends. The stubs append every line they receive to a log file, which
//!      is the only way to assert the mission's actual requirement — that a
//!      rejected frame reaches NO backend. The stubs also answer a frame they
//!      cannot parse with a parseError, exactly as a real backend does, so the
//!      desynchronization is reproduced faithfully rather than assumed.
//!
//! The stub backends are `/usr/bin/awk` scripts, so this suite has no dependency
//! on mempalace-mcp or mootx01 being installed and runs everywhere the live
//! acceptance test skips.

use moot_bridge::bridge::{
    BridgeServer, FrameDisposition, INVALID_REQUEST_CODE, PARSE_ERROR_CODE,
};
use moot_bridge::config::BridgeConfig;
use moot_bridge::run_bridge;
use serde_json::Value;
use std::io::BufReader;
use std::path::{Path, PathBuf};

// MARK: - Unit: the three-way split

/// A well-formed request carrying an id classifies as `Request`, and the method
/// and id the classifier extracted are the ones downstream uses.
#[test]
fn request_with_id_is_a_request() {
    let line = r#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#;
    match BridgeServer::classify_frame(line) {
        FrameDisposition::Request { method, id, .. } => {
            assert_eq!(method, "tools/list");
            assert_eq!(id, serde_json::json!(1));
        }
        other => panic!("expected Request, got {other:?}"),
    }
}

/// A well-formed envelope with no id is a genuine notification — the one case
/// that legitimately reaches both backends.
#[test]
fn envelope_without_id_is_a_notification() {
    let line = r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#;
    assert_eq!(
        BridgeServer::classify_frame(line),
        FrameDisposition::Notification
    );
}

/// An explicit `"id": null` is a REQUEST, not a notification: JSON-RPC 2.0
/// permits a null id, and the classifier tests for presence of the key rather
/// than for a non-null value. This is the pre-change behaviour, preserved
/// deliberately.
#[test]
fn explicit_null_id_is_still_a_request() {
    let line = r#"{"jsonrpc":"2.0","id":null,"method":"tools/list"}"#;
    match BridgeServer::classify_frame(line) {
        FrameDisposition::Request { method, id, .. } => {
            assert_eq!(method, "tools/list");
            assert_eq!(id, Value::Null);
        }
        other => panic!("expected Request for an explicit null id, got {other:?}"),
    }
}

/// Unparseable bytes are a parseError (-32700) — the frame never became JSON, so
/// there is nothing to say about its envelope.
#[test]
fn unparseable_line_is_parse_error() {
    for bad in ["{", "not json at all", r#"{"jsonrpc": "2.0""#, r#"{"a":}"#] {
        match BridgeServer::classify_frame(bad) {
            FrameDisposition::Reject { code, .. } => {
                assert_eq!(code, PARSE_ERROR_CODE, "wrong code for {bad}")
            }
            other => panic!("expected Reject for {bad}, got {other:?}"),
        }
    }
}

/// Valid JSON that is not a JSON-RPC envelope is invalidRequest (-32600), NOT
/// parseError. Collapsing the two would tell a client "bad JSON" when the JSON
/// was fine and only the envelope was wrong.
#[test]
fn valid_json_that_is_not_an_envelope_is_invalid_request() {
    let not_envelopes = [
        "[1,2,3]",                                // bare array
        r#""just a string""#,                     // bare string
        "42",                                     // bare number
        "true",                                   // bare bool
        "null",                                   // bare null
        "{}",                                     // object, no fields
        r#"{"id":1,"method":"tools/list"}"#,      // no jsonrpc
        r#"{"jsonrpc":"1.0","id":1,"method":"x"}"#, // wrong jsonrpc version
        r#"{"jsonrpc":"2.0","id":1}"#,            // no method
        r#"{"jsonrpc":"2.0","id":1,"method":7}"#, // method is not a string
    ];
    for line in not_envelopes {
        match BridgeServer::classify_frame(line) {
            FrameDisposition::Reject { code, .. } => {
                assert_eq!(code, INVALID_REQUEST_CODE, "wrong code for {line}")
            }
            other => panic!("expected Reject for {line}, got {other:?}"),
        }
    }
}

/// PINNED PORT DIVERGENCE. serde_json rejects a trailing comma as a syntax
/// error; Swift's Foundation parser accepts it. So
/// `{"jsonrpc":"2.0","method":"x",}` is a parseError here and a perfectly good
/// notification in the Swift twin.
///
/// This is recorded rather than papered over, because the invariant that matters
/// still holds in both ports: each bridge delegates parsing to its own vertical's
/// standard parser — the same parser its own backends use — so a bridge never
/// forwards a frame that its backends would then fail to read. The
/// desynchronization the mission fixes cannot occur on either side of the
/// divergence. Normalizing it would mean hand-rolling a strict JSON parser in
/// each port to second-guess the standard one, which buys nothing.
#[test]
fn serde_json_rejects_a_trailing_comma_where_foundation_would_not() {
    match BridgeServer::classify_frame(r#"{"jsonrpc":"2.0","method":"notifications/x",}"#) {
        FrameDisposition::Reject { code, .. } => assert_eq!(code, PARSE_ERROR_CODE),
        other => panic!("expected Reject, got {other:?}"),
    }
}

/// The two codes are the JSON-RPC 2.0 standard values, matching the ones
/// AriaMcpKit's backend answers with. A client must not be able to tell whether
/// its bad frame was refused by the bridge or by a backend.
#[test]
fn codes_match_the_jsonrpc_standard() {
    assert_eq!(PARSE_ERROR_CODE, -32700);
    assert_eq!(INVALID_REQUEST_CODE, -32600);
}

// MARK: - Wired: rejected frames reach no backend

/// A malformed line is answered by the BRIDGE with a parseError carrying a null
/// id, and reaches NEITHER backend.
///
/// This is the regression test. Against pre-fix code the malformed line went out
/// on the notification path, so both backend logs contained it and the client got
/// no error at all.
#[test]
fn malformed_line_is_rejected_and_not_forwarded() {
    let rig = StubRig::new("malformed-rejected");
    let responses = rig.drive(&["{"]);

    assert_eq!(
        responses.len(),
        1,
        "the bridge owes the client exactly one error"
    );
    assert_eq!(
        responses[0]["error"]["code"],
        serde_json::json!(PARSE_ERROR_CODE)
    );
    assert_eq!(
        responses[0]["id"],
        Value::Null,
        "a refused frame has no id to echo"
    );

    assert!(
        rig.lines_received_by_a().is_empty(),
        "backend A must receive nothing at all, got {:?}",
        rig.lines_received_by_a()
    );
    assert!(
        rig.lines_received_by_b().is_empty(),
        "backend B must receive nothing at all, got {:?}",
        rig.lines_received_by_b()
    );
}

/// THE DESYNCHRONIZATION TEST. A malformed line followed by two valid requests:
/// each request must receive ITS OWN response.
///
/// Against pre-fix code the malformed line was forwarded, each backend answered
/// it with an unread parseError, and the id-1 request then read that stale error
/// while id 2 read id 1's result — the exact skew Codex observed.
#[test]
fn malformed_line_does_not_desynchronize_the_session() {
    let rig = StubRig::new("malformed-desync");
    let responses = rig.drive(&[
        "{",
        r#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#,
        r#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}"#,
    ]);

    assert_eq!(responses.len(), 3, "one error plus one response per request");

    // The first response is the bridge's refusal; it is not correlated to any
    // request, so it carries a null id and must not be mistaken for one.
    assert_eq!(responses[0]["id"], Value::Null);
    assert!(responses[0].get("error").is_some());

    // Every subsequent response carries its OWN request's id. The stub echoes the
    // id it was asked with into `result.echo`, so a skew would show up as an echo
    // that disagrees with the envelope id.
    assert_eq!(responses[1]["id"], serde_json::json!(1));
    assert_eq!(responses[1]["result"]["echo"], serde_json::json!(1));
    assert_eq!(responses[2]["id"], serde_json::json!(2));
    assert_eq!(responses[2]["result"]["echo"], serde_json::json!(2));

    // And the malformed line reached neither backend, so neither had a stale
    // parseError sitting on its stdout to hand to the next reader.
    assert!(!rig.lines_received_by_a().iter().any(|l| l == "{"));
    assert!(!rig.lines_received_by_b().iter().any(|l| l == "{"));
}

/// Valid JSON that is not a JSON-RPC envelope is refused as invalidRequest and,
/// like a malformed frame, reaches no backend.
#[test]
fn non_envelope_json_is_rejected_and_not_forwarded() {
    let rig = StubRig::new("non-envelope");
    let marker = r#"{"hello":"world"}"#;
    let responses = rig.drive(&[marker]);

    assert_eq!(responses.len(), 1);
    assert_eq!(
        responses[0]["error"]["code"],
        serde_json::json!(INVALID_REQUEST_CODE)
    );
    assert_eq!(responses[0]["id"], Value::Null);

    assert!(rig.lines_received_by_a().is_empty());
    assert!(rig.lines_received_by_b().is_empty());
}

/// A GENUINE notification is unaffected: valid envelope, no id, still forwarded
/// to both backends, still no response to the client. The fix narrows the
/// notification path; it must not close it.
#[test]
fn genuine_notification_still_reaches_both_backends() {
    let rig = StubRig::new("genuine-notification");
    let notification = r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#;
    let responses = rig.drive(&[notification]);

    assert!(responses.is_empty(), "a notification is owed no response");
    assert_eq!(rig.lines_received_by_a(), vec![notification.to_string()]);
    assert_eq!(rig.lines_received_by_b(), vec![notification.to_string()]);
}

/// The ordinary path is untouched: a request gets its own response back with its
/// own id.
#[test]
fn normal_request_still_correlates() {
    let rig = StubRig::new("normal-request");
    let responses = rig.drive(&[
        r#"{"jsonrpc":"2.0","id":41,"method":"initialize","params":{}}"#,
        r#"{"jsonrpc":"2.0","id":42,"method":"initialize","params":{}}"#,
    ]);

    assert_eq!(responses.len(), 2);
    assert_eq!(responses[0]["id"], serde_json::json!(41));
    assert_eq!(responses[0]["result"]["echo"], serde_json::json!(41));
    assert_eq!(responses[1]["id"], serde_json::json!(42));
    assert_eq!(responses[1]["result"]["echo"], serde_json::json!(42));
}

// MARK: - The stub rig

/// The env var carrying each stub's log path.
const LOG_ENV_VAR: &str = "MOOT_BRIDGE_STUB_LOG";

// The settle sequence appended to every `drive()`, and the reason it exists.
//
// A notification is fire-and-forget: the bridge writes it and reads nothing
// back, so nothing in the protocol says when a stub has consumed it. That makes
// BOTH "the stub received it" and "the stub did NOT receive it" race the stub's
// own write. A REQUEST is not fire-and-forget — the bridge blocks until the stub
// answers, and because each stub is a single sequential reader, its answer
// proves it has already processed every earlier line. That is a real
// happens-before edge; a sleep never is.
//
// One request only synchronizes the PRIMARY, though — requests never reach the
// secondary. So the sequence barriers the primary, flips the primary with the
// bridge's own `bridge_set_primary` tool (handled inside the bridge, so it
// generates no backend traffic of its own), then barriers the new primary. After
// it, both stubs are known to have drained.
const BARRIER_A: &str = r#"{"jsonrpc":"2.0","id":99,"method":"initialize","params":{}}"#;
const SWITCH_TO_B: &str = r#"{"jsonrpc":"2.0","id":98,"method":"tools/call","params":{"name":"bridge_set_primary","arguments":{"backend":"stubB"}}}"#;
const BARRIER_B: &str = r#"{"jsonrpc":"2.0","id":97,"method":"initialize","params":{}}"#;

/// The stub backend: log every received line, then answer like a real JSON-RPC
/// server.
///
/// `fflush()` after every write is load-bearing — without it awk block-buffers
/// into the pipe and the bridge blocks forever on a response that has been
/// written but not yet flushed.
const STUB_PROGRAM: &str = r#"
# Stub MCP backend for the moot-bridge frame-rejection tests.
#
# Appends every line received to $MOOT_BRIDGE_STUB_LOG so a test can assert what
# did and did not reach the backend, then replies the way a real JSON-RPC server
# replies:
#   line with a numeric "id"      -> a result echoing that id
#   line with "method" and no id  -> a notification: no reply
#   anything else                 -> parseError with a null id. This is the unread
#     response that desynchronizes a session when the bridge forwards a frame it
#     should have refused, so the stub must produce it.
{
    log_path = ENVIRON["MOOT_BRIDGE_STUB_LOG"]
    print $0 >> log_path
    fflush(log_path)
    if (match($0, /"id"[ ]*:[ ]*[0-9]+/)) {
        id_text = substr($0, RSTART, RLENGTH)
        sub(/^"id"[ ]*:[ ]*/, "", id_text)
        printf "{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":{\"tools\":[],\"echo\":%s}}\n", id_text, id_text
    } else if (index($0, "\"method\"") > 0) {
        # a notification — a real backend sends nothing back
    } else {
        printf "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"stub backend: parse error\"}}\n"
    }
    fflush()
}
"#;

/// A bridge config wired to two stub backends, plus the temp dir holding their
/// logs.
///
/// The stubs are `/usr/bin/awk` scripts rather than mempalace-mcp / mootx01
/// because these tests need two things a real backend cannot give: a record of
/// exactly which lines reached the backend, and a guarantee the suite runs on a
/// machine where neither memory server is installed.
struct StubRig {
    root: PathBuf,
    config: BridgeConfig,
    log_a: PathBuf,
    log_b: PathBuf,
}

impl StubRig {
    fn new(label: &str) -> StubRig {
        // Unique per test: these run concurrently under cargo's threaded harness,
        // and two rigs sharing a log file would cross-assert.
        let root = std::env::temp_dir().join(format!(
            "moot-bridge-frame-rejection-{}-{}",
            std::process::id(),
            label
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("create rig dir");

        let script = root.join("stub.awk");
        std::fs::write(&script, STUB_PROGRAM).expect("write stub program");
        let log_a = root.join("backendA.log");
        let log_b = root.join("backendB.log");
        std::fs::write(&log_a, "").expect("create log A");
        std::fs::write(&log_b, "").expect("create log B");

        // The log path travels as an env-var prefix on the command string, which
        // RawMcpBackend splits off and sets on the child — the same mechanism the
        // real config uses for MOOTX01_DATA_DIR. Paths carry no spaces (the
        // command is whitespace-split), which the temp-dir naming guarantees.
        //
        // The verbs are never exercised: these tests issue no tools/call except
        // the bridge-owned bridge_set_primary, which never reaches a backend, so
        // nothing is ever classified or fanned out.
        let config_json = format!(
            r#"{{
              "backendA": {{
                "name": "stubA",
                "command": "{env}={log_a} /usr/bin/awk -f {script}",
                "verbMap": {{ "write": "stub_write", "query": "stub_query", "constantArgs": {{}} }}
              }},
              "backendB": {{
                "name": "stubB",
                "command": "{env}={log_b} /usr/bin/awk -f {script}",
                "verbMap": {{ "write": "stub_write", "query": "stub_query", "constantArgs": {{}} }}
              }},
              "primary": "stubA"
            }}"#,
            env = LOG_ENV_VAR,
            log_a = log_a.to_str().unwrap(),
            log_b = log_b.to_str().unwrap(),
            script = script.to_str().unwrap(),
        );
        let config: BridgeConfig =
            serde_json::from_str(&config_json).expect("stub config must decode");

        StubRig {
            root,
            config,
            log_a,
            log_b,
        }
    }

    /// Feeds `lines` to the bridge as a client would, then the settle sequence,
    /// and returns the responses to `lines` alone — the settle responses are
    /// verified and stripped here so a test never has to know they exist.
    fn drive(&self, lines: &[&str]) -> Vec<Value> {
        let mut all: Vec<&str> = lines.to_vec();
        all.extend_from_slice(&[BARRIER_A, SWITCH_TO_B, BARRIER_B]);
        let input = all.join("\n") + "\n";

        let mut out: Vec<u8> = Vec::new();
        let mut diagnostics: Vec<u8> = Vec::new();
        run_bridge(
            &self.config,
            BufReader::new(std::io::Cursor::new(input.into_bytes())),
            &mut out,
            &mut diagnostics,
        )
        .expect("run_bridge");

        let responses: Vec<Value> = String::from_utf8_lossy(&out)
            .lines()
            .filter(|l| !l.trim().is_empty())
            .filter_map(|l| serde_json::from_str(l).ok())
            .collect();

        // The settle sequence answered in order, which is what makes the log
        // assertions sound. If it did not, the rig itself is broken and no
        // conclusion drawn from the logs would be trustworthy.
        let n = responses.len();
        assert!(n >= 3, "settle sequence produced no responses: {responses:?}");
        let tail: Vec<&Value> = responses[n - 3..].iter().collect();
        assert_eq!(tail[0]["id"], serde_json::json!(99), "barrier A unanswered");
        assert_eq!(tail[1]["id"], serde_json::json!(98), "primary flip unanswered");
        assert_eq!(tail[2]["id"], serde_json::json!(97), "barrier B unanswered");

        responses[..n - 3].to_vec()
    }

    /// Every CLIENT line backend A actually received, in order. The assertion the
    /// mission asks for — "neither backend receives the line" — is a statement
    /// about backend stdin, which nothing but a stub can observe.
    ///
    /// The startup handshake and the settle barrier are the rig's own traffic,
    /// not the client's, so they are verified and stripped.
    fn lines_received_by_a(&self) -> Vec<String> {
        self.client_lines(&self.log_a, BARRIER_A)
    }
    /// Every CLIENT line backend B actually received, in order.
    fn lines_received_by_b(&self) -> Vec<String> {
        self.client_lines(&self.log_b, BARRIER_B)
    }

    fn client_lines(&self, path: &Path, barrier: &str) -> Vec<String> {
        let mut lines: Vec<String> = std::fs::read_to_string(path)
            .unwrap_or_default()
            .lines()
            .map(String::from)
            .collect();
        assert_eq!(
            lines.first().map(String::as_str),
            Some(self.handshake_line().as_str()),
            "every backend is handshaked at startup"
        );
        lines.remove(0);
        assert_eq!(
            lines.pop().as_deref(),
            Some(barrier),
            "the settle barrier must be the last line this backend saw"
        );
        lines
    }

    /// The startup handshake line every backend receives before any client
    /// traffic. `run_bridge` initializes both backends, so it is the first entry
    /// in every stub log and is not evidence of a forwarded client frame.
    fn handshake_line(&self) -> String {
        serde_json::json!({
            "jsonrpc": "2.0", "id": 0, "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": { "name": "moot-bridge", "version": "0.1.0" }
            }
        })
        .to_string()
    }
}

impl Drop for StubRig {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}
