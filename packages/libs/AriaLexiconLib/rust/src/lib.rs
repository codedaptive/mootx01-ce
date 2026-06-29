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

use serde::{Deserialize, Serialize};

/// The grammar, stated. The contract every consumer composes.
pub const GRAMMAR: &str =
    "Every call is one verb applied to a noun, optionally constrained by adjectives.";

/// A storage shape's relationship to the drawer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
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

    /// The wire string for this noun — matches the Swift `Noun.rawValue` exactly.
    ///
    /// Swift `Noun` is a `String` enum whose case names ARE the raw values (no
    /// explicit `= "…"` needed in Swift). The Rust variants use PascalCase by
    /// convention; this method maps them back to the camelCase wire strings so
    /// the JSON lexicon payload is byte-identical to the Swift port.
    pub fn as_str(self) -> &'static str {
        match self {
            Noun::Drawer          => "drawer",
            Noun::Tunnel          => "tunnel",
            Noun::KgFact          => "kgFact",
            Noun::Vector          => "vector",
            Noun::DiaryEntry      => "diaryEntry",
            Noun::Proposal        => "proposal",
            Noun::Association     => "association",
            Noun::LearnedReference => "learnedReference",
        }
    }

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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Flow {
    CallerDriven,
    SubstrateDriven,
    GroundingDriven,
}

/// One of the nine actions the substrate supports.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
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

    /// The wire string for this verb — matches the Swift `Verb.rawValue` exactly.
    ///
    /// Swift `Verb` case names ARE the raw values. The Rust PascalCase variants
    /// map to lowercase camelCase wire strings here so the JSON lexicon payload
    /// is byte-identical to the Swift port.
    pub fn as_str(self) -> &'static str {
        match self {
            Verb::Capture   => "capture",
            Verb::Reanchor  => "reanchor",
            Verb::Mutate    => "mutate",
            Verb::Withdraw  => "withdraw",
            Verb::Expunge   => "expunge",
            Verb::Recall    => "recall",
            Verb::Propose   => "propose",
            Verb::Associate => "associate",
            Verb::Learn     => "learn",
        }
    }

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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
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

    /// The wire string for this adjective category — matches the Swift
    /// `Adjective.rawValue` exactly. Swift case names ARE the raw values;
    /// this method maps the PascalCase Rust variants back to lowercase.
    pub fn as_str(self) -> &'static str {
        match self {
            Adjective::State         => "state",
            Adjective::Trust         => "trust",
            Adjective::Sensitivity   => "sensitivity",
            Adjective::Exportability => "exportability",
        }
    }
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

    #[test]
    fn serde_noun_wire_strings_match_as_str() {
        // serde encoding must produce the same string as as_str() for
        // cross-language wire compatibility with Swift Codable.
        for noun in Noun::ALL {
            let json = serde_json::to_string(&noun).expect("serialize");
            let expected = format!("\"{}\"", noun.as_str());
            assert_eq!(json, expected, "Noun::{:?} serde mismatch", noun);
        }
    }

    #[test]
    fn serde_verb_wire_strings_match_as_str() {
        for verb in Verb::ALL {
            let json = serde_json::to_string(&verb).expect("serialize");
            let expected = format!("\"{}\"", verb.as_str());
            assert_eq!(json, expected, "Verb::{:?} serde mismatch", verb);
        }
    }

    #[test]
    fn serde_adjective_wire_strings_match_as_str() {
        for adj in Adjective::ALL {
            let json = serde_json::to_string(&adj).expect("serialize");
            let expected = format!("\"{}\"", adj.as_str());
            assert_eq!(json, expected, "Adjective::{:?} serde mismatch", adj);
        }
    }

    #[test]
    fn serde_noun_roundtrip() {
        for noun in Noun::ALL {
            let json = serde_json::to_string(&noun).expect("serialize");
            let decoded: Noun = serde_json::from_str(&json).expect("deserialize");
            assert_eq!(decoded, noun);
        }
    }

    #[test]
    fn serde_verb_roundtrip() {
        for verb in Verb::ALL {
            let json = serde_json::to_string(&verb).expect("serialize");
            let decoded: Verb = serde_json::from_str(&json).expect("deserialize");
            assert_eq!(decoded, verb);
        }
    }

    // Conformance gate: `as_str()` on every variant must match the Swift rawValue
    // wire strings exactly. These are foundational — a mismatch silently mis-labels
    // every noun/verb/adjective in the JSON lexicon served to the dashboard.
    #[test]
    fn noun_as_str_wire_conformance() {
        assert_eq!(Noun::Drawer.as_str(),           "drawer");
        assert_eq!(Noun::Tunnel.as_str(),           "tunnel");
        assert_eq!(Noun::KgFact.as_str(),           "kgFact");
        assert_eq!(Noun::Vector.as_str(),           "vector");
        assert_eq!(Noun::DiaryEntry.as_str(),       "diaryEntry");
        assert_eq!(Noun::Proposal.as_str(),         "proposal");
        assert_eq!(Noun::Association.as_str(),      "association");
        assert_eq!(Noun::LearnedReference.as_str(), "learnedReference");
        // Ensure ALL is complete — every variant must be covered.
        assert_eq!(Noun::ALL.len(), 8);
        let all_strs: Vec<&str> = Noun::ALL.iter().map(|n| n.as_str()).collect();
        let expected = ["drawer", "tunnel", "kgFact", "vector",
                        "diaryEntry", "proposal", "association", "learnedReference"];
        assert_eq!(all_strs, expected);
    }

    #[test]
    fn verb_as_str_wire_conformance() {
        assert_eq!(Verb::Capture.as_str(),   "capture");
        assert_eq!(Verb::Reanchor.as_str(),  "reanchor");
        assert_eq!(Verb::Mutate.as_str(),    "mutate");
        assert_eq!(Verb::Withdraw.as_str(),  "withdraw");
        assert_eq!(Verb::Expunge.as_str(),   "expunge");
        assert_eq!(Verb::Recall.as_str(),    "recall");
        assert_eq!(Verb::Propose.as_str(),   "propose");
        assert_eq!(Verb::Associate.as_str(), "associate");
        assert_eq!(Verb::Learn.as_str(),     "learn");
        // Ensure ALL is complete.
        assert_eq!(Verb::ALL.len(), 9);
        let all_strs: Vec<&str> = Verb::ALL.iter().map(|v| v.as_str()).collect();
        let expected = ["capture", "reanchor", "mutate", "withdraw", "expunge",
                        "recall", "propose", "associate", "learn"];
        assert_eq!(all_strs, expected);
    }

    #[test]
    fn adjective_as_str_wire_conformance() {
        assert_eq!(Adjective::State.as_str(),         "state");
        assert_eq!(Adjective::Trust.as_str(),         "trust");
        assert_eq!(Adjective::Sensitivity.as_str(),   "sensitivity");
        assert_eq!(Adjective::Exportability.as_str(), "exportability");
        // Ensure ALL is complete.
        assert_eq!(Adjective::ALL.len(), 4);
        let all_strs: Vec<&str> = Adjective::ALL.iter().map(|a| a.as_str()).collect();
        let expected = ["state", "trust", "sensitivity", "exportability"];
        assert_eq!(all_strs, expected);
    }

    #[test]
    fn serde_flow_wire_strings() {
        assert_eq!(serde_json::to_string(&Flow::CallerDriven).unwrap(), "\"callerDriven\"");
        assert_eq!(serde_json::to_string(&Flow::SubstrateDriven).unwrap(), "\"substrateDriven\"");
        assert_eq!(serde_json::to_string(&Flow::GroundingDriven).unwrap(), "\"groundingDriven\"");
        let rt: Flow = serde_json::from_str("\"callerDriven\"").unwrap();
        assert_eq!(rt, Flow::CallerDriven);
    }

    #[test]
    fn serde_noun_role_wire_strings() {
        assert_eq!(serde_json::to_string(&NounRole::Primary).unwrap(), "\"primary\"");
        assert_eq!(serde_json::to_string(&NounRole::Rung).unwrap(), "\"rung\"");
        assert_eq!(serde_json::to_string(&NounRole::Structure).unwrap(), "\"structure\"");
        assert_eq!(serde_json::to_string(&NounRole::Product).unwrap(), "\"product\"");
        let rt: NounRole = serde_json::from_str("\"rung\"").unwrap();
        assert_eq!(rt, NounRole::Rung);
    }
}
