// word_class_table.rs — Static noun/verb fast-path table
//
// Port of WordClassTable.swift and WordClassTagger.swift's fast-path.
//
// NOVEL-TOKEN FALLBACK
// The Swift source has two paths for novel (non-table) tokens:
//   1. Apple: NLTagger with .lexicalClass (cookbook §2.2)
//   2. Non-Apple: a deterministic stub returning .other
//      ("Until the compiled HMM artifact is bundled, this deterministic stub
//       keeps the platform-dispatch seam intact and defaults every novel token
//       to .other" — WordClassTagger.swift, hmmViterbiTag)
//
// The Rust port implements the static-table fast path and mirrors the
// non-Apple stub: novel tokens return WordClass::Other. This is correct
// and intentional — cookbook §2.2/§8: "novel-token tagging is
// platform-divergent BY DESIGN; the static table is the cross-platform-
// guaranteed surface." The Apple NLTagger fallback is explicitly not ported.

use std::collections::HashSet;
use serde::Deserialize;

use crate::word_class::WordClass;

/// The parsed word-class table (matches JSON schema of WordClassTable.swift).
#[derive(Debug, Deserialize)]
pub struct WordClassTable {
    #[serde(rename = "table_version")]
    pub table_version: String,
    #[serde(rename = "min_os_version")]
    pub min_os_version: String,
    #[serde(rename = "snapshot_date")]
    pub snapshot_date: String,
    pub nouns: Vec<String>,
    pub verbs: Vec<String>,
}

/// The process-lifetime cache: parsed table + derived membership sets.
/// Loaded once from the bundled JSON bytes.
pub struct WordClassTableCache {
    pub noun_set: HashSet<String>,
    pub verb_set: HashSet<String>,
}

impl WordClassTableCache {
    /// Build from parsed table bytes.
    pub fn from_json(data: &[u8]) -> Option<Self> {
        let table: WordClassTable = serde_json::from_slice(data).ok()?;
        let noun_set: HashSet<String> = table.nouns.into_iter().collect();
        let verb_set: HashSet<String> = table.verbs.into_iter().collect();
        Some(WordClassTableCache { noun_set, verb_set })
    }

    /// Classify a token.
    /// Verb set is checked before noun set (matching the Swift ordering in
    /// `LatticeLib.wordClass`: "The verb set is checked before the noun set,
    /// so a token listed under both resolves to `.verb`").
    /// Novel tokens (not in either set) return WordClass::Other — the
    /// deterministic stub mirroring the Swift non-Apple path.
    pub fn word_class(&self, token: &str) -> WordClass {
        let lowered = token.to_lowercase();
        if lowered.is_empty() {
            return WordClass::Other;
        }
        // Fast path: verb set first (matching Swift ordering).
        if self.verb_set.contains(&lowered) {
            return WordClass::Verb;
        }
        if self.noun_set.contains(&lowered) {
            return WordClass::Noun;
        }
        // Novel token: deterministic stub returns Other.
        // This mirrors Swift's `hmmViterbiTag` (non-Apple path) which
        // returns `.other` until the HMM artifact is bundled.
        WordClass::Other
    }
}
