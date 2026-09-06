//! Pins `corpus_kit::encoder::spanner::spans` to the shared cross-port
//! fixture `SynapseKit/Tests/Fixtures/encoder/spanner_vectors.json` (the
//! Swift leg reads the SAME file in Tests/CorpusKitTests/SpannerFixtureTests.swift).
//!
//! Failure modes: an off-by-one at the tail, a longest-first reordering, or
//! a cap that lets more than `max_spans` spans through.

use std::path::PathBuf;

use corpus_kit::encoder::spanner;
use serde::Deserialize;

#[derive(Deserialize)]
struct Fixture {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    word_count: usize,
    window_words: usize,
    overlap_divisor: usize,
    max_spans: usize,
    spans: Vec<[usize; 2]>,
}

fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../SynapseKit/Tests/Fixtures/encoder/spanner_vectors.json")
}

#[test]
fn every_fixture_case_reproduces_its_span_bounds() {
    let text = std::fs::read_to_string(fixture_path()).expect("read spanner_vectors.json");
    let fixture: Fixture = serde_json::from_str(&text).expect("parse spanner_vectors.json");
    // 10 word counts × 2 windows.
    assert_eq!(fixture.cases.len(), 20);
    for c in &fixture.cases {
        let got: Vec<[usize; 2]> =
            spanner::spans(c.word_count, c.window_words, c.overlap_divisor, c.max_spans)
                .into_iter()
                .map(|(s, e)| [s, e])
                .collect();
        assert_eq!(
            got, c.spans,
            "word_count={} window={}",
            c.word_count, c.window_words
        );
    }
}

#[test]
fn cap_widening_stays_under_max_spans_and_ends_at_word_count() {
    let mut word_count = 200;
    while word_count <= 6000 {
        let spans = spanner::spans(word_count, 60, 2, 32);
        assert!(spans.len() <= 32, "word_count={word_count}");
        assert!(spans.len() > 1);
        if word_count - 60 > 31 * 30 {
            assert_eq!(spans.last().unwrap().1, word_count, "word_count={word_count}");
        }
        for pair in spans.windows(2) {
            assert!(pair[0].0 < pair[1].0);
            assert_eq!(pair[0].1 - pair[0].0, 60);
        }
        word_count += 173;
    }
}

#[test]
fn words_is_the_product_keyword_split() {
    let text = "Hello, World! Painting in Brazil since 1999 — ok.";
    assert_eq!(spanner::words(text), corpus_kit::default_keyword_tokens(text));
    assert_eq!(
        spanner::words(text),
        ["hello", "world", "painting", "in", "brazil", "since", "1999", "ok"]
    );
}
