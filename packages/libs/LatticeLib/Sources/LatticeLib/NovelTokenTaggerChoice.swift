// NovelTokenTaggerChoice.swift
//
// LatticeLib-scoped novel-token tagger selection enum. Mirrors the
// identically-named type in PersistenceKit (which carries it on
// `EstateConfiguration`). Because PersistenceKit is upstream of LatticeLib
// in the dependency topology, the two packages define this enum independently
// with case-for-case semantics. A consumer bridging the two (e.g.
// GeniusLocusKit) maps between them with a trivial switch.
//
// Thread the `NovelTokenTaggerChoice` from the estate's
// `EstateConfiguration.novelTokenTagger` to the call sites
// `LatticeLib.wordClass(_:tagger:)` and `BagBuilder.bag(_:lexicon:keep:taggerChoice:)`
// via parameter (never via global or thread-local state).

import Foundation

/// Novel-token tagger to apply when a token is absent from the static
/// word-class table.
///
/// Select once at estate creation time. The value lives on
/// `PersistenceKit.EstateConfiguration.novelTokenTagger`; callers bridge
/// it to this type when invoking LatticeLib's tagging API.
public enum NovelTokenTaggerChoice: Sendable, Hashable {
    /// Deterministic HMM/Viterbi tagger — the default and cross-port baseline.
    ///
    /// Byte-identical to the Rust port. Safe for all platforms and federatable
    /// with non-Apple estates. This is the correct choice unless Apple-only
    /// higher accuracy on novel tokens is explicitly required and federation
    /// with non-Apple estates is known to be unnecessary.
    case hmm

    /// Apple NaturalLanguage `NLTagger` — available on Apple platforms only.
    ///
    /// When this choice is active and `NaturalLanguage` is available, novel
    /// tokens are classified by `NLTagger` with `.lexicalClass`. The result
    /// is platform-specific (not cross-platform deterministic, not federable
    /// with HMM estates). On non-Apple builds this case is not reachable
    /// at the tagger-dispatch level (`tagNovelToken(_:tagger:)` treats it as
    /// HMM because NaturalLanguage is absent); callers are responsible for not
    /// constructing this value on non-Apple platforms (PersistenceKit enforces
    /// this at estate-configuration validation on Rust).
    case nlTagger
}
