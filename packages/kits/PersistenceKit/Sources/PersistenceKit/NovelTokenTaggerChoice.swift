// NovelTokenTaggerChoice.swift
//
// Estate-creation-time selection of the novel-token tagger (Layer-2a,
// Decision 1 / v1.0). This choice is fixed at estate creation and cannot
// be changed on an existing estate (change-after-creation is v1.1).
//
// Design notes:
//   - HMM is the default and the cross-port conformance baseline.
//     The HMM tagger is deterministic, integer-scored, and byte-identical
//     between the Swift and Rust ports (shared test vectors).
//   - NLTagger is an Apple-only advanced option that uses Apple's
//     NaturalLanguage framework. It typically produces higher accuracy
//     for English novel tokens on Apple hardware, but it is NOT available
//     outside the Apple ecosystem and its output is NOT cross-platform
//     deterministic. An estate tagged with NLTagger cannot be federated
//     with an HMM-tagged estate without re-tagging all content —
//     federation enforcement is v1.1; this field documents the constraint.
//
// Federation constraint (v1.1 enforcement):
//   An estate created with `.nlTagger` produces novel-token classifications
//   that differ from `.hmm` estates. Federating (syncing rows between)
//   an NLTagger estate and an HMM estate will produce term-set mismatches
//   that corrupt concept-bag recall. The federation enforcement check
//   (refusing to sync incompatible estates) is out of scope for v1.0 and
//   will be added in v1.1. Until then: advanced users who select `.nlTagger`
//   must not federate that estate with non-Apple or HMM-configured estates.
//
// Rust: the `NovelTokenTaggerChoice` enum exists in `persistence-kit` with
// identical case semantics. `NlTagger` is an invalid selection on Rust
// (no NaturalLanguage framework available) — `EstateConfiguration::new_with_tagger`
// returns an error when called with `NovelTokenTaggerChoice::NlTagger` on Rust.

import Foundation

/// The novel-token tagger to use for this estate.
///
/// Selected at estate creation time. Cannot be changed after creation
/// (that is a v1.1 feature with re-tagging migration support).
///
/// ``hmm`` is the default and the correct choice for all cross-platform and
/// federated deployments. ``nlTagger`` is an Apple-only advanced opt-in for
/// single-device estates where federation with non-Apple estates is not required.
public enum NovelTokenTaggerChoice: Sendable, Hashable, Codable {
    /// Deterministic HMM/Viterbi tagger — the default and cross-port baseline.
    ///
    /// An integer-scored 3-state Hidden Markov Model that produces bit-identical
    /// results on every platform (Swift and Rust, Apple and non-Apple). Novel
    /// tokens not found in the static word-class table are classified by the HMM.
    /// This is the safe, federable choice.
    case hmm

    /// Apple NaturalLanguage `NLTagger` — an advanced Apple-only opt-in.
    ///
    /// Uses Apple's `NLTagger` with `.lexicalClass` for novel-token classification.
    /// Typically higher accuracy than the HMM for English on Apple hardware.
    ///
    /// CONSTRAINTS (read before selecting):
    ///   1. Apple-only. This option is invalid on Rust / non-Apple platforms
    ///      (no `NaturalLanguage` framework). Code that creates an estate with
    ///      this option on a non-Apple host will receive a compile-time or
    ///      runtime error (depending on the path).
    ///   2. Not cross-platform deterministic. NLTagger output varies by OS
    ///      version and is not expected to match the HMM.
    ///   3. Federation-incompatible. An NLTagger-tagged estate CANNOT be
    ///      safely federated with an HMM-tagged estate without full content
    ///      re-tagging. Federation enforcement is v1.1; until then, the
    ///      caller is responsible for not mixing estate types in a sync group.
    case nlTagger
}

extension NovelTokenTaggerChoice {
    /// The cross-port default: HMM is available everywhere, deterministic,
    /// and the baseline for all conformance tests.
    public static let `default`: NovelTokenTaggerChoice = .hmm
}
