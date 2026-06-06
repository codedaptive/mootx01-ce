//! Kernel telemetry integration tests — SUBSTRATE_REPORT_001.
//!
//! Mirrors the Swift suite in
//! Tests/SubstrateKernelTests/KernelTelemetryTests.swift.
//! Section numbers correspond to the Swift suites:
//!
//!   §1 Disabled gate: no metric emitted when monitoring is OFF.
//!   §2 Enabled gate: backend_selected metric emitted when ON.
//!   §3 Arch tag: emitted tag matches current_arch_tag().
//!   §4 Conformance: math output is unaffected by telemetry.
//!
//! Notes on global state isolation:
//!   for_current_platform() uses the intellectus_lib global singleton.
//!   Rust integration tests run in parallel by default.
//!   Tests that toggle the global enabled flag acquire GLOBAL_LOCK
//!   for the duration, ensuring they are never interleaved. Tests
//!   that only read math output (§4 disabled-path) do not need the
//!   lock (they don't care about sink state).

use std::sync::{Arc, Mutex, OnceLock};

use intellectus_lib::{Intellectus, NoOpSink, StatSample, StatsSink};
use substrate_kernel::kernel::{PortableKernel, KernelKind, SubstrateKernel};
use substrate_types::fingerprint256::Fingerprint256;

// Process-wide serialisation lock for tests that manipulate the
// Intellectus global singleton (enabled flag + installed sink).
// All such tests hold this lock for their entire duration, ensuring
// that concurrent enabled/install races cannot cause spurious
// mismatches in the captured sample count.
//
// Lock poisoning: if a prior test panicked while holding the lock,
// `lock()` returns a PoisonError. We recover with `into_inner()`
// so subsequent tests can still run. Each test restores the global
// state to disabled+NoOpSink before releasing, limiting cross-test
// contamination to the single panicking test.
static GLOBAL_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn global_lock() -> std::sync::MutexGuard<'static, ()> {
    let mutex = GLOBAL_LOCK.get_or_init(|| Mutex::new(()));
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poison) => poison.into_inner(),
    }
}

// MARK: - Helper: capturing sink

/// Records every received StatSample. Thread-safe via Mutex.
struct CapturingSink {
    samples: Mutex<Vec<StatSample>>,
}

impl CapturingSink {
    fn new() -> Self {
        CapturingSink { samples: Mutex::new(Vec::new()) }
    }

    fn count(&self) -> usize {
        self.samples.lock().unwrap().len()
    }

    fn first(&self) -> Option<StatSample> {
        self.samples.lock().unwrap().first().cloned()
    }
}

impl StatsSink for CapturingSink {
    fn receive(&self, sample: StatSample) {
        self.samples.lock().unwrap().push(sample);
    }
}

// MARK: - §1 Disabled gate

/// With monitoring OFF, for_current_platform() must not emit a sample.
#[test]
fn no_metric_emitted_when_disabled() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    // Explicitly disabled — the default state.
    Intellectus::set_enabled(false);

    let _ = PortableKernel::for_current_platform();

    assert_eq!(sink.count(), 0,
        "for_current_platform() must not emit when monitoring is disabled");

    // Restore defaults.
    Intellectus::install(Arc::new(NoOpSink));
}

/// Factory still returns the correct kernel even when monitoring is disabled.
#[test]
fn factory_returns_correct_kernel_when_disabled() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let kernel = PortableKernel::for_current_platform();

    // On aarch64 with simd-nightly: Simd. Without feature or on other arches: Scalar.
    #[cfg(all(target_arch = "aarch64", feature = "simd-nightly"))]
    assert_eq!(kernel.kind(), KernelKind::Simd,
        "aarch64+simd-nightly must return SimdKernel");

    #[cfg(not(all(target_arch = "aarch64", feature = "simd-nightly")))]
    assert_eq!(kernel.kind(), KernelKind::Scalar,
        "non-simd build must return ScalarKernel");

    // Restore.
    Intellectus::install(Arc::new(NoOpSink));
}

// MARK: - §2 Enabled gate

/// With monitoring ON, exactly one backend_selected metric must be
/// received per for_current_platform() call.
#[test]
fn backend_selected_metric_emitted_when_enabled() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let _ = PortableKernel::for_current_platform();

    assert_eq!(sink.count(), 1,
        "exactly one metric must be emitted per for_current_platform() call");

    if let Some(StatSample::Metric { name, value, tags, .. }) = sink.first() {
        assert_eq!(name, "substrate.kernel.backend_selected");
        assert_eq!(value, 1.0);
        assert!(tags.contains_key("backend"),
            "metric must carry a 'backend' tag; got {:?}", tags);
        assert!(tags.contains_key("arch"),
            "metric must carry an 'arch' tag; got {:?}", tags);
    } else {
        panic!("expected a Metric sample; got {:?}", sink.first());
    }

    // Restore defaults.
    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// The backend tag must match the kernel kind the factory returned.
#[test]
fn backend_tag_matches_selected_kernel_kind() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let kernel = PortableKernel::for_current_platform();

    let expected_backend = kernel.kind().as_str();
    if let Some(StatSample::Metric { tags, .. }) = sink.first() {
        assert_eq!(tags.get("backend").map(|s| s.as_str()), Some(expected_backend),
            "backend tag must match kernel kind rawValue");
    } else {
        panic!("no metric emitted");
    }

    // Restore defaults.
    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

// MARK: - §3 Arch tag

/// The arch tag in the emitted metric must match current_arch_tag().
#[test]
fn arch_tag_matches_current_arch_tag() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let _ = PortableKernel::for_current_platform();

    if let Some(StatSample::Metric { tags, .. }) = sink.first() {
        assert_eq!(tags.get("arch").map(|s| s.as_str()),
                   Some(PortableKernel::current_arch_tag()),
                   "arch tag must match current_arch_tag()");
    } else {
        panic!("no metric emitted");
    }

    // Restore defaults.
    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// current_arch_tag() must be a non-empty string.
#[test]
fn current_arch_tag_is_non_empty() {
    assert!(!PortableKernel::current_arch_tag().is_empty());
}

/// Validate the compile-time arch tag value for this build host.
#[test]
fn current_arch_tag_compile_time_value_is_correct() {
    #[cfg(target_arch = "aarch64")]
    assert_eq!(PortableKernel::current_arch_tag(), "aarch64");
    #[cfg(target_arch = "x86_64")]
    assert_eq!(PortableKernel::current_arch_tag(), "x86_64");
    #[cfg(not(any(target_arch = "aarch64", target_arch = "x86_64")))]
    assert_eq!(PortableKernel::current_arch_tag(), "other");
}

// MARK: - §4 Conformance gate

/// Math output is byte-identical to the scalar reference even with
/// telemetry disabled — proof that adding the emit call does not affect
/// the kernel's mathematical behavior.
#[test]
fn factory_kernel_hamming_distance_matches_scalar() {
    Intellectus::set_enabled(false);

    use substrate_kernel::kernel::ScalarKernel;
    let factory = PortableKernel::for_current_platform();
    let scalar = ScalarKernel::new();

    let a = Fingerprint256::new(0xCAFE_BABE, 0xDEAD_BEEF, 0x0123_4567_89AB_CDEF, 0xFEDC_BA98_7654_3210);
    let b = Fingerprint256::new(0x1234_5678, 0x9ABC_DEF0, 0x0F0F_0F0F_0F0F_0F0F, 0xF0F0_F0F0_F0F0_F0F0);

    assert_eq!(
        factory.hamming_distance_256(&a, &b),
        scalar.hamming_distance_256(&a, &b),
        "factory kernel must produce scalar-identical Hamming distance"
    );
}

/// OR-reduce conformance with telemetry disabled.
#[test]
fn factory_kernel_or_reduce_matches_scalar() {
    Intellectus::set_enabled(false);

    use substrate_kernel::kernel::ScalarKernel;
    let factory = PortableKernel::for_current_platform();
    let scalar = ScalarKernel::new();

    let fps: Vec<Fingerprint256> = (0..32u64).map(|i| {
        Fingerprint256::new(
            i,
            i.wrapping_mul(0x9E3779B97F4A7C15),
            i.wrapping_mul(0xBF58476D1CE4E5B9),
            i.wrapping_mul(0x94D049BB133111EB),
        )
    }).collect();

    assert_eq!(
        factory.or_reduce_256(&fps),
        scalar.or_reduce_256(&fps),
        "factory kernel must produce scalar-identical OR-reduce"
    );
}

/// Conformance holds even with monitoring enabled — the math output
/// is unaffected by the telemetry emission.
#[test]
fn conformance_holds_when_monitoring_enabled() {
    let _guard = global_lock();
    use substrate_kernel::kernel::ScalarKernel;

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let factory = PortableKernel::for_current_platform();
    let scalar = ScalarKernel::new();

    let a = Fingerprint256::new(0xDEAD, 0xBEEF, 0xCAFE, 0xBABE);
    let b = Fingerprint256::new(0xFACE, 0xFEED, 0xC0DE, 0xD00D);

    // Math output must be identical to scalar.
    assert_eq!(
        factory.hamming_distance_256(&a, &b),
        scalar.hamming_distance_256(&a, &b),
        "math must be unaffected by telemetry being enabled"
    );

    // One metric was emitted (proves the monitoring path ran).
    assert_eq!(sink.count(), 1,
        "telemetry must still emit when enabled during conformance test");

    // Restore defaults.
    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}
