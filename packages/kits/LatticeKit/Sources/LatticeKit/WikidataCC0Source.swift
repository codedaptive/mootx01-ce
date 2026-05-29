// WikidataCC0Source.swift
//
// Loads the CC0 Wikidata concept seed and turns each entry into a
// `SourceConcept` for the assembler. The seed is the 2026-entry file
// shipped in EideticLib's resources
// (EideticLib/Sources/EideticLib/Resources/WikidataSubset.json), license
// CC0 1.0. LatticeKit does NOT import EideticLib: the executable resolves
// the file path at runtime and hands it in, and this type models the
// data shape only. The default path is resolved relative to this
// source file so a developer- or CI-run build finds the seed without
// a flag, while `--seed <path>` overrides it.
//
// The one place a UDC hint is consulted. Each seed entry carries a
// `udc_hint` — a UDC code string such as "5", "510", or "004.7". MDCC
// is not UDC and carries no UDC codes forward; the hint is used purely
// as a class-level bucketing signal to pick the concept's MDCC spine
// class. The mapping is deliberately coarse: the leading decimal digit
// of the hint selects the spine class (UDC main class N -> MDCC base
// N*100), because UDC's top-level division (0 Generalities, 1
// Philosophy, ... 9 Geography/History) is Dewey-shaped and lines up
// one-to-one with the MDCC spine. Everything below the first digit is
// ignored — leaf placement comes from the subclass/instance graph, not
// from the UDC notation. A hint that does not begin with a digit (or
// is absent) yields no pin, leaving the concept to inherit its class
// from the collapsed parent graph.

import Foundation

/// Loader and concept-mapper for the CC0 Wikidata seed.
public enum WikidataCC0Source {

    /// The decoded seed file. Mirrors the on-disk JSON shape. Only the
    /// fields the pipeline needs are modelled; `source_notes` and other
    /// commentary fields are ignored on decode.
    public struct Seed: Sendable, Codable {
        public let schemaVersion: String
        public let dataVersion: String
        public let licenseNote: String
        public let entries: [Entry]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case dataVersion = "data_version"
            case licenseNote = "license_note"
            case entries
        }
    }

    /// A single seed entry. `udcHint` is the class-level bucketing
    /// signal described in the file header; `sourceSection` records
    /// which pass of the seed assembly produced the row and is carried
    /// for provenance only.
    public struct Entry: Sendable, Codable {
        public let qid: String
        public let label: String
        public let aliases: [String]
        public let udcHint: String?
        public let sourceSection: String?

        private enum CodingKeys: String, CodingKey {
            case qid
            case label
            case aliases
            case udcHint = "udc_hint"
            case sourceSection = "source_section"
        }
    }

    /// Maps a UDC hint to an MDCC spine class base, or nil when no pin
    /// applies. The leading decimal digit selects the class: "0" -> 0,
    /// "5" -> 500, "510" -> 500, "004.7" -> 0. A hint with no leading
    /// digit, or an absent hint, returns nil so the concept inherits
    /// its class from the parent graph rather than being force-pinned.
    /// The returned base is validated against the spine, so a malformed
    /// hint can never produce a base that no class owns.
    public static func pinnedClassBase(forUDCHint hint: String?) -> Int? {
        guard let hint, let first = hint.first, let digit = first.wholeNumberValue else {
            return nil
        }
        let base = digit * 100
        // Guard against a stray two-digit lead or any value the spine
        // does not own; wholeNumberValue on a single Character is 0...9,
        // so base is already in 0...900, but validate explicitly so the
        // contract holds if the parse ever widens.
        return NotationSpine.owningClass(forBase: base) != nil ? base : nil
    }

    /// Builds a `SourceConcept` from a seed entry. The Wikidata Q-ID is
    /// the stable source identity; the label is the human-readable
    /// English name; the pinned class base is derived from the UDC hint.
    public static func concept(from entry: Entry) -> SourceConcept {
        SourceConcept(
            sourceIdentity: entry.qid,
            label: entry.label,
            pinnedClassBase: pinnedClassBase(forUDCHint: entry.udcHint)
        )
    }

    /// Maps every seed entry to a `SourceConcept`, preserving file order.
    public static func concepts(from seed: Seed) -> [SourceConcept] {
        seed.entries.map(concept(from:))
    }

    /// Decodes a seed from raw JSON data.
    public static func decodeSeed(from data: Data) throws -> Seed {
        try JSONDecoder().decode(Seed.self, from: data)
    }

    /// Loads and decodes the seed file at an explicit path.
    public static func loadSeedFile(at path: String) throws -> Seed {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try decodeSeed(from: data)
    }

    /// The default seed path: EideticLib's committed CC0 resource,
    /// resolved relative to this source file so both the test target
    /// and the `mdcc-build` executable find it without configuration.
    /// This file lives at `<repo>/packages/kits/LatticeKit/Sources/LatticeKit/`,
    /// so the repo root is six directories up. EideticLib is a lib,
    /// not a kit, so its resource path includes `packages/libs/`.
    public static func defaultSeedPath() -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()   // LatticeKit/Sources/LatticeKit
            .deletingLastPathComponent()   // LatticeKit/Sources
            .deletingLastPathComponent()   // LatticeKit
            .deletingLastPathComponent()   // packages/kits
            .deletingLastPathComponent()   // packages
            .deletingLastPathComponent()   // <repo root>
        return repoRoot
            .appendingPathComponent("packages/libs/EideticLib/Sources/EideticLib/Resources/WikidataSubset.json")
            .path
    }

    /// Convenience cold load: decodes the default seed file and maps it
    /// to `SourceConcept` values. Used by tests and by the executable's
    /// default (no `--seed`) path.
    public static func loadSeed() throws -> [SourceConcept] {
        let seed = try loadSeedFile(at: defaultSeedPath())
        return concepts(from: seed)
    }
}
