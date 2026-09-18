//! Shared selected-surface argument, result, and clock utilities.
//!
//! The retired v1 route chain formerly lived above these helpers.

use std::collections::BTreeMap;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JsonValue};

/// Successful MCP tool result with one text content block.
pub fn text_result(text: &str) -> serde_json::Value {
    serde_json::json!({
        "content": [{ "type": "text", "text": text }],
        "isError": false
    })
}

/// Successful MCP tool result carrying ordered text content blocks.
pub fn text_result_blocks(blocks: &[String]) -> serde_json::Value {
    serde_json::json!({
        "content": blocks
            .iter()
            .map(|block| serde_json::json!({ "type": "text", "text": block }))
            .collect::<Vec<_>>(),
        "isError": false
    })
}

/// Tool refusal result that retains the call id for the client.
pub fn error_result(text: &str) -> serde_json::Value {
    serde_json::json!({
        "content": [{ "type": "text", "text": text }],
        "isError": true
    })
}

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
/// defaults, but no confirmation constraint. Mirrors the Swift filter decode in
/// `AriaV2GeniusLocusMemoryBackend.search`.
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
        // Feature-flag adoption §1. Mirrors the Swift "pinned" arm in
        // AriaV2GeniusLocusMemoryBackend.search.
        Some("pinned") => Ok(vec![Filter::HasFeatureFlag(DrawerFeatureFlags::IS_PINNED)]),
        // hasLinks filter: constrains recall to drawers with links/citations
        // (bit 15). Used by grounded synthesis for citation-scoped synthesis.
        // Feature-flag adoption §2.
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
/// tests inject fixed values through the clock seam below.
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
pub(crate) fn bench_clock_parse_iso8601_ms(s: &str) -> Option<i64> {
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
