//! SSC fact supplement for the BM25 lexical lane. Rust twin of Swift
//! `CorpusKit/SSCFacts.swift`.
//!
//! Schema 19: facts are stored in `drawers.ssc_facts` as a bare comma-separated
//! pair list (e.g. `"entity: louvre, place: paris"`). The supplement appends
//! these tokens to the verbatim BM25 document at index time. The function
//! reads the column value directly — no scanning, no delimiter dependency.

/// Returns the lexical supplement for BM25 indexing: the `ssc_facts` column
/// value prefixed with one separating space, or `""` when `facts` is `None` or
/// empty (fail-quiet — absent facts contribute nothing to keyword scoring).
pub fn lexical_supplement(facts: Option<&str>) -> String {
    match facts {
        Some(f) if !f.is_empty() => format!(" {f}"),
        _ => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn appends_with_space() {
        assert_eq!(
            lexical_supplement(Some("entity: louvre, place: paris")),
            " entity: louvre, place: paris"
        );
    }

    #[test]
    fn none_is_empty() {
        assert_eq!(lexical_supplement(None), "");
    }

    #[test]
    fn empty_string_is_empty() {
        assert_eq!(lexical_supplement(Some("")), "");
    }

    #[test]
    fn bare_pair_list_no_delimiters() {
        // Old content may contain (*[ … ]*) in the verbatim text.
        // The supplement must NOT scan for delimiters — it passes through as-is.
        let facts = "entity: snake, place: paris";
        assert_eq!(lexical_supplement(Some(facts)), " entity: snake, place: paris");
    }
}
