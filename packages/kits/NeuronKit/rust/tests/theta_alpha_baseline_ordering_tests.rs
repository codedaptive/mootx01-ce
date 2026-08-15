//! theta_alpha_baseline_ordering_tests.rs — THETA/ALPHA baseline-advance ordering.
//!
//! These tests pin the `DreamingDaemon` invariant that keeps the governor from
//! running two full-corpus reindexes in a single pump tick.
//!
//! ## What the four tests assert
//!
//! The governor executes the THETA basis retrain before calling
//! `check_corpus_growth` (the ALPHA growth gate). When THETA fires and advances
//! the shared vocab baseline, ALPHA then sees a delta of zero — below every
//! threshold — and skips the retrain. The tests verify:
//!
//! 1. After `advance_reindex_vocab`, `check_corpus_growth` does not fire a
//!    second retrain (the double-reindex prevention property).
//! 2. After advancing the baseline, `theta_retrain_warranted` returns false for
//!    growth within the threshold (THETA does not re-fire the same cycle).
//! 3. After advancing the baseline, `theta_retrain_warranted` returns true once
//!    growth crosses the threshold (the gate is still active, not permanently
//!    silenced).
//! 4. On the very first cycle (sentinel baseline), `check_corpus_growth`
//!    initialises the baseline without triggering a retrain (ALPHA first-cycle
//!    path is unaffected by the THETA changes).
//!
//! ## Why the ordering invariant matters
//!
//! If ALPHA ran before THETA, or if THETA did not advance the baseline before
//! returning control to ALPHA's gate, both phases would independently see the
//! full vocab delta and both would fire a reindex on the same tick. The ordering
//! in the governor (THETA execution runs before `check_corpus_growth`) is the
//! structural guarantee; these tests confirm the `DreamingDaemon` methods
//! uphold their side of that contract.
//!
//! ## Seam note
//!
//! These tests drive `DreamingDaemon` directly and do not observe coordinator
//! lock state. `CorpusContentEngine` is a concrete type with no mock seam, and
//! NeuronKit does not depend on CorpusKit, so no governor-level test can
//! construct a real corpus or observe the coordinator mutex from inside a
//! reindex call.

use neuron_kit::dreaming_cycle::{
    DreamingDaemon, DreamingPolicy, InMemoryCorpusGrowthProbe,
};

// ─── Shared fixture ──────────────────────────────────────────────────────────

/// Minimal policy sufficient to activate dreaming gates.
fn test_policy() -> DreamingPolicy {
    DreamingPolicy {
        min_success_rate: 0.1,
        min_confidence: 0.1,
        min_attempts: 1,
        tick_interval_ms: 30_000,
        event_observation_threshold: 3,
    }
}

/// Arbitrary deterministic epoch used as "now" throughout.
const T0: f64 = 1_700_000_000.0;

// ─── Tests ───────────────────────────────────────────────────────────────────

/// After a THETA retrain advances the vocab baseline, `check_corpus_growth`
/// (the ALPHA gate) does NOT fire a second retrain on the same tick.
///
/// Guards the double-reindex defect class: two full-corpus reindexes per tick
/// caused by ALPHA and THETA both observing the same non-zero vocab delta.
/// The fix is that THETA execution and `advance_reindex_vocab` run before
/// `check_corpus_growth`, leaving ALPHA with a zero delta.
#[test]
fn theta_advance_prevents_alpha_double_reindex() {
    let mut daemon = DreamingDaemon::new(test_policy());

    // Fresh daemon: last_reindex_vocab = -1 (sentinel). THETA retrain is
    // always warranted on the first cycle (backstop for dormant ALPHA paths).
    let live_vocab: i64 = 1_000;
    assert!(
        daemon.theta_retrain_warranted(live_vocab),
        "pre-condition: THETA warranted at sentinel baseline"
    );

    // Simulate a successful THETA retrain: advance the shared baseline.
    // In the governor this runs AFTER the lock block closes and BEFORE
    // check_corpus_growth (ALPHA) is called.
    daemon.advance_reindex_vocab(live_vocab);

    // Now run ALPHA's growth gate with a probe reporting the same live_vocab.
    // Because THETA already advanced the baseline to live_vocab, the delta is
    // zero — below every threshold — so the probe's reindex must NOT fire.
    let mut probe = InMemoryCorpusGrowthProbe::new(live_vocab);
    daemon.check_corpus_growth(T0, &mut probe);

    assert!(
        probe.reindex_calls.is_empty(),
        "ALPHA must not double-reindex when THETA already advanced the baseline; \
         probe.reindex_calls = {:?}",
        probe.reindex_calls
    );
}

/// After `advance_reindex_vocab`, `theta_retrain_warranted` returns false for
/// vocab growth within the threshold. Pins the baseline-advance contract the
/// governor relies on for the subsequent THETA cadence.
#[test]
fn theta_warranted_false_after_advance_within_threshold() {
    let mut daemon = DreamingDaemon::new(test_policy());

    let live_vocab: i64 = 1_000;
    daemon.advance_reindex_vocab(live_vocab);

    // Growth well within the fractional threshold (< 10 % of 1000 = 100 terms).
    let small_growth: i64 = live_vocab + 50;
    assert!(
        !daemon.theta_retrain_warranted(small_growth),
        "THETA must not fire again when growth is below threshold after advance; \
         small_growth = {small_growth}"
    );
}

/// After `advance_reindex_vocab`, `theta_retrain_warranted` returns true once
/// growth crosses the threshold. Confirms the gate is still active after the
/// first advance (not permanently silenced).
#[test]
fn theta_warranted_true_after_advance_when_growth_crosses_threshold() {
    let mut daemon = DreamingDaemon::new(test_policy());

    let live_vocab: i64 = 1_000;
    daemon.advance_reindex_vocab(live_vocab);

    // Growth well above the fractional threshold (> 10 % of 1000 = 100 terms).
    let large_growth: i64 = live_vocab + 200;
    assert!(
        daemon.theta_retrain_warranted(large_growth),
        "THETA must fire when growth crosses threshold after advance; \
         large_growth = {large_growth}"
    );
}

/// `check_corpus_growth` on a fresh daemon (sentinel baseline) records the
/// live vocab as the new baseline but does NOT trigger a retrain (first-cycle
/// initialisation path). Confirms the ALPHA sentinel path is unaffected by the
/// THETA changes.
#[test]
fn alpha_growth_check_initialises_baseline_without_reindex_on_first_cycle() {
    let mut daemon = DreamingDaemon::new(test_policy());

    // Fresh daemon: last_reindex_vocab = -1 sentinel.
    let mut probe = InMemoryCorpusGrowthProbe::new(500);
    daemon.check_corpus_growth(T0, &mut probe);

    // First cycle establishes baseline; no retrain should fire.
    assert!(
        probe.reindex_calls.is_empty(),
        "ALPHA first cycle must initialise baseline without retrain; \
         probe.reindex_calls = {:?}",
        probe.reindex_calls
    );
}
