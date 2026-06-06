//! The FDC code-state classifier. Port of `LatticeCodeState.swift` and
//! `LatticeCodeGrammar` in Swift EideticLib.
//!
//! An FDC code string presented to `classify_lattice_code` is one of three
//! things:
//!
//!   - `Malformed`  — the string does not match the FDC code grammar.
//!   - `Known`      — well-formed and present in the caller's bound canon
//!                    (the `known_codes` set passed by the caller).
//!   - `Pending`    — well-formed but not in the caller's bound canon.
//!                    Accepted, stored, and round-tripped intact; resolvable
//!                    on the next canon pull.
//!
//! The grammar (`LatticeCodeGrammar::is_well_formed`) is a parallel
//! implementation of `LatticeCodeGrammar.isWellFormed(_:)` in Swift
//! EideticLib. Both mirror `Code.isWellFormed(_:)` in LatticeLib.
//! Agreement is enforced by shared conformance vectors.
//!
//! This module is dependency-free (no lattice_lib import): the grammar
//! check is pure-string arithmetic. `classify_lattice_code` (in `lib.rs`)
//! uses this module without loading the FDC reference data.

use std::collections::HashSet;
use serde::{Deserialize, Serialize};

/// The state a candidate FDC code string is in relative to a bound canon.
///
/// `Serialize`/`Deserialize` so a pending code round-trips intact through
/// storage layers — the core invariant of the valid-but-unknown-code
/// requirement from the launch plan. The encoding mirrors the Swift
/// `Codable` encoding: a tagged enum with the associated value.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "state", content = "code", rename_all = "camelCase")]
pub enum LatticeCodeState {
    /// The string does not match the FDC code grammar. The associated
    /// value preserves the original input for error reporting.
    Malformed(String),

    /// Well-formed and present in the bound canon. The associated value
    /// is the code itself; resolution to a label/entry is performed by
    /// the consumer through their LatticeLib canon.
    Known(String),

    /// Well-formed but not present in the bound canon — the pending
    /// state. Consumers must accept and round-trip the code intact; it
    /// will resolve on the next canon pull or when a newer canon ships.
    Pending(String),
}

impl LatticeCodeState {
    /// The original input string, regardless of state. Lets storage
    /// layers round-trip the value without unpacking.
    pub fn raw_code(&self) -> &str {
        match self {
            LatticeCodeState::Malformed(c) => c,
            LatticeCodeState::Known(c) => c,
            LatticeCodeState::Pending(c) => c,
        }
    }

    /// True when the code passed the grammar check. False only for
    /// `Malformed`. Mirrors Swift's `LatticeCodeState.isWellFormed`.
    pub fn is_well_formed(&self) -> bool {
        !matches!(self, LatticeCodeState::Malformed(_))
    }
}

/// The FDC code grammar — a dependency-free pure-string check.
///
/// Parallel implementation of Swift `LatticeCodeGrammar.isWellFormed(_:)`.
/// Grammar rule: three ASCII digits optionally followed by a dot and up to
/// eight ASCII digits. Matches `Code.isWellFormed(_:)` in LatticeLib.
pub struct LatticeCodeGrammar;

impl LatticeCodeGrammar {
    /// Maximum digits permitted after the decimal point.
    /// Mirrors Swift's `LatticeCodeGrammar.maxExtensionDigits` (v1: 8).
    /// Locked across both implementations.
    pub const MAX_EXTENSION_DIGITS: usize = 8;

    /// True if `code` matches the FDC grammar: three ASCII digits
    /// optionally followed by a dot and up to eight ASCII digits.
    pub fn is_well_formed(code: &str) -> bool {
        let mut parts = code.splitn(2, '.');
        let integer_part = match parts.next() {
            Some(p) => p,
            None => return false,
        };

        // Integer part: exactly three ASCII decimal digits.
        if integer_part.len() != 3 || !integer_part.bytes().all(|b| b.is_ascii_digit()) {
            return false;
        }

        // Extension part: if present, 1–8 ASCII decimal digits.
        match parts.next() {
            None => true,
            Some(ext) => {
                !ext.is_empty()
                    && ext.len() <= Self::MAX_EXTENSION_DIGITS
                    && ext.bytes().all(|b| b.is_ascii_digit())
            }
        }
    }
}

/// Classifies a candidate FDC code string against the grammar and a supplied
/// known-code set, without loading the FDC reference data.
///
/// Port of `EideticLib.classifyLatticeCode(_:knownCodes:)` in Swift.
///
/// - If the code fails the grammar: `LatticeCodeState::Malformed(code)`.
/// - If the code is in `known_codes`: `LatticeCodeState::Known(code)`.
/// - Otherwise: `LatticeCodeState::Pending(code)`.
pub fn classify_lattice_code(code: &str, known_codes: &HashSet<String>) -> LatticeCodeState {
    if !LatticeCodeGrammar::is_well_formed(code) {
        return LatticeCodeState::Malformed(code.to_string());
    }
    if known_codes.contains(code) {
        return LatticeCodeState::Known(code.to_string());
    }
    LatticeCodeState::Pending(code.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    // ── LatticeCodeGrammar ───────────────────────────────────────────────

    #[test]
    fn grammar_accepts_three_digit_code() {
        // Mirrors Swift `grammarAcceptsThreeDigitCode`.
        assert!(LatticeCodeGrammar::is_well_formed("540"));
    }

    #[test]
    fn grammar_accepts_extension() {
        // Mirrors Swift `grammarAcceptsExtension`.
        assert!(LatticeCodeGrammar::is_well_formed("540.137"));
        assert!(LatticeCodeGrammar::is_well_formed("000.00000000")); // max 8 ext digits
    }

    #[test]
    fn grammar_rejects_short_integer_part() {
        // Mirrors Swift `grammarRejectsShortIntegerPart`.
        assert!(!LatticeCodeGrammar::is_well_formed("54"));
    }

    #[test]
    fn grammar_rejects_long_integer_part() {
        // Mirrors Swift `grammarRejectsLongIntegerPart`.
        assert!(!LatticeCodeGrammar::is_well_formed("5400"));
    }

    #[test]
    fn grammar_rejects_trailing_dot() {
        // Mirrors Swift `grammarRejectsTrailingDot`.
        assert!(!LatticeCodeGrammar::is_well_formed("540."));
    }

    #[test]
    fn grammar_rejects_overlong_extension() {
        // Mirrors Swift `grammarRejectsOverlongExtension`.
        // 9 digits after the dot exceeds maxExtensionDigits (8).
        assert!(!LatticeCodeGrammar::is_well_formed("540.123456789"));
    }

    #[test]
    fn grammar_rejects_non_digit() {
        // Mirrors Swift `grammarRejectsNonDigit`.
        assert!(!LatticeCodeGrammar::is_well_formed("54a"));
        assert!(!LatticeCodeGrammar::is_well_formed("540.1a"));
    }

    #[test]
    fn grammar_rejects_empty_string() {
        assert!(!LatticeCodeGrammar::is_well_formed(""));
    }

    #[test]
    fn grammar_max_extension_digits_is_eight() {
        // Locks the constant against accidental drift.
        assert_eq!(LatticeCodeGrammar::MAX_EXTENSION_DIGITS, 8);
    }

    // ── classify_lattice_code ────────────────────────────────────────────

    #[test]
    fn classify_known_code() {
        // Mirrors Swift `classifyKnownCode`.
        let known: HashSet<String> = ["540".to_string()].into();
        let state = classify_lattice_code("540", &known);
        assert_eq!(state, LatticeCodeState::Known("540".to_string()));
        assert!(state.is_well_formed());
    }

    #[test]
    fn classify_pending_code() {
        // Well-formed but not in the bound canon — the valid-but-unknown
        // state. Mirrors Swift `classifyPendingCode`.
        let known: HashSet<String> = ["540".to_string(), "541".to_string()].into();
        let state = classify_lattice_code("999.42", &known);
        assert_eq!(state, LatticeCodeState::Pending("999.42".to_string()));
        assert!(state.is_well_formed());
    }

    #[test]
    fn classify_malformed_code() {
        // Mirrors Swift `classifyMalformedCode`.
        let known: HashSet<String> = HashSet::new();
        let state = classify_lattice_code("bogus", &known);
        assert_eq!(state, LatticeCodeState::Malformed("bogus".to_string()));
        assert!(!state.is_well_formed());
    }

    #[test]
    fn pending_code_round_trips_through_json() {
        // The core invariant from the launch plan: a pending code round-trips
        // intact through storage. Mirrors Swift `pendingCodeRoundTripsThroughJSON`.
        let original = LatticeCodeState::Pending("999.42".to_string());
        let json = serde_json::to_string(&original).expect("serialize");
        let decoded: LatticeCodeState = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(decoded, original);
        assert_eq!(decoded.raw_code(), "999.42");
    }

    #[test]
    fn known_code_round_trips_through_json() {
        // Mirrors Swift `knownCodeRoundTripsThroughJSON`.
        let original = LatticeCodeState::Known("540.137".to_string());
        let json = serde_json::to_string(&original).expect("serialize");
        let decoded: LatticeCodeState = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(decoded, original);
    }

    #[test]
    fn raw_code_exposes_input_for_every_state() {
        // Mirrors Swift `rawCodeExposesInputForEveryState`.
        assert_eq!(LatticeCodeState::Known("540".to_string()).raw_code(), "540");
        assert_eq!(LatticeCodeState::Pending("999.9".to_string()).raw_code(), "999.9");
        assert_eq!(LatticeCodeState::Malformed("xyz".to_string()).raw_code(), "xyz");
    }

    #[test]
    fn empty_known_set_produces_pending_for_well_formed_code() {
        let state = classify_lattice_code("100", &HashSet::new());
        assert_eq!(state, LatticeCodeState::Pending("100".to_string()));
    }
}
