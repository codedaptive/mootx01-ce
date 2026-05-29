// RandomWalks.swift
//
// Random walks with restart on the estate graph, per cookbook
// § 7.4.
//
// A random walk starts at a designated row, repeatedly samples a
// next row from the current row's weighted out-edges (or restarts
// to the start row with probability `restartProb`), and records
// the visited sequence. The result is consumed by CognitionKit's
// exploratory recall primitives (deferred to v0.37 per cookbook
// § 19.1).
//
// The substrate uses SplitMix64 as the random number generator
// (mirroring the test harness's deterministic PRNG); calls with
// the same `(adjacency, start, length, restartProb, seed)` produce
// the same walk in both reference language ports.
//
// Cookbook references:
//   § 7.4   Random walks (the spec)
//   § 8.5   OR-reduction (downstream consumer for walk-aggregate
//           fingerprints)
//   § 19.1  v0.37 deferred: recall_exploratory primitive

import Foundation
import SubstrateTypes

public enum RandomWalks {

    public typealias Adjacency = [[(neighbor: Int, weight: Double)]]

    public static let defaultRestartProb: Double = 0.15

    /// Run a single random walk. Returns the visited node indices
    /// including the start row. Length includes the start row;
    /// a walk of length 1 returns just `[start]`.
    public static func walk(
        adjacency: Adjacency,
        start: Int,
        length: Int,
        restartProb: Double = defaultRestartProb,
        seed: UInt64
    ) -> [Int] {
        precondition(start >= 0 && start < adjacency.count,
                     "start row out of range")
        precondition(length >= 1, "length must be at least 1")
        precondition(restartProb >= 0.0 && restartProb < 1.0,
                     "restartProb must be in [0, 1)")
        var rng = SplitMix64(seed: seed)
        var visited = [Int]()
        visited.reserveCapacity(length)
        var current = start
        for _ in 0..<length {
            visited.append(current)
            let next: Int
            if uniform01(&rng) < restartProb {
                next = start
            } else {
                let neighbors = adjacency[current]
                if neighbors.isEmpty {
                    next = start  // dead end ⇒ restart
                } else {
                    next = sampleWeighted(neighbors, rng: &rng)
                }
            }
            current = next
        }
        return visited
    }

    /// Sample a neighbor proportional to edge weight. Negative
    /// weights are treated as zero (the substrate does not use
    /// negative weights, but the reference is defensive).
    @inlinable
    public static func sampleWeighted(
        _ neighbors: [(neighbor: Int, weight: Double)],
        rng: inout SplitMix64
    ) -> Int {
        var total = 0.0
        for (_, w) in neighbors { if w > 0 { total += w } }
        if total <= 0.0 {
            // Uniform fallback.
            let idx = Int(rng.next() % UInt64(neighbors.count))
            return neighbors[idx].neighbor
        }
        let pick = uniform01(&rng) * total
        var acc = 0.0
        for (j, w) in neighbors {
            if w > 0 {
                acc += w
                if pick <= acc { return j }
            }
        }
        return neighbors.last!.neighbor   // fallback for FP edge case
    }

    /// Uniform double in [0, 1). Same construction in Swift and
    /// Rust ports so cross-language reproducibility holds:
    /// take the high 53 bits of a u64 and scale.
    @inlinable
    public static func uniform01(_ rng: inout SplitMix64) -> Double {
        let bits = rng.next() >> 11    // 53 high bits
        return Double(bits) * (1.0 / Double(1 << 53))
    }

    /// Random walk with restart aggregating visits by row. Used
    /// by CognitionKit's recall_exploratory (cookbook § 19.1
    /// deferred-to-v0.37; reference here returns a usable result
    /// for harness tests). Takes a `[RowId: [RowId]]` adjacency
    /// rather than the indexed form because the cognition tier
    /// works in RowId space, not in densely-numbered graph nodes.
    ///
    /// Returns a dictionary mapping visited rowIds to visit counts.
    public static func walkWithRestart(
        seed: RowId,
        steps: Int,
        restartProbability: Float32,
        rngSeed: UInt64,
        adjacency: [RowId: [RowId]]
    ) -> [RowId: Int] {
        precondition(steps >= 1, "steps must be at least 1")
        precondition(restartProbability >= 0 && restartProbability < 1,
                     "restartProbability must be in [0, 1)")
        var rng = SplitMix64(seed: rngSeed)
        var visits: [RowId: Int] = [:]
        var current = seed
        for _ in 0..<steps {
            visits[current, default: 0] += 1
            let restart = uniform01(&rng) < Double(restartProbability)
            if restart {
                current = seed
            } else if let neighbors = adjacency[current], !neighbors.isEmpty {
                let idx = Int(rng.next() % UInt64(neighbors.count))
                current = neighbors[idx]
            } else {
                current = seed  // dead end ⇒ restart
            }
        }
        return visits
    }
}

// MARK: - SplitMix64 (mirror of harness/SplitMix64.swift)

public struct SplitMix64 {
    public var state: UInt64
    public init(seed: UInt64) { self.state = seed }
    public mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Properties
//
//   deterministic:     same (adj, start, length, restartProb, seed)
//                      → same walk.
//   start-in-walk:     walk[0] == start always.
//   length-respected:  len(walk) == length always.
//   range-respected:   every walk[i] is a valid row index.
//   restart-correct:   restartProb = 0 produces a walk with no
//                      restarts (apart from dead-end fallbacks);
//                      restartProb close to 1 produces walks that
//                      almost always return to start.
//
// MARK: - Cookbook references
//   § 7.4, § 8.5, § 19.1
