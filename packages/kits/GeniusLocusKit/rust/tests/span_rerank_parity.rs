//! Cross-port pin for the span rerank stage (Encoder Rerank Program, contract
//! sheet §8/§10/§11). Reads the shared fixture
//! SynapseKit/Tests/Fixtures/encoder/span_rerank_parity.json (also asserted by
//! GeniusLocusKit's SpanRerankParityTests.swift): 50 dim-8 span rows over 20
//! items, 20 unit query vectors, one BM25 head of 30 items (10 without span
//! rows) and the fused order per query. Failure mode: a port dequantises the
//! int8 rows differently, picks a different best span on a tie, or sorts the
//! RRF ties differently.

use std::collections::HashMap;
use std::path::PathBuf;

use genius_locus_kit::span_rerank::{
    fuse, span_rerank, SpanRerankEncoding, SpanRerankError, SpanRerankInput, SpanRerankVector,
    SpanVectorReading,
};

/// The fixture's rows, keyed by item — a stand-in for SynapseKit's span rows.
struct FixtureRows {
    rows: HashMap<String, Vec<SpanRerankVector>>,
}

impl SpanVectorReading for FixtureRows {
    fn span_vectors(
        &self,
        item_ids: &[String],
        _model_id: &str,
    ) -> Result<HashMap<String, Vec<SpanRerankVector>>, SpanRerankError> {
        Ok(self
            .rows
            .iter()
            .filter(|(id, _)| item_ids.contains(id))
            .map(|(id, rows)| (id.clone(), rows.clone()))
            .collect())
    }
}

/// An encoder whose query vector is the fixture's (the model is out of the loop).
struct FixtureEncoder {
    model_id: String,
    vector: Vec<f32>,
}

impl SpanRerankEncoding for FixtureEncoder {
    fn model_id(&self) -> &str {
        &self.model_id
    }
    fn encode_query(&self, _text: &str) -> Result<Vec<f32>, SpanRerankError> {
        Ok(self.vector.clone())
    }
}

fn f32_at(v: &serde_json::Value, key: &str) -> f32 {
    v[key].as_f64().unwrap_or_else(|| panic!("{key} must be a number")) as f32
}

#[test]
fn every_query_reproduces_the_fixture_order_and_best_spans() {
    // CARGO_MANIFEST_DIR is GeniusLocusKit/rust/; the fixture is shared with
    // the Swift twin under SynapseKit/Tests/Fixtures/encoder/.
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../SynapseKit/Tests/Fixtures/encoder/span_rerank_parity.json");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    let fixture: serde_json::Value = serde_json::from_str(&text).expect("fixture is JSON");

    let model_id = fixture["model_id"].as_str().expect("model_id").to_string();
    let span_weight = f32_at(&fixture, "span_weight");
    let mut rows: HashMap<String, Vec<SpanRerankVector>> = HashMap::new();
    for span in fixture["span_vectors"].as_array().expect("span_vectors") {
        let int8: Vec<i8> = span["int8"]
            .as_array()
            .expect("int8")
            .iter()
            .map(|v| v.as_i64().expect("int8 entry") as i8)
            .collect();
        rows.entry(span["item_id"].as_str().expect("item_id").to_string())
            .or_default()
            .push(SpanRerankVector {
                index: span["index"].as_u64().expect("index") as u32,
                int8,
                scale: f32_at(span, "scale"),
                start_word: span["start_word"].as_u64().expect("start_word") as usize,
                end_word: span["end_word"].as_u64().expect("end_word") as usize,
            });
    }
    let store = FixtureRows { rows: rows.clone() };
    let head_ids: Vec<String> = fixture["bm25_head"]
        .as_array()
        .expect("bm25_head")
        .iter()
        .map(|v| v.as_str().expect("head id").to_string())
        .collect();
    let head: Vec<SpanRerankInput> = head_ids
        .iter()
        .enumerate()
        .map(|(i, id)| SpanRerankInput { item_id: id.clone(), bm25_rank: i + 1 })
        .collect();
    let queries = fixture["query_vectors"].as_array().expect("query_vectors");
    let expected = fixture["expected_orders"].as_array().expect("expected_orders");
    assert_eq!(queries.len(), expected.len());

    for (qi, (query, want)) in queries.iter().zip(expected).enumerate() {
        let vector: Vec<f32> = query["vector"]
            .as_array()
            .expect("vector")
            .iter()
            .map(|v| v.as_f64().expect("f") as f32)
            .collect();
        let encoder = FixtureEncoder { model_id: model_id.clone(), vector };
        let hits = span_rerank(&head, &format!("fixture query {qi}"), &encoder, &store).expect("rerank");
        let want_hits = want["hits"].as_array().expect("hits");
        let got_ids: Vec<&str> = hits.iter().map(|h| h.item_id.as_str()).collect();
        let want_ids: Vec<&str> = want_hits.iter().map(|h| h["item_id"].as_str().expect("id")).collect();
        assert_eq!(got_ids, want_ids, "query {qi}: span rank order");
        for (hit, w) in hits.iter().zip(want_hits) {
            assert_eq!(hit.best_span_index as u64, w["best_span_index"].as_u64().expect("idx"), "query {qi} {}", hit.item_id);
            let want_cos = f32_at(w, "cosine");
            assert!((hit.cosine - want_cos).abs() < 1e-4, "query {qi} {}: cosine {} vs {want_cos}", hit.item_id, hit.cosine);
        }
        let fused = fuse(&head_ids, &hits, span_weight);
        let got_order: Vec<&str> = fused.iter().map(|e| e.id.as_str()).collect();
        let want_order: Vec<&str> = want["order"].as_array().expect("order").iter().map(|v| v.as_str().expect("id")).collect();
        assert_eq!(got_order, want_order, "query {qi}: fused order");
        // Items without span rows keep no hit; items with rows carry theirs.
        for entry in &fused {
            assert_eq!(entry.hit.is_some(), rows.contains_key(&entry.id), "query {qi} {}: hit presence", entry.id);
        }
    }
}
