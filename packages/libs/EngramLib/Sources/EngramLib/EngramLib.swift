// EngramLib.swift
//
// Public API surface. Consumers import EngramLib and call the
// static methods on EngramLib. The underlying kernel selection,
// dispatcher, and reference implementations are not exposed.
//
// Threading model: EngramLib is stateless and thread-safe. Every
// public method creates and discards its own kernel instance. For
// hot loops that benefit from kernel reuse, consumers can hold an
// `EngramLib.Session` and call methods on it.

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
import SubstrateTypes
import SubstrateKernel

// Phase 4.3 (decision 2026-05-28 §6.4.3): cache the kernel at
// module scope. The kernel is stateless and Sendable; resolving it
// per-call (the previous behavior) was a needless dispatch cost on
// the static API hot path.
@usableFromInline
internal let _engramLibCachedKernel: any SubstrateKernel = PortableKernel.kernelForCurrentPlatform()

/// 256-bit engram. The substrate-native representation is
/// currently `Fingerprint256` (four 64-bit blocks). Future
/// substrate versions may use a wider representation
/// (`Fingerprint512`); the `Engram` typealias is the stable
/// public name so product code does not need to change.
///
/// Construct via the `Engram` initializers below, not by reaching
/// into the underlying representation.
public typealias Engram = Fingerprint256

extension Engram {
    /// Construct an engram from four 64-bit blocks. The blocks
    /// carry different aspects of similarity (bitmap, lattice,
    /// lineage+temporal, channel+source) but product code treats
    /// the engram opaquely.
    public init(blocks b0: UInt64, _ b1: UInt64, _ b2: UInt64, _ b3: UInt64) {
        self.init(block0: b0, block1: b1, block2: b2, block3: b3)
    }
}

/// EngramLib is the product-facing API for similarity, retrieval,
/// and bit-tensor operations over engrams.
///
/// All methods are stateless and thread-safe. Internally the kit
/// selects the optimal kernel for the current platform. Consumers
/// do not see kernel types or dispatcher decisions.
///
/// Quick example:
///
/// ```swift
/// let probe = Engram(blocks: 0xDEAD, 0xBEEF, 0xCAFE, 0xBABE)
/// let estate: [Engram] = loadFromStore()
/// let matches = EngramLib.findNearest(probe: probe,
///                                      in: estate,
///                                      k: 10)
/// ```
public enum EngramLib {

    // MARK: - Distance

    /// Hamming distance between two engrams. Range: 0...256.
    /// Identical engrams return 0; bit-inverses return 256.
    public static func distance(_ a: Engram, _ b: Engram) -> Int {
        return kernel().hammingDistance256(a, b)
    }

    /// Hamming distance from probe to every candidate. Returns an
    /// array with the same count and indexing as `candidates`.
    /// Returns an empty array if `candidates` is empty.
    public static func distances(probe: Engram,
                                 candidates: [Engram]) -> [Int] {
        guard !candidates.isEmpty else { return [] }
        return kernel().hammingDistanceBatch(
            probe: probe, candidates: candidates)
    }

    // MARK: - Nearest neighbor

    /// Find the k nearest candidates to the probe by Hamming
    /// distance. Returns up to k matches sorted by distance
    /// ascending, with ties broken by candidate index ascending.
    ///
    /// - Returns: empty array if `candidates` is empty or `k <= 0`.
    ///            Otherwise returns min(k, candidates.count) matches.
    public static func findNearest(probe: Engram,
                                   in candidates: [Engram],
                                   k: Int) -> [Match] {
        guard k > 0, !candidates.isEmpty else { return [] }
        let raw = kernel().hammingTopK(
            probe: probe, candidates: candidates, k: k)
        return raw.map { Match(index: $0.index, distance: $0.distance) }
    }

    /// Find the single nearest candidate to the probe. Convenience
    /// wrapper over `findNearest(probe:in:k:)` with k=1.
    ///
    /// - Returns: nil if `candidates` is empty.
    public static func findNearest(probe: Engram,
                                   in candidates: [Engram]) -> Match? {
        return findNearest(probe: probe, in: candidates, k: 1).first
    }

    // MARK: - Filtering

    /// Find all candidates within `maxDistance` of the probe.
    /// Returns matches sorted by distance ascending, ties broken
    /// by candidate index ascending.
    ///
    /// - Parameter maxDistance: inclusive upper bound (0...256).
    public static func findWithin(probe: Engram,
                                  in candidates: [Engram],
                                  maxDistance: Int) -> [Match] {
        guard !candidates.isEmpty, maxDistance >= 0 else { return [] }
        let ds = distances(probe: probe, candidates: candidates)
        var hits: [Match] = []
        hits.reserveCapacity(min(candidates.count, 64))
        for i in 0..<ds.count where ds[i] <= maxDistance {
            hits.append(Match(index: i, distance: ds[i]))
        }
        hits.sort { lhs, rhs in
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            return lhs.index < rhs.index
        }
        return hits
    }

    // MARK: - Aggregation

    /// Bitwise OR-reduction across a set of engrams. The result
    /// has a 1-bit at every position where at least one input had
    /// a 1-bit. Returns the zero engram for an empty input.
    ///
    /// Use case: building cohort engrams, computing the union of
    /// a set's structural features.
    public static func union(_ engrams: [Engram]) -> Engram {
        return kernel().orReduce256(engrams)
    }

    /// Pairwise OR of two engrams.
    public static func union(_ a: Engram, _ b: Engram) -> Engram {
        return a.union(b)
    }

    // MARK: - Session

    /// A long-lived session that holds a kernel instance for
    /// reuse across many calls. Equivalent in result to the
    /// stateless static methods; faster when the same kernel is
    /// needed across thousands of operations in a hot loop.
    ///
    /// Sessions are `Sendable` and safe to share across tasks.
    public struct Session: Sendable {
        let k: any SubstrateKernel

        public init() {
            self.k = _engramLibCachedKernel
        }

        public func distance(_ a: Engram, _ b: Engram) -> Int {
            return k.hammingDistance256(a, b)
        }

        public func distances(probe: Engram,
                              candidates: [Engram]) -> [Int] {
            guard !candidates.isEmpty else { return [] }
            return k.hammingDistanceBatch(
                probe: probe, candidates: candidates)
        }

        public func findNearest(probe: Engram,
                                in candidates: [Engram],
                                k: Int) -> [Match] {
            guard k > 0, !candidates.isEmpty else { return [] }
            let raw = self.k.hammingTopK(
                probe: probe, candidates: candidates, k: k)
            return raw.map { Match(index: $0.index, distance: $0.distance) }
        }

        public func findWithin(probe: Engram,
                               in candidates: [Engram],
                               maxDistance: Int) -> [Match] {
            guard !candidates.isEmpty, maxDistance >= 0 else { return [] }
            let ds = self.distances(probe: probe, candidates: candidates)
            var hits: [Match] = []
            hits.reserveCapacity(min(candidates.count, 64))
            for i in 0..<ds.count where ds[i] <= maxDistance {
                hits.append(Match(index: i, distance: ds[i]))
            }
            hits.sort { lhs, rhs in
                if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
                return lhs.index < rhs.index
            }
            return hits
        }

        public func union(_ engrams: [Engram]) -> Engram {
            return k.orReduce256(engrams)
        }
    }

    /// Create a reusable session. Equivalent to `Session()`.
    public static func session() -> Session {
        return Session()
    }

    // MARK: - Internal

    @inline(__always)
    private static func kernel() -> any SubstrateKernel {
        return _engramLibCachedKernel
    }
}
