//! Default wing constants and definitions. Rust port of `DefaultWings.swift`.
//!
//! ADR-016 §1–§2: the estate's default wing name is the fixed constant
//! `DEFAULT_WING_NAME` ("Agentic Memory"). At provision time, GeniusLocusKit
//! seeds seven named wings, each with a hint memory in the normal room
//! `HINT_ROOM` ("AI_Charter_Hint"). These constants drive both the per-capture
//! wing assignment (in `estate_verbs.rs`) and the seeding loop in
//! `estate_verbs.rs::seed_wing`.
//!
//! Seven seeded wings:
//! 1. Agentic Memory — the default wing for all `capture` calls
//! 2. User Canon
//! 3. Source Corpus
//! 4. Personal
//! 5. Professional
//! 6. Projects
//! 7. Temp
//!
//! Swift parity: `DefaultWings.swift` in LocusKit. Kept in lockstep.
//! Hint text must match verbatim — the cross-port canonical text.

/// Fixed name for the default wing. ADR-016 §1.
/// Every `capture` call that does not supply an explicit wing writes here.
pub const DEFAULT_WING_NAME: &str = "Agentic Memory";

/// Room name for per-wing hint memories seeded at provision. ADR-016 §2.
/// A drawer filed in this room IS the hint memory for the wing.
/// Per ADR-017, wings are node rows in the `nodes` table and drawers
/// reference their parent room via `parent_node_id`.
/// The hint memory is a NORMAL drawer: embedded, recallable, user-deletable.
pub const HINT_ROOM: &str = "AI_Charter_Hint";

/// UDC anchor for hint drawers — Knowledge class, matches spec I-5
/// requirement that udcCode must not be empty.
pub const HINT_UDC_CODE: &str = "001";

/// Provenance addedBy for hint drawers — identifies the estate
/// provisioner as the source, not an AI inference or user action.
/// This is an HONEST PROVENANCE VALUE only. No code may branch on it.
pub const HINT_ADDED_BY: &str = "estate-provision";

/// A single default wing definition: name + its hint text.
/// Hint text is the wing's role description, stored verbatim in the
/// `AI_Charter_Hint` room so recalls against that wing surface its purpose.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WingDefinition {
    /// The wing name (used as the node `display_name` for the wing node in the
    /// ADR-017 `nodes` table).
    pub name: &'static str,
    /// The hint text (becomes `drawer.content` in the `AI_Charter_Hint` room).
    pub hint: &'static str,
}

/// The seven default wings seeded at provision time. ADR-016 §2.
///
/// Order matches `DefaultWings.swift` exactly — the first entry is the
/// default wing (`DEFAULT_WING_NAME`). Hint text is identical verbatim
/// to the Swift side; any divergence is a conformance failure.
pub const DEFAULT_WINGS: &[WingDefinition] = &[
    WingDefinition {
        name: "Agentic Memory",
        hint: "The AI's own observations, inferences, decisions, session learnings.",
    },
    WingDefinition {
        name: "User Canon",
        hint: "Explicit user directives, preferences, corrections, standing orders — authoritative; the AI weights these above its own inferences and does not silently overwrite them.",
    },
    WingDefinition {
        name: "Source Corpus",
        hint: "Imported / ingested documents, books, reference material — external grounding, not the AI's beliefs.",
    },
    WingDefinition {
        name: "Personal",
        hint: "The user's personal-life domain.",
    },
    WingDefinition {
        name: "Professional",
        hint: "The user's work domain.",
    },
    WingDefinition {
        name: "Projects",
        hint: "Active project / workspace context.",
    },
    WingDefinition {
        name: "Temp",
        hint: "Scratch / ephemeral. Aggressively dream-aged (decay knob scoped to this wing).",
    },
];
