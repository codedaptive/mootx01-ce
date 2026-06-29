// AsOfCoordinate.swift
//
// Temporal query parameter for as-of reads per ADR-017 §15–§17.
// AsOfCoordinate is a discriminated value — `.present` means
// "the live state now" and `.asOf(hlc)` means "the state at
// this HLC." This prevents the class of bug where a caller
// passes a zero HLC meaning "present" and the filter interprets
// it as "the dawn of time."

import Foundation

/// Temporal coordinate for a substrate read operation.
///
/// Every as-of read carries an `AsOfCoordinate` that says "now"
/// or "at this HLC." The enum discriminant prevents zero-HLC
/// ambiguity — `.present` is always present, never confused
/// with an HLC at the epoch.
public enum AsOfCoordinate: Hashable, Sendable, Codable {
    /// Read the current live state.
    case present

    /// Read the state as it was at the given HLC.
    case asOf(HLC)

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case kind
        case hlc
    }

    private enum Kind: String, Codable {
        case present
        case asOf
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .present:
            self = .present
        case .asOf:
            let hlc = try container.decode(HLC.self, forKey: .hlc)
            self = .asOf(hlc)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .present:
            try container.encode(Kind.present, forKey: .kind)
        case .asOf(let hlc):
            try container.encode(Kind.asOf, forKey: .kind)
            try container.encode(hlc, forKey: .hlc)
        }
    }
}
