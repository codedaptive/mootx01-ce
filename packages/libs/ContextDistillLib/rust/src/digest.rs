//! Digest, token-estimation, and enrichment-split utilities.
//!
//! Ports three top-level functions from distill_plus_converter.py:
//!   - `source_digest` — SHA-256 hex digest of the source text.
//!   - `estimate_tokens` — deterministic advisory token count.
//!   - `split_enrichment` — split a distilled record into body and trailer.
//!
//! All three are pure functions with no I/O, no randomness, no `Date()`.

use substrate_kernel::sha256;

// ---------------------------------------------------------------------------
// source_digest
// ---------------------------------------------------------------------------

/// Compute the SHA-256 hex digest of `content` encoded as UTF-8.
///
/// Mirrors Python:
/// ```python
/// def source_digest(content: str) -> str:
///     return hashlib.sha256(content.encode("utf-8")).hexdigest()
/// ```
///
/// The result is a 64-character lowercase hex string.
pub fn source_digest(content: &str) -> String {
    let hash_bytes = sha256::hash(content.as_bytes());
    // Format each byte as two lowercase hex digits — mirrors Python's
    // `hexdigest()` which always uses lowercase and zero-pads.
    hash_bytes.iter().map(|b| format!("{:02x}", b)).collect()
}

// ---------------------------------------------------------------------------
// estimate_tokens
// ---------------------------------------------------------------------------

/// Deterministic advisory token-count estimator.
///
/// Mirrors Python exactly:
/// ```python
/// def estimate_tokens(text: str) -> int:
///     words = text.split()
///     if not words:
///         return 0
///     return (3 * len(text.encode("utf-8")) + 16 * len(words) + 12) // 24
/// ```
///
/// Python `//` is floor division; for strictly non-negative operands
/// (byte length and word count are always ≥ 0) it equals Rust integer
/// division (which truncates toward zero).
///
/// Python `text.split()` (no argument) splits on any whitespace run
/// and never produces empty tokens, so `len(words)` is the number of
/// whitespace-delimited non-empty tokens.
pub fn estimate_tokens(text: &str) -> u64 {
    // Count whitespace-delimited tokens (mirrors Python str.split()).
    let word_count = text.split_whitespace().count() as u64;
    if word_count == 0 {
        return 0;
    }
    let byte_len = text.len() as u64; // str::len() returns UTF-8 byte count
    // Formula: (3 * bytes + 16 * words + 12) // 24
    (3 * byte_len + 16 * word_count + 12) / 24
}

// ---------------------------------------------------------------------------
// split_enrichment
// ---------------------------------------------------------------------------

/// Split a distilled record into its rendering body and grammar-v1 trailer.
///
/// Mirrors Python:
/// ```python
/// TRAILER_RE = re.compile(
///     r"(?P<trailer>\s+\(\*\[\s.*?\s\]\*\))\s*$",
///     re.DOTALL,
/// )
///
/// def split_enrichment(distilled: str) -> tuple[str, str]:
///     match = TRAILER_RE.search(distilled)
///     if not match:
///         return distilled.strip(), ""
///     return distilled[:match.start()].rstrip(), match.group("trailer").strip()
/// ```
///
/// The trailer grammar is `(*[ ... ]*)` preceded by one or more
/// whitespace characters and optionally followed by trailing whitespace.
///
/// ## Edge cases
/// - No trailer → returns `(text.strip(), "")`.
/// - The DOTALL flag means `.` in the original Python matches newlines;
///   the hand-written scanner handles this explicitly by not excluding
///   any character in the non-greedy interior.
pub fn split_enrichment(distilled: &str) -> (String, String) {
    match find_trailer(distilled) {
        None => (distilled.trim().to_string(), String::new()),
        Some((match_start_cp, trailer_text)) => {
            // body = distilled[:match.start()].rstrip()
            let chars: Vec<char> = distilled.chars().collect();
            let body_chars = &chars[..match_start_cp];
            let body: String = crate::python_text::py_rstrip(body_chars).iter().collect();
            // trailer = match.group("trailer").strip()
            let trailer: String = trailer_text.trim().to_string();
            (body, trailer)
        }
    }
}

/// Locate the LAST (rightmost) TRAILER_RE match in `text`.
///
/// Python's `TRAILER_RE.search()` with a `$` anchor and `re.DOTALL`
/// finds the match closest to the end of the string.  Because the
/// trailer pattern is anchored to `$` (end of string including any
/// trailing newlines under DOTALL), there is at most one match, and
/// it always terminates at or near the end of the string.
///
/// The trailer pattern is:
///   `(?P<trailer>\s+\(\*\[\s.*?\s\]\*\))\s*$`  (re.DOTALL)
///
/// This expands to:
///   1. One or more whitespace chars (the leading `\s+`)
///   2. The literal `(*[`
///   3. One or more whitespace chars (`\s`)
///   4. Any chars (lazy, including newlines due to DOTALL): `.*?`
///   5. One or more whitespace chars (`\s`)
///   6. The literal `]*)`
///   7. Zero or more trailing whitespace chars (`\s*$`)
///
/// The named group `trailer` captures items 1-6.
/// We scan for the LAST occurrence of `\s(*[` working backward from
/// the end, then verify the rest of the grammar forward.
///
/// Returns `Some((match_start_cp, trailer_text))` where `match_start_cp`
/// is the code-point index of the start of the full match (the leading
/// `\s` of the trailer group), and `trailer_text` is the full matched
/// group text.
/// Public wrapper around `find_trailer` for use by `scanners::scan_trailer_re`.
pub fn find_trailer_pub(text: &str) -> Option<(usize, String)> {
    find_trailer(text)
}

fn find_trailer(text: &str) -> Option<(usize, String)> {
    // The pattern `(?P<trailer>\s+\(\*\[\s.*?\s\]\*\))\s*$` (re.DOTALL) requires:
    //   1. Leading `\s+` (whitespace run before the trailer)
    //   2. Literal `(*[`
    //   3. One whitespace char `\s` (interior open)
    //   4. Any chars including newlines `.*?` (non-greedy)
    //   5. One whitespace char `\s` (interior close)
    //   6. Literal `]*)`
    //   7. Trailing `\s*$`
    //
    // Strategy: strip trailing whitespace to find content_end, verify `]*)` at
    // content_end-3, verify interior `\s` at content_end-4, then search backward
    // for `(*[` preceded by `\s+`.  The non-greedy `.*?` means we use the LAST
    // (rightmost) valid `(*[` that satisfies all constraints.
    let chars: Vec<char> = text.chars().collect();
    let n = chars.len();

    // 1. Find content_end (strip trailing whitespace).
    let content_end = crate::python_text::py_rstrip(&chars).len();
    if content_end < 5 {
        // Minimum valid trailer: " (*[ ]*)  " → at least 5 content chars
        return None;
    }
    // Verify `]*)` at content_end-3..content_end
    if chars[content_end - 3] != ']'
        || chars[content_end - 2] != '*'
        || chars[content_end - 1] != ')'
    {
        return None;
    }
    // Verify `\s` just before `]` (interior closing whitespace)
    let just_before_close = content_end - 4;
    if !crate::python_text::is_python_whitespace(chars[just_before_close]) {
        return None;
    }
    // close_interior_end: the position of the final `\s` before `]` (inclusive bound).
    // The interior text ends at content_end-4 (exclusive: from `[`+1 up to here).
    let close_interior_end = content_end - 4; // exclusive upper bound for the interior

    // 2. Search backward for `(*[` with interior `\s` after it.
    let mut search_end = close_interior_end; // search in chars[..search_end]
    loop {
        // Find the last `[` in chars[..search_end]
        let bracket_pos = match chars[..search_end].iter().rposition(|&c| c == '[') {
            Some(p) => p,
            None => return None,
        };
        if bracket_pos < 2 {
            return None;
        }
        // Check for `(*` immediately before `[`
        if chars[bracket_pos - 1] != '*' || chars[bracket_pos - 2] != '(' {
            // Not `(*[`; search for `[` further left.
            if bracket_pos == 0 {
                return None;
            }
            search_end = bracket_pos;
            continue;
        }
        let open_paren_pos = bracket_pos - 2;

        // Verify `\s` immediately after `[` (interior opening whitespace)
        if bracket_pos + 1 >= close_interior_end
            || !crate::python_text::is_python_whitespace(chars[bracket_pos + 1])
        {
            // No room for interior whitespace → try earlier `(*[`
            search_end = open_paren_pos;
            continue;
        }

        // Verify at least one `\s` before `(*[`
        if open_paren_pos == 0
            || !crate::python_text::is_python_whitespace(chars[open_paren_pos - 1])
        {
            search_end = open_paren_pos;
            continue;
        }

        // Find the start of the leading whitespace run.
        let mut ws_start = open_paren_pos - 1;
        while ws_start > 0 && crate::python_text::is_python_whitespace(chars[ws_start - 1]) {
            ws_start -= 1;
        }

        // The trailer group spans ws_start..content_end (including leading \s+ and (*[..]*)).
        let trailer_text: String = chars[ws_start..content_end].iter().collect();
        let _ = n; // n used indirectly through the chars slice
        return Some((ws_start, trailer_text));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_source_digest_ascii() {
        // Known SHA-256: echo -n "hello" | sha256sum
        let d = source_digest("hello");
        assert_eq!(
            d,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
    }

    #[test]
    fn test_source_digest_empty() {
        let d = source_digest("");
        assert_eq!(
            d,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn test_estimate_tokens_empty() {
        assert_eq!(estimate_tokens(""), 0);
    }

    #[test]
    fn test_estimate_tokens_whitespace_only() {
        assert_eq!(estimate_tokens("   "), 0);
    }

    #[test]
    fn test_estimate_tokens_one_word() {
        // words=1, bytes=5: (3*5 + 16*1 + 12) // 24 = (15+16+12)//24 = 43//24 = 1
        assert_eq!(estimate_tokens("hello"), 1);
    }

    #[test]
    fn test_split_enrichment_no_trailer() {
        let (body, trailer) = split_enrichment("Hello world");
        assert_eq!(body, "Hello world");
        assert_eq!(trailer, "");
    }

    #[test]
    fn test_split_enrichment_with_trailer() {
        let text = "Some content (*[ key: value ]*)";
        let (body, trailer) = split_enrichment(text);
        assert_eq!(body, "Some content");
        assert_eq!(trailer, "(*[ key: value ]*)");
    }

    #[test]
    fn test_split_enrichment_with_trailing_whitespace() {
        let text = "Body text (*[ key: value ]*)   ";
        let (body, trailer) = split_enrichment(text);
        assert_eq!(body, "Body text");
        assert_eq!(trailer, "(*[ key: value ]*)");
    }
}
