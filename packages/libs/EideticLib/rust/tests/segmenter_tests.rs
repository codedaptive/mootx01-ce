//! Tests for `eidetic_lib::segmenter::sentences`. Mirror the
//! Swift `SegmenterTests` cases that exercise the delimiter
//! reference path (Swift's `sentencesByDelimiter`); the routed
//! Apple entry has no Rust equivalent today.

use eidetic_lib::segmenter::sentences;

#[test]
fn empty_input_returns_empty() {
    assert!(sentences("").is_empty());
}

#[test]
fn single_sentence_no_terminator_returns_full_input() {
    let text = "this is one fragment with no terminator";
    let segs = sentences(text);
    assert_eq!(segs.len(), 1);
    assert_eq!(segs[0], text);
}

#[test]
fn splits_on_period_exclaim_question() {
    let segs = sentences("First. Second! Third? Fourth");
    assert_eq!(segs, vec![
        "First.".to_string(),
        " Second!".to_string(),
        " Third?".to_string(),
        " Fourth".to_string(),
    ]);
}

#[test]
fn splits_on_newline() {
    let segs = sentences("Line one\nLine two\nLine three");
    assert_eq!(segs.len(), 3);
    assert!(segs[0].ends_with('\n'));
    assert!(segs[1].ends_with('\n'));
    assert!(!segs[2].ends_with('\n'));
}

#[test]
fn total_coverage_round_trip() {
    let text = "Alpha. Beta! Gamma? Delta\nEpsilon";
    let segs = sentences(text);
    let rejoined: String = segs.join("");
    assert_eq!(rejoined, text);
}

#[test]
fn input_of_only_terminators_yields_covering_segments() {
    let segs = sentences("...");
    assert_eq!(segs, vec![".".to_string(), ".".to_string(), ".".to_string()]);
}

#[test]
fn matches_swift_canonical_reference_on_simple_input() {
    // Mirror of the Swift `testRoutedAndReferenceAgreeOnSimpleInput`
    // case. Pure delimiter behavior on unambiguous input.
    let text = "One sentence. Two sentences. Three sentences.";
    let segs = sentences(text);
    assert_eq!(segs.len(), 3);
    let rejoined: String = segs.join("");
    assert_eq!(rejoined, text);
}
