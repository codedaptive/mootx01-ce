// src/harness/kernel_selector.rs
//
// Global kernel selector for the Rust test harness. Mirror of
// the Swift `KernelSelector` in
// `test-harness/swift/Sources/Harness/Core/KernelSelector.swift`.
//
// The three harness binaries (gen-vectors, validate-vectors,
// stress-test) accept a `--kernel <name>` flag. The flag's
// value lives here as a process-global, and primitive code
// consults `current()` when it needs a `SubstrateKernel`.
//
// This is a global because the alternative is threading a
// kernel parameter through every PrimitiveDescriptor.generate
// and .validate signature plus every internal helper. The
// global is set once in `main` (after argv parsing) and read
// many times in primitive code. The harness runs single-
// threaded, so the OnceLock + atomic pattern below is overkill
// for thread safety but cheap and tidy.
//
// See DECISION_OR_REDUCE_BACKENDS_2026-05-17.md for the
// rationale on per-op kernel selection.

use std::sync::atomic::{AtomicU8, Ordering};
use substrate_kernel::kernel::{KernelKind, PortableKernel, SubstrateKernel};

// Stored as a u8 so we can use a plain atomic and avoid a Mutex.
// Encoding mirrors KernelKind::parse / as_str.
static KIND: AtomicU8 = AtomicU8::new(0); // 0 = Scalar (default)

fn encode(kind: KernelKind) -> u8 {
    match kind {
        KernelKind::Scalar => 0,
        KernelKind::Simd   => 1,
        KernelKind::Neon   => 2,
        KernelKind::Avx512 => 3,
        KernelKind::Avx2   => 4,
    }
}

fn decode(v: u8) -> KernelKind {
    match v {
        1 => KernelKind::Simd,
        2 => KernelKind::Neon,
        3 => KernelKind::Avx512,
        4 => KernelKind::Avx2,
        _ => KernelKind::Scalar,
    }
}

/// Set the selected kernel kind. Call once from `main` after
/// parsing `--kernel <name>`.
pub fn set(kind: KernelKind) {
    KIND.store(encode(kind), Ordering::Relaxed);
}

/// The currently-selected kernel kind.
pub fn kind() -> KernelKind {
    decode(KIND.load(Ordering::Relaxed))
}

/// Resolve the selected kernel to a concrete `Box<dyn SubstrateKernel>`.
/// Allocates a fresh instance per call; instances are stateless.
pub fn current() -> Box<dyn SubstrateKernel> {
    PortableKernel::of_kind(kind())
}

/// Parse a CLI flag value into a `KernelKind`. Returns None for
/// unrecognized names. Delegates to `KernelKind::parse` so the
/// recognized-names list is in one place.
pub fn parse(name: &str) -> Option<KernelKind> {
    KernelKind::parse(name)
}
