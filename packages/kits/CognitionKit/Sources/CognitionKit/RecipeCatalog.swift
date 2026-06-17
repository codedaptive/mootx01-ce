// RecipeCatalog.swift
//
// The conscious mind's self-knowledge: an enumerable catalog of the
// behaviour recipes CognitionKit ships. A recipe's `Input`/`Output` are
// associated types, so recipes cannot live together in a homogeneous
// array — but their METADATA can. `RecipeDescriptor` is the type-erased
// metadata projection (name, version, description, required
// capabilities); `RecipeCatalog` is the registry of all shipped recipes.
//
// This is the "broader reach" primitive: any caller — an MCP client, an
// agent, a future composing recipe — can ask CognitionKit what
// behaviours exist and what each one needs, without hard-coding the list
// at every call site. As noun-verb missions land and new recipes ship,
// they register here once and every enumerator sees them.

import Foundation

/// Type-erased metadata for a recipe. Carries everything a caller needs
/// to discover and reason about a recipe without invoking it. Codable so
/// it crosses the MCP wire as a tool/listing payload.
public struct RecipeDescriptor: Sendable, Equatable, Codable {
    /// Stable recipe name (e.g. "grounded_synthesis"). Matches the
    /// recipe's own `name` and the MCP tool stem.
    public let name: String
    /// Recipe version string.
    public let version: String
    /// One-line human-readable description.
    public let description: String
    /// The NeuronKit capabilities the recipe sequences.
    public let requiredCapabilities: [NeuronKitCapability]

    public init(
        name: String,
        version: String,
        description: String,
        requiredCapabilities: [NeuronKitCapability]
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.requiredCapabilities = requiredCapabilities
    }

    /// Project a live recipe into its descriptor.
    public init(_ recipe: some Recipe) {
        self.init(
            name: recipe.name,
            version: recipe.version,
            description: recipe.description,
            requiredCapabilities: recipe.requiredCapabilities)
    }
}

/// The registry of behaviour recipes CognitionKit ships. The single
/// place a new recipe is registered for discovery; both the ARIA_MCP
/// tool surface and any in-process enumerator read from here.
public enum RecipeCatalog {

    /// Every shipped recipe's descriptor, in stable declaration order:
    /// the foundational recipes first, then the reasoning lenses by
    /// category. A recipe registers when both its versions ship
    /// (LENS_DISCOVERABILITY_DECISION v2.0) — added here once, it
    /// becomes discoverable everywhere that reads the catalog. The lens
    /// entry points are static namespaces, so their descriptors are
    /// declared literally; descriptor strings match `catalog.rs`
    /// byte-for-byte (the conformance anchor).
    public static let all: [RecipeDescriptor] = [
        RecipeDescriptor(GroundedSynthesis()),
        RecipeDescriptor(MigrationBenchmark()),
        // Structure lenses.
        RecipeDescriptor(
            name: "keystones", version: "1.0.0",
            description: "Reasoning lens: rank a wing's load-bearing memories by centrality over its drawer-to-drawer tunnel graph.",
            requiredCapabilities: []),
        RecipeDescriptor(
            name: "constellation", version: "1.0.0",
            description: "Reasoning lens: recover the emergent communities of a wing's drawer-to-drawer tunnel graph.",
            requiredCapabilities: []),
        RecipeDescriptor(
            name: "free_association", version: "1.0.0",
            description: "Reasoning lens: from a seed memory, walk the wing's tunnel graph with restart and rank the memories the walk keeps landing on.",
            requiredCapabilities: []),
        // Topic lenses.
        RecipeDescriptor(
            name: "theme_weather", version: "1.0.0",
            description: "Reasoning lens: per-room momentum — recent attention share vs historical share; what's rising and what's fading.",
            requiredCapabilities: []),
        RecipeDescriptor(
            name: "latent_themes", version: "1.0.0",
            description: "Reasoning lens: factor the recalled set's metadata co-occurrence into soft latent themes — the emergent topics in how the estate is filed.",
            requiredCapabilities: []),
        // Preference lens.
        RecipeDescriptor(
            name: "bias", version: "1.0.0",
            description: "Reasoning lens: representation bias vs a reference, per-room dismissal rates, and learned preference from real curation choices.",
            requiredCapabilities: []),
        // Surprise lenses.
        RecipeDescriptor(
            name: "drift", version: "1.0.0",
            description: "Reasoning lens: how far the room distribution after a split instant has drifted from the distribution before it.",
            requiredCapabilities: []),
        RecipeDescriptor(
            name: "contradiction", version: "1.0.0",
            description: "Reasoning lens: flag the recalled memories whose content cohesion with their peers is anomalously low — the odd-ones-out.",
            requiredCapabilities: []),
        // Grounding / trust lens (v1.1.0: adds optional calibrated confidences).
        RecipeDescriptor(
            name: "trust_grounded_synthesis", version: "1.1.0",
            description: "Reasoning lens: recall, rank by provenance trust (canonical and user above derived), and synthesize the trust-ordered set.",
            requiredCapabilities: [.synthesize]),
        // Associative lens.
        RecipeDescriptor(
            name: "partial_cue_recall", version: "1.0.0",
            description: "Reasoning lens: one anchor memory, three recalls — feels-like, about-this, from-then — by per-block fingerprint matching.",
            requiredCapabilities: []),
        // Prediction lenses.
        RecipeDescriptor(
            name: "anticipate", version: "1.0.0",
            description: "Reasoning lens: learn which capture actions tend to reach a target outcome, ranked by conservative success rate.",
            requiredCapabilities: []),
        RecipeDescriptor(
            name: "tunnel_successor", version: "1.0.0",
            description: "Reasoning lens: the memories an anchor points onward to by explicit tunnels, ranked by frequency.",
            requiredCapabilities: []),
        // Federated lenses.
        RecipeDescriptor(
            name: "mind_overlap", version: "1.0.0",
            description: "Reasoning lens (federated): privacy-preserving overlap of two estates via differentially-private fingerprint summaries.",
            requiredCapabilities: []),
        RecipeDescriptor(
            name: "estate_divergence", version: "1.0.0",
            description: "Reasoning lens (federated): how two estates' room distributions diverge, by Jensen-Shannon divergence.",
            requiredCapabilities: []),
        // Analytics lenses.
        RecipeDescriptor(AssociationRules()),
        RecipeDescriptor(FormalConcepts()),
        RecipeDescriptor(AprioriRules()),
        // Temporal lenses (Lenses 1–3, Time+Prediction).
        RecipeDescriptor(
            name: "moment", version: "1.0.0",
            description: "Reasoning lens: OR-reduce the primary window's fingerprints into a temporal signature and rank comparison windows by Hamming proximity.",
            requiredCapabilities: []),
        RecipeDescriptor(
            name: "rhythm", version: "1.0.0",
            description: "Reasoning lens: FFT over a time-bucketed fingerprint bit series to surface the dominant periodic activity patterns.",
            requiredCapabilities: []),
        RecipeDescriptor(
            name: "precedence", version: "1.0.0",
            description: "Reasoning lens: fold the estate's audit trail into T-matrix deltas and rank the antecedents most predictive of a target field-value coordinate.",
            requiredCapabilities: []),
        // Information-theoretic lens (Lens 4, Topics).
        RecipeDescriptor(
            name: "complexity", version: "1.0.0",
            description: "Reasoning lens: Shannon entropy (and optional mutual information) over the distribution of a label field across the recalled set.",
            requiredCapabilities: []),
        // Steerable-fusion recipe (GLK-RECALL-SHAPE-PRESETS): one parameterized
        // recipe over the named RecallShape preset roster. Declared literally
        // here (the entry point is the static `ShapedRecall` namespace); the
        // descriptor strings match `catalog.rs` byte-for-byte.
        RecipeDescriptor(ShapedRecall()),
    ]

    /// The descriptor for the recipe named `name`, or nil if no shipped
    /// recipe carries that name.
    public static func descriptor(named name: String) -> RecipeDescriptor? {
        all.first { $0.name == name }
    }

    /// The names of all shipped recipes, in catalog order.
    public static var names: [String] {
        all.map(\.name)
    }
}
