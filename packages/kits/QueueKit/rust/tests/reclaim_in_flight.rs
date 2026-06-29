// reclaim_in_flight.rs — Integration tests for Mission #54 Part A:
// PersistenceKitBackend::reclaim_in_flight_for_stream and the QueueKit facade.
//
// Mirrors Swift's ReclaimInFlightTests.swift.
//
// Success criteria:
//   1. reclaim count: reclaim_in_flight_for_stream returns the exact count of
//      cur rows reset for the named stream.
//   2. state after reclaim: reclaimed rows become "new" and are claimable again.
//   3. stream isolation: reclaiming stream "encode" does NOT affect stream
//      "dreaming" cur rows.
//   4. empty queue: returns 0 when no cur rows exist for the stream.
//   5. facade passthrough: QueueKit::reclaim_in_flight_for_stream delegates to
//      PersistenceKitBackend and returns the correct count.
//   6. done rows untouched: reclaim does NOT reset "done" rows.

use queuekit::{HLC, Job, JobId, ObservationStatus, QueueBackend, StreamId};
use serde_json::Map;
use std::sync::Arc;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_job(seq: u64, stream: &str) -> Job {
    Job {
        id: JobId(format!("job-{:04}-{}", seq, stream)),
        stream_id: StreamId(stream.to_string()),
        submitted_at: HLC {
            physical_time: 1_700_000_000_000 + seq as i64,
            logical_count: 0,
            node_id: 1,
        },
        priority: 50,
        payload: format!("payload-{}", seq).into_bytes(),
        extensions: Map::new(),
    }
}

// ---------------------------------------------------------------------------
// PersistenceKitBackend tests (requires --features persistencekit)
// ---------------------------------------------------------------------------

#[cfg(feature = "persistencekit")]
mod pk {
    use super::*;
    use persistence_kit::{BackendConfiguration, EstateConfiguration};
    use persistence_kit::inmemory::InMemoryStorage;
    use queuekit::persistencekit::PersistenceKitBackend;

    fn make_backend() -> PersistenceKitBackend {
        let cfg = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
        let storage = Arc::new(InMemoryStorage::new(cfg));
        PersistenceKitBackend::open_schema(storage.as_ref()).expect("open_schema");
        PersistenceKitBackend::new(storage)
    }

    // ── 1. Reclaim count ─────────────────────────────────────────────────────

    /// reclaim_in_flight_for_stream returns the exact count of cur rows reset.
    #[test]
    fn reclaim_count_accurate() {
        let backend = make_backend();
        let encode = StreamId("encode".to_string());
        let dreaming = StreamId("dreaming".to_string());

        // Write two encode jobs and one dreaming job; drain all to cur.
        backend.write(&make_job(1, "encode")).unwrap();
        backend.write(&make_job(2, "encode")).unwrap();
        backend.write(&make_job(3, "dreaming")).unwrap();
        let claimed = backend.drain_available().unwrap();
        assert_eq!(claimed.len(), 3, "all three jobs should be claimed");

        // Reclaim only the encode stream.
        let n = backend.reclaim_in_flight_for_stream(&encode).unwrap();
        assert_eq!(n, 2, "must reclaim exactly 2 encode cur rows");

        // Dreaming row is still cur — not pending.
        let dreaming_pending = backend.pending_count_for_stream(&dreaming).unwrap();
        assert_eq!(dreaming_pending, 0, "dreaming cur row must not be reset");
    }

    // ── 2. State after reclaim: rows become new and are re-claimable ─────────

    #[test]
    fn reclaimed_rows_are_new_and_claimable() {
        let backend = make_backend();
        let encode = StreamId("encode".to_string());

        let j = make_job(1, "encode");
        let j_id = j.id.clone();
        backend.write(&j).unwrap();
        backend.drain_available().unwrap();   // → cur

        // No pending rows before reclaim.
        assert_eq!(backend.pending_count_for_stream(&encode).unwrap(), 0);

        backend.reclaim_in_flight_for_stream(&encode).unwrap();

        // After reclaim: the row is back in "new".
        assert_eq!(backend.pending_count_for_stream(&encode).unwrap(), 1);

        // drain_available_for_stream picks it up again.
        let reclaimed = backend.drain_available_for_stream(&encode).unwrap();
        assert_eq!(reclaimed.len(), 1);
        assert_eq!(reclaimed[0].0.id, j_id);
    }

    // ── 3. Stream isolation ───────────────────────────────────────────────────

    #[test]
    fn stream_isolation() {
        let backend = make_backend();
        let encode = StreamId("encode".to_string());
        let dreaming = StreamId("dreaming".to_string());

        backend.write(&make_job(1, "encode")).unwrap();
        backend.write(&make_job(2, "dreaming")).unwrap();
        backend.drain_available().unwrap();   // both → cur

        // Reclaim only encode.
        let n = backend.reclaim_in_flight_for_stream(&encode).unwrap();
        assert_eq!(n, 1);

        // Dreaming row is still cur — pending count is zero.
        assert_eq!(backend.pending_count_for_stream(&dreaming).unwrap(), 0);

        // In-flight count is exactly one (the dreaming row).
        let in_flight = backend.in_flight().unwrap();
        assert_eq!(in_flight.len(), 1);
        assert_eq!(in_flight[0].stream_id, dreaming);
    }

    // ── 4. Empty queue returns 0 ─────────────────────────────────────────────

    #[test]
    fn empty_queue_returns_zero() {
        let backend = make_backend();
        let encode = StreamId("encode".to_string());
        let n = backend.reclaim_in_flight_for_stream(&encode).unwrap();
        assert_eq!(n, 0);
    }

    // ── 5. Done rows are NOT reset ───────────────────────────────────────────

    #[test]
    fn done_rows_untouched() {
        let backend = make_backend();
        let encode = StreamId("encode".to_string());

        let j = make_job(1, "encode");
        let j_id = j.id.clone();
        backend.write(&j).unwrap();
        let claimed = backend.drain_available().unwrap();
        let (claimed_job, _) = &claimed[0];
        // Complete via the QueueBackend trait's complete().
        backend
            .complete(&claimed_job.id, ObservationStatus::Done, vec![])
            .unwrap();

        // reclaim_in_flight must not touch done rows.
        let n = backend.reclaim_in_flight_for_stream(&encode).unwrap();
        assert_eq!(n, 0);

        // Done row is still done.
        let done = backend.completed(None).unwrap();
        assert_eq!(done.len(), 1);
        assert_eq!(done[0].id, j_id);
    }
}

// ---------------------------------------------------------------------------
// QueueKit facade tests (requires --features persistencekit)
// ---------------------------------------------------------------------------

#[cfg(feature = "persistencekit")]
mod facade_tests {
    use super::*;
    use persistence_kit::{BackendConfiguration, EstateConfiguration};
    use persistence_kit::inmemory::InMemoryStorage;
    use queuekit::persistencekit::PersistenceKitBackend;
    use queuekit::QueueKit;

    fn make_kit() -> QueueKit<PersistenceKitBackend> {
        let cfg = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
        let storage = Arc::new(InMemoryStorage::new(cfg));
        PersistenceKitBackend::open_schema(storage.as_ref()).expect("open_schema");
        let backend = PersistenceKitBackend::new(storage);
        QueueKit::new(backend)
    }

    // Wall-clock epoch seconds for drain telemetry (infrastructure, not the
    // deterministic engine — drain telemetry uses wall clock by spec exception).
    fn now_secs() -> f64 {
        use std::time::{SystemTime, UNIX_EPOCH};
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs_f64())
            .unwrap_or(0.0)
    }

    /// Facade delegates to PersistenceKitBackend and returns the correct count.
    #[test]
    fn facade_delegates_correctly() {
        let kit = make_kit();
        let encode = StreamId("encode".to_string());

        // Write two encode jobs; drain them to cur via the facade.
        kit.send(&make_job(1, "encode")).unwrap();
        kit.send(&make_job(2, "encode")).unwrap();
        kit.drain_for_stream(&encode, now_secs()).unwrap();

        let n = kit.reclaim_in_flight_for_stream(&encode).unwrap();
        assert_eq!(n, 2);
    }
}
