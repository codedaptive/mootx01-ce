//! The recipe catalog — Rust version of the Swift `RecipeCatalog` /
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
/// across the versions' wire shapes.
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
        // Structure lenses.
        RecipeDescriptor {
            name: "keystones".into(),
            version: "1.0.0".into(),
            description:
                "Reasoning lens: rank a wing's load-bearing memories by centrality over its drawer-to-drawer tunnel graph."
                    .into(),
            required_capabilities: vec![],
        },
        RecipeDescriptor {
            name: "constellation".into(),
            version: "1.0.0".into(),
            description:
                "Reasoning lens: recover the emergent communities of a wing's drawer-to-drawer tunnel graph."
                    .into(),
            required_capabilities: vec![],
        },
        RecipeDescriptor {
            name: "free_association".into(),
            version: "1.0.0".into(),
            description:
                "Reasoning lens: from a seed memory, walk the wing's tunnel graph with restart and rank the memories the walk keeps landing on."
                    .into(),
            required_capabilities: vec![],
        },
        // Topic lenses.
        RecipeDescriptor {
            name: "theme_weather".into(),
            version: "1.0.0".into(),
            description:
                "Reasoning lens: per-room momentum — recent attention share vs historical share; what's rising and what's fading."
                    .into(),
            required_capabilities: vec![],
        },
        RecipeDescriptor {
            name: "latent_themes".into(),
            version: "1.0.0".into(),
            description:
                "Reasoning lens: factor the recalled set's metadata co-occurrence into soft latent themes — the emergent topics in how the estate is filed."
                    .into(),
            required_capabilities: vec![],
        },
        // Preference lens.
        RecipeDescriptor {
            name: "bias".into(),
            version: "1.0.0".into(),
            description:
                "Reasoning lens: representation bias vs a reference, per-room dismissal rates, and learned preference from real curation choices."
                    .into(),
            required_capabilities: vec![],
        },
        // Surprise lenses.
        RecipeDescriptor {
            name: "drift".into(),
            version: "1.0.0".into(),
            description:
                "Reasoning lens: how far the room distribution after a split instant has drifted from the distribution before it."
                    .into(),
            required_capabilities: vec![],
        },
        // Diffusion node layer (ADR-DIFFUSION-001): a single memory's motion over time.
        RecipeDescriptor {
            name: "node_motion".into(),
            version: "1.0.0".into(),
            description:
                "Reasoning lens (diffusion, node layer): how a single memory has MOVED over time — its mutation volatility (decay-weighted recent-churn mass), its topic trajectory (the UDC anchors it has occupied), whether it reanchored, and a write-time anomaly verdict (churning / reanchored / stable). Reads the memory's fresh audit history."
                    .into(),
            required_capabilities: vec![],
        },
        RecipeDescriptor {
            name: "cohesion".into(),
            version: "1.0.0".into(),
            description:
                "Reasoning lens: flag the recalled memories whose content cohesion with their peers is anomalously low — the odd-ones-out."
                    .into(),
            required_capabilities: vec![],
        },
        RecipeDescriptor {
            name: "lens_contradiction".into(),
            version: "1.0.0".into(),
            description:
                "Reasoning lens: surface genuine contradictions — drawer pairs linked by a `contradicts` tunnel and KG facts with conflicting objects for the same subject+predicate key."
                    .into(),
            required_capabilities: vec![],
        },
        // Grounding / trust lens.
        RecipeDescriptor {
            name: "trust_grounded_synthesis".into(),
            version: "1.1.0".into(),
            description:
                "Reasoning lens: recall, rank by provenance trust (canonical and user above derived), and synthesize the trust-ordered set."
                    .into(),
            required_capabilities: vec![NeuronKitCapability::Synthesize],
        },
        // Associative lens.
        RecipeDescriptor {
            name: "partial_cue_recall".into(),
            version: "1.0.0".into(),
            description:
                "Reasoning lens: one anchor memory, three recalls — feels-like, about-this, from-then — by per-block fingerprint matching."
                    .into(),
            required_capabilities: vec![],
        },
        // Prediction lenses.
        RecipeDescriptor {
            name: "anticipate".into(),
            version: "1.0.0".into(),
            description:
                "Reasoning lens: learn which capture actions tend to reach a target outcome, ranked by conservative success rate."
                    .into(),
            required_capabilities: vec![],
        },
        RecipeDescriptor {
            name: "tunnel_successor".into(),
            version: "1.0.0".into(),
            description:
                "Reasoning lens: the memories an anchor points onward to by explicit tunnels, ranked by frequency."
                    .into(),
            required_capabilities: vec![],
        },
        // Federated lenses.
        RecipeDescriptor {
            name: "mind_overlap".into(),
            version: "1.0.0".into(),
            description:
                "Reasoning lens (federated): privacy-preserving overlap of two estates via differentially-private fingerprint summaries."
                    .into(),
            required_capabilities: vec![],
        },
        RecipeDescriptor {
            name: "estate_divergence".into(),
            version: "1.0.0".into(),
            description:
                "Reasoning lens (federated): how two estates' room distributions diverge, by Jensen-Shannon divergence."
                    .into(),
            required_capabilities: vec![],
        },
        // Analytics lenses.
        RecipeDescriptor {
            name: "association_rules".into(),
            version: "1.0.0".into(),
            description:
                "Recall a frame, project each drawer's categorical facets into a co-occurrence matrix, and mine pairwise association rules."
                    .into(),
            required_capabilities: vec![NeuronKitCapability::AssociationRuleMining],
        },
        RecipeDescriptor {
            name: "formal_concepts".into(),
            version: "1.0.0".into(),
            description:
                "Recall a frame, build a formal context whose attributes are each drawer's trust, lattice anchors, sensitivity, and filing facets, and mine bounded formal concepts — emergent provenance and about-ness clusters, not the authored taxonomy."
                    .into(),
            required_capabilities: vec![NeuronKitCapability::FormalConceptAnalysis],
        },
        RecipeDescriptor {
            name: "apriori_rules".into(),
            version: "1.0.0".into(),
            description:
                "Read the estate's audit log and mine multi-antecedent association rules via the Apriori algorithm."
                    .into(),
            required_capabilities: vec![NeuronKitCapability::AssociationRuleMining],
        },
        // Temporal lenses (Lenses 1-3, Time+Prediction).
        RecipeDescriptor {
            name: "moment".into(),
            version: "1.0.0".into(),
            description:
                "Reasoning lens: OR-reduce the primary window's fingerprints into a temporal signature and rank comparison windows by Hamming proximity."
                    .into(),
            required_capabilities: vec![],
        },
        RecipeDescriptor {
            name: "rhythm".into(),
            version: "1.0.0".into(),
            description:
                "Reasoning lens: FFT over a time-bucketed fingerprint bit series to surface the dominant periodic activity patterns."
                    .into(),
            required_capabilities: vec![],
        },
        RecipeDescriptor {
            name: "precedence".into(),
            version: "1.0.0".into(),
            description:
                "Reasoning lens: fold the estate's audit trail into T-matrix deltas and rank the antecedents most predictive of a target field-value coordinate."
                    .into(),
            required_capabilities: vec![],
        },
        // Information-theoretic lens (Lens 4, Topics).
        RecipeDescriptor {
            name: "complexity".into(),
            version: "1.0.0".into(),
            description:
                "Reasoning lens: Shannon entropy (and optional mutual information) over the distribution of a label field across the recalled set."
                    .into(),
            required_capabilities: vec![],
        },
        // Steerable-fusion recipe (GLK-RECALL-SHAPE-PRESETS): one parameterized
        // recipe over the named RecallShape preset roster. Description matches the
        // Swift `ShapedRecall.description` byte-for-byte (the conformance anchor).
        RecipeDescriptor {
            name: "shaped_recall".into(),
            version: "1.0.0".into(),
            description:
                "Recall a query with a named signed-weight RecallShape preset applied — forward, exclude, suppress, or invert individual fusion lanes (and bound the candidate frontier) by selecting one of the roster presets, instead of the uniform balanced fusion."
                    .into(),
            required_capabilities: vec![],
        },
        // Exploratory-recall recipe: random walk with restart from a seed drawer
        // over a wing's tunnel graph (cookbook § 19.1). Consumes
        // SubstrateML::RandomWalks::walk_with_restart. Description matches the
        // Swift `ExploratoryRecall.description` byte-for-byte (the conformance anchor).
        RecipeDescriptor {
            name: "recall_exploratory".into(),
            version: "1.0.0".into(),
            description:
                "Walk with restart from a seed drawer over a wing's tunnel graph and return the most-visited drawers ranked by visit frequency."
                    .into(),
            required_capabilities: vec![NeuronKitCapability::ExploratoryRecall],
        },
        // Distillation-family recipes (Dc1–Dc3, registered Dc4). Descriptor
        // metadata registered here; full Rust implementations ship in a future
        // mission. Description strings match Swift byte-for-byte.
        RecipeDescriptor {
            name: "consolidate".into(),
            version: "1.0.0".into(),
            description:
                "Compact working memory by distilling open clusters into factoids. \
                Calls the GLK distillation sweep, which processes all ready clusters \
                (member_count \u{2265} 3, status = open) and persists each factoid as a \
                drawer in room `_distilled`."
                    .into(),
            required_capabilities: vec![],
        },
        RecipeDescriptor {
            name: "distilled_recall".into(),
            version: "1.0.0".into(),
            description:
                "Dense recall: search the distilled memory tier and return factoid \
                prose (~10 tokens/hit) for AI reasoning. Uses structural fingerprint \
                Hamming NN \u{2014} no embedding model inference, no full corpus scan."
                    .into(),
            required_capabilities: vec![],
        },
        RecipeDescriptor {
            name: "expand_memory".into(),
            version: "1.0.0".into(),
            description:
                "Expand a distilled factoid to its source memories: follows the \
                _distilled_from tunnel graph and returns full episodic content \
                from the M memories that produced the factoid. Use when the user \
                needs the full explanation behind a dense factoid. The AI synthesises \
                the sources into a user-facing narrative."
                    .into(),
            required_capabilities: vec![],
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
        // Both versions of every recipe ship, so every recipe registers
        // (LENS_DISCOVERABILITY_DECISION v2.0): the 2 foundational recipes
        // plus the 16 reasoning lenses (14 + lens_contradiction + node_motion)
        // plus the 3 analytics lenses plus
        // the 4 temporal/entropy lenses (moment, rhythm, precedence, complexity)
        // plus the steerable-fusion recipe (shaped_recall)
        // plus the exploratory-recall recipe (recall_exploratory)
        // plus the 3 distillation-family recipes (Dc1–Dc3, registered Dc4)
        // = 30 total.
        let mut names = recipe_names();
        names.sort();
        assert_eq!(
            names,
            vec![
                "anticipate",
                "apriori_rules",
                "association_rules",
                "bias",
                "cohesion",
                "complexity",
                "consolidate",
                "constellation",
                "distilled_recall",
                "drift",
                "estate_divergence",
                "expand_memory",
                "formal_concepts",
                "free_association",
                "grounded_synthesis",
                "keystones",
                "latent_themes",
                "lens_contradiction",
                "migration_benchmark",
                "mind_overlap",
                "moment",
                "node_motion",
                "partial_cue_recall",
                "precedence",
                "recall_exploratory",
                "rhythm",
                "shaped_recall",
                "theme_weather",
                "trust_grounded_synthesis",
                "tunnel_successor",
            ]
        );
    }

    #[test]
    fn lens_descriptors_carry_capability_gates() {
        // Mirrors Swift `lensDescriptorsCarryCapabilityGates`.
        let trust = recipe_descriptor("trust_grounded_synthesis").unwrap();
        assert_eq!(
            trust.required_capabilities,
            vec![NeuronKitCapability::Synthesize]
        );
        let keystones = recipe_descriptor("keystones").unwrap();
        assert!(keystones.required_capabilities.is_empty());
        // Analytics lenses carry their capability requirements.
        let ar = recipe_descriptor("association_rules").unwrap();
        assert_eq!(
            ar.required_capabilities,
            vec![NeuronKitCapability::AssociationRuleMining]
        );
        let fca = recipe_descriptor("formal_concepts").unwrap();
        assert_eq!(
            fca.required_capabilities,
            vec![NeuronKitCapability::FormalConceptAnalysis]
        );
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

    #[test]
    fn association_rules_descriptor_matches_swift() {
        // Byte-for-byte parity anchor with Swift AssociationRules recipe metadata.
        let d = recipe_descriptor("association_rules").unwrap();
        assert_eq!(d.version, "1.0.0");
        assert_eq!(
            d.description,
            "Recall a frame, project each drawer's categorical facets into a co-occurrence matrix, and mine pairwise association rules."
        );
        assert_eq!(
            d.required_capabilities,
            vec![NeuronKitCapability::AssociationRuleMining]
        );
        // Wire form uses the serde rename (Swift rawValue).
        let json = serde_json::to_string(&d).unwrap();
        assert!(json.contains("\"associationRuleMining\""));
    }

    #[test]
    fn formal_concepts_descriptor_matches_swift() {
        // Byte-for-byte parity anchor with Swift FormalConcepts recipe metadata.
        let d = recipe_descriptor("formal_concepts").unwrap();
        assert_eq!(d.version, "1.0.0");
        assert_eq!(
            d.description,
            "Recall a frame, build a formal context whose attributes are each drawer's trust, lattice anchors, sensitivity, and filing facets, and mine bounded formal concepts — emergent provenance and about-ness clusters, not the authored taxonomy."
        );
        assert_eq!(
            d.required_capabilities,
            vec![NeuronKitCapability::FormalConceptAnalysis]
        );
        let json = serde_json::to_string(&d).unwrap();
        assert!(json.contains("\"formalConceptAnalysis\""));
    }

    #[test]
    fn apriori_rules_descriptor_matches_swift() {
        // Byte-for-byte parity anchor with Swift AprioriRules recipe metadata
        // (`AssociationRules.swift:227-233`).
        let d = recipe_descriptor("apriori_rules").unwrap();
        assert_eq!(d.version, "1.0.0");
        assert_eq!(
            d.description,
            "Read the estate's audit log and mine multi-antecedent association rules via the Apriori algorithm."
        );
        assert_eq!(
            d.required_capabilities,
            vec![NeuronKitCapability::AssociationRuleMining]
        );
        let json = serde_json::to_string(&d).unwrap();
        assert!(json.contains("\"associationRuleMining\""));
    }

    #[test]
    fn recall_exploratory_descriptor_matches_swift() {
        // Byte-for-byte parity anchor with Swift ExploratoryRecall recipe
        // metadata (`ExploratoryRecall.swift`).
        let d = recipe_descriptor("recall_exploratory").unwrap();
        assert_eq!(d.version, "1.0.0");
        assert_eq!(
            d.description,
            "Walk with restart from a seed drawer over a wing's tunnel graph and return the most-visited drawers ranked by visit frequency."
        );
        assert_eq!(
            d.required_capabilities,
            vec![NeuronKitCapability::ExploratoryRecall]
        );
        // Wire form uses the serde rename (Swift rawValue).
        let json = serde_json::to_string(&d).unwrap();
        assert!(json.contains("\"exploratoryRecall\""));
    }

    #[test]
    fn consolidate_descriptor_matches_swift() {
        // Byte-for-byte parity anchor with Swift Consolidate recipe
        // metadata (`Consolidate.swift`).
        let d = recipe_descriptor("consolidate").unwrap();
        assert_eq!(d.version, "1.0.0");
        assert_eq!(
            d.description,
            "Compact working memory by distilling open clusters into factoids. \
            Calls the GLK distillation sweep, which processes all ready clusters \
            (member_count \u{2265} 3, status = open) and persists each factoid as a \
            drawer in room `_distilled`."
        );
        assert!(d.required_capabilities.is_empty());
    }

    #[test]
    fn distilled_recall_descriptor_matches_swift() {
        // Byte-for-byte parity anchor with Swift DistilledRecall recipe
        // metadata (`DistilledRecall.swift`).
        let d = recipe_descriptor("distilled_recall").unwrap();
        assert_eq!(d.version, "1.0.0");
        assert_eq!(
            d.description,
            "Dense recall: search the distilled memory tier and return factoid \
            prose (~10 tokens/hit) for AI reasoning. Uses structural fingerprint \
            Hamming NN \u{2014} no embedding model inference, no full corpus scan."
        );
        assert!(d.required_capabilities.is_empty());
    }

    #[test]
    fn expand_memory_descriptor_matches_swift() {
        // Byte-for-byte parity anchor with Swift ExpandMemory recipe
        // metadata (`ExpandMemory.swift`).
        let d = recipe_descriptor("expand_memory").unwrap();
        assert_eq!(d.version, "1.0.0");
        assert_eq!(
            d.description,
            "Expand a distilled factoid to its source memories: follows the \
            _distilled_from tunnel graph and returns full episodic content \
            from the M memories that produced the factoid. Use when the user \
            needs the full explanation behind a dense factoid. The AI synthesises \
            the sources into a user-facing narrative."
        );
        assert!(d.required_capabilities.is_empty());
    }
}
