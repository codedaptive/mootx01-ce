//! Tunnel review-ladder endorsement ledger. Ports `TunnelReviewLedger.swift`.
//!
//! MXE-CT3 P2.5 — the review-ladder record carried in the tunnels
//! table's nullable JSON `ext` column.
//!
//! Ladder: Rejected / Proposed / Endorsed / Accepted. A model (AI)
//! reviewer may reject and endorse; ONLY the user accepts — edge
//! activation stays human-authoritative. "Endorsed" is NOT a lifecycle
//! case: it is bit 14 of `operational_bitmap` on a still-Proposed
//! tunnel, and this ledger is the record behind that bit.
//!
//! ## Wire shape (identical in both ports, canonical serialization)
//!
//! ```json
//! {
//!   "endorsements": [{"at": "2026-08-07T12:00:00Z", "by": "claude", "tier": 2}],
//!   "objections":   [{"at": "2026-08-07T12:05:00Z", "by": "apple-onboard", "tier": 2}],
//!   "reviewedBy":   "owner"
//! }
//! ```
//!
//! ## Determinism contract (golden-fixture tested against Swift)
//!
//! - object keys sorted byte-lexicographically at EVERY level,
//! - entry arrays sorted by `by` ascending (byte order), one entry per
//!   distinct reviewer (idempotent re-record updates at/tier only),
//! - compact output (no whitespace),
//! - string escaping: `\"`, `\\`, `\b`, `\f`, `\n`, `\r`, `\t`, and
//!   `\u00xx` (lowercase hex) for other control characters,
//! - empty arrays and absent `reviewedBy` are OMITTED,
//! - timestamps are whole-second UTC ISO-8601 formatted by the shared
//!   civil-calendar algorithm (`iso8601_seconds`) — never a platform
//!   formatter.
//!
//! NOTE: serialization does NOT go through `serde_json::to_string`.
//! GLK's dependency graph enables serde_json's `preserve_order`
//! feature, and cargo feature unification would silently flip map
//! ordering under this crate too — the hand-rolled canonical writer is
//! immune to that.
//!
//! ## Tolerance contract
//!
//! - `None` / empty `ext` parses to the empty ledger.
//! - Unknown top-level keys are preserved verbatim on rewrite (the
//!   `ext` column is the shared forward-compat slot).
//! - Malformed JSON, or a KNOWN key with the wrong shape, throws
//!   `LocusKitError::InvalidContent` (fail-loud — never overwritten).

use crate::error::LocusKitError;
use serde_json::Value;

/// One endorsement or objection: who, when (canonical ISO-8601 UTC
/// whole seconds), and under which contradiction-tier lens
/// (1 typed / 2 lexical-structural / 3 lexical-value).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TunnelReviewEntry {
    /// Reviewer identity, e.g. "apple-onboard", "claude",
    /// "dream-adjudicator@1". The model FAMILY used by the review-queue
    /// diversity bonus is the prefix before the first '-' or ':'.
    pub by: String,
    /// Canonical ISO-8601 UTC timestamp (whole seconds). Kept as a
    /// string: the canonical format sorts lexicographically in
    /// chronological order, so recency comparisons never re-parse.
    pub at_iso: String,
    /// Contradiction-tier lens judged.
    pub tier: i64,
}

/// Parsed form of the tunnel `ext` review ledger. Mirrors Swift
/// `TunnelReviewLedger` — see the module header for contracts.
#[derive(Debug, Clone, Default)]
pub struct TunnelReviewLedger {
    /// Identity of the most recent lifecycle reviewer (accept/reject).
    pub reviewed_by: Option<String>,
    /// One entry per distinct endorser, kept sorted by `by` (byte order).
    pub endorsements: Vec<TunnelReviewEntry>,
    /// One entry per distinct model objector, kept sorted by `by`.
    pub objections: Vec<TunnelReviewEntry>,
    /// Unknown top-level `ext` keys, preserved verbatim on rewrite.
    unknown: Vec<(String, Value)>,
}

impl PartialEq for TunnelReviewLedger {
    fn eq(&self, other: &Self) -> bool {
        // Canonical bytes are the identity (matches Swift `==`).
        self.serialized() == other.serialized()
    }
}

impl TunnelReviewLedger {
    /// Empty ledger (fresh tunnel, no review activity).
    pub fn new() -> Self {
        Self::default()
    }

    // ─── Parse ──────────────────────────────

    /// Parse a tunnel's `ext` JSON into a ledger. `None` / blank input
    /// yields the empty ledger; corruption fails loud.
    pub fn parse(ext: Option<&str>) -> Result<Self, LocusKitError> {
        let text = match ext {
            Some(t) if !t.trim().is_empty() => t,
            _ => return Ok(Self::new()),
        };
        let root: Value = serde_json::from_str(text).map_err(|e| {
            LocusKitError::InvalidContent(format!(
                "tunnel ext is not valid JSON (fail-loud, not overwritten): {e}"
            ))
        })?;
        let Value::Object(map) = root else {
            return Err(LocusKitError::InvalidContent(
                "tunnel ext must be a JSON object".to_string(),
            ));
        };
        let mut ledger = Self::new();
        for (key, value) in map {
            match key.as_str() {
                "reviewedBy" => match value {
                    Value::String(s) => ledger.reviewed_by = Some(s),
                    _ => {
                        return Err(LocusKitError::InvalidContent(
                            "tunnel ext reviewedBy must be a string".to_string(),
                        ))
                    }
                },
                "endorsements" => ledger.endorsements = Self::entries(&value, "endorsements")?,
                "objections" => ledger.objections = Self::entries(&value, "objections")?,
                _ => ledger.unknown.push((key, value)),
            }
        }
        ledger.endorsements.sort_by(|a, b| a.by.cmp(&b.by));
        ledger.objections.sort_by(|a, b| a.by.cmp(&b.by));
        Ok(ledger)
    }

    fn entries(value: &Value, key: &str) -> Result<Vec<TunnelReviewEntry>, LocusKitError> {
        let Value::Array(items) = value else {
            return Err(LocusKitError::InvalidContent(format!(
                "tunnel ext {key} must be an array"
            )));
        };
        items
            .iter()
            .map(|item| {
                let Value::Object(fields) = item else {
                    return Err(LocusKitError::InvalidContent(format!(
                        "tunnel ext {key} entries must be objects"
                    )));
                };
                let mut by = None;
                let mut at = None;
                let mut tier = None;
                for (k, v) in fields {
                    match (k.as_str(), v) {
                        ("by", Value::String(s)) => by = Some(s.clone()),
                        ("at", Value::String(s)) => at = Some(s.clone()),
                        ("tier", Value::Number(n)) if n.is_i64() => tier = n.as_i64(),
                        _ => {
                            // A known-key entry with an unexpected field
                            // is corruption of ledger-owned data.
                            return Err(LocusKitError::InvalidContent(format!(
                                "tunnel ext {key} entry has unexpected field {k}"
                            )));
                        }
                    }
                }
                match (by, at, tier) {
                    (Some(by), Some(at_iso), Some(tier)) => {
                        Ok(TunnelReviewEntry { by, at_iso, tier })
                    }
                    _ => Err(LocusKitError::InvalidContent(format!(
                        "tunnel ext {key} entry missing by/at/tier"
                    ))),
                }
            })
            .collect()
    }

    // ─── Mutation (idempotent per reviewer) ─

    /// Record the lifecycle reviewer's identity.
    pub fn record_review(&mut self, reviewer: &str) {
        self.reviewed_by = Some(reviewer.to_string());
    }

    /// Record an endorsement. One vote per distinct endorser: a repeat by
    /// the same id updates at/tier only and returns false; a new endorser
    /// inserts sorted and returns true.
    pub fn record_endorsement(&mut self, by: &str, at_iso: &str, tier: i64) -> bool {
        Self::upsert(&mut self.endorsements, by, at_iso, tier)
    }

    /// Record a model objection. Same one-vote-per-reviewer rule.
    pub fn record_objection(&mut self, by: &str, at_iso: &str, tier: i64) -> bool {
        Self::upsert(&mut self.objections, by, at_iso, tier)
    }

    fn upsert(list: &mut Vec<TunnelReviewEntry>, by: &str, at_iso: &str, tier: i64) -> bool {
        if let Some(existing) = list.iter_mut().find(|e| e.by == by) {
            existing.at_iso = at_iso.to_string();
            existing.tier = tier;
            return false;
        }
        list.push(TunnelReviewEntry {
            by: by.to_string(),
            at_iso: at_iso.to_string(),
            tier,
        });
        list.sort_by(|a, b| a.by.cmp(&b.by));
        true
    }

    // ─── Derived facts ──────────────────────

    /// Distinct endorser count — the base of the review-queue weight.
    pub fn distinct_endorser_count(&self) -> usize {
        self.endorsements.len()
    }

    /// True when the ledger holds BOTH a model endorsement and a model
    /// objection — the contested condition (bit 15).
    pub fn is_contested_evidence(&self) -> bool {
        !self.endorsements.is_empty() && !self.objections.is_empty()
    }

    /// Latest review activity (endorsement or objection) as canonical
    /// ISO — lexicographic max IS chronological max for this format.
    pub fn latest_activity_iso(&self) -> Option<&str> {
        self.endorsements
            .iter()
            .chain(self.objections.iter())
            .map(|e| e.at_iso.as_str())
            .max()
    }

    // ─── Serialize (canonical) ──────────────

    /// Canonical serialization per the determinism contract. `None` when
    /// the ledger holds nothing (no owned content AND no unknown tenant
    /// keys) so an untouched tunnel keeps `ext` NULL.
    pub fn serialized(&self) -> Option<String> {
        let mut pairs: Vec<(String, Value)> = self.unknown.clone();
        if let Some(reviewed_by) = &self.reviewed_by {
            pairs.push(("reviewedBy".to_string(), Value::String(reviewed_by.clone())));
        }
        if !self.endorsements.is_empty() {
            pairs.push(("endorsements".to_string(), Self::entries_value(&self.endorsements)));
        }
        if !self.objections.is_empty() {
            pairs.push(("objections".to_string(), Self::entries_value(&self.objections)));
        }
        if pairs.is_empty() {
            return None;
        }
        let mut out = String::new();
        write_canonical_object(&pairs, &mut out);
        Some(out)
    }

    fn entries_value(entries: &[TunnelReviewEntry]) -> Value {
        Value::Array(
            entries
                .iter()
                .map(|e| {
                    serde_json::json!({
                        "at": e.at_iso,
                        "by": e.by,
                        "tier": e.tier,
                    })
                })
                .collect(),
        )
    }
}

// ─── Canonical JSON writer ──────────────────

/// Serialize a `serde_json::Value` canonically: compact, object keys
/// sorted byte-lexicographically at every level, serde_json-compatible
/// escaping. Hand-rolled instead of `serde_json::to_string` because
/// feature unification (GLK enables `preserve_order`) would otherwise
/// change map ordering under this crate. Non-integer numbers emit via
/// f64 Display (shortest repr) — the ledger's own fields are strings
/// and integers only, so ledger-managed content is always byte-stable;
/// documented as best-effort for floats inside unknown tenant keys.
fn write_canonical(value: &Value, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                out.push_str(&i.to_string());
            } else if let Some(u) = n.as_u64() {
                out.push_str(&u.to_string());
            } else if let Some(f) = n.as_f64() {
                if f.fract() == 0.0 && f.abs() < 9.007_199_254_740_992e15 {
                    // Integral floats emit as "<n>.0" in both ports,
                    // keeping the float/int token distinction stable.
                    out.push_str(&format!("{}.0", f as i64));
                } else {
                    out.push_str(&format!("{f}"));
                }
            }
        }
        Value::String(s) => write_escaped(s, out),
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_canonical(item, out);
            }
            out.push(']');
        }
        Value::Object(map) => {
            let mut pairs: Vec<(&String, &Value)> = map.iter().collect();
            pairs.sort_by(|a, b| a.0.cmp(b.0));
            out.push('{');
            for (i, (k, v)) in pairs.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_escaped(k, out);
                out.push(':');
                write_canonical(v, out);
            }
            out.push('}');
        }
    }
}

/// Top-level variant taking an explicit pair list (the ledger's unknown
/// keys plus owned keys) — sorted here, values recurse through
/// `write_canonical`.
fn write_canonical_object(pairs: &[(String, Value)], out: &mut String) {
    let mut sorted: Vec<&(String, Value)> = pairs.iter().collect();
    sorted.sort_by(|a, b| a.0.cmp(&b.0));
    out.push('{');
    for (i, (k, v)) in sorted.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        write_escaped(k, out);
        out.push(':');
        write_canonical(v, out);
    }
    out.push('}');
}

/// serde_json-compatible string escaping (mirrors the Swift writer).
fn write_escaped(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0C}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

// ─── Canonical ISO-8601 (shared civil-calendar algorithm) ───

/// Format epoch seconds as canonical whole-second UTC ISO-8601
/// (`yyyy-MM-ddTHH:mm:ssZ`). Same Howard Hinnant `civil_from_days`
/// algorithm as Swift `TunnelReviewLedger.isoTimestamp(epochSeconds:)`
/// — a deliberate re-implementation (no chrono dependency here) so both
/// ports emit identical bytes by construction.
pub fn iso8601_seconds(secs: i64) -> String {
    let days = secs.div_euclid(86_400);
    let sod = secs.rem_euclid(86_400); // seconds-of-day, always 0..86400
    // civil_from_days
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097; // day-of-era 0..146097
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // day-of-year (Mar-based)
    let mp = (5 * doy + 2) / 153; // month index 0=Mar
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        y,
        m,
        d,
        sod / 3600,
        (sod % 3600) / 60,
        sod % 60
    )
}

/// Convenience: format epoch MILLISECONDS (the GLK/estate `now` domain)
/// as canonical whole-second ISO — floors to seconds first, matching
/// the Swift port's `rounded(.down)` truncation.
pub fn iso8601_from_millis(ms: i64) -> String {
    iso8601_seconds(ms.div_euclid(1000))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Golden fixture — MUST match the Swift test
    // `TunnelReviewLedgerTests.goldenFixtureBytes` byte-for-byte. This
    // pair of tests IS the cross-port determinism gate.
    const GOLDEN: &str = "{\"endorsements\":[{\"at\":\"2026-08-07T12:00:00Z\",\"by\":\"apple-onboard\",\"tier\":2},{\"at\":\"2026-08-07T12:05:00Z\",\"by\":\"claude\",\"tier\":3}],\"objections\":[{\"at\":\"2026-08-07T12:10:00Z\",\"by\":\"dream-adjudicator@1\",\"tier\":2}],\"reviewedBy\":\"owner\",\"zFuture\":{\"keep\":true}}";

    #[test]
    fn golden_fixture_bytes() {
        let mut ledger =
            TunnelReviewLedger::parse(Some("{\"zFuture\":{\"keep\":true}}")).unwrap();
        // Recorded out of order on purpose: canonical output must sort.
        ledger.record_endorsement("claude", "2026-08-07T12:05:00Z", 3);
        ledger.record_endorsement("apple-onboard", "2026-08-07T12:00:00Z", 2);
        ledger.record_objection("dream-adjudicator@1", "2026-08-07T12:10:00Z", 2);
        ledger.record_review("owner");
        assert_eq!(ledger.serialized().as_deref(), Some(GOLDEN));
    }

    #[test]
    fn round_trip_preserves_unknown_keys_and_content() {
        let parsed = TunnelReviewLedger::parse(Some(GOLDEN)).unwrap();
        assert_eq!(parsed.serialized().as_deref(), Some(GOLDEN));
        assert_eq!(parsed.distinct_endorser_count(), 2);
        assert!(parsed.is_contested_evidence());
        assert_eq!(parsed.reviewed_by.as_deref(), Some("owner"));
        assert_eq!(parsed.latest_activity_iso(), Some("2026-08-07T12:10:00Z"));
    }

    #[test]
    fn empty_and_none_parse_to_empty_ledger_and_serialize_to_none() {
        assert_eq!(TunnelReviewLedger::parse(None).unwrap().serialized(), None);
        assert_eq!(
            TunnelReviewLedger::parse(Some("  ")).unwrap().serialized(),
            None
        );
    }

    #[test]
    fn endorsement_is_idempotent_per_endorser() {
        let mut ledger = TunnelReviewLedger::new();
        assert!(ledger.record_endorsement("claude", "2026-08-07T12:00:00Z", 2));
        // Same endorser again: one vote, timestamp updates, returns false.
        assert!(!ledger.record_endorsement("claude", "2026-08-07T13:00:00Z", 2));
        assert_eq!(ledger.distinct_endorser_count(), 1);
        assert_eq!(ledger.endorsements[0].at_iso, "2026-08-07T13:00:00Z");
    }

    #[test]
    fn malformed_ext_fails_loud() {
        assert!(matches!(
            TunnelReviewLedger::parse(Some("not json {")),
            Err(LocusKitError::InvalidContent(_))
        ));
        assert!(matches!(
            TunnelReviewLedger::parse(Some("[1,2]")),
            Err(LocusKitError::InvalidContent(_))
        ));
        assert!(matches!(
            TunnelReviewLedger::parse(Some("{\"endorsements\":\"nope\"}")),
            Err(LocusKitError::InvalidContent(_))
        ));
        assert!(matches!(
            TunnelReviewLedger::parse(Some("{\"reviewedBy\":7}")),
            Err(LocusKitError::InvalidContent(_))
        ));
    }

    #[test]
    fn iso8601_matches_known_instants() {
        assert_eq!(iso8601_seconds(0), "1970-01-01T00:00:00Z");
        assert_eq!(iso8601_seconds(1_700_000_000), "2023-11-14T22:13:20Z");
        // Leap-year day.
        assert_eq!(iso8601_seconds(1_709_164_800), "2024-02-29T00:00:00Z");
        // Pre-epoch (euclidean division correctness).
        assert_eq!(iso8601_seconds(-1), "1969-12-31T23:59:59Z");
        // Millisecond convenience floors toward negative infinity.
        assert_eq!(iso8601_from_millis(1_700_000_000_123), "2023-11-14T22:13:20Z");
    }

    #[test]
    fn string_escaping_matches_contract() {
        let mut ledger = TunnelReviewLedger::new();
        ledger.record_review("a\"b\\c\nd\u{01}");
        assert_eq!(
            ledger.serialized().as_deref(),
            Some("{\"reviewedBy\":\"a\\\"b\\\\c\\nd\\u0001\"}")
        );
    }
}
