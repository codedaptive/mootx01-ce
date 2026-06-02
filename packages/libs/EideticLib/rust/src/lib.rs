//! EideticLib, the deterministic text-to-anchor utility. Pass a
//! term to `lookup`; get back an `Anchor` carrying an FDC code, the
//! dominant concept's Wikidata Q-ID, a confidence, and the FDC
//! signatures version that produced the answer.
//!
//! Swift LEADS this surface; the Rust port follows. The FDC encoder
//! itself lives in the `lattice_lib` crate (frame / lexicon /
//! signatures / concept-bag / stemmer / matcher). Swift's
//! `EideticLib.lookup` delegates to `LatticeLib.FDC.encodeAnchor`;
//! the Rust `lookup` here is a documented stub until it is wired to
//! `lattice_lib`'s FDC runtime (`Fdc::encode_anchor`) — the remaining
//! Rust-parity step. It returns the `not_implemented` sentinel so
//! consumers can build against the API surface. (The retired MDCC /
//! UDC pipeline and its Wikidata-subset resolver were removed.)

pub mod anchor;

pub use anchor::Anchor;

/// The EideticLib crate version.
pub const VERSION: &str = "0.1.0";

/// Looks up the lattice anchor for a term.
///
/// Swift's `EideticLib.lookup` resolves real FDC codes by delegating
/// to LatticeLib's FDC encoder. This Rust port returns the
/// `not_implemented` sentinel until `lookup` is wired to the
/// `lattice_lib` FDC runtime (`Fdc::encode_anchor`) — the remaining
/// Rust-parity step. It is intentionally a stub, not the retired MDCC
/// pipeline.
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
        // Rust lookup is a documented stub until it is wired to the
        // lattice_lib FDC runtime (Swift leads; Rust-parity follow-up).
        let anchor = lookup("organic chemistry research");
        assert_eq!(anchor.code, "");
        assert_eq!(anchor.confidence, 0);
        assert!(anchor.wikidata_qid.is_none());
    }

    #[test]
    fn lookup_empty_string_yields_empty_anchor() {
        let anchor = lookup("");
        assert_eq!(anchor.code, "");
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
