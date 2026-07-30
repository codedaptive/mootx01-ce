// Wave-2 consolidation sweep + vague recall — Rust twin of the Swift
// ConsolidationCycleTests acceptance set (SPEC_CONSOLIDATION_VAGUE_RECALL):
// the act (with AC-5 surface), idempotence, D5 minimum, D3 quiet gate,
// AC-3 K/M bounds, §5.1 fold-in, §5.2 defrag.
//
// Determinism mirrors the Swift suite: capture at NOW; sweep with an
// injected now 91 days later so the D1/D2 gate passes; trace ABSENCE
// satisfies D3 (the ratified semantics).

use std::sync::Arc;

use genius_locus_kit::brain::consolidation_cycle::ConsolidationConfig;
use genius_locus_kit::EstateCoordinator;
use locus_kit::drawer_operational::{CaptureChannel, DrawerFeatureFlags};
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::CaptureFrame;
use locus_kit::recall_trace_item::RecallTraceItem;
use corpus_kit::{CorpusContentEngine, EmbeddingModelConfig};
use persistence_kit::inmemory::InMemoryStorage;
use uuid::Uuid;
use vectorkit::vector_store::VectorStore;

const NOW: i64 = 1_700_000_000;
const DAY: i64 = 86_400;

const CLUSTER_BODIES: [&str; 4] = [
    "Project Falcon deadline moved to March. Falcon deploy target is the staging cluster. Maria owns the Falcon rollout checklist.",
    "Project Falcon deadline moved to March. Falcon deploy target is the staging cluster. Maria owns the Falcon rollout checklist now.",
    "Project Falcon deadline moved to March again. Falcon deploy target is the staging cluster. Maria owns the Falcon rollout checklist.",
    "Project Falcon deadline moved to March. Falcon deploy target remains the staging cluster. Maria owns the Falcon rollout checklist.",
];
const DISTINCT_BODIES: [&str; 2] = [
    "Grandmother's lasagna recipe uses fresh basil. The oven runs hot at 400 degrees. Sunday dinners start at six.",
    "The telescope needs a new focuser knob. Jupiter rises after midnight this week. Collimation drifts in cold air.",
];

fn open_one() -> (EstateCoordinator, genius_locus_kit::EstateHandle) {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::with_storage(storage, NOW, None).unwrap());
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(store, OwnerCredentials::new("owner-consolidation-tests"), 0, 100)
        .expect("open estate");
    let vs_storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let vector_store = Arc::new(VectorStore::open(vs_storage).expect("VectorStore::open"));
    coord.register_vector_store(&handle, vector_store);
    // Corpus registration: the defrag path expunges the vague item, and the
    // cross-kit vector delete needs the corpus model id (production shape).
    let c_storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let corpus = Arc::new(
        CorpusContentEngine::standalone_on(c_storage, vec![EmbeddingModelConfig::Deterministic])
            .expect("Corpus::open"),
    );
    coord.register_corpus(&handle, corpus);
    (coord, handle)
}

fn capture_at(
    coord: &EstateCoordinator,
    handle: &genius_locus_kit::EstateHandle,
    body: &str,
    at: i64,
) -> String {
    let frame = CaptureFrame::new(
        body,
        CaptureChannel::Typed,
        "inbox",
        LatticeAnchor::udc("000"),
        "test-consolidation",
        "test-model-v1",
    );
    coord.capture(handle, frame, at).expect("capture").id
}

/// Capture the fixture corpus, distill (fingerprints), sweep 91 days later.
fn consolidated_estate() -> (
    EstateCoordinator,
    genius_locus_kit::EstateHandle,
    Vec<String>,
    i64,
    usize,
) {
    let (coord, handle) = open_one();
    let mut cluster_ids = Vec::new();
    for (i, body) in CLUSTER_BODIES.iter().enumerate() {
        cluster_ids.push(capture_at(&coord, &handle, body, NOW + i as i64));
    }
    for (i, body) in DISTINCT_BODIES.iter().enumerate() {
        let _ = capture_at(&coord, &handle, body, NOW + 100 + i as i64);
    }
    coord
        .distill_items_sweep(&handle, NOW, None)
        .expect("distill sweep");
    let aged = NOW + 91 * DAY;
    let produced = coord
        .consolidation_sweep(&handle, aged, &ConsolidationConfig::default(), None)
        .expect("consolidation sweep");
    (coord, handle, cluster_ids, aged, produced)
}

#[test]
fn sweep_consolidates_cluster_and_marks_constituents() {
    let (coord, handle, cluster_ids, _aged, produced) = consolidated_estate();
    assert_eq!(produced, 1, "exactly the one similar cluster consolidates");

    // AC-5 surface: constituents remain fetchable, non-vague, bit-21 marked.
    for cid in &cluster_ids {
        let ids: Vec<&str> = vec![cid.as_str()];
        let rows = coord
            .get_drawers(&handle, &ids)
            .expect("get drawers");
        let d = rows.first().expect("constituent row present");
        assert_ne!(d.operational_bitmap & DrawerFeatureFlags::REPRESENTED_BY_VAGUE, 0);
        assert_eq!(d.operational_bitmap & DrawerFeatureFlags::IS_VAGUE, 0);
        assert!(!d.content.is_empty());
    }
}

#[test]
fn sweep_is_idempotent() {
    let (coord, handle, _ids, aged, produced) = consolidated_estate();
    assert_eq!(produced, 1);
    let second = coord
        .consolidation_sweep(&handle, aged + 3_600, &ConsolidationConfig::default(), None)
        .expect("second sweep");
    assert_eq!(second, 0, "re-running the sweep must not re-consolidate");
}

#[test]
fn d5_minimum_cluster_size_holds() {
    let (coord, handle) = open_one();
    for (i, body) in CLUSTER_BODIES[..2].iter().enumerate() {
        let _ = capture_at(&coord, &handle, body, NOW + i as i64);
    }
    for (i, body) in DISTINCT_BODIES.iter().enumerate() {
        let _ = capture_at(&coord, &handle, body, NOW + 100 + i as i64);
    }
    coord.distill_items_sweep(&handle, NOW, None).expect("distill");
    let produced = coord
        .consolidation_sweep(&handle, NOW + 91 * DAY, &ConsolidationConfig::default(), None)
        .expect("sweep");
    assert_eq!(produced, 0);
}

#[test]
fn d3_recent_recall_blocks_consolidation() {
    let (coord, handle) = open_one();
    let mut ids = Vec::new();
    for (i, body) in CLUSTER_BODIES.iter().enumerate() {
        ids.push(capture_at(&coord, &handle, body, NOW + i as i64));
    }
    coord.distill_items_sweep(&handle, NOW, None).expect("distill");
    let aged = NOW + 91 * DAY;
    // Two hot members drop the 4-cluster below D5 (one would leave 3,
    // which correctly still consolidates) — twin of the Swift arithmetic.
    let mk = |target: &String, at: i64| RecallTraceItem {
        id: Uuid::new_v4().to_string(),
        target: target.clone(),
        recalled_at: iso(at),
        score: None,
        operational_bitmap: 0,
    };
    coord
        .insert_recall_traces(&handle, &[mk(&ids[0], aged - DAY), mk(&ids[1], aged - DAY / 2)])
        .expect("seed traces");
    let produced = coord
        .consolidation_sweep(&handle, aged, &ConsolidationConfig::default(), None)
        .expect("sweep");
    assert_eq!(produced, 0, "two hot members shrink the cluster below D5");
}

#[test]
fn ac3_vague_recall_bounded_by_k_and_m() {
    let (coord, handle, cluster_ids, _aged, produced) = consolidated_estate();
    assert_eq!(produced, 1);

    let full = coord
        .vague_recall(&handle, "Project Falcon rollout checklist", 8, 8, 32)
        .expect("vague recall");
    assert_eq!(full.vague_hits.len(), 1);
    assert!(full
        .vague_hits
        .iter()
        .all(|d| (d.operational_bitmap & DrawerFeatureFlags::IS_VAGUE) != 0));
    let got: std::collections::BTreeSet<&str> =
        full.constituents.iter().map(|d| d.id.as_str()).collect();
    let want: std::collections::BTreeSet<&str> =
        cluster_ids.iter().map(|s| s.as_str()).collect();
    assert_eq!(got, want, "hop 2 hydrates the full constituent set");

    let k_bound = coord
        .vague_recall(&handle, "Project Falcon rollout checklist", 8, 2, 32)
        .expect("k bound");
    assert_eq!(k_bound.constituents.len(), 2);

    let m_bound = coord
        .vague_recall(&handle, "Project Falcon rollout checklist", 8, 8, 1)
        .expect("m bound");
    assert_eq!(m_bound.constituents.len(), 1);
}

#[test]
fn fold_in_enlarges_the_vague_lineage() {
    let (coord, handle, cluster_ids, aged, produced) = consolidated_estate();
    assert_eq!(produced, 1);

    let fifth = capture_at(
        &coord,
        &handle,
        "Project Falcon deadline moved to March. Falcon deploy target is the staging cluster. Maria still owns the Falcon rollout checklist.",
        NOW + 200,
    );
    coord
        .distill_items_sweep(&handle, aged + 3_600, None)
        .expect("distill fifth");

    // Explicit D4 ceiling (configured wins — the ratified alternative to the
    // per-sweep derivation), mirroring the Swift test: the combined-distillate
    // fingerprint sits ~59 bits from a member's per-item fingerprint on this
    // fixture in BOTH ports (word segmentation is space-only with empties
    // dropped in both twins — see SubstrateML distillation_pipeline.rs
    // default_extractor), while unrelated items sit near the ~128-bit random
    // expectation. 90 pins the fold MECHANICS with margin AND fails if the
    // ports' combined renderings ever diverge again.
    let mut config = ConsolidationConfig::default();
    config.hamming_ceiling = Some(90);
    let report = coord
        .consolidation_sweep_report(&handle, aged + 92 * DAY, &config, None)
        .expect("fold sweep");
    assert_eq!(report.fold_ins, 1, "the neighbor folds into the vague item");

    let v2 = coord
        .vague_recall(&handle, "Project Falcon rollout checklist", 8, 8, 32)
        .expect("recall v2");
    assert_eq!(v2.vague_hits.len(), 1, "exactly one ACTIVE vague version");
    let got: std::collections::BTreeSet<&str> =
        v2.constituents.iter().map(|d| d.id.as_str()).collect();
    let mut want: Vec<&str> = cluster_ids.iter().map(|s| s.as_str()).collect();
    want.push(fifth.as_str());
    let want: std::collections::BTreeSet<&str> = want.into_iter().collect();
    assert_eq!(got, want, "the enlarged constituent set hydrates");
}

#[test]
fn defrag_recomposes_without_orphans() {
    let (coord, handle, cluster_ids, aged, produced) = consolidated_estate();
    assert_eq!(produced, 1);
    let hit = coord
        .vague_recall(&handle, "Project Falcon rollout checklist", 8, 8, 32)
        .expect("hit");
    let vague_id = hit.vague_hits.first().expect("vague hit").id.clone();

    let report = coord
        .defrag_vague_item(&handle, &vague_id, aged + DAY, &ConsolidationConfig::default())
        .expect("defrag");
    assert_eq!(report.new_vague_items, 1, "the reverted pool re-consolidates");

    let rebuilt = coord
        .vague_recall(&handle, "Project Falcon rollout checklist", 8, 8, 32)
        .expect("rebuilt");
    assert_eq!(rebuilt.vague_hits.len(), 1);
    assert_ne!(rebuilt.vague_hits[0].id, vague_id, "drifted vague item expunged");
    let got: std::collections::BTreeSet<&str> =
        rebuilt.constituents.iter().map(|d| d.id.as_str()).collect();
    let want: std::collections::BTreeSet<&str> =
        cluster_ids.iter().map(|s| s.as_str()).collect();
    assert_eq!(got, want, "constituents represented by the rebuilt item");
}

/// Local ISO helper for trace seeding (matches the coordinator's format).
fn iso(epoch_secs: i64) -> String {
    let secs = epoch_secs.max(0) as u64;
    let s = secs % 60;
    let m = (secs / 60) % 60;
    let h = (secs / 3600) % 24;
    let days = secs / 86400;
    let z = days + 719468;
    let era = z / 146097;
    let doe = z % 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mo = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if mo <= 2 { y + 1 } else { y };
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{m:02}:{s:02}Z")
}
