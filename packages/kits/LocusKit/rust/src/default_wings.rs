//! Default wing constants and definitions. Rust port of `DefaultWings.swift`.
//!
//! ADR-016 §1–§2: the estate's default wing name is the fixed constant
//! `DEFAULT_WING_NAME` ("Agentic Memory"). At provision time, GeniusLocusKit
//! seeds seven named wings, each with a `_charter` drawer in the reserved
//! `CHARTER_ROOM` ("_charter"). These constants drive both the per-capture
//! wing assignment (in `estate_verbs.rs`) and the seeding loop in
//! `coordinator.rs`.
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
//! Charter text must match verbatim — the ADR defines it as the
//! cross-port canonical text.

/// Fixed name for the default wing. ADR-016 §1.
/// Every `capture` call that does not supply an explicit wing writes here.
pub const DEFAULT_WING_NAME: &str = "Agentic Memory";

/// Reserved room for wing charter drawers. ADR-016 §2.
/// A drawer filed in this room IS the act of creating the wing —
/// no separate wings table exists; wings emerge from SELECT DISTINCT wing.
pub const CHARTER_ROOM: &str = "_charter";

/// UDC anchor for charter drawers — Knowledge class, matches spec I-5
/// requirement that udcCode must not be empty.
pub const CHARTER_UDC_CODE: &str = "001";

/// Provenance addedBy for charter drawers — identifies the estate
/// provisioner as the source, not an AI inference or user action.
pub const CHARTER_ADDED_BY: &str = "estate-provision";

/// Embedding model ID for charter drawers — "none" because charter
/// text is structural metadata, not semantic content to be embedded.
pub const CHARTER_EMBEDDING_MODEL_ID: &str = "none";

/// A single default wing definition: name + its charter text.
/// Charter text is the wing's role description, stored verbatim in the
/// `_charter` drawer so recalls against that wing surface its purpose.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WingDefinition {
    /// The wing name (becomes `drawer.wing` and the DISTINCT wing identifier).
    pub name: &'static str,
    /// The charter text (becomes `drawer.content` in the `_charter` room).
    pub charter: &'static str,
}

/// The seven default wings seeded at provision time. ADR-016 §2.
///
/// Order matches `DefaultWings.swift` exactly — the first entry is the
/// default wing (`DEFAULT_WING_NAME`). Charter text is identical verbatim
/// to the Swift side; any divergence is a conformance failure.
pub const DEFAULT_WINGS: &[WingDefinition] = &[
    WingDefinition {
        name: "Agentic Memory",
        charter: "The AI's own observations, inferences, decisions, session learnings.",
    },
    WingDefinition {
        name: "User Canon",
        charter: "Explicit user directives, preferences, corrections, standing orders — authoritative; the AI weights these above its own inferences and does not silently overwrite them.",
    },
    WingDefinition {
        name: "Source Corpus",
        charter: "Imported / ingested documents, books, reference material — external grounding, not the AI's beliefs.",
    },
    WingDefinition {
        name: "Personal",
        charter: "The user's personal-life domain.",
    },
    WingDefinition {
        name: "Professional",
        charter: "The user's work domain.",
    },
    WingDefinition {
        name: "Projects",
        charter: "Active project / workspace context.",
    },
    WingDefinition {
        name: "Temp",
        charter: "Scratch / ephemeral. Aggressively dream-aged (decay knob scoped to this wing).",
    },
];
