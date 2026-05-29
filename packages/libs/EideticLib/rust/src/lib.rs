//! EideticLib, the deterministic text-to-anchor utility. Pass a
//! term to `lookup`; get back an `Anchor` carrying an MDCC code,
//! an optional Wikidata Q-ID, a confidence, and the data version
//! that produced the answer.
//!
//! The Rust runtime currently returns the `not_implemented`
//! sentinel. The legacy UDC pipeline was retired alongside the
//! Swift port (the UDC schedule is CC-BY-SA and cannot ship in the
//! core). The deterministic FDC encoder steps that replace it land
//! in the FDC runtime missions (see docs FDC_ENCODER_MISSION_PLAN_v1.0,
//! GNO-FDC-06/07). Until then the tokenizer / normalizer / stemmer /
//! wikidata / word_class modules below stand ready as the encoder's
//! building blocks. Determinism is guaranteed against the pinned
//! data version once the runtime lands.

pub mod anchor;
pub mod normalizer;
pub mod segmenter;
pub mod stemmer;
pub mod tokenizer;
pub mod wikidata_resolver;
pub mod wikidata_subset;
pub mod word_class;

pub use anchor::Anchor;
pub use wikidata_resolver::ResolverDecision;
pub use wikidata_subset::{WikidataEntry, WikidataSubset};
pub use word_class::{WordClass, WordClassTable};

/// The EideticLib crate version. Pinned with the Wikidata data
/// version in the bundled JSON files.
pub const VERSION: &str = "0.1.0";

/// Looks up the lattice anchor for a term.
///
/// The deterministic FDC encoder that produces real anchors lands
/// in the FDC runtime missions (GNO-FDC-06/07); until then this
/// returns the `not_implemented` sentinel so consumers can build
/// against the API surface. The Swift port resolves real MDCC codes
/// today — this Rust port is intentionally a stub pending the FDC
/// runtime, not the retired UDC pipeline.
pub fn lookup(_term: &str) -> Anchor {
    Anchor::not_implemented()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_pinned() {
        assert_eq!(VERSION, "0.1.0");
    }

    #[test]
    fn lookup_returns_not_implemented_stub() {
        // Until the FDC runtime (GNO-FDC-06/07) lands, lookup is a
        // stub: empty code, null confidence, stub data version.
        let anchor = lookup("organic chemistry research");
        assert_eq!(anchor.mdcc_code, "");
        assert_eq!(anchor.confidence, 0);
        assert!(anchor.wikidata_qid.is_none());
    }

    #[test]
    fn lookup_empty_string_yields_empty_anchor() {
        let anchor = lookup("");
        assert_eq!(anchor.mdcc_code, "");
        assert_eq!(anchor.confidence, 0);
    }

    #[test]
    fn lookup_carries_stub_data_version() {
        let anchor = lookup("computer");
        assert_eq!(anchor.data_version, "0.1.0-stub");
    }

    #[test]
    fn lookup_is_deterministic() {
        let a = lookup("organic chemistry");
        let b = lookup("organic chemistry");
        assert_eq!(a, b);
    }
}
