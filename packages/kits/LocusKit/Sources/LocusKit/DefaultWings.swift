// DefaultWings.swift — Seven seeded default wings and their charter content.
//
// ADR-016: Wings are the provenance/role axis. A fresh estate seeds these
// seven wings, each with a `_charter` memory in the reserved `_charter` room
// that describes the wing's role. The set is a suggestion, not a constraint —
// callers may create any wing; these seven are seeded at provision time to
// orient a fresh agent.
//
// "Agentic Memory" is the default wing used by `capture` when the caller
// does not pass an explicit wing. It is the AI's primary working space.

/// The default wing for `capture` when no explicit wing is supplied.
///
/// ADR-016: renamed from the prior dynamic `"wing_<owner>"` derivation.
/// All new captures without an explicit wing land here. Existing captures
/// that landed in the prior `"wing_<owner>"` form are not migrated — the
/// schema is unfrozen and no data exists that requires migration.
public let defaultWingName: String = "Agentic Memory"

/// The reserved room name for charter drawers within each wing.
///
/// ADR-016: each seeded wing carries one memory in this room stating in
/// plain language what the lane is for. Charter drawers are seeded at
/// estate provision and may be updated by the AI or user to refine the
/// wing's purpose.
public let charterRoom: String = "_charter"

/// UDC Knowledge class code stamped onto charter drawers.
/// UDC 001 = "Knowledge. Science. Information". Appropriate for
/// self-describing / meta-knowledge drawers per spec I-5 (udcCode must
/// not be empty).
public let charterUDCCode: String = "001"

/// Actor identifier written into charter drawer `addedBy` fields.
public let charterAddedBy: String = "estate-provision"

/// Embedding model ID used for charter drawers. Charters are plain prose;
/// they use the same model ID as ordinary captured content so that semantic
/// recall surfaces them alongside the memories they describe.
public let charterEmbeddingModelID: String = "none"

// MARK: - WingDefinition

/// A wing name paired with its charter text.
///
/// The charter is seeded as a drawer in the wing's `_charter` room at
/// estate provision time (ADR-016 §2).
public struct WingDefinition: Sendable, Equatable {
    /// The wing's display name (also the value stored in the `wing` column).
    public let name: String
    /// Plain-language role description seeded as the `_charter` memory.
    public let charter: String

    public init(name: String, charter: String) {
        self.name = name
        self.charter = charter
    }
}

// MARK: - Default wing set (ADR-016 §1)

/// The seven default wings seeded at estate provision.
///
/// These are **suggestions**, not a fixed schema. The AI may create any
/// additional wing; nothing enforces this set as the complete list.
/// Wing order here is not significant — estates are indexed by wing name,
/// not position.
public let defaultWings: [WingDefinition] = [
    WingDefinition(
        name: "Agentic Memory",
        charter: "The AI's own observations, inferences, decisions, session learnings."
    ),
    WingDefinition(
        name: "User Canon",
        charter: "Explicit user directives, preferences, corrections, standing orders — authoritative; the AI weights these above its own inferences and does not silently overwrite them."
    ),
    WingDefinition(
        name: "Source Corpus",
        charter: "Imported / ingested documents, books, reference material — external grounding, not the AI's beliefs."
    ),
    WingDefinition(
        name: "Personal",
        charter: "The user's personal-life domain."
    ),
    WingDefinition(
        name: "Professional",
        charter: "The user's work domain."
    ),
    WingDefinition(
        name: "Projects",
        charter: "Active project / workspace context."
    ),
    WingDefinition(
        name: "Temp",
        charter: "Scratch / ephemeral. Aggressively dream-aged (decay knob scoped to this wing)."
    ),
]
