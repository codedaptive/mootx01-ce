//! Estate-close registry completeness — Rust twin of
//! `EstateCloseCompletenessTests.swift`.
//!
//! Two tests, doing two different jobs.
//!
//! `reopen_does_not_resurrect_the_subject_producer` is the regression test for
//! Codex finding `6ed2ab30948481919f147fae496f55b1`. It fails against pre-fix
//! code: `close` did not remove `subject_producers`, and an `EstateHandle` is
//! equal across reopens of the same estate (its `estate_uuid` comes from the
//! manifest, so estate identity belongs to the substrate rather than to the
//! open), so reopening resolved the stale producer, rendered the
//! `subject_backfill` drain lane as live, and let `subject_backfill_sweep` —
//! which authorises on map presence alone — hand full drawer content to a
//! producer nobody had re-registered.
//!
//! `close_removes_every_declared_per_estate_registry` is the durable one. The
//! generalisable defect was never the one missing line; it was that nothing
//! enforced close-path completeness, so every registry added since had been one
//! act of memory away from leaking. This test reads `coordinator.rs` and fails
//! the next time a `HashMap<EstateHandle, …>` is declared without a matching
//! removal in `close`.
//!
//! Why a source scan and not a runtime assertion: Rust has no runtime
//! reflection, and the registries are private to the crate, so an integration
//! test cannot observe them directly. The Swift twin, which does have `Mirror`,
//! asserts emptiness at runtime instead. Both ports end up enforcing the same
//! invariant through the mechanism their language actually offers.

use std::sync::Arc;

use genius_locus_kit::{DrainStatus, EstateCoordinator, EstateHandle, SubjectProducer};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::CaptureFrame;

const NOW: i64 = 1_700_000_000;

/// Deterministic stub: derives a valid register subject from the content's
/// first line. Output text is a fixture, never a model claim.
struct StubProducer;
impl SubjectProducer for StubProducer {
    fn pipeline_version(&self) -> &str {
        "close-completeness-stub-v1"
    }
    fn subject_for_content(&self, content: &str) -> Result<String, String> {
        Ok(content.lines().next().unwrap_or("").chars().take(120).collect())
    }
}

/// Open `store` into an EXISTING coordinator.
///
/// The coordinator must be the same instance across close and reopen: the
/// finding is that the stale registry entry lives on the coordinator, so a test
/// that mints a fresh `EstateCoordinator` for the second open throws the
/// evidence away and passes against pre-fix code. Reopening the same store into
/// the same coordinator is the reproduction.
fn open_over(coord: &mut EstateCoordinator, store: Arc<dyn DrawerStore>) -> EstateHandle {
    coord
        .open(store, OwnerCredentials::new("close-completeness"), 0, 100)
        .expect("open must succeed")
}

fn seed_debt(coord: &EstateCoordinator, handle: &EstateHandle, count: usize) {
    for i in 1..=count {
        let frame = CaptureFrame::new(
            format!("Debt row number {i} awaiting a subject."),
            CaptureChannel::Typed,
            "close-completeness",
            LatticeAnchor::udc("000"),
            "close-completeness-tests",
            "test-model-v1",
        );
        coord.capture(handle, frame, NOW).expect("capture must succeed");
    }
}

// ─── 1. Regression: the reported finding ────────────────────────────────────

#[test]
fn reopen_does_not_resurrect_the_subject_producer() {
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let mut coord = EstateCoordinator::new();
    let handle = open_over(&mut coord, Arc::clone(&store));
    seed_debt(&coord, &handle, 3);

    // Register the rider; the lane goes live for this open.
    coord
        .register_subject_producer(&handle, Arc::new(StubProducer))
        .expect("register must succeed");
    assert_eq!(
        coord.subject_producer_pipeline(&handle).as_deref(),
        Some("close-completeness-stub-v1"),
        "precondition: the rider must be registered before close"
    );

    coord.close(&handle).expect("close must succeed");

    // Reopen the SAME store into the SAME coordinator. The handle is equal
    // across reopens by design — that stability is load-bearing and is NOT
    // what this mission changes.
    let reopened = open_over(&mut coord, store);
    assert_eq!(
        reopened, handle,
        "precondition for the whole finding: handles are equal across reopens"
    );

    // The rider must be gone. Pre-fix this returned Some(...).
    assert_eq!(
        coord.subject_producer_pipeline(&reopened),
        None,
        "close must not leave a subject producer resolvable on the reopened handle"
    );

    // The sweep refuses rather than handing drawer content to a producer the
    // caller never re-registered.
    assert!(
        coord.subject_backfill_sweep(&reopened, 10, NOW).is_err(),
        "sweep must refuse on a reopened estate with no re-registered rider"
    );

    // And the drain lane is dark again (barrier safety: the benchmarker gates
    // unknown lanes, so a lane rendering as live is itself the damage).
    let drains = coord.drain_statuses(&reopened).expect("drain_statuses");
    assert!(
        !drains.iter().any(|d| d.name == DrainStatus::SUBJECT_BACKFILL_NAME),
        "subject_backfill lane must be dark on the reopened handle: {drains:?}"
    );
}

// ─── 2. Durable: close-path completeness ────────────────────────────────────

/// `coordinator.rs`, read at compile time. The completeness check below is a
/// source scan because the registries are private to the crate and Rust offers
/// no runtime reflection to enumerate them.
const COORDINATOR_SRC: &str = include_str!("../src/coordinator.rs");

/// Every `HashMap<EstateHandle, …>` field declared on `EstateCoordinator`.
///
/// Two exclusions keep the scan honest: lines containing `fn ` (the
/// crate-internal `registry()` accessor mentions the same type in its return
/// position) and comment lines (the declaration block's own guidance names the
/// type in prose).
fn declared_registries(src: &str) -> Vec<String> {
    src.lines()
        .map(str::trim)
        .filter(|line| {
            line.contains("HashMap<EstateHandle,")
                && !line.contains("fn ")
                && !line.starts_with("//")
        })
        .filter_map(|line| {
            // `pub(crate) subject_producers: HashMap<EstateHandle, …>,`
            // → `subject_producers`
            let decl = line.trim_start_matches("pub(crate) ").trim_start_matches("pub ");
            decl.split(':').next().map(str::trim).map(str::to_string)
        })
        .filter(|name| {
            !name.is_empty()
                && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        })
        .collect()
}

/// The body of `EstateCoordinator::close`, from its signature to the first
/// method-level closing brace (four-space indent inside the `impl`).
fn close_body(src: &str) -> &str {
    let start = src
        .find("pub fn close(&mut self, handle: &EstateHandle)")
        .expect("close must exist with this signature; update this test if it is renamed");
    let rest = &src[start..];
    let end = rest
        .find("\n    }\n")
        .expect("close must end at a method-level closing brace");
    &rest[..end]
}

#[test]
fn close_removes_every_declared_per_estate_registry() {
    let declared = declared_registries(COORDINATOR_SRC);
    let body = close_body(COORDINATOR_SRC);

    // Guard the scanner itself: if the declaration syntax ever drifts far
    // enough that this finds nothing, the test would pass vacuously and the
    // enforcement would be silently gone.
    assert!(
        declared.len() >= 16,
        "the declaration scan found only {} registries — the scanner has drifted \
         from the source and is no longer enforcing anything: {declared:?}",
        declared.len()
    );

    let missing: Vec<&String> = declared
        .iter()
        .filter(|name| {
            // A plain map, or a `RefCell`-wrapped one (`dreaming_queues`).
            let plain = format!("self.{name}.remove(handle)");
            let cell = format!("self.{name}.borrow_mut().remove(handle)");
            !body.contains(&plain) && !body.contains(&cell)
        })
        .collect();

    assert!(
        missing.is_empty(),
        "close does not remove {} of the {} declared per-estate registries: {missing:?}\n\
         \n\
         A handle is equal across reopens of the same estate, so a registry \
         `close` does not remove resolves on the NEXT open as state the caller \
         never registered. Add `self.<field>.remove(handle);` to `close`, \
         teardown-ordered if the value owns a worker, a lease, or a connection.",
        missing.len(),
        declared.len()
    );
}

/// Pins the specific registry the Codex finding named, so a future refactor of
/// the scanner above cannot quietly stop covering it.
#[test]
fn close_removes_the_subject_producer_registry() {
    let body = close_body(COORDINATOR_SRC);
    assert!(
        body.contains("self.subject_producers.remove(handle)"),
        "close must remove subject_producers — Codex finding \
         6ed2ab30948481919f147fae496f55b1"
    );
}
