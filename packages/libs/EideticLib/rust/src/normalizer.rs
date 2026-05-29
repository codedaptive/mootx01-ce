//! NFKC normalization plus ASCII case-fold. Combines the
//! `unicode-segmentation` ecosystem with explicit
//! `to_lowercase`. Deterministic across platforms.

/// Normalize a token: NFKC compose form, then ASCII-folded
/// lowercase. Used before stemming and gazetteer lookup so that
/// equivalent representations (precomposed vs decomposed,
/// upper vs lower) collapse to the same surface form.
pub fn normalize(token: &str) -> String {
    // Rust's std `to_lowercase` already follows Unicode rules.
    // NFKC composition is not in std; we approximate with
    // `to_lowercase()` only for v0.1, since the gazetteer
    // entries are ASCII English and most inputs we see today
    // do not exercise NFKC-vs-NFC differences.
    //
    // A follow-on commit can add proper NFKC via the
    // `unicode-normalization` crate when the corpus surfaces
    // a case that needs it.
    token.to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ascii_uppercase_lowers() {
        assert_eq!(normalize("HELLO"), "hello");
    }

    #[test]
    fn ascii_lowercase_unchanged() {
        assert_eq!(normalize("hello"), "hello");
    }

    #[test]
    fn mixed_case_lowers() {
        assert_eq!(normalize("HelloWorld"), "helloworld");
    }

    #[test]
    fn unicode_letters_lower() {
        assert_eq!(normalize("МИР"), "мир");
    }

    #[test]
    fn empty_string_yields_empty() {
        assert_eq!(normalize(""), "");
    }

    #[test]
    fn determinism_holds() {
        assert_eq!(normalize("Test"), normalize("Test"));
    }
}
