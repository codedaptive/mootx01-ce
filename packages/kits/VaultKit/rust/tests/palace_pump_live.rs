//! Live scratch-pump integration test — Rust leg.
//!
//! GUARDED: runs only when `MP_PUMP_LIVE=1` AND a `mempalace-mcp` binary is on
//! PATH. It pumps a small real estate into a SCRATCH MemPalace palace under a
//! fresh /tmp directory (via `MEMPALACE_PALACE_PATH`) — NEVER the real
//! `~/.mempalace` palace — and verifies every item landed by fetching it back
//! with `get_drawer` by the assigned drawer id.
//!
//! Run it explicitly:
//!     MP_PUMP_LIVE=1 cargo test --test palace_pump_live -- --nocapture
//!
//! When the guard is off (the default CI/local `cargo test` run) the test
//! returns immediately, so the suite is green without a live server.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use genius_locus_kit::{coordinator::EstateCoordinator, handle::EstateHandle};
use locus_kit::{
    adjectives::AdjectiveSensitivity,
    drawer_operational::CaptureChannel,
    drawer_store::DrawerStore,
    drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::{LatticeAnchor, OwnerCredentials},
    frames::CaptureFrame,
};
use vault_kit::{
    CheckpointQueue, McpStdioClient, PalacePump, VaultExportScope,
};

const NOW: i64 = 1_765_000_000_000;

fn live_enabled() -> bool {
    std::env::var("MP_PUMP_LIVE").as_deref() == Ok("1")
        && which_mempalace().is_some()
}

/// Locate a `mempalace-mcp` binary on PATH (or the known pipx shim).
fn which_mempalace() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("PATH") {
        for dir in path.split(':') {
            let candidate = PathBuf::from(dir).join("mempalace-mcp");
            if candidate.exists() {
                return Some(candidate);
            }
        }
    }
    None
}

fn open_estate() -> (EstateCoordinator, EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).expect("InMemoryDrawerStore::new"));
    let handle = coord
        .open(store, OwnerCredentials::new("mp-pump-live"), 0, 100)
        .expect("open");
    (coord, handle)
}

/// Capture a small estate with hierarchy + a non-default sensitivity so the
/// pump exercises wing/room derivation and the full data model.
fn capture_small_estate(coord: &EstateCoordinator, handle: &EstateHandle) {
    let notes = [
        ("research/chem", "Benzene is an aromatic ring.", AdjectiveSensitivity::Normal),
        ("research/bio", "Mitochondria are the powerhouse.", AdjectiveSensitivity::Elevated),
        ("journal", "Today the pump shipped.", AdjectiveSensitivity::Restricted),
    ];
    for (room, content, sensitivity) in notes {
        let mut frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            room,
            LatticeAnchor::udc("000"),
            "mp-pump-live",
            "test-v1",
        );
        frame.sensitivity = sensitivity;
        coord.capture(handle, frame, NOW).expect("capture");
    }
}

#[test]
fn live_pump_to_scratch_palace_verifies_every_item() {
    if !live_enabled() {
        eprintln!("skipping live pump: set MP_PUMP_LIVE=1 with mempalace-mcp on PATH");
        return;
    }

    // SCRATCH palace under /tmp — never the real ~/.mempalace.
    let scratch = std::env::temp_dir().join(format!("mp-pump-rust-{}", uuid::Uuid::new_v4()));
    let palace = scratch.join("palace");
    let queue_root = scratch.join("queue");
    std::fs::create_dir_all(&palace).expect("mkdir scratch palace");

    let (coord, handle) = open_estate();
    capture_small_estate(&coord, &handle);

    // Spawn MemPalace with an explicit argv vector (no shell) — the palace path
    // rides as an env var so no metacharacter in the path can escape into a
    // shell argument position.
    let palace_str = palace.to_string_lossy();
    let mut client = McpStdioClient::connect(
        "mempalace-mcp",
        &["--palace", &palace_str],
        &[("MEMPALACE_PALACE_PATH", &palace_str)],
    )
    .expect("connect to scratch mempalace");
    let mut queue = CheckpointQueue::mount(&queue_root).expect("mount checkpoint queue");
    let pump = PalacePump::new(Duration::from_millis(0));

    let result = pump
        .run(
            &mut client,
            &mut queue,
            &coord,
            &handle,
            VaultExportScope::BelievedIncludingPrivate,
            NOW,
        )
        .expect("pump run");

    // All three notes wrote and verified by get_drawer round-trip.
    assert_eq!(result.items.len(), 3, "all notes pumped");
    assert_eq!(result.failed_count(), 0, "no write failures");
    assert_eq!(result.verified_count(), 3, "every item verified by get_drawer");
    for item in &result.items {
        assert!(item.drawer_id.is_some(), "{} got a drawer id", item.source_key);
        assert!(item.verified, "{} verified", item.source_key);
    }

    // Cleanup the scratch palace.
    let _ = std::fs::remove_dir_all(&scratch);
}
