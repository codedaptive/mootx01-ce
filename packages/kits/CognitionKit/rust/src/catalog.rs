//! The recipe catalog — Rust port of the Swift `RecipeCatalog` /
//! `RecipeDescriptor` in
//! `CognitionKit/Sources/CognitionKit/RecipeCatalog.swift`.
//!
//! The conscious mind's self-knowledge: an enumerable registry of the
//! behaviour recipes CognitionKit ships, each with its metadata
//! (name, version, description, required capabilities). The descriptor
//! strings MUST match the Swift recipes byte-for-byte — that equality is
//! the strongest conformance anchor in this crate, because the Swift
//! `moot_list_recipes` MCP tool and any agent enumerator read exactly
//! these values.

use crate::capability::NeuronKitCapability;
use serde::{Deserialize, Serialize};

/// Type-erased metadata for a recipe. `serde` field names match the Swift
/// `Codable` `RecipeDescriptor`, so a descriptor round-trips identically
/// across the ports' wire shapes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecipeDescriptor {
    pub name: String,
    pub version: String,
    pub description: String,
    #[serde(rename = "requiredCapabilities")]
    pub required_capabilities: Vec<NeuronKitCapability>,
}

/// Every shipped recipe's descriptor, in stable declaration order. The
/// single place a recipe is registered for discovery. These strings are
/// the exact values the Swift recipes report (`GroundedSynthesis` and
/// `MigrationBenchmark`); the Swift `RecipeCatalogTests` and the Rust
/// tests below both assert them.
pub fn recipe_catalog() -> Vec<RecipeDescriptor> {
    vec![
        RecipeDescriptor {
            name: "grounded_synthesis".into(),
            version: "1.0.0".into(),
            description:
                "Hybrid-recall a query and synthesize the recalled drawers into a single grounded context document."
                    .into(),
            required_capabilities: vec![
                NeuronKitCapability::HybridRecall,
                NeuronKitCapability::Synthesize,
            ],
        },
        RecipeDescriptor {
            name: "migration_benchmark".into(),
            version: "1.0.0".into(),
            description:
                "Derive one branch per migration plan, benchmark each branch's recall fidelity against the origin (zero-silent-loss gate), and rank survivors."
                    .into(),
            required_capabilities: vec![
                NeuronKitCapability::DeriveBranch,
                NeuronKitCapability::Benchmark,
                NeuronKitCapability::PromoteBranch,
            ],
        },
    ]
}

/// The descriptor named `name`, or `None`. Mirrors Swift
/// `RecipeCatalog.descriptor(named:)`.
pub fn recipe_descriptor(name: &str) -> Option<RecipeDescriptor> {
    recipe_catalog().into_iter().find(|d| d.name == name)
}

/// The names of all shipped recipes, in catalog order. Mirrors Swift
/// `RecipeCatalog.names`.
pub fn recipe_names() -> Vec<String> {
    recipe_catalog().into_iter().map(|d| d.name).collect()
}

#[cfg(test)]
mod tests {
    //! Conformance fixtures — mirror Swift `RecipeCatalogTests`.
    use super::*;

    #[test]
    fn catalog_lists_all_shipped_recipes() {
        let mut names = recipe_names();
        names.sort();
        assert_eq!(names, vec!["grounded_synthesis", "migration_benchmark"]);
    }

    #[test]
    fn migration_descriptor_capabilities_match_swift() {
        let d = recipe_descriptor("migration_benchmark").unwrap();
        assert_eq!(d.version, "1.0.0");
        assert_eq!(
            d.required_capabilities,
            vec![
                NeuronKitCapability::DeriveBranch,
                NeuronKitCapability::Benchmark,
                NeuronKitCapability::PromoteBranch,
            ]
        );
    }

    #[test]
    fn grounded_descriptor_capabilities_match_swift() {
        let d = recipe_descriptor("grounded_synthesis").unwrap();
        assert_eq!(
            d.required_capabilities,
            vec![
                NeuronKitCapability::HybridRecall,
                NeuronKitCapability::Synthesize,
            ]
        );
    }

    #[test]
    fn unknown_name_yields_none() {
        assert!(recipe_descriptor("no_such_recipe").is_none());
    }

    #[test]
    fn descriptor_round_trips_through_serde() {
        let original = recipe_descriptor("grounded_synthesis").unwrap();
        let json = serde_json::to_string(&original).unwrap();
        let decoded: RecipeDescriptor = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, original);
        // The capability wire form matches the Swift Codable rawValue.
        assert!(json.contains("\"hybridRecall\""));
        assert!(json.contains("\"requiredCapabilities\""));
    }
}
