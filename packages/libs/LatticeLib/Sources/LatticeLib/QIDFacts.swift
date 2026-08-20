// QIDFacts.swift
//
// The Q-ID property-facts surface: a process-global static lookup over the
// pinned Wikidata property subset (`QIDFacts.json`) — English labels and
// P17 country per Q-ID for the canon's QID universe. Vendored per
// DECISION_DENSE_LANE_ENRICHMENT v0.2 (fetch script:
// tools/wikidata-subset/fetch_wikidata_facts.py); the runtime NEVER
// queries Wikidata. Mirrors `QIDClosure`'s bundled-resource pattern and
// the Rust twin `lattice_lib::qid_facts` exactly.
//
// Artifact shape:
//   { "version": "...", "generated_utc": "...", "source": "...",
//     "facts": { "<qid>": { "label": "...", "country": "<qid>"? } } }

import Foundation

/// The pinned Q-ID property-facts surface (en label + P17 country).
public enum QIDFacts {

    /// The English label for a Q-ID, or nil when unknown/unavailable.
    public static func label(for qid: String) -> String? {
        guard !qid.isEmpty else { return nil }
        return table?.facts[qid]?.label
    }

    /// The P17 country Q-ID for a Q-ID, or nil. Render it with `label(for:)`.
    public static func countryQID(for qid: String) -> String? {
        guard !qid.isEmpty else { return nil }
        return table?.facts[qid]?.country
    }

    /// The country's English label for a Q-ID, or nil (either no P17 fact
    /// or the country label is absent from the subset).
    public static func countryLabel(for qid: String) -> String? {
        countryQID(for: qid).flatMap(label(for:))
    }

    /// True when the bundled artifact loaded and the surface is ready.
    public static var isAvailable: Bool { table != nil }

    /// The pinned-artifact version string, "0.0.0-unavailable" when absent.
    public static var dataVersion: String { table?.version ?? "0.0.0-unavailable" }

    // MARK: - Bundled artifact

    struct Entry: Codable {
        let label: String?
        let country: String?
    }

    struct Table: Codable {
        let version: String
        let facts: [String: Entry]
    }

    /// Loaded once per process from the module bundle (QIDClosure pattern).
    private static let table: Table? = {
        guard let url = Bundle.module.url(
            forResource: "QIDFacts", withExtension: "json",
            subdirectory: "Resources")
            ?? Bundle.module.url(forResource: "QIDFacts", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let table = try? JSONDecoder().decode(Table.self, from: data)
        else { return nil }
        return table
    }()
}
