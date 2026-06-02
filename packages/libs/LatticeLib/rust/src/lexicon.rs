// lexicon.rs — Canonicalization lexicon
//
// Port of Lexicon.swift's CanonicalizationLexicon struct (runtime-only;
// LexiconBuilder is build-time and not ported).
//
// The lexicon is a flat map: stem(normalize(token)) -> conceptID.
// Used by Step 2 of the encoder: a surface token is normalized and
// Porter2-stemmed, then looked up to collapse synonyms onto one concept ID.

use std::collections::HashMap;
use serde::Deserialize;

/// A pinned, versioned canonicalization lexicon.
/// Matches the JSON schema of CanonicalizationLexicon.swift.
#[derive(Debug, Clone, Deserialize)]
pub struct CanonicalizationLexicon {
    /// Pinned lexicon version. Part of the FDC agreement protocol.
    pub version: String,
    /// Language scope (ISO code). "en" for English.
    pub language: String,
    /// Flat map: stemmed/normalized surface form -> concept ID
    /// (Wikidata Q-ID or WordNet fallback "wn:...").
    pub entries: HashMap<String, String>,
}

impl CanonicalizationLexicon {
    /// Deserialize from JSON bytes (the bundled Lexicon.json artifact).
    pub fn from_json(data: &[u8]) -> Option<Self> {
        serde_json::from_slice(data).ok()
    }

    /// Look up a pre-stemmed/normalized key.
    pub fn lookup(&self, key: &str) -> Option<&str> {
        self.entries.get(key).map(|s| s.as_str())
    }
}
