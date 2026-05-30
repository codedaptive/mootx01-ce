// CanonWriter.swift
//
// Writes the four build artifacts of a canon-build run to a target
// directory, deterministically:
//
//   LatticeCanonV1.json     — the canon (code -> concept), the bundled
//                          resource the kit loads at runtime.
//   LatticeCodesV1.json     — the fast-codes channel (compact, code-sorted,
//                          pulled frequently).
//   LatticeDocsV1.md        — the slow-docs channel (documented spine,
//                          reserved ranges, entries) plus a provenance
//                          header naming the CC0 source and access date.
//   LatticeRegistryV1.json  — the persisted stable-key registry, so a
//                          rerun pins every previously assigned code.
//
// Determinism is the whole point: the same `AssemblerOutput` plus the
// same provenance produce byte-identical files on every machine. All
// JSON is encoded with sorted keys and unescaped slashes — the same
// settings Channels uses for the fast-codes channel — so key order is
// fixed and Q-ID URIs (if ever present) are not slash-escaped. Dates
// are never read from the clock here: the access date is supplied in
// the provenance by the caller, keeping the writer pure.

import Foundation

/// Provenance recorded alongside a build. All Wikidata statement data
/// is CC0 1.0; this records which source version produced the canon,
/// the license, the access date, and how the edge graph was obtained
/// (live endpoint, fixture, or none). The access date is supplied by
/// the caller — never read from the clock — so the writer stays
/// deterministic.
public struct BuildProvenance: Sendable, Codable, Equatable {
    /// The seed `data_version` (e.g. the CC0 Wikidata subset version),
    /// optionally annotated to mark a fixture-derived build.
    public let dataVersion: String
    /// The CC0 license note carried from the source.
    public let licenseNote: String
    /// ISO8601 calendar date (YYYY-MM-DD) the source was accessed,
    /// supplied by the caller.
    public let accessDate: String
    /// How the edge graph was obtained: "wikidata-endpoint", "fixture",
    /// or "none".
    public let edgeSourceKind: String

    public init(dataVersion: String, licenseNote: String, accessDate: String, edgeSourceKind: String) {
        self.dataVersion = dataVersion
        self.licenseNote = licenseNote
        self.accessDate = accessDate
        self.edgeSourceKind = edgeSourceKind
    }
}

/// The on-disk shape of the persisted stable-key registry. Carries the
/// canon version and build provenance alongside the entries so a rerun
/// can audit where the prior codes came from. Reloading drops back to
/// a plain `StableKeyRegistry` for the assembler.
public struct PersistedRegistry: Sendable, Codable {
    public let canonVersion: String
    public let provenance: BuildProvenance
    public let entries: [StableKeyEntry]

    public init(canonVersion: String, provenance: BuildProvenance, entries: [StableKeyEntry]) {
        self.canonVersion = canonVersion
        self.provenance = provenance
        self.entries = entries
    }
}

/// Writes and reloads canon-build artifacts.
public enum CanonWriter {

    /// The four artifact filenames, fixed for v1.
    public static let canonFilename = "LatticeCanonV1.json"
    public static let codesFilename = "LatticeCodesV1.json"
    public static let docsFilename = "LatticeDocsV1.md"
    public static let registryFilename = "LatticeRegistryV1.json"

    /// The deterministic JSON encoder shared by every artifact. Sorted
    /// keys fix field order; unescaped slashes keep any URI-shaped value
    /// readable; pretty-printing keeps the canon human-diffable in the
    /// repo. These settings are byte-stable across runs and machines.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return encoder
    }

    /// Encodes a canon to deterministic JSON bytes. Exposed so callers
    /// (and the determinism test) can compare canon output without
    /// touching the filesystem.
    public static func canonData(_ canon: LatticeCanon) throws -> Data {
        try makeEncoder().encode(canon)
    }

    /// Writes all four artifacts to `directory`, creating it if needed.
    /// The directory is created with intermediate directories so a fresh
    /// output path works on the first run.
    public static func write(
        output: AssemblerOutput,
        provenance: BuildProvenance,
        to directory: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        // 1. Canon.
        let canonData = try canonData(output.canon)
        try canonData.write(to: directory.appendingPathComponent(canonFilename))

        // 2. Fast-codes channel — reuse the channel's own byte-stable
        //    encoder so the written file matches what consumers pull.
        let fastCodes = try Channels.encodeFastCodes(Channels.fastCodes(from: output.canon))
        try fastCodes.write(to: directory.appendingPathComponent(codesFilename))

        // 3. Slow-docs channel — the channel markdown with a provenance
        //    header prepended naming the CC0 source and access date.
        let docs = provenanceHeader(provenance, canonVersion: output.canon.canonVersion)
            + Channels.slowDocs(from: output.canon)
        try Data(docs.utf8).write(to: directory.appendingPathComponent(docsFilename))

        // 4. Persisted registry for reruns.
        let persisted = PersistedRegistry(
            canonVersion: output.canon.canonVersion,
            provenance: provenance,
            entries: output.registry.entries
        )
        let registryData = try makeEncoder().encode(persisted)
        try registryData.write(to: directory.appendingPathComponent(registryFilename))
    }

    /// Reloads a persisted registry from disk as a `StableKeyRegistry`
    /// ready to feed back into the assembler as the prior registry. The
    /// provenance and canon version in the file are not needed by the
    /// assembler and are dropped here.
    public static func loadRegistry(from url: URL) throws -> StableKeyRegistry {
        let data = try Data(contentsOf: url)
        let persisted = try JSONDecoder().decode(PersistedRegistry.self, from: data)
        return StableKeyRegistry(entries: persisted.entries)
    }

    /// The provenance header prepended to the slow-docs markdown. Kept
    /// in the slow channel (not the canon JSON) because `LatticeCanon`'s
    /// schema is fixed to version-plus-entries and must not be widened;
    /// the documented channel is the right home for build metadata.
    private static func provenanceHeader(_ p: BuildProvenance, canonVersion: String) -> String {
        var out = ""
        out += "<!-- MDCC \(canonVersion) build provenance\n"
        out += "data_version: \(p.dataVersion)\n"
        out += "license: \(p.licenseNote)\n"
        out += "access_date: \(p.accessDate)\n"
        out += "edge_source: \(p.edgeSourceKind)\n"
        out += "-->\n\n"
        return out
    }
}
