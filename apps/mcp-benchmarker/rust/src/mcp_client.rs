//! mcp_client.rs — a minimal MCP client over one endpoint.
//!
//! Ports `MCPClient.swift`. The client speaks JSON-RPC 2.0 over MCP stdio
//! framing — one JSON object per line — launching the configured local command
//! and exchanging newline-delimited messages over its stdin/stdout. (The Swift
//! leg also offers an `sse` HTTP transport; the Rust leg's stdio transport is
//! the full-parity surface — see the parity note in the crate docs. An `Sse`
//! endpoint returns [`MCPError`] rather than silently succeeding.)
//!
//! The `initialize` handshake, monotonic request ids, the `tools/call` wrapper,
//! and result parsing (delegated to [`crate::mcp_result`]) all match the Swift
//! actor.
//!
//! MCP SECURITY BOUNDARY (matching Swift): the client only ever calls tools
//! named in the endpoint's verbMap. The stdio command is operator-supplied and
//! treated at CLI-argument trust level — split on whitespace and run via
//! `/usr/bin/env`, the same as the Swift leg.

use crate::config::{EndpointConfig, ResultFormat, Transport};
use crate::json_value::JsonValue;
use crate::mcp_result::{parse_tool_result, MCPToolResult};
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};

/// An error raised while talking to an MCP endpoint. Mirrors Swift `MCPError`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MCPError {
    pub description: String,
}

impl MCPError {
    fn new(description: impl Into<String>) -> MCPError {
        MCPError { description: description.into() }
    }
}

impl std::fmt::Display for MCPError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.description)
    }
}

impl std::error::Error for MCPError {}

/// The verb-driven tool-call surface the transfer/benchmark engines depend on.
/// Implemented by the live [`MCPClient`] and by test doubles so the engine flow
/// is exercised without a live server (matching how the Swift tests stay pure).
pub trait ToolCaller {
    /// Calls one tool by name with the given arguments and parses the result
    /// according to `format`. Mirrors Swift `MCPClient.callTool`.
    fn call_tool(
        &mut self,
        name: &str,
        arguments: BTreeMap<String, JsonValue>,
        format: &ResultFormat,
    ) -> Result<MCPToolResult, MCPError>;
}

/// A client bound to one MCP endpoint over stdio. Mirrors Swift `MCPClient`.
pub struct MCPClient {
    endpoint: EndpointConfig,
    process: Option<Child>,
    stdin: Option<ChildStdin>,
    stdout: Option<BufReader<std::process::ChildStdout>>,
    next_request_id: i64,
}

impl MCPClient {
    /// Creates a client for the endpoint. The transport is not brought up until
    /// [`connect`](Self::connect) is called.
    pub fn new(endpoint: EndpointConfig) -> MCPClient {
        MCPClient {
            endpoint,
            process: None,
            stdin: None,
            stdout: None,
            next_request_id: 1,
        }
    }

    /// Brings the transport up. For stdio this launches the process and
    /// performs the MCP `initialize` handshake. Mirrors Swift `MCPClient.connect`.
    pub fn connect(&mut self) -> Result<(), MCPError> {
        let command = match &self.endpoint.transport {
            Transport::Stdio { command } => command.clone(),
            Transport::Sse { .. } => {
                // The Rust leg ships the stdio transport at parity; an SSE
                // endpoint is rejected rather than silently no-op'd.
                return Err(MCPError::new(format!(
                    "sse transport not supported by the Rust leg for {}",
                    self.endpoint.name
                )));
            }
        };
        self.launch_stdio(&command)?;
        // MCP requires an initialize call before tool calls. Send it and ignore
        // the capabilities payload — the benchmarker only needs verbMap tools.
        let _ = self.send_request(
            "initialize",
            JsonValue::object([
                ("protocolVersion".to_string(), JsonValue::String("2024-11-05".to_string())),
                ("capabilities".to_string(), JsonValue::Object(BTreeMap::new())),
                (
                    "clientInfo".to_string(),
                    JsonValue::object([
                        ("name".to_string(), JsonValue::String("mcp-benchmarker".to_string())),
                        ("version".to_string(), JsonValue::String("0.1.0".to_string())),
                    ]),
                ),
            ]),
        )?;
        Ok(())
    }

    /// Tears down the stdio process, if any. Safe to call more than once.
    /// Mirrors Swift `MCPClient.disconnect`.
    pub fn disconnect(&mut self) {
        // Dropping stdin closes the write end (EOF to the child).
        self.stdin = None;
        self.stdout = None;
        if let Some(mut proc) = self.process.take() {
            let _ = proc.kill();
            let _ = proc.wait();
        }
    }

    fn launch_stdio(&mut self, command: &str) -> Result<(), MCPError> {
        // Split the command on whitespace into program + args; operator-supplied,
        // treated at CLI-argument trust level. Run via /usr/bin/env so an
        // env-var prefix is honored — matching the Swift leg.
        let parts: Vec<&str> = command.split(' ').filter(|p| !p.is_empty()).collect();
        let program = parts
            .first()
            .ok_or_else(|| MCPError::new(format!("empty stdio command for {}", self.endpoint.name)))?;

        let mut cmd = Command::new("/usr/bin/env");
        cmd.arg(program);
        for arg in &parts[1..] {
            cmd.arg(arg);
        }
        cmd.stdin(Stdio::piped());
        cmd.stdout(Stdio::piped());

        let mut child = cmd
            .spawn()
            .map_err(|e| MCPError::new(format!("failed to launch {}: {e}", self.endpoint.name)))?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| MCPError::new("no stdin pipe"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| MCPError::new("no stdout pipe"))?;
        self.stdin = Some(stdin);
        self.stdout = Some(BufReader::new(stdout));
        self.process = Some(child);
        Ok(())
    }

    /// Sends one JSON-RPC request and returns its `result` value. Throws on a
    /// JSON-RPC `error` object or a transport failure. Mirrors Swift
    /// `MCPClient.sendRequest`.
    fn send_request(&mut self, method: &str, params: JsonValue) -> Result<JsonValue, MCPError> {
        let id = self.next_request_id;
        self.next_request_id += 1;

        let envelope = JsonValue::object([
            ("jsonrpc".to_string(), JsonValue::String("2.0".to_string())),
            ("id".to_string(), JsonValue::Number(id as f64)),
            ("method".to_string(), JsonValue::String(method.to_string())),
            ("params".to_string(), params),
        ]);
        let request_data = envelope
            .to_vec()
            .map_err(|e| MCPError::new(format!("encode failed: {e}")))?;

        let response_data = self.send_stdio(&request_data)?;

        let response = JsonValue::from_slice(&response_data)
            .map_err(|e| MCPError::new(format!("decode failed: {e}")))?;
        if let Some(error) = response.get("error") {
            let message = error
                .get("message")
                .and_then(JsonValue::string_value)
                .unwrap_or("unknown JSON-RPC error");
            return Err(MCPError::new(format!(
                "JSON-RPC error from {}: {message}",
                self.endpoint.name
            )));
        }
        response
            .get("result")
            .cloned()
            .ok_or_else(|| MCPError::new(format!(
                "JSON-RPC response from {} had no result",
                self.endpoint.name
            )))
    }

    /// Writes one newline-delimited JSON-RPC message and reads one non-blank
    /// line back. MCP stdio framing is one JSON object per line. Mirrors Swift
    /// `MCPClient.sendStdio` + `readLine`.
    fn send_stdio(&mut self, request_data: &[u8]) -> Result<Vec<u8>, MCPError> {
        let stdin = self
            .stdin
            .as_mut()
            .ok_or_else(|| MCPError::new(format!("stdio transport not connected for {}", self.endpoint.name)))?;
        stdin
            .write_all(request_data)
            .and_then(|_| stdin.write_all(b"\n"))
            .and_then(|_| stdin.flush())
            .map_err(|e| MCPError::new(format!("stdio write failed: {e}")))?;

        let stdout = self
            .stdout
            .as_mut()
            .ok_or_else(|| MCPError::new(format!("stdio transport not connected for {}", self.endpoint.name)))?;
        loop {
            let mut line = String::new();
            let n = stdout
                .read_line(&mut line)
                .map_err(|e| MCPError::new(format!("stdio read failed: {e}")))?;
            if n == 0 {
                return Err(MCPError::new(format!(
                    "stdio stream closed by {} before a full message",
                    self.endpoint.name
                )));
            }
            let trimmed = line.trim_end_matches(['\n', '\r']);
            if trimmed.is_empty() {
                continue; // skip blank lines
            }
            return Ok(trimmed.as_bytes().to_vec());
        }
    }
}

impl ToolCaller for MCPClient {
    fn call_tool(
        &mut self,
        name: &str,
        arguments: BTreeMap<String, JsonValue>,
        format: &ResultFormat,
    ) -> Result<MCPToolResult, MCPError> {
        let params = JsonValue::object([
            ("name".to_string(), JsonValue::String(name.to_string())),
            ("arguments".to_string(), JsonValue::Object(arguments)),
        ]);
        let result = self.send_request("tools/call", params)?;
        Ok(parse_tool_result(&result, format))
    }
}

impl Drop for MCPClient {
    fn drop(&mut self) {
        self.disconnect();
    }
}
