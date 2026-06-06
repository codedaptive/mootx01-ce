// lib.rs, the ARIA grammar reified.
//
// One noun, nine verbs, four adjectives, and the verb-noun acceptance
// matrix, as data. No behavior. This is the Rust version of the
// vocabulary every MOOTx01 kit and ARIA surface conforms to; it is
// conformance-gated against the Swift port (AriaLexicon) so both speak
// the same words. The canonical statement is ARIA_LEXICON.md.
//
// Provenance: the grammar was set in the action-vocabulary design
// session of 2026-05-09 (architecture v0.20, Part 10). The verb count
// is fixed at nine and the adjective category count at four (spec
// invariants I-7, I-8).

#![allow(dead_code)]

/// The grammar, stated. The contract every consumer composes.
pub const GRAMMAR: &str =
    "Every call is one verb applied to a noun, optionally constrained by adjectives.";

/// A storage shape's relationship to the drawer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum NounRole {
    /// The drawer itself, the noun of the language.
    Primary,
    /// A representation of the drawer's content (a rung).
    Rung,
    /// An edge or event about drawers.
    Structure,
    /// What a verb leaves behind.
    Product,
}

/// A storage shape the substrate persists. The Drawer is the noun of
/// the language; the rest are its rungs, structure about it, or the
/// products of verbs.
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
    /// Every shape, in declaration order.
    pub const ALL: [Noun; 8] = [
        Noun::Drawer, Noun::Tunnel, Noun::KgFact, Noun::Vector,
        Noun::DiaryEntry, Noun::Proposal, Noun::Association, Noun::LearnedReference,
    ];

    /// The one noun of the language.
    pub const PRIMARY: Noun = Noun::Drawer;

    /// How this shape relates to the drawer in the language.
    pub fn role(self) -> NounRole {
        match self {
            Noun::Drawer => NounRole::Primary,
            Noun::KgFact | Noun::Vector => NounRole::Rung,
            Noun::Tunnel | Noun::DiaryEntry | Noun::Association => NounRole::Structure,
            Noun::Proposal | Noun::LearnedReference => NounRole::Product,
        }
    }
}

/// Who initiates a verb.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Flow {
    CallerDriven,
    SubstrateDriven,
    GroundingDriven,
}

/// One of the nine actions the substrate supports.
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
    /// All nine verbs, in declaration order.
    pub const ALL: [Verb; 9] = [
        Verb::Capture, Verb::Reanchor, Verb::Mutate, Verb::Withdraw, Verb::Expunge,
        Verb::Recall, Verb::Propose, Verb::Associate, Verb::Learn,
    ];

    /// Who initiates the verb.
    pub fn flow(self) -> Flow {
        match self {
            Verb::Capture | Verb::Reanchor | Verb::Mutate
            | Verb::Withdraw | Verb::Expunge | Verb::Recall => Flow::CallerDriven,
            Verb::Propose | Verb::Associate => Flow::SubstrateDriven,
            Verb::Learn => Flow::GroundingDriven,
        }
    }
}

/// One of the four cross-noun adjective categories. The values within
/// each category are a bitmap-layout concern (spec section 5.5),
/// reified in LocusKit; the lexicon names the categories, not the
/// values, so the two do not fork.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Adjective {
    State,
    Trust,
    Sensitivity,
    Exportability,
}

impl Adjective {
    /// All four categories, in declaration order.
    pub const ALL: [Adjective; 4] = [
        Adjective::State, Adjective::Trust, Adjective::Sensitivity, Adjective::Exportability,
    ];
}

/// The verbs a shape accepts (architecture spec section 7.2). The
/// Vector is substrate-managed and not directly verb-addressable, so
/// it accepts none. Returned in canonical verb order.
pub fn accepted_verbs(noun: Noun) -> Vec<Verb> {
    use Verb::*;
    let set: &[Verb] = match noun {
        Noun::Drawer => &[Capture, Reanchor, Mutate, Withdraw, Expunge, Recall],
        Noun::Tunnel => &[Capture, Mutate, Withdraw, Expunge, Recall],
        Noun::KgFact => &[Mutate, Withdraw, Expunge, Recall],
        Noun::Vector => &[],
        Noun::DiaryEntry => &[Recall],
        // Proposal accepts Propose (the substrate-driven verb that creates it),
        // plus the lifecycle verbs. Matches Swift: [.propose, .mutate, .withdraw, .expunge, .recall]
        Noun::Proposal => &[Propose, Mutate, Withdraw, Expunge, Recall],
        // Association accepts Associate (the substrate-driven verb that accumulates
        // connective weight), plus the lifecycle verbs. Matches Swift: [.associate, .mutate, .expunge, .recall]
        Noun::Association => &[Associate, Mutate, Expunge, Recall],
        Noun::LearnedReference => &[Learn, Mutate, Withdraw, Expunge, Recall],
    };
    set.to_vec()
}

/// Whether a shape accepts a verb.
pub fn accepts(noun: Noun, verb: Verb) -> bool {
    accepted_verbs(noun).contains(&verb)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verb_count_is_nine() {
        assert_eq!(Verb::ALL.len(), 9);
    }

    #[test]
    fn adjective_count_is_four() {
        assert_eq!(Adjective::ALL.len(), 4);
    }

    #[test]
    fn drawer_is_primary() {
        assert_eq!(Noun::PRIMARY, Noun::Drawer);
        assert_eq!(Noun::Drawer.role(), NounRole::Primary);
        let primaries: Vec<Noun> =
            Noun::ALL.iter().copied().filter(|n| n.role() == NounRole::Primary).collect();
        assert_eq!(primaries, vec![Noun::Drawer]);
    }

    #[test]
    fn non_drawer_shapes_have_roles() {
        assert_eq!(Noun::KgFact.role(), NounRole::Rung);
        assert_eq!(Noun::Vector.role(), NounRole::Rung);
        assert_eq!(Noun::Tunnel.role(), NounRole::Structure);
        assert_eq!(Noun::DiaryEntry.role(), NounRole::Structure);
        assert_eq!(Noun::Association.role(), NounRole::Structure);
        assert_eq!(Noun::Proposal.role(), NounRole::Product);
        assert_eq!(Noun::LearnedReference.role(), NounRole::Product);
    }

    #[test]
    fn verb_flows_partition() {
        let caller: Vec<Verb> =
            Verb::ALL.iter().copied().filter(|v| v.flow() == Flow::CallerDriven).collect();
        let substrate: Vec<Verb> =
            Verb::ALL.iter().copied().filter(|v| v.flow() == Flow::SubstrateDriven).collect();
        let grounding: Vec<Verb> =
            Verb::ALL.iter().copied().filter(|v| v.flow() == Flow::GroundingDriven).collect();
        assert_eq!(caller, vec![Verb::Capture, Verb::Reanchor, Verb::Mutate,
                                Verb::Withdraw, Verb::Expunge, Verb::Recall]);
        assert_eq!(substrate, vec![Verb::Propose, Verb::Associate]);
        assert_eq!(grounding, vec![Verb::Learn]);
        assert_eq!(caller.len() + substrate.len() + grounding.len(), 9);
    }

    // Conformance gate: this test must match the Swift Acceptance.swift
    // implementation exactly (interface doc constraint C-3). The matrix
    // is pure vocabulary with zero platform binding — any divergence
    // between Swift and Rust is a conformance failure.
    #[test]
    fn acceptance_matrix() {
        use Verb::*;
        assert_eq!(accepted_verbs(Noun::Drawer),
                   vec![Capture, Reanchor, Mutate, Withdraw, Expunge, Recall]);
        assert_eq!(accepted_verbs(Noun::Tunnel),
                   vec![Capture, Mutate, Withdraw, Expunge, Recall]);
        assert_eq!(accepted_verbs(Noun::KgFact),
                   vec![Mutate, Withdraw, Expunge, Recall]);
        assert!(accepted_verbs(Noun::Vector).is_empty());
        assert_eq!(accepted_verbs(Noun::DiaryEntry), vec![Recall]);
        // Proposal accepts Propose (the substrate-driven verb that creates it),
        // plus the lifecycle verbs. Matches Swift: [.propose, .mutate, .withdraw, .expunge, .recall]
        assert_eq!(accepted_verbs(Noun::Proposal),
                   vec![Propose, Mutate, Withdraw, Expunge, Recall]);
        // Association accepts Associate (the substrate-driven verb that accumulates
        // connective weight), plus the lifecycle verbs. Matches Swift: [.associate, .mutate, .expunge, .recall]
        assert_eq!(accepted_verbs(Noun::Association),
                   vec![Associate, Mutate, Expunge, Recall]);
        assert_eq!(accepted_verbs(Noun::LearnedReference),
                   vec![Learn, Mutate, Withdraw, Expunge, Recall]);
    }

    #[test]
    fn accepts_agrees() {
        assert!(accepts(Noun::Drawer, Verb::Capture));
        assert!(!accepts(Noun::Drawer, Verb::Learn));
        assert!(accepts(Noun::LearnedReference, Verb::Learn));
        assert!(!accepts(Noun::Vector, Verb::Recall));
        // Spot-check the previously-missing Propose/Associate rows to ensure
        // the conformance gate now actually checks these cells.
        assert!(accepts(Noun::Proposal, Verb::Propose));
        assert!(!accepts(Noun::Proposal, Verb::Associate));
        assert!(accepts(Noun::Association, Verb::Associate));
        assert!(!accepts(Noun::Association, Verb::Propose));
    }

    #[test]
    fn verb_applicability() {
        let learners: Vec<Noun> =
            Noun::ALL.iter().copied().filter(|n| accepts(*n, Verb::Learn)).collect();
        assert_eq!(learners, vec![Noun::LearnedReference]);
        let capturers: Vec<Noun> =
            Noun::ALL.iter().copied().filter(|n| accepts(*n, Verb::Capture)).collect();
        assert_eq!(capturers, vec![Noun::Drawer, Noun::Tunnel]);
    }

    #[test]
    fn grammar_stated() {
        assert!(GRAMMAR.contains("one verb applied to a noun"));
    }
}
