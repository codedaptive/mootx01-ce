// distilled_savings.rs: Rust mirror of CognitionKit/DistilledSavings.swift.
//
// Structured metadata reporting how much context the distilled payload
// saved against the original bodies of the same returned records.
//
// `DistilledSavings` is produced by the ARIA v2 surface for
// `moot_recall_distilled`, from the per-match `token_count` and
// `original_token_count` that `run_distilled_recall` carries, summed over
// the rows the surface actually emits (after its row cap and privacy
// projection). It compares the distilled payload cost (tokens sent to the
// caller) against the original body cost (what naive full-body hydration
// would have paid). Estimates are clearly labelled and the estimator is
// named for provenance.
//
// The `skim` field is part of the wire contract now so the schema does
// not change when skim is wired. It is always `None` today because
// `moot_recall_distilled` does not apply skim.
//
// Codable: serde with `rename_all = "camelCase"`. The `skim` key is
// absent from serialised output when `skim == None` (via
// `skip_serializing_if = "Option::is_none"`). The `default` attribute
// on `skim` lets it be decoded from JSON with a missing key as `None`.

use serde::{Deserialize, Serialize};

// MARK: - DistilledSkim

/// Context saved by a skim stage applied on top of distillation.
///
/// Absent (`None` on the parent field) when skim was not applied.
/// `moot_recall_distilled` does not apply skim today; this struct exists
/// so the wire contract is stable before skim is wired.
/// Mirrors `DistilledSkim` in the Swift port.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DistilledSkim {
    /// Tokens the skim stage omitted after distillation. Always non-negative.
    pub omitted_tokens: i64,
}

// MARK: - DistilledSavings

/// Tokens the distilled payload saved against the original bodies of
/// the same returned records.
///
/// Mirrors `DistilledSavings` in the Swift port. Arithmetic is
/// integer-only so both ports agree bit for bit on every field.
///
/// ## Field layout
///
///   - `returned_tokens = distilled_tokens - (skim_omitted ?? 0)`
///   - `saved_tokens = original_tokens - distilled_tokens` (signed)
///   - `saved_percent`: half-away-from-zero rounding, integers only
///   - `skim`: absent when skim was not applied
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DistilledSavings {
    /// Tokens sent to the caller: `distilled_tokens - skim_omitted`.
    pub returned_tokens: i64,
    /// Sum of `original_token_count` over the emitted rows that carry a
    /// distilled body: the cost of naive full-body hydration.
    pub original_tokens: i64,
    /// `original_tokens - distilled_tokens`. Negative when the distilled
    /// payload was larger than the original bodies.
    pub saved_tokens: i64,
    /// `saved_tokens * 100 / original_tokens`, rounded half-away-from-zero.
    /// Negative when the payload grew. Zero when `original_tokens == 0`.
    pub saved_percent: i64,
    /// Always `true`: token counts use `ContextDistillLib.estimateTokens`.
    pub estimated: bool,
    /// Name of the estimator that produced the token counts.
    pub estimator: String,
    /// Tokens omitted by skim after distillation. `None` when skim was
    /// not applied (current `moot_recall_distilled` behaviour).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub skim: Option<DistilledSkim>,
    /// Human-readable summary of the savings.
    pub display: String,
}

/// Name of the token-count estimator used for all estimates.
/// Mirrors `DistilledSavings.estimatorName` in the Swift port.
pub const ESTIMATOR_NAME: &str = "ContextDistillLib.estimateTokens (TokenCompaction v1)";

// MARK: - Thousands formatter

/// Format a non-negative `i64` with comma separators every three digits.
///
/// Implemented by hand: no locale dependency, no external crate.
/// The caller is responsible for passing a non-negative value.
/// Examples: 0 -> "0", 800 -> "800", 1200 -> "1,200", 1234567 -> "1,234,567".
fn format_thousands(n: i64) -> String {
    // n must be non-negative at call sites; sign is handled by the caller.
    let s = n.to_string();
    let len = s.len();
    let mut result = String::with_capacity(len + len.saturating_sub(1) / 3);
    for (i, c) in s.chars().enumerate() {
        if i > 0 && (len - i) % 3 == 0 {
            result.push(',');
        }
        result.push(c);
    }
    result
}

// MARK: - Display builder

/// Build the display string from the computed savings fields.
///
/// Grammar mirrors the Swift `buildDisplay` helper byte-for-byte:
///
///   skim absent, saved_tokens >= 0:
///     `🌱 Distilled: ~R tokens returned vs ~O original · ~S saved (P%)`
///
///   skim absent, saved_tokens < 0 (payload grew):
///     `🌱 Distilled: ~R tokens returned vs ~O original · ~|S| increase (|P|%)`
///
///   skim present, saved_tokens >= 0:
///     `🌱 Distillation saved ~S tokens; skim omitted another ~K tokens.`
///
///   skim present, saved_tokens < 0:
///     `🌱 Distillation added ~|S| tokens; skim omitted ~K tokens.`
///
/// `~` marks estimated values. `·` is U+00B7 with one space each side.
/// `🌱` (U+1F331) is followed by one space.
fn build_display(
    returned_tokens: i64,
    original_tokens: i64,
    saved_tokens: i64,
    saved_percent: i64,
    skim: &Option<DistilledSkim>,
) -> String {
    let p = "~";
    // U+00B7 MIDDLE DOT with one space on each side.
    let dot = " \u{00B7} ";
    // U+1F331 SEEDLING followed by one space.
    let leaf = "\u{1F331} ";

    if let Some(s) = skim {
        // Skim-present forms end with a period.
        let omitted = format_thousands(s.omitted_tokens);
        if saved_tokens >= 0 {
            let saved = format_thousands(saved_tokens);
            format!("{leaf}Distillation saved {p}{saved} tokens; skim omitted another {p}{omitted} tokens.")
        } else {
            let added = format_thousands(-saved_tokens);
            format!("{leaf}Distillation added {p}{added} tokens; skim omitted {p}{omitted} tokens.")
        }
    } else {
        // No-skim forms carry no trailing period.
        let ret = format_thousands(returned_tokens);
        let orig = format_thousands(original_tokens);
        // Use absolute value of percent for the display (sign is in saved/increase wording).
        let pct = saved_percent.unsigned_abs();
        if saved_tokens >= 0 {
            let saved = format_thousands(saved_tokens);
            format!("{leaf}Distilled: {p}{ret} tokens returned vs {p}{orig} original{dot}{p}{saved} saved ({pct}%)")
        } else {
            let added = format_thousands(-saved_tokens);
            format!("{leaf}Distilled: {p}{ret} tokens returned vs {p}{orig} original{dot}{p}{added} increase ({pct}%)")
        }
    }
}

// MARK: - Factory

/// Compute distilled savings from raw token sums.
///
/// Mirrors `DistilledSavings.measure(originalTokens:distilledTokens:skimOmittedTokens:)`
/// in the Swift port. Arithmetic is integer-only to guarantee exact
/// parity across ports: no f64, no unguarded narrowing.
///
/// - `original_tokens`: sum of per-match `original_token_count` over the
///   emitted rows that carry a distilled body.
/// - `distilled_tokens`: sum of per-match `token_count` over the same rows.
/// - `skim_omitted_tokens`: tokens removed by skim; `None` when skim not applied.
pub fn measure_distilled_savings(
    original_tokens: i64,
    distilled_tokens: i64,
    skim_omitted_tokens: Option<i64>,
) -> DistilledSavings {
    let omitted = skim_omitted_tokens.unwrap_or(0);
    let returned = distilled_tokens - omitted;
    let saved = original_tokens - distilled_tokens;

    // Integer-only rounding: half-away-from-zero of (saved * 100 / original).
    // Rust's i64 division truncates toward zero, so we add half the
    // denominator before dividing. Positive and negative paths are handled
    // separately so the bias is always away from zero.
    let percent = if original_tokens == 0 {
        0
    } else {
        let scaled = saved * 100;
        let half = original_tokens / 2;
        if saved >= 0 {
            (scaled + half) / original_tokens
        } else {
            -((-scaled + half) / original_tokens)
        }
    };

    let skim_struct = skim_omitted_tokens.map(|o| DistilledSkim { omitted_tokens: o });
    let display = build_display(returned, original_tokens, saved, percent, &skim_struct);

    DistilledSavings {
        returned_tokens: returned,
        original_tokens,
        saved_tokens: saved,
        saved_percent: percent,
        estimated: true,
        estimator: ESTIMATOR_NAME.to_string(),
        skim: skim_struct,
        display,
    }
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    // Thousands formatter
    #[test]
    fn format_thousands_zero() {
        assert_eq!(format_thousands(0), "0");
    }

    #[test]
    fn format_thousands_small() {
        assert_eq!(format_thousands(800), "800");
    }

    #[test]
    fn format_thousands_four_digits() {
        assert_eq!(format_thousands(1200), "1,200");
    }

    #[test]
    fn format_thousands_seven_digits() {
        assert_eq!(format_thousands(1234567), "1,234,567");
    }

    // Rounding cases matching the mission spec and Swift unit tests.

    #[test]
    fn rounding_33_percent() {
        // original=3, distilled=2 -> saved=1 -> 1*100/3 = 33.33 -> 33
        let s = measure_distilled_savings(3, 2, None);
        assert_eq!(s.saved_percent, 33);
    }

    #[test]
    fn rounding_67_percent() {
        // original=3, distilled=1 -> saved=2 -> 2*100/3 = 66.67 -> 67
        let s = measure_distilled_savings(3, 1, None);
        assert_eq!(s.saved_percent, 67);
    }

    #[test]
    fn rounding_negative_50_percent() {
        // original=2, distilled=3 -> saved=-1 -> -1*100/2 = -50
        let s = measure_distilled_savings(2, 3, None);
        assert_eq!(s.saved_percent, -50);
    }

    #[test]
    fn rounding_half_rounds_up() {
        // original=200, distilled=199 -> saved=1 -> 1*100/200 = 0.5 -> rounds to 1
        let s = measure_distilled_savings(200, 199, None);
        assert_eq!(s.saved_percent, 1);
    }

    #[test]
    fn rounding_negative_half_rounds_away() {
        // original=200, distilled=201 -> saved=-1 -> -0.5 -> rounds to -1
        let s = measure_distilled_savings(200, 201, None);
        assert_eq!(s.saved_percent, -1);
    }

    // Serialisation: skim absent means no "skim" key in JSON output.
    #[test]
    fn skim_absent_no_skim_key_in_json() {
        let s = measure_distilled_savings(1000, 800, None);
        assert!(s.skim.is_none());
        let json = serde_json::to_string(&s).expect("serialise");
        assert!(
            !json.contains("\"skim\""),
            "skim key must be absent when skim is None, got: {json}"
        );
    }

    // Round-trip with skim.
    #[test]
    fn round_trip_with_skim() {
        let s = measure_distilled_savings(2000, 1200, Some(700));
        let json = serde_json::to_string(&s).expect("serialise");
        let back: DistilledSavings = serde_json::from_str(&json).expect("deserialise");
        assert_eq!(s, back);
    }

    // Round-trip without skim.
    #[test]
    fn round_trip_without_skim() {
        let s = measure_distilled_savings(2000, 1200, None);
        let json = serde_json::to_string(&s).expect("serialise");
        let back: DistilledSavings = serde_json::from_str(&json).expect("deserialise");
        assert_eq!(s, back);
    }
}
