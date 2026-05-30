// Channels.swift
//
// The two MDCC distribution channels:
//
//   - Fast-codes: a compact JSON payload pulled frequently. Includes
//     only what a resolver needs to map a code to a source identity
//     and a label. No prose, no scope notes.
//
//   - Slow-docs: a markdown rendering of the canon spine, reserved
//     ranges, and entries. Pulled at canon cadence (quarterly).
//
// Both channels are pure functions of a canon plus the bundled
// spine and reservation tables. Emitting them is deterministic —
// the JSON output of the fast channel has stable key ordering, and
// the markdown of the slow channel walks the spine in fixed order.

import Foundation

/// Fast-codes channel payload. A flat array, sorted by code.
public struct FastCodesPayload: Sendable, Codable {
    public let canonVersion: String
    public let codes: [Row]

    public struct Row: Sendable, Codable, Hashable {
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

    public init(canonVersion: String, codes: [Row]) {
        self.canonVersion = canonVersion
        self.codes = codes
    }
}

/// Channel emitters. Pure functions over the canon — given the same
/// canon, they always produce the same bytes.
public enum Channels {

    /// Builds the fast-codes payload from a canon. Rows are sorted
    /// by code so encoded output is byte-stable across runs.
    public static func fastCodes(from canon: LatticeCanon) -> FastCodesPayload {
        let rows = canon.entries
            .sorted { $0.code < $1.code }
            .map { entry in
                FastCodesPayload.Row(
                    code: entry.code,
                    sourceIdentity: entry.sourceIdentity,
                    label: entry.label,
                    classBase: entry.classBase
                )
            }
        return FastCodesPayload(canonVersion: canon.canonVersion, codes: rows)
    }

    /// Encodes the fast-codes payload as deterministic JSON. Sorted
    /// keys, no escape-slash trickery, UTF-8 bytes. The same canon
    /// produces the same JSON bytes on every machine.
    public static func encodeFastCodes(_ payload: FastCodesPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    /// Builds the slow-docs channel markdown for a canon. The
    /// document walks the spine in order, lists reserved ranges per
    /// class, and enumerates the entries assigned to each class.
    public static func slowDocs(from canon: LatticeCanon) -> String {
        var out = ""
        out += "# MDCC \(canon.canonVersion) — Documented Canon\n\n"
        out += "Moot Decimal Classification Codes — the documented release of canon \(canon.canonVersion). "
        out += "This document is the slow channel: it is pulled at canon-cut cadence (quarterly), not "
        out += "continuously. For the fast machine-readable channel, see LatticeCodesV1.json.\n\n"

        out += "## Top-of-tree spine\n\n"
        for cls in NotationSpine.classes {
            out += "### \(cls.renderedBase) — \(cls.name)\n\n"
            out += "\(cls.scopeNote)\n\n"

            let classReservations = ReservedRanges.table
                .filter { $0.lowerBound >= cls.base && $0.upperBound < cls.base + 100 }
            if !classReservations.isEmpty {
                out += "**Reserved ranges:**\n\n"
                for r in classReservations {
                    out += "- \(String(format: "%03d", r.lowerBound))-"
                    out += "\(String(format: "%03d", r.upperBound)) (\(r.kind.rawValue)): \(r.note)\n"
                }
                out += "\n"
            }

            let classEntries = canon.entries
                .filter { $0.classBase == cls.base }
                .sorted { $0.code < $1.code }
            if !classEntries.isEmpty {
                out += "**Entries:**\n\n"
                for entry in classEntries {
                    out += "- `\(entry.code)` \(entry.label) [\(entry.sourceIdentity)]\n"
                }
                out += "\n"
            }
        }

        out += "## Channels\n\n"
        out += "- Fast-codes (`LatticeCodesV1.json`) — pull frequently; tiny payload.\n"
        out += "- Slow-docs (`LatticeDocsV1.md`) — pull at canon-cut cadence.\n"
        return out
    }
}
