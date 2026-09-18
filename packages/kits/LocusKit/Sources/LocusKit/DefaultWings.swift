// DefaultWings.swift — Seven seeded default wings and their hint content.

import Foundation
//
// Wings are the provenance/role axis. A fresh estate seeds these
// seven wings, each with a hint memory in the normal `AI_Charter_Hint` room
// that describes the wing's role. The set is a suggestion, not a constraint —
// callers may create any wing; these seven are seeded at provision time to
// orient a fresh agent.
//
// "Agentic Memory" is the default wing used by `capture` when the caller
// does not pass an explicit wing. It is the AI's primary working space.

/// The default wing for `capture` when no explicit wing is supplied.
///
/// renamed from the prior dynamic `"wing_<owner>"` derivation.
/// All new captures without an explicit wing land here. Existing captures
/// that landed in the prior `"wing_<owner>"` form are not migrated — the
/// schema is unfrozen and no data exists that requires migration.
public let defaultWingName: String = "Agentic Memory"

/// The room name for per-wing hint memories seeded at provision.
///
/// each seeded wing carries one memory in this room stating in
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

/// Fixed filing instant for charter hint drawers (2000-01-01T00:00:00Z).
///
/// Charters are reference documentation, not recent memories: stamping them
/// with the provision wall-clock made them the NEWEST rows in every fresh
/// estate, so they won recency contests against real user memories and —
/// because the stamp varied with the provision instant — made two estates
/// built from the same recipe rank differently (the 2026-08-24 benchmark
/// replay-drift root cause). A fixed past date removes both effects: charters
/// never outrank genuinely recent content, and the stamp is a constant.
/// Mirrors Rust `default_wings::CHARTER_SEED_UNIX_MS`.
public let charterSeedDate: Date = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01T00:00:00Z

/// Fixed drawer IDs for the seven default-wing charter hints, by position in
/// `defaultWings` (index 0 → …0001). Seed data carries well-known IDs so
/// charters are directly addressable and never participate in the random-UUID
/// tie-break noise that a fresh mint per estate produced. A wing OUTSIDE the
/// default roster (custom seeding) gets a normal random UUID — only the seven
/// canonical charters are pinned. Mirrors Rust `default_wings::charter_drawer_id`.
public func charterDrawerID(forWingIndex index: Int) -> String {
    String(format: "00000000-0000-0000-0000-%012X", index + 1)
}

// MARK: - WingDefinition

/// A wing name paired with its hint text.
///
/// The hint is seeded as a drawer in the wing's `AI_Charter_Hint` room at
/// estate provision time.
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

// MARK: - Default wing set

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
