// Match.swift
//
// Result type for nearest-neighbor and within-distance queries.

import Foundation

/// A single match from a similarity query. `index` is the
/// position of the matched candidate in the input array;
/// `distance` is the Hamming distance from the probe.
///
/// Matches are ordered by distance ascending, with ties broken
/// by index ascending. Two matches are equal when both index
/// and distance agree.
public struct Match: Hashable, Sendable, Codable {
    public let index: Int
    public let distance: Int

    public init(index: Int, distance: Int) {
        self.index = index
        self.distance = distance
    }
}

extension Match: Comparable {
    public static func < (lhs: Match, rhs: Match) -> Bool {
        if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
        return lhs.index < rhs.index
    }
}
