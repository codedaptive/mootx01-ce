//! The cross-encoder contract: the packaged profile round-trips column-style,
//! the provider pair scorer keeps span order across batch boundaries and
//! refuses a seam that returns the wrong count or a non-finite logit, and
//! the rerank directive round-trips with the shared key names.
//!
//! Failure modes: a batch boundary that drops or reorders spans (the stage
//! would fuse a logit against the wrong candidate), a NaN that survives into
//! fusion, a serialised key that disagrees with the Swift twin.

use std::sync::{Arc, Mutex};

use corpus_kit::encoder::{
    CrossEncoderProfile, EncoderError, EncoderModelSpec, PairInference, PairScorer,
    ProviderPairScorer, RerankAction, RerankDirective,
};

/// Records every (query, span batch) the fake seam receives and returns a
/// logit derived from the span text so two spans differ.
struct FakePairInference {
    /// Shared with the test so the batches stay inspectable after the
    /// seam is boxed into the scorer.
    batches: Arc<Mutex<Vec<(String, Vec<String>)>>>,
    /// When set, every batch returns this many logits regardless of input.
    forced_count: Option<usize>,
    /// When set, the logit at this pair index (within a batch) is NaN.
    poison_index: Option<usize>,
}

impl FakePairInference {
    fn new() -> Self {
        Self { batches: Arc::new(Mutex::new(Vec::new())), forced_count: None, poison_index: None }
    }
}

impl PairInference for FakePairInference {
    fn backend(&self) -> &str {
        "fake"
    }

    fn logits(&self, query: &str, spans: &[&str]) -> Result<Vec<f32>, EncoderError> {
        self.batches
            .lock()
            .unwrap()
            .push((query.to_string(), spans.iter().map(|s| s.to_string()).collect()));
        let count = self.forced_count.unwrap_or(spans.len());
        Ok((0..count)
            .map(|i| {
                if Some(i) == self.poison_index {
                    return f32::NAN;
                }
                let span = spans.get(i).copied().unwrap_or("");
                span.len() as f32 - query.len() as f32 / 10.0
            })
            .collect())
    }
}

#[test]
fn qualified_profile_carries_the_lab_values() {
    let p = CrossEncoderProfile::minilm_l6();
    assert_eq!(p.model_id, "ms-marco-minilm-l6-cross-v1");
    assert_eq!(p.model_version, "233902d2");
    assert_eq!(p.tokenizer_hash, EncoderModelSpec::floor().tokenizer_hash);
    assert_eq!((p.max_sequence, p.pool, p.head, p.spans, p.rrf_k), (512, 50, 30, 3, 60));
}

#[test]
fn artifact_name_is_the_pascal_cased_model_id() {
    assert_eq!(CrossEncoderProfile::minilm_l6().artifact_name(), "MsMarcoMinilmL6CrossV1");
}

#[test]
fn profile_serialises_column_style_and_round_trips() {
    let json = serde_json::to_string(&CrossEncoderProfile::minilm_l6()).unwrap();
    assert!(json.contains("\"model_id\":\"ms-marco-minilm-l6-cross-v1\""));
    assert!(json.contains("\"rrf_k\":60"));
    assert!(json.contains("\"max_sequence\":512"));
    let back: CrossEncoderProfile = serde_json::from_str(&json).unwrap();
    assert_eq!(back, CrossEncoderProfile::minilm_l6());
}

#[test]
fn one_logit_per_span_order_kept_across_batches_same_query() {
    let scorer =
        ProviderPairScorer::new(CrossEncoderProfile::minilm_l6(), Box::new(FakePairInference::new()), 2);
    let spans = ["a", "bb", "ccc", "dddd", "eeeee"];
    assert_eq!(scorer.backend(), "fake");
    let logits = scorer.score("q", &spans).expect("score");
    assert_eq!(logits.len(), spans.len());
    let expected: Vec<f32> = spans.iter().map(|s| s.len() as f32 - 0.1).collect();
    assert_eq!(logits, expected);
}

#[test]
fn batches_are_chunked_with_the_same_query() {
    let seam = FakePairInference::new();
    let batches = Arc::clone(&seam.batches);
    let scorer = ProviderPairScorer::new(CrossEncoderProfile::minilm_l6(), Box::new(seam), 2);
    scorer.score("q", &["a", "bb", "ccc", "dddd", "eeeee"]).expect("score");
    let seen = batches.lock().unwrap();
    let texts: Vec<Vec<String>> = seen.iter().map(|b| b.1.clone()).collect();
    assert_eq!(texts, vec![vec!["a", "bb"], vec!["ccc", "dddd"], vec!["eeeee"]]);
    assert!(seen.iter().all(|b| b.0 == "q"));
}

#[test]
fn empty_span_list_returns_empty_without_touching_the_seam() {
    let seam = FakePairInference { forced_count: Some(3), ..FakePairInference::new() };
    let scorer = ProviderPairScorer::new(CrossEncoderProfile::minilm_l6(), Box::new(seam), 8);
    // A forced count of 3 would fail the count check if the seam were called.
    assert_eq!(scorer.score("q", &[]).expect("score"), Vec::<f32>::new());
}

#[test]
fn batch_size_below_one_acts_as_one() {
    let scorer =
        ProviderPairScorer::new(CrossEncoderProfile::minilm_l6(), Box::new(FakePairInference::new()), 0);
    assert_eq!(scorer.batch_size(), 1);
}

#[test]
fn wrong_count_is_inference_failed() {
    let seam = FakePairInference { forced_count: Some(1), ..FakePairInference::new() };
    let scorer = ProviderPairScorer::new(CrossEncoderProfile::minilm_l6(), Box::new(seam), 8);
    match scorer.score("q", &["a", "b"]) {
        Err(EncoderError::InferenceFailed(m)) => assert!(m.contains("1 logits for 2 pairs"), "{m}"),
        other => panic!("expected InferenceFailed, got {other:?}"),
    }
}

#[test]
fn non_finite_logit_is_inference_failed_and_names_the_pair() {
    let seam = FakePairInference { poison_index: Some(1), ..FakePairInference::new() };
    let scorer = ProviderPairScorer::new(CrossEncoderProfile::minilm_l6(), Box::new(seam), 8);
    match scorer.score("q", &["a", "b", "c"]) {
        Err(EncoderError::InferenceFailed(m)) => assert!(m.contains("non-finite logit at pair 1"), "{m}"),
        other => panic!("expected InferenceFailed, got {other:?}"),
    }
}

#[test]
fn directive_factories_name_the_qualified_profile() {
    assert_eq!(
        RerankDirective::apply(None),
        RerankDirective {
            action: RerankAction::Apply,
            profile_id: "ms-marco-minilm-l6-cross-v1".into(),
            reason: None
        }
    );
    assert_eq!(RerankDirective::bypass(Some("lab")).reason.as_deref(), Some("lab"));
}

#[test]
fn directive_serialises_with_shared_keys_and_round_trips() {
    let json = serde_json::to_string(&RerankDirective::apply(Some("explicit"))).unwrap();
    assert_eq!(
        json,
        "{\"action\":\"apply\",\"profile_id\":\"ms-marco-minilm-l6-cross-v1\",\"reason\":\"explicit\"}"
    );
    let back: RerankDirective = serde_json::from_str(&json).unwrap();
    assert_eq!(back, RerankDirective::apply(Some("explicit")));
    // A reason-less directive serialises without the key, the shape the
    // Swift twin decodes.
    assert_eq!(
        serde_json::to_string(&RerankDirective::bypass(None)).unwrap(),
        "{\"action\":\"bypass\",\"profile_id\":\"ms-marco-minilm-l6-cross-v1\"}"
    );
}
