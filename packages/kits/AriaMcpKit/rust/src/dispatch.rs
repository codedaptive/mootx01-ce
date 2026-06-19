//! Top-level tool dispatch — maps a tool name to its handler.
//!
//! Routing order:
//!   0. teachme pre-check — intercepts `teachme:true` before any runner fires
//!   1. Federation tool (moot_federated_search)
//!   2. Interface tools (Tier 1–5, 19 tools)
//!   3. Vault tools (backed by vault-kit; ADR-VAULTKIT-002)
//!   4. Recipe tools (moot_list_lenses, moot_synthesize, …)
//!   5. Lens tools (moot_lens_keystones … moot_lens_concepts)
//!   6. Unknown tool → methodNotFound error
//!   hint: appended to non-error results by CoachingEngine
//!
//! Out-of-band faults (unknown tool, missing required argument, malformed
//! UUID) surface as `JSONRPCError` (thrown as Err). Substrate-level
//! refusals surface as a tool-call result with `isError: true`, matching
//! the Swift discipline.

use std::collections::BTreeMap;

use crate::estate_registry::EstateRegistry;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JsonValue};
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
///   2. Interface tools (Tier 1–5, 19 tools)
///   3. Vault tools (backed by vault-kit; ADR-VAULTKIT-002)
///   4. Recipe tools (moot_list_lenses, moot_synthesize, …)
///   5. Lens tools (moot_lens_keystones … moot_lens_concepts)
///   post-dispatch: hint injection via CoachingEngine
pub fn dispatch_tool(
    name: &str,
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
    ledger: &SurfacedRecallLedger,
) -> Result<serde_json::Value, JSONRPCError> {
    dispatch_tool_with_vault_ledger(name, args, registry, ledger, &VaultJobLedger::new())
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
    dispatch_tool_with_vault_ledger_and_flag(name, args, registry, ledger, &VaultJobLedger::new(), vault_on)
}

/// Internal dispatch entry point that accepts an explicit `vault_ledger`.
/// Used by `Dispatcher::handle` (passes the owned ledger) and by
/// `dispatch_tool` (passes a throwaway ledger for callers that don't need job
/// tracking, such as test helpers that call individual tools in isolation).
pub fn dispatch_tool_with_vault_ledger(
    name: &str,
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
    ledger: &SurfacedRecallLedger,
    vault_ledger: &VaultJobLedger,
) -> Result<serde_json::Value, JSONRPCError> {
    dispatch_tool_with_vault_ledger_and_flag(
        name, args, registry, ledger, vault_ledger, crate::tool_list::vault_enabled()
    )
}

/// Inner dispatch that accepts an explicit vault-on flag. This is the single
/// implementation all entry points delegate to. The flag controls whether
/// vault tool calls are routed to the vault backend or rejected with a clear
/// refusal. Callers that want env-var semantics pass `vault_enabled()`;
/// callers that need deterministic testing pass `true`/`false` directly.
fn dispatch_tool_with_vault_ledger_and_flag(
    name: &str,
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
    ledger: &SurfacedRecallLedger,
    vault_ledger: &VaultJobLedger,
    vault_on: bool,
) -> Result<serde_json::Value, JSONRPCError> {
    // 0. Teachme interception — intercepts BEFORE any runner fires.
    //    Returns guide text; estate is never touched.
    match optional_bool(args, "teachme") {
        Ok(Some(true)) => return Ok(text_result(crate::teachme_guides::guide(name))),
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
    if crate::interface_tools::is_interface_tool(name) {
        let result = crate::interface_tools::dispatch(name, args, registry, ledger)?;
        return Ok(inject_hint(name, args, result));
    }

    // 3. Vault tools — backed by vault-kit (VaultBridge + ObsidianAdapter +
    //    DrawerMapping). The ARIA layer owns the SHA-256 sidecar manifest for
    //    drift detection (ADR-VAULTKIT-002 decision b). No hint injection on
    //    vault results — they carry filesystem paths, not coaching triggers.
    //    vault_ledger tracks completed export/import jobs for moot_vault_job.
    //
    //    Gated by MOOTX01_VAULT env var (ADR-015): when vault is disabled
    //    (MOOTX01_VAULT=0, installed with --vault-off), vault tool names are
    //    absent from tools/list, but if a client hard-codes a name we return a
    //    clear refusal rather than an opaque methodNotFound. Default = vault-on.
    if name.starts_with("moot_vault_") {
        // vault_on is the resolved flag: true = vault surface enabled (the default),
        // false = vault surface hidden (installed with --vault-off, ADR-015).
        // The tool is absent from tools/list when disabled, but if a client
        // hard-codes the name we return a clear refusal, not a methodNotFound.
        if !vault_on {
            return Ok(error_result(
                "vault is disabled; reinstall with mootx01 install --vault-on to enable import/export"
            ));
        }
        return crate::vault_tools::dispatch_vault(name, args, registry, vault_ledger);
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

    // Resolve the requester estate from requesterEstateID. This is a required
    // argument; a missing or malformed UUID returns isError:true (not a thrown
    // JSONRPCError) so the caller sees a refusal, not a transport fault.
    let raw_requester_id = match args.get("requesterEstateID") {
        Some(JsonValue::String(s)) => s.as_str(),
        None => return error_result("federated_search: missing required argument: requesterEstateID"),
        Some(_) => return error_result(
            "federated_search: requesterEstateID must be a UUID string"
        ),
    };
    let requester_uuid = match Uuid::parse_str(raw_requester_id) {
        Ok(u) => u,
        Err(_) => return error_result(&format!(
            "federated_search: malformed requesterEstateID (not a UUID): {raw_requester_id}"
        )),
    };

    // Find the requester OpenEstate by matching the handle's estate_uuid
    // (the store-manifest UUID, a [u8;16]). The grant system uses this UUID
    // for grantee_estate_id, so federated_recall checks against it. Using the
    // handle UUID here keeps MCP surface and grant surface in sync.
    // Extract handle and coord before iterating all estates to avoid
    // double-borrow of the extras map.
    let (requester_handle, requester_handle_uuid, coord_arc) = {
        let oe = match registry.extras.values()
            .find(|oe| Uuid::from_bytes(oe.handle.estate_uuid) == requester_uuid)
        {
            Some(oe) => oe,
            None => return error_result(&format!(
                "federated_search: unknown requesterEstateID: {raw_requester_id}"
            )),
        };
        (oe.handle, Uuid::from_bytes(oe.handle.estate_uuid), oe.coord.clone())
    };

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
                let lines: Vec<String> = fr.drawers.iter().take(50).map(|d| {
                    let preview: String = d.content.chars().take(80).collect();
                    format!("{}  [{}]  {}", d.id, d.room, preview)
                }).collect();
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
// Shared argument helpers used by recipe, lens, and lexicon modules
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
    use locus_kit::filter::Filter;
    match optional_string(args, "filter")? {
        None => Ok(vec![]),
        Some("unconfirmed") => Ok(vec![Filter::Unconfirmed]),
        Some("userConfirmed") => Ok(vec![Filter::UserConfirmed]),
        Some("exportable") => Ok(vec![Filter::Exportable]),
        Some("contained") => Ok(vec![Filter::Contained]),
        Some("currentlyBelieve") => Ok(vec![Filter::CurrentlyBelieve]),
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
pub(crate) fn describe_glk_error(e: &genius_locus_kit::GeniusLocusKitError) -> String {
    use genius_locus_kit::GeniusLocusKitError;
    match e {
        GeniusLocusKitError::EstateNotOpen { estate_uuid } => {
            format!("estate {:?} is not open", estate_uuid)
        }
        GeniusLocusKitError::DuplicateEstate { estate_uuid } => {
            format!("estate {:?} is already open", estate_uuid)
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
            format!("estate {:?} is quiesced and not accepting new work", estate_uuid)
        }
        GeniusLocusKitError::DestroyRequiresClose { estate_uuid } => {
            format!("estate {:?} must be closed before it can be destroyed", estate_uuid)
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
            };
            format!(
                "cross-estate read from {source} by {requester} refused: {why}"
            )
        }
    }
}

/// Wall-clock seconds at the time of dispatch. Lenses that take `now: i64`
/// call this. Tests inject fixed values through `dispatch_tool_at` below.
pub fn wall_now() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}
