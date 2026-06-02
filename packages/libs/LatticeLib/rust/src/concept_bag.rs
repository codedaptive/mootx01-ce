// concept_bag.rs — FDC encoder Steps 1–3 (concept bag construction)
//
// Port of ConceptBag.swift and BagBuilder.
//
// Steps:
//   1  tag — keep Noun/Verb tokens via WordClassTableCache, plus any token that
//            resolves to a Wikidata Q-ID concept (§3.2 relaxation)
//   2  canonicalize — normalize + stem each kept token, then lexicon lookup:
//            hit -> conceptID, miss -> stemmed surface form
//   3  accumulate — count occurrences (Steps 2 and 3 are one pass)
//
// The §3.2 relaxation: `isQID = concept.starts_with("Q")`. When a token
// resolves to a Q-ID via the lexicon, it is kept regardless of word class.
// This recovers named entities the POS tagger may drop or mislabel.
//
// Deterministic and pure given a fixed lexicon and word-class table.

use std::collections::HashMap;
use crate::normalizer::normalize;
use crate::stemmer::stem;
use crate::tokenizer::tokenize;
use crate::lexicon::CanonicalizationLexicon;
use crate::word_class::WordClass;
use crate::word_class_table::WordClassTableCache;

/// A weighted concept bag: conceptID | surfaceForm -> count.
/// Keys are Q-IDs / wn: IDs when the token resolves in the lexicon, else the
/// bare stemmed surface form (which scores only against a signature carrying
/// the same string — cookbook §3.2 step 4).
pub type ConceptBag = HashMap<String, usize>;

/// Build the concept bag for `text` against the pinned lexicon and word-class table.
/// Mirrors `BagBuilder.bag` in Swift. `keep_classes` is the set of word classes
/// Step 1 retains; the encoder keeps nouns and verbs.
pub fn build_bag(
    text: &str,
    lexicon: &CanonicalizationLexicon,
    table: &WordClassTableCache,
    keep_classes: &[WordClass],
) -> ConceptBag {
    let mut bag: ConceptBag = HashMap::new();

    for token in tokenize(text) {
        // Step 2: canonicalize (normalize + stem), then lexicon lookup.
        let key = stem(&normalize(&token));
        if key.is_empty() {
            continue;
        }
        let concept: Option<&str> = lexicon.lookup(&key);

        // Step 1 (relaxed — cookbook §3.2): keep nouns/verbs, OR any token
        // that resolves to a Wikidata Q-ID concept. The Q-ID path recovers
        // named entities the POS tagger mislabels/drops, and it decides
        // membership from the PINNED lexicon (deterministic, identical
        // build+runtime) rather than fragile cross-platform proper-noun tagging.
        let is_qid = concept.map(|c| c.starts_with('Q')).unwrap_or(false);
        let wc = table.word_class(&token);
        if !keep_classes.contains(&wc) && !is_qid {
            continue;
        }

        // Step 3: accumulate (hit -> conceptID; miss kept via POS -> surface).
        let bag_key = concept.unwrap_or(&key).to_owned();
        *bag.entry(bag_key).or_insert(0) += 1;
    }

    bag
}

/// Convenience: build a bag with the default encoder keep classes (noun + verb).
pub fn build_encoder_bag(
    text: &str,
    lexicon: &CanonicalizationLexicon,
    table: &WordClassTableCache,
) -> ConceptBag {
    build_bag(text, lexicon, table, &[WordClass::Noun, WordClass::Verb])
}
