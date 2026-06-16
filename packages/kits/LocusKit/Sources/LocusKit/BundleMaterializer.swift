// BundleMaterializer.swift
//
// Recomputes the bundle-algebra count-vector aggregates from drawers.
// This is the first real caller of countFold256 and the consumer side
// of the drawer-to-fingerprint derivation. It materializes Bundle A,
// the active centroid, per room and rolls it up to the wing.
//
// Bundle A cannot be maintained incrementally, because active
// membership changes and the fold does not subtract, so it is
// recomputed: gather the active drawers under a node, derive their
// fingerprints, and fold them into a count-vector. The per-row
// fingerprints are computed on demand here and discarded; only the
// aggregate is stored. In the running system this recompute is a
// Dreaming tick (temporal compression / cognition bundle export); the
// materializer is the operation that tick invokes.

import Foundation
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib
import SubstrateTypes
import SubstrateKernel

public struct BundleMaterializer {

    let drawers: DrawerStore
    let bundles: NodeBundleStore
    let families: EstateFingerprintFamilies
    let kernel: any SubstrateKernel

    public init(drawers: DrawerStore,
                bundles: NodeBundleStore,
                families: EstateFingerprintFamilies,
                kernel: any SubstrateKernel = PortableKernel.kernelForCurrentPlatform()) {
        self.drawers = drawers
        self.bundles = bundles
        self.families = families
        self.kernel = kernel
    }

    /// Recompute Bundle A for one room: fold the room's active drawers
    /// into a count-vector and store it. Returns the count-vector.
    ///
    /// Bundle A is the "active centroid" per cookbook §11.5: a fold over
    /// the room's Cluster A drawers (active / pending / contested /
    /// accepted). `drawersIn` returns ALL non-tombstoned rows including
    /// superseded / withdrawn / decayed / expired / rejected, so we
    /// filter to `State.isClusterA` before folding. (Rust mirror
    /// pushes this responsibility outward by taking a pre-filtered
    /// `&[&Drawer]` parameter; Swift fetches internally and applies
    /// the filter here for caller convenience.)
    @discardableResult
    public func materializeRoom(wing: String, room: String,
                                now: Date = Date()) async throws -> CountVector256 {
        let all = try await drawers.drawersIn(wing: wing, room: room)
        let active = all.filter { $0.state.isClusterA }
        let fingerprints = active.map { families.fingerprint(of: $0) }
        let cv = kernel.countFold256(fingerprints)
        try await bundles.put(wing: wing, room: room, kind: .activeA, cv, now: now)
        return cv
    }

    /// Roll Bundle A up to the wing by merging its already-materialized
    /// room bundles. By the count-vector's associativity this equals
    /// the direct fold of every active drawer in the wing, so callers
    /// may materialize rooms in any order and roll up afterward.
    /// Returns the wing-level count-vector.
    @discardableResult
    public func rollUpWing(wing: String, now: Date = Date()) async throws -> CountVector256 {
        let roomBundles = try await bundles.rooms(forWing: wing, kind: .activeA)
        var acc = CountVector256()
        for entry in roomBundles {
            acc.merge(entry.bundle)
        }
        try await bundles.put(wing: wing, room: "", kind: .activeA, acc, now: now)
        return acc
    }
}
