// redistill_convergence_tests.rs — Rust twin of RedistillConvergenceTests.swift
//
// The product distiller is ContextDistillLib's intent-span v23.2 converter,
// keyed by converter ID and source digest.
//  - end-to-end: the Debug-7 oracle originals distill to the oracle
//    representation under the current converter ID; the forced sweep rewrites
//    every row; the full derived-lane reindex succeeds.
//  - trailer parity (REPORTED, not gated): the regenerated enrichment trailer
//    versus the trailer the artifact estates stored under p2.3, over the
//    locomo-272 oracle rows.
//  - currency: a row stamped with the v22 converter id regenerates on the next
//    sweep and comes back stamped v23.2 with the digest of its content; a row
//    whose digest disagrees with its content regenerates; a row with the
//    active id and the matching digest is left alone; identical source gives
//    identical bytes and an identical digest.

use std::path::PathBuf;
use std::sync::Arc;

use corpus_kit::{
    CorpusContentConfiguration, CorpusContentEngine, CorpusIndexUnitPolicy, CorpusOperatingMode,
    EmbeddingModelConfig,
};
use context_distill_lib::digest::source_digest;
use genius_locus_kit::brain::distillation_cycle::{distilled_representation, distilled_token_count};
use genius_locus_kit::brain::enrichment_stage::enrichment_trailer;
use genius_locus_kit::intake::LocusDrawerContentSource;
use genius_locus_kit::{distilled_representation_is_current, EstateCoordinator};
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
        "Vectors", &format!("{bed}-intent-span-v23-attributed.jsonl"),
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
        assert_eq!(d.distilled_source_digest.as_deref(), Some(source_digest(&row.original).as_str()));
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

/// Open an estate whose corpus source is backed by the same drawer store
/// (matching the production `wireSubstores` path). `reindex_corpus` can
/// therefore create corpus index state rows for every active drawer.
fn open_estate_with_drawer_corpus() -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::with_storage(storage, NOW, None).unwrap());
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(store, OwnerCredentials::new("owner-redistill-drawer-corpus"), 0, 100)
        .expect("open estate");
    let vs_storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let vector_store = Arc::new(VectorStore::open(vs_storage).expect("VectorStore::open"));
    coord.register_vector_store(&handle, vector_store);
    // Attach a corpus whose source reads directly from the drawer store, so
    // `reindex_corpus` creates CorpusIndexState rows keyed by drawer ID.
    let estate = coord.estate_for(&handle).expect("estate_for").clone();
    let source: Arc<dyn corpus_kit::CorpusContentSource> =
        Arc::new(LocusDrawerContentSource::new(estate));
    let c_storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let corpus = Arc::new(
        CorpusContentEngine::open(
            c_storage,
            CorpusContentConfiguration::new(
                CorpusOperatingMode::Attached,
                CorpusIndexUnitPolicy::WholeContent,
            )
            .expect("CorpusContentConfiguration::new"),
            source,
            vec![EmbeddingModelConfig::Deterministic],
        )
        .expect("CorpusContentEngine::open"),
    );
    coord.register_corpus(&handle, corpus);
    (coord, handle)
}

/// Open a LocusOnly estate (no corpus, no vector store registered).
fn open_locus_only_estate() -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::with_storage(storage, NOW, None).unwrap());
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(store, OwnerCredentials::new("owner-redistill-locus-only"), 0, 100)
        .expect("open estate");
    // No corpus and no vector store registered — LocusOnly.
    (coord, handle)
}

// MARK: - awaiting-reindex

#[test]
fn sweep_and_reindex_leaves_zero_awaiting() {
    // Use the drawer-backed corpus so reindex_corpus actually creates index
    // state rows keyed by drawer ID — matching the production path.
    let (coord, handle) = open_estate_with_drawer_corpus();
    capture(&coord, &handle, "alpha content");
    capture(&coord, &handle, "beta content");

    // Sweep — both drawers get a representation at NOW.
    let regenerated = coord.distill_items_sweep(&handle, NOW, None).expect("sweep");
    assert!(regenerated >= 2, "expected >= 2 regenerated, got {regenerated}");

    // Reindex at NOW — index rows get updated_at_millis == NOW == distilled_at,
    // so strict `<` is false and no drawer counts as awaiting.
    coord.reindex_corpus(&handle, NOW).expect("reindex_corpus");
    let awaiting = coord
        .distilled_representations_awaiting_reindex(&handle)
        .expect("awaiting_reindex");
    assert_eq!(awaiting, 0, "full sweep+reindex must leave awaiting == 0");
}

#[test]
fn sweep_without_reindex_leaves_drawers_awaiting() {
    // Crash-scenario simulation: sweep commits, reindex does not run. Use the
    // drawer-backed corpus so that after the reindex the index rows exist and
    // the awaiting count correctly drops to zero.
    let (coord, handle) = open_estate_with_drawer_corpus();
    let filed = 3usize;
    for i in 0..filed {
        capture(&coord, &handle, &format!("crash content {i}"));
    }

    // Sweep sets distilled_at on all drawers — but we do NOT call reindex_corpus.
    let regenerated = coord.distill_items_sweep(&handle, NOW, None).expect("sweep");
    assert!(regenerated >= filed, "expected >= {filed} regenerated, got {regenerated}");

    // No index rows exist, so every represented drawer is awaiting.
    let awaiting = coord
        .distilled_representations_awaiting_reindex(&handle)
        .expect("awaiting_reindex after sweep only");
    assert!(awaiting >= filed, "expected >= {filed} awaiting, got {awaiting}");

    // After reindex the gap closes.
    coord.reindex_corpus(&handle, NOW).expect("reindex_corpus");
    let after_reindex = coord
        .distilled_representations_awaiting_reindex(&handle)
        .expect("awaiting_reindex after reindex");
    assert_eq!(after_reindex, 0, "awaiting must be 0 after reindex");
}

#[test]
fn drawer_with_no_index_row_counts_as_awaiting() {
    let (coord, handle) = open_estate();
    capture(&coord, &handle, "singleton content");
    coord.distill_items_sweep(&handle, NOW, None).expect("sweep");
    // No reindex — no index rows. At least one represented drawer has no index entry.
    let awaiting = coord
        .distilled_representations_awaiting_reindex(&handle)
        .expect("awaiting_reindex");
    assert!(awaiting >= 1, "expected >= 1 awaiting (no index rows), got {awaiting}");
}

#[test]
fn locus_only_estate_returns_zero_awaiting() {
    // No corpus registered — function returns 0 immediately.
    let (coord, handle) = open_locus_only_estate();
    let awaiting = coord
        .distilled_representations_awaiting_reindex(&handle)
        .expect("awaiting_reindex");
    assert_eq!(awaiting, 0, "LocusOnly estate must return 0 (no corpus to check)");
}


// MARK: - currency

/// The converter id v22 rows carry: the library's previous ruleset, kept in
/// the library and never routed to by the product.
const V22_CONVERTER_ID: &str = "intent-span@intent-span-v22-authority-closure";

#[test]
fn active_converter_is_v23_attributed() {
    assert_eq!(
        genius_locus_kit::DISTILLATION_CONVERTER,
        context_distill_lib::converter::ContextDistillConverter::IntentSpanV23Attributed
    );
    assert_eq!(
        genius_locus_kit::distillation_converter_id(),
        "intent-span-v23-attributed@intent-span-v23.2-attributed-prose"
    );
    assert_ne!(genius_locus_kit::distillation_converter_id(), V22_CONVERTER_ID);
}

/// Stamp one row exactly as a v22-era build wrote it: the v22 converter id
/// beside the digest of the content it distilled.
fn stamp_v22(coord: &EstateCoordinator, handle: &genius_locus_kit::handle::EstateHandle, id: &str, content: &str) {
    let estate = coord.estate_for(handle).expect("estate");
    let written = estate
        .set_distilled_representation(
            id,
            &format!("v22 rendering of {id}"),
            V22_CONVERTER_ID,
            &source_digest(content),
            3,
            NOW,
        )
        .expect("stamp v22");
    assert_eq!(written, 1);
}

fn drawer(coord: &EstateCoordinator, handle: &genius_locus_kit::handle::EstateHandle, id: &str) -> locus_kit::drawer::Drawer {
    coord
        .get_drawers(handle, &[id])
        .expect("get_drawers")
        .into_iter()
        .next()
        .expect("row")
}

#[test]
fn converter_bump_forces_regeneration() {
    let (coord, handle) = open_estate_with_drawer_corpus();
    let alpha = "alpha content that the v22 converter once distilled";
    let beta = "beta content that the v22 converter once distilled";
    let alpha_id = capture(&coord, &handle, alpha);
    let beta_id = capture(&coord, &handle, beta);
    // Settle the estate under the active converter.
    coord.distill_items_sweep(&handle, NOW, None).expect("sweep");
    coord.reindex_corpus(&handle, NOW).expect("reindex");
    assert_eq!(coord.distill_items_sweep(&handle, NOW, None).expect("sweep"), 0);

    // Rewind the two filed rows to the v22 converter.
    stamp_v22(&coord, &handle, &alpha_id, alpha);
    stamp_v22(&coord, &handle, &beta_id, beta);
    let estate = coord.estate_for(&handle).expect("estate");
    assert_eq!(estate.count_undistilled(genius_locus_kit::distillation_converter_id()).expect("count"), 2);
    assert!(!distilled_representation_is_current(&drawer(&coord, &handle, &alpha_id)));
    assert!(!distilled_representation_is_current(&drawer(&coord, &handle, &beta_id)));

    // The sweep regenerates exactly those two rows. Rooms that carry bit 19
    // for every row are entered because the stale-room projection names them.
    let later = NOW + 1_000;
    assert_eq!(coord.distill_items_sweep(&handle, later, None).expect("sweep"), 2);
    for (id, content) in [(&alpha_id, alpha), (&beta_id, beta)] {
        let row = drawer(&coord, &handle, id);
        assert_eq!(row.distilled_pipeline_version.as_deref(), Some(genius_locus_kit::distillation_converter_id()));
        assert_eq!(row.distilled_source_digest.as_deref(), Some(source_digest(content).as_str()));
        assert_eq!(row.distilled.as_deref(), Some(distilled_representation(content).as_str()));
        assert!(distilled_representation_is_current(&row));
    }
    assert_eq!(estate.count_undistilled(genius_locus_kit::distillation_converter_id()).expect("count"), 0);

    // The regenerated rows postdate their index rows until the reindex runs.
    assert!(coord.distilled_representations_awaiting_reindex(&handle).expect("awaiting") >= 2);
    coord.reindex_corpus(&handle, later).expect("reindex");
    assert_eq!(coord.distilled_representations_awaiting_reindex(&handle).expect("awaiting"), 0);
}

#[test]
fn converter_bump_is_not_hidden_by_a_fully_represented_room_after_reopen() {
    // Rust twin of the Swift "stale pipeline version hidden by bit 19" case:
    // after a reopen, rebuild_all tightens the room's operational AND so bit
    // 19 reads 1 for a fully represented room, and the sweep would skip the
    // room on the bit alone. The stale-room projection names the room, so
    // the v22 row inside it still regenerates.
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::with_storage(storage, NOW, None).unwrap());
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(Arc::clone(&store), OwnerCredentials::new("owner-reopen"), 0, 100)
        .expect("open estate");
    let alpha = "alpha content whose room reads fully represented after reopen";
    let alpha_id = capture(&coord, &handle, alpha);
    assert_eq!(coord.distill_items_sweep(&handle, NOW, None).expect("sweep"), 1);
    stamp_v22(&coord, &handle, &alpha_id, alpha);

    // Reopen on the same store: rebuild_all recomputes the room AND from
    // scratch, and every drawer in the room carries bit 19.
    let mut coord2 = EstateCoordinator::new();
    let handle2 = coord2
        .open(Arc::clone(&store), OwnerCredentials::new("owner-reopen"), 0, 100)
        .expect("reopen estate");
    let estate2 = coord2.estate_for(&handle2).expect("estate");
    let skip_bit = locus_kit::drawer_operational::DrawerFeatureFlags::HAS_CURRENT_REPRESENTATION;
    let entries = estate2.room_level_fingerprints().expect("room fingerprints");
    let room = entries
        .iter()
        .find(|e| e.room == "redistill-convergence-tests")
        .expect("the capture room has a fingerprint entry");
    assert_eq!(room.fingerprint.operational_and & skip_bit, skip_bit, "bit 19 must read 1 for the room after reopen");
    let stale = estate2
        .rooms_with_stale_distilled_representations(genius_locus_kit::distillation_converter_id())
        .expect("stale rooms");
    assert!(stale.contains(&(room.wing.clone(), room.room.clone())), "the stale-room projection must name the room: {stale:?}");

    // The sweep enters the room through the projection and regenerates the row.
    assert_eq!(coord2.distill_items_sweep(&handle2, NOW + 1_000, None).expect("sweep"), 1);
    let row = drawer(&coord2, &handle2, &alpha_id);
    assert_eq!(row.distilled_pipeline_version.as_deref(), Some(genius_locus_kit::distillation_converter_id()));
    assert_eq!(row.distilled_source_digest.as_deref(), Some(source_digest(alpha).as_str()));
    assert!(distilled_representation_is_current(&row));
    // And a converged room is skipped again on the next pass.
    assert_eq!(coord2.distill_items_sweep(&handle2, NOW + 2_000, None).expect("sweep"), 0);
}

#[test]
fn digest_mismatch_regenerates() {
    let (coord, handle) = open_estate();
    let alpha = "alpha content whose digest will be replaced";
    let alpha_id = capture(&coord, &handle, alpha);
    coord.distill_items_sweep(&handle, NOW, None).expect("sweep");

    let estate = coord.estate_for(&handle).expect("estate");
    estate
        .set_distilled_representation(
            &alpha_id,
            "rendering of other content",
            genius_locus_kit::distillation_converter_id(),
            &source_digest("other content"),
            4,
            NOW,
        )
        .expect("stamp mismatched digest");
    assert!(!distilled_representation_is_current(&drawer(&coord, &handle, &alpha_id)));

    assert_eq!(coord.distill_items_sweep(&handle, NOW + 1_000, None).expect("sweep"), 1);
    let row = drawer(&coord, &handle, &alpha_id);
    assert_eq!(row.distilled_source_digest.as_deref(), Some(source_digest(alpha).as_str()));
    assert_eq!(row.distilled.as_deref(), Some(distilled_representation(alpha).as_str()));
    assert!(distilled_representation_is_current(&row));
}

#[test]
fn matching_id_and_digest_is_left_alone() {
    let (coord, handle) = open_estate();
    let alpha = "alpha content that stays as written";
    let alpha_id = capture(&coord, &handle, alpha);
    coord.distill_items_sweep(&handle, NOW, None).expect("sweep");

    // A hand-written representation that satisfies the rule exactly.
    let estate = coord.estate_for(&handle).expect("estate");
    estate
        .set_distilled_representation(
            &alpha_id,
            "hand-written but current",
            genius_locus_kit::distillation_converter_id(),
            &source_digest(alpha),
            4,
            NOW,
        )
        .expect("stamp current");
    assert!(distilled_representation_is_current(&drawer(&coord, &handle, &alpha_id)));

    assert_eq!(coord.distill_items_sweep(&handle, NOW + 1_000, None).expect("sweep"), 0);
    let row = drawer(&coord, &handle, &alpha_id);
    assert_eq!(row.distilled.as_deref(), Some("hand-written but current"));
    assert_eq!(row.distilled_at, Some(NOW));
}

#[test]
fn same_source_twice_is_byte_identical() {
    let gamma = "gamma content distilled twice must store the same bytes";
    // Pure function level: same content, same converter, same bytes.
    let first = distilled_representation(gamma);
    let second = distilled_representation(gamma);
    assert_eq!(first, second);
    assert_eq!(source_digest(gamma), source_digest(gamma));

    // Stored level: two forced distillations of one row store the same text
    // and the same digest.
    let (coord, handle) = open_estate();
    let gamma_id = capture(&coord, &handle, gamma);
    assert_eq!(coord.redistill_items_sweep(&handle, NOW, None).expect("redistill"), 1);
    let one = drawer(&coord, &handle, &gamma_id);
    assert_eq!(coord.redistill_items_sweep(&handle, NOW + 1_000, None).expect("redistill"), 1);
    let two = drawer(&coord, &handle, &gamma_id);
    assert_eq!(one.distilled, two.distilled);
    assert_eq!(one.distilled.as_deref(), Some(first.as_str()));
    assert_eq!(one.distilled_source_digest, two.distilled_source_digest);
    assert_eq!(one.distilled_source_digest.as_deref(), Some(source_digest(gamma).as_str()));
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
