//! The method router — dispatches JSON-RPC requests to handlers.
//!
//! Mirrors the Swift `ARIA_MCPDispatcher.route(_:)` method: handles
//! `initialize`, `ping`, `tools/list`, `tools/call`, `resources/list`,
//! and `prompts/list`. All other method names return a `methodNotFound` error.
//!
//! `tools/call` decodes and dispatches through the v2 surface (`crate::surface::SelectedSurface`)
//! which covers all 80 ARIA v2 tools. Unknown tool names are rejected with METHOD_NOT_FOUND.
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
use std::sync::Arc;
use crate::mode_session_state::ModeSessionState;
use crate::sensitivity_grant_ledger::SensitivityGrantLedger;
use crate::estate_posture::EstatePosture;
use crate::surfaced_recall_ledger::SurfacedRecallLedger;
use crate::vault_tools::VaultJobLedger;

/// The `memory` (Anthropic memory_20250818) tool schema for `tools/list`.
///
/// Matches Swift `ToolProjection.memoryTool()` exactly: same name, same
/// description string, same ten properties (command, path, file_text, old_str,
/// new_str, view_range, insert_line, insert_text, old_path, new_path) plus the
/// `estateID` property that Swift's `withEstateID` injects, and `required:
/// ["command"]`. `insert_line` is an integer schema; every other property is a
/// string schema.
///
/// `memory` stays OUT of the v2 typed registry and OUT of the v2 capability
/// digest. It is appended to `tools/list` here when `memory_tool_enabled` is
/// true, and intercepted in `tools_call` before `surface.decode` is reached.
fn memory_tool_schema() -> serde_json::Value {
    serde_json::json!({
        "name": "memory",
        "description": "Anthropic memory_20250818 compatible. Manages a virtual /memories filesystem backed by the MOOTx01 estate with governance: audit trail, lineage, sensitivity, confirmation state. Commands: view, create, str_replace, insert, delete, rename. While a restricted or secret grant is live (mootx01 unlock), create, str_replace and insert file at the grant's tier and the reply names it; a file filed restricted or secret is outside this tool's read posture until the grant lifts a grant-aware read such as moot_memory_get.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "command":     {"type": "string",  "description": "One of: view, create, str_replace, insert, delete, rename."},
                "path":        {"type": "string",  "description": "Virtual path under /memories."},
                "file_text":   {"type": "string",  "description": "File content for create."},
                "old_str":     {"type": "string",  "description": "Text to find for str_replace."},
                "new_str":     {"type": "string",  "description": "Replacement text for str_replace. Omit to delete old_str."},
                "view_range":  {"type": "string",  "description": "Optional 'start,end' for view line range. Use -1 for EOF."},
                "insert_line": {"type": "integer", "description": "Line number after which to insert (0 = beginning)."},
                "insert_text": {"type": "string",  "description": "Text to insert."},
                "old_path":    {"type": "string",  "description": "Source path for rename."},
                "new_path":    {"type": "string",  "description": "Destination path for rename."},
                "estateID":    {"type": "string",  "description": "Optional UUID of the open estate to target. Omit for the default estate."}
            },
            "required": ["command"]
        }
    })
}

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
    /// Plugin/binary version-skew advisory injected by the serve host.
    /// Empty string (the default, set in `new`) means no advisory to report.
    /// Passed to `surface::execute` → `execute_estate_diagnostics` →
    /// `EstateDiagnosticsContext.version_skew` where the service populates
    /// it into `EstatePingData` and `EstateStatusData` when non-empty.
    /// Mirrors Swift `ToolDispatcher.versionSkewAdvisory`.
    /// Injected via `with_version_skew`; hosts that have no plugin concept
    /// (reference stdio server, aria-mcp dev server) leave it at the default.
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
    /// Per-session mode sticky state and coaching counters.
    ///
    /// One instance per `Dispatcher` (= one per `mootx01 serve` process for stdio,
    /// or one per HTTP dispatcher for HTTP). Uses `Mutex` for interior mutability
    /// so `Dispatcher::handle` stays `&self`. Mirrors Swift `ToolDispatcher.modeSessionState`.
    mode_session_state: Arc<ModeSessionState>,
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
    /// Pre-decode transform registrations injected before argument decode.
    ///
    /// In production this is populated by `aria_v2_pre_decode_registrations` with the
    /// mode concern's transform hook, which strips the `mode` global modifier before
    /// decode and injects sticky recall `answer` for `moot_memory_search`. Tests may
    /// add their own registrations to exercise the transform phase with a custom hook.
    /// Mirrors Swift `ToolDispatcher.preDecodeRegistrations`.
    pub pre_decode_registrations: Vec<crate::v2::call_chain::V2ChainRegistration>,
}

impl Dispatcher {
    /// Construct from an estate registry, server identity, and build serial.
    ///
    /// `build_serial` is produced by `crate::build_serial::derive()` at
    /// server startup and carried unchanged for the lifetime of the server.
    /// It is surfaced by `moot_estate_ping` so drivers can confirm they are
    /// talking to the most recently compiled binary.
    ///
    /// `version_skew` defaults to an empty string (no advisory). Serve hosts
    /// that know the plugin has a different version from the binary inject it
    /// via `with_version_skew` after `new`. It is threaded through
    /// `surface::execute` → `execute_estate_diagnostics` →
    /// `EstateDiagnosticsContext.version_skew` and surfaces as the optional
    /// `version_skew` field of `moot_estate_ping` and `moot_estate_status`
    /// structured data when non-empty. Mirrors Swift
    /// `ToolDispatcher.versionSkewAdvisory`.
    pub fn new(
        registry: EstateRegistry, name: &str, version: &str, build_serial: &str,
        monitoring_control: Option<std::sync::Arc<dyn crate::monitoring_control::MonitoringControl>>,
    ) -> Self {
        let surface = crate::surface::SelectedSurface::selected(
            crate::tool_list::vault_enabled(),
            crate::tool_list::memory_enabled(),
        );
        // Resolve once so tools/list and the intercept gate use the same value.
        // Calling memory_enabled() twice (once for tools, once for the field)
        // is harmless in new() because the env is stable, but it opens a window
        // where a two-call sequence could theoretically differ. More importantly,
        // it means with_memory_tool_enabled() overrides the field while the
        // tools list was built from the env call — leaving them inconsistent.
        // Resolving here and using mem_enabled for both closes that gap at the
        // source. with_memory_tool_enabled() then keeps tools in sync when it
        // overrides the field after construction.
        let mem_enabled = crate::tool_list::memory_enabled();
        // Append the memory tool schema to tools/list when the adapter is
        // enabled. `memory` stays out of the v2 typed registry (and thus out
        // of the v2 capability digest), but must appear in tools/list when
        // MOOTX01_MEMORY_TOOL=1, matching Swift's ToolProjection.tools().
        let mut tools = surface.catalog().clone();
        if mem_enabled {
            if let Some(arr) = tools.as_array_mut() {
                arr.push(memory_tool_schema());
            }
        }
        // Create the mode session state as a local Arc first so we can share it
        // between the struct field and the pre-decode registration factory.
        // In Rust struct literals, one field cannot reference another being
        // initialized in the same expression.
        let mode_session_state = Arc::new(ModeSessionState::new());
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
            // Wired post-construction via `with_version_skew` — defaults to
            // empty (no advisory). Serve hosts that know of a plugin/binary
            // version mismatch inject it after `new`.
            version_skew: String::new(),
            // Wired post-construction via `with_update_advisory` — the Rust
            // equivalent of Swift's defaulted `updateAdvisoryProvider: nil`
            // initializer parameter, chosen so the many existing
            // `Dispatcher::new` call sites (tests included) stay unchanged.
            update_advisory: None,
            monitoring_control,
            // Spec defaults: sticky_enabled = true, coaching_calls_x = 25.
            // Overridden on the first tool call by provisioned_modes_config
            // read from the default estate's manifest (apply_preferences).
            mode_session_state: Arc::clone(&mode_session_state),
            posture: EstatePosture::from_process_environment(),
            // Set from the same resolved value used to build tools/list above,
            // so the catalog and the intercept gate start in agreement.
            memory_tool_enabled: mem_enabled,
            // In production, holds the mode concern's pre-decode transform hook
            // (strips the `mode` global modifier, injects sticky recall `answer`
            // for moot_memory_search).  Test code may replace this field entirely
            // to exercise the transform phase with a custom hook.
            pre_decode_registrations: crate::v2::chain_registry::aria_v2_pre_decode_registrations(
                Arc::clone(&mode_session_state),
            ),
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

    /// Builder-style override of the memory-tool gate. Updates both the
    /// intercept field and the tools/list catalog so they always agree.
    /// Tests use this so no env-var mutation is needed — `std::env::set_var`
    /// is not thread-safe under the parallel Rust test runner. Mirrors
    /// `with_posture`.
    pub fn with_memory_tool_enabled(mut self, enabled: bool) -> Self {
        self.memory_tool_enabled = enabled;
        // Keep tools/list in sync: the catalog and the intercept gate must
        // always agree. Add the schema when enabling (if absent); remove it
        // when disabling (if present).
        if let Some(arr) = self.tools.as_array_mut() {
            let present = arr.iter().any(|v| v["name"] == "memory");
            if enabled && !present {
                arr.push(memory_tool_schema());
            } else if !enabled && present {
                arr.retain(|v| v["name"] != "memory");
            }
        }
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

    /// Builder-style injection of the plugin/binary version-skew advisory.
    /// Called by serve hosts after `new` when the plugin version and the
    /// binary version are known to differ. Empty string (the default) means
    /// no advisory; a non-empty value surfaces as `version_skew` in the
    /// structured data of `moot_estate_ping` and `moot_estate_status`.
    /// Mirrors Swift `ToolDispatcher.versionSkewAdvisory`.
    pub fn with_version_skew(mut self, skew: String) -> Self {
        self.version_skew = skew;
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
        let _withheld_call = crate::v2::report_withheld::CallGuard::new();
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

        // `memory` is intercepted here — after args parsing, before the typed
        // v2 decoder — because `memory` stays out of the v2 registry. The v2
        // envelope would break Anthropic's reply-text contract and move the
        // capability digest.
        // Guard order matches Swift (ToolDispatch.swift): disabled-flag first,
        // then frozen per-command, then record, then adapter. The disabled flag
        // runs first because when the adapter is switched off the tool does not
        // exist for this serve at all — its frozen classification is not
        // reachable and must not be reported. Answering with a posture
        // classification for a tool that is switched off also states more about
        // the serve than a disabled tool should. The refusal shape is plain
        // isError:true — not the v2 render::refusal envelope.
        if name == "memory" {
            // Disabled-flag guard runs first. When the adapter is switched off
            // the tool does not exist for this serve; returning a frozen
            // classification here would be wrong. dispatch_memory handles the
            // flag and returns the disabled text when memory_tool_enabled is false.
            if !self.memory_tool_enabled {
                return crate::memory_adapter::dispatch_memory(
                    &args_map,
                    &self.registry,
                    self.memory_tool_enabled,
                    &self.sensitivity_ledger,
                );
            }
            // Frozen posture is evaluated per command using frozen_read_commands:
            // `view` proceeds, every other value (and missing or unknown command)
            // is refused before the adapter runs and before session state records
            // the call.
            if self.posture.is_frozen() {
                let command = args_map.get("command").and_then(|v| v.as_str());
                let read_cmds = crate::tool_mutation_inventory::frozen_read_commands("memory")
                    .unwrap_or(&[]);
                let is_read = command.map_or(false, |c| read_cmds.contains(&c));
                if !is_read {
                    return Ok(serde_json::json!({
                        "content": [{"type": "text", "text": EstatePosture::refusal_message_for_command("memory", command)}],
                        "isError": true
                    }));
                }
            }
            // Record the admitted call before running the adapter so the session
            // counter reflects every dispatched memory command. Disabled-flag and
            // frozen-refused calls return above and are not counted.
            self.mode_session_state.record_call("memory", None);
            return crate::memory_adapter::dispatch_memory(
                &args_map,
                &self.registry,
                self.memory_tool_enabled,
                &self.sensitivity_ledger,
            );
        }

        // Transform phase: run before decode so a hook can remove or add a key
        // before the strict argument decoder sees the arguments.  In production,
        // pre_decode_registrations holds the mode concern's transform hook (strips
        // the `mode` global modifier, injects sticky recall `answer` for
        // moot_memory_search).  Test code that replaces pre_decode_registrations
        // entirely still works because the field is pub — the replacement overrides
        // production hooks.  Construction fails only on duplicate concern names or
        // positions — programmer errors in the injected list — so expect is used.
        // `clone_transform_only` copies the Arc-wrapped hook, leaving ingress and
        // egress None — only the transform phase is exercised here.
        let transform_chain = crate::v2::call_chain::V2CallChain::new(
            self.pre_decode_registrations
                .iter()
                .map(|r| r.clone_transform_only())
                .collect(),
        ).expect("pre_decode_registrations: duplicate concern name or position");
        let transform_outcome = transform_chain.run_transform(
            name,
            JsonValue::Object(args_map.clone()),
        );
        // On error the prior arguments carry forward; the outcome always yields
        // the best available set of arguments.
        // Extract the BTreeMap from the transform outcome, falling back to the
        // original args when the transform returned a non-object value.
        let effective_args = match transform_outcome.arguments {
            JsonValue::Object(m) => m,
            _ => args_map.clone(),
        };

        // Surface admission: decode the typed v2 request before frozen policy
        // is evaluated.  The decoder receives the transform-phase output so a
        // pre-decode hook can strip a key the strict decoder rejects.
        // A name absent from the v2 catalog is rejected here (METHOD_NOT_FOUND
        // below) — `dispatch::route_tool` is never reached from this handler;
        // it is a v1 test-helper path called directly by the integration suites,
        // not by the running server.
        if let Some(request) = self.surface.decode(name, &effective_args)? {
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
            // Apply provisioned modes preferences on the first tool call of
            // this session. The once-guard (configured_from_estate bit) lives
            // inside ModeSessionState::apply_preferences. Falls back to spec
            // defaults (sticky_enabled=true, coaching_calls=25) when the
            // estate carries no manifest key or the coordinator lock fails.
            // Swift twin: ToolDispatch.swift `dispatchV2` inlines the same
            // guard (`if !modeSessionState.configuredFromEstate`) at the call
            // site rather than extracting it as a named method.
            if !self.mode_session_state.is_configured_from_estate() {
                let manifest = self.registry.coord
                    .lock()
                    .ok()
                    .and_then(|coord| {
                        coord.provisioned_modes_config(&self.registry.default.handle).ok()
                    })
                    .unwrap_or_default();
                self.mode_session_state
                    .apply_preferences(manifest.sticky_enabled, manifest.coaching_calls);
            }

            // Build the per-call chain from the production factory.
            //
            // Construction fails only on a duplicate concern name or position —
            // both programmer errors in this hard-coded list. `expect` follows
            // the same infallible-programmer-error convention used elsewhere in
            // this codebase (e.g. capability_digest construction).
            //
            // The record (ingress) chain runs after the frozen guard so the
            // session counter does not advance on frozen refusals (which return
            // above) or on decode failures (which return before this branch).
            // The transform phase ran before decode; counting runs here because
            // a refused call is not a call.
            //
            // The request is cloned for the egress closure capture. The original
            // is moved into surface::execute below; the clone carries the decoded
            // argument data the coaching engine needs to check triggers (e.g.
            // query length for moot_memory_search).
            let chain = crate::v2::call_chain::V2CallChain::new(
                crate::v2::chain_registry::aria_v2_production_registrations(
                    request.clone(),
                    Arc::clone(&self.mode_session_state),
                )
            ).expect("chain construction fails only on programmer error in hard-coded registrations");

            // Record phase: the coaching hook calls record_call on admitted,
            // decoded calls.  Refused and decode-failed calls both return before
            // this point.  The ingress outcome is threaded to run_egress so each
            // concern's optional ingress-state is delivered to its egress hook.
            let ingress_outcome = chain.run_ingress(name, JsonValue::Object(effective_args.clone()));

            let now_millis = crate::dispatch::bench_clock_now();
            let result = crate::surface::execute(
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
                &self.version_skew,
                self.update_advisory.as_ref(),
            )?;

            // Egress: hint injection and periodic coaching block run inside the
            // coaching egress transform (see chain_registry.rs). The chain halts
            // at the first gate that fires; no gate registers in production.
            let egress_outcome = chain.run_egress(name, result, &ingress_outcome);
            return Ok(egress_outcome.result);
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
        // Enable the memory adapter so frozen-posture tests reach the
        // per-command gate. Without memory enabled the disabled-flag guard
        // fires first (correct behaviour), which would make frozen-posture
        // tests test the wrong path. Tests that need memory disabled call
        // with_memory_tool_enabled(false) themselves.
        Dispatcher::new(EstateRegistry::new_inmemory(), "ARIA_MCP_Rust", "test", "test-serial", None)
            .with_posture(EstatePosture::Frozen)
            .with_memory_tool_enabled(true)
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
        // Control: an admitted `memory view` through the same intercept must
        // increment total_calls to 1, proving the zero above is the refusal's
        // doing and that record_call is wired. A separate dispatcher is used so
        // the refusal loop's zero is not contaminated.
        let control = Dispatcher::new(EstateRegistry::new_inmemory(), "ARIA_MCP_Rust", "test", "test-serial", None)
            .with_posture(EstatePosture::Frozen)
            .with_memory_tool_enabled(true);
        let view = call(&control, "memory", serde_json::json!({"command": "view", "path": "/memories"}));
        assert_ne!(view["result"]["isError"], serde_json::json!(true), "memory view must be admitted under frozen; got {view}");
        assert_eq!(control.mode_session_state.snapshot().total_calls, 1,
            "an admitted memory command must be recorded in session state");
    }

    #[test]
    fn frozen_disabled_memory_returns_disabled_text_not_frozen_refusal() {
        // Pins the guard order: disabled-flag runs before frozen per-command.
        // When the adapter is switched off, the tool does not exist for this
        // serve at all; returning a frozen classification would be wrong and
        // would reveal serve posture for a tool the caller should not see.
        let dispatcher = Dispatcher::new(
            EstateRegistry::new_inmemory(), "ARIA_MCP_Rust", "test", "test-serial", None,
        )
        .with_posture(EstatePosture::Frozen)
        .with_memory_tool_enabled(false);
        let response = call(
            &dispatcher,
            "memory",
            serde_json::json!({"command": "create", "path": "/memories/x.txt", "file_text": "x"}),
        );
        let text = response["result"]["content"][0]["text"]
            .as_str()
            .unwrap_or("");
        assert_eq!(
            text,
            "memory tool is disabled; run `mootx01 enable memory-tool` to activate it",
            "disabled memory must return disabled text; got {response}"
        );
        assert!(
            !text.contains("frozen"),
            "disabled memory must NOT return frozen refusal; got {text}"
        );
    }

    #[test]
    fn v2_rejects_malformed_file_memory_arguments_before_the_session_records_it() {
        let dispatcher = frozen_dispatcher();
        let response = call(
            &dispatcher,
            "moot_file_memory",
            serde_json::json!({"teachme": true, "mode": "Recall=exact"}),
        );
        // ARIA_MCP_INTERFACE.md § 16.1: a missing `subject` argument is
        // invalidParams (-32602), not methodNotFound (-32601). The call passes
        // {"teachme": true, "mode": "Recall=exact"} with no `subject`, and
        // `moot_file_memory` is a live v2 name so the call reaches the
        // decoder, which rejects the malformed arguments with invalidParams.
        // The old -32601 expectation was v1 carry-over from the § 15.3
        // dispatch order that put a teachme pre-check ahead of everything.
        assert_eq!(response["error"]["code"], serde_json::json!(-32602));
        assert_eq!(
            dispatcher.mode_session_state.snapshot().total_calls,
            0,
            "a malformed call on a live v2 name must reject before v2 session handling",
        );
    }

    // MARK: - GATE 2: Record phase placement (v2 choke point)

    /// A frozen-estate v2 MUTATION refusal returns before the record phase runs.
    /// The session call counter must remain at zero.
    ///
    /// `moot_file_memory` is the Rust twin of the Swift GATE 2 case.  It is a
    /// v2 mutation — the frozen guard fires inside the `if let Some(request)`
    /// branch, above the chain build and record-phase invocation.  The session
    /// counter must not advance.
    ///
    /// This test fails if the chain build or `chain.run_ingress` is moved above
    /// the `is_frozen()` guard in `tools_call` (the counter would advance to 1
    /// on the refused call, because the record phase would have run before the
    /// guard could reject the call).
    #[test]
    fn gate2_frozen_v2_mutation_refusal_leaves_session_counter_at_zero() {
        // Live estate, frozen posture — moot_file_memory is a mutation.
        let frozen = Dispatcher::new(
            EstateRegistry::new_inmemory(), "ARIA_MCP_Rust", "test", "test-serial", None,
        ).with_posture(EstatePosture::Frozen);

        let response = call(
            &frozen,
            "moot_file_memory",
            serde_json::json!({
                "content": "must not land",
                "subject": "gate2-frozen-test",
                "location": "gate2",
            }),
        );

        // The call must be refused with estate_frozen.
        assert_eq!(
            response["result"]["isError"],
            serde_json::json!(true),
            "frozen v2 mutation must return isError:true; got {response}"
        );
        assert_eq!(
            response["result"]["structuredContent"]["error"]["code"],
            serde_json::json!("estate_frozen"),
            "frozen v2 mutation must carry code estate_frozen; got {response}"
        );

        // The record-phase hook (record_call) must not have run.
        assert_eq!(
            frozen.mode_session_state.snapshot().total_calls,
            0,
            "frozen v2 mutation refusal must not advance the session counter"
        );
    }
}

#[cfg(test)]
mod partial_cue_frame_tests {
    use super::*;
    use locus_kit::{
        adjectives::AdjectiveSensitivity,
        drawer_operational::CaptureChannel,
        estate_types::LatticeAnchor,
        frames::CaptureFrame,
        provenance::Sensitivity,
    };

    fn call(dispatcher: &Dispatcher, arguments: serde_json::Value) -> serde_json::Value {
        let request = JSONRPCRequest::decode(&serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": "moot_lens_partial_cue", "arguments": arguments}
        }))
        .expect("request");
        serde_json::to_value(dispatcher.handle(&request)).expect("response")
    }

    fn capture(
        dispatcher: &Dispatcher,
        content: &str,
        udc: &str,
        adjective: AdjectiveSensitivity,
    ) -> String {
        let mut frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            "partial-cue-frame-test",
            LatticeAnchor::udc(udc),
            "aria-mcp-tests",
            "default",
        );
        frame.subject = Some(format!("{content} subject"));
        frame.sensitivity = adjective;
        frame.provenance_sensitivity = Sensitivity::Normal;
        dispatcher
            .registry
            .default
            .coord
            .lock()
            .expect("lock")
            .capture(
                &dispatcher.registry.default.handle,
                frame,
                crate::dispatch::wall_now(),
            )
            .expect("capture")
            .id
    }

    #[test]
    fn partial_cue_uses_caller_frame_for_recipe_and_hydration() {
        let dispatcher = Dispatcher::new(
            EstateRegistry::new_inmemory_with(crate::estate_registry::EstateOpening::TRANSIENT),
            "ARIA_MCP_Rust",
            "test",
            "test-serial",
            None,
        )
        .with_posture(EstatePosture::Live);
        let anchor = capture(&dispatcher, "partial-cue frame anchor", "004", AdjectiveSensitivity::Normal);
        let peer = capture(&dispatcher, "partial-cue restricted peer", "530", AdjectiveSensitivity::Restricted);
        let arguments = serde_json::json!({
            "anchor_memory_id": anchor,
            "mode": "feelsLike",
            "limit": 5,
        });
        let locked = call(&dispatcher, arguments.clone());
        let locked_rows = locked["result"]["structuredContent"]["data"]["results"]
            .as_array()
            .expect("rows");
        assert!(!locked_rows.iter().any(|row| row["id"]
            .as_str()
            .is_some_and(|id| id.eq_ignore_ascii_case(&peer))));
        dispatcher.sensitivity_ledger.grant_restricted(crate::dispatch::wall_now());
        let granted = call(&dispatcher, arguments);
        let rows = granted["result"]["structuredContent"]["data"]["results"]
            .as_array()
            .expect("rows");
        let row = rows
            .iter()
            .find(|row| {
                row["id"]
                    .as_str()
                    .is_some_and(|id| id.eq_ignore_ascii_case(&peer))
            })
            .expect("restricted peer admitted and hydrated");
        assert_eq!(row["subject"].as_str(), Some("partial-cue restricted peer subject"));
        assert!(row.get("bestSpan").is_some());
    }
}

#[cfg(test)]
mod catalog_sync_tests {
    //! Regression gate for the `retain`/`push` branches in
    //! `with_memory_tool_enabled`.  This module reads the dispatcher's actual
    //! `tools/list` response — the same bytes a client sees — not the inventory
    //! or the surface catalog.
    //!
    //! It does NOT cover the `Dispatcher::new` env-var path: calling
    //! `with_memory_tool_enabled` bypasses the env-var read, so commenting out
    //! the append at dispatcher.rs:229-233 leaves this test green.  The
    //! production path is gated by
    //! `tests/memory_tool_env_gate_tests.rs`, which constructs via
    //! `Dispatcher::new` only and fails when that append is absent.
    use super::*;

    /// Make a `tools/list` request against the dispatcher and return the array.
    fn tools_list(dispatcher: &Dispatcher) -> Vec<serde_json::Value> {
        let raw = serde_json::json!({
            "jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}
        });
        let request = JSONRPCRequest::decode(&raw).expect("tools/list request must decode");
        let response = serde_json::to_value(dispatcher.handle(&request))
            .expect("tools/list response must serialize");
        response["result"]["tools"]
            .as_array()
            .expect("tools/list result must contain a `tools` array")
            .clone()
    }

    fn has_memory(tools: &[serde_json::Value]) -> bool {
        tools
            .iter()
            .any(|t| t.get("name").and_then(|n| n.as_str()) == Some("memory"))
    }

    /// Reads the dispatcher's actual tools/list response — not the inventory,
    /// not the surface catalog — and asserts the `memory` entry is present when
    /// enabled and absent when disabled.  The absolute counts (81 / 80) pin the
    /// full roster so any addition or removal shows up here.
    ///
    /// This pins the `retain`/`push` branches in `with_memory_tool_enabled`.
    /// It does NOT cover the `Dispatcher::new` env-var append: see
    /// `tests/memory_tool_env_gate_tests.rs` for that gate.
    #[test]
    fn dispatcher_catalog_includes_memory_tool_when_enabled_and_excludes_it_when_disabled() {
        let enabled = Dispatcher::new(
            EstateRegistry::new_inmemory(),
            "ARIA_MCP_Rust",
            "test",
            "test-serial",
            None,
        )
        .with_memory_tool_enabled(true);

        let disabled = Dispatcher::new(
            EstateRegistry::new_inmemory(),
            "ARIA_MCP_Rust",
            "test",
            "test-serial",
            None,
        )
        .with_memory_tool_enabled(false);

        let enabled_tools = tools_list(&enabled);
        let disabled_tools = tools_list(&disabled);

        // The `memory` entry is the sole difference between the two catalogs.
        assert_eq!(
            enabled_tools.len(),
            disabled_tools.len() + 1,
            "enabled tools/list must be exactly one entry longer than disabled; \
             enabled={}, disabled={}",
            enabled_tools.len(),
            disabled_tools.len(),
        );
        // Absolute counts pin the full roster: an unrelated addition or removal
        // will surface here before it can hide behind a relative-only assertion.
        assert_eq!(
            enabled_tools.len(),
            81,
            "enabled tools/list must have exactly 81 entries; got {}",
            enabled_tools.len(),
        );
        assert_eq!(
            disabled_tools.len(),
            80,
            "disabled tools/list must have exactly 80 entries; got {}",
            disabled_tools.len(),
        );
        assert!(
            has_memory(&enabled_tools),
            "enabled tools/list must contain a tool named `memory`",
        );
        assert!(
            !has_memory(&disabled_tools),
            "disabled tools/list must NOT contain a tool named `memory`",
        );
    }
}
