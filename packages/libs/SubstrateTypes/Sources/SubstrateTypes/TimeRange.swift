// TimeRange.swift
//

// Moved from SubstrateLib/Sources/SubstrateLib/MomentSummary.swift.
//
// Closed HLC interval [start, end]. Pure data; the MomentSummary
// primitive that consumes TimeRange windows stays in SubstrateLib.

import Foundation

public struct TimeRange: Sendable, Equatable {
    /// HLC lower bound, inclusive.
    public let start: HLC
    /// HLC upper bound, inclusive.
    public let end: HLC

    public init(start: HLC, end: HLC) {
        precondition(!(end < start), "TimeRange end must not precede start")
        self.start = start
        self.end = end
    }

    /// Returns true if the supplied HLC is within [start, end].
    public func contains(_ hlc: HLC) -> Bool {
        return !(hlc < start) && !(end < hlc)
    }
}
