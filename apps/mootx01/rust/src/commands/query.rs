//! commands/query.rs — §4.6: one ARIA tool call from the command line.
//!
//! v1.0 transport: when the resident daemon is alive, POST the call over
//! loopback HTTP; otherwise spawn a short-lived `mootx01 serve` (stdio)
//! subprocess for the duration of the query. `--db` always uses the
//! subprocess path so the named estate is guaranteed (the resident daemon
//! serves its own estate).
//!
//! The verb is the ARIA tool name without the `moot_` prefix; remaining
//! `--key value` pairs become the tool arguments (values parsed as JSON when
//! they look like it, strings otherwise).

use std::io::{BufRead, BufReader, Write};
use std::process::{Command as Proc, ExitCode, Stdio};

use genius_locus_kit::EstateCatalog;

use crate::core::daemon_client;
use crate::exit;

pub fn run(verb: String, db: Option<String>, json: bool, args: Vec<String>) -> ExitCode {
    // `--db` is resolved by the catalog here, so a bad value fails in this
    // process with the catalog's message instead of inside the serve child.
    // The value itself is passed to serve unchanged; serve resolves it the
    // same way (a registered name, or `<dir>/<name>` for a transient estate).
    if let Some(value) = db.as_deref() {
        if let Err(e) = EstateCatalog::open_selecting(value) {
            eprintln!("mootx01 query: {e}");
            return ExitCode::from(exit::FAILURE);
        }
    }

    let tool = format!("moot_{verb}");
    let arguments = match parse_kv_args(&args) {
        Ok(a) => a,
        Err(msg) => {
            eprintln!("{msg}");
            return ExitCode::from(exit::FAILURE);
        }
    };

    let init = serde_json::json!({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "mootx01-query", "version": crate::CURRENT_VERSION}
        }
    });
    let call = serde_json::json!({
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": {"name": tool, "arguments": arguments}
    });

    // Transport select: live daemon (HTTP, stateless per frame) unless --db
    // pins a specific estate.
    let response = if db.is_none() && daemon_client::alive(daemon_client::resolved_port()) {
        let port = daemon_client::resolved_port();
        match daemon_client::post_frame(port, call.to_string().as_bytes()) {
            Ok((200, body)) => match serde_json::from_slice(&body) {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("mootx01 query: daemon returned non-JSON: {e}");
                    return ExitCode::from(exit::FAILURE);
                }
            },
            Ok((status, _)) => {
                eprintln!("mootx01 query: daemon returned HTTP {status}");
                return ExitCode::from(exit::FAILURE);
            }
            Err(e) => {
                eprintln!("mootx01 query: daemon request failed: {e}");
                return ExitCode::from(exit::FAILURE);
            }
        }
    } else {
        match subprocess_call(db.as_deref(), &init, &call) {
            Ok(v) => v,
            Err(msg) => {
                eprintln!("{msg}");
                return ExitCode::from(exit::FAILURE);
            }
        }
    };

    render(&response, json)
}

/// Spawn `mootx01 serve [--db name]` (stdio), send initialize + tools/call,
/// return the id=2 response.
fn subprocess_call(
    db: Option<&str>,
    init: &serde_json::Value,
    call: &serde_json::Value,
) -> Result<serde_json::Value, String> {
    let exe = std::env::current_exe().map_err(|e| format!("mootx01 query: {e}"))?;
    let mut cmd = Proc::new(exe);
    cmd.arg("serve");
    if let Some(name) = db {
        cmd.args(["--db", name]);
    }
    let mut child = cmd
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("mootx01 query: cannot spawn serve subprocess: {e}"))?;

    let mut stdin = child.stdin.take().expect("piped stdin");
    let stdout = child.stdout.take().expect("piped stdout");

    let send = (|| -> std::io::Result<()> {
        stdin.write_all(init.to_string().as_bytes())?;
        stdin.write_all(b"\n")?;
        stdin.write_all(call.to_string().as_bytes())?;
        stdin.write_all(b"\n")?;
        stdin.flush()
    })();
    if let Err(e) = send {
        let _ = child.kill();
        return Err(format!("mootx01 query: subprocess write failed: {e}"));
    }
    drop(stdin); // close → server exits after responding (stdin-closed loop)

    let mut result = None;
    for line in BufReader::new(stdout).lines() {
        let Ok(line) = line else { break };
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        if v.get("id").and_then(|i| i.as_i64()) == Some(2) {
            result = Some(v);
            break;
        }
    }
    let _ = child.wait();
    result.ok_or_else(|| "mootx01 query: no response from serve subprocess".to_string())
}

/// `--key value` pairs → JSON object. Values that parse as JSON (numbers,
/// bools, arrays, objects, quoted strings) are taken as such; anything else
/// is a string.
///
/// ## Conformance rules (parity with Swift `parseArguments`)
///
/// - A leading bare `--` is skipped (bash-style option terminator). This lets
///   `mootx01 query moot_tool -- --key value` work correctly.
/// - A bare `--` at any position other than the leading slot is rejected with
///   a named error (empty key), matching the intent of flag validation.
/// - A bare value (no `--` prefix) is rejected with an error.
/// - Flag-style: `--key` followed by another `--` argument or end-of-args
///   sets `key = true`, matching Swift `parseArguments` flag-style handling.
fn parse_kv_args(args: &[String]) -> Result<serde_json::Value, String> {
    let mut obj = serde_json::Map::new();
    // Skip a leading bare "--" (bash-style option terminator).
    // `mootx01 query moot_tool -- --key value` is idiomatic shell; without
    // this skip, strip_prefix("--") on "--" yields an empty key that silently
    // swallows the next argument as its value.
    let args = if args.first().map(|s| s.as_str()) == Some("--") {
        &args[1..]
    } else {
        args
    };
    let mut it = args.iter();
    while let Some(a) = it.next() {
        let Some(key) = a.strip_prefix("--") else {
            return Err(format!(
                "mootx01 query: expected '--key value' pairs, got '{a}'."
            ));
        };
        if key.is_empty() {
            // A non-leading bare "--": the leading-separator skip above consumed
            // the first one. Any further "--" is a usage error.
            return Err(
                "mootx01 query: bare '--' is only valid as the leading separator.".to_string(),
            );
        }
        // Flag-style: if the next token is absent or begins with "--", treat
        // the current key as a boolean flag (value = true). This mirrors Swift
        // `parseArguments`, which sets `result[key] = true` in the same case.
        let value = match it.as_slice().first() {
            Some(next) if !next.starts_with("--") => {
                let raw = it.next().unwrap();
                serde_json::from_str::<serde_json::Value>(raw)
                    .unwrap_or_else(|_| serde_json::Value::String(raw.clone()))
            }
            _ => serde_json::Value::Bool(true),
        };
        obj.insert(key.to_string(), value);
    }
    Ok(serde_json::Value::Object(obj))
}

/// Print the response. `--json` → the raw frame pretty-printed. Default →
/// the result.content[].text blocks joined; JSON-RPC errors go to stderr
/// with exit 1.
fn render(response: &serde_json::Value, json: bool) -> ExitCode {
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(response).unwrap_or_else(|_| response.to_string())
        );
        return ExitCode::from(if response.get("error").is_some() {
            exit::FAILURE
        } else {
            exit::OK
        });
    }
    if let Some(err) = response.get("error") {
        let msg = err.get("message").and_then(|m| m.as_str()).unwrap_or("error");
        eprintln!("mootx01 query: {msg}");
        return ExitCode::from(exit::FAILURE);
    }
    let texts: Vec<&str> = response
        .pointer("/result/content")
        .and_then(|c| c.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|i| i.get("text").and_then(|t| t.as_str()))
                .collect()
        })
        .unwrap_or_default();
    if texts.is_empty() {
        // No text content: fall back to the raw result.
        if let Some(result) = response.get("result") {
            println!(
                "{}",
                serde_json::to_string_pretty(result).unwrap_or_else(|_| result.to_string())
            );
        }
    } else {
        for t in texts {
            println!("{t}");
        }
    }
    ExitCode::from(exit::OK)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    // ─── existing conformance ────────────────────────────────────────────

    #[test]
    fn kv_args_parse_json_and_strings() {
        let v = parse_kv_args(&args(&["--limit", "5", "--wing", "work", "--flag", "true"])).unwrap();
        assert_eq!(v["limit"], 5);
        assert_eq!(v["wing"], "work");
        assert_eq!(v["flag"], true);
    }

    #[test]
    fn kv_args_reject_bare_value() {
        // A positional arg without "--" prefix is a usage error.
        assert!(parse_kv_args(&args(&["oops"])).is_err());
    }

    // ─── V3 conformance vectors (VAULT-FIX-01) ──────────────────────────
    // Parity with Swift `parseArguments`. Each vector is documented with
    // the corresponding Swift outcome to verify cross-port alignment.

    #[test]
    fn kv_args_leading_separator_is_skipped() {
        // ["--", "--key", "value"] → {"key": "value"}
        // Swift: result[""] = true, then {"key": "value"} — Rust is stricter
        // (skips "--" entirely rather than creating empty key).
        let v = parse_kv_args(&args(&["--", "--key", "value"])).unwrap();
        assert_eq!(v["key"], "value");
        assert!(v.get("").is_none(), "leading '--' must not insert empty key");
    }

    #[test]
    fn kv_args_lone_separator_yields_empty_object() {
        // ["--"] → {} (nothing to parse after the separator)
        let v = parse_kv_args(&args(&["--"])).unwrap();
        assert!(v.as_object().unwrap().is_empty(), "lone '--' must yield {{}}");
    }

    #[test]
    fn kv_args_non_leading_bare_separator_is_rejected() {
        // ["--key", "val", "--"] → error: non-leading "--" is a usage error.
        // This prevents silent swallowing of the argument after the second "--".
        assert!(
            parse_kv_args(&args(&["--key", "val", "--"])).is_err(),
            "non-leading '--' must be an error"
        );
    }

    #[test]
    fn kv_args_flag_style_trailing_key_is_true() {
        // ["--key"] → {"key": true} (flag-style, no value token follows)
        // Previously this was rejected with "requires a value" — the V3 fix
        // aligns with Swift `parseArguments` which sets result[key] = true.
        let v = parse_kv_args(&args(&["--key"])).unwrap();
        assert_eq!(v["key"], true, "--key alone must parse as flag (true)");
    }

    #[test]
    fn kv_args_flag_style_followed_by_another_flag() {
        // ["--verbose", "--limit", "5"] → {"verbose": true, "limit": 5}
        // When the next token starts with "--", current key is a flag.
        let v = parse_kv_args(&args(&["--verbose", "--limit", "5"])).unwrap();
        assert_eq!(v["verbose"], true, "--verbose must be a flag");
        assert_eq!(v["limit"], 5);
    }

    #[test]
    fn kv_args_separator_then_flag_style() {
        // ["--", "--key"] → {"key": true} (separator skipped, then flag-style)
        let v = parse_kv_args(&args(&["--", "--key"])).unwrap();
        assert_eq!(v["key"], true, "flag after separator must parse as true");
    }

    #[test]
    fn kv_args_separator_then_kv_pairs() {
        // ["--", "--a", "1", "--b", "hello"] → {"a": 1, "b": "hello"}
        let v = parse_kv_args(&args(&["--", "--a", "1", "--b", "hello"])).unwrap();
        assert_eq!(v["a"], 1);
        assert_eq!(v["b"], "hello");
    }
}
