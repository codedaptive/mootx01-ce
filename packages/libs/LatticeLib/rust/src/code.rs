// code.rs — FDC code grammar validator
//
// Port of Code.swift. Pure functions; no artifact lookup involved.
//
// Grammar:
//   code     := integer ( '.' digits )?
//   integer  := exactly three ASCII decimal digits (000..999)
//   digits   := 1..MAX_EXTENSION_DIGITS ASCII decimal digits (v1 cap: 8)
//
// Validity is purely grammatical. A well-formed code is accepted by
// tooling regardless of whether any term currently encodes to it. The
// known-vs-pending distinction belongs to the caller (EideticLib
// `classify_lattice_code`). Matches Swift `Code` enum exactly.
//
// Conformance contract:
//   For every code string, `is_well_formed(code)` and `integer_base(code)`
//   must return the same result as Swift `Code.isWellFormed` and
//   `Code.integerBase(of:)` respectively.

/// The maximum number of decimal digits permitted after the '.'.
/// v1 cap: 8. Matches Swift `Code.maxExtensionDigits`.
pub const MAX_EXTENSION_DIGITS: usize = 8;

/// Returns true if `code` matches the FDC code grammar.
///
/// Accepts:
///   - Exactly three ASCII decimal digits ("000".."999")
///   - Three digits, a '.', then 1..MAX_EXTENSION_DIGITS ASCII decimal digits
///
/// Rejects everything else: empty strings, two-digit integers, four-digit
/// integers before the dot, empty extensions ("540."), leading dots
/// (".540"), non-ASCII, non-digit characters.
///
/// Mirrors Swift `Code.isWellFormed(_:)`.
pub fn is_well_formed(code: &str) -> bool {
    // Split on the first '.' only. `splitn(2, '.')` returns at most two
    // parts: the integer portion and (if '.' present) the extension.
    let mut parts = code.splitn(2, '.');

    let integer_part = match parts.next() {
        Some(s) => s,
        None => return false,
    };

    // Integer part: exactly three ASCII decimal digits.
    if integer_part.len() != 3 {
        return false;
    }
    if !integer_part.bytes().all(|b| b.is_ascii_digit()) {
        return false;
    }

    // If no '.' was present, the three-digit integer is the complete code.
    let extension_part = match parts.next() {
        None => return true,
        Some(s) => s,
    };

    // Extension part: 1..MAX_EXTENSION_DIGITS ASCII decimal digits. An
    // empty extension ("540.") is invalid.
    if extension_part.is_empty() {
        return false;
    }
    if extension_part.len() > MAX_EXTENSION_DIGITS {
        return false;
    }
    if !extension_part.bytes().all(|b| b.is_ascii_digit()) {
        return false;
    }

    true
}

/// Returns the three-digit integer base of a well-formed code, or `None`
/// if the code is malformed. "540.137" -> Some(540), "000" -> Some(0).
///
/// Mirrors Swift `Code.integerBase(of:)`.
pub fn integer_base(code: &str) -> Option<u32> {
    if !is_well_formed(code) {
        return None;
    }
    // The integer part is always the first three characters (validated above).
    let int_str = &code[..3];
    // Parse is infallible here: three ASCII decimal digits always fit u32.
    int_str.parse::<u32>().ok()
}
