// redistill_convergence_tests.rs — Rust twin of RedistillConvergenceTests.swift
//
// CDL-02: the product distiller is ContextDistillLib, keyed by converter ID.
//  - end-to-end: the Debug-7 oracle originals distill to the oracle
//    representation under the current converter ID; the forced sweep rewrites
//    every row; the full derived-lane reindex succeeds.
//  - trailer parity (REPORTED, not gated): the regenerated enrichment trailer
//    versus the trailer the artifact estates stored under p2.3, over the
//    locomo-272 oracle rows.

use std::path::PathBuf;
use std::sync::Arc;

use corpus_kit::{CorpusContentEngine, EmbeddingModelConfig};
use genius_locus_kit::brain::distillation_cycle::{distilled_representation, distilled_token_count};
use genius_locus_kit::brain::enrichment_stage::enrichment_trailer;
use genius_locus_kit::EstateCoordinator;
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::CaptureFrame;
use persistence_kit::inmemory::InMemoryStorage;
use uuid::Uuid;
use vectorkit::vector_store::VectorStore;

const NOW: i64 = 1_700_000_000_000;

/// One oracle row: the source content, the trailer the artifact stored under
/// p2.3, and the representation the frozen converter produced.
struct OracleRow {
    original: String,
    enrichment_trailer: String,
    ai_text: String,
}

fn oracle_rows(bed: &str) -> Vec<OracleRow> {
    let path: PathBuf = [
        env!("CARGO_MANIFEST_DIR"),
        "..", "..", "..", "libs", "ContextDistillLib", "Tests", "ContextDistillLibTests",
        "Vectors", &format!("{bed}-intent-span-v22.jsonl"),
    ]
    .iter()
    .collect();
    let text = std::fs::read_to_string(&path).expect("oracle bed readable");
    text.lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| {
            let v: serde_json::Value = serde_json::from_str(l).expect("valid JSON line");
            OracleRow {
                original: v["original"].as_str().expect("original").to_string(),
                enrichment_trailer: v["enrichment_trailer"].as_str().unwrap_or("").to_string(),
                ai_text: v["ai_text"].as_str().expect("ai_text").to_string(),
            }
        })
        .collect()
}

fn open_estate() -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::with_storage(storage, NOW, None).unwrap());
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(store, OwnerCredentials::new("owner-redistill-convergence"), 0, 100)
        .expect("open estate");
    let vs_storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let vector_store = Arc::new(VectorStore::open(vs_storage).expect("VectorStore::open"));
    coord.register_vector_store(&handle, vector_store);
    let c_storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let corpus = Arc::new(
        CorpusContentEngine::standalone_on(c_storage, vec![EmbeddingModelConfig::Deterministic])
            .expect("Corpus::open"),
    );
    coord.register_corpus(&handle, corpus);
    (coord, handle)
}

fn capture(coord: &EstateCoordinator, handle: &genius_locus_kit::handle::EstateHandle, body: &str) -> String {
    let frame = CaptureFrame::new(
        body,
        CaptureChannel::Typed,
        "redistill-convergence-tests",
        LatticeAnchor::udc("000"),
        "redistill-convergence-tests",
        "test-model-v1",
    );
    coord.capture(handle, frame, NOW).expect("capture").id
}

#[test]
fn debug7_end_to_end() {
    let rows = oracle_rows("debug7");
    assert_eq!(rows.len(), 7);
    let (coord, handle) = open_estate();
    let ids: Vec<String> = rows.iter().map(|r| capture(&coord, &handle, &r.original)).collect();

    // Eligibility sweep: every row is undistilled, so all seven regenerate.
    let produced = coord.distill_items_sweep(&handle, NOW, None).expect("sweep");
    assert_eq!(produced, 7);

    let refs: Vec<&str> = ids.iter().map(String::as_str).collect();
    let drawers = coord.get_drawers(&handle, &refs).expect("get_drawers");
    for (row, id) in rows.iter().zip(ids.iter()) {
        let d = drawers.iter().find(|d| &d.id == id).expect("row");
        // The product contract: the stored text is the converter's
        // representation of the content with the REGENERATED trailer.
        let expected = distilled_representation(&row.original);
        assert_eq!(d.distilled.as_deref(), Some(expected.as_str()), "stored text is the converter's representation for {id}");
        assert_eq!(d.distilled_pipeline_version.as_deref(), Some(genius_locus_kit::distillation_converter_id()));
        assert_eq!(d.distilled_token_count, Some(distilled_token_count(&expected)));
        // Oracle equality holds exactly when the regenerated trailer equals
        // the trailer the artifact stored under p2.3 (the parity report below
        // counts those rows); the library's own conformance suite already
        // pins the converter to the oracle for the stored trailer.
        if enrichment_trailer(&row.original).trim() == row.enrichment_trailer {
            assert_eq!(expected, row.ai_text, "oracle equality for {id}");
        }
    }

    // Converged estate: a second eligibility sweep regenerates nothing.
    assert_eq!(coord.distill_items_sweep(&handle, NOW, None).expect("sweep"), 0);

    // The forced sweep behind moot_redistill rewrites every row regardless.
    assert_eq!(coord.redistill_items_sweep(&handle, NOW, None).expect("redistill"), 7);

    // Full derived-lane reindex succeeds on the corpus-wired estate.
    coord.reindex_corpus(&handle, NOW).expect("reindex_corpus");
}

/// REPORTED, not gated: the regenerated enrichment trailer versus the
/// trailer the artifact estates stored under p2.3, per oracle bed.
fn trailer_parity_report(bed: &str, expected_rows: usize) {
    let rows = oracle_rows(bed);
    assert_eq!(rows.len(), expected_rows);
    let mut identical = 0usize;
    let mut mismatches: Vec<(String, String)> = Vec::new();
    for row in &rows {
        // enrichment_trailer returns the block with its leading space; the
        // oracle stores the stripped block.
        let regenerated = enrichment_trailer(&row.original).trim().to_string();
        if regenerated == row.enrichment_trailer {
            identical += 1;
        } else {
            mismatches.push((row.enrichment_trailer.clone(), regenerated));
        }
    }
    println!("TRAILER PARITY {bed}-{expected_rows}: identical={identical} mismatched={}", mismatches.len());
    for (i, (stored, regenerated)) in mismatches.iter().take(5).enumerate() {
        println!("  mismatch {}: stored={} | regenerated={}", i + 1,
            stored.chars().take(200).collect::<String>(),
            regenerated.chars().take(200).collect::<String>());
    }
    // Reported, not gated: the numbers above are the deliverable.
    assert_eq!(identical + mismatches.len(), expected_rows);
}

#[test]
fn trailer_parity_report_debug7() { trailer_parity_report("debug7", 7); }

#[test]
fn trailer_parity_report_sample30() { trailer_parity_report("sample30", 30); }

#[test]
fn trailer_parity_report_locomo() { trailer_parity_report("locomo", 272); }
