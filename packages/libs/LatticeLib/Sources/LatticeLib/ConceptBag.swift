// ConceptBag.swift
//
// FDC encoder Steps 1–3 (cookbook §2–§4): turn a block of text into a
// weighted concept bag. This is the shared front end for both the runtime
// encoder and the build-time signature producer (cookbook §7 runs it over a
// code's label / title / article texts).
//
//   Step 1  tag — keep Noun/Verb tokens (WordClassTagger), plus any token that
//           resolves to a Wikidata Q-ID concept (cookbook §3.2 relaxation:
//           recovers named entities the POS tagger drops, decided from the
//           pinned lexicon so it stays deterministic across platforms).
//   Step 2  canonicalize — normalize + Porter2-stem each kept token, then look
//           it up in the pinned lexicon: a hit contributes its conceptID, a
//           miss contributes the surface form as its own key.
//   Step 3  accumulate — count occurrences. (Steps 2 and 3 are one pass.)
//
// Deterministic and pure given a fixed lexicon and word-class table.

import Foundation

/// A weighted concept bag: `conceptID | surfaceForm -> count`. Keys are
/// Wikidata Q-IDs / `wn:` IDs when the token resolves in the lexicon, else the
/// bare stemmed surface form (which scores only against a signature carrying
/// the same string — cookbook §3.2 step 4).
public typealias ConceptBag = [String: Int]

public enum BagBuilder {

    /// Build the concept bag for `text` against the pinned `lexicon`
    /// (cookbook §2–§4). `keepClasses` is the set of word classes Step 1
    /// retains; the encoder keeps nouns and verbs.
    ///
    /// Novel tokens (absent from the static word-class table) are classified
    /// via the platform default: Apple uses `NLTagger`; non-Apple uses the
    /// deterministic HMM. Use the `taggerChoice:` overload to specify the
    /// tagger explicitly from the estate's `EstateConfiguration.novelTokenTagger`.
    public static func bag(
        _ text: String,
        lexicon: CanonicalizationLexicon,
        keep keepClasses: Set<WordClass> = [.noun, .verb]
    ) -> ConceptBag {
        var bag: ConceptBag = [:]
        for token in Tokenizer.tokenize(text) {
            // Step 2: canonicalize (normalize + stem), then lexicon lookup.
            let key = Stemmer.stem(Normalizer.normalize(token))
            guard !key.isEmpty else { continue }
            let concept = lexicon.entries[key]          // nil if not in the lexicon
            // Step 1 (relaxed — cookbook §3.2): keep nouns/verbs, OR any token
            // that resolves to a Wikidata Q-ID concept. The Q-ID path recovers
            // named entities the POS tagger mislabels/drops, and it decides
            // membership from the PINNED lexicon (deterministic, identical
            // build+runtime) rather than fragile cross-platform proper-noun
            // tagging — so it adds coverage without risking the agreement property.
            let isQID = concept?.hasPrefix("Q") ?? false
            guard keepClasses.contains(LatticeLib.wordClass(token)) || isQID else { continue }
            // Step 3: accumulate (hit -> conceptID; miss kept via POS -> surface).
            bag[concept ?? key, default: 0] += 1
        }
        return bag
    }

    /// Build the concept bag for `text` with an explicit novel-token tagger
    /// choice threaded from the estate's configuration.
    ///
    /// Identical to `bag(_:lexicon:keep:)` except novel tokens (table misses)
    /// are classified by the specified `taggerChoice` rather than the platform
    /// default. Thread this from `EstateConfiguration.novelTokenTagger` (bridged
    /// from `PersistenceKit.NovelTokenTaggerChoice` to `LatticeLib.NovelTokenTaggerChoice`)
    /// to ensure the concept bag is built consistently with the estate's indexed
    /// content.
    ///
    /// - Parameters:
    ///   - text: raw input text to encode.
    ///   - lexicon: pinned canonicalization lexicon for Step 2.
    ///   - keepClasses: word classes Step 1 retains (default: nouns + verbs).
    ///   - taggerChoice: which novel-token tagger to invoke on a table miss.
    /// - Returns: the weighted concept bag.
    public static func bag(
        _ text: String,
        lexicon: CanonicalizationLexicon,
        keep keepClasses: Set<WordClass> = [.noun, .verb],
        taggerChoice: NovelTokenTaggerChoice
    ) -> ConceptBag {
        var bag: ConceptBag = [:]
        for token in Tokenizer.tokenize(text) {
            let key = Stemmer.stem(Normalizer.normalize(token))
            guard !key.isEmpty else { continue }
            let concept = lexicon.entries[key]
            let isQID = concept?.hasPrefix("Q") ?? false
            // Use the estate-specified tagger choice for novel-token classification.
            guard keepClasses.contains(LatticeLib.wordClass(token, tagger: taggerChoice)) || isQID else { continue }
            bag[concept ?? key, default: 0] += 1
        }
        return bag
    }
}
