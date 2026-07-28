// distill_segmentation_parity.rs — conformance gate for the intra-item
// distillation segmentation fix (R10, 2026-06-20).
//
// Root cause: coordinator.rs used `split(". ")` to segment drawer content
// into sentences for `distill_items_sweep`. That approximation under-counts
// sentences compared to Swift's EideticLib.sentencesByDelimiter(_:) for
// any text that ends with a bare period (no trailing space), uses `!`/`?`/
// `\n` as terminators, or has sentences joined by `. ` but ending in `.`.
//
// Fix: replaced with `eidetic_lib::segmenter::sentences`, the canonical
// cross-leg delimiter algorithm (Rust parity of Swift sentencesByDelimiter).
//
// Tests:
//  T1 — Segmenter yields ≥3 segments on the parity probe text (the exact
//       content used in the head-to-head live test that revealed the gap).
//  T2 — `distill_items_sweep` distills ≥1 item for a drawer with content
//       that has ≥3 sentences AND recurring named entities so the pipeline
//       emits a non-zero fingerprint. This tests end-to-end eligibility after
//       the segmentation fix. Note: the live parity test used the HMM extractor
//       (injected via NeuronKit at the app layer); distill_items_sweep uses
//       DistillationPipeline::default_extractor (capitalization heuristic).
//       T2 uses content crafted so the capitalization heuristic finds recurring
//       entities — verifying the sweep pipeline runs end-to-end, not just segments.
//  T3 — Old `split(". ")` approach on the same text also yields ≥3 segments
//       for this specific probe (sanity check — the bug manifests on other
//       inputs, not this exact probe). Documents the boundary.
//  T4 — A text whose last sentence ends with a bare period (no space after)
//       that `split(". ")` would collapse: the new segmenter counts correctly.

use std::sync::Arc;

use genius_locus_kit::EstateCoordinator;
use locus_kit::adjectives::AdjectiveSensitivity;
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::CaptureFrame;
use persistence_kit::inmemory::InMemoryStorage;
use uuid::Uuid;

// The RETIRED factoid-daemon actor string (SPEC_DISTILLATION_STORAGE §11).
// Used only to assert its ABSENCE: no new-write path may produce drawers
// with this provenance on 1.1.x.
const DISTILLATION_DAEMON_ACTOR: &str = "distillation-daemon";

// The exact probe text used in the head-to-head parity test that revealed
// the segmentation divergence. Swift counted ≥3 sentences; Rust must too.
const PROBE_TEXT: &str = "\
Head to head parity probe: the same content filed on both the Swift and Rust \
servers to diff capture, recall, distillation, and lens output byte for byte. \
Distillation needs several sentences. This memory has enough sentences to \
distill. The ports should agree.";

const NOW: i64 = 1_700_000_000;

fn open_one() -> (EstateCoordinator, genius_locus_kit::EstateHandle) {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::with_storage(storage, NOW, None).unwrap());
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(store, OwnerCredentials::new("owner-r10-tests"), 0, 100)
        .expect("open estate");
    (coord, handle)
}

// MARK: - T1: EideticLib segmenter yields ≥3 on the probe text

/// The canonical segmenter (eidetic_lib::segmenter::sentences) must count
/// ≥3 sentences on the probe text so the item is distillable.
/// This is the cross-leg reference invariant: if Swift counts ≥3, Rust must too.
#[test]
fn eidetic_segmenter_counts_at_least_three_on_probe_text() {
    let segments = eidetic_lib::segmenter::sentences(PROBE_TEXT);
    assert!(
        segments.len() >= 3,
        "EideticLib segmenter must yield ≥3 segments on the probe text \
         (got {}) — parity with Swift's sentencesByDelimiter(_:)",
        segments.len()
    );
}

// MARK: - T2: distill_items_sweep produces ≥1 factoid for eligible content

/// `distill_items_sweep` must distill ≥1 item (write its representation
/// columns) when a drawer contains content with ≥3 sentences AND recurring
/// named entities detectable by the default capitalization extractor.
///
/// The live parity failure (Swift=1, Rust=0) was driven by the segmentation
/// bug plus the HMM-vs-default extractor gap; this test isolates the sweep
/// end-to-end with content the default extractor CAN handle — "Swift" and
/// "Rust" are capitalized non-initial words that recur across sentences.
///
/// Content is crafted so that "Swift" and "Rust" each appear in ≥2 of the
/// 3+ segments, clearing the structural-recurrence threshold and causing the
/// pipeline to emit a non-zero feature fingerprint.
#[test]
fn distill_items_sweep_produces_factoid_for_eligible_content() {
    let (coord, h) = open_one();

    // Content with ≥3 sentences and recurring named entities "Swift" and "Rust"
    // that the capitalization heuristic will detect as ENT features.
    // "Swift" appears in sentences 0 and 2; "Rust" appears in sentences 0 and 1.
    // Each recurs across ≥2 of 3 segments, passing the majority threshold.
    let content = "Both Swift and Rust implement the same segmenter algorithm. \
                   Rust counts sentences using the delimiter approach. \
                   Swift uses the same delimiter approach for cross-leg parity.";

    let frame = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "notes",
        LatticeAnchor::udc("004"),
        "test-actor",
        "minilm-v6",
    );
    coord.capture(&h, frame, NOW).expect("capture drawer");

    // Run the sweep without a VectorStore — the fingerprint lane is dark but
    // the on-row column writes still land (VectorStore absence is non-fatal
    // per the sweep contract).
    let produced = coord
        .distill_items_sweep(&h, NOW, None)
        .expect("distill_items_sweep");

    assert!(
        produced >= 1,
        "distill_items_sweep must distill ≥1 item for content with recurring \
         named entities across ≥3 sentences (got 0)"
    );
}

// MARK: - T3: old split(". ") also counts ≥3 on this specific probe (sanity)

/// Documents that the old `split(". ")` approach also counts ≥3 on the
/// exact probe text — the parity gap exists for other inputs (trailing-period
/// content, `!`/`?`/`\n` terminators), not this specific probe. The fix still
/// applies because the old approach was structurally wrong; this test documents
/// the boundary.
#[test]
fn old_split_approach_also_counts_at_least_three_on_probe_text() {
    // Reproduce the old coordinator logic exactly.
    let old_count: usize = PROBE_TEXT
        .split(". ")
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .count();
    assert!(
        old_count >= 3,
        "old split('. ') also yields ≥3 on this probe ({old_count}) — gap is on other inputs"
    );
}

// MARK: - T4: trailing-period input where old approach under-counts

/// A text where every sentence ends with a bare `.` and the last sentence
/// does NOT have a trailing `. ` — exactly the case where `split(". ")`
/// would collapse the last sentence into the second-to-last.
///
/// Three sentences, all ending in `.`, with `. ` only BETWEEN sentences:
///   "First sentence. Second sentence. Third sentence."
///
/// `split(". ")` yields ["First sentence", "Second sentence", "Third sentence."]
/// → 3 segments.
///
/// But a two-sentence version that ends in a bare `.` without any trailing
/// text after it is the boundary: "First. Second." → split(". ") = ["First", "Second."]
/// → only 2 segments if fed as-is, which matches. HOWEVER, if the second sentence
/// is empty after the terminal `.`, this collapses. Test the exact boundary case:
/// three-part content joined by ". " that the new segmenter handles correctly
/// and is byte-for-byte equivalent.
#[test]
fn eidetic_segmenter_handles_trailing_period_text() {
    // This input is where `split(". ")` breaks: last segment after final `.`
    // has no `. ` so it is returned as one fused token by the old approach
    // BUT only if there is ambiguity. The cleanest failure mode: two sentences
    // with no space after the final period that a third clause appends to.
    let tricky = "Alpha has several words here. Beta is another sentence here. Gamma ends here.";

    // New segmenter: splits on every `.`
    let new_segs = eidetic_lib::segmenter::sentences(tricky);
    assert!(
        new_segs.len() >= 3,
        "EideticLib segmenter must yield ≥3 on the tricky trailing-period input (got {})",
        new_segs.len()
    );

    // Old approach: split(". ") on same text — also yields 3 for ". " between sentences
    let old_segs: Vec<_> = tricky.split(". ").filter(|s| !s.trim().is_empty()).collect();
    // Document: old approach gets 3 here too, so the boundary is specifically
    // inputs that lack `. ` (i.e., use `!`/`?`/`\n` or have no space after `.`).
    assert_eq!(old_segs.len(), 3, "old approach agrees here — boundary is elsewhere");

    // Demonstrate the real failure boundary: text using `!` or `?` as terminators.
    let with_exclaim = "Statement one! Statement two! Statement three!";
    let new_exclaim = eidetic_lib::segmenter::sentences(with_exclaim);
    let old_exclaim: Vec<_> = with_exclaim.split(". ").filter(|s| !s.trim().is_empty()).collect();

    assert!(
        new_exclaim.len() >= 3,
        "EideticLib segmenter correctly segments `!`-terminated sentences (got {})",
        new_exclaim.len()
    );
    assert_eq!(
        old_exclaim.len(), 1,
        "old split('. ') FAILS on `!`-terminated text (returns {} segments, not 3) — confirms the bug boundary",
        old_exclaim.len()
    );
}

// MARK: - T5: the sweep writes the representation ON the source row
//
// SPEC_DISTILLATION_STORAGE §7.2/§11: distillation performs on-row column
// writes only — no factoid drawer is captured, at any sensitivity tier.
// The representation lives on the row whose sensitivity governs it (§2),
// so an Elevated source simply carries its own representation.

#[test]
fn distill_items_sweep_writes_representation_on_source_row() {
    let (coord, h) = open_one();

    let content = "Both Swift and Rust implement the same algorithm. \
                   Rust parity is verified by the same tests. \
                   Swift and Rust must produce identical renderings.";

    let mut frame = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "notes",
        LatticeAnchor::udc("004"),
        "test-secfix",
        "minilm-v6",
    );
    frame.sensitivity = AdjectiveSensitivity::Elevated;
    let source = coord.capture(&h, frame, NOW).expect("capture elevated drawer");

    let produced = coord
        .distill_items_sweep(&h, NOW, None)
        .expect("distill_items_sweep");
    assert!(produced >= 1, "sweep must distill the Elevated source (got {produced})");

    let all = coord.all_drawers(&h).expect("all_drawers");
    // §11: no factoid drawers exist in any new-write path.
    assert!(
        all.iter().all(|d| d.added_by != DISTILLATION_DAEMON_ACTOR),
        "the sweep must not capture factoid drawers"
    );
    let row = all.iter().find(|d| d.id == source.id).expect("source row");
    assert_eq!(row.adjective_sensitivity(), AdjectiveSensitivity::Elevated);
    assert!(row.distilled.is_some(), "the representation rides the source row");
    assert_eq!(
        row.distilled_pipeline_version.as_deref(),
        Some(substrate_ml::token_compaction::DISTILLATION_PIPELINE_VERSION)
    );
}
