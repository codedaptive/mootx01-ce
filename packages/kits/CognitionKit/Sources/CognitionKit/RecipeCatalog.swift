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

    /// Every shipped recipe's descriptor, in stable declaration order.
    /// A new recipe is added here once and becomes discoverable
    /// everywhere that reads the catalog.
    public static let all: [RecipeDescriptor] = [
        RecipeDescriptor(GroundedSynthesis()),
        RecipeDescriptor(MigrationBenchmark()),
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
