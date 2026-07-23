//! The method router — dispatches JSON-RPC requests to handlers.
//!
//! Mirrors the Swift `ARIA_MCPDispatcher.route(_:)` method: handles
//! `initialize`, `ping`, `tools/list`, `tools/call`, `resources/list`,
//! and `prompts/list`. All other method names return a `methodNotFound` error.
//!
//! `tools/call` delegates to `crate::dispatch::dispatch_tool` which holds
//! the full tool dispatch table (federation, interface/maintenance, vault, recipe, lens tools).
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
use crate::sensitivity_grant_ledger::SensitivityGrantLedger;
use crate::surfaced_recall_ledger::SurfacedRecallLedger;
use crate::tool_list::build_tool_list;
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
    /// version-skew advisory surfaced by `moot_estate_ping` /
    /// `moot_estate_status` when the host detected a mismatch between an
    /// installed plugin (e.g. Claude Code's `mootx01@mootx01`) and this
    /// running binary. Empty string when no plugin is detected or its
    /// version matches — the common case, which omits the field entirely
    /// (see `run_estate_ping`/`run_estate_status` in `interface_tools.rs`).
    /// Computed once at server startup by the host binary (mootx01-cli's
    /// `serve` command); this kit never reads `~/.claude/plugins/` itself.
    pub(crate) version_skew: String,
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
}

impl Dispatcher {
    /// Construct from an estate registry, server identity, build serial, and
    /// version-skew advisory.
    ///
    /// `build_serial` is produced by `crate::build_serial::derive()` at
    /// server startup and carried unchanged for the lifetime of the server.
    /// It is surfaced by `moot_estate_ping` so drivers can confirm they are
    /// talking to the most recently compiled binary.
    ///
    /// `version_skew` is empty when the host detected no plugin/binary
    /// version mismatch — pass `""` from callers that have no
    /// skew to report (e.g. `aria-mcp-server`, which has no plugin concept).
    pub fn new(
        registry: EstateRegistry, name: &str, version: &str, build_serial: &str,
        version_skew: &str,
        monitoring_control: Option<std::sync::Arc<dyn crate::monitoring_control::MonitoringControl>>,
    ) -> Self {
        let tools = build_tool_list();
        Dispatcher {
            registry,
            server_name: name.to_owned(),
            server_version: version.to_owned(),
            tools,
            ledger: SurfacedRecallLedger::new(),
            vault_ledger: VaultJobLedger::new(),
            sensitivity_ledger: SensitivityGrantLedger::new(),
            build_serial: build_serial.to_owned(),
            version_skew: version_skew.to_owned(),
            // Wired post-construction via `with_update_advisory` — the Rust
            // equivalent of Swift's defaulted `updateAdvisoryProvider: nil`
            // initializer parameter, chosen so the many existing
            // `Dispatcher::new` call sites (tests included) stay unchanged.
            update_advisory: None,
            monitoring_control,
        }
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
        let args_map = arguments.as_object().cloned().unwrap_or_default();

        crate::dispatch::dispatch_tool_with_ledgers(
            name, &args_map, &self.registry, &self.ledger, &self.vault_ledger, &self.sensitivity_ledger,
            &self.build_serial, &self.version_skew,
            // Upstream-release advisory provider — evaluated by ping/status
            // only; None when the host wired none.
            self.update_advisory.as_ref(),
            // thread the monitoring-control seam so the
            // interface-tools layer can reach it without importing observer_sink.
            self.monitoring_control.as_deref(),
        )
    }
}
