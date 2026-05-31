//! NeuronKit capability set + the pre-execution capability gate.
//!
//! Rust port of the Swift `NeuronKitCapability` enum and
//! `verifyCapabilities(required:available:)` in
//! `CognitionKit/Sources/CognitionKit/NeuronKitCapability.swift`.
//! Per COGNITIONKIT_SPEC § 2 / B-5, a recipe verifies its declared
//! capabilities are available BEFORE any execution begins, and the gate
//! reports the FIRST missing capability in declaration order so the
//! failure is deterministic across ports.

use crate::error::RecipeError;
use serde::{Deserialize, Serialize};

/// A NeuronKit reasoning capability a recipe sequences. Each case names a
/// NeuronKit surface that is actually shipped in the Swift port. The
/// `serde` rename gives each case the SAME string the Swift `String`
/// rawValue uses, so the wire shape is identical across ports.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum NeuronKitCapability {
    #[serde(rename = "hybridRecall")]
    HybridRecall,
    #[serde(rename = "synthesize")]
    Synthesize,
    #[serde(rename = "deriveBranch")]
    DeriveBranch,
    #[serde(rename = "promoteBranch")]
    PromoteBranch,
    #[serde(rename = "benchmark")]
    Benchmark,
    #[serde(rename = "runTournament")]
    RunTournament,
}

impl NeuronKitCapability {
    /// Declaration order — MUST match the Swift `allCases` order. The
    /// capability gate walks this order and reports the first required
    /// capability that is unavailable, so two ports agree on which one
    /// they name.
    pub const ALL: [NeuronKitCapability; 6] = [
        NeuronKitCapability::HybridRecall,
        NeuronKitCapability::Synthesize,
        NeuronKitCapability::DeriveBranch,
        NeuronKitCapability::PromoteBranch,
        NeuronKitCapability::Benchmark,
        NeuronKitCapability::RunTournament,
    ];

    /// The capability's stable string identifier — identical to the Swift
    /// rawValue and to the serde rename above.
    pub fn raw_value(self) -> &'static str {
        match self {
            NeuronKitCapability::HybridRecall => "hybridRecall",
            NeuronKitCapability::Synthesize => "synthesize",
            NeuronKitCapability::DeriveBranch => "deriveBranch",
            NeuronKitCapability::PromoteBranch => "promoteBranch",
            NeuronKitCapability::Benchmark => "benchmark",
            NeuronKitCapability::RunTournament => "runTournament",
        }
    }
}

/// The full set of NeuronKit capabilities shipped in the current in-tree
/// NeuronKit — the default host set a recipe is checked against. Equal to
/// `NeuronKitCapability::ALL` today (every declared capability maps to a
/// shipped surface). Mirrors Swift `shippedNeuronKitCapabilities`.
pub fn shipped_capabilities() -> Vec<NeuronKitCapability> {
    NeuronKitCapability::ALL.to_vec()
}

/// Verify that `available` covers every capability in `required`.
///
/// Returns `Err(RecipeError::MissingCapability(c))` naming the FIRST
/// `c` in `NeuronKitCapability::ALL` order that is required but not
/// available; returns `Ok(())` when every requirement is met. Mirrors
/// the Swift `verifyCapabilities` first-missing-in-declaration-order
/// contract exactly (spec § 2, B-5).
pub fn verify_capabilities(
    required: &[NeuronKitCapability],
    available: &[NeuronKitCapability],
) -> Result<(), RecipeError> {
    for cap in NeuronKitCapability::ALL {
        if required.contains(&cap) && !available.contains(&cap) {
            return Err(RecipeError::MissingCapability(cap));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    //! Conformance fixtures — mirror Swift `CapabilityGateTests`.
    use super::*;

    #[test]
    fn all_shipped_capabilities_available_by_default() {
        assert!(verify_capabilities(
            &NeuronKitCapability::ALL,
            &shipped_capabilities()
        )
        .is_ok());
        assert_eq!(shipped_capabilities(), NeuronKitCapability::ALL.to_vec());
    }

    #[test]
    fn empty_requirement_always_passes() {
        assert!(verify_capabilities(&[], &shipped_capabilities()).is_ok());
        assert!(verify_capabilities(&[], &[]).is_ok());
    }

    #[test]
    fn missing_capability_throws_naming_it() {
        // Host supports only hybridRecall; a recipe needing runTournament
        // must fail naming runTournament.
        let available = [NeuronKitCapability::HybridRecall];
        let required = [
            NeuronKitCapability::HybridRecall,
            NeuronKitCapability::RunTournament,
        ];
        assert_eq!(
            verify_capabilities(&required, &available),
            Err(RecipeError::MissingCapability(
                NeuronKitCapability::RunTournament
            ))
        );
    }

    #[test]
    fn first_missing_reported_in_declaration_order() {
        // With benchmark AND deriveBranch both missing, deriveBranch is
        // reported because it precedes benchmark in ALL order. Matches the
        // Swift fixture exactly.
        let available = [
            NeuronKitCapability::HybridRecall,
            NeuronKitCapability::Synthesize,
        ];
        let required = [
            NeuronKitCapability::Benchmark,
            NeuronKitCapability::DeriveBranch,
        ];
        assert_eq!(
            verify_capabilities(&required, &available),
            Err(RecipeError::MissingCapability(
                NeuronKitCapability::DeriveBranch
            ))
        );
    }

    #[test]
    fn raw_values_match_swift() {
        let pairs = [
            (NeuronKitCapability::HybridRecall, "hybridRecall"),
            (NeuronKitCapability::Synthesize, "synthesize"),
            (NeuronKitCapability::DeriveBranch, "deriveBranch"),
            (NeuronKitCapability::PromoteBranch, "promoteBranch"),
            (NeuronKitCapability::Benchmark, "benchmark"),
            (NeuronKitCapability::RunTournament, "runTournament"),
        ];
        for (cap, raw) in pairs {
            assert_eq!(cap.raw_value(), raw);
        }
    }
}
