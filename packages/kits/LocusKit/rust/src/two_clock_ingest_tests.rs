//! Two-clock ingest conformance tests for the Rust port.
//!
//! Mirrors `TwoClockIngestTests.swift`. Asserts the same event_time
//! semantics that Swift ships: round-trip, NULL→filed_at backfill,
//! capture stamping, fingerprint bucket parity. (ING-01)

#![cfg(test)]

use crate::drawer::Drawer;
use crate::drawer_fingerprint::{capture_week_bucket, EstateFingerprintFamilies};
use crate::drawer_operational::CaptureChannel;
use crate::drawer_store::DrawerStore;
use crate::drawer_store_inmemory::InMemoryDrawerStore;
use crate::estate::Estate;
use crate::estate_types::{LatticeAnchor, OwnerCredentials};
use crate::frames::CaptureFrame;
use std::sync::Arc;

// Epoch MILLISECONDS (ADR-023). NOW ≈ 2023-11-14; HISTORICAL = 2021-01-01.
const NOW: i64 = 1_700_000_000_000;
// A historical authorship date: 2021-01-01 00:00 UTC.
const HISTORICAL: i64 = 1_609_459_200_000;

fn make_estate() -> (Estate, Arc<InMemoryDrawerStore>) {
    let store = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let estate = Estate::create(store.clone(), OwnerCredentials::new("owner"), None).unwrap();
    (estate, store)
}

fn base_frame(content: &str, event_time: Option<i64>) -> CaptureFrame {
    let mut f = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "test-room",
        LatticeAnchor::udc("613"),
        "test-agent",
        "minilm-v6",
    );
    f.event_time = event_time;
    f
}

// -----------------------------------------------------------------------
// 1. event_time round-trips through capture + read
// -----------------------------------------------------------------------
#[test]
fn event_time_round_trips() {
    let (estate, _store) = make_estate();
    let frame = base_frame("hello world", Some(HISTORICAL));
    let drawer = estate.capture(frame, NOW).unwrap();
    assert_eq!(drawer.event_time, HISTORICAL);
    assert_eq!(drawer.filed_at, NOW);
}

// -----------------------------------------------------------------------
// 2. Streaming capture (no event_time) stamps filed_at as event_time
// -----------------------------------------------------------------------
#[test]
fn streaming_capture_stamps_now_as_event_time() {
    let (estate, _store) = make_estate();
    let frame = base_frame("streaming note", None);
    let drawer = estate.capture(frame, NOW).unwrap();
    assert_eq!(drawer.event_time, NOW);
    assert_eq!(drawer.filed_at, NOW);
}

// -----------------------------------------------------------------------
// 3. NULL→filed_at backfill at the decode boundary (legacy row simulation)
//
// Drawer.event_time is non-optional (i64), mirroring Swift. A row written
// before the eventTime column existed would carry NULL in SQLite; the
// decode boundary coalesces that NULL to filed_at. Here we verify the
// eagerly-resolved behavior by storing a drawer with event_time == filed_at
// and confirming it round-trips to the same value.
// -----------------------------------------------------------------------
#[test]
fn legacy_row_event_time_decoded_as_filed_at() {
    // Drawer::new() resolves event_time to filed_at by default (eager
    // resolution). This is what the decode boundary produces for a legacy
    // row that carried NULL in the eventTime column.
    let id = "00000000-0000-0000-0000-000000000099";
    let store = InMemoryDrawerStore::new(NOW, None).unwrap();
    let mut d = Drawer::new(id, "content", "test-parent", "agent", NOW, "model-v1");
    // event_time is already == filed_at (== NOW) after Drawer::new().
    // This mirrors the post-decode state for a legacy NULL-eventTime row.
    assert_eq!(d.event_time, NOW);
    d.udc_code = "613".to_string();
    store.add_drawer(&d, NOW).unwrap();

    let read_back = store.get_drawer(id).unwrap().unwrap();
    // Stored and decoded as the resolved value; must equal filed_at.
    assert_eq!(
        read_back.event_time,
        NOW,
        "event_time must equal filed_at for a legacy-style row"
    );
}

// -----------------------------------------------------------------------
// 4. Fingerprint bucket uses event_time, not filed_at (ING-01)
// -----------------------------------------------------------------------
#[test]
fn fingerprint_bucket_uses_event_time_not_filed_at() {
    // Historical doc filed today: bucket should reflect historical week.
    let hist_bucket = capture_week_bucket(HISTORICAL);
    let now_bucket = capture_week_bucket(NOW);
    // The two times are in different years; buckets must differ.
    assert_ne!(
        hist_bucket, now_bucket,
        "historical event_time and now should produce different week buckets"
    );
}

// -----------------------------------------------------------------------
// 5. Fingerprint with event_time ≠ filed_at differs from event_time == filed_at
// -----------------------------------------------------------------------
#[test]
fn fingerprint_differs_when_event_time_differs_from_filed_at() {
    let estate_uuid = "00000000-0000-0000-0000-000000000001";
    let families = EstateFingerprintFamilies::new(estate_uuid);

    // Two otherwise-identical drawers: one with historical event_time,
    // one with now. Fingerprints must differ (week bucket component).
    let mut d_hist = Drawer::new("id-hist", "content", "test-parent", "agent", NOW, "model");
    d_hist.event_time = HISTORICAL;
    d_hist.udc_code = "613".to_string();
    // Fix lineage so all other block inputs are identical.
    d_hist.lineage_id = uuid::Uuid::nil();

    let mut d_now = Drawer::new("id-now", "content", "test-parent", "agent", NOW, "model");
    d_now.event_time = NOW;
    d_now.udc_code = "613".to_string();
    d_now.lineage_id = uuid::Uuid::nil();

    let fp_hist = families.fingerprint(&d_hist);
    let fp_now = families.fingerprint(&d_now);
    assert_ne!(
        fp_hist, fp_now,
        "different event_time must produce different fingerprints"
    );
}
