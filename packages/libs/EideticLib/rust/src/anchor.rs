//! The result of a EideticLib lookup. Pure data; byte-identical
//! shape to the Swift port's `Anchor` struct.

use serde::{Deserialize, Serialize};

/// The lattice anchor returned by `eidetic_lib::lookup`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Anchor {
    /// The MDCC code at the deepest depth supported by the
    /// evidence. Empty string means classification failed.
    pub mdcc_code: String,

    /// The Wikidata Q-ID for the primary concept, or `None` if
    /// the resolver could not find a confident match.
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

impl Anchor {
    /// The sentinel anchor returned by the v0.1 stub. Callers
    /// can integrate against the API surface; real anchors
    /// replace these sentinels once the pipeline lands.
    pub fn not_implemented() -> Self {
        Anchor {
            mdcc_code: String::new(),
            wikidata_qid: None,
            confidence: 0,
            data_version: "0.1.0-stub".to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn anchor_roundtrips_through_json() {
        let anchor = Anchor {
            mdcc_code: "547".to_string(),
            wikidata_qid: Some("Q11165".to_string()),
            confidence: 32,
            data_version: "0.1.0".to_string(),
        };
        let json = serde_json::to_string(&anchor).expect("serialize");
        let decoded: Anchor = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(decoded, anchor);
    }

    #[test]
    fn not_implemented_carries_stub_data_version() {
        let stub = Anchor::not_implemented();
        assert_eq!(stub.mdcc_code, "");
        assert!(stub.wikidata_qid.is_none());
        assert_eq!(stub.confidence, 0);
        assert_eq!(stub.data_version, "0.1.0-stub");
    }
}
