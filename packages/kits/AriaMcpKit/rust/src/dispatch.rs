//! Top-level tool dispatch — maps a tool name to its handler.
//!
//! Routing order:
//!   0. teachme pre-check — intercepts `teachme:true` before any runner fires
//!   1. Federation tool (moot_federated_search)
//!   2. Interface tools (Tier 1–5 plus maintenance/admin tools)
//!   3. Vault tools (backed by vault-kit; Vault drift and candidate handling)
//!   3.5 Dataset tools (moot_file_dataset, moot_dataset_query, moot_dataset_stats; MX-TAB-7b)
//!   4. Recipe tools (moot_list_lenses, moot_synthesize, …)
//!   5. Lens tools (moot_lens_keystones … moot_lens_concepts)
//!   6. Unknown tool → methodNotFound error
//!   hint: appended to non-error results by CoachingEngine
//!
//! Protocol faults (unknown tool, missing required argument, malformed
//! UUID) surface as `JSONRPCError` (thrown as Err). Every failure of a
//! call that reached its runner — substrate refusals AND runner-thrown
//! `TOOL_DISPATCH_FAILURE` errors, which `surface_dispatch_failure`
//! converts at the funnel — surfaces as a tool-call result with
//! `isError: true`, matching the Swift discipline.

use std::collections::BTreeMap;

use crate::estate_registry::EstateRegistry;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JsonValue};
use crate::estate_posture::EstatePosture;
use crate::sensitivity_grant_ledger::SensitivityGrantLedger;
use crate::surfaced_recall_ledger::SurfacedRecallLedger;
use crate::vault_tools::VaultJobLedger;

/// Dispatch `name` with `args` against `registry`, `ledger`, and `vault_ledger`.
/// Returns the MCP `tools/call` result payload (a `serde_json::Value` with
/// `content` array and `isError` flag). Throws `JSONRPCError` for out-of-band
/// failures.
///
/// The `ledger` is the session-scoped `SurfacedRecallLedger` owned by the
/// `Dispatcher`. It is passed to `interface_tools::dispatch` so that:
///   - `moot_memory_search` can record surfaced drawer ids.
///   - Dereference verbs (`moot_withdraw_memory`, `moot_update_memory`,
///     `moot_confirm_memory`, `moot_move_memory`) can note usage and trigger
///     reward-trace marking (B-10a / DESIGN_TRACE_REWARD_2026-06-12.md).
///
/// The `vault_ledger` is the process-scoped `VaultJobLedger` owned by the
/// `Dispatcher`. It is passed to `vault_tools::dispatch_vault` so that:
///   - `moot_vault_export` and `moot_vault_import` can record completed jobs.
///   - `moot_vault_job` can look up completed job records by ID.
///
/// Routing order (mirrors Swift `ToolDispatcher.dispatch(_:_:)`):
///   0. teachme interception — returns guide before any runner fires
///   1. Federation tool (moot_federated_search)
///   2. Interface tools (Tier 1–5 plus maintenance/admin tools)
///   3. Vault tools (backed by vault-kit; Vault drift and candidate handling)
///   4. Recipe tools (moot_list_lenses, moot_synthesize, …)
///   5. Lens tools (moot_lens_keystones … moot_lens_concepts)
///   post-dispatch: hint injection via CoachingEngine
pub fn dispatch_tool(
    name: &str,
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
    ledger: &SurfacedRecallLedger,
) -> Result<serde_json::Value, JSONRPCError> {
    // monitoring_control: None — bare convenience entry point, no stats store.
    dispatch_tool_with_vault_ledger(name, args, registry, ledger, &VaultJobLedger::new(), "", "")
}

/// dispatch with an explicit, PERSISTENT sensitivity-unlock
/// grant ledger. This is the entry point `Dispatcher::tools_call` uses in
/// production — it is the one owned by the `Dispatcher` for the process
/// lifetime, so a live grant persists across calls within the same
/// `mootx01 serve` process (and is gone on restart, by construction, same
/// as Swift's `ToolDispatcher`).
///
/// Every OTHER public entry point in this file (`dispatch_tool`,
/// `dispatch_tool_with_vault_flag`, `dispatch_tool_with_vault_ledger`) is
/// left with its EXACT existing signature — each internally passes a
/// fresh, throwaway, always-locked `SensitivityGrantLedger::new()` to the
/// inner implementation. This keeps every existing call site (the ~180+
/// tests across `dispatch_tests.rs` that call those functions directly)
/// compiling unchanged; none of them exercise sensitivity-unlock gating,
/// so a throwaway ledger (equivalent to "no grant ever issued") preserves
/// their existing behavior exactly.
#[allow(clippy::too_many_arguments)] // production entry point threading every session-scoped ledger + advisory string; grouping would obscure which caller owns which state
pub fn dispatch_tool_with_ledgers(
    name: &str,
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
    ledger: &SurfacedRecallLedger,
    vault_ledger: &VaultJobLedger,
    sensitivity_ledger: &SensitivityGrantLedger,
    // Frozen or live: the runners that write on the read path (memory
    // search origin, reward marks) and `moot_estate_status` read it.
    posture: EstatePosture,
    build_serial: &str,
    version_skew: &str,
    // Upstream-release advisory provider — evaluated by ping/status only.
    // None when the host wired none (stdio one-shots, tests, aria-mcp dev).
    update_advisory: Option<&crate::dispatcher::UpdateAdvisoryProvider>,
    // monitoring seam, threaded to interface_tools::dispatch.
    // None when no stats store is wired (stdio, test harnesses, provision-less contexts).
    monitoring_control: Option<&dyn crate::monitoring_control::MonitoringControl>,
) -> Result<serde_json::Value, JSONRPCError> {
    dispatch_tool_with_vault_ledger_and_flag(
        name, args, registry, ledger, vault_ledger, sensitivity_ledger, posture,
        crate::tool_list::vault_enabled(), build_serial, version_skew,
        update_advisory, monitoring_control,
    )
}

/// Dispatch with an explicit vault-on flag. Used by tests that need to verify
/// vault-gating behaviour without mutating the process environment
/// (std::env::set_var is not thread-safe under the parallel Rust test runner).
/// Production code uses `dispatch_tool` / `dispatch_tool_with_vault_ledger`
/// which read the env var via `vault_enabled()`.
pub fn dispatch_tool_with_vault_flag(
    name: &str,
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
    ledger: &SurfacedRecallLedger,
    vault_on: bool,
) -> Result<serde_json::Value, JSONRPCError> {
    // Throwaway sensitivity ledger — see `dispatch_tool_with_ledgers`'s doc
    // comment for why every non-production entry point does this.
    // Monitoring control: None — test/non-production entry points have no stats store.
    dispatch_tool_with_vault_ledger_and_flag(
        name, args, registry, ledger, &VaultJobLedger::new(), &SensitivityGrantLedger::new(),
        EstatePosture::Live, vault_on, "", "", None, None,
    )
}

/// Internal dispatch entry point that accepts an explicit `vault_ledger`,
/// build serial, and version-skew advisory. Used by `Dispatcher::handle`
/// (passes the owned ledger, serial, and advisory) and by `dispatch_tool`
/// (passes a throwaway ledger and empty strings for callers that don't need
/// job tracking or build-serial/version-skew surfacing, such as test helpers
/// that call individual tools in isolation).
pub fn dispatch_tool_with_vault_ledger(
    name: &str,
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
    ledger: &SurfacedRecallLedger,
    vault_ledger: &VaultJobLedger,
    build_serial: &str,
    version_skew: &str,
) -> Result<serde_json::Value, JSONRPCError> {
    // Throwaway sensitivity ledger — see `dispatch_tool_with_ledgers`'s doc
    // comment for why every non-production entry point does this.
    // Monitoring control: None — non-production entry points have no stats store.
    dispatch_tool_with_vault_ledger_and_flag(
        name, args, registry, ledger, vault_ledger, &SensitivityGrantLedger::new(),
        EstatePosture::Live, crate::tool_list::vault_enabled(), build_serial, version_skew, None, None,
    )
}

/// Inner dispatch that accepts an explicit vault-on flag, build serial, and
/// version-skew advisory. This is the single implementation all entry points
/// delegate to. The `vault_on` flag controls whether vault tool calls are
/// routed to the vault backend or rejected with a clear refusal. Callers that
/// want env-var semantics pass `vault_enabled()`; callers that need
/// deterministic testing pass `true`/`false` directly. `build_serial` is
/// forwarded to `interface_tools::dispatch` so `moot_estate_ping` can include
/// it without touching the filesystem. `version_skew` is an
/// empty string when the host detected no plugin/binary version mismatch —
/// the common case — or the advisory text to surface verbatim in
/// `moot_estate_ping` / `moot_estate_status`.
#[allow(clippy::too_many_arguments)] // single inner impl all entry points delegate to; grouping would obscure which ledger/flag each callsite supplies
fn dispatch_tool_with_vault_ledger_and_flag(
    name: &str,
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
    ledger: &SurfacedRecallLedger,
    vault_ledger: &VaultJobLedger,
    sensitivity_ledger: &SensitivityGrantLedger,
    posture: EstatePosture,
    vault_on: bool,
    build_serial: &str,
    version_skew: &str,
    update_advisory: Option<&crate::dispatcher::UpdateAdvisoryProvider>,
    monitoring_control: Option<&dyn crate::monitoring_control::MonitoringControl>,
) -> Result<serde_json::Value, JSONRPCError> {
    let routed = route_tool(
        name, args, registry, ledger, vault_ledger, sensitivity_ledger, posture,
        vault_on, build_serial, version_skew, update_advisory, monitoring_control,
    );
    // Apply unrecognized-arg hint after surface_dispatch_failure so error
    // results (isError:true) also get the stderr log but not the appended
    // hint text — matching Swift ToolDispatcher.appendUnknownArgsHint.
    surface_dispatch_failure(name, routed)
        .map(|result| inject_unknown_args_hint(name, args, result))
}

/// Convert a runner's `TOOL_DISPATCH_FAILURE` into a tool result with
/// `isError:true`, and mirror the message to stderr. Every other outcome
/// passes through untouched.
///
/// A `TOOL_DISPATCH_FAILURE` means the call reached its runner and the
/// substrate (or an adapter under it) failed — an execution failure, not a
/// protocol fault. MCP clients render a thrown JSON-RPC error as a bare
/// "failed to call tool" and discard the message; an `isError` result puts
/// the description in front of the model so it can react. Matches the Swift
/// `ToolDispatcher.dispatch` catch-all discipline. The stderr mirror exists
/// because the daemon log otherwise records nothing for a failed tool call,
/// which makes field failures undiagnosable.
///
/// Protocol faults (`METHOD_NOT_FOUND`, `INVALID_PARAMS`, …) stay thrown —
/// those mean the call never reached a runner.
pub fn surface_dispatch_failure(
    name: &str,
    routed: Result<serde_json::Value, JSONRPCError>,
) -> Result<serde_json::Value, JSONRPCError> {
    match routed {
        // The message is emitted bare (no prefix): the Rust runners route
        // substrate refusals through this band, and Swift surfaces those same
        // refusals as bare `describe(error)` isError results — a prefix here
        // would diverge the legs' output for the same failure.
        Err(e) if e.code == JSONRPCErrorCode::TOOL_DISPATCH_FAILURE => {
            eprintln!("aria-mcp: tool {name} failed: {msg}", msg = e.message);
            Ok(error_result(&e.message))
        }
        other => other,
    }
}

/// Route `name` to its tool-group runner. Errors propagate raw — the caller
/// (`dispatch_tool_with_vault_ledger_and_flag`) owns converting
/// `TOOL_DISPATCH_FAILURE` into an `isError` result.
#[allow(clippy::too_many_arguments)] // mirrors the funnel signature it is extracted from
fn route_tool(
    name: &str,
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
    ledger: &SurfacedRecallLedger,
    vault_ledger: &VaultJobLedger,
    sensitivity_ledger: &SensitivityGrantLedger,
    posture: EstatePosture,
    vault_on: bool,
    build_serial: &str,
    version_skew: &str,
    update_advisory: Option<&crate::dispatcher::UpdateAdvisoryProvider>,
    monitoring_control: Option<&dyn crate::monitoring_control::MonitoringControl>,
) -> Result<serde_json::Value, JSONRPCError> {
    // 0. Teachme interception — intercepts BEFORE any runner fires.
    //    Returns guide text; estate is never touched.
    match optional_bool(args, "teachme") {
        Ok(Some(true)) => return Ok(text_result(&crate::teachme_guides::guide(name))),
        Ok(_) => {}
        Err(error) => return Err(error),
    }

    // 1. Federation tool — moot_federated_search: grant-authorized federated
    //    read that fans across locally-open estates the caller is entitled to
    //    read, narrows each contribution to its grant's scope, and refuses
    //    cleanly (isError:true) when no authorizing grant is present. Mirrors
    //    Swift ToolDispatcher.runFederatedSearch. Authorization is NOT
    //    performed here; per-estate grant gating lives in GLK federated_recall
    //    (the I-13 boundary: ARIA mediates which estates to attempt; GLK
    //    enforces whether each read is granted).
    if name == "moot_federated_search" {
        return Ok(run_federated_search(args, registry));
    }

    // 2. Interface tools (Tier 1–5) — pass the session ledger so moot_memory_search
    //    can record surfaced ids and dereference verbs can note usage.
    //    Also passes build_serial so moot_estate_ping can include it.
    if crate::interface_tools::is_interface_tool(name) {
        // moot_palace_import and moot_json_import open arbitrary local files
        // — same security posture as vault import/export. Refuse when vault
        // is disabled so a hard-coded caller gets a clear message rather
        // than an opaque dispatch.
        if (name == "moot_palace_import" || name == "moot_json_import") && !vault_on {
            return Ok(error_result(
                "vault is disabled; reinstall with mootx01 install --vault-on to enable import/export"
            ));
        }
        let result = crate::interface_tools::dispatch(name, args, registry, ledger, sensitivity_ledger, posture, build_serial, version_skew, update_advisory, monitoring_control)?;
        return Ok(inject_hint(name, args, result));
    }

    // 3. Vault tools — backed by vault-kit (VaultBridge + ObsidianAdapter +
    //    DrawerMapping). The ARIA layer owns the SHA-256 sidecar manifest for
    //    drift detection (Vault drift and candidate handling decision b). No hint injection on
    //    vault results — they carry filesystem paths, not coaching triggers.
    //    vault_ledger tracks completed export/import jobs for moot_vault_job.
    //
    //    Gated by MOOTX01_VAULT env var: when vault is disabled
    //    (MOOTX01_VAULT=0, installed with --vault-off), vault tool names are
    //    absent from tools/list, but if a client hard-codes a name we return a
    //    clear refusal rather than an opaque methodNotFound. Default = vault-on.
    if name.starts_with("moot_vault_") {
        // vault_on is the resolved flag: true = vault surface enabled (the default),
        // false = vault surface hidden (installed with --vault-off, the open 1.0 Vault posture).
        // The tool is absent from tools/list when disabled, but if a client
        // hard-codes the name we return a clear refusal, not a methodNotFound.
        if !vault_on {
            return Ok(error_result(
                "vault is disabled; reinstall with mootx01 install --vault-on to enable import/export"
            ));
        }
        return crate::vault_tools::dispatch_vault(name, args, registry, vault_ledger);
    }

    // 3.5. Dataset tools — interface-tier CRUD over user-owned datasets (MX-TAB-7b).
    //
    // Inserted between vault and recipe to mirror Swift ToolDispatcher.dispatch(_:_:)
    // insertion order: after VaultTools and before InterfaceTools in the Swift dispatch
    // chain. Dataset tools are always present (not vault-gated): they open user-supplied
    // data into the estate, which is not a vault-filesystem-import concern.
    if crate::dataset_tools::is_dataset_tool(name) {
        let result = crate::dataset_tools::dispatch(name, args, registry)?;
        return Ok(inject_hint(name, args, result));
    }

    // 4. Recipe tools
    if crate::recipe_tools::is_recipe_tool(name) {
        let result = crate::recipe_tools::dispatch(name, args, registry)?;
        return Ok(inject_hint(name, args, result));
    }

    // 5. Lens tools
    if crate::lens_tools::is_lens_tool(name) {
        let result = crate::lens_tools::dispatch(name, args, registry)?;
        return Ok(inject_hint(name, args, result));
    }

    // Unknown tool — transport-level fault (not a tool-level refusal).
    Err(JSONRPCError::new(
        JSONRPCErrorCode::METHOD_NOT_FOUND,
        format!("Unknown tool: {name}"),
    ))
}

// ---------------------------------------------------------------------------
// Federation runner
// ---------------------------------------------------------------------------

/// Run `moot_federated_search`: a grant-authorized federated read that fans
/// across the locally-open estates the caller is entitled to read, narrows
/// each contribution to its grant's scope, and returns per-estate sections.
///
/// Mirrors Swift `ToolDispatcher.runFederatedSearch`. Authorization is NOT
/// performed here — per-estate grant gating lives in GLK `federated_recall`
/// (the I-13 boundary: ARIA mediates which estates to attempt; GLK enforces
/// whether each read is granted). A per-estate `CrossEstateReadRefused` is
/// the expected "not granted" signal and is skipped. If no estate authorizes
/// the caller, returns an error result (isError:true), not a thrown error.
///
/// Omitted filter uses ordinary recall defaults; hydration defaults to `Full` so
/// content blobs are present in the assembled response text. Ordering
/// defaults to `ByCaptureTimeDesc`. Candidate sources are sorted by UUID
/// string for deterministic output independent of map iteration order.
fn run_federated_search(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> serde_json::Value {
    use genius_locus_kit::coordinator::FederatedReadRefusalReason;
    use genius_locus_kit::GeniusLocusKitError;
    use locus_kit::filter::{HydrationLevel, RecallFrame};
    use uuid::Uuid;

    // Resolve the requester estate. Item 2 hardening (secfix/batch2-aria):
    // requesterEstateID is now optional. When omitted the requester is always
    // the default (authenticated caller) estate. When supplied it must match
    // the default estate's UUID exactly — supplying a different UUID is refused
    // to prevent cross-estate identity spoofing.
    // Mirrors Swift ToolDispatcher.resolveRequester(_:).
    let default_requester_uuid = Uuid::from_bytes(registry.default.handle.estate_uuid);
    if let Some(supplied) = args.get("requesterEstateID") {
        let raw_requester_id = match supplied {
            JsonValue::String(s) => s.as_str(),
            _ => return error_result(
                "federated_search: requesterEstateID must be a UUID string when supplied; \
                 omit it to use the default caller estate"
            ),
        };
        let supplied_uuid = match Uuid::parse_str(raw_requester_id) {
            Ok(u) => u,
            Err(_) => return error_result(&format!(
                "federated_search: malformed requesterEstateID (not a UUID): {raw_requester_id}"
            )),
        };
        if supplied_uuid != default_requester_uuid {
            return error_result(
                "federated_search: requesterEstateID does not match the authenticated \
                 caller estate; omit requesterEstateID to use the default estate"
            );
        }
    }
    // Bind the requester to the default estate (the authenticated caller).
    let (requester_handle, requester_handle_uuid, coord_arc) = (
        registry.default.handle,
        default_requester_uuid,
        registry.default.coord.clone(),
    );

    // Decode the recall frame. Absent `hydrationLevel` defaults to Full so
    // content blobs are present in the assembled response text — federated search
    // renders drawer content as a preview and the caller cannot evaluate relevance
    // on empty strings. When present the value must be a string: a non-string type
    // (number, null, boolean) is a protocol violation and returns isError:true rather
    // than silently coercing to None→Full (the prior bug). An unknown string is
    // likewise fail-CLOSED. Mirrors Swift `decodeHydration` which throws
    // invalidParams for both cases. Both verticals must be identical:
    // absent→Full, valid-string→honored, non-string→error, unknown-string→error.
    let filter_chain = match decode_filter_chain(args) {
        Ok(chain) => chain,
        Err(error) => return error_result(&format!("federated_search: {}", error.message)),
    };
    let mut frame = RecallFrame::new(filter_chain);
    // Route limit through clamp_limit so negative and over-ceiling values are
    // rejected/clamped at the MCP boundary on this federated surface.
    // Parity: Swift runFederatedSearch uses Self.clampLimit with the same ceiling.
    match optional_integer(args, "limit") {
        Ok(raw) => match clamp_limit(raw, "limit", 20, LIMIT_HARD_CEILING) {
            Ok(limit) => frame.limit = Some(limit),
            Err(e) => return error_result(&format!("federated_search: {}", e.message)),
        },
        Err(e) => return error_result(&format!("federated_search: {}", e.message)),
    }
    frame.hydration_level = match args.get("hydrationLevel") {
        None => HydrationLevel::Full,
        Some(v) => match v.as_str() {
            None => return error_result(
                "federated_search: hydrationLevel must be a string (full, structured, bitmapOnly); got non-string value"
            ),
            Some("full") => HydrationLevel::Full,
            Some("structured") => HydrationLevel::Structured,
            Some("bitmapOnly") => HydrationLevel::BitmapOnly,
            Some(unknown) => return error_result(&format!(
                "federated_search: unknown hydrationLevel: {unknown}; valid values: full, structured, bitmapOnly"
            )),
        },
    };

    // Wall-clock now for both LocusKit bitmap evaluation and grant expiry.
    // The grant subsystem uses Unix epoch seconds throughout on the Rust port.
    let now_unix = wall_now();

    // Visit candidate sources sorted by handle UUID string for deterministic
    // output. Filter out the requester itself (handle UUID comparison).
    // Mirrors Swift candidates sorted by estateUUID.uuidString.
    let mut candidates: Vec<_> = registry.extras.values()
        .filter(|oe| Uuid::from_bytes(oe.handle.estate_uuid) != requester_handle_uuid)
        .map(|oe| (oe.handle, Uuid::from_bytes(oe.handle.estate_uuid)))
        .collect();
    candidates.sort_by_key(|(_, id)| id.to_string());

    let mut sections: Vec<String> = Vec::new();
    // federated_recall takes &mut self — the coordinator updates internal
    // recall-ledger state during the call, so the guard must be mutable.
    let mut coord = coord_arc.lock().unwrap();

    for (source_handle, source_id) in candidates {
        let result = coord.federated_recall(
            frame.clone(),
            &source_handle,
            &requester_handle,
            now_unix as f64,
            now_unix,
        );
        match result {
            Ok(fr) => {
                // Render contribution: header + up to 50 drawer lines.
                // Format mirrors Swift renderContribution. source_id is the
                // handle UUID (store-manifest UUID, same as Swift estateUUID).
                let header = format!(
                    "estate {} — grant {}, {} row(s)",
                    source_id,
                    fr.grant.id,
                    fr.drawers.len(),
                );
                // Dense-row reply (PR-03): federated hits travel as dense
                // rows like every other recall surface — subjects instead
                // of content previews, which also tightens the cross-estate
                // disclosure to assertions the source chose to write (plus
                // lattice metadata). Mirrors Swift renderContribution.
                let lines: Vec<String> = fr.drawers.iter().take(50)
                    .map(|d| crate::result_composer::render_s2_row(
                        &crate::result_composer::candidate_from_drawer(d)))
                    .collect();
                let section = std::iter::once(header).chain(lines).collect::<Vec<_>>().join("\n");
                sections.push(section);
            }
            Err(GeniusLocusKitError::CrossEstateReadRefused { reason: FederatedReadRefusalReason::NoActiveGrant, .. }) => {
                // Expected: no grant from this source to the requester. Skip silently.
                continue;
            }
            Err(GeniusLocusKitError::CrossEstateReadRefused { reason: FederatedReadRefusalReason::GrantExpired, .. }) => {
                // All grants have expired. Skip silently.
                continue;
            }
            Err(e) => {
                // Unexpected error — surface as an error result so the caller
                // can see what went wrong without losing the call id.
                // Use `describe_glk_error` so no internal Rust type names leak.
                return error_result(&format!("federated_search: {}", describe_glk_error(&e)));
            }
        }
    }

    if sections.is_empty() {
        return error_result(
            "federated_search refused: no open estate holds an active grant naming the requester."
        );
    }
    text_result(&sections.join("\n\n"))
}

/// Append a coaching hint to a non-error result if the CoachingEngine fires.
/// Never modifies error results (`isError: true`).
fn inject_hint(
    name: &str,
    args: &BTreeMap<String, JsonValue>,
    mut result: serde_json::Value,
) -> serde_json::Value {
    // Only inject hints on success results.
    if result.get("isError").and_then(|v| v.as_bool()) == Some(true) {
        return result;
    }
    let result_text = result["content"][0]["text"]
        .as_str()
        .unwrap_or("")
        .to_string();
    if let Some(hint) = crate::coaching_engine::hint(name, args, &result_text) {
        let new_text = format!("{result_text}\nhint: {hint}");
        if let Some(text_field) = result["content"][0]["text"].as_str() {
            let _ = text_field; // drop immutable borrow so the mutable assignment below compiles
            result["content"][0]["text"] = serde_json::Value::String(new_text);
        }
    }
    result
}

/// Append a hint line when the caller sent argument keys not declared in the
/// tool's inputSchema. Never modifies error results (`isError: true`). Also
/// logs unrecognized keys to stderr for daemon log visibility.
///
/// Accepted keys are extracted from `crate::tool_list::accepted_arg_keys`,
/// which reads the live tool schema (post-`with_estate_id`/`with_teachme`
/// wrappers). Returns `None` for unknown tool names — no check runs.
///
/// Mirrors Swift `ToolDispatcher.appendUnknownArgsHint`.
fn inject_unknown_args_hint(
    name: &str,
    args: &BTreeMap<String, JsonValue>,
    mut result: serde_json::Value,
) -> serde_json::Value {
    let Some(accepted) = crate::tool_list::accepted_arg_keys(name) else {
        return result;
    };
    let unknown: Vec<String> = {
        let mut v: Vec<String> = args.keys()
            .filter(|k| !accepted.contains(*k))
            .cloned()
            .collect();
        v.sort();
        v
    };
    if unknown.is_empty() {
        return result;
    }
    let sorted_names = unknown.join(", ");
    eprintln!("aria-mcp: {name}: unrecognized argument(s) ignored: {sorted_names}");
    // Append hint to non-error results only.
    if result.get("isError").and_then(|v| v.as_bool()) == Some(true) {
        return result;
    }
    if let Some(text) = result["content"][0]["text"].as_str() {
        let new_text = format!("{text}\nhint: unrecognized argument(s) ignored: {sorted_names}");
        result["content"][0]["text"] = serde_json::Value::String(new_text);
    }
    result
}

// ---------------------------------------------------------------------------
// Shared result helpers — mirror Swift ToolDispatcher.textResult / errorResult
// ---------------------------------------------------------------------------

/// MCP `tools/call` success result with a single text content block.
/// Wire-identical to the Swift `ToolDispatcher.textResult(_:)`.
pub fn text_result(text: &str) -> serde_json::Value {
    serde_json::json!({
        "content": [{ "type": "text", "text": text }],
        "isError": false
    })
}

/// MCP `tools/call` success result carrying several text blocks, in order.
///
/// Used where a machine-readable payload travels alongside the prose receipt
/// (`moot_json_import` with `return_id_map`): the reader parses one block whole
/// rather than scraping structure out of a sentence. Wire-identical to Swift
/// `ToolDispatcher.textResultBlocks(_:)`.
pub fn text_result_blocks(blocks: &[String]) -> serde_json::Value {
    serde_json::json!({
        "content": blocks
            .iter()
            .map(|b| serde_json::json!({ "type": "text", "text": b }))
            .collect::<Vec<_>>(),
        "isError": false
    })
}

/// MCP `tools/call` failure result. Substrate refusals surface here so the
/// client retains the call id and can render the message.
/// Wire-identical to Swift `ToolDispatcher.errorResult(_:)`.
pub fn error_result(text: &str) -> serde_json::Value {
    serde_json::json!({
        "content": [{ "type": "text", "text": text }],
        "isError": true
    })
}

// ---------------------------------------------------------------------------
// Shared argument helpers used by recipe and lens modules
// ---------------------------------------------------------------------------

/// Extract a required string argument or return `invalidParams`.
pub fn require_string<'a>(
    args: &'a BTreeMap<String, JsonValue>,
    key: &str,
) -> Result<&'a str, JSONRPCError> {
    args.get(key).and_then(|v| v.as_str()).ok_or_else(|| {
        JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("Missing required string argument: {key}"),
        )
    })
}

/// Extract an optional string argument. Absent means `None`; present null or
/// wrong type is invalidParams so clients cannot accidentally ask the server to
/// guess which default they intended.
pub fn optional_string<'a>(
    args: &'a BTreeMap<String, JsonValue>,
    key: &str,
) -> Result<Option<&'a str>, JSONRPCError> {
    match args.get(key) {
        None => Ok(None),
        Some(JsonValue::String(value)) => Ok(Some(value.as_str())),
        Some(_) => Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("{key} must be a string; omit it to use the default"),
        )),
    }
}

/// Extract an optional boolean argument. Absent means `None`; present null or
/// wrong type is invalidParams.
pub fn optional_bool(
    args: &BTreeMap<String, JsonValue>,
    key: &str,
) -> Result<Option<bool>, JSONRPCError> {
    match args.get(key) {
        None => Ok(None),
        Some(JsonValue::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("{key} must be a boolean; omit it to use the default"),
        )),
    }
}

/// Extract an optional integer argument. Absent means `None`; present null or
/// wrong type is invalidParams.
pub fn optional_integer(
    args: &BTreeMap<String, JsonValue>,
    key: &str,
) -> Result<Option<i64>, JSONRPCError> {
    match args.get(key) {
        None => Ok(None),
        Some(value) => value.as_i64().map(Some).ok_or_else(|| {
            JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                format!("{key} must be an integer; omit it to use the default"),
            )
        }),
    }
}

/// Hard ceiling for all caller-supplied `limit`/`count`/`k` arguments at the
/// MCP tool boundary. Parity: mirrors `limitHardCeiling` in Swift `ToolDispatch.swift`.
pub const LIMIT_HARD_CEILING: usize = 500;

/// Clamp a caller-supplied `limit`/`count`/`k` to the safe MCP boundary range
/// `[1, ceiling]`. This is the single clamping funnel for all such arguments
/// across the ARIA_MCP tool surface (interface tools, recipe tools, lens tools).
///
/// - `None` (absent arg)  → returns `default_value`.
/// - raw ≤ 0             → returns `Err(invalidParams)`; negative/zero values
///                         crash downstream range and iterator operations.
/// - raw > `ceiling`     → silently clamped to `ceiling`; prevents DoS via
///                         unbounded substrate scans.
/// - Otherwise           → converted to `usize` and returned.
///
/// Parity: mirrors `clampLimit` in Swift `ToolDispatch.swift`.
pub fn clamp_limit(
    raw: Option<i64>,
    name: &str,
    default_value: usize,
    ceiling: usize,
) -> Result<usize, JSONRPCError> {
    match raw {
        None => Ok(default_value),
        Some(v) if v <= 0 => Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("{name} must be 1 or greater; received {v}"),
        )),
        Some(v) => Ok((v as usize).min(ceiling)),
    }
}

/// Extract an optional float argument. Absent means `None`; present null or
/// wrong type is invalidParams.
pub fn optional_float(
    args: &BTreeMap<String, JsonValue>,
    key: &str,
) -> Result<Option<f64>, JSONRPCError> {
    match args.get(key) {
        None => Ok(None),
        Some(value) => value.as_f64().map(Some).ok_or_else(|| {
            JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                format!("{key} must be a number; omit it to use the default"),
            )
        }),
    }
}

/// Extract an optional integer argument with a fallback.
pub fn opt_integer(
    args: &BTreeMap<String, JsonValue>,
    key: &str,
    fallback: i64,
) -> Result<i64, JSONRPCError> {
    Ok(optional_integer(args, key)?.unwrap_or(fallback))
}

/// Extract an optional float argument with a fallback.
pub fn opt_float(
    args: &BTreeMap<String, JsonValue>,
    key: &str,
    fallback: f64,
) -> Result<f64, JSONRPCError> {
    Ok(optional_float(args, key)?.unwrap_or(fallback))
}

/// Decode the recall filter from an optional `filter` argument.
/// Omitted filter means ordinary recall: LocusKit inserts state/trust/sensitivity
/// defaults, but no confirmation constraint. Mirrors Swift `decodeFilterChain`.
/// `LensTools.frame(_:)`.
pub fn decode_filter_chain(
    args: &BTreeMap<String, JsonValue>,
) -> Result<Vec<locus_kit::filter::Filter>, JSONRPCError> {
    use locus_kit::drawer_operational::DrawerFeatureFlags;
    use locus_kit::filter::Filter;
    match optional_string(args, "filter")? {
        None => Ok(vec![]),
        Some("unconfirmed") => Ok(vec![Filter::Unconfirmed]),
        Some("userConfirmed") => Ok(vec![Filter::UserConfirmed]),
        Some("exportable") => Ok(vec![Filter::Exportable]),
        Some("contained") => Ok(vec![Filter::Contained]),
        Some("currentlyBelieve") => Ok(vec![Filter::CurrentlyBelieve]),
        // isPinned filter: constrains recall to user-pinned drawers (bit 16).
        // Activates the container-fingerprint pruning path for the first
        // time in production (.HasFeatureFlag is the only prunable filter
        // case; containers whose OR-fingerprint lacks bit 16 are pruned).
        // Feature-flag adoption §1. Mirrors Swift ToolDispatch.decodeFilterChain.
        Some("pinned") => Ok(vec![Filter::HasFeatureFlag(DrawerFeatureFlags::IS_PINNED)]),
        // hasLinks filter: constrains recall to drawers with links/citations
        // (bit 15). Used by grounded synthesis for citation-scoped synthesis.
        // Feature-flag adoption §2. Mirrors Swift RecipeTools.decodeFilterChain.
        Some("hasLinks") => Ok(vec![Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_LINKS)]),
        Some(unknown) => Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("Unknown filter: {unknown}"),
        )),
    }
}

/// Build a recall frame from the filter in `args`. Used by the lenses
/// that accept an optional filter. Mirrors `LensTools.frame(_:)`.
pub fn recall_frame(
    args: &BTreeMap<String, JsonValue>,
) -> Result<locus_kit::filter::RecallFrame, JSONRPCError> {
    Ok(locus_kit::filter::RecallFrame::new(decode_filter_chain(args)?))
}

/// Produce a user-facing English description of a `GeniusLocusKitError` at
/// the ARIA boundary. No internal Rust type names or enum variant names appear
/// in the output. Called from `federated_search` for unexpected GLK errors.
///
/// `estate_uuid` fields are `[u8; 16]` — format via `uuid::Uuid::from_bytes`
/// to produce a canonical UUID string (e.g. `"3f2504e0-4f89-11d3-9a0c-0305e82c3301"`)
/// rather than a raw byte-array debug dump that leaks nothing useful to a caller.
pub(crate) fn describe_glk_error(e: &genius_locus_kit::GeniusLocusKitError) -> String {
    use genius_locus_kit::GeniusLocusKitError;
    match e {
        GeniusLocusKitError::EstateNotOpen { estate_uuid } => {
            format!("estate {} is not open", uuid::Uuid::from_bytes(*estate_uuid))
        }
        GeniusLocusKitError::DuplicateEstate { estate_uuid } => {
            format!("estate {} is already open", uuid::Uuid::from_bytes(*estate_uuid))
        }
        GeniusLocusKitError::InvalidManifest { key, detail } => {
            format!("invalid manifest key '{key}': {detail}")
        }
        GeniusLocusKitError::InvalidLatticeRegion { low, high } => {
            format!("invalid lattice region: low={low} must not exceed high={high}")
        }
        GeniusLocusKitError::EstateOpenFailed { detail } => {
            format!("estate could not be opened: {detail}")
        }
        GeniusLocusKitError::EstateQuiesced { estate_uuid } => {
            format!("estate {} is quiesced and not accepting new work", uuid::Uuid::from_bytes(*estate_uuid))
        }
        GeniusLocusKitError::DestroyRequiresClose { estate_uuid } => {
            format!("estate {} must be closed before it can be destroyed", uuid::Uuid::from_bytes(*estate_uuid))
        }
        GeniusLocusKitError::UnderlyingEstateFailure { reason } => {
            format!("estate operation failed: {reason}")
        }
        GeniusLocusKitError::CrossEstateReadRefused { source, requester, reason } => {
            use genius_locus_kit::coordinator::FederatedReadRefusalReason;
            let why = match reason {
                FederatedReadRefusalReason::NoActiveGrant =>
                    "no active grant names the requester",
                FederatedReadRefusalReason::GrantExpired =>
                    "the grant has expired",
                FederatedReadRefusalReason::BudgetExhausted =>
                    "the read budget for this grant has been exhausted",
                FederatedReadRefusalReason::CustodyRefused =>
                    "the source estate's custody mode refused the read",
                FederatedReadRefusalReason::GrantRevoked =>
                    "the grant has been revoked",
                // F-5: a non-empty grant signature failed verification against
                // the source estate's registered Ed25519 key (forged or
                // key-mismatched grant). Same wording posture as the other
                // arms: state the refusal, no key material in the message.
                FederatedReadRefusalReason::InvalidGrantSignature =>
                    "the grant's signature failed verification",
            };
            format!(
                "cross-estate read from {source} by {requester} refused: {why}"
            )
        }
    }
}

/// Wall-clock MILLISECONDS at the time of dispatch — the deterministic `now`
/// token threaded through the verb/recall/reward stack. The substrate's time
/// fields (`filed_at`, `event_time`) and every temporal interval are epoch-ms,
/// matching the sub-second precision Swift's `Date` carries, so the two ports
/// store and score byte-identically. Lenses that take `now: i64` call this;
/// tests inject fixed values through `dispatch_tool_at` below.
///
/// In production this is the true wall clock. In benchmark replay mode,
/// callers should use `bench_clock_now()` instead — it returns a pinned
/// deterministic value when `MOOT_BENCH_EPOCH_NOW` is set.
pub fn wall_now() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

/// Bench-clock `now` in epoch milliseconds.
///
/// ## Behaviour
///
/// - **Pinned mode** (`MOOT_BENCH_EPOCH_NOW` is set to an ISO8601 instant at
///   server start): returns `base_ms + call_index * 1000`. The call index is
///   a process-global atomic counter that increments once per invocation, so
///   successive calls return strictly increasing values (filedAt uniqueness,
///   HLC advance) without wrapping in any realistic session. The base is
///   parsed once via `OnceLock`; all subsequent calls read the cached value
///   and the counter atomically.
///
/// - **Wall-clock mode** (env var absent or unparseable): delegates to
///   `wall_now()` — byte-identical behaviour to before this seam existed.
///
/// ## Contract
///
/// `MOOT_BENCH_EPOCH_NOW` is an internal benchmark seam, NOT an MCP surface
/// (no tool arg, no schema mention, never named in any payload).
/// Scope: request path only. Background daemon clocks (dreaming, governor)
/// must remain wall-clock for correctness.
///
/// All request-path `wall_now()` calls in `interface_tools.rs` are replaced
/// with this function so a single pinned instant gates all temporal decisions
/// for a tool call.
pub fn bench_clock_now() -> i64 {
    use std::sync::atomic::{AtomicI64, Ordering};
    use std::sync::OnceLock;

    // Base timestamp in epoch-ms, or None for wall-clock mode.
    // Parsed once from MOOT_BENCH_EPOCH_NOW; all subsequent calls skip the env read.
    static BASE_MS: OnceLock<Option<i64>> = OnceLock::new();

    // Per-call counter: starts at 0, increments by 1 each bench_clock_now() call.
    // One second (1000 ms) is added per index so filedAt values remain unique
    // and HLC can advance monotonically. AtomicI64 so concurrent HTTP connections
    // get distinct, strictly increasing instants without a mutex.
    static CALL_IDX: AtomicI64 = AtomicI64::new(0);

    let base_ms = BASE_MS.get_or_init(|| {
        let raw = std::env::var("MOOT_BENCH_EPOCH_NOW").unwrap_or_default();
        if raw.is_empty() { return None; }
        bench_clock_parse_iso8601_ms(&raw)
    });

    match base_ms {
        Some(base) => {
            let idx = CALL_IDX.fetch_add(1, Ordering::SeqCst);
            // 1000 ms per call index; checked_add saturates at i64::MAX rather
            // than wrapping (astronomically large sessions are not a real risk).
            base.saturating_add(idx.saturating_mul(1000))
        }
        None => wall_now(),
    }
}

/// Parse an ISO8601 UTC instant to epoch milliseconds.
///
/// Accepts `YYYY-MM-DDTHH:MM:SSZ`, `YYYY-MM-DDTHH:MM:SS+00:00`, and
/// `YYYY-MM-DDTHH:MM:SS.mmmZ` (fractional seconds, 3-digit truncation).
/// Used exclusively by `bench_clock_now()` — not a general-purpose parser.
/// Copied from the private `parse_iso8601_to_ms` in `interface_tools.rs`
/// so `bench_clock_now` can live in `dispatch.rs` without a cross-module
/// private dependency.
fn bench_clock_parse_iso8601_ms(s: &str) -> Option<i64> {
    let s = s
        .trim_end_matches('Z')
        .trim_end_matches("+00:00")
        .trim_end_matches("+0000");
    let (s, millis) = if let Some(dot_pos) = s.rfind('.') {
        let frac: String = s[dot_pos + 1..].chars().take(3).collect();
        let mut ms: i64 = frac.parse().ok()?;
        for _ in frac.len()..3 { ms *= 10; }
        (&s[..dot_pos], ms)
    } else {
        (s, 0i64)
    };
    let parts: Vec<&str> = s.split('T').collect();
    if parts.len() != 2 { return None; }
    let date_parts: Vec<i64> = parts[0].split('-').filter_map(|p| p.parse().ok()).collect();
    let time_parts: Vec<i64> = parts[1].split(':').filter_map(|p| p.parse().ok()).collect();
    if date_parts.len() < 3 || time_parts.len() < 3 { return None; }
    let (y, m, d) = (date_parts[0], date_parts[1], date_parts[2]);
    let (h, min, sec) = (time_parts[0], time_parts[1], time_parts[2]);
    // Days-from-epoch via Howard Hinnant's algorithm — identical to the copy
    // in `lens_tools.rs` and `interface_tools.rs`.
    let days = bench_clock_days_from_ymd(y, m, d)?;
    let secs = days.checked_mul(86400)?
        .checked_add(h.checked_mul(3600)?)?
        .checked_add(min.checked_mul(60)?)?
        .checked_add(sec)?;
    secs.checked_mul(1000)?.checked_add(millis)
}

fn bench_clock_days_from_ymd(y: i64, m: i64, d: i64) -> Option<i64> {
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) { return None; }
    let y = if m <= 2 { y - 1 } else { y };
    let m = if m <= 2 { m + 9 } else { m - 3 };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * m + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    Some(era * 146097 + doe - 719468)
}

// ─────────────────────────────────────────────────────────────────────────────
// Bench-clock unit tests
// ─────────────────────────────────────────────────────────────────────────────
//
// Three surfaces under test (twin of Swift `BenchClockTests.swift`):
//
//   A. Parser — `bench_clock_parse_iso8601_ms` returns the correct epoch-ms
//      value for known instants and None for malformed / empty input.
//
//   B. Date helper — `bench_clock_days_from_ymd` matches known day-counts
//      for Unix epoch anchor dates.
//
//   C. Wall clock — `wall_now()` is positive and plausible (> year-2020 epoch).
//
// Note: `bench_clock_now()` uses process-global OnceLock + AtomicI64 statics.
// Those statics are initialised once per test binary and cannot be reset between
// tests. Direct unit testing of `bench_clock_now()` under controlled env values
// would require running each variant in a separate process (integration-test
// binary). The pure-function surfaces (A, B) give full coverage of the parser
// and counter arithmetic without that constraint; the process-level OnceLock
// behavior is confirmed by the 6-run replay acceptance test in the harness.

#[cfg(test)]
mod bench_clock_tests {
    use super::{bench_clock_parse_iso8601_ms, bench_clock_days_from_ymd, wall_now};

    // ── A. Parser ─────────────────────────────────────────────────────────────

    /// 2026-07-25T00:00:00Z is the canonical replay seed epoch. Its epoch-ms
    /// value is derived by:
    ///   TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "2026-07-25T00:00:00Z" +%s
    ///   => 1784937600 seconds == 1784937600000 ms
    /// The Swift BenchClock test pins the same instant and the harness derives
    /// its epoch from seed 20260725, which maps to this exact instant via
    /// `benchClockEpochISO(for: 20260725)` in ScratchPosture.swift.
    #[test]
    fn parser_returns_correct_epoch_ms_for_canonical_instant() {
        // 2026-07-25T00:00:00Z: 1784937600 seconds since Unix epoch.
        let expected_ms: i64 = 1_784_937_600_000;
        let result = bench_clock_parse_iso8601_ms("2026-07-25T00:00:00Z");
        assert_eq!(
            result,
            Some(expected_ms),
            "canonical replay epoch must parse to {expected_ms}; got {result:?}"
        );
    }

    /// Unix epoch (1970-01-01T00:00:00Z) must parse to exactly 0 ms.
    #[test]
    fn parser_returns_zero_for_unix_epoch() {
        let result = bench_clock_parse_iso8601_ms("1970-01-01T00:00:00Z");
        assert_eq!(
            result,
            Some(0),
            "Unix epoch must parse to 0 ms; got {result:?}"
        );
    }

    /// Fractional-seconds form (3-digit ms) must parse correctly.
    /// 1970-01-01T00:00:00.500Z == 500 ms.
    #[test]
    fn parser_handles_fractional_seconds() {
        let result = bench_clock_parse_iso8601_ms("1970-01-01T00:00:00.500Z");
        assert_eq!(
            result,
            Some(500),
            "fractional-seconds (.500Z) must parse to 500 ms; got {result:?}"
        );
    }

    /// +00:00 suffix (equivalent to Z) must parse correctly.
    #[test]
    fn parser_handles_plus_zero_offset() {
        let result_z      = bench_clock_parse_iso8601_ms("1970-01-01T00:00:00Z");
        let result_offset = bench_clock_parse_iso8601_ms("1970-01-01T00:00:00+00:00");
        assert_eq!(
            result_z, result_offset,
            "+00:00 and Z suffixes must parse to the same epoch-ms value"
        );
    }

    /// Empty string must return None — activates wall-clock mode.
    #[test]
    fn parser_returns_none_for_empty_string() {
        let result = bench_clock_parse_iso8601_ms("");
        assert!(result.is_none(), "empty string must return None; got {result:?}");
    }

    /// Malformed string must return None — wall-clock fallback, no panic.
    #[test]
    fn parser_returns_none_for_malformed_input() {
        for bad in &["not-a-date", "2026/07/25", "2026-07-25", "T00:00:00Z"] {
            let result = bench_clock_parse_iso8601_ms(bad);
            assert!(
                result.is_none(),
                "malformed input {bad:?} must return None; got {result:?}"
            );
        }
    }

    /// Two successive seconds are exactly 1000 ms apart when computed from
    /// the parser: base_ms(T00:00:01Z) - base_ms(T00:00:00Z) == 1000.
    /// This validates the step arithmetic the bench_clock_now counter relies on.
    #[test]
    fn consecutive_seconds_are_1000_ms_apart() {
        let t0 = bench_clock_parse_iso8601_ms("2026-07-25T00:00:00Z");
        let t1 = bench_clock_parse_iso8601_ms("2026-07-25T00:00:01Z");
        assert!(t0.is_some() && t1.is_some());
        assert_eq!(
            t1.unwrap() - t0.unwrap(),
            1000,
            "consecutive seconds must be exactly 1000 ms apart"
        );
    }

    // ── B. Date helper ────────────────────────────────────────────────────────

    /// 1970-01-01 is day 0 in the Unix epoch.
    #[test]
    fn days_from_ymd_unix_epoch_is_zero() {
        let days = bench_clock_days_from_ymd(1970, 1, 1);
        assert_eq!(days, Some(0), "1970-01-01 must be day 0; got {days:?}");
    }

    /// Month 0 and month 13 must return None (out of range).
    #[test]
    fn days_from_ymd_rejects_invalid_month() {
        assert!(bench_clock_days_from_ymd(2026, 0, 1).is_none(), "month 0 must return None");
        assert!(bench_clock_days_from_ymd(2026, 13, 1).is_none(), "month 13 must return None");
    }

    /// Day 0 and day 32 must return None (out of range).
    #[test]
    fn days_from_ymd_rejects_invalid_day() {
        assert!(bench_clock_days_from_ymd(2026, 7, 0).is_none(), "day 0 must return None");
        assert!(bench_clock_days_from_ymd(2026, 7, 32).is_none(), "day 32 must return None");
    }

    // ── C. Wall clock ─────────────────────────────────────────────────────────

    /// `wall_now()` must return a value clearly past 2020-01-01T00:00:00Z
    /// (epoch-ms 1577836800000). A value below this threshold would indicate
    /// a platform or unit-scale bug.
    #[test]
    fn wall_now_is_past_year_2020() {
        // 2020-01-01T00:00:00Z in epoch-ms.
        let year_2020_ms: i64 = 1_577_836_800_000;
        let now = wall_now();
        assert!(
            now > year_2020_ms,
            "wall_now() must return a time after 2020-01-01; got {now}"
        );
    }
}
