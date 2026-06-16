//! mcp_stdio_client — a minimal MCP client over a local stdio server. Rust
//! parallel of the Swift `MCPStdioClient`, narrowed to what the outbound pump
//! needs: launch the server, do the MCP `initialize` handshake, call
//! `tools/list`, and call `tools/call`.
//!
//! Wire protocol: JSON-RPC 2.0, newline-delimited (one JSON object per line) —
//! the MCP stdio framing. The Rust port is SYNCHRONOUS (blocking
//! `std::process` + `BufRead`), idiomatic for Rust and matching the
//! synchronous Rust `DrawerMapping::export`. Requests are serialized by
//! construction (one method takes `&mut self`), so request ids stay monotonic
//! and reads/writes never interleave — the same invariant the Swift actor
//! provides.
//!
//! Launch is via the shell so the command string may carry leading
//! `KEY=value` env assignments (the pump's scratch-palace integration test
//! points MemPalace at a /tmp palace via `MEMPALACE_PALACE_PATH`).

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};

/// An error raised while talking to the MCP server.
#[derive(Debug)]
pub enum McpClientError {
    /// Spawning or doing I/O with the server process failed.
    Io(std::io::Error),
    /// The server returned a JSON-RPC error or a malformed response.
    Protocol(String),
}

impl std::fmt::Display for McpClientError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            McpClientError::Io(e) => write!(f, "MCP client I/O error: {e}"),
            McpClientError::Protocol(m) => write!(f, "MCP protocol error: {m}"),
        }
    }
}

impl std::error::Error for McpClientError {}

impl From<std::io::Error> for McpClientError {
    fn from(e: std::io::Error) -> Self {
        McpClientError::Io(e)
    }
}

/// One tool result: the text content blocks the server returned, plus the raw
/// result JSON. Mirrors Swift `MCPCallResult`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpCallResult {
    /// The text payloads from the MCP `content` array, in order.
    pub text_blocks: Vec<String>,
    /// The raw result JSON (drift detection reads `tools/list` this way).
    pub raw_result_json: Vec<u8>,
}

/// A client bound to one local stdio MCP server. Spawn with [`connect`], then
/// call [`list_tools`]/[`call_tool`]; the child is killed on drop.
///
/// [`connect`]: McpStdioClient::connect
/// [`list_tools`]: McpStdioClient::list_tools
/// [`call_tool`]: McpStdioClient::call_tool
pub struct McpStdioClient {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<std::process::ChildStdout>,
    next_request_id: i64,
}

impl McpStdioClient {
    /// Spawn the server (via `sh -c` so env-var prefixes apply) and perform the
    /// MCP `initialize` handshake. `command` is the stdio launch command, e.g.
    /// `"mempalace-mcp"` or `"MEMPALACE_PALACE_PATH=/tmp/p mempalace-mcp"`.
    pub fn connect(command: &str) -> Result<Self, McpClientError> {
        let mut child = Command::new("sh")
            .arg("-c")
            .arg(command)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| McpClientError::Protocol("child has no stdin".to_owned()))?;
        let stdout = BufReader::new(
            child
                .stdout
                .take()
                .ok_or_else(|| McpClientError::Protocol("child has no stdout".to_owned()))?,
        );
        let mut client = Self {
            child,
            stdin,
            stdout,
            next_request_id: 1,
        };
        client.send_request(
            "initialize",
            serde_json::json!({
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": { "name": "mootx01-pump", "version": "1.0.0" }
            }),
        )?;
        Ok(client)
    }

    /// Call `tools/list` and return the raw result JSON.
    pub fn list_tools(&mut self) -> Result<Vec<u8>, McpClientError> {
        let result = self.send_request("tools/list", serde_json::json!({}))?;
        serde_json::to_vec(&result).map_err(|e| McpClientError::Protocol(e.to_string()))
    }

    /// Call one tool by name with the given arguments. Returns the text blocks
    /// from the MCP `content` array plus the raw result JSON.
    pub fn call_tool(
        &mut self,
        name: &str,
        arguments: serde_json::Value,
    ) -> Result<McpCallResult, McpClientError> {
        let result = self.send_request(
            "tools/call",
            serde_json::json!({ "name": name, "arguments": arguments }),
        )?;
        let mut text_blocks = Vec::new();
        if let Some(content) = result.get("content").and_then(|c| c.as_array()) {
            for block in content {
                if block.get("type").and_then(|t| t.as_str()) == Some("text") {
                    if let Some(text) = block.get("text").and_then(|t| t.as_str()) {
                        text_blocks.push(text.to_owned());
                    }
                }
            }
        }
        let raw = serde_json::to_vec(&result).map_err(|e| McpClientError::Protocol(e.to_string()))?;
        Ok(McpCallResult {
            text_blocks,
            raw_result_json: raw,
        })
    }

    // MARK: JSON-RPC core

    /// Send one JSON-RPC request and return its `result` value. Errors on a
    /// JSON-RPC `error` object or transport failure.
    fn send_request(
        &mut self,
        method: &str,
        params: serde_json::Value,
    ) -> Result<serde_json::Value, McpClientError> {
        let id = self.next_request_id;
        self.next_request_id += 1;
        let envelope = serde_json::json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        });
        let mut line = serde_json::to_vec(&envelope)
            .map_err(|e| McpClientError::Protocol(e.to_string()))?;
        line.push(b'\n'); // MCP stdio framing: one object per line.
        self.stdin.write_all(&line)?;
        self.stdin.flush()?;

        // Read newline-delimited lines until one carries a non-empty JSON
        // object; skip blank lines (the same tolerance the Swift reader has).
        loop {
            let mut buf = String::new();
            let n = self.stdout.read_line(&mut buf)?;
            if n == 0 {
                return Err(McpClientError::Protocol(
                    "stdio stream closed before a full message".to_owned(),
                ));
            }
            let trimmed = buf.trim();
            if trimmed.is_empty() {
                continue;
            }
            let response: serde_json::Value = serde_json::from_str(trimmed)
                .map_err(|e| McpClientError::Protocol(e.to_string()))?;
            if let Some(error) = response.get("error") {
                let message = error
                    .get("message")
                    .and_then(|m| m.as_str())
                    .unwrap_or("unknown JSON-RPC error");
                return Err(McpClientError::Protocol(format!("JSON-RPC error: {message}")));
            }
            return response
                .get("result")
                .cloned()
                .ok_or_else(|| McpClientError::Protocol("response had no result".to_owned()));
        }
    }
}

impl Drop for McpStdioClient {
    fn drop(&mut self) {
        // Best-effort teardown: close stdin then kill the child so a dropped
        // client never leaks a server process.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
