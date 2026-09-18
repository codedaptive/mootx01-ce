//! Term normalisation — Rust port of `_normalized_terms` from
//! `distill_plus_converter.py`.
//!
//! # What this module provides
//!
//! - [`SCORING_STOPWORDS`] — the union of the basic filler-word drop set and
//!   the extended grammatical stopwords used during scoring and deduplication.
//! - [`normalized_terms`] — lowercases the text, extracts `WORD_RE` tokens,
//!   drops stopwords and very-short tokens, then applies a small fixed stemmer
//!   identical to the Python oracle.
//!
//! # No regex
//! `WORD_RE` (`[A-Za-z0-9]+(?:['-][A-Za-z0-9]+)*`) is matched via
//! `crate::scanners::scan_word_re`, which is the already-ported hand-written
//! scanner.

use crate::scanners::scan_word_re;

// ---------------------------------------------------------------------------
// Stop-word sets
// ---------------------------------------------------------------------------

/// Basic filler-word set.
///
/// Mirrors Python:
/// ```python
/// STOPWORDS = frozenset({
///     "really", "very", "quite", "actually", "basically",
///     "literally", "honestly", "frankly", "anyway", "please",
/// })
/// ```
const STOPWORDS: &[&str] = &[
    "really", "very", "quite", "actually", "basically",
    "literally", "honestly", "frankly", "anyway", "please",
];

/// Extended stopword set used for scoring and deduplication.
///
/// Mirrors Python:
/// ```python
/// SCORING_STOPWORDS = STOPWORDS | frozenset({
///     "a", "an", "the", "and", "as", "at", "be", "been", "being", "by",
///     "for", "from", "in", "of", "on", "or", "that", "this", "to",
///     "was", "were", "with", "you", "your", "we", "our", "they", "their",
///     "it", "its", "i", "my", "me",
/// })
/// ```
pub const SCORING_STOPWORDS: &[&str] = &[
    // Base STOPWORDS
    "really", "very", "quite", "actually", "basically",
    "literally", "honestly", "frankly", "anyway", "please",
    // Extended grammatical stopwords
    "a", "an", "the", "and", "as", "at", "be", "been", "being", "by",
    "for", "from", "in", "of", "on", "or", "that", "this", "to",
    "was", "were", "with", "you", "your", "we", "our", "they", "their",
    "it", "its", "i", "my", "me",
];

/// Return true if `word` is in `SCORING_STOPWORDS`.
///
/// Both `word` and the set entries are already lowercase ASCII, so
/// comparison is a simple equality check.
#[inline]
pub fn is_scoring_stopword(word: &str) -> bool {
    SCORING_STOPWORDS.contains(&word)
}

/// Return true if `word` is in `STOPWORDS` (basic filler-word set).
#[inline]
pub fn is_stopword(word: &str) -> bool {
    STOPWORDS.contains(&word)
}

// ---------------------------------------------------------------------------
// Suffix-stemmer constants
// ---------------------------------------------------------------------------

/// Suffixes applied in order by the small fixed stemmer in
/// `_normalized_terms`. Mirrors Python:
/// ```python
/// for suffix in ("ing", "ed", "es", "s"):
///     if word.endswith(suffix) and len(word) > len(suffix) + 3:
///         word = word[:-len(suffix)]
///         break
/// ```
const STEM_SUFFIXES: &[&str] = &["ing", "ed", "es", "s"];

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Normalise text into scored terms for deduplication and MMR.
///
/// Mirrors Python `_normalized_terms(text: str) -> tuple[str, ...]`:
///
/// 1. Lowercase the text.
/// 2. Extract all `WORD_RE` tokens (`[A-Za-z0-9]+(?:['-][A-Za-z0-9]+)*`).
/// 3. Drop tokens in `SCORING_STOPWORDS` or shorter than 2 characters.
/// 4. Apply the small fixed stemmer (one pass, first matching suffix wins).
///
/// Python semantics note: `.lower()` is applied to the whole input string
/// before `WORD_RE.finditer`.  In the scorer this is always ASCII content,
/// so Rust `str::to_lowercase()` is equivalent.
pub fn normalized_terms(text: &str) -> Vec<String> {
    // Step 1: lowercase — mirrors Python `text.lower()` before finditer.
    let lowered = text.to_lowercase();

    // Step 2: extract WORD_RE tokens on the lowercased text.
    // scan_word_re returns matches with code-point offsets; we use
    // groups[0] (the full match string) directly.
    let word_matches = scan_word_re(&lowered);

    let mut terms: Vec<String> = Vec::new();

    for m in &word_matches {
        let word_ref = match m.groups.first().and_then(|g| g.as_ref()) {
            Some(s) => s.as_str(),
            None => continue,
        };

        // Step 3a: length < 2 → drop.
        if word_ref.len() < 2 {
            continue;
        }

        // Step 3b: stopword → drop.
        if is_scoring_stopword(word_ref) {
            continue;
        }

        // Step 4: small fixed stemmer — first matching suffix wins.
        // Mirrors Python:
        //   for suffix in ("ing", "ed", "es", "s"):
        //       if word.endswith(suffix) and len(word) > len(suffix) + 3:
        //           word = word[:-len(suffix)]
        //           break
        let mut word = word_ref.to_string();
        for &suffix in STEM_SUFFIXES {
            if word.ends_with(suffix) && word.len() > suffix.len() + 3 {
                word.truncate(word.len() - suffix.len());
                break;
            }
        }

        terms.push(word);
    }

    terms
}

/// Query-stopword set — extends SCORING_STOPWORDS with task-instruction words.
///
/// Mirrors Python:
/// ```python
/// QUERY_STOPWORDS = SCORING_STOPWORDS | frozenset({
///     "answer", "analyze", "check", "compare", "convert", "describe",
///     "document", "explain", "extract", "find", "following", "identify",
///     "list", "question", "review", "show", "summarize", "tell", "text",
///     "verify", "write",
/// })
/// ```
const QUERY_STOPWORDS_EXTRA: &[&str] = &[
    "answer", "analyze", "check", "compare", "convert", "describe",
    "document", "explain", "extract", "find", "following", "identify",
    "list", "question", "review", "show", "summarize", "tell", "text",
    "verify", "write",
];

/// Return true if `word` is in `QUERY_STOPWORDS`.
#[inline]
pub fn is_query_stopword(word: &str) -> bool {
    is_scoring_stopword(word) || QUERY_STOPWORDS_EXTRA.contains(&word)
}

/// Normalise text for query-term extraction (drops query-specific stopwords).
///
/// Used by `_query_terms` in `distill_plus_converter.py`.
///
/// Mirrors Python `_query_terms`:
/// ```python
/// return {term for term in _normalized_terms(text)
///         if term not in QUERY_STOPWORDS and len(term) >= 3}
/// ```
/// Note: the length gate is `>= 3` (not `>= 2`), matching the Python oracle.
/// Terms shorter than 3 characters after stemming are dropped even if they
/// are not in QUERY_STOPWORDS.
pub fn query_terms(text: &str) -> std::collections::HashSet<String> {
    let lowered = text.to_lowercase();
    let word_matches = scan_word_re(&lowered);
    let mut result = std::collections::HashSet::new();
    for m in &word_matches {
        let word_ref = match m.groups.first().and_then(|g| g.as_ref()) {
            Some(s) => s.as_str(),
            None => continue,
        };
        // _normalized_terms drops len < 2; query_terms further requires len >= 3.
        if word_ref.len() < 2 {
            continue;
        }
        if is_query_stopword(word_ref) {
            continue;
        }
        // Apply stemmer.
        let mut word = word_ref.to_string();
        for &suffix in STEM_SUFFIXES {
            if word.ends_with(suffix) && word.len() > suffix.len() + 3 {
                word.truncate(word.len() - suffix.len());
                break;
            }
        }
        // Python _query_terms: `len(term) >= 3` applied AFTER normalisation.
        // Terms that survive scoring-stopword filter but are shorter than 3
        // chars are still dropped here (e.g. "ai" which is len=2).
        if word.len() < 3 {
            continue;
        }
        result.insert(word);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalized_terms_basic() {
        // "running" → "runn" (strip "ing", len "running"=7 > 3+3=6 ✓)
        let terms = normalized_terms("running fast");
        assert!(terms.contains(&"runn".to_string()), "got {:?}", terms);
        assert!(terms.contains(&"fast".to_string()));
    }

    #[test]
    fn test_normalized_terms_stopwords() {
        // "a", "the", "and" should be dropped.
        let terms = normalized_terms("a the and hello");
        assert!(!terms.contains(&"a".to_string()));
        assert!(!terms.contains(&"the".to_string()));
        assert!(!terms.contains(&"and".to_string()));
        assert!(terms.contains(&"hello".to_string()));
    }

    #[test]
    fn test_normalized_terms_stemmer_order() {
        // "shipped" → stem "ed" → "shipp" (len 7 > 2+3=5 ✓)
        let terms = normalized_terms("shipped");
        assert_eq!(terms, vec!["shipp".to_string()]);
    }

    #[test]
    fn test_normalized_terms_too_short_after_stem_not_applied() {
        // "beds" → try "s": len 4, 4 > 1+3=4 is FALSE, so no stem.
        // Result: "beds" (length 4 >= 2, not a stopword).
        let terms = normalized_terms("beds");
        // len("beds") = 4 > 1+3 = 4 is False, so no suffix stripped.
        assert_eq!(terms, vec!["beds".to_string()]);
    }
}
