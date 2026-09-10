//! The method router — dispatches JSON-RPC requests to handlers.
//!
//! Mirrors the Swift `ARIA_MCPDispatcher.route(_:)` method: handles
//! `initialize`, `ping`, `tools/list`, `tools/call`, `resources/list`,
//! and `prompts/list`. All other method names return a `methodNotFound` error.
//!
//! `tools/call` decodes and dispatches through the v2 surface (`crate::surface::SelectedSurface`)
//! which covers all 84 ARIA v2 tools. Unknown tool names are rejected with METHOD_NOT_FOUND.
//!
//! # Session ledger
//!
//! The `Dispatcher` owns a `SurfacedRecallLedger` that tracks which drawer ids
//! have been returned to the AI client by `moot_memory_search` in this session.
//! When a dereference verb (`moot_withdraw_memory`, `moot_update_memory`,
//! `moot_confirm_memory`, `moot_move_memory`) targets an id that is present in
//! the ledger, the tool runner calls `coordinator.mark_recall_used` to flip the
//! trace-row reward bit to 1.0 (B-10a / DESIGN_TRACE_REWARD_2026-06-12.md).
//!
//! Interior mutability: the ledger uses `Mutex` internally so `Dispatcher` stays
//! `&self` on `handle` (required by the single-threaded stdio loop).
//!
//! # Vault job ledger
//!
//! The `Dispatcher` also owns a `VaultJobLedger` that records completed vault
//! export/import jobs. `moot_vault_export` and `moot_vault_import` record a
//! completed `VaultJobRecord` in the ledger (Rust backend is synchronous).
//! `moot_vault_job` looks up the record by job ID. The ledger is bounded to
//! 100 entries to prevent unbounded memory growth in long-running servers.

use crate::estate_registry::EstateRegistry;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JSONRPCRequest, JSONRPCResponse, JsonValue};
use crate::mode_session_state::ModeSessionState;
use crate::sensitivity_grant_ledger::SensitivityGrantLedger;
use crate::estate_posture::EstatePosture;
use crate::surfaced_recall_ledger::SurfacedRecallLedger;
use crate::vault_tools::VaultJobLedger;

/// The complete set of MCP protocol versions this server implements, most
/// recent first. The first entry is returned to any client that requests an
/// unsupported or absent version.
///
/// Sources:
/// - "2025-11-25": Claude Desktop's current protocol version; backward-
///   compatible wire shape. The server responds with the same capabilities
///   shape for all three revisions.
/// - "2025-03-26": the MCP stable revision following 2024-11-05; adds
///   elicitation + audio content type; capabilities shape is unchanged.
/// - "2024-11-05": the initial stable MCP revision implemented by the ARIA_MCP
///   surface (tools, resources, prompts, logging).
///
/// Per the MCP specification §3 (Initialization):
///   "If the server does not support the client's requested version, it SHOULD
///    respond with its latest supported version. The client MUST then decide
///    whether to proceed or abort."
///
/// Parity: mirrors Swift `ARIA_MCPDispatcher.supportedProtocolVersions` exactly.
pub const SUPPORTED_PROTOCOL_VERSIONS: &[&str] = &["2025-11-25", "2025-03-26", "2024-11-05"];

/// Host-injected provider for the upstream-release advisory surfaced as an
/// `update_available:` line by `moot_estate_ping` / `moot_estate_status`.
/// Returns the advisory line (e.g. "v1.0.34 is available (installed 1.0.33)
/// — upgrade with `mootx01 upgrade`") or `None` when there is nothing to
/// say. The host owns rate limiting, timeouts, and the network boundary;
/// the kit only calls it from the two orientation tools and renders the
/// line. `Arc` because the dispatcher is shared across HTTP connection
/// threads. Rust twin of Swift's `ToolDispatcher.updateAdvisoryProvider`.
pub type UpdateAdvisoryProvider = std::sync::Arc<dyn Fn() -> Option<String> + Send + Sync>;

/// The method router and tool registry. Owns the estate registry and
/// the tool list; dispatches each inbound request to the right handler.
pub struct Dispatcher {
    pub(crate) registry: EstateRegistry,
    server_name: String,
    server_version: String,
    tools: serde_json::Value,
    /// The compile-time selected public surface. Its decoder admits v2 calls
    /// before legacy policy, teachme, and session processing.
    surface: crate::surface::SelectedSurface,
    /// Session-scoped ledger of drawer ids surfaced by `moot_memory_search`.
    /// Consulted by dereference verbs to trigger reward-trace marking (B-10a).
    pub(crate) ledger: SurfacedRecallLedger,
    /// Process-scoped ledger of completed vault export/import jobs.
    /// `moot_vault_export` / `moot_vault_import` write here on completion;
    /// `moot_vault_job` reads by job ID. Bounded to 100 entries.
    vault_ledger: VaultJobLedger,
    /// sensitivity unlock grant ledger. Process-scoped, RAM-only —
    /// constructed fresh exactly once per `Dispatcher` (i.e. once per
    /// `mootx01 serve` process), so a daemon restart drops any live grant
    /// by construction, mirroring Swift `ToolDispatcher.sensitivityUnlockLedger`.
    /// `pub(crate)` so `http_server.rs` can access it for the control routes
    /// that are structurally outside the JSON-RPC/MCP surface.
    pub(crate) sensitivity_ledger: SensitivityGrantLedger,
    /// Build serial surfaced by `moot_estate_ping`. Computed once at
    /// server startup via `crate::build_serial::derive()` and stored here
    /// so the filesystem is not touched on every ping call.
    pub(crate) build_serial: String,
    /// Upstream-release advisory provider: returns a one-line "a newer
    /// release exists" message, or `None` when there is nothing to say.
    /// Unlike `version_skew` this is a CLOSURE, not a startup-computed
    /// string: the resident daemon is long-lived and releases ship while
    /// it is running, so freshness requires evaluation at call time. The
    /// host owns rate limiting and the network boundary (mootx01-cli's
    /// `UpdateAdvisor` — this kit never touches the network); the kit only
    /// renders the returned line. Evaluated in `moot_estate_ping` /
    /// `moot_estate_status` ONLY, mirroring Swift's
    /// `ToolDispatcher.updateAdvisoryProvider`. `None` (the default) means
    /// the host wired no provider — stdio one-shots and the aria-mcp dev
    /// server.
    pub(crate) update_advisory: Option<UpdateAdvisoryProvider>,
    /// Injection seam for daemon telemetry monitoring state.
    ///
    /// `None` when no stats store is configured (stdio mode, test harnesses,
    /// provision-less contexts). The concrete type lives in the serve host
    /// (`StatsStoreMonitoringControl` in `monitoring_control.rs`), which wraps
    /// `observer_sink::StatsStore`. AriaMcpKit never imports observer_sink directly —
    /// the trait keeps the dependency boundary clean.
    pub(crate) monitoring_control: Option<std::sync::Arc<dyn crate::monitoring_control::MonitoringControl>>,
    /// Per-session mode sticky state and coaching counters.
    ///
    /// One instance per `Dispatcher` (= one per `mootx01 serve` process for stdio,
    /// or one per HTTP dispatcher for HTTP). Uses `Mutex` for interior mutability
    /// so `Dispatcher::handle` stays `&self`. Mirrors Swift `ToolDispatcher.modeSessionState`.
    mode_session_state: ModeSessionState,
    /// Live or frozen. A frozen dispatcher refuses every tool in
    /// `tool_mutation_inventory`, runs `moot_memory_search` with internal
    /// origin (no recall-trace rows, no dreaming enqueue), and skips the
    /// reward mark in `note_usage`. `new` derives it from `MOOTX01_FROZEN`
    /// in the process environment (the CLI translates `--frozen` into that
    /// variable before the runtime starts); `with_posture` overrides it for
    /// hosts and tests that hold the posture explicitly. One process, one
    /// posture. Mirrors Swift `ToolDispatcher.posture`.
    posture: EstatePosture,
    /// Whether the Anthropic memory_20250818 adapter (`memory` tool) is
    /// enabled for this serve session. Derived once in `new` from the
    /// `MOOTX01_MEMORY_TOOL` env var — matching the posture pattern so the
    /// process environment is never consulted per-call inside `dispatch_memory`.
    /// Tests set this via `with_memory_tool_enabled` so no env mutation is needed.
    /// Mirrors Swift `ToolDispatcher.memoryToolEnabled`.
    memory_tool_enabled: bool,
}

impl Dispatcher {
    /// Construct from an estate registry, server identity, and build serial.
    ///
    /// `build_serial` is produced by `crate::build_serial::derive()` at
    /// server startup and carried unchanged for the lifetime of the server.
    /// It is surfaced by `moot_estate_ping` so drivers can confirm they are
    /// talking to the most recently compiled binary.
    ///
    /// `Dispatcher` does not take a version-skew advisory: it does not read
    /// one anywhere in the v2 request path (`self.surface.execute` never
    /// receives it). The version-skew advisory that `moot_estate_ping`/
    /// `moot_estate_status` actually render comes from the `version_skew:
    /// &str` argument threaded separately through `interface_tools::dispatch`
    /// (see `runtime.rs`).
    pub fn new(
        registry: EstateRegistry, name: &str, version: &str, build_serial: &str,
        monitoring_control: Option<std::sync::Arc<dyn crate::monitoring_control::MonitoringControl>>,
    ) -> Self {
        let surface = crate::surface::SelectedSurface::selected(
            crate::tool_list::vault_enabled(),
            crate::tool_list::memory_enabled(),
        );
        let tools = surface.catalog().clone();
        Dispatcher {
            registry,
            server_name: name.to_owned(),
            server_version: version.to_owned(),
            tools,
            surface,
            ledger: SurfacedRecallLedger::new(),
            vault_ledger: VaultJobLedger::new(),
            sensitivity_ledger: SensitivityGrantLedger::new(),
            build_serial: build_serial.to_owned(),
            // Wired post-construction via `with_update_advisory` — the Rust
            // equivalent of Swift's defaulted `updateAdvisoryProvider: nil`
            // initializer parameter, chosen so the many existing
            // `Dispatcher::new` call sites (tests included) stay unchanged.
            update_advisory: None,
            monitoring_control,
            // Spec defaults: sticky_enabled = true, coaching_calls_x = 25.
            // Overridden on the first tool call by provisioned_modes_config
            // read from the default estate's manifest (apply_preferences).
            mode_session_state: ModeSessionState::new(),
            posture: EstatePosture::from_process_environment(),
            // Resolved once here so dispatch_memory never re-reads the process
            // environment. Mirrors how posture is resolved once in new().
            memory_tool_enabled: crate::tool_list::memory_enabled(),
        }
    }

    /// Builder-style override of the frozen/live posture. The serve host
    /// derives the posture through the environment in `new`; tests and
    /// hosts that resolved the flag themselves pass it here so the process
    /// environment is never consulted (std::env is process-global and the
    /// test runner is parallel).
    pub fn with_posture(mut self, posture: EstatePosture) -> Self {
        self.posture = posture;
        self
    }

    /// Builder-style override of the memory-tool gate. Tests use this so no
    /// env-var mutation is needed — `std::env::set_var` is not thread-safe
    /// under the parallel Rust test runner. Mirrors `with_posture`.
    pub fn with_memory_tool_enabled(mut self, enabled: bool) -> Self {
        self.memory_tool_enabled = enabled;
        self
    }

    /// The posture this dispatcher serves under.
    pub fn posture(&self) -> EstatePosture {
        self.posture
    }

    /// Test seam: return the current sticky recall answer mode raw value.
    ///
    /// Exposes the session state's sticky Recall variant for dispatcher-level
    /// gate tests (modes_tests.rs test I). Not for production use.
    /// Note: not gated on #[cfg(test)] because integration tests in tests/
    /// compile against the library without the test feature flag.
    pub fn sticky_recall_answer_mode_for_test(&self) -> Option<&'static str> {
        self.mode_session_state.sticky_recall_answer_mode()
    }

    /// Builder-style injection of the upstream-release advisory provider
    /// (see `UpdateAdvisoryProvider`). Called by the serve hosts after
    /// `new`; `None` (the default) leaves ping/status without an
    /// `update_available` line.
    pub fn with_update_advisory(mut self, provider: Option<UpdateAdvisoryProvider>) -> Self {
        self.update_advisory = provider;
        self
    }

    /// Handle one parsed inbound request. Returns the response.
    /// (Notifications are already filtered out by the stdio loop before
    /// reaching this method.)
    pub fn handle(&self, request: &JSONRPCRequest) -> JSONRPCResponse {
        let id = request.id.clone().unwrap_or(JsonValue::Null);
        match self.route(request) {
            Ok(result) => JSONRPCResponse::ok(id, result),
            Err(e) => JSONRPCResponse::failure(id, e),
        }
    }

    fn route(&self, request: &JSONRPCRequest) -> Result<serde_json::Value, JSONRPCError> {
        match request.method.as_str() {
            "initialize" => self.initialize(request.params.as_ref()),
            "ping" => Ok(serde_json::json!({})),
            "tools/list" => Ok(serde_json::json!({ "tools": self.tools })),
            "tools/call" => self.tools_call(request.params.as_ref()),
            // Resources and prompts are advertised in v1.0 capabilities; the lists
            // are empty until v1.1 implements subscriptions and recipe-prompt surfacing.
            // Mirrors Swift Server.route() cases for "resources/list" and "prompts/list".
            "resources/list" => Ok(serde_json::json!({ "resources": [] })),
            "prompts/list" => Ok(serde_json::json!({ "prompts": [] })),
            _ => Err(JSONRPCError::new(
                JSONRPCErrorCode::METHOD_NOT_FOUND,
                format!("Method not found: {}", request.method),
            )),
        }
    }

    fn initialize(&self, params: Option<&JsonValue>) -> Result<serde_json::Value, JSONRPCError> {
        // MCP spec §3 (Initialization) — explicit protocol-version negotiation.
        //
        // Rule: if the client requests a version this server supports, echo it
        // back exactly. If the client requests an unsupported version, respond
        // with the server's latest supported version; the client then decides
        // whether to proceed or abort.
        //
        // This replaces the previous stub that echoed any version unconditionally,
        // which silently claimed support for contracts the server did not implement.
        //
        // If the client omits protocolVersion entirely (non-conforming client),
        // default to the latest supported version so the handshake still completes.
        //
        // Parity: mirrors Swift ARIA_MCPDispatcher.initialize(params:) exactly.
        let requested = params
            .and_then(|p| p.as_object())
            .and_then(|o| o.get("protocolVersion"))
            .and_then(|v| v.as_str());

        let negotiated = match requested {
            Some(v) if SUPPORTED_PROTOCOL_VERSIONS.contains(&v) => v.to_owned(),
            // Unsupported or absent version → respond with latest per MCP spec §3.
            _ => SUPPORTED_PROTOCOL_VERSIONS[0].to_owned(),
        };

        Ok(serde_json::json!({
            "protocolVersion": negotiated,
            "capabilities": {
                "tools": {},
                // Resources and prompts are advertised (v1.0 conformance per
                // ARIA_MCP_SPEC_v0.2 §9). Lists are empty until v1.1 implements
                // subscriptions and recipe-prompt surfacing. Advertising now
                // signals capability to clients so they light up those surfaces
                // when content arrives, and degrade cleanly to tools-only today.
                "resources": {
                    "subscribe": false,
                    "listChanged": false
                },
                "prompts": {
                    "listChanged": false
                },
                // Logging is advertised; the server logs to stderr per §5.
                "logging": {}
            },
            "serverInfo": {
                "name": self.server_name,
                "version": self.server_version
            }
        }))
    }

    fn tools_call(&self, params: Option<&JsonValue>) -> Result<serde_json::Value, JSONRPCError> {
        let obj = params.and_then(|p| p.as_object()).ok_or_else(|| {
            JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                "tools/call requires a 'name' parameter",
            )
        })?;
        let name = obj.get("name").and_then(|v| v.as_str()).ok_or_else(|| {
            JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                "tools/call requires a 'name' parameter",
            )
        })?;
        let arguments = obj
            .get("arguments")
            .cloned()
            .unwrap_or_else(|| JsonValue::Object(Default::default()));
        let args_map = match arguments.as_object() {
            Some(args) => args.clone(),
            None => {
                let message =
                    "tools/call arguments must be an object for the active ARIA v2 surface";
                return Err(JSONRPCError {
                    code: JSONRPCErrorCode::INVALID_PARAMS,
                    message: message.to_owned(),
                    data: Some(serde_json::json!({
                        "code": "invalid_argument",
                        "path": "arguments",
                        "message": message,
                        "correction": "Call moot_monitoring_status with an empty arguments object."
                    })),
                });
            }
        };

        // Surface admission: decode the typed v2 request before frozen policy
        // is evaluated. A name absent from the v2 catalog is rejected here
        // (METHOD_NOT_FOUND below) — `dispatch::route_tool` is never reached
        // from this handler; it is a v1 test-helper path called directly by
        // the integration suites, not by the running server.
        if let Some(request) = self.surface.decode(name, &args_map)? {
            // Stable typed effect drives posture before the request clock or
            // any session/estate state changes.
            if request.effect() == crate::surface::SurfaceEffect::Mutation
                && self.posture.is_frozen()
            {
                return Ok(crate::v2::render::refusal(
                    name,
                    &crate::v2::render::V2OperationalRefusal {
                        code: "estate_frozen".to_owned(),
                        message: EstatePosture::refusal_message(name),
                        retryable: false,
                        recovery: None,
                    },
                    &crate::v2::render::V2ResultMeta::incomplete(
                        &self.build_serial,
                        self.surface.capability_digest(),
                        crate::v2::operation::V2OperationEffect::Write,
                    ),
                ));
            }
            let now_millis = crate::dispatch::bench_clock_now();
            return crate::surface::execute(
                &self.surface,
                self.posture,
                request,
                &self.registry,
                &self.sensitivity_ledger,
                &self.ledger,
                &self.vault_ledger,
                self.monitoring_control.as_deref(),
                &self.build_serial,
                now_millis,
            );
        }

        // No tool matched the v2 catalog — surface.decode() already returns
        // METHOD_NOT_FOUND for unknown names; this branch is a safety net for
        // any gap between accepted_arg_keys and the match arms in decode().
        Err(JSONRPCError::new(
            JSONRPCErrorCode::METHOD_NOT_FOUND,
            format!("Unknown tool for active ARIA v2 surface: {name}"),
        ))
    }
}

#[cfg(test)]
mod frozen_command_tests {
    //! The session-state record is a private field, so the "refused before
    //! the call is recorded" half of the frozen `memory` contract is held
    //! here, in-crate. The integration half (estate bytes untouched, `view`
    //! proceeds, live `delete` still works, mint tools refused) lives in
    //! tests/frozen_posture_tests.rs.
    use super::*;

    fn frozen_dispatcher() -> Dispatcher {
        Dispatcher::new(EstateRegistry::new_inmemory(), "ARIA_MCP_Rust", "test", "test-serial", None)
            .with_posture(EstatePosture::Frozen)
    }

    fn call(dispatcher: &Dispatcher, tool: &str, arguments: serde_json::Value) -> serde_json::Value {
        let raw = serde_json::json!({
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": { "name": tool, "arguments": arguments }
        });
        let request = JSONRPCRequest::decode(&raw).expect("request must decode");
        serde_json::to_value(dispatcher.handle(&request)).expect("response must serialize")
    }

    #[test]
    fn frozen_memory_mutating_commands_are_refused_before_the_session_records_them() {
        let frozen = frozen_dispatcher();
        for command in [Some("create"), Some("str_replace"), Some("insert"), Some("delete"), Some("rename"), Some("frobnicate"), None] {
            let mut arguments = serde_json::json!({"path": "/memories/frozen.txt", "file_text": "must not land"});
            if let Some(command) = command {
                arguments["command"] = serde_json::Value::String(command.to_owned());
            }
            let response = call(&frozen, "memory", arguments);
            assert_eq!(response["result"]["isError"], serde_json::json!(true), "memory {command:?} must be refused; got {response}");
            assert_eq!(
                response["result"]["content"][0]["text"].as_str().unwrap_or(""),
                EstatePosture::refusal_message_for_command("memory", command)
            );
        }
        assert_eq!(
            frozen.mode_session_state.snapshot().total_calls, 0,
            "a refused memory command must not be recorded in session state"
        );
        // Control: a read the same dispatcher lets through is recorded, so
        // the zero above is the refusal's doing.
        let ping = call(&frozen, "moot_estate_ping", serde_json::json!({}));
        assert_ne!(ping["result"]["isError"], serde_json::json!(true), "moot_estate_ping is a read; got {ping}");
        assert_eq!(frozen.mode_session_state.snapshot().total_calls, 1);
    }

    #[test]
    fn v2_rejects_inactive_teachme_before_the_session_records_it() {
        let dispatcher = frozen_dispatcher();
        let response = call(
            &dispatcher,
            "moot_file_memory",
            serde_json::json!({"teachme": true, "mode": "Recall=exact"}),
        );
        assert_eq!(response["error"]["code"], serde_json::json!(-32601));
        assert_eq!(
            dispatcher.mode_session_state.snapshot().total_calls,
            0,
            "inactive v1 names must reject before v2 session handling",
        );
    }
}
