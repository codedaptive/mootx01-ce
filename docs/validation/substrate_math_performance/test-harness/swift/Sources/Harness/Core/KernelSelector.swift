// KernelSelector.swift
//
// Global kernel selector for the test harness. Per
// measured SIMD OR-reduce selection, the
// harness binaries (gen-vectors, validate-vectors, stress-test)
// accept a `--kernel <name>` flag. The flag's value lives here
// as a global, and primitives consult `KernelSelector.current()`
// when they need a `SubstrateKernel` instance.
//
// This is a global because the alternative is threading a kernel
// parameter through every `PrimitiveDescriptor.generate` and
// `.validate` signature, plus through every internal helper. The
// global is read-only at primitive-call time (set once in main,
// read many times in primitive code) and has no thread-safety
// concerns under the harness's single-threaded execution model.
//
// Primitives that do NOT use the kernel layer (e.g. lattice ops,
// HLC, audit log fold) ignore this entirely.

import Foundation
import GeniusLocusReference

public enum KernelSelector {
    // `nonisolated(unsafe)` is correct here: the harness binaries
    // set this once in `main` after parsing `--kernel`, then read
    // it from primitive code under the harness's single-threaded
    // execution model. The Swift 6 strict-concurrency checker
    // can't see the set-once invariant, so we declare it unsafe
    // and own the discipline at the call sites.
    private nonisolated(unsafe) static var _kind: KernelKind = .scalar

    /// Set the selected kernel kind. Call once from `main` after
    /// parsing `--kernel <name>`.
    public static func set(_ kind: KernelKind) {
        _kind = kind
    }

    /// The currently-selected kernel kind.
    public static func kind() -> KernelKind {
        return _kind
    }

    /// Resolve the selected kernel to a concrete `SubstrateKernel`
    /// instance. Allocates a fresh instance per call; instances
    /// are stateless.
    public static func current() -> SubstrateKernel {
        return PortableKernel.kernel(of: _kind)
    }

    /// Parse the `--kernel` flag value into a `KernelKind`.
    /// Returns nil for unrecognized names.
    public static func parse(_ name: String) -> KernelKind? {
        return KernelKind(rawValue: name)
    }
}
