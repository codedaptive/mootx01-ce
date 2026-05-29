// Canon.swift
//
// In-memory representation of an MDCC canon. A canon is a frozen
// snapshot of the (code -> concept) mapping plus enough metadata to
// reproduce or audit the build that produced it.
//
// The canon serves two distribution channels (LAUNCH_PLAN.md §MDCC):
//
//   - Fast-codes channel: people pull this frequently. It is the
//     codes table — code, source identity, label, owning class. Tiny
//     payload, suitable for daily polling.
//
//   - Slow-docs channel: the documented canon. It carries the spine
//     scope notes, reserved-range descriptions, deprecation notes,
//     and any release commentary. Pulled at canon-cut cadence
//     (quarterly), not continuously.
//
// Channel emitters live in Channels.swift. This file defines the
// in-memory canon and the bundled-resource loader.

import Foundation

/// A single resolved concept in the canon. The code is its MDCC code,
/// the source identity is the CC0 anchor that justifies the
/// assignment, and the label is the human-readable English name.
public struct LatticeEntry: Sendable, Hashable, Codable {
    public let code: String
    public let sourceIdentity: String
    public let label: String
    public let classBase: Int

    public init(code: String, sourceIdentity: String, label: String, classBase: Int) {
        self.code = code
        self.sourceIdentity = sourceIdentity
        self.label = label
        self.classBase = classBase
    }
}

/// An MDCC canon — the frozen output of an assembler run, indexed
/// for fast lookup.
public struct LatticeCanon: Sendable, Codable {
    public let canonVersion: String
    public let entries: [LatticeEntry]

    private let byCode: [String: LatticeEntry]
    private let bySourceIdentity: [String: LatticeEntry]

    public init(canonVersion: String, entries: [LatticeEntry]) {
        self.canonVersion = canonVersion
        self.entries = entries
        var bc: [String: LatticeEntry] = [:]
        var bs: [String: LatticeEntry] = [:]
        for entry in entries {
            bc[entry.code] = entry
            bs[entry.sourceIdentity] = entry
        }
        self.byCode = bc
        self.bySourceIdentity = bs
    }

    /// Codable conformance — recompute the indexes from the entry
    /// array on decode, rather than storing them in the JSON.
    private enum CodingKeys: String, CodingKey {
        case canonVersion
        case entries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(String.self, forKey: .canonVersion)
        let entries = try container.decode([LatticeEntry].self, forKey: .entries)
        self.init(canonVersion: version, entries: entries)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(canonVersion, forKey: .canonVersion)
        try container.encode(entries, forKey: .entries)
    }

    /// Returns the entry for a given code, or nil if the code is not
    /// resolved by this canon. A nil return does not imply malformed:
    /// the code may be well-formed but valid-but-unknown.
    public func entry(for code: String) -> LatticeEntry? {
        byCode[code]
    }

    /// Returns the entry for a source identity, or nil if no entry in
    /// this canon resolves to it.
    public func entry(forSourceIdentity identity: String) -> LatticeEntry? {
        bySourceIdentity[identity]
    }

    // Bundled canon loader. The v1 canon JSON file lives in
    // Sources/LatticeKit/Resources/LatticeCanonV1.json. Build-time resource
    // processing places it inside the kit's Bundle.module.
    static func loadBundledV1() -> LatticeCanon? {
        guard let url = Bundle.module.url(
                forResource: "LatticeCanonV1",
                withExtension: "json"
        ) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url),
              let canon = try? JSONDecoder().decode(LatticeCanon.self, from: data) else {
            return nil
        }
        return canon
    }
}
