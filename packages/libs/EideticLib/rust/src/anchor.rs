//! The result of a EideticLib lookup. Pure data; byte-identical
//! shape to the Swift port's `Anchor` struct.

use serde::{Deserialize, Serialize};

/// The lattice anchor returned by `eidetic_lib::lookup`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Anchor {
    /// The FDC code at the deepest depth supported by the
    /// evidence. Empty string means UNRESOLVED (no signature overlap).
    pub code: String,

    /// The Wikidata Q-ID for the primary concept, or `None` if
    /// the resolver could not find a confident match.
    /// Explicit rename: camelCase auto-rename produces "wikidataQid" but
    /// Swift's Codable encodes the property name verbatim as "wikidataQID".
    #[serde(rename = "wikidataQID")]
    pub wikidata_qid: Option<String>,

    /// Confidence packed into the substrate provenance
    /// confidence field's value set: 0=null, 16=low, 32=medium,
    /// 48=high, 56=verified.
    pub confidence: u8,

    /// The data version of the reference snapshot that produced
    /// this answer. Lets callers record provenance per substrate
    /// invariant I-4.
    pub data_version: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn anchor_roundtrips_through_json() {
        let anchor = Anchor {
            code: "547".to_string(),
            wikidata_qid: Some("Q11165".to_string()),
            confidence: 32,
            data_version: "0.1.0".to_string(),
        };
        let json = serde_json::to_string(&anchor).expect("serialize");
        let decoded: Anchor = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(decoded, anchor);
    }

    #[test]
    fn anchor_json_key_matches_swift_codable() {
        // Swift encodes the property as "wikidataQID" (capital QID),
        // not "wikidataQid" (which camelCase auto-rename would produce).
        let anchor = Anchor {
            code: "547".to_string(),
            wikidata_qid: Some("Q11165".to_string()),
            confidence: 32,
            data_version: "0.1.0".to_string(),
        };
        let json = serde_json::to_string(&anchor).expect("serialize");
        assert!(json.contains("\"wikidataQID\""), "JSON must use wikidataQID (capital QID) to match Swift: {json}");
        assert!(!json.contains("\"wikidataQid\""), "JSON must NOT use wikidataQid (lowercase id): {json}");
    }
}
