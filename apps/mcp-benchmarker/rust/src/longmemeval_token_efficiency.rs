//! longmemeval_token_efficiency.rs — Token estimator and evidence-density scorer.
//!
//! Rust twin of `LongMemEvalTokenEfficiency.swift`. Every function must produce
//! IDENTICAL results to the Swift counterpart for the same inputs — verified by
//! `conformance/token_efficiency_vectors.json` which both twins exercise.
//!
//! # Token estimator
//!
//! Algorithm: `(utf8_byte_count + 3) / 4` (ceiling integer division).
//! - A 4-byte ASCII word counts as 1 token.
//! - A 1-byte string counts as 1 token (never 0 for non-empty input).
//! - Multi-byte UTF-8 characters count proportionally.
//! - Deterministic, zero external dependencies.
//!
//! # Evidence hit
//!
//! Algorithm: normalize both strings (lowercase, trim, collapse whitespace runs
//! to a single space), then check if the normalized evidence is a substring of
//! the normalized payload.
//!
//! Empty evidence always returns false — absence of evidence text is not evidence
//! of a hit (the real HuggingFace LongMemEval corpus omits `has_answer`).

// ─────────────────────────────────────────────────────────────────────────────
// Token estimator
// ─────────────────────────────────────────────────────────────────────────────

/// Estimates the token count of a string using the UTF-8 byte approximation.
///
/// Algorithm: `(utf8_byte_count + 3) / 4` (ceiling integer division, d=4).
/// Returns 0 for an empty string.
///
/// Twin of Swift `lmeEstimateTokens(_:)`.
pub fn lme_estimate_tokens(text: &str) -> usize {
    let byte_count = text.len(); // str::len() returns UTF-8 byte count
    // Ceiling division: (n + d-1) / d with d=4.
    (byte_count + 3) / 4
}

// ─────────────────────────────────────────────────────────────────────────────
// Evidence normalization
// ─────────────────────────────────────────────────────────────────────────────

/// Normalizes a string for evidence-hit comparison.
///
/// Steps:
///   1. Lowercase.
///   2. Split on any whitespace (including `\n`, `\r`, `\t`).
///   3. Drop empty tokens.
///   4. Rejoin with a single space.
///
/// Twin of Swift `lmeNormalizeForEvidence(_:)`.
pub fn lme_normalize_for_evidence(text: &str) -> String {
    text.to_lowercase()
        .split_whitespace()
        .collect::<Vec<&str>>()
        .join(" ")
}

// ─────────────────────────────────────────────────────────────────────────────
// Evidence-density hit
// ─────────────────────────────────────────────────────────────────────────────

/// Returns true when the evidence text appears (case-insensitively) in the payload.
///
/// Both arguments are normalized before comparison.
/// Empty `evidence_text` always returns false.
///
/// Twin of Swift `lmeEvidenceHit(evidenceText:payloadText:)`.
pub fn lme_evidence_hit(evidence_text: &str, payload_text: &str) -> bool {
    let norm_evidence = lme_normalize_for_evidence(evidence_text);
    if norm_evidence.is_empty() {
        return false;
    }
    let norm_payload = lme_normalize_for_evidence(payload_text);
    norm_payload.contains(norm_evidence.as_str())
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests — conformance vectors
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use std::path::{Path, PathBuf};

    /// Resolves `conformance/<filename>` relative to the Cargo manifest directory.
    ///
    /// `CARGO_MANIFEST_DIR` is set by Cargo at build/test time to the absolute path
    /// of the directory containing `Cargo.toml` (i.e. `rust/`). One `.parent()` step
    /// reaches `apps/mcp-benchmarker/`, where `conformance/` lives.
    fn conformance_path(filename: &str) -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()  // apps/mcp-benchmarker/
            .unwrap()
            .join("conformance")
            .join(filename)
    }

    #[test]
    fn token_estimator_vectors() {
        let path = conformance_path("token_efficiency_vectors.json");
        let data = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("cannot read {}: {}", path.display(), e));
        let json: Value = serde_json::from_str(&data)
            .expect("token_efficiency_vectors.json is not valid JSON");

        let cases = json["token_estimator_cases"]
            .as_array()
            .expect("missing token_estimator_cases array");

        for c in cases {
            let id = c["id"].as_str().unwrap_or("(unknown)");
            let input = c["input"].as_str().expect("missing input");
            let expected = c["expected_tokens"]
                .as_u64()
                .expect("missing expected_tokens") as usize;
            let actual = lme_estimate_tokens(input);
            assert_eq!(
                actual, expected,
                "token estimator vector '{id}': expected {expected}, got {actual}"
            );
        }
    }

    #[test]
    fn evidence_hit_vectors() {
        let path = conformance_path("token_efficiency_vectors.json");
        let data = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("cannot read {}: {}", path.display(), e));
        let json: Value = serde_json::from_str(&data)
            .expect("token_efficiency_vectors.json is not valid JSON");

        let cases = json["evidence_hit_cases"]
            .as_array()
            .expect("missing evidence_hit_cases array");

        for c in cases {
            let id = c["id"].as_str().unwrap_or("(unknown)");
            let evidence_text = c["evidence_text"].as_str().expect("missing evidence_text");
            let payload_text = c["payload_text"].as_str().expect("missing payload_text");
            let expected = c["expected_hit"].as_bool().expect("missing expected_hit");
            let actual = lme_evidence_hit(evidence_text, payload_text);
            assert_eq!(
                actual, expected,
                "evidence hit vector '{id}': expected {expected}, got {actual}"
            );
        }
    }
}
