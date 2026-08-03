//! §11.5 Option B add-coverage conformance tests for the Rust port.
//!
//! Mirrors `ContainerFingerprintStoreTests.addCoverageGuaranteeAllThreeBitmaps`
//! and `addCoverageTwoDrawersSameRoom` in Swift.
//!
//! Invariant: after adding a drawer through the sanctioned path
//! (`Estate::capture`), `aggregate & drawer_bits == drawer_bits` must hold for
//! each of the three bitmap fields (adjective, operational, provenance), at both
//! the room-level AND the wing-level container aggregate. Coverage is now
//! structurally guaranteed because `add_drawer` folds the FP update inside
//! itself — this test proves the fold works correctly.

#![cfg(test)]

use crate::adjectives::AdjectiveSensitivity;
use crate::container_fingerprint_store::{ContainerFingerprint, ContainerFingerprintStore};
use crate::drawer_operational::{CaptureChannel, ContentKind, DrawerFeatureFlags};
use crate::drawer_store::DrawerStore;
use crate::drawer_store_inmemory::InMemoryDrawerStore;
use crate::estate::Estate;
use crate::estate_types::{LatticeAnchor, OwnerCredentials};
use crate::frames::CaptureFrame;
use crate::provenance::SourceType;
use std::collections::BTreeSet;
use std::sync::Arc;

const NOW: i64 = 1_700_000_000;

fn make_estate() -> (Estate, Arc<InMemoryDrawerStore>) {
    let store = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let estate = Estate::create(store.clone(), OwnerCredentials::new("cov-owner"), None).unwrap();
    (estate, store)
}

// -----------------------------------------------------------------------
// §11.5 coverage: single capture covers room and wing for all three bitmaps
// -----------------------------------------------------------------------

/// After adding a drawer through the sanctioned path (`Estate::capture`),
/// all three bitmap fields must be fully covered by both the room-level AND
/// the wing-level container aggregate: `aggregate & drawer_bits == drawer_bits`
/// for adjective, operational, and provenance. Mirrors Swift
/// `addCoverageGuaranteeAllThreeBitmaps`.
#[test]
fn add_coverage_guarantee_all_three_bitmaps() {
    let (estate, store) = make_estate();

    // Build a frame with non-trivial values in all three bitmap axes.
    // .voiced channel (raw 1) occupies operationalBitmap bits 0–5;
    // .code kind (raw 1) occupies bits 6–11; .restricted sensitivity
    // (raw 32) sits in adjectiveBitmap bits 6–11; .observed sourceType
    // (raw 1) sits in provenance bits 0–5.
    let mut frame = CaptureFrame::new(
        "coverage-test",
        CaptureChannel::Voiced,
        "r-cov",
        LatticeAnchor::udc("004"),
        "cov-tester",
        "model-v1",
    );
    frame.sensitivity = AdjectiveSensitivity::Restricted;
    frame.source_type = SourceType::Observed;
    // content_kind defaults to Prose (raw 0); channel=Voiced sets op bits 0–5
    // to the raw value of Voiced (1). This produces non-zero values in all fields.

    let drawer = estate.capture(frame, NOW).unwrap();

    // wing/room resolved from node tree via parent_node_id.
    let names = store.resolve_node_names(&[drawer.parent_node_id.clone()]).unwrap();
    let (wing, room) = names.get(&drawer.parent_node_id).expect("node must resolve");
    let wing = wing.clone();
    let room = room.clone();

    // Room-level aggregate must cover all three fields.
    let room_fp = store
        .get_container_fingerprint(&wing, &room)
        .unwrap()
        .expect("room aggregate must exist after capture");
    assert_eq!(
        room_fp.adjective & drawer.adjective_bitmap,
        drawer.adjective_bitmap,
        "room adjective aggregate must cover drawer.adjective_bitmap"
    );
    assert_eq!(
        room_fp.operational & drawer.operational_bitmap,
        drawer.operational_bitmap,
        "room operational aggregate must cover drawer.operational_bitmap"
    );
    assert_eq!(
        room_fp.provenance & drawer.provenance,
        drawer.provenance,
        "room provenance aggregate must cover drawer.provenance"
    );

    // Wing-level rollup (room == "") must also cover all three fields.
    let wing_fp = store
        .get_container_fingerprint(&wing, "")
        .unwrap()
        .expect("wing aggregate must exist after capture");
    assert_eq!(
        wing_fp.adjective & drawer.adjective_bitmap,
        drawer.adjective_bitmap,
        "wing adjective aggregate must cover drawer.adjective_bitmap"
    );
    assert_eq!(
        wing_fp.operational & drawer.operational_bitmap,
        drawer.operational_bitmap,
        "wing operational aggregate must cover drawer.operational_bitmap"
    );
    assert_eq!(
        wing_fp.provenance & drawer.provenance,
        drawer.provenance,
        "wing provenance aggregate must cover drawer.provenance"
    );
}

// -----------------------------------------------------------------------
// §11.5 coverage: two drawers in same room, aggregate covers both
// -----------------------------------------------------------------------

/// Two drawers in the same room: aggregate covers both, so no field of
/// either drawer is absent from the aggregate. Mirrors Swift
/// `addCoverageTwoDrawersSameRoom`.
#[test]
fn add_coverage_two_drawers_same_room() {
    let (estate, store) = make_estate();

    let frame1 = CaptureFrame::new(
        "first",
        CaptureChannel::Voiced,
        "r-cov2",
        LatticeAnchor::udc("004"),
        "t",
        "m",
    );
    let frame2 = CaptureFrame::new(
        "second",
        CaptureChannel::Typed,
        "r-cov2",
        LatticeAnchor::udc("004"),
        "t",
        "m",
    );

    let d1 = estate.capture(frame1, NOW).unwrap();
    let d2 = estate.capture(frame2, NOW + 1).unwrap();

    // wing resolved from node tree via parent_node_id.
    let names = store.resolve_node_names(&[d1.parent_node_id.clone()]).unwrap();
    let (wing, _) = names.get(&d1.parent_node_id).expect("node must resolve");

    let room_fp = store
        .get_container_fingerprint(wing, "r-cov2")
        .unwrap()
        .expect("room aggregate must exist after two captures");

    // The aggregate must cover d1's bits AND d2's bits.
    assert_eq!(room_fp.adjective & d1.adjective_bitmap, d1.adjective_bitmap,
               "aggregate must cover d1 adjective");
    assert_eq!(room_fp.adjective & d2.adjective_bitmap, d2.adjective_bitmap,
               "aggregate must cover d2 adjective");
    assert_eq!(room_fp.operational & d1.operational_bitmap, d1.operational_bitmap,
               "aggregate must cover d1 operational");
    assert_eq!(room_fp.operational & d2.operational_bitmap, d2.operational_bitmap,
               "aggregate must cover d2 operational");
    assert_eq!(room_fp.provenance & d1.provenance, d1.provenance,
               "aggregate must cover d1 provenance");
    assert_eq!(room_fp.provenance & d2.provenance, d2.provenance,
               "aggregate must cover d2 provenance");
}

// -----------------------------------------------------------------------
// setDistilledRepresentation fingerprint maintenance
// -----------------------------------------------------------------------

/// `DrawerStoreCore::set_distilled_representation` must OR bit 19
/// (`HAS_CURRENT_REPRESENTATION`) into the room/wing OR aggregate in the
/// same logical operation, so a subsequent recall filter on
/// `HasFeatureFlag(HasCurrentRepresentation)` does not falsely exclude
/// the container mid-session without requiring an estate reopen.
/// Mirrors Swift `ContainerFingerprintStoreTests
/// .setDistilledRepresentationUpdatesFingerprint`.
#[test]
fn set_distilled_representation_updates_fingerprint() {
    let (estate, store) = make_estate();

    // Capture a drawer — bit 19 (HAS_CURRENT_REPRESENTATION) is clear at capture.
    let frame = CaptureFrame::new(
        "dist-content",
        CaptureChannel::Voiced,
        "r-dist",
        LatticeAnchor::udc("004"),
        "t",
        "m",
    );
    let drawer = estate.capture(frame, NOW).unwrap();
    let bit19 = DrawerFeatureFlags::HAS_CURRENT_REPRESENTATION;

    // Resolve wing/room from the node tree.
    let names = store
        .resolve_node_names(&[drawer.parent_node_id.clone()])
        .unwrap();
    let (wing, _) = names
        .get(&drawer.parent_node_id)
        .expect("node must resolve");
    let wing = wing.clone();

    // Bit 19 absent from OR aggregate before distillation.
    let pre_fp = store
        .get_container_fingerprint(&wing, "r-dist")
        .unwrap()
        .expect("room aggregate must exist after capture");
    assert_eq!(
        pre_fp.operational & bit19,
        0,
        "bit 19 must be absent from the room aggregate before distillation"
    );

    // Distil the drawer post-capture — no estate reopen.
    let updated = estate
        .set_distilled_representation(&drawer.id, "distilled text", "v1", 42, NOW + 1000)
        .unwrap();
    assert_eq!(updated, 1);

    // Bit 19 must now appear in both room-level and wing-level OR aggregates.
    let post_room_fp = store
        .get_container_fingerprint(&wing, "r-dist")
        .unwrap()
        .expect("room aggregate must exist after distillation");
    assert_eq!(
        post_room_fp.operational & bit19,
        bit19,
        "bit 19 must be set in the room OR aggregate after set_distilled_representation"
    );
    let post_wing_fp = store
        .get_container_fingerprint(&wing, "")
        .unwrap()
        .expect("wing aggregate must exist after distillation");
    assert_eq!(
        post_wing_fp.operational & bit19,
        bit19,
        "bit 19 must be set in the wing OR aggregate after set_distilled_representation"
    );
}

// -----------------------------------------------------------------------
// Open-time rebuild: projected read must be output-identical
//
// `Estate::open`/`create` calls `rebuild_container_fingerprints`, which reads
// the active drawer set through a projected (no-blob) scan. These tests pin
// the property that makes that read legal: the aggregate it produces is
// byte-identical to the one a full-row read produces, and it still covers
// every active row (spec § 11.5).
// -----------------------------------------------------------------------

/// Snapshot every row in the `container_fingerprints` table as a
/// deterministically ordered `(wing, room, fingerprint)` list.
///
/// `room_level_entries` deliberately excludes the wing-rollup rows
/// (`room == ""`), so those are fetched separately and folded in — a rebuild
/// that got the rollups wrong while getting the rooms right must still fail
/// the comparison. The final sort by `(wing, room)` makes the snapshot
/// independent of storage iteration order, so an equality failure means the
/// aggregate genuinely differs rather than that the rows came back shuffled.
fn fingerprint_snapshot(
    fp_store: &ContainerFingerprintStore,
) -> Vec<(String, String, ContainerFingerprint)> {
    let mut rows: Vec<(String, String, ContainerFingerprint)> = fp_store
        .room_level_entries()
        .unwrap()
        .into_iter()
        .map(|e| (e.wing, e.room, e.fingerprint))
        .collect();
    let wings: BTreeSet<String> = rows.iter().map(|(w, _, _)| w.clone()).collect();
    for w in wings {
        if let Some(f) = fp_store
            .get(&w, ContainerFingerprintStore::WING_ROLLUP_ROOM)
            .unwrap()
        {
            rows.push((
                w,
                ContainerFingerprintStore::WING_ROLLUP_ROOM.to_string(),
                f,
            ));
        }
    }
    rows.sort_by(|a, b| (&a.0, &a.1).cmp(&(&b.0, &b.1)));
    rows
}

/// A bit no real flag occupies, used to dirty the aggregate before a rebuild.
///
/// `add_drawer` already folds each capture into the room and wing aggregates
/// incrementally, so straight after the fixture is built the table ALREADY
/// holds the right answer. A rebuild that silently skipped containers would
/// therefore be invisible — the capture-time rows would carry the comparison.
/// Poisoning every row first removes that safety net: only a container the
/// rebuild actually visits gets its row replaced (`put` writes a whole row),
/// so any container the rebuild misses keeps the poison and is caught.
const POISON: i64 = 1 << 40;

/// OR [`POISON`] into every container row that currently exists.
///
/// Returns the number of room-level rows poisoned, so a caller can assert the
/// fixture was non-empty rather than trusting a silent no-op.
fn poison_every_container(fp_store: &ContainerFingerprintStore, now: i64) -> usize {
    let entries = fp_store.room_level_entries().unwrap();
    for e in &entries {
        // `or_in` also ORs into the wing-rollup row, so the rollups are
        // poisoned alongside their rooms.
        fp_store
            .or_in(&e.wing, &e.room, POISON, POISON, POISON, now)
            .unwrap();
    }
    entries.len()
}

/// Capture a drawer with an explicit spread across all three bitmap axes so
/// the fixture exercises adjective, operational, and provenance together
/// rather than leaving two of the three at their defaults.
fn capture_spread(
    estate: &Estate,
    content: &str,
    room: &str,
    channel: CaptureChannel,
    kind: crate::drawer_operational::ContentKind,
    sensitivity: AdjectiveSensitivity,
    source_type: SourceType,
    now: i64,
) -> crate::drawer::Drawer {
    let mut frame = CaptureFrame::new(
        content,
        channel,
        room,
        LatticeAnchor::udc("004"),
        "fb-tester",
        "model-v1",
    );
    frame.kind = kind;
    frame.sensitivity = sensitivity;
    frame.source_type = source_type;
    estate.capture(frame, now).unwrap()
}

/// Build the multi-room fixture the equivalence test folds over: four active
/// drawers spread across three rooms with distinct values on all three bitmap
/// axes, plus one tombstoned row.
///
/// Returns the estate, the store, and the id of the tombstoned drawer.
fn spread_fixture() -> (Estate, Arc<InMemoryDrawerStore>, String) {
    let (estate, store) = make_estate();

    // Room A — two drawers, so the room-level AND fold has something to
    // narrow (a single-drawer room's AND is just that drawer's bitmap and
    // would not distinguish a broken AND from a correct one).
    capture_spread(
        &estate,
        "room a first body text",
        "r-fb-a",
        CaptureChannel::Voiced,
        ContentKind::Prose,
        AdjectiveSensitivity::Normal,
        SourceType::User,
        NOW,
    );
    capture_spread(
        &estate,
        "room a second body text",
        "r-fb-a",
        CaptureChannel::Ocr,
        ContentKind::Code,
        AdjectiveSensitivity::Restricted,
        SourceType::Observed,
        NOW + 1,
    );
    // Room B — different axis combination again.
    capture_spread(
        &estate,
        "room b body text",
        "r-fb-b",
        CaptureChannel::ImportedFile,
        ContentKind::Transcript,
        AdjectiveSensitivity::Restricted,
        SourceType::Observed,
        NOW + 2,
    );
    // The tombstoned row lives in room A, alongside two active siblings.
    //
    // It deliberately does NOT get a room of its own. A container whose ENTIRE
    // active set is tombstoned is never revisited by `rebuild_all` — there is
    // nothing left to fold — so its capture-time row survives and the wing
    // rollup keeps ORing it in. That is pre-existing behaviour, identical
    // before and after the projected read, and out of this mission's scope;
    // putting the tombstone in a live room keeps this fixture measuring the
    // projection rather than that unrelated property.
    let doomed = capture_spread(
        &estate,
        "room a body text that gets expunged",
        "r-fb-a",
        CaptureChannel::Sensor,
        ContentKind::List,
        AdjectiveSensitivity::Normal,
        SourceType::User,
        NOW + 3,
    );
    // Room D — an active row filed after the tombstone, so the tombstone is
    // not the last row in `(filedAt, id)` order.
    capture_spread(
        &estate,
        "room d body text",
        "r-fb-d",
        CaptureChannel::Typed,
        ContentKind::StructuredJson,
        AdjectiveSensitivity::Normal,
        SourceType::Observed,
        NOW + 4,
    );

    estate
        .expunge(&doomed.id, "fb fixture tombstone", true, NOW + 5, false)
        .unwrap();

    (estate, store, doomed.id)
}

/// **The test that matters.** The projected rebuild must produce a
/// byte-identical aggregate to the full-row rebuild, and must cover every
/// active container while doing it.
///
/// ## How the pre-fix output is captured
///
/// Not transcribed from a previous run — recomputed inside the test. The
/// full-row read (`all_drawers`) is still a live trait method, so the
/// pre-projection algorithm is reproduced verbatim in the second half of this
/// test: full-row scan, filter tombstones, resolve node names, `rebuild_all`.
/// Both halves run against the same fixture in the same process, and
/// `rebuild_room`/`roll_up_wing` write via `put`, which upserts a complete row
/// — so the second pass fully overwrites the first and the two snapshots are
/// directly comparable.
///
/// ## Why each pass is preceded by a poisoning pass
///
/// Verified by mutation: without it this test passes even when the rebuild's
/// scan is truncated to a row limit, because `add_drawer` folds each capture
/// into the aggregate as it lands, so the capture-time rows already hold the
/// correct answer and a rebuild that visited nothing would still compare
/// equal. [`poison_every_container`] sets a bit no real flag uses in every row
/// first; `put` replaces whole rows, so a container the rebuild visits comes
/// back clean and one it skips keeps the poison. The final assertion — no
/// surviving poison — is the § 11.5 completeness check: the aggregate is only
/// sound to prune against if the rebuild covered every active row.
#[test]
fn projected_rebuild_is_output_identical_to_full_row_rebuild() {
    let (_estate, store, _doomed_id) = spread_fixture();
    let fp_store = ContainerFingerprintStore::new(Arc::clone(store.storage())).unwrap();

    // --- Pass 1: the shipping path (projected, no-blob read). ---
    let poisoned = poison_every_container(&fp_store, NOW + 50);
    assert!(
        poisoned >= 3,
        "fixture must span at least three active rooms, got {poisoned}"
    );
    store.rebuild_container_fingerprints(NOW + 100).unwrap();
    let projected = fingerprint_snapshot(&fp_store);

    // Guard the guard: an empty snapshot would make the comparison vacuous.
    assert!(
        projected.len() > poisoned,
        "snapshot must hold every room row plus at least one wing rollup, got {}: {:?}",
        projected.len(),
        projected
    );

    // Completeness: every container the rebuild was responsible for came back
    // without the poison, so none was skipped.
    for (wing, room, fp) in &projected {
        assert_eq!(
            fp.adjective & POISON,
            0,
            "container ({wing}, {room}) kept the poison in adjectiveOR — the rebuild skipped it"
        );
        assert_eq!(
            fp.operational & POISON,
            0,
            "container ({wing}, {room}) kept the poison in operationalOR — the rebuild skipped it"
        );
        assert_eq!(
            fp.provenance & POISON,
            0,
            "container ({wing}, {room}) kept the poison in provenanceOR — the rebuild skipped it"
        );
    }

    // --- Pass 2: the full-row algorithm, reproduced verbatim. ---
    let re_poisoned = poison_every_container(&fp_store, NOW + 150);
    assert_eq!(
        re_poisoned, poisoned,
        "both passes must start from the same poisoned state"
    );
    let active: Vec<crate::drawer::Drawer> = store
        .all_drawers()
        .unwrap()
        .into_iter()
        .filter(|d| d.tombstoned_at.is_none())
        .collect();
    // The full-row read really did carry content — this is what the projected
    // scan avoids, and it confirms pass 2 is the heavier implementation and
    // not an accidental second run of pass 1.
    assert!(
        active.iter().any(|d| !d.content.is_empty()),
        "the full-row read must materialise content, otherwise this is not the pre-fix path"
    );
    let parent_ids: Vec<String> = active.iter().map(|d| d.parent_node_id.clone()).collect();
    let node_names = store.resolve_node_names(&parent_ids).unwrap();
    fp_store.rebuild_all(&active, &node_names, NOW + 100).unwrap();
    let full_row = fingerprint_snapshot(&fp_store);

    assert_eq!(
        projected, full_row,
        "the projected rebuild must produce a byte-identical aggregate to the full-row rebuild"
    );
}

/// The rebuild's read path must never materialise the `content` blob.
///
/// There is no I/O counter on the in-memory storage backend to assert against,
/// so this asserts the projection contract that the rebuild depends on
/// instead: the same fixture, read through the full-row scan, carries content;
/// read through `all_drawers_bounded_projected` — the scan
/// `rebuild_container_fingerprints` uses — every row's content is empty. If a
/// future edit routes the rebuild back through a content-bearing read, the
/// equivalence test above still passes but this one documents which read the
/// rebuild is required to use.
#[test]
fn projected_scan_used_by_the_rebuild_does_not_carry_content() {
    let (_estate, store, _doomed_id) = spread_fixture();

    let full = store.all_drawers().unwrap();
    assert!(
        full.iter().any(|d| !d.content.is_empty()),
        "fixture must store non-empty content for this test to mean anything"
    );

    let projected = store.all_drawers_bounded_projected(None).unwrap();
    assert_eq!(
        projected.len(),
        full.len(),
        "the projected scan must return the same row count as the full-row scan"
    );
    for d in &projected {
        assert!(
            d.content.is_empty(),
            "drawer {} carried content through the projected scan the rebuild uses",
            d.id
        );
    }
    // The five fields the rebuild actually folds must all survive the
    // projection — a projection that dropped one of these would silently
    // change the aggregate.
    for (p, f) in projected.iter().zip(full.iter()) {
        assert_eq!(p.id, f.id, "projected scan must preserve row order");
        assert_eq!(p.parent_node_id, f.parent_node_id);
        assert_eq!(p.tombstoned_at, f.tombstoned_at);
        assert_eq!(p.adjective_bitmap, f.adjective_bitmap);
        assert_eq!(p.operational_bitmap, f.operational_bitmap);
        assert_eq!(p.provenance, f.provenance);
    }
}

/// Opening an estate with no drawers still succeeds, and writes no
/// container rows. `Estate::create` already runs the rebuild once on an empty
/// store; this pins that the projected scan handles the zero-row case.
#[test]
fn rebuild_on_an_empty_estate_succeeds_and_writes_no_rows() {
    let (_estate, store) = make_estate();
    let fp_store = ContainerFingerprintStore::new(Arc::clone(store.storage())).unwrap();

    store.rebuild_container_fingerprints(NOW + 100).unwrap();

    assert!(
        fp_store.room_level_entries().unwrap().is_empty(),
        "an estate with no drawers must produce no container-fingerprint rows"
    );
}

/// Tombstoned rows stay out of the rebuilt aggregate.
///
/// The two drawers share a room and carry disjoint operational bits, so the
/// tombstoned row contributes at least one bit the survivor does not. After
/// the rebuild that bit must be absent from the room aggregate — proof the
/// tombstone filter still runs on the projected read, not just on the
/// full-row one.
#[test]
fn tombstoned_rows_stay_excluded_from_the_rebuilt_aggregate() {
    let (estate, store) = make_estate();

    let survivor = capture_spread(
        &estate,
        "surviving row",
        "r-fb-tomb",
        CaptureChannel::Voiced, // raw 1 → bit 0 of the channel field
        ContentKind::Prose,
        AdjectiveSensitivity::Normal,
        SourceType::User,
        NOW,
    );
    let doomed = capture_spread(
        &estate,
        "row to be tombstoned",
        "r-fb-tomb",
        CaptureChannel::Ocr, // raw 2 → bit 1 of the channel field
        ContentKind::Prose,
        AdjectiveSensitivity::Normal,
        SourceType::User,
        NOW + 1,
    );

    // Read the bitmaps BEFORE the expunge — expunge rewrites the doomed
    // row's operational bitmap (it clears hasCurrentRepresentation).
    let unique_to_doomed = doomed.operational_bitmap & !survivor.operational_bitmap;
    assert_ne!(
        unique_to_doomed, 0,
        "fixture must give the doomed drawer at least one operational bit the survivor lacks"
    );

    estate
        .expunge(&doomed.id, "fb tombstone exclusion", true, NOW + 2, false)
        .unwrap();
    store.rebuild_container_fingerprints(NOW + 100).unwrap();

    let room_fp = store
        .get_container_fingerprint(
            &store
                .resolve_node_names(&[survivor.parent_node_id.clone()])
                .unwrap()
                .get(&survivor.parent_node_id)
                .expect("survivor's node must resolve")
                .0
                .clone(),
            "r-fb-tomb",
        )
        .unwrap()
        .expect("room aggregate must exist after rebuild");

    assert_eq!(
        room_fp.operational & unique_to_doomed,
        0,
        "the tombstoned row's operational bits must not appear in the rebuilt aggregate"
    );
    assert_eq!(
        room_fp.operational, survivor.operational_bitmap,
        "the rebuilt room OR must equal exactly the surviving active row's bitmap"
    );
}
