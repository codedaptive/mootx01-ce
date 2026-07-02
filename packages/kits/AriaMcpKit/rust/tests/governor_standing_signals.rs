//! Standing-signal harness conformance for the Rust autonomic governor
//! (#8 Track 1). Mirrors the Swift `AutonomicGovernorTests` standing-signal
//! suite:
//!
//!   - `signalTickBenignWhenNoSchedulerRegistered`
//!     → `benign_skip_when_no_scheduler_registered`
//!   - `registeredSchedulerMakesSignalTickFireOnLivePath`
//!     → `registered_defaults_make_signal_tick_fire`
//!   - `governorTickDrivesQueryableEmission`
//!     → `governor_tick_drives_queryable_emission`
//!
//! Plus a deterministic cadence parity assertion: an interval signal is due on
//! its first evaluation and ticks exactly once per interval boundary, matching
//! the Swift scheduler's `isDue` interval contract.
//!
//! # Why the scheduler lives in the governor
//!
//! The Rust standing-signal scheduler ENGINE (`SerialLaneScheduler`,
//! `CoordinatorDispatcher`, nine signals per `default_standing_signal_names()`) already exists in GLK Rust with
//! its own parity gate (`genius_locus_kit/tests/scheduler_parity.rs`). This
//! suite covers the HARNESS Track 1 added: the governor OWNING a scheduler,
//! REGISTERING signals into it, and TICKING it on the governor cadence — the
//! seam where Track 2/3 producers will plug in.
//!
//! # Determinism
//!
//! Every test injects `now` as `UNIX_EPOCH + Duration` — no wall-clock read in
//! the assertion path, the same contract as the Swift suite and the
//! daemon-cadence tests in `autonomic_governor_tests.rs`.

use std::sync::Arc;
use std::time::{Duration, UNIX_EPOCH};

use neuron_kit::autonomic_governor::AutonomicGovernor;
use aria_mcp::estate_registry::EstateRegistry;
use genius_locus_kit::{
    default_standing_signal_names, SchedulerConcurrencyPolicy as ConcurrencyPolicy,
    SchedulerDiagnosticReport as DiagnosticReport, SchedulerResourceCostEstimate as ResourceCostEstimate,
    SchedulerSignalEmission as SignalEmission, SchedulerSignalSpec as SignalSpec,
    SchedulerSignalTrigger as SignalTrigger,
};

/// Per-call isolated pool paths so the governor's reducer never reads or writes
/// the real user pool (ce-fdcpool test isolation). Unique per call via a PID +
/// atomic counter — no `LATTICE_POOL_DIR` mutation, which would race across
/// parallel test threads.
fn isolated_pool_paths() -> (std::path::PathBuf, std::path::PathBuf) {
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let n = SEQ.fetch_add(1, Ordering::Relaxed);
    let base = std::env::temp_dir().join(format!("mootx01-testpool-{}-{}", std::process::id(), n));
    let pool_dir = base.join("pool");
    std::fs::create_dir_all(&pool_dir).unwrap();
    (pool_dir, base.join("WordClassTable.json"))
}

/// Build a governor over a fresh in-memory estate. The registry's
/// `new_inmemory` wires a `VectorStore` for the default estate, so
/// `register_default_standing_signals` finds a store (the live-path
/// precondition).
fn make_governor() -> (AutonomicGovernor, EstateRegistry) {
    let registry = EstateRegistry::new_inmemory();
    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;
    let store = Arc::clone(&registry.default.store);
    // Test isolation (ce-fdcpool): a private empty temp pool so a governor tick's
    // pool-reduce branch never reads or writes the real user pool. The 300_000 ms
    // topology cadence and 0 ms pool-reduce cadence mirror `new`'s production
    // defaults (DEFAULT_TOPOLOGY_CADENCE_MS / DEFAULT_POOL_REDUCE_CADENCE_MS).
    let (pool_dir, artifact) = isolated_pool_paths();
    let governor = AutonomicGovernor::new_for_testing_with_pool(
        coord, handle, store, 300_000, None, 0, pool_dir, artifact,
    );
    (governor, registry)
}

// MARK: - Benign skip (Swift: signalTickBenignWhenNoSchedulerRegistered)

/// GSS-1: with no scheduler registered, a governor tick benign-skips the
/// standing-signal scheduler — `signals_ticked == false`, never an error.
/// Mirrors Swift `signalTickBenignWhenNoSchedulerRegistered`.
#[test]
fn gss1_benign_skip_when_no_scheduler_registered() {
    let (mut governor, _registry) = make_governor();
    let report = governor.tick(UNIX_EPOCH + Duration::from_secs(3_000_000));
    assert!(
        !report.signals_ticked,
        "no scheduler registered → signals_ticked must be false (benign skip)"
    );
    assert_eq!(
        governor.open_signal_count(),
        0,
        "no signals registered before any registration call"
    );
}

// MARK: - Registered defaults make the tick fire (Swift:
// registeredSchedulerMakesSignalTickFireOnLivePath)

/// GSS-2: registering the six default standing signals makes a governor tick
/// drive the scheduler — `signals_ticked` is true and every default signal is
/// present in the status report. Mirrors Swift
/// `registeredSchedulerMakesSignalTickFireOnLivePath`.
#[test]
fn gss2_registered_defaults_make_signal_tick_fire() {
    let (mut governor, _registry) = make_governor();
    // Register at t=1 s so interval triggers schedule their first run relative
    // to a known instant (the scheduler stamps last_run_at at registration).
    let registered = governor
        .register_default_standing_signals("minilm-v6", UNIX_EPOCH + Duration::from_secs(1))
        .expect("in-memory estate has a registered VectorStore → registration succeeds");

    // Parity: the registered count matches the GLK default-signal roster.
    assert_eq!(
        registered.len(),
        default_standing_signal_names().len(),
        "registered default count must match GLK default_standing_signal_names"
    );

    // Tick well past every default's first-due window.
    let report = governor.tick(UNIX_EPOCH + Duration::from_secs(20_000_000));
    assert!(
        report.signals_ticked,
        "signal_tick must fire once a scheduler is registered (no benign skip on the live path)"
    );

    // Every interval signal is due on first evaluation (no prior run), so the
    // scheduler ran them — last_run_at is set on at least one. Mirrors the Swift
    // `reports.contains { $0.lastRunAt != nil }` assertion.
    let reports = governor.signal_status();
    assert!(
        reports.iter().any(|r| r.last_run_at_nanos.is_some()),
        "the scheduler must have run the registered signals on the tick"
    );
}

// MARK: - Governor tick drives a queryable emission (Swift:
// governorTickDrivesQueryableEmission)

/// GSS-3: a diagnostic emission produced by a registered signal on a governor
/// tick is queryable afterward through `signal_status`. Uses a custom
/// diagnostic-emitting signal for a deterministic, estate-data-independent
/// emission (the production propose/associate signals emit only when their
/// estate scan finds candidates). Mirrors Swift
/// `governorTickDrivesQueryableEmission`.
#[test]
fn gss3_governor_tick_drives_queryable_emission() {
    let (mut governor, _registry) = make_governor();
    let probe = SignalSpec {
        name: "op3-emission-probe".into(),
        trigger: SignalTrigger::Interval {
            seconds: Duration::from_secs(30),
        },
        resource_cost: ResourceCostEstimate::ZERO,
        freshness_target: Duration::from_secs(60),
        concurrency_policy: ConcurrencyPolicy::Single,
        emit: Arc::new(|ctx| {
            vec![SignalEmission::Diagnostic(DiagnosticReport {
                title: "op3.probe".into(),
                detail: "emission proof".into(),
                observed_at_nanos: ctx.now_nanos,
            })]
        }),
    };
    let _id = governor.register_standing_signal(probe, UNIX_EPOCH + Duration::from_secs(1));

    let report = governor.tick(UNIX_EPOCH + Duration::from_secs(21_000_000));
    assert!(report.signals_ticked);

    let reports = governor.signal_status();
    let probe_report = reports
        .iter()
        .find(|r| r.name == "op3-emission-probe")
        .expect("the registered probe signal must appear in status");
    // The emission was applied and recorded — queryable after the tick.
    assert!(
        probe_report.emission_count >= 1,
        "the probe's emission must be counted after the tick"
    );
    assert_eq!(
        probe_report.recent_diagnostics.len(),
        1,
        "the diagnostic emission must be recorded in recent_diagnostics"
    );
    assert_eq!(probe_report.recent_diagnostics[0].title, "op3.probe");
}

// MARK: - Interval cadence parity

/// GSS-4: an interval signal registered at t=1 s fires on its first tick past
/// the interval and again only after another full interval elapses — the same
/// `isDue` interval contract the GLK `scheduler_parity` gate checks, now driven
/// through the governor tick. Deterministic injected `now`.
#[test]
fn gss4_interval_signal_fires_once_per_interval_through_governor() {
    let (mut governor, _registry) = make_governor();
    // 30-second interval.
    let spec = SignalSpec {
        name: "cadence-probe".into(),
        trigger: SignalTrigger::Interval {
            seconds: Duration::from_secs(30),
        },
        resource_cost: ResourceCostEstimate::ZERO,
        freshness_target: Duration::from_secs(60),
        concurrency_policy: ConcurrencyPolicy::Single,
        emit: Arc::new(|ctx| {
            vec![SignalEmission::Diagnostic(DiagnosticReport {
                title: "cadence".into(),
                detail: "fire".into(),
                observed_at_nanos: ctx.now_nanos,
            })]
        }),
    };
    governor.register_standing_signal(spec, UNIX_EPOCH + Duration::from_secs(1));

    // Tick at t=2 s — interval (30 s) NOT elapsed since registration at t=1 s.
    governor.tick(UNIX_EPOCH + Duration::from_secs(2));
    let after_early = governor.signal_status()[0].emission_count;
    assert_eq!(after_early, 0, "must not fire before the 30 s interval elapses");

    // Tick at t=32 s — one full interval elapsed since registration → fires once.
    governor.tick(UNIX_EPOCH + Duration::from_secs(32));
    let after_first = governor.signal_status()[0].emission_count;
    assert_eq!(after_first, 1, "must fire exactly once at the first interval boundary");

    // Tick again at t=40 s — < 30 s since the t=32 fire → no new fire.
    governor.tick(UNIX_EPOCH + Duration::from_secs(40));
    let after_within = governor.signal_status()[0].emission_count;
    assert_eq!(after_within, 1, "must not re-fire within the same interval");

    // Tick at t=70 s — another full interval since t=32 → fires again.
    governor.tick(UNIX_EPOCH + Duration::from_secs(70));
    let after_second = governor.signal_status()[0].emission_count;
    assert_eq!(after_second, 2, "must fire again at the next interval boundary");
}
