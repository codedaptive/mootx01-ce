//! Python-semantics text helpers for CDL-01 hand-written scanners.
//!
//! Every function in this module mirrors the behaviour of a Python
//! string or `re` built-in as precisely as possible on `&[char]`
//! (Unicode scalar values, equal to Python code-points for valid
//! UTF-8 excluding surrogates).
//!
//! Where Rust semantics diverge from Python semantics the divergence
//! is documented in an inline comment.

// ---------------------------------------------------------------------------
// Whitespace
// ---------------------------------------------------------------------------

/// Return true if `c` is a Python whitespace character.
///
/// Mirrors `str.isspace()` / `re.compile(r'\s')` (no `re.ASCII`).
///
/// Python's Unicode whitespace set includes, among others:
///   U+0009 HT, U+000A LF, U+000B VT, U+000C FF, U+000D CR,
///   U+0020 SPACE, U+00A0 NBSP, U+2000-U+200A, U+2028, U+2029,
///   U+202F, U+205F, U+3000.
///
/// Rust `char::is_whitespace()` implements the Unicode White_Space
/// property, which covers the same set for all practical inputs in
/// this corpus.  The two properties diverge on a handful of rarely-
/// used code points (e.g. U+0085 NEL is White_Space in Rust/Unicode
/// but not in Python's `\s`).  We use `char::is_whitespace()` here
/// and document the gap.  For the 509-row corpus no divergence was
/// observed.
#[inline]
pub fn is_python_whitespace(c: char) -> bool {
    c.is_whitespace()
}

// ---------------------------------------------------------------------------
// Strip helpers (mirror Python str.strip / lstrip / rstrip)
// ---------------------------------------------------------------------------

/// Return the sub-slice with leading whitespace removed.
/// Mirrors Python `str.lstrip()` (no argument → strips whitespace).
pub fn py_lstrip(chars: &[char]) -> &[char] {
    let start = chars.iter().position(|c| !is_python_whitespace(*c)).unwrap_or(chars.len());
    &chars[start..]
}

/// Return the sub-slice with trailing whitespace removed.
/// Mirrors Python `str.rstrip()` (no argument → strips whitespace).
pub fn py_rstrip(chars: &[char]) -> &[char] {
    let end = chars.iter().rposition(|c| !is_python_whitespace(*c)).map_or(0, |p| p + 1);
    &chars[..end]
}

/// Return the sub-slice with leading and trailing whitespace removed.
/// Mirrors Python `str.strip()` (no argument → strips whitespace).
pub fn py_strip(chars: &[char]) -> &[char] {
    py_rstrip(py_lstrip(chars))
}

// ---------------------------------------------------------------------------
// Split (mirrors Python str.split() with no argument)
// ---------------------------------------------------------------------------

/// Split on any run of whitespace, discarding leading and trailing
/// whitespace runs, and discarding empty tokens.
///
/// Mirrors Python `text.split()` (no argument):
///   ```python
///   "  hello   world  ".split()  # ['hello', 'world']
///   ```
///
/// Note: Python `str.split()` with no argument splits on any
/// consecutive whitespace and never produces empty strings.
pub fn py_split(chars: &[char]) -> Vec<&[char]> {
    let mut result = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        // Skip whitespace
        while i < chars.len() && is_python_whitespace(chars[i]) {
            i += 1;
        }
        if i >= chars.len() {
            break;
        }
        let start = i;
        // Consume non-whitespace token
        while i < chars.len() && !is_python_whitespace(chars[i]) {
            i += 1;
        }
        result.push(&chars[start..i]);
    }
    result
}

// ---------------------------------------------------------------------------
// Case conversion
// ---------------------------------------------------------------------------

/// Convert a char to its Python `str.lower()` equivalent.
///
/// Python's `str.lower()` performs full Unicode case-folding, which can
/// produce multiple chars for a single input (e.g. U+00DF LATIN SMALL
/// LETTER SHARP S → "ss").  Rust `char::to_lowercase()` returns an
/// iterator over the full lowercase sequence, matching Python here.
///
/// The returned `Vec<char>` is almost always length 1; callers that
/// need a scalar approximation may take the first element only, but
/// should document the truncation.
pub fn py_lower_char(c: char) -> Vec<char> {
    c.to_lowercase().collect()
}

/// Lowercase an entire slice, expanding multi-char lowercases.
/// Mirrors Python `str.lower()`.
pub fn py_lower(chars: &[char]) -> Vec<char> {
    chars.iter().flat_map(|c| c.to_lowercase()).collect()
}

// ---------------------------------------------------------------------------
// Character class tests (used in scanner word-class and \b logic)
// ---------------------------------------------------------------------------

/// True if `c` is a Python `\w` character.
///
/// Python's `\w` without `re.ASCII` matches Unicode word characters:
/// letters, digits, and `_`.  Rust `char::is_alphanumeric()` covers
/// the same letter and digit set (Unicode General Category L* + N*).
/// The underscore is added explicitly.
#[inline]
pub fn py_word_char(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// True if `c` is a Python `\d` character.
///
/// In the distill_plus_converter.py oracle all `\d` uses are in ASCII
/// contexts (date/number matching).  Python `\d` without `re.ASCII`
/// matches Unicode digits; in practice the corpus contains only ASCII
/// digits so we use `char::is_ascii_digit()`.
///
/// Divergence note: Python `\d` matches e.g. U+0660 ARABIC-INDIC
/// DIGIT ZERO; `char::is_ascii_digit()` does not.  No such code
/// points appear in the 509-row corpus.
#[inline]
pub fn py_digit(c: char) -> bool {
    c.is_ascii_digit()
}

/// True if `c` is a Python `[A-Za-z0-9]` ASCII alphanumeric character.
///
/// Unlike `py_word_char`, this mirrors explicit `[A-Za-z0-9]` char
/// classes in patterns like WORD_RE that exclude Unicode-only alnum.
#[inline]
pub fn py_ascii_alnum(c: char) -> bool {
    c.is_ascii_alphanumeric()
}

/// True if `c` is an ASCII letter `[A-Za-z]`.
#[inline]
pub fn py_ascii_alpha(c: char) -> bool {
    c.is_ascii_alphabetic()
}

/// True if `c` is an uppercase ASCII letter `[A-Z]`.
#[inline]
pub fn py_ascii_upper(c: char) -> bool {
    c.is_ascii_uppercase()
}

// ---------------------------------------------------------------------------
// Word-boundary detection
// ---------------------------------------------------------------------------

/// Return true if a Python `\b` word boundary exists at `pos` in `chars`.
///
/// Python `\b` (no `re.ASCII`) is a zero-width assertion that matches
/// where the `\w` status changes between the character before and the
/// character after position `pos`:
///
///   `is_word(chars[pos-1]) != is_word(chars[pos])`
///
/// with `is_word(out_of_range)` defined as `false`.
///
/// This uses `py_word_char` (Unicode alnum + `_`) as the `\w` test.
#[inline]
pub fn word_boundary_at(chars: &[char], pos: usize) -> bool {
    let before = if pos > 0 { py_word_char(chars[pos - 1]) } else { false };
    let after = if pos < chars.len() { py_word_char(chars[pos]) } else { false };
    before != after
}

/// Return true if a `\b` word boundary exists BEFORE `pos` (i.e. pos
/// is the START of a potential word match).
///
/// Equivalent to `word_boundary_at(chars, pos)` when the char at `pos`
/// is a word char (which is the usual case for word-start positions).
#[inline]
pub fn word_start_boundary(chars: &[char], pos: usize) -> bool {
    word_boundary_at(chars, pos)
}

/// Return true if a `\b` word boundary exists AFTER the matched region
/// ending at `end` (exclusive).
///
/// This is `word_boundary_at(chars, end)`.
#[inline]
pub fn word_end_boundary(chars: &[char], end: usize) -> bool {
    word_boundary_at(chars, end)
}

// ---------------------------------------------------------------------------
// UTF-8 byte-offset conversion
// ---------------------------------------------------------------------------

/// Compute the UTF-8 byte offset corresponding to code-point index
/// `cp_idx` in `chars`.
///
/// Python code-point indices (used throughout this codebase) are
/// equivalent to indices into `chars` (a `Vec<char>`).  This function
/// converts such an index to the byte offset in the original UTF-8
/// `&str`, which is needed for the `span_utf8_offset_unit` field in
/// oracle output.
///
/// `cp_idx` must be `<= chars.len()`.  If `cp_idx == chars.len()`,
/// returns the total byte length of the string.
pub fn cp_to_utf8_offset(chars: &[char], cp_idx: usize) -> usize {
    chars[..cp_idx].iter().map(|c| c.len_utf8()).sum()
}

// ---------------------------------------------------------------------------
// ASCII word character (used for \b in ASCII-context patterns)
// ---------------------------------------------------------------------------

/// True if `c` is an ASCII word character: `[A-Za-z0-9_]`.
///
/// Some patterns in record_shape_classifier.py use `\b` in purely
/// ASCII contexts.  This narrower definition avoids false boundaries
/// on Unicode accented letters.
#[inline]
pub fn ascii_word_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

/// ASCII-context word boundary: uses `ascii_word_char` instead of
/// `py_word_char`.
#[inline]
pub fn ascii_word_boundary_at(chars: &[char], pos: usize) -> bool {
    let before = if pos > 0 { ascii_word_char(chars[pos - 1]) } else { false };
    let after = if pos < chars.len() { ascii_word_char(chars[pos]) } else { false };
    before != after
}
