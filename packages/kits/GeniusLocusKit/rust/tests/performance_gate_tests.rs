// performance_gate_tests.rs — Rust mirror of the Theorem 5
// performance harness. The Swift reference is
// `Tests/GeniusLocusKitTests/PerformanceGateTests.swift`.
//
// Two budgets per implementation plan §7:
//
//   capture-path P99 latency ≤ 100 ms (iPhone budget, applied here as
//                                       a Mac-headroom ceiling)
//   enrichment throughput ≥ 60 drawers/hour (Mac floor)
//
// The Rust capture path on the GeniusLocusKit scaffold does not call
// into a live LocusKit Rust port — that port has not landed — so the
// capture-side measurement times the substrate primitives the Rust
// kit owns today: building a `CaptureFrame` and emitting an
// equivalent audit entry into the unified log. The enrichment
// measurement times `EnrichmentPipeline::run`, the same surface the
// Swift fixture measures.
//
// Both gates carry the same intent as the Swift fixture: assert with
// huge headroom, surface the measured figure in the test output.

use std::time::Instant;

use genius_locus_kit::audit::{
    AuditTier, EntryUUID, UnifiedAuditEntry, UnifiedAuditLog, UnifiedAuditValue,
    UnifiedAuditVerb,
};
use genius_locus_kit::matrix::{MatrixCalibrationRegistry, MatrixTier};
use genius_locus_kit::training::EnrichmentPipeline;
use genius_locus_kit::verbs::frames::{CaptureFrame, LatticeAnchor};
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_types::hlc::HLC;

const CAPTURE_P99_CEILING_MILLIS: f64 = 100.0;
const ENRICHMENT_RATE_FLOOR_PER_HOUR: f64 = 60.0;

#[test]
fn theorem_5_capture_p99_under_iphone_budget() {
    let sample_count = 200usize;
    let mut samples_millis: Vec<f64> = Vec::with_capacity(sample_count);

    // Warm-up: build one frame + audit entry before timing starts so
    // the first allocation does not dominate the tail.
    let _ = synthesise_capture(-1);

    for i in 0..sample_count {
        let start = Instant::now();
        let _ = synthesise_capture(i as i64);
        let elapsed_nanos = start.elapsed().as_nanos();
        samples_millis.push(elapsed_nanos as f64 / 1_000_000.0);
    }

    samples_millis.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let p50 = percentile(&samples_millis, 0.50);
    let p95 = percentile(&samples_millis, 0.95);
    let p99 = percentile(&samples_millis, 0.99);
    let max = samples_millis.last().copied().unwrap_or(0.0);

    println!(
        "[GLK-08 perf-rs] capture-latency p50={:.3} ms p95={:.3} ms p99={:.3} ms max={:.3} ms \
         (n={} Mac profile; iPhone budget {} ms)",
        p50, p95, p99, max, sample_count, CAPTURE_P99_CEILING_MILLIS
    );

    assert!(
        p99 < CAPTURE_P99_CEILING_MILLIS,
        "P99 capture latency {:.3} ms exceeds iPhone budget {} ms (Mac profile, n={})",
        p99,
        CAPTURE_P99_CEILING_MILLIS,
        sample_count
    );
}

#[test]
fn theorem_5_enrichment_throughput_clears_mac_floor() {
    let sample_count = 500usize;
    let mut log = UnifiedAuditLog::new();
    for i in 0..sample_count {
        let mut bytes = [0u8; 16];
        bytes[0] = (i & 0xFF) as u8;
        bytes[1] = ((i >> 8) & 0xFF) as u8;
        log.add(UnifiedAuditEntry::new(
            AuditTier::Locus,
            HLC::new((i as i64) + 1, 0, 1),
            UnifiedAuditVerb::Capture,
            EntryUUID(bytes),
            "tag_bits".to_string(),
            UnifiedAuditValue::Null,
            UnifiedAuditValue::Bitmap(1u64 << (i % 8)),
            None,
        ));
    }

    let mut tier = MatrixTier::new();
    let mut calibration = MatrixCalibrationRegistry::default();
    let pipeline = EnrichmentPipeline::new();

    let start = Instant::now();
    let result = pipeline.run(&log, &mut tier, &mut calibration, HLC::new(0, 0, 0));
    let elapsed_secs = start.elapsed().as_secs_f64();

    assert_eq!(
        result.transitions_considered as usize, sample_count,
        "pipeline must enrich every capture in the synthetic log"
    );
    assert!(elapsed_secs > 0.0, "elapsed must be positive; guards div-by-zero");

    let drawers_per_second = sample_count as f64 / elapsed_secs;
    let drawers_per_hour = drawers_per_second * 3600.0;

    println!(
        "[GLK-08 perf-rs] enrichment-rate elapsed={:.6} s drawers={} \
         rate={:.3} drawers/hour (Mac profile; floor {} drawers/hour)",
        elapsed_secs, sample_count, drawers_per_hour, ENRICHMENT_RATE_FLOOR_PER_HOUR
    );

    assert!(
        drawers_per_hour > ENRICHMENT_RATE_FLOOR_PER_HOUR,
        "enrichment rate {:.3} drawers/hour below Mac floor {} (n={})",
        drawers_per_hour,
        ENRICHMENT_RATE_FLOOR_PER_HOUR,
        sample_count
    );
}

// MARK: - Helpers

/// Build one CaptureFrame and append the equivalent unified audit
/// entry to a fresh log. The cost the Rust kit can measure end-to-end
/// today; downstream missions that wire the LocusKit Rust port will
/// replace the body with the live capture verb dispatch.
fn synthesise_capture(index: i64) -> UnifiedAuditLog {
    let udc_codes = ["004", "100", "300", "500", "684.08"];
    let rooms = ["work", "research", "personal", "ops", "scratch"];
    let i = if index < 0 { 0usize } else { index as usize };
    // Raw scaffold values for channel / kind / sensitivity — the Rust
    // port carries them as i64 raw values until the LocusKit Rust enum
    // taxonomy lands (see `frames.rs` for the documented numeric map).
    let _frame = CaptureFrame {
        content: format!("content-{}", index),
        channel: 0, // typed
        room: rooms[i % rooms.len()].to_string(),
        lattice_anchor: LatticeAnchor::udc(udc_codes[i % udc_codes.len()]),
        added_by: "perf-test".to_string(),
        embedding_model_id: "model-v1".to_string(),
        sensitivity: 0, // normal
        kind: 0,        // prose
        lineage_id: None,
    };

    let mut log = UnifiedAuditLog::new();
    let mut bytes = [0u8; 16];
    bytes[0] = ((i) & 0xFF) as u8;
    bytes[1] = ((i >> 8) & 0xFF) as u8;
    log.add(UnifiedAuditEntry::new(
        AuditTier::Locus,
        HLC::new(index + 1, 0, 1),
        UnifiedAuditVerb::Capture,
        EntryUUID(bytes),
        "tag_bits".to_string(),
        UnifiedAuditValue::Null,
        UnifiedAuditValue::Bitmap(1u64 << (i % 8)),
        None,
    ));
    log
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    let n = sorted.len();
    if n == 0 {
        return 0.0;
    }
    let rank = ((p * n as f64).ceil() as usize).max(1).min(n);
    sorted[rank - 1]
}
