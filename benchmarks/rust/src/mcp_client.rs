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
//!
//! TOKENIZATION IS A TRUST BOUNDARY IN ITSELF (#21, 2026-08-15): because the
//! split happens on plain whitespace and `/usr/bin/env` decides which token
//! is the program to exec (any leading `VAR=val`-shaped tokens are consumed
//! as environment assignments; the first token that isn't is the program),
//! any caller that builds `command` by interpolating a value it does not
//! fully control must ensure that value cannot introduce an extra
//! whitespace-delimited token — an embedded space could otherwise redirect
//! which program actually launches. `gauntlet_runner::gauntlet_endpoint_config`
//! is the concrete example: it validates its scratch-directory and resolved
//! binary path inputs for exactly this reason before calling into
//! [`launch_stdio`](MCPClient::launch_stdio). This module does not (and
//! cannot, generically) re-validate an already-assembled command string —
//! the obligation sits with the constructor.

use crate::config::{EndpointConfig, ResultFormat, Transport};
use crate::json_value::JsonValue;
use crate::mcp_result::{decode_jsonrpc_refusal, parse_tool_result, MCPRefusalInfo, MCPToolResult};
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

    /// Internal: sends one JSON-RPC request and returns the `result` value or an error tuple.
    ///
    /// The error tuple is `(description, refusal)` where `refusal` is `Some` only for
    /// -32602 errors that carry a valid `error.data` payload. All other errors return `None`
    /// for the refusal. Transport and encode failures also return `None`.
    ///
    /// Callers that need only the error description use `send_request`, which wraps this.
    /// `call_tool_with_refusal` uses this directly to surface the typed refusal contract.
    fn send_request_inner(
        &mut self,
        method: &str,
        params: JsonValue,
    ) -> Result<JsonValue, (String, Option<MCPRefusalInfo>)> {
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
            .map_err(|e| (format!("encode failed: {e}"), None))?;

        let response_data = self.send_stdio(&request_data)
            .map_err(|e| (e.description, None))?;

        let response = JsonValue::from_slice(&response_data)
            .map_err(|e| (format!("decode failed: {e}"), None))?;

        if let Some(error) = response.get("error") {
            let message = error
                .get("message")
                .and_then(JsonValue::string_value)
                .unwrap_or("unknown JSON-RPC error");
            // Attempt typed refusal decode for -32602 errors (invalid_argument).
            // `decode_jsonrpc_refusal` in mcp_result provides the full contract:
            // code, message, path, allowed (array), correction. For all other error
            // codes the refusal is None and the caller receives only the description.
            let refusal = decode_jsonrpc_refusal(error);
            return Err((
                format!("JSON-RPC error from {}: {message}", self.endpoint.name),
                refusal,
            ));
        }
        response
            .get("result")
            .cloned()
            .ok_or_else(|| {
                (
                    format!("JSON-RPC response from {} had no result", self.endpoint.name),
                    None,
                )
            })
    }

    /// Sends one JSON-RPC request and returns its `result` value. Throws on a
    /// JSON-RPC `error` object or a transport failure. Mirrors Swift `MCPClient.sendRequest`.
    ///
    /// For -32602 errors where the typed refusal contract is needed, use
    /// `call_tool_with_refusal` instead — that method returns `MCPToolResult.refusal`
    /// rather than encoding the error class in a description string.
    fn send_request(&mut self, method: &str, params: JsonValue) -> Result<JsonValue, MCPError> {
        self.send_request_inner(method, params)
            .map_err(|(desc, _)| MCPError::new(desc))
    }

    /// Calls one tool and returns the result with a typed refusal for -32602 errors
    /// instead of throwing. On a JSON-RPC -32602 error, returns an `MCPToolResult` with
    /// `is_error: true` and `refusal: Some(info)` carrying the full typed contract —
    /// `code`, `message`, `path`, `allowed` (as `Vec<String>`), `correction` — and no items.
    /// On transport failures and all other JSON-RPC error codes, this still throws.
    ///
    /// Use this method when the caller needs to inspect `path`, `allowed`, or `correction`.
    /// The existing `call_tool` (on the `ToolCaller` trait) still throws on -32602 so
    /// existing callers are unaffected.
    ///
    /// # Port parity note
    /// The Swift leg throws `MCPError` with a typed `refusal` field directly on -32602,
    /// so Swift callers can inspect the contract from the thrown error. The Rust thrown
    /// `MCPError` carries only a description string; the typed path is this method. Both
    /// ports expose the full typed contract; the vehicle differs. The asymmetry is a
    /// porting constraint: adding a `refusal` field to `MCPError` would break 156 struct
    /// literal constructions across 18 files.
    pub fn call_tool_with_refusal(
        &mut self,
        name: &str,
        arguments: BTreeMap<String, JsonValue>,
        format: &ResultFormat,
    ) -> Result<MCPToolResult, MCPError> {
        let params = JsonValue::object([
            ("name".to_string(), JsonValue::String(name.to_string())),
            ("arguments".to_string(), JsonValue::Object(arguments)),
        ]);
        match self.send_request_inner("tools/call", params) {
            Ok(result) => Ok(parse_tool_result(&result, format)),
            Err((_, Some(refusal))) => {
                // -32602 with typed refusal: surface as an isError MCPToolResult so
                // the caller can inspect path/allowed/correction without string surgery.
                Ok(MCPToolResult {
                    is_error: true,
                    refusal: Some(refusal),
                    ..Default::default()
                })
            }
            Err((desc, None)) => Err(MCPError::new(desc)),
        }
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
