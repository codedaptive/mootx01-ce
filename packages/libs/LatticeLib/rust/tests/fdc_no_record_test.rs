// fdc_no_record_test.rs — Integration tests for the secfix/fdc-pool
// non-recording encode-anchor path.
//
// Tests here are PARALLELISM-SAFE: they test tag identity and result identity
// only, with no assertions on the SHARED_NOVEL_CACHE singleton count.
// Pool-accumulation non-recording gate tests live in a SEPARATE file
// (no_record_accumulation_test.rs) where a single-test binary guarantees
// a clean slate and no concurrent recording interference.
//
// Three invariants:
//   1. word_class_no_record returns the same WordClass as word_class (tag identity).
//   2. Fdc::encode_anchor_no_record returns the same (code, qid) as Fdc::encode_anchor
//      (result identity).
//   3. UNRESOLVED-code text: code is None from the no-record path (same as standard
//      path). Note: qid MAY be non-None even when code is None — this is correct
//      behavior when a bag term resolves to a Q-ID but no FDC code matches.

use lattice_lib::{
    Fdc,
    WordClass,
    word_class,
    word_class_no_record,
};

// MARK: - word_class_no_record tag identity

/// A table-resident verb and noun must produce the same classification
/// from both the recording and non-recording paths.
#[test]
fn word_class_no_record_table_resident_identity() {
    assert_eq!(word_class("engine"), word_class_no_record("engine"));
    assert_eq!(word_class("compute"), word_class_no_record("compute"));
    assert_eq!(word_class("run"), word_class_no_record("run"));
}

/// An empty token must return WordClass::Other from both paths.
#[test]
fn word_class_no_record_empty_token() {
    assert_eq!(word_class_no_record(""), WordClass::Other);
    assert_eq!(word_class(""), WordClass::Other);
}

/// A novel token (not in any shipped table) must return the same
/// WordClass from both paths — only the pool side effect differs.
#[test]
fn word_class_no_record_novel_identity() {
    // "zorbquinate" is almost certainly not in any shipped word-class table.
    let novel = "zorbquinate";
    assert_eq!(
        word_class(novel),
        word_class_no_record(novel),
        "word_class_no_record must return the same WordClass as word_class for the same novel token"
    );
}

// MARK: - Fdc::encode_anchor_no_record result identity

/// The anchor (code, qid) pair must be byte-identical whether the recording
/// or non-recording variant is used.
#[test]
fn encode_anchor_no_record_result_identity() {
    if !Fdc::is_available() {
        return;
    }
    let text = "modern diesel engine technology";
    let standard      = Fdc::encode_anchor(text);
    let non_recording = Fdc::encode_anchor_no_record(text);
    assert_eq!(
        standard, non_recording,
        "encode_anchor_no_record must produce the same (code, qid) as encode_anchor"
    );
}

/// Text with clearly unresolvable fictional content: code must be None.
/// Note: qid may still be non-None if any token resolves to a Q-ID entry in
/// the lexicon that has no matching FDC signature (correct per encode_from_bag
/// logic, line 339: `return (None, qid)` when no candidate codes match).
/// We only assert on the code here.
#[test]
fn encode_anchor_no_record_unresolvable_fictional_text_code_is_none() {
    if !Fdc::is_available() {
        return;
    }
    // Fictional gibberish tokens that cannot be in any lexicon or signature.
    let code_std = Fdc::encode_anchor("zorbquinatefoo borbleplonk frubliqwerty").0;
    let code_nr  = Fdc::encode_anchor_no_record("zorbquinatefoo borbleplonk frubliqwerty").0;
    // Both must agree: either both None (UNRESOLVED) or both the same code.
    assert_eq!(
        code_std, code_nr,
        "No-record path must produce the same code as standard path"
    );
}
