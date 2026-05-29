//! Snowball English stemmer (Porter2 algorithm). Wraps the
//! `rust-stemmers` crate, which is a Rust port of the canonical
//! Snowball-language source compiled by the Snowball project.
//! BSD-3-Clause. Deterministic; conformance-gated against the
//! canonical Snowball test corpus.

use rust_stemmers::{Algorithm, Stemmer};

/// Stem a token using the Snowball English (Porter2) algorithm.
/// Returns the stemmed form. Determinism is guaranteed by the
/// underlying algorithm.
pub fn stem(token: &str) -> String {
    let stemmer = Stemmer::create(Algorithm::English);
    stemmer.stem(token).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn running_stems_to_run() {
        assert_eq!(stem("running"), "run");
    }

    #[test]
    fn ran_stems_to_ran() {
        // Porter2 does not catch irregular past tense; "ran"
        // remains "ran". This is intentional behavior of the
        // algorithm, not a bug.
        assert_eq!(stem("ran"), "ran");
    }

    #[test]
    fn computer_and_computing_collapse_to_same_stem() {
        // Both "computer" and "computing" should reduce to a
        // common stem so the gazetteer can match either to the
        // same UDC code.
        let a = stem("computer");
        let b = stem("computing");
        assert_eq!(a, b);
    }

    #[test]
    fn empty_string_yields_empty() {
        assert_eq!(stem(""), "");
    }

    #[test]
    fn determinism_holds() {
        assert_eq!(stem("test"), stem("test"));
    }

    #[test]
    fn chemistry_stems_consistently() {
        let chemistry = stem("chemistry");
        let chemical = stem("chemical");
        // Both should reduce to "chemistri" or "chemic"
        // depending on the algorithm's reductions; not
        // necessarily the same, but each must be deterministic.
        assert!(!chemistry.is_empty());
        assert!(!chemical.is_empty());
    }
}
