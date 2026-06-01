// ConceptBag.swift
//
// FDC encoder Steps 1–3 (cookbook §2–§4): turn a block of text into a
// weighted concept bag. This is the shared front end for both the runtime
// encoder and the build-time signature producer (cookbook §7 runs it over a
// code's label / title / article texts).
//
//   Step 1  tag — keep only Noun/Verb tokens (WordClassTagger).
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
    public static func bag(
        _ text: String,
        lexicon: CanonicalizationLexicon,
        keep keepClasses: Set<WordClass> = [.noun, .verb]
    ) -> ConceptBag {
        var bag: ConceptBag = [:]
        for token in Tokenizer.tokenize(text) {
            // Step 1: tag; keep only the requested classes.
            guard keepClasses.contains(LatticeLib.wordClass(token)) else { continue }
            // Step 2: canonicalize (normalize + stem), then lexicon lookup.
            let key = Stemmer.stem(Normalizer.normalize(token))
            guard !key.isEmpty else { continue }
            let concept = lexicon.entries[key] ?? key   // hit -> conceptID; miss -> surface
            // Step 3: accumulate.
            bag[concept, default: 0] += 1
        }
        return bag
    }
}
