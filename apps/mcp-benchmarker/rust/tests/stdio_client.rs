//! stdio_client.rs — wire-level integration test for the stdio MCP client.
//!
//! Spawns a tiny mock MCP server (a shell script that reads newline-delimited
//! JSON-RPC requests and replies per line) and drives the real [`MCPClient`]
//! through `connect` (the `initialize` handshake) and a `tools/call`. This
//! proves the newline framing, monotonic id stream, and result parsing work
//! end-to-end against a live process — the one piece of the Rust leg with real
//! IO. The mock speaks the MemPalace `search` shape (`results` array under a
//! text block) so the parse path is exercised too.
//!
//! The mock is a `sh` script (always present) that echoes a canned `result`
//! for every request; it ignores the request id (the benchmarker matches
//! responses by transport ordering, not by id, exactly like the Swift leg).

use mcp_benchmarker_rs::config::{EndpointConfig, EndpointRole, ResultFormat, Transport, VerbMap};
use mcp_benchmarker_rs::mcp_client::{MCPClient, ToolCaller};
use std::collections::BTreeMap;
use std::io::Write;

/// Writes a mock MCP server script to a temp path and returns it. The script
/// reads one JSON line per request and prints one canned JSON-RPC response per
/// line. The first response (to `initialize`) and every later one are valid
/// JSON-RPC `result` envelopes; the `tools/call` reply carries a MemPalace
/// `search`-shaped payload in a text content block.
fn write_mock_server() -> std::path::PathBuf {
    let dir = std::env::temp_dir();
    let path = dir.join(format!("mock-mcp-{}.sh", std::process::id()));
    // Each `read` consumes one request line; we reply with a fixed result. The
    // payload's inner JSON is single-quoted-safe (no shell metachars).
    let script = r#"#!/bin/sh
# Mock MCP server: one canned JSON-RPC result per request line.
first=1
while IFS= read -r line; do
  if [ "$first" = "1" ]; then
    # initialize handshake reply
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05"}}'
    first=0
  else
    # tools/call reply: MemPalace search shape (results array in a text block)
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"{\"results\":[{\"text\":\"first hit\"},{\"text\":\"second hit\"}]}"}]}}'
  fi
done
"#;
    let mut f = std::fs::File::create(&path).expect("create mock script");
    f.write_all(script.as_bytes()).expect("write mock script");
    drop(f);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&path, perms).unwrap();
    }
    path
}

fn endpoint(command: &str) -> EndpointConfig {
    EndpointConfig {
        name: "mock".to_string(),
        transport: Transport::Stdio { command: command.to_string() },
        auth: None,
        verb_map: VerbMap::new(
            "mempalace_add_drawer",
            "mempalace_search",
            None,
            None,
            None,
            None,
            Some(BTreeMap::new()),
            Some(ResultFormat::JsonObjects { id_key: None, content_key: "text".to_string() }),
        ),
        role: EndpointRole::Both,
    }
}

#[test]
fn stdio_client_connects_and_calls_tool() {
    let script = write_mock_server();
    // Run the script through `sh` so it works regardless of the +x bit / OS.
    let command = format!("sh {}", script.display());
    let mut client = MCPClient::new(endpoint(&command));
    client.connect().expect("connect (initialize handshake) must succeed");

    let result = client
        .call_tool(
            "mempalace_search",
            {
                let mut m = BTreeMap::new();
                m.insert(
                    "query".to_string(),
                    mcp_benchmarker_rs::json_value::JsonValue::String("test".to_string()),
                );
                m
            },
            &ResultFormat::JsonObjects { id_key: None, content_key: "text".to_string() },
        )
        .expect("tools/call must succeed");

    // The MemPalace search shape parses to two content items, no ids.
    assert!(result.ordered_ids.is_empty());
    assert_eq!(
        result.items.iter().filter_map(|i| i.content.clone()).collect::<Vec<_>>(),
        vec!["first hit".to_string(), "second hit".to_string()]
    );

    client.disconnect();
    let _ = std::fs::remove_file(&script);
}
