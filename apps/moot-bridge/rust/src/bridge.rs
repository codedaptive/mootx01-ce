//! bridge.rs — the bridging MCP memory server (Rust twin of `BridgeServer.swift`).
//!
//! An AI client launches this process as its single memory MCP server. The bridge:
//!   1. initialize — both backends are handshaked at startup (in main.rs) before
//!      the loop, so the first write reaches two live, initialized servers.
//!   2. tools/list — returns the PRIMARY's tool list PLUS two bridge-owned tools:
//!      `bridge_set_primary { backend }` and `bridge_status`.
//!   3. WRITE-classified tools/call — forward to the primary verbatim (response,
//!      id-preserving, returns to the client) AND translate the call through the
//!      secondary's verbMap and fire it there. The secondary response is NOT
//!      returned; a secondary FAILURE is counted and swallowed.
//!   4. READ-classified (query) and ANY unclassifiable tools/call — primary only,
//!      verbatim, id-preserving. Unclassifiable calls are NOT blind-fanned out.
//!   5. bridge-owned calls — handled inside the bridge; never touch a backend.
//!      bridge_set_primary swaps which backend serves reads + whose response is
//!      returned, effective on the very next call.
//!   6. notifications — a VALID JSON-RPC envelope with no id is forwarded to
//!      BOTH backends, no response awaited.
//!   7. unreadable frames — a line that is not valid JSON, or that is valid JSON
//!      but not a JSON-RPC envelope, is REJECTED here: the client receives a
//!      JSON-RPC error (parseError -32700 / invalidRequest -32600, null id) and
//!      NO backend ever sees the line. The bridge is the boundary; a frame it
//!      cannot read is a frame the backends should never receive. Forwarding one
//!      as a notification would leave the backend's own parseError response
//!      unread on its stdout, and the next send_and_receive would consume that
//!      stale error instead of its own result — skewing every response from then
//!      on until the process restarts.
//!
//! SAFETY (dual-write rule): a WRITE fan-out re-issues the write to BOTH
//! backends — the whole point of the bridge. Both must be writable targets the
//! operator intends to populate. For tests: scratch backends only.

use crate::backend::RawMcpBackend;
use crate::config::VerbMap;
use crate::stats::BridgeStats;
use serde_json::{json, Value};
use std::time::Instant;

/// The classified call type for a tools/call, matched against a verbMap. Two
/// verbs are recognized; everything else is unclassifiable (primary-only).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BridgeCallType {
    Write,
    Query,
}

pub const SET_PRIMARY_TOOL: &str = "bridge_set_primary";
pub const STATUS_TOOL: &str = "bridge_status";

/// JSON-RPC 2.0 code for a frame that is not valid JSON at all.
pub const PARSE_ERROR_CODE: i64 = -32700;
/// JSON-RPC 2.0 code for valid JSON that is not a valid JSON-RPC envelope.
pub const INVALID_REQUEST_CODE: i64 = -32600;

/// What the bridge decides to do with one raw client line, decided BEFORE any
/// backend transport is touched.
///
/// There are THREE outcomes here, not two. Asking only "does it have an id?"
/// collapses a genuine id-less notification together with a frame that could not
/// be read at all, and routes both down the notification path — which is exactly
/// how a single malformed line desynchronizes a whole session.
#[derive(Debug, Clone, PartialEq)]
pub enum FrameDisposition {
    /// A valid JSON-RPC envelope carrying an `id`. Served on the request path
    /// with the client's id preserved. `method` and `id` are carried alongside
    /// the parsed value because the classifier has already proved both present,
    /// so no downstream site needs to re-check or supply a fallback.
    Request {
        parsed: Value,
        method: String,
        id: Value,
    },
    /// A valid JSON-RPC envelope with no `id`: a real notification. Forwarded to
    /// both backends; no response is owed to the client.
    Notification,
    /// Unreadable, or readable but not a JSON-RPC envelope. Answered at the
    /// bridge with a JSON-RPC error and forwarded to NO backend.
    Reject { code: i64, message: String },
}

/// A handle to one configured backend: its live transport, name, and verbMap.
pub struct BridgeBackend {
    pub transport: RawMcpBackend,
    pub name: String,
    pub verb_map: VerbMap,
}

/// The bridging MCP server. Owns the two backends and the mutable primary index;
/// the run loop is the single owner (one client line at a time), so no lock is
/// needed around the primary pointer.
pub struct BridgeServer {
    backends: Vec<BridgeBackend>,
    /// Index into `backends` of the current primary. Flipped by bridge_set_primary.
    primary_index: usize,
    stats: BridgeStats,
    /// Running counter for fresh secondary-request ids (disjoint id space).
    next_secondary_id: i64,
}

impl BridgeServer {
    pub fn new(backends: Vec<BridgeBackend>, primary_index: usize) -> BridgeServer {
        assert_eq!(backends.len(), 2, "bridge requires exactly two backends");
        assert!(primary_index < 2, "primary_index must be 0 or 1");
        BridgeServer {
            backends,
            primary_index,
            stats: BridgeStats::new(),
            next_secondary_id: 1,
        }
    }

    fn primary_idx(&self) -> usize {
        self.primary_index
    }
    fn secondary_idx(&self) -> usize {
        1 - self.primary_index
    }

    pub fn primary_name(&self) -> &str {
        &self.backends[self.primary_idx()].name
    }
    pub fn secondary_name(&self) -> &str {
        &self.backends[self.secondary_idx()].name
    }

    /// Consumes the server and returns the final stats snapshot (for the shutdown
    /// report) plus the backends so the caller can stop them.
    pub fn into_parts(self) -> (crate::stats::BridgeStatsSnapshot, Vec<BridgeBackend>) {
        (self.stats.snapshot(), self.backends)
    }

    /// Borrows the stats for an interim snapshot (status tool / periodic flush).
    pub fn stats(&self) -> &BridgeStats {
        &self.stats
    }

    // MARK: - Per-message handling

    /// Handles one client message end to end, returning the response line to
    /// write back to the client (None for a notification, which has no response).
    ///
    /// The three-way split is the whole point: reject / notify / request. A frame
    /// the bridge cannot read is answered here and forwarded nowhere, so a
    /// backend never has to reply to garbage the bridge would then fail to read
    /// back off its stdout.
    pub fn handle_message(&mut self, line: &str) -> Option<String> {
        let (parsed, method, id_value) = match Self::classify_frame(line) {
            // Rejected at the boundary: the client gets a JSON-RPC error and NO
            // backend sees the line. Draining a backend's stdout after the fact
            // would race legitimate traffic and would still have let the
            // malformed frame through, so the refusal happens before any write.
            FrameDisposition::Reject { code, message } => {
                return Some(Self::protocol_error_line(code, &message));
            }
            // A real notification: valid envelope, no id, so no response is owed.
            // Forward to BOTH backends so a backend that relies on, e.g.,
            // `notifications/initialized` stays in sync. Hoist the indices into
            // locals first — indexing mutably while a method call borrows `self`
            // would otherwise conflict under the borrow checker.
            FrameDisposition::Notification => {
                let pi = self.primary_idx();
                let si = self.secondary_idx();
                let _ = self.backends[pi].transport.send_notification(line);
                let _ = self.backends[si].transport.send_notification(line);
                return None;
            }
            FrameDisposition::Request { parsed, method, id } => (parsed, method, id),
        };

        match method.as_str() {
            "tools/list" => Some(self.handle_tools_list(line)),
            "tools/call" => {
                let tool_name = parsed
                    .get("params")
                    .and_then(|p| p.get("name"))
                    .and_then(|n| n.as_str())
                    .unwrap_or("")
                    .to_string();
                if tool_name == SET_PRIMARY_TOOL {
                    Some(self.handle_set_primary(Some(&parsed), id_value))
                } else if tool_name == STATUS_TOOL {
                    Some(self.handle_status(id_value))
                } else {
                    Some(self.handle_tool_call(line, Some(&parsed), &tool_name))
                }
            }
            // initialize and any other id-bearing method: forward to primary.
            _ => Some(self.forward_to_primary(line, &method)),
        }
    }

    // MARK: - Frame classification (the boundary)

    /// Classifies one raw client line into the bridge's three frame dispositions.
    ///
    /// The envelope test mirrors `JSONRPCRequest::decode` in AriaMcpKit
    /// (Swift `JSONRPC.swift:68-79`) exactly — an object, `jsonrpc` equal to the
    /// string `"2.0"`, and a string `method`. Failing the JSON parse is
    /// `parseError`; parsing but failing the envelope test is `invalidRequest`.
    /// The backends draw the same line, so a frame refused here receives the same
    /// answer it would have received had it been forwarded, minus the
    /// desynchronization. Collapsing the two codes into one would tell a client
    /// "bad JSON" when the JSON was fine and only the envelope was wrong.
    ///
    /// `id` is deliberately tested for PRESENCE, not for non-null: JSON-RPC 2.0
    /// permits an id to be a string, a number, or null, and an explicit
    /// `"id": null` is a request, not a notification.
    ///
    /// Pure and `pub` for direct unit testing without a live `BridgeServer`.
    pub fn classify_frame(line: &str) -> FrameDisposition {
        let parsed: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => {
                return FrameDisposition::Reject {
                    code: PARSE_ERROR_CODE,
                    message: "Parse error: client frame is not valid JSON".to_string(),
                }
            }
        };
        // A non-object (bare array, string, number, bool, null) fails every
        // lookup below, but the object test is written out so the envelope
        // contract is legible rather than implied by serde_json's Value::get.
        let is_envelope = parsed.is_object()
            && parsed.get("jsonrpc").and_then(|v| v.as_str()) == Some("2.0")
            && parsed.get("method").and_then(|v| v.as_str()).is_some();
        if !is_envelope {
            return FrameDisposition::Reject {
                code: INVALID_REQUEST_CODE,
                message: "Invalid Request: malformed JSON-RPC envelope".to_string(),
            };
        }
        let method = parsed
            .get("method")
            .and_then(|v| v.as_str())
            .expect("envelope test above proved `method` is a string")
            .to_string();
        match parsed.get("id").cloned() {
            None => FrameDisposition::Notification,
            Some(id) => FrameDisposition::Request { parsed, method, id },
        }
    }

    /// Forwards tools/list to the primary, splices the two bridge-owned tools into
    /// the returned tool array, and returns the relayed line. On any shape
    /// surprise it relays the primary's response verbatim.
    fn handle_tools_list(&mut self, line: &str) -> String {
        let pi = self.primary_idx();
        let start = Instant::now();
        let response = match self.backends[pi].transport.send_and_receive(line) {
            Ok(r) => r,
            Err(e) => return Self::transport_error_line(&e.to_string()),
        };
        let label = format!("{}.tools/list", self.backends[pi].name);
        self.stats.record_latency(start.elapsed().as_secs_f64(), &label);

        let mut root: Value = match serde_json::from_str(&response) {
            Ok(v) => v,
            Err(_) => return response,
        };
        let spliced = root
            .get_mut("result")
            .and_then(|r| r.get_mut("tools"))
            .and_then(|t| t.as_array_mut())
            .map(|tools| {
                tools.push(Self::bridge_set_primary_schema());
                tools.push(Self::bridge_status_schema());
            });
        if spliced.is_none() {
            return response;
        }
        serde_json::to_string(&root).unwrap_or(response)
    }

    /// Handles a backend tools/call: forward to primary (response → client), and
    /// for WRITE-classified calls translate + fan out to the secondary.
    fn handle_tool_call(&mut self, line: &str, parsed: Option<&Value>, tool_name: &str) -> String {
        let pi = self.primary_idx();
        let start = Instant::now();
        let response = match self.backends[pi].transport.send_and_receive(line) {
            Ok(r) => r,
            Err(e) => return Self::transport_error_line(&e.to_string()),
        };
        let label = format!("{}.tools/call", self.backends[pi].name);
        self.stats.record_latency(start.elapsed().as_secs_f64(), &label);

        // Classify against the PRIMARY's verbMap (the backend the client drives).
        let call_type = Self::classify_call(tool_name, &self.backends[pi].verb_map);
        // Only WRITE calls fan out. A read is served from the primary alone.
        if call_type != Some(BridgeCallType::Write) {
            return response;
        }

        let fresh_id = self.next_secondary_id;
        self.next_secondary_id += 1;
        let si = self.secondary_idx();
        let translated = Self::translate_call(
            parsed,
            BridgeCallType::Write,
            &self.backends[pi].verb_map,
            &self.backends[si].verb_map,
            fresh_id,
        );
        match translated {
            None => {
                // Could not extract the content to mirror — count as a failure so
                // stats stay honest, but never surface it.
                self.stats.record_secondary_failure();
            }
            Some(translated_line) => {
                let mirror_start = Instant::now();
                match self.backends[si].transport.send_and_receive(&translated_line) {
                    Ok(_) => {
                        let mlabel = format!("{}.tools/call.mirror", self.backends[si].name);
                        self.stats
                            .record_latency(mirror_start.elapsed().as_secs_f64(), &mlabel);
                    }
                    Err(_) => self.stats.record_secondary_failure(),
                }
            }
        }
        response
    }

    /// Forwards an arbitrary id-bearing method (e.g. initialize) to the primary.
    fn forward_to_primary(&mut self, line: &str, method: &str) -> String {
        let pi = self.primary_idx();
        let start = Instant::now();
        let response = match self.backends[pi].transport.send_and_receive(line) {
            Ok(r) => r,
            Err(e) => return Self::transport_error_line(&e.to_string()),
        };
        let label = format!("{}.{}", self.backends[pi].name, method);
        self.stats.record_latency(start.elapsed().as_secs_f64(), &label);
        response
    }

    // MARK: - Bridge-owned tools

    /// bridge_set_primary { backend }: flip which backend is primary, effective
    /// immediately, and confirm. Unknown backend → tool-result error.
    fn handle_set_primary(&mut self, parsed: Option<&Value>, id: Value) -> String {
        let requested = parsed
            .and_then(|v| v.get("params"))
            .and_then(|p| p.get("arguments"))
            .and_then(|a| a.get("backend"))
            .and_then(|b| b.as_str());
        let requested = match requested {
            Some(r) => r.to_string(),
            None => {
                return Self::tool_error_line(
                    &id,
                    "bridge_set_primary requires a `backend` string argument",
                )
            }
        };
        let new_index = self.backends.iter().position(|b| b.name == requested);
        match new_index {
            None => {
                let names: Vec<&str> = self.backends.iter().map(|b| b.name.as_str()).collect();
                Self::tool_error_line(
                    &id,
                    &format!(
                        "bridge_set_primary: unknown backend \"{}\" — configured backends are: {}",
                        requested,
                        names.join(", ")
                    ),
                )
            }
            Some(idx) => {
                let previous = self.backends[self.primary_idx()].name.clone();
                self.primary_index = idx;
                let confirmation = format!(
                    "primary is now \"{requested}\" (was \"{previous}\"); reads and returned \
                     responses now come from \"{requested}\", writes still fan out to both"
                );
                Self::tool_text_line(&id, &confirmation)
            }
        }
    }

    /// bridge_status: report current primary/secondary and per-backend stats.
    fn handle_status(&self, id: Value) -> String {
        let snap = self.stats.snapshot();
        let mut lines: Vec<String> = Vec::new();
        lines.push(format!("primary:   {}", self.primary_name()));
        lines.push(format!("secondary: {}", self.secondary_name()));
        let names: Vec<&str> = self.backends.iter().map(|b| b.name.as_str()).collect();
        lines.push(format!("backends:  {}", names.join(", ")));
        if snap.series.is_empty() {
            lines.push("stats:     (no traffic yet)".to_string());
        } else {
            lines.push("stats:".to_string());
            for s in &snap.series {
                lines.push(format!(
                    "  {}: mean {:.2} ms  p95 {:.2} ms  n={}",
                    s.label,
                    s.mean * 1000.0,
                    s.p95 * 1000.0,
                    s.total_count
                ));
            }
        }
        lines.push(format!(
            "secondary write failures (non-fatal): {}",
            snap.secondary_failure_count
        ));
        Self::tool_text_line(&id, &lines.join("\n"))
    }

    // MARK: - Classify + translate (pure, unit-tested)

    /// Classifies a tools/call by tool name against a verbMap. None when neither
    /// verb matches (unclassifiable → primary-only, no fan-out).
    pub fn classify_call(tool_name: &str, verb_map: &VerbMap) -> Option<BridgeCallType> {
        if tool_name == verb_map.write {
            Some(BridgeCallType::Write)
        } else if tool_name == verb_map.query {
            Some(BridgeCallType::Query)
        } else {
            None
        }
    }

    /// Translates a primary-side tools/call into a secondary-side tools/call:
    /// secondary tool name + secondary constantArgs + the variable arg mapped
    /// from the primary's arg-role key to the secondary's. `fresh_id` is the
    /// JSON-RPC id (never the client's). None when the content/query is absent.
    pub fn translate_call(
        client_parsed: Option<&Value>,
        call_type: BridgeCallType,
        primary_verb_map: &VerbMap,
        secondary_verb_map: &VerbMap,
        fresh_id: i64,
    ) -> Option<String> {
        let client_args = client_parsed?
            .get("params")?
            .get("arguments")?
            .as_object()?;

        // Start with the secondary's constant write-context.
        let mut secondary_args = serde_json::Map::new();
        for (k, v) in &secondary_verb_map.constant_args {
            secondary_args.insert(k.clone(), Value::String(v.clone()));
        }

        let secondary_tool = match call_type {
            BridgeCallType::Write => {
                let value = client_args.get(&primary_verb_map.content_arg)?;
                secondary_args.insert(secondary_verb_map.content_arg.clone(), value.clone());
                &secondary_verb_map.write
            }
            BridgeCallType::Query => {
                let value = client_args.get(&primary_verb_map.query_arg)?;
                secondary_args.insert(secondary_verb_map.query_arg.clone(), value.clone());
                &secondary_verb_map.query
            }
        };

        let envelope = json!({
            "jsonrpc": "2.0",
            "id": fresh_id,
            "method": "tools/call",
            "params": { "name": secondary_tool, "arguments": Value::Object(secondary_args) }
        });
        serde_json::to_string(&envelope).ok()
    }

    // MARK: - Bridge tool schemas

    pub fn bridge_set_primary_schema() -> Value {
        json!({
            "name": SET_PRIMARY_TOOL,
            "description": "Switch which memory backend is PRIMARY (serves reads and returns its \
                response to you). Writes always fan out to BOTH backends regardless. Effective \
                immediately, mid-session.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "backend": { "type": "string", "description": "The name of the backend to make primary." }
                },
                "required": ["backend"]
            }
        })
    }

    pub fn bridge_status_schema() -> Value {
        json!({
            "name": STATUS_TOOL,
            "description": "Report the current primary backend and a per-backend latency + \
                failure-count summary.",
            "inputSchema": { "type": "object", "properties": {} }
        })
    }

    // MARK: - Response builders

    fn tool_text_line(id: &Value, text: &str) -> String {
        let envelope = json!({
            "jsonrpc": "2.0", "id": id,
            "result": { "content": [ { "type": "text", "text": text } ], "isError": false }
        });
        serde_json::to_string(&envelope).unwrap_or_default()
    }

    fn tool_error_line(id: &Value, message: &str) -> String {
        let envelope = json!({
            "jsonrpc": "2.0", "id": id,
            "result": { "content": [ { "type": "text", "text": message } ], "isError": true }
        });
        serde_json::to_string(&envelope).unwrap_or_default()
    }

    /// A JSON-RPC PROTOCOL error for the client — an `error` member, not an
    /// `isError` tool result. Used only for frames the bridge refuses at the
    /// boundary; nothing is sent to any backend on this path.
    ///
    /// The id is null because a refused frame has no id the bridge can trust: it
    /// either failed to parse, or failed the envelope test, so any `id` bytes
    /// inside it are not a JSON-RPC id. JSON-RPC 2.0 prescribes a null id for
    /// exactly this case, and AriaMcpKit's `StdioServer` answers the same way —
    /// the bridge and the backends must give a client the same answer, or the
    /// client sees two different protocols depending on how far its frame
    /// happened to travel.
    ///
    /// This is distinct from `tool_error_line`, which reports bridge-TOOL misuse
    /// as a successful call carrying `isError: true`. A frame that is not a valid
    /// JSON-RPC message never reached a tool, so it cannot be reported as one.
    pub fn protocol_error_line(code: i64, message: &str) -> String {
        let envelope = json!({
            "jsonrpc": "2.0", "id": Value::Null,
            "error": { "code": code, "message": message }
        });
        serde_json::to_string(&envelope).unwrap_or_default()
    }

    /// A JSON-RPC error response for a transport failure on the primary path.
    /// id is null because the failure is detected after the client id is already
    /// consumed by the dead transport; the client treats it as a protocol error.
    fn transport_error_line(message: &str) -> String {
        let envelope = json!({
            "jsonrpc": "2.0", "id": Value::Null,
            "error": { "code": -32000, "message": format!("bridge: primary backend error: {message}") }
        });
        serde_json::to_string(&envelope).unwrap_or_default()
    }
}
