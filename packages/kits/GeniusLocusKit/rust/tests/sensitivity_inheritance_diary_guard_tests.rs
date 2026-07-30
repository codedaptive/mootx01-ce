// sensitivity_inheritance_diary_guard_tests.rs
//
// Guard test for the dreaming-diary counts-only invariant (§D.4 option a).
// Rust twin of Swift `SensitivityInheritanceDiaryTests`.
//
// The `diary` table has no sensitivity column. Until it does, diary entries
// MUST NOT interpolate drawer content, drawer IDs, or any other material
// derived from estate drawers — only count integers and fixed keywords may
// appear. This file pins that contract with FORMAT-CONTRACT checks for all
// three diary format strings used by the Rust dreaming cycle.
//
// Scope caveat: these tests validate locally-MIRRORED copies of the diary
// format strings and a directly-written entry — they do NOT execute the
// DreamingCycle's own diary write path. A regression in DreamingCycle's
// interpolation surfaces here only if the mirrored format strings below
// are kept in sync with dreaming_cycle.rs (its three diary-site invariant
// comments point back here with a keep-in-sync instruction). A daemon-
// invoking sentinel test is the stronger upgrade if the invariant ever
// needs hard enforcement. This scope matches the Swift guard test exactly
// (SensitivityInheritanceDiaryTests.swift scope caveat).

use genius_locus_kit::EstateCoordinator;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::CaptureFrame;
use locus_kit::drawer_operational::CaptureChannel;
use persistence_kit::inmemory::InMemoryStorage;
use std::sync::Arc;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000;

// Keywords allowed in diary entries — fixed terms and non-negative integers only.
// Mirrors the Swift allowedKeywords set.
const ALLOWED_KEYWORDS: &[&str] = &[
    "dreaming", "cycle", "considered", "proposed", "suppressed", "below-threshold",
    "theta", "window", "24h", "used-set", "pairs",
    "omega", "14d", "dreamed-active", "reinforced", "retired",
];

/// Assert that every whitespace-separated token in the entry is either a
/// known keyword or a non-negative integer (no drawer content, IDs, or UUIDs).
fn assert_counts_only(entry: &str, source: &str) {
    for token in entry.split_whitespace() {
        // Strip trailing punctuation (commas, colons) to match the Swift helper.
        let trimmed = token.trim_end_matches([',', ':'].as_ref());
        let is_keyword = ALLOWED_KEYWORDS.iter().any(|&k| k.eq_ignore_ascii_case(trimmed));
        let is_integer = trimmed.parse::<u64>().is_ok();
        assert!(
            is_keyword || is_integer,
            "{}: token '{}' is neither a known keyword nor a non-negative integer — \
             diary must stay counts-only until diary.adjectiveBitmap is added",
            source,
            trimmed
        );
    }
}

// ── Format shape checks ────────────────────────────────────────────────────

#[test]
fn alpha_diary_format_is_counts_only() {
    // Mirror dreaming_cycle.rs ALPHA diary format string exactly.
    // keep-in-sync: dreaming_cycle.rs "dreaming cycle" diary write site.
    let cycle_count = 1usize;
    let candidates_considered = 5usize;
    let proposals_emitted_len = 3usize;
    let suppressed_duplicates = 2usize;
    let below_threshold = 0usize;
    let entry = format!(
        "dreaming cycle {}: considered {}, proposed {}, suppressed {}, below-threshold {}",
        cycle_count,
        candidates_considered,
        proposals_emitted_len,
        suppressed_duplicates,
        below_threshold
    );
    assert_counts_only(&entry, "ALPHA");
}

#[test]
fn theta_diary_format_is_counts_only() {
    // Mirror dreaming_cycle.rs THETA diary format string exactly.
    // keep-in-sync: dreaming_cycle.rs "theta cycle" diary write site.
    let cycle_count = 2usize;
    let used_set_len = 10usize;
    let observations_len = 5usize;
    let proposals_emitted_len = 3usize;
    let suppressed_duplicates = 1usize;
    let below_threshold = 0usize;
    let entry = format!(
        "theta cycle {}: window 24h, used-set {}, pairs {}, proposed {}, suppressed {}, below-threshold {}",
        cycle_count,
        used_set_len,
        observations_len,
        proposals_emitted_len,
        suppressed_duplicates,
        below_threshold
    );
    assert_counts_only(&entry, "THETA");
}

#[test]
fn omega_diary_format_is_counts_only() {
    // Mirror dreaming_cycle.rs OMEGA diary format string exactly.
    // keep-in-sync: dreaming_cycle.rs "omega cycle" diary write site.
    let cycle_count = 3usize;
    let candidates_len = 7usize;
    let retired_count = 2usize;
    let reinforced_count = candidates_len - retired_count;
    let entry = format!(
        "omega cycle {}: window 14d, dreamed-active {}, reinforced {}, retired {}",
        cycle_count,
        candidates_len,
        reinforced_count,
        retired_count
    );
    assert_counts_only(&entry, "OMEGA");
}

// ── Sentinel non-leakage check ─────────────────────────────────────────────

#[test]
fn dreaming_diary_does_not_leak_drawer_content() {
    // Verify that a directly-written counts-only diary entry does NOT contain
    // drawer content, even when a sentinel-bearing drawer exists in the estate.
    // Direct write via the coordinator verb surface (not daemon invocation)
    // per the scope caveat stated in this file's header comment.
    let sentinel = "DIARY_SENTINEL_RUST_abc123";

    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::with_storage(storage, NOW, None).unwrap());
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(
            store,
            OwnerCredentials::new("diary-guard-rust"),
            0,
            100,
        )
        .expect("open estate");

    // Capture a drawer whose content contains the sentinel.
    let body = format!("This drawer contains {} in its content.", sentinel);
    let frame = CaptureFrame::new(
        &body,
        CaptureChannel::Typed,
        "inbox",
        LatticeAnchor::udc("000"),
        "diary-guard",
        "test-model-v1",
    );
    coord.capture(&handle, frame, NOW).expect("capture");

    // Write a diary entry directly using the coordinator verb surface —
    // simulating what DreamingCycle does but without running the full cycle.
    coord
        .add_diary_entry(
            &handle,
            "dreaming-daemon",
            "dreaming cycle 1: considered 1, proposed 0, suppressed 0, below-threshold 0",
            "dreaming-cycle",
            "no-embedding",
            NOW,
        )
        .expect("add diary entry");

    // Read all diary entries and assert none contain the sentinel.
    let entries = coord
        .recall_diary_entries(&handle)
        .expect("recall diary entries");
    for e in &entries {
        assert!(
            !e.entry.contains(sentinel),
            "diary entry must not contain drawer content (sentinel found in '{}')",
            e.entry
        );
    }
}
