// expunge_partial_lineage.rs
//
// Honesty tests for a PARTIAL lineage expunge (MXE-FA). Rust mirror of
// Swift's ExpungePartialLineageTests.swift.
//
// The audit gate refuses `Accepted → Tombstoned` (S-3), so a lineage
// expunge that meets an accepted sibling scrubs only the admitted
// members. These tests pin the end-to-end consequences at the GLK layer:
//
//   P1 — The refused (accepted) sibling keeps BOTH its content and its
//        corpus index entries. Deleting the vector for a row whose content
//        survives would make the row unrecallable by search while still
//        readable by id — a third inconsistent state.
//   P2 — Scrubbed members lose both content and corpus entries, exactly
//        as a full expunge does.
//   P3 — The expunge verb returns the refusal to the caller: an expunge
//        that refused a sibling is not a success, and a layer that
//        summarises it as one is the defect.
//   P4 — A lineage with no accepted members expunges fully and reports
//        no refusals — the pre-existing contract is unchanged.

use std::sync::Arc;

use corpus_kit::{CorpusContentEngine, EmbeddingModelConfig};
use genius_locus_kit::EstateCoordinator;
use locus_kit::adjectives::{State, Trust};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::{CaptureFrame, MutationKind};
use persistence_kit::{
    inmemory::InMemoryStorage, BackendConfiguration, EstateConfiguration, Storage,
};

const NOW: i64 = 1_700_000_000;

fn make_storage() -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    Arc::new(InMemoryStorage::new(config))
}

fn open_one() -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("owner"), 0, 100)
        .expect("open");
    (coord, handle)
}

fn cap_frame(content: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "expunge-partial-tests",
        LatticeAnchor::udc("000"),
        "test-agent",
        "test-embed-v1",
    )
}

fn make_corpus() -> Arc<CorpusContentEngine> {
    let storage = make_storage();
    Arc::new(
        CorpusContentEngine::standalone_on(storage, vec![EmbeddingModelConfig::Deterministic])
            .expect("Corpus::open"),
    )
}

/// Capture an accepted head (D1) and an active sibling (D2) in the SAME
/// lineage. Order matters: D1 is promoted to Accepted BEFORE D2 is
/// captured — an accepted row is not an active predecessor, so the D2
/// capture does not supersede it (same recipe as the MXE-EZ
/// DrawerStore-layer tests). Trust=Canonical (raw 3) satisfies the S-1
/// accept guard.
fn seed_accepted_sibling_lineage(
    coord: &mut EstateCoordinator,
    h: &genius_locus_kit::handle::EstateHandle,
) -> (locus_kit::drawer::Drawer, locus_kit::drawer::Drawer) {
    let d1 = coord
        .capture(
            h,
            cap_frame("accepted ruthenium ledger entry kept verbatim for audit"),
            NOW,
        )
        .expect("capture d1");
    coord
        .mutate(h, &d1.id, MutationKind::CorrectTrust(Trust::Canonical), None)
        .expect("correct trust to canonical");
    coord
        .mutate(h, &d1.id, MutationKind::Accept, None)
        .expect("promote d1 to accepted");

    let mut d2_frame = cap_frame("active ruthenium draft note superseding nothing yet");
    d2_frame.lineage_id = Some(d1.lineage_id);
    let d2 = coord.capture(h, d2_frame, NOW + 100).expect("capture d2");
    (d1, d2)
}

/// True when the corpus recall index still returns `drawer_id` for `query`.
fn corpus_recalls(corpus: &CorpusContentEngine, query: &str, drawer_id: &str) -> bool {
    corpus
        .recall(query, 10)
        .expect("corpus recall")
        .iter()
        .any(|sc| sc.id == drawer_id)
}

// ---------------------------------------------------------------------------
// P1+P2+P3: refused sibling keeps content AND vector; scrubbed members lose
// both; the verb reports the refusal
// ---------------------------------------------------------------------------

#[test]
fn partial_expunge_preserves_accepted_sibling_content_and_vector() {
    let (mut coord, h) = open_one();
    let (d1, d2) = seed_accepted_sibling_lineage(&mut coord, &h);

    // Wire corpus; ingest both lineage members (drawer id = source_id, G4).
    let corpus = make_corpus();
    corpus.ingest(&d1.content, &d1.id, NOW).expect("ingest d1");
    corpus.ingest(&d2.content, &d2.id, NOW).expect("ingest d2");
    coord.register_corpus(&h, corpus.clone());

    // Sanity: both members are corpus-recallable before the expunge.
    assert!(
        corpus_recalls(&corpus, "ruthenium ledger audit", &d1.id),
        "accepted sibling must be corpus-recallable before expunge"
    );
    assert!(
        corpus_recalls(&corpus, "ruthenium draft note", &d2.id),
        "head must be corpus-recallable before expunge"
    );

    let d1_before = coord
        .estate_for(&h)
        .expect("estate")
        .drawer_by_id(&d1.id)
        .expect("read d1")
        .expect("d1 exists");

    // Expunge the head. The gate refuses the accepted sibling (S-3).
    // P3 — the verb returns the refusal instead of summarising the
    // partial expunge as a plain success.
    let outcome = coord
        .expunge(&h, &d2.id, "partial lineage expunge probe", true, NOW + 300)
        .expect("expunge");
    assert_eq!(
        outcome.refused_sibling_ids,
        vec![d1.id.clone()],
        "the verb must name exactly the refused accepted sibling"
    );

    let estate = coord.estate_for(&h).expect("estate");

    // P2 — the admitted head is scrubbed: content gone, corpus entry gone.
    let d2_after = estate
        .drawer_by_id(&d2.id)
        .expect("read d2")
        .expect("d2 row survives as a tombstone");
    assert_eq!(
        d2_after.adjective_bitmap & 0x3F,
        State::Tombstoned.raw_value(),
        "the expunge target must be tombstoned"
    );
    assert_eq!(d2_after.content, "", "the expunge target's content must be scrubbed");
    assert!(
        !corpus_recalls(&corpus, "ruthenium draft note", &d2.id),
        "the scrubbed head must no longer be corpus-recallable"
    );

    // P1 — the refused sibling is byte-identical AND still recallable.
    let d1_after = estate
        .drawer_by_id(&d1.id)
        .expect("read d1")
        .expect("d1 exists");
    assert_eq!(
        d1_after.adjective_bitmap & 0x3F,
        State::Accepted.raw_value(),
        "refused sibling state must remain Accepted"
    );
    assert_eq!(
        d1_after.content, d1_before.content,
        "refused sibling content must survive byte-identical"
    );
    assert_eq!(
        d1_after.adjective_bitmap, d1_before.adjective_bitmap,
        "refused sibling adjective bitmap must be untouched"
    );
    assert!(
        corpus_recalls(&corpus, "ruthenium ledger audit", &d1.id),
        "refused sibling must STILL be corpus-recallable: its content survives, \
         so deleting its vector would create a row readable by id but invisible \
         to search"
    );
}

// ---------------------------------------------------------------------------
// P4: a lineage with no accepted members is unchanged
// ---------------------------------------------------------------------------

#[test]
fn full_expunge_of_unprotected_lineage_scrubs_every_member() {
    let (mut coord, h) = open_one();

    let v1 = coord
        .capture(&h, cap_frame("plain hafnium note first draft"), NOW)
        .expect("capture v1");
    let mut v2_frame = cap_frame("plain hafnium note second draft");
    v2_frame.lineage_id = Some(v1.lineage_id);
    let v2 = coord.capture(&h, v2_frame, NOW + 100).expect("capture v2");

    let corpus = make_corpus();
    corpus.ingest(&v1.content, &v1.id, NOW).expect("ingest v1");
    corpus.ingest(&v2.content, &v2.id, NOW).expect("ingest v2");
    coord.register_corpus(&h, corpus.clone());

    let outcome = coord
        .expunge(&h, &v2.id, "full lineage expunge control", true, NOW + 300)
        .expect("expunge");
    assert!(
        outcome.refused_sibling_ids.is_empty(),
        "a lineage with no accepted members must report no refusals"
    );

    let estate = coord.estate_for(&h).expect("estate");
    for id in [&v1.id, &v2.id] {
        let row = estate
            .drawer_by_id(id)
            .expect("read row")
            .expect("row survives as tombstone");
        assert_eq!(
            row.adjective_bitmap & 0x3F,
            State::Tombstoned.raw_value(),
            "member {id} must be tombstoned"
        );
        assert_eq!(row.content, "", "member {id} content must be scrubbed");
        assert!(
            !corpus_recalls(&corpus, "hafnium note draft", id),
            "member {id} must no longer be corpus-recallable"
        );
    }
}
