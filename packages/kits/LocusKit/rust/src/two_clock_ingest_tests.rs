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

const NOW: i64 = 1_700_000_000;
// A historical authorship date: 2021-01-01 00:00 UTC.
const HISTORICAL: i64 = 1_609_459_200;

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
    assert_eq!(drawer.event_time, Some(HISTORICAL));
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
    assert_eq!(drawer.event_time, Some(NOW));
    assert_eq!(drawer.filed_at, NOW);
}

// -----------------------------------------------------------------------
// 3. NULL→filed_at backfill on read (row written without eventTime)
// -----------------------------------------------------------------------
#[test]
fn null_event_time_backfills_to_filed_at_on_read() {
    // Use InMemoryDrawerStore directly to bypass the capture verb and
    // write a row with event_time = None, simulating a row written before
    // the column existed.
    // Use a well-formed UUID so the store's id-validation passes.
    let id = "00000000-0000-0000-0000-000000000099";
    let store = InMemoryDrawerStore::new(NOW, None).unwrap();
    let mut d = Drawer::new(id, "content", "wing_test", "room", "agent", NOW, "model-v1");
    d.event_time = None; // simulate pre-column row
    d.udc_code = "613".to_string();
    store.add_drawer(&d, NOW).unwrap();

    let read_back = store.get_drawer(id).unwrap().unwrap();
    // After read, event_time must not be None — backfilled to filed_at.
    assert_eq!(
        read_back.event_time,
        Some(NOW),
        "NULL eventTime must backfill to filed_at on read"
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
    let mut d_hist = Drawer::new("id-hist", "content", "wing", "room", "agent", NOW, "model");
    d_hist.event_time = Some(HISTORICAL);
    d_hist.udc_code = "613".to_string();
    // Fix lineage so all other block inputs are identical.
    d_hist.lineage_id = uuid::Uuid::nil();

    let mut d_now = Drawer::new("id-now", "content", "wing", "room", "agent", NOW, "model");
    d_now.event_time = Some(NOW);
    d_now.udc_code = "613".to_string();
    d_now.lineage_id = uuid::Uuid::nil();

    let fp_hist = families.fingerprint(&d_hist);
    let fp_now = families.fingerprint(&d_now);
    assert_ne!(
        fp_hist, fp_now,
        "different event_time must produce different fingerprints"
    );
}
