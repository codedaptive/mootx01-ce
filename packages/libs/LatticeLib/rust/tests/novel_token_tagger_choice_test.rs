// novel_token_tagger_choice_test.rs — Layer-2a: NovelTokenTaggerChoice in LatticeLib Rust
//
// Verifies:
//   (a) NovelTokenTaggerChoice::default() is Hmm
//   (b) word_class_with_tagger(Hmm) on a novel -tion token → Noun
//   (c) word_class_with_tagger(NlTagger) on Rust falls back to HMM
//   (d) build_bag_with_tagger(Hmm) on a novel noun token produces a non-empty bag
//   (e) build_bag_with_tagger determinism: same input, same output
//   (f) HMM conformance regression: tag vectors still pass (regression guard)

use lattice_lib::{
    NovelTokenTaggerChoice,
    WordClass,
    build_bag_with_tagger,
    global_table,
};
use lattice_lib::lexicon::CanonicalizationLexicon;

// (a) NovelTokenTaggerChoice::default() is Hmm.
#[test]
fn novel_token_tagger_choice_default_is_hmm() {
    assert_eq!(NovelTokenTaggerChoice::default(), NovelTokenTaggerChoice::Hmm);
}

// (b) word_class_with_tagger(.Hmm) on a novel -tion token classifies as Noun.
// "xylophonation" is not in the bundled table; trained model -tion emission:
//   noun -3091, verb -7466. With noun-prior -1480 vs verb-prior -1884:
//   noun total -4571, verb total -9350, other total -10853. Noun wins.
#[test]
fn hmm_choice_novel_tion_token_is_noun() {
    let table = global_table();
    let result = table.word_class_with_tagger("xylophonation", NovelTokenTaggerChoice::Hmm);
    assert_eq!(
        result,
        WordClass::Noun,
        "HMM should classify -tion novel token as Noun"
    );
}

// (c) word_class_with_tagger(.NlTagger) on Rust falls back to HMM — same result.
// On Rust there is no NaturalLanguage framework, so NlTagger and Hmm must agree.
#[test]
fn nl_tagger_choice_falls_back_to_hmm_on_rust() {
    let table = global_table();
    let hmm_result = table.word_class_with_tagger("xylophonation", NovelTokenTaggerChoice::Hmm);
    let nlt_result = table.word_class_with_tagger("xylophonation", NovelTokenTaggerChoice::NlTagger);
    assert_eq!(
        hmm_result, nlt_result,
        "NlTagger must fall back to HMM on Rust (no NaturalLanguage); both must agree"
    );
}

// (d) build_bag_with_tagger(.Hmm) on a novel noun token produces a non-empty bag.
// "xylophonation" → stem → some form → noun per HMM → included in bag.
#[test]
fn build_bag_with_tagger_hmm_includes_novel_noun() {
    let table = global_table();
    let lexicon = CanonicalizationLexicon { version: "test".to_owned(), language: "en".to_owned(), entries: std::collections::HashMap::new() };
    let bag = build_bag_with_tagger(
        "xylophonation",
        &lexicon,
        &table,
        &[WordClass::Noun, WordClass::Verb],
        NovelTokenTaggerChoice::Hmm,
    );
    assert!(!bag.is_empty(), "Novel noun via HMM should appear in bag");
}

// (e) build_bag_with_tagger(.Hmm) is deterministic.
#[test]
fn build_bag_with_tagger_hmm_is_deterministic() {
    let table = global_table();
    let lexicon = CanonicalizationLexicon { version: "test".to_owned(), language: "en".to_owned(), entries: std::collections::HashMap::new() };
    let bag1 = build_bag_with_tagger(
        "xylophonation",
        &lexicon,
        &table,
        &[WordClass::Noun, WordClass::Verb],
        NovelTokenTaggerChoice::Hmm,
    );
    let bag2 = build_bag_with_tagger(
        "xylophonation",
        &lexicon,
        &table,
        &[WordClass::Noun, WordClass::Verb],
        NovelTokenTaggerChoice::Hmm,
    );
    assert_eq!(bag1, bag2, "build_bag_with_tagger(Hmm) must be deterministic");
}

// (f) HMM conformance regression: the -ing suffix → Verb path still works.
// This mirrors the HMM cross-port conformance tested by tag_conformance.json.
#[test]
fn hmm_conformance_regression_ing_is_verb() {
    let table = global_table();
    let result = table.word_class_with_tagger("zorbilating", NovelTokenTaggerChoice::Hmm);
    assert_eq!(result, WordClass::Verb, "HMM -ing suffix should classify as Verb");
}

// (g) HMM conformance regression: empty token → Other.
#[test]
fn hmm_conformance_regression_empty_is_other() {
    let table = global_table();
    let result = table.word_class_with_tagger("", NovelTokenTaggerChoice::Hmm);
    assert_eq!(result, WordClass::Other, "empty token must be Other");
}
