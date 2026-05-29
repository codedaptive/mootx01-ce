//! The curated Wikidata subset, mirrored from the canonical
//! reference data at
//! `../Sources/EideticLib/Resources/WikidataSubset.json` via
//! `include_str!`. The Swift Resources directory is the single
//! source of truth; both ports read identical bytes.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WikidataEntry {
    pub qid: String,
    pub label: String,
    pub aliases: Vec<String>,
    #[serde(rename = "udc_hint")]
    pub udc_hint: Option<String>,
    #[serde(rename = "source_section")]
    pub source_section: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WikidataSubset {
    #[serde(rename = "schema_version")]
    pub schema_version: String,
    #[serde(rename = "data_version")]
    pub data_version: String,
    #[serde(rename = "source_notes")]
    pub source_notes: String,
    #[serde(rename = "license_note")]
    pub license_note: String,
    pub entries: Vec<WikidataEntry>,
}

const BUNDLED_SUBSET_JSON: &str = include_str!(
    "../../Sources/EideticLib/Resources/WikidataSubset.json"
);

impl WikidataSubset {
    pub fn load_bundled() -> Result<Self, serde_json::Error> {
        serde_json::from_str(BUNDLED_SUBSET_JSON)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn subset_loads_from_embedded_bytes() {
        let subset = WikidataSubset::load_bundled().expect("parse");
        assert_eq!(subset.schema_version, "1");
        assert!(!subset.data_version.is_empty());
    }

    #[test]
    fn every_entry_has_qid_and_label() {
        let subset = WikidataSubset::load_bundled().expect("parse");
        for entry in &subset.entries {
            assert!(!entry.qid.is_empty());
            assert!(entry.qid.starts_with('Q'));
            assert!(!entry.label.is_empty());
        }
    }

    #[test]
    fn every_qid_unique() {
        let subset = WikidataSubset::load_bundled().expect("parse");
        let qids: Vec<&str> =
            subset.entries.iter().map(|e| e.qid.as_str()).collect();
        let unique: HashSet<&str> = qids.iter().copied().collect();
        assert_eq!(qids.len(), unique.len());
    }

    #[test]
    fn labels_are_already_lowercased() {
        let subset = WikidataSubset::load_bundled().expect("parse");
        for entry in &subset.entries {
            assert_eq!(entry.label, entry.label.to_lowercase());
            for alias in &entry.aliases {
                assert_eq!(*alias, alias.to_lowercase());
            }
        }
    }
}
