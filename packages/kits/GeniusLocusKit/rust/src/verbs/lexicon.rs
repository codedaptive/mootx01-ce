// lexicon.rs — Rust mirror of the AriaLexicon vocabulary, scoped to
// the constructs the GLK verb surface needs.
//
// Source of truth for the vocabulary is the AriaLexicon Swift module
// at `AriaLexicon/Sources/AriaLexicon/`. The Rust port duplicates the
// names and the §7.2 acceptance matrix as data so the parity test in
// `tests/verb_parity.rs` can assert agreement across ports. AriaLexicon
// has its own Rust port in a later mission; until then this minimal
// mirror keeps the GLK conformance gate honored.

use crate::verbs::frames; // for re-exporting types if needed downstream

// Suppress the unused-import lint without removing the import: it
// keeps the module-level dependency record honest and signals to
// downstream missions that the lexicon module is meant to share
// frame-adjacent types as the Rust port grows.
#[allow(dead_code)]
const _FRAMES_LINK: fn() = || {
    let _ = std::mem::size_of::<frames::CaptureFrame>();
};

/// The nine verbs of the ARIA grammar. Names and order mirror
/// `AriaLexicon.Verb` in Swift (`Verb.swift`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Verb {
    Capture,
    Reanchor,
    Mutate,
    Withdraw,
    Expunge,
    Recall,
    Propose,
    Associate,
    Learn,
}

impl Verb {
    /// All nine verbs in declaration order. Mirrors
    /// `Verb.allCases` in Swift.
    pub const ALL: [Verb; 9] = [
        Verb::Capture,
        Verb::Reanchor,
        Verb::Mutate,
        Verb::Withdraw,
        Verb::Expunge,
        Verb::Recall,
        Verb::Propose,
        Verb::Associate,
        Verb::Learn,
    ];

    /// Lower-case method-name representation used by the surface's
    /// identity-by-name mapping. The string is the same as Swift's
    /// `Verb.rawValue` for the same case.
    pub fn name(self) -> &'static str {
        match self {
            Verb::Capture => "capture",
            Verb::Reanchor => "reanchor",
            Verb::Mutate => "mutate",
            Verb::Withdraw => "withdraw",
            Verb::Expunge => "expunge",
            Verb::Recall => "recall",
            Verb::Propose => "propose",
            Verb::Associate => "associate",
            Verb::Learn => "learn",
        }
    }

    /// Who initiates the verb. Mirrors `AriaLexicon.Verb.flow`.
    pub fn flow(self) -> VerbFlow {
        match self {
            Verb::Capture
            | Verb::Reanchor
            | Verb::Mutate
            | Verb::Withdraw
            | Verb::Expunge
            | Verb::Recall => VerbFlow::CallerDriven,
            Verb::Propose | Verb::Associate => VerbFlow::SubstrateDriven,
            Verb::Learn => VerbFlow::GroundingDriven,
        }
    }
}

/// Who initiates a verb. Mirrors `AriaLexicon.Flow`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VerbFlow {
    CallerDriven,
    SubstrateDriven,
    GroundingDriven,
}

/// Eight storage shapes. Mirrors `AriaLexicon.Noun` in Swift
/// (`Noun.swift`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Noun {
    Drawer,
    Tunnel,
    KgFact,
    Vector,
    DiaryEntry,
    Proposal,
    Association,
    LearnedReference,
}

impl Noun {
    /// All eight nouns in declaration order.
    pub const ALL: [Noun; 8] = [
        Noun::Drawer,
        Noun::Tunnel,
        Noun::KgFact,
        Noun::Vector,
        Noun::DiaryEntry,
        Noun::Proposal,
        Noun::Association,
        Noun::LearnedReference,
    ];

    /// The one noun of the language.
    pub const PRIMARY: Noun = Noun::Drawer;

    /// How this shape relates to the drawer.
    pub fn role(self) -> NounRole {
        match self {
            Noun::Drawer => NounRole::Primary,
            Noun::KgFact | Noun::Vector => NounRole::Rung,
            Noun::Tunnel | Noun::DiaryEntry | Noun::Association => NounRole::Structure,
            Noun::Proposal | Noun::LearnedReference => NounRole::Product,
        }
    }
}

/// A storage shape's relationship to the drawer. Mirrors
/// `AriaLexicon.NounRole`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NounRole {
    Primary,
    Rung,
    Structure,
    Product,
}

/// The four adjective categories. Mirrors `AriaLexicon.Adjective`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Adjective {
    State,
    Trust,
    Sensitivity,
    Exportability,
}

impl Adjective {
    pub const ALL: [Adjective; 4] = [
        Adjective::State,
        Adjective::Trust,
        Adjective::Sensitivity,
        Adjective::Exportability,
    ];
}

/// The verb-noun acceptance matrix (architecture spec §7.2).
/// Mirrors `AriaLexicon.Acceptance` in Swift. Treat as data so the
/// parity test can compare against the Swift enumeration.
pub struct Acceptance;

impl Acceptance {
    /// The verbs a shape accepts. Same closed sets as
    /// `Acceptance.verbs(for:)` in Swift.
    pub fn verbs(noun: Noun) -> &'static [Verb] {
        match noun {
            Noun::Drawer => &[
                Verb::Capture,
                Verb::Reanchor,
                Verb::Mutate,
                Verb::Withdraw,
                Verb::Expunge,
                Verb::Recall,
            ],
            Noun::Tunnel => &[
                Verb::Capture,
                Verb::Mutate,
                Verb::Withdraw,
                Verb::Expunge,
                Verb::Recall,
            ],
            Noun::KgFact => &[Verb::Mutate, Verb::Withdraw, Verb::Expunge, Verb::Recall],
            Noun::Vector => &[],
            Noun::DiaryEntry => &[Verb::Recall],
            Noun::Proposal => &[Verb::Mutate, Verb::Withdraw, Verb::Expunge, Verb::Recall],
            Noun::Association => &[Verb::Mutate, Verb::Expunge, Verb::Recall],
            Noun::LearnedReference => &[
                Verb::Learn,
                Verb::Mutate,
                Verb::Withdraw,
                Verb::Expunge,
                Verb::Recall,
            ],
        }
    }

    /// Whether a shape accepts a verb.
    pub fn accepts(noun: Noun, verb: Verb) -> bool {
        Self::verbs(noun).contains(&verb)
    }
}

/// A (Verb, Noun) pair the GLK surface routes against an existing
/// operand noun in the lexicon's §7.2 matrix sense. Mirrors
/// `AriaLexiconConformance.surfaceTargets` in Swift.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SurfaceTarget {
    pub verb: Verb,
    pub noun: Noun,
}

impl SurfaceTarget {
    /// The seven surface targets the §7.2 matrix accepts. The two
    /// substrate-driven verbs (propose, associate) are excluded for
    /// the same reason as the Swift mirror: the matrix has no row
    /// that accepts them, because both verbs create products without
    /// targeting an existing instance of a noun.
    pub const ALL: [SurfaceTarget; 7] = [
        SurfaceTarget {
            verb: Verb::Capture,
            noun: Noun::Drawer,
        },
        SurfaceTarget {
            verb: Verb::Recall,
            noun: Noun::Drawer,
        },
        SurfaceTarget {
            verb: Verb::Mutate,
            noun: Noun::Drawer,
        },
        SurfaceTarget {
            verb: Verb::Withdraw,
            noun: Noun::Drawer,
        },
        SurfaceTarget {
            verb: Verb::Expunge,
            noun: Noun::Drawer,
        },
        SurfaceTarget {
            verb: Verb::Reanchor,
            noun: Noun::Drawer,
        },
        SurfaceTarget {
            verb: Verb::Learn,
            noun: Noun::LearnedReference,
        },
    ];

    /// True when every surface target is in the §7.2 matrix.
    pub fn every_target_accepted() -> bool {
        Self::ALL
            .iter()
            .all(|t| Acceptance::accepts(t.noun, t.verb))
    }
}
