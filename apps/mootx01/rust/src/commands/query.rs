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

use crate::core::daemon_client;
use crate::exit;

pub fn run(verb: String, db: Option<String>, json: bool, args: Vec<String>) -> ExitCode {
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
/// is a string. A trailing key without a value is an error.
fn parse_kv_args(args: &[String]) -> Result<serde_json::Value, String> {
    let mut obj = serde_json::Map::new();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        let Some(key) = a.strip_prefix("--") else {
            return Err(format!(
                "mootx01 query: expected '--key value' pairs, got '{a}'."
            ));
        };
        let Some(raw) = it.next() else {
            return Err(format!("mootx01 query: '--{key}' requires a value."));
        };
        let value = serde_json::from_str::<serde_json::Value>(raw)
            .unwrap_or_else(|_| serde_json::Value::String(raw.clone()));
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

    #[test]
    fn kv_args_parse_json_and_strings() {
        let a: Vec<String> = ["--limit", "5", "--wing", "work", "--flag", "true"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let v = parse_kv_args(&a).unwrap();
        assert_eq!(v["limit"], 5);
        assert_eq!(v["wing"], "work");
        assert_eq!(v["flag"], true);
    }

    #[test]
    fn kv_args_reject_bare_value_and_trailing_key() {
        assert!(parse_kv_args(&["oops".to_string()]).is_err());
        assert!(parse_kv_args(&["--key".to_string()]).is_err());
    }
}
