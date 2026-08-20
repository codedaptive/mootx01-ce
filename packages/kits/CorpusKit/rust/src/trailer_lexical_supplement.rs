//! Grammar-v1 trailer extraction for the LEXICAL lane. Twin of Swift
//! `CorpusKit/TrailerLexicalSupplement.swift` — see that file and
//! DECISION_DENSE_LANE_ENRICHMENT (Wave-2 delivery ruling 2026-08-20) for
//! the measured rationale (the anarrow oracle arm). SCANS, never regex.

/// Opening delimiter — the pair cannot occur in natural prose.
pub const TRAILER_OPEN: &str = "(*[";
/// Closing delimiter.
pub const TRAILER_CLOSE: &str = "]*)";

/// Returns the lexical supplement for a dense-composition text: the inner
/// text of the LAST well-formed trailer block, prefixed with one separating
/// space — or `""` when absent/malformed (fail-quiet: a broken trailer
/// contributes nothing to the keyword lane).
pub fn lexical_supplement(dense_text: Option<&str>) -> String {
    let Some(text) = dense_text else { return String::new() };
    if text.is_empty() {
        return String::new();
    }
    let (Some(open), Some(close)) = (text.rfind(TRAILER_OPEN), text.rfind(TRAILER_CLOSE)) else {
        return String::new();
    };
    let start = open + TRAILER_OPEN.len();
    if start > close {
        return String::new();
    }
    let inner = text[start..close].trim();
    if inner.is_empty() {
        return String::new();
    }
    format!(" {inner}")
}

#[cfg(test)]
mod tests {
    use super::*;

    // Literal twins of the Swift TrailerGrammarScannerTests pins.
    #[test]
    fn extracts_inner() {
        let dense = "Jolene: I bought Seraphim a year ago in Paris. (*[ entity: snake, place: paris, country: france, fdc: pets ]*)";
        assert_eq!(
            lexical_supplement(Some(dense)),
            " entity: snake, place: paris, country: france, fdc: pets"
        );
    }

    #[test]
    fn fail_quiet() {
        assert_eq!(lexical_supplement(None), "");
        assert_eq!(lexical_supplement(Some("")), "");
        assert_eq!(lexical_supplement(Some("plain distillate")), "");
        assert_eq!(lexical_supplement(Some("]*) broken (*[")), "");
        assert_eq!(lexical_supplement(Some("x (*[   ]*)")), "");
    }

    #[test]
    fn last_block_wins() {
        let dense = "we discussed (*[ old: note ]*) earlier (*[ kind: hobby ]*)";
        assert_eq!(lexical_supplement(Some(dense)), " kind: hobby");
    }
}
