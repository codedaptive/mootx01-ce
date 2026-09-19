//! Payload-economics shape-variant arms V0–V5 (PAYLOAD-ARMS).
//! Twin of Swift `PayloadArm.swift`.
//!
//! Prices candidate-row FIELD CONTRIBUTIONS without reopening the ruled
//! ARIA 2.0.0 result contract. The product payload never changes: the
//! benchmarker post-processes the FULL ruled payload harness-side, per
//! arm, before row text feeds judged output. The ruled dense row is
//!
//! `<UUID> · <subject> · <bestSpan> · <sscFacts> ·
//! <eventTime ISO8601> · <score>`
//!
//! (` · ` = space, U+00B7 MIDDLE DOT, space; S2 rows carry five columns,
//! score absent). A suppressed column re-renders as the contract's own
//! absent-field sentinel `-`, so a stripped row stays IN-GRAMMAR: any
//! downstream dense-row parse still reads it, the UUID/subject columns
//! survive, and only the priced content is removed. Retrieval scoring is
//! unaffected by design — the seam call sites strip only the result's
//! `text_blocks`; `ordered_ids`/`items` (parsed from the full payload)
//! pass through untouched.
//!
//! Arm identity is recorded in the report's run_environment as
//! `payload_arm` (`IdentityEnvironment`). A run with no arm records
//! nothing and is byte-identical to pre-arm behaviour.

/// The dense-row field separator — space, U+00B7 MIDDLE DOT, space.
/// Must stay identical to the constant in `mcp_result.rs`.
const SEPARATOR: &str = " \u{00B7} ";

/// The ruled contract's absent-field sentinel (`-` on the wire).
const ABSENT_SENTINEL: &str = "-";

/// One payload-economics shape-variant arm. The wire spelling is
/// lowercase `v0`, `v1`, `v4`, `v5` (`--payload-arm` / `MOOT_BENCH_PAYLOAD_ARM`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PayloadArm {
    /// Floor: uuid + subject + eventTime + score. bestSpan and sscFacts are
    /// sentineled.
    V0,
    /// Floor + bestSpan (only sscFacts sentineled).
    V1,
    /// Full ruled row — the identity transform / control cell.
    V4,
    /// Full ruled row with CONTROL LINES suppressed: non-row lines (e.g.
    /// the `found N candidate memories…` header) are dropped from
    /// payloads that contain at least one dense row. A payload with no
    /// dense rows passes through unchanged so hydrated full-body
    /// payloads are never wiped.
    V5,
}

impl PayloadArm {
    /// The CLI/env spelling of this arm.
    pub fn as_str(&self) -> &'static str {
        match self {
            PayloadArm::V0 => "v0",
            PayloadArm::V1 => "v1",
            PayloadArm::V4 => "v4",
            PayloadArm::V5 => "v5",
        }
    }

    /// 0-based ruled-row column indexes this arm suppresses.
    /// Columns: 0 uuid · 1 subject · 2 bestSpan · 3 sscFacts ·
    /// 4 eventTime · 5 score (absent on S2 rows). The suppressible columns
    /// are 2 and 3 only, so the same set applies to 5-column (S2) and
    /// 6-column (S1) rows.
    fn suppressed_columns(&self) -> &'static [usize] {
        match self {
            PayloadArm::V0 => &[2, 3],
            PayloadArm::V1 => &[3],
            PayloadArm::V4 | PayloadArm::V5 => &[],
        }
    }

    /// True when the line parses as a ruled dense row (5 or 6 ` · `
    /// separated columns). Anything else is a control line (header,
    /// coaching text, hydrated body text).
    fn is_dense_row(line: &str) -> bool {
        let n = line.split(SEPARATOR).count();
        n == 5 || n == 6
    }

    /// Re-renders one dense row with this arm's suppressed columns
    /// replaced by the absent sentinel. Non-row lines and V4/V5 rows
    /// return unchanged. Idempotent: a sentinel column re-sentinels to
    /// itself.
    pub fn strip_row(&self, row: &str) -> String {
        let suppressed = self.suppressed_columns();
        if suppressed.is_empty() {
            return row.to_string();
        }
        let fields: Vec<&str> = row.split(SEPARATOR).collect();
        if fields.len() != 5 && fields.len() != 6 {
            return row.to_string();
        }
        fields
            .iter()
            .enumerate()
            .map(|(idx, field)| {
                if suppressed.contains(&idx) { ABSENT_SENTINEL } else { field }
            })
            .collect::<Vec<&str>>()
            .join(SEPARATOR)
    }

    /// Applies the arm to one multi-line payload block. V0, V1 strip each
    /// dense row and pass control lines through; V4 is the identity; V5
    /// keeps rows whole and drops control lines (only when the block
    /// actually contains dense rows — see the variant doc).
    pub fn apply_payload(&self, payload: &str) -> String {
        if *self == PayloadArm::V4 {
            return payload.to_string();
        }
        let lines: Vec<&str> = payload.split('\n').collect();
        if *self == PayloadArm::V5 {
            if !lines.iter().any(|l| Self::is_dense_row(l)) {
                return payload.to_string();
            }
            return lines
                .into_iter()
                .filter(|l| Self::is_dense_row(l))
                .collect::<Vec<&str>>()
                .join("\n");
        }
        lines
            .iter()
            .map(|l| {
                if Self::is_dense_row(l) { self.strip_row(l) } else { l.to_string() }
            })
            .collect::<Vec<String>>()
            .join("\n")
    }

    /// Applies the arm to each MCP text block independently.
    pub fn apply_text_blocks(&self, blocks: &[String]) -> Vec<String> {
        if *self == PayloadArm::V4 {
            return blocks.to_vec();
        }
        blocks.iter().map(|b| self.apply_payload(b)).collect()
    }
}

/// Strips only the `text_blocks` of a seam-routed tool result through the
/// arm. `ordered_ids`/`items`/`write_assigned_id` (parsed from the FULL
/// ruled payload) pass through untouched — retrieval scoring is
/// arm-invariant by construction. `None` (and V4) return the result
/// unchanged. Twin of the arm application inside Swift
/// `retrieveThroughSeam`; the Rust seam call sites own the actual call, so
/// they own the strip too.
pub fn strip_tool_result(
    arm: Option<PayloadArm>,
    mut result: crate::mcp_result::MCPToolResult,
) -> crate::mcp_result::MCPToolResult {
    if let Some(a) = arm {
        if a != PayloadArm::V4 {
            result.text_blocks = a.apply_text_blocks(&result.text_blocks);
        }
    }
    result
}

/// Parses a payload-arm spelling (`"v0"`, `"v1"`, `"v4"`, `"v5"`). `None`
/// in, `None` out — the arm machinery stays inert when neither
/// `--payload-arm` nor `MOOT_BENCH_PAYLOAD_ARM` is present. An unknown value
/// is a HARD error: an unrecognized arm silently falling back to the full
/// payload would record a mislabeled cell (same fail-loud rule as
/// `MOOT_BENCH_RETRIEVAL_ARGS`). Twin of Swift `parsePayloadArm`.
pub fn parse_payload_arm(raw: Option<&str>) -> Result<Option<PayloadArm>, String> {
    let raw = match raw {
        Some(r) if !r.is_empty() => r,
        _ => return Ok(None),
    };
    match raw {
        "v0" => Ok(Some(PayloadArm::V0)),
        "v1" => Ok(Some(PayloadArm::V1)),
        "v4" => Ok(Some(PayloadArm::V4)),
        "v5" => Ok(Some(PayloadArm::V5)),
        _ => Err(format!(
            "--payload-arm / MOOT_BENCH_PAYLOAD_ARM must be one of v0|v1|v4|v5; got '{raw}'"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // The fixed full ruled row (S1, 6 columns) used by every arm
    // assertion — same fixture as Swift `PayloadArmTests`.
    const ROW: &str = "0B1F4C2A-9D8E-4F00-B2C3-A5D6E7F80912 \u{00B7} kettle descaling schedule \u{00B7} The kettle needs descaling every six weeks. \u{00B7} SSC17 \u{00B7} 2026-08-01T09:30:00Z \u{00B7} 0.9312";

    #[test]
    fn arm_subsets_from_fixed_row() {
        // V0 suppresses bestSpan (col 2) and sscFacts (col 3).
        assert_eq!(
            PayloadArm::V0.strip_row(ROW),
            "0B1F4C2A-9D8E-4F00-B2C3-A5D6E7F80912 \u{00B7} kettle descaling schedule \u{00B7} - \u{00B7} - \u{00B7} 2026-08-01T09:30:00Z \u{00B7} 0.9312"
        );
        // V1 suppresses only sscFacts (col 3).
        assert_eq!(
            PayloadArm::V1.strip_row(ROW),
            "0B1F4C2A-9D8E-4F00-B2C3-A5D6E7F80912 \u{00B7} kettle descaling schedule \u{00B7} The kettle needs descaling every six weeks. \u{00B7} - \u{00B7} 2026-08-01T09:30:00Z \u{00B7} 0.9312"
        );
        assert_eq!(PayloadArm::V4.strip_row(ROW), ROW);
        assert_eq!(PayloadArm::V5.strip_row(ROW), ROW);
    }

    #[test]
    fn v5_suppresses_control_lines_but_never_hydrated_bodies() {
        let payload = format!("found 1 candidate memories, one per line\n{ROW}");
        assert_eq!(PayloadArm::V5.apply_payload(&payload), ROW);
        let hydrated = "Full memory body text.\nSecond line of the body.";
        assert_eq!(PayloadArm::V5.apply_payload(hydrated), hydrated);
    }

    #[test]
    fn control_lines_pass_through_below_v5_and_s2_rows_strip() {
        let payload = format!("found 1 candidate memories, one per line\n{ROW}");
        let out = PayloadArm::V0.apply_payload(&payload);
        assert!(out.starts_with("found 1 candidate memories, one per line\n"));
        assert!(out.contains(" \u{00B7} - \u{00B7} "));
        // 5-column S2 row (no score) strips by the same positions.
        let s2 = "0B1F4C2A-9D8E-4F00-B2C3-A5D6E7F80912 \u{00B7} kettle descaling schedule \u{00B7} The kettle needs descaling every six weeks. \u{00B7} SSC17 \u{00B7} 2026-08-01T09:30:00Z";
        assert_eq!(
            PayloadArm::V0.strip_row(s2),
            "0B1F4C2A-9D8E-4F00-B2C3-A5D6E7F80912 \u{00B7} kettle descaling schedule \u{00B7} - \u{00B7} - \u{00B7} 2026-08-01T09:30:00Z"
        );
        // Idempotence.
        let once = PayloadArm::V0.strip_row(ROW);
        assert_eq!(PayloadArm::V0.strip_row(&once), once);
    }

    #[test]
    fn parse_is_fail_loud() {
        assert_eq!(parse_payload_arm(None).unwrap(), None);
        assert_eq!(parse_payload_arm(Some("")).unwrap(), None);
        assert_eq!(parse_payload_arm(Some("v0")).unwrap(), Some(PayloadArm::V0));
        assert_eq!(parse_payload_arm(Some("v1")).unwrap(), Some(PayloadArm::V1));
        assert_eq!(parse_payload_arm(Some("v4")).unwrap(), Some(PayloadArm::V4));
        assert_eq!(parse_payload_arm(Some("v5")).unwrap(), Some(PayloadArm::V5));
        // v2 and v3 were defined solely by the adornment column; removed in
        // DENSE_ROW_RETIRE. They must fail loudly rather than silently falling
        // back to a different arm.
        assert!(parse_payload_arm(Some("v2")).is_err());
        assert!(parse_payload_arm(Some("v3")).is_err());
        assert!(parse_payload_arm(Some("v9")).is_err());
    }
}
