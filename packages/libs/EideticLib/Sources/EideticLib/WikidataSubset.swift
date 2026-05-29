// WikidataSubset.swift
//
// The curated Wikidata subset loaded from the committed reference
// data at Resources/WikidataSubset.json. Each entry maps a Wikidata
// Q-ID (CC0) to its English label and any aliases. The resolver uses
// it to confirm and enrich the Q-ID carried by a resolved MDCC canon
// entry.

import Foundation

/// One Wikidata subset entry.
public struct WikidataEntry: Equatable, Sendable, Codable {

    /// The Wikidata Q-ID, including the Q prefix
    /// (e.g. "Q21198").
    public let qid: String

    /// The canonical English label, lowercased so it matches
    /// the resolver's normalized input form.
    public let label: String

    /// Alternative labels (Wikidata aliases plus morphological
    /// variants), lowercased.
    public let aliases: [String]

    /// Audit-trail discriminator: which assembly section
    /// produced this entry. Values include "udc_anchor" and
    /// "common_knowledge".
    public let sourceSection: String

    enum CodingKeys: String, CodingKey {
        case qid
        case label
        case aliases
        case sourceSection = "source_section"
    }
}

/// The Wikidata subset itself with versioning and provenance.
public struct WikidataSubset: Sendable, Codable {
    public let schemaVersion: String
    public let dataVersion: String
    public let sourceNotes: String
    public let licenseNote: String
    public let entries: [WikidataEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case dataVersion = "data_version"
        case sourceNotes = "source_notes"
        case licenseNote = "license_note"
        case entries
    }
}

extension WikidataSubset {
    /// Loads the subset from the module's bundled resource at
    /// Resources/WikidataSubset.json. Returns nil if the
    /// resource is missing or malformed; production code
    /// should treat that as a build error since the JSON
    /// ships with the kit.
    public static func loadBundled() -> WikidataSubset? {
        guard let url = Bundle.module.url(
            forResource: "WikidataSubset",
            withExtension: "json"
        ) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(
            WikidataSubset.self,
            from: data
        )
    }
}
