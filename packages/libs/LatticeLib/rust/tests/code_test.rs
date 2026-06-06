// code_test.rs — FDC code grammar conformance
//
// Mirrors Swift CodeTests.swift exactly. Every input/expected pair here
// must produce the same result from Rust `is_well_formed` / `integer_base`
// as from Swift `Code.isWellFormed` / `Code.integerBase(of:)`.
//
// Conformance scope:
//   Swift Code.isWellFormed  == Rust is_well_formed  (same result for all inputs)
//   Swift Code.integerBase   == Rust integer_base    (same result for all inputs)
//   Swift Code.maxExtensionDigits == Rust MAX_EXTENSION_DIGITS (both 8)
//
// These are pure string predicates with no seed dependency.

use lattice_lib::code::{is_well_formed, integer_base, MAX_EXTENSION_DIGITS};

/// MAX_EXTENSION_DIGITS must equal 8 on both sides.
#[test]
fn max_extension_digits_is_eight() {
    assert_eq!(MAX_EXTENSION_DIGITS, 8);
}

/// Bare three-digit integers are well-formed (mirrors Swift "threeDigit" test).
#[test]
fn three_digit_integer_is_well_formed() {
    assert!(is_well_formed("000"));
    assert!(is_well_formed("540"));
    assert!(is_well_formed("999"));
}

/// Integer plus decimal extension is well-formed (mirrors Swift "withExtension" test).
#[test]
fn integer_with_extension_is_well_formed() {
    assert!(is_well_formed("540.1"));
    assert!(is_well_formed("540.12345678")); // exactly MAX_EXTENSION_DIGITS digits
}

/// Extension is capped at MAX_EXTENSION_DIGITS (mirrors Swift "extensionCap" test).
#[test]
fn extension_cap_is_enforced() {
    // Nine digits exceeds the cap.
    assert!(!is_well_formed("540.123456789"));
}

/// Malformed inputs are rejected (mirrors Swift "malformed" test).
#[test]
fn malformed_inputs_are_rejected() {
    assert!(!is_well_formed(""));            // empty
    assert!(!is_well_formed("54"));          // two digits (short)
    assert!(!is_well_formed("5400"));        // four digits before dot
    assert!(!is_well_formed("540."));        // dot without extension
    assert!(!is_well_formed(".540"));        // leading dot
    assert!(!is_well_formed("abc"));         // non-digit
    assert!(!is_well_formed("540.abc"));     // non-digit extension
}

/// integer_base parses the three-digit prefix (mirrors Swift "integerBase" test).
#[test]
fn integer_base_parses_prefix() {
    assert_eq!(integer_base("540.137"), Some(540));
    assert_eq!(integer_base("000"), Some(0));
    assert_eq!(integer_base("malformed"), None);
}

/// integer_base returns None for every malformed input that is_well_formed rejects.
#[test]
fn integer_base_returns_none_for_malformed() {
    let malformed = ["", "54", "5400", "540.", ".540", "abc", "540.abc", "540.123456789"];
    for &code in &malformed {
        assert_eq!(
            integer_base(code),
            None,
            "expected None for malformed input {:?}",
            code
        );
    }
}

/// Additional boundary: single-digit, two-digit, and four-digit (no dot) are rejected.
#[test]
fn boundary_digit_counts_rejected() {
    assert!(!is_well_formed("0"));
    assert!(!is_well_formed("00"));
    assert!(!is_well_formed("0000"));
}

/// Exact extension-length boundary: 1 through 8 digits all pass; 9 fails.
#[test]
fn extension_length_boundary() {
    assert!(is_well_formed("540.1"));
    assert!(is_well_formed("540.12"));
    assert!(is_well_formed("540.123"));
    assert!(is_well_formed("540.1234"));
    assert!(is_well_formed("540.12345"));
    assert!(is_well_formed("540.123456"));
    assert!(is_well_formed("540.1234567"));
    assert!(is_well_formed("540.12345678")); // 8 digits — max
    assert!(!is_well_formed("540.123456789")); // 9 digits — over cap
}
