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

    /// The Q-ID whose MULTI-WORD English label matches `phrase` (lowercase,
    /// single-space joined), or nil. Single-word labels are deliberately
    /// excluded — single tokens anchor through the Lexicon/EideticLib path;
    /// this surface exists for multi-word entity anchoring
    /// (DECISION_DENSE_LANE_ENRICHMENT v0.2, p2.2). When two Q-IDs share a
    /// lowercase label the numerically smallest wins (deterministic).
    public static func qid(forPhrase phrase: String) -> String? {
        guard phrase.contains(" ") else { return nil }
        return phraseIndex[phrase]
    }

    /// Lazily built lowercase multi-word label → Q-ID index.
    private static let phraseIndex: [String: String] = {
        guard let table else { return [:] }
        var index: [String: String] = [:]
        for (qid, entry) in table.facts {
            guard let label = entry.label, label.contains(" ") else { continue }
            let key = label.lowercased()
            if let existing = index[key] {
                // Numerically smallest Q-ID wins.
                if (Int(qid.dropFirst()) ?? .max) < (Int(existing.dropFirst()) ?? .max) {
                    index[key] = qid
                }
            } else {
                index[key] = qid
            }
        }
        return index
    }()

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
