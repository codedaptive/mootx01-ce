// DefaultWings.swift — Seven seeded default wings and their hint content.
//
// ADR-016: Wings are the provenance/role axis. A fresh estate seeds these
// seven wings, each with a hint memory in the normal `AI_Charter_Hint` room
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

/// The room name for per-wing hint memories seeded at provision.
///
/// ADR-016: each seeded wing carries one memory in this room stating in
/// plain language what the lane is for. Hint drawers are seeded at
/// estate provision and are normal recallable memories — they may be
/// updated or deleted by the AI or user like any other drawer.
public let hintRoom: String = "AI_Charter_Hint"

/// UDC Knowledge class code stamped onto hint drawers.
/// UDC 001 = "Knowledge. Science. Information". Appropriate for
/// self-describing / meta-knowledge drawers per spec I-5 (udcCode must
/// not be empty).
public let hintUDCCode: String = "001"

/// Actor identifier written into hint drawer `addedBy` fields.
/// This is an HONEST PROVENANCE VALUE only — no code may branch on it.
public let hintAddedBy: String = "estate-provision"

// MARK: - WingDefinition

/// A wing name paired with its hint text.
///
/// The hint is seeded as a drawer in the wing's `AI_Charter_Hint` room at
/// estate provision time (ADR-016 §2).
public struct WingDefinition: Sendable, Equatable {
    /// The wing's display name (also the value stored in the `wing` column).
    public let name: String
    /// Plain-language role description seeded as the hint memory.
    public let hint: String

    public init(name: String, hint: String) {
        self.name = name
        self.hint = hint
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
        hint: "The AI's own observations, inferences, decisions, session learnings."
    ),
    WingDefinition(
        name: "User Canon",
        hint: "Explicit user directives, preferences, corrections, standing orders — authoritative; the AI weights these above its own inferences and does not silently overwrite them."
    ),
    WingDefinition(
        name: "Source Corpus",
        hint: "Imported / ingested documents, books, reference material — external grounding, not the AI's beliefs."
    ),
    WingDefinition(
        name: "Personal",
        hint: "The user's personal-life domain."
    ),
    WingDefinition(
        name: "Professional",
        hint: "The user's work domain."
    ),
    WingDefinition(
        name: "Projects",
        hint: "Active project / workspace context."
    ),
    WingDefinition(
        name: "Temp",
        hint: "Scratch / ephemeral. Aggressively dream-aged (decay knob scoped to this wing)."
    ),
]
