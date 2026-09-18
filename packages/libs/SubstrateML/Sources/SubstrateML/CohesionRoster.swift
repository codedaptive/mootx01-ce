// CohesionRoster.swift
//
// The integer bookkeeping behind the incremental anomaly sweep (ADR-026,
// GeniusLocusKit spec § CHESTS). A roster holds, for every member of a
// chest, the SUM of its quantised similarities to every other member.
// Cohesion is that sum divided by the peer count; the z-score against the
// chest's mean and standard deviation decides the anomalous flag.
//
// WHY integers: floating-point sums depend on the order they were added
// in, so an incremental roster and a batch recompute, or Swift and Rust,
// would drift apart at the last bit and could flip a flag at the threshold.
// Each pairwise similarity is quantised to 24-bit fixed point once
// (`quantise`), and sums are exact Int64 arithmetic: order-independent,
// reversible (remove subtracts exactly what add added), and identical on
// both ports. The statistics are then Float32 over identical integers in
// the same operation order.
//
// The roster does no similarity computation and reads no storage. The
// caller computes similarities in roster order and hands them in.

import Foundation

public struct CohesionRoster: Equatable, Sendable, Codable {
    public struct Entry: Equatable, Sendable, Codable {
        public let id: String
        public var digest: String
        public var sum: Int64
        public init(id: String, digest: String, sum: Int64) { self.id = id; self.digest = digest; self.sum = sum }
    }

    /// Similarities are quantised to 1/2²⁴; a similarity of 1.0 is `scale`.
    public static let scale: Int32 = 1 << 24

    /// Members in ascending id order. Every `similarities` argument below is
    /// aligned with this order.
    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries.sorted { $0.id < $1.id }
    }

    /// Quantise a similarity in 0...1 to fixed point. Out-of-range input is
    /// clamped; NaN reads as 0.
    @inlinable
    public static func quantise(_ similarity: Float32) -> Int32 {
        guard similarity.isFinite else { return 0 }
        let clamped = min(max(similarity, 0), 1)
        return Int32((clamped * Float32(scale)).rounded())
    }

    /// Add a member. `similarities[i]` is its quantised similarity to
    /// `entries[i]` (before the add). Each existing sum gains its value; the
    /// new member's sum is their total.
    public mutating func add(id: String, digest: String, similarities: [Int32]) {
        precondition(similarities.count == entries.count, "one similarity per existing member")
        var total: Int64 = 0
        for i in entries.indices {
            entries[i].sum += Int64(similarities[i])
            total += Int64(similarities[i])
        }
        let entry = Entry(id: id, digest: digest, sum: total)
        let at = entries.firstIndex { $0.id > id } ?? entries.count
        entries.insert(entry, at: at)
    }

    /// Remove a member. `similarities[i]` is its quantised similarity to
    /// the i-th REMAINING member, in order. Exactly undoes the add.
    public mutating func remove(id: String, similarities: [Int32]) {
        guard let at = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: at)
        precondition(similarities.count == entries.count, "one similarity per remaining member")
        for i in entries.indices {
            entries[i].sum -= Int64(similarities[i])
        }
    }

    /// Replace a member's content: remove with the old similarities, add
    /// with the new, under the new digest. Both lists are aligned with the
    /// roster without the member.
    public mutating func replace(id: String, digest: String, oldSimilarities: [Int32], newSimilarities: [Int32]) {
        remove(id: id, similarities: oldSimilarities)
        add(id: id, digest: digest, similarities: newSimilarities)
    }

    /// The anomalous flag per member, in roster order: cohesion = sum /
    /// (peers × scale); z against the roster's mean and population standard
    /// deviation; anomalous when z ≤ −threshold. Fewer than `minimumSize`
    /// members has no cohesion baseline: every flag is false.
    public func flags(threshold: Float32, minimumSize: Int = 3) -> [(id: String, anomalous: Bool)] {
        let count = entries.count
        guard count >= minimumSize else { return entries.map { ($0.id, false) } }
        let peers = Float32(count - 1) * Float32(Self.scale)
        var cohesion: [Float32] = []
        cohesion.reserveCapacity(count)
        for e in entries { cohesion.append(Float32(e.sum) / peers) }
        let n = Float32(count)
        var mean: Float32 = 0
        for c in cohesion { mean += c }
        mean /= n
        var variance: Float32 = 0
        for c in cohesion { let d = c - mean; variance += d * d }
        variance /= n
        let stddev = variance.squareRoot()
        return entries.indices.map { i in
            (entries[i].id, AnomalyDetection.zScore(value: cohesion[i], mean: mean, stddev: stddev) <= -threshold)
        }
    }
}
