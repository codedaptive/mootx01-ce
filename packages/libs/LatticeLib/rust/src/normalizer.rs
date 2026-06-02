// normalizer.rs — NFKC normalization + case fold
//
// Port of Normalizer.swift. The Swift implementation is `token.lowercased()`,
// which is Unicode-aware case folding. In Rust the equivalent is
// `str::to_lowercase()`, which is also Unicode-aware. Both implementations
// produce byte-identical output for ASCII + common Latin inputs; the corpus
// in Lexicon.json is ASCII English so no divergence is expected or observed.
//
// Full NFKC composition is deferred in the Swift source ("deferred to a
// follow-on commit when the corpus surfaces a case needing it; the gazetteer
// entries are ASCII English in v0.1"). This Rust port matches that behaviour.

/// Normalize a token: Unicode-aware case fold (lowercase).
/// Mirrors `Normalizer.normalize` in Swift.
pub fn normalize(token: &str) -> String {
    token.to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ascii_lowercase_passthrough() {
        assert_eq!(normalize("hello"), "hello");
    }

    #[test]
    fn uppercased_ascii_folded() {
        assert_eq!(normalize("HELLO"), "hello");
    }

    #[test]
    fn mixed_case() {
        assert_eq!(normalize("ChEmIsTrY"), "chemistry");
    }

    #[test]
    fn empty_string() {
        assert_eq!(normalize(""), "");
    }
}
