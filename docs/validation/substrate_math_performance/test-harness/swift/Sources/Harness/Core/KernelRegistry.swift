// KernelRegistry.swift
//
// Enumeration of every kernel actually available on this build.
// The `--all` mode of stress-test iterates this list. New
// candidate kernels register themselves here so they pick up
// the full benchmark sweep automatically.
//
// On Apple platforms, every kernel listed here is always
// available (the Swift package always compiles the SIMD path,
// the Metal path, and so on once they exist). Future kernels
// with platform requirements (e.g. an AVX-512 shim for x86_64
// Linux Swift, if such a thing ever ships) will gate their
// entries with #if predicates here.
//
// Mirror of test-harness/rust/src/harness/kernel_registry.rs.

import Foundation
import GeniusLocusReference

public enum KernelRegistry {

    /// Ordered list of kernel kinds available on this build.
    /// The order is stable across runs so JSON output is
    /// reproducible.
    public static func available() -> [KernelKind] {
        var out: [KernelKind] = [.scalar]
        // SimdKernel ships unconditionally on Apple platforms
        // because `import simd` is part of the SDK on every
        // supported target. If a future port needs to gate it,
        // do it here.
        out.append(.simd)
        // NeonKernel uses `import simd` which is broadly
        // available, but the kernel is meaningful only on
        // aarch64 (NEON instructions). Gate on the arch check
        // to avoid sweeping a kernel that just duplicates the
        // scalar codepath on non-aarch64.
        #if canImport(simd) && arch(arm64)
        out.append(.neon)
        #endif
        // MetalKernel needs the Metal framework AND a usable
        // GPU at runtime. On hosts where MTLCreateSystemDefault
        // returns nil (headless CI, virtualization), don't
        // register it; the dispatcher would fall through to
        // scalar and that's misleading in a benchmark sweep.
        #if canImport(Metal)
        if MetalKernel() != nil {
            out.append(.metal)
        }
        #endif
        return out
    }
}
