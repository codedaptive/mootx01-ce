// WordClassTable.swift
//
// The static noun/verb fast-path table loaded from the committed
// reference data at Resources/WordClassTable.json (cookbook §1.3).
// A token present in this table is resolved to its WordClass in
// constant time with no platform tagger invoked — the fast path that
// covers the vast majority of tokens (cookbook §2.1).
//
// The table is produced at Seed-Generator time (cookbook §7.3) by
// running NLTagger over a large Wikipedia corpus and recording the
// deduplicated, lowercased noun and verb sets. EideticLib only reads
// the pinned snapshot; it never tags at table-build scale itself.

import Foundation

/// The parsed word-class table with its pinned versioning metadata
/// (cookbook §1.3 schema). Byte-identical shape to the Rust port's
/// `WordClassTable` struct so both ports parse the same JSON.
public struct WordClassTable: Sendable, Codable {

    /// The table version. Pinned; it gates pool submission — the
    /// server discards submissions whose `table_version` does not
    /// match the current shipping table (cookbook §2.3).
    public let tableVersion: String

    /// The NLTagger OS version that produced this table (cookbook
    /// §1.3). A pinned parameter of the encoder contract: builds
    /// targeting an OS below this version use the table only and do
    /// not invoke an older tagger (cookbook §2.2).
    public let minOSVersion: String

    /// The cutoff date for local pool-cache purge on table update
    /// (cookbook §1.3, §2.2). On ingesting a newer table, a device
    /// purges accumulated novel tokens predating this date; they are
    /// retagged on next encounter.
    public let snapshotDate: String

    /// The lowercased noun surface forms.
    public let nouns: [String]

    /// The lowercased verb surface forms.
    public let verbs: [String]

    enum CodingKeys: String, CodingKey {
        case tableVersion = "table_version"
        case minOSVersion = "min_os_version"
        case snapshotDate = "snapshot_date"
        case nouns
        case verbs
    }
}

extension WordClassTable {
    /// Loads the table from the module's bundled resource at
    /// Resources/WordClassTable.json. Returns nil if the resource is
    /// missing or malformed; production code should treat that as a
    /// build error since the JSON ships with the kit.
    public static func loadBundled() -> WordClassTable? {
        guard let url = Bundle.module.url(
            forResource: "WordClassTable",
            withExtension: "json"
        ) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(
            WordClassTable.self,
            from: data
        )
    }
}

/// The process-lifetime cache of the parsed table and its derived
/// membership sets. The table ships as a build-time constant, so it
/// is parsed exactly once on first access and reused thereafter — the
/// same caching rationale as `EideticLib.cachedSubset`.
///
/// The noun and verb membership sets are `Set<String>` of lowercased
/// tokens, giving constant-time fast-path lookup (cookbook §2.1).
enum WordClassTableCache {

    /// The parsed bundled table, or nil if it failed to load.
    static let table: WordClassTable? = WordClassTable.loadBundled()

    /// Lowercased noun surface forms for constant-time membership.
    static let nounSet: Set<String> = Set(table?.nouns ?? [])

    /// Lowercased verb surface forms for constant-time membership.
    static let verbSet: Set<String> = Set(table?.verbs ?? [])
}
