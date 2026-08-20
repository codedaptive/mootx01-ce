//! Q-ID property-facts surface. Twin of Swift `LatticeLib/QIDFacts.swift` —
//! pinned Wikidata property subset (en labels + P17 country), vendored per
//! DECISION_DENSE_LANE_ENRICHMENT v0.2. Loads the shared JSON artifact
//! (`../../Sources/LatticeLib/Resources/QIDFacts.json`) once per process
//! via `include_bytes!`; the runtime NEVER queries Wikidata.

use std::collections::HashMap;
use std::sync::OnceLock;

#[derive(serde::Deserialize)]
struct Entry {
    label: Option<String>,
    country: Option<String>,
}

#[derive(serde::Deserialize)]
struct Table {
    version: String,
    facts: HashMap<String, Entry>,
}

static TABLE: OnceLock<Option<Table>> = OnceLock::new();

fn table() -> Option<&'static Table> {
    TABLE
        .get_or_init(|| {
            serde_json::from_slice(include_bytes!(
                "../../Sources/LatticeLib/Resources/QIDFacts.json"
            ))
            .ok()
        })
        .as_ref()
}

/// The English label for a Q-ID, or None. Twin of Swift `QIDFacts.label(for:)`.
pub fn label(qid: &str) -> Option<&'static str> {
    if qid.is_empty() {
        return None;
    }
    table()?.facts.get(qid)?.label.as_deref()
}

/// The P17 country Q-ID for a Q-ID, or None.
pub fn country_qid(qid: &str) -> Option<&'static str> {
    if qid.is_empty() {
        return None;
    }
    table()?.facts.get(qid)?.country.as_deref()
}

/// The country's English label for a Q-ID, or None.
pub fn country_label(qid: &str) -> Option<&'static str> {
    label(country_qid(qid)?)
}

/// True when the bundled artifact parsed and the surface is ready.
pub fn is_available() -> bool {
    table().is_some()
}

/// The pinned-artifact version, "0.0.0-unavailable" when absent.
pub fn data_version() -> &'static str {
    table().map(|t| t.version.as_str()).unwrap_or("0.0.0-unavailable")
}

#[cfg(test)]
mod tests {
    use super::*;

    // Literal twins of Swift QIDFactsTests.
    #[test]
    fn loads() {
        assert!(is_available());
        assert_ne!(data_version(), "0.0.0-unavailable");
    }

    #[test]
    fn paris_pins() {
        assert_eq!(label("Q90"), Some("Paris"));
        assert_eq!(country_qid("Q90"), Some("Q142"));
        assert_eq!(country_label("Q90"), Some("France"));
        assert_eq!(label(""), None);
        assert_eq!(label("Q999999999"), None);
    }
}
