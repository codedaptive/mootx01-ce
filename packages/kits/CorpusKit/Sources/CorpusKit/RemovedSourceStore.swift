// RemovedSourceStore.swift
//
// Persistence for the set of source IDs (drawer IDs) whose recall has been
// REMOVED from a Corpus.
//
// ## Why this exists
//
// `BundleStore.chunks` is append-only (schema invariant): `remove(sourceID:)`
// deletes the source's vector rows and removes its term frequencies from the
// durable InvertedIndexStore. A reindex (or an InvertedIndexStore reload on open)
// reads `allChunks()` and would re-embed / re-index the removed source's chunks,
// resurrecting it in recall — and the autonomic governor's auto-reindex makes
// that happen automatically in normal operation. This store records which
// sources are removed so every rebuild path can EXCLUDE them.
//
// A removed source is REACTIVATED by re-ingesting it: `Corpus.ingest` clears the
// row, so a later reindex includes the source again (and the re-ingest restores
// its vectors + BM25 postings).
//
// ## Schema (one row per removed source)
//   removed_sources (
//     source_id  TEXT NOT NULL,    -- the removed drawer id
//     removed_at TEXT NOT NULL,    -- ISO8601 (schema invariant); never REAL
//     PRIMARY KEY (source_id)
//   )
//
// The presence of a row marks the source removed; there is NO Bool column
// (schema-invariants rule). `removed_at` is the caller's `now` (determinism).
//
// Layering: CorpusKit core; depends only on PersistenceKit + SubstrateTypes,
// exactly like BasisStore / CorpusProviderCountsStore. It stores ids only and
// interprets no chunk content.

import Foundation
import PersistenceKit
import SubstrateTypes

/// Storage for the set of removed (recall-suppressed) source IDs.
///
/// One row per removed source. `markRemoved` records a removal; `clearRemoved`
/// reactivates a source on re-ingest; `removedIDs` reads the full set for the
/// active-chunk filter; `deleteAll` wipes every row as part of
/// `Corpus.destroyRecallIndex()`.
public actor RemovedSourceStore {

    let storage: any Storage

    /// Additive schema declaration for the removed-sources table. Mirrors the
    /// BasisStore / CorpusProviderCountsStore declaration pattern (its own kitID
    /// so it is created via `migrate(to:)` regardless of the other schemas'
    /// version gates). `appendOnly` is false: a reactivation deletes the row.
    public static let schemaDeclaration = SchemaDeclaration(
        kitID: "CorpusKitRemovedSources",
        version: 1,
        tables: [
            TableDeclaration(
                name: "removed_sources",
                columns: [
                    .text("source_id", nullable: false),
                    // TIMESTAMP maps to TEXT ISO8601 (schema invariant) — never REAL.
                    .timestamp("removed_at", nullable: false)
                ],
                primaryKey: ["source_id"]
            )
        ],
        indices: []
    )

    public init(storage: any Storage) {
        self.storage = storage
    }

    /// Mark a source removed (recall-suppressed). Idempotent: re-marking an
    /// already-removed source replaces the row in place (UPSERT on the
    /// source_id primary key). `now` is the caller's instant (determinism).
    public func markRemoved(_ sourceID: String, now: Date) async throws {
        _ = try await storage.rowStore.upsert(
            table: "removed_sources",
            values: [
                "source_id": .text(sourceID),
                "removed_at": .timestamp(now)
            ],
            conflictColumns: ["source_id"]
        )
    }

    /// Reactivate a source: delete its removed-row so subsequent rebuilds include
    /// it again. No-op when the source was not removed. Called by `Corpus.ingest`
    /// when a source is (re-)ingested.
    public func clearRemoved(_ sourceID: String) async throws {
        _ = try await storage.rowStore.delete(
            table: "removed_sources",
            where: .eq(Column(table: "removed_sources", name: "source_id"), .text(sourceID))
        )
    }

    /// The full set of removed source IDs — the active-chunk filter reads this to
    /// exclude removed sources from reindex / BM25-rebuild / count.
    public func removedIDs() async throws -> Set<String> {
        let rows = try await storage.rowStore.query(
            table: "removed_sources",
            where: nil,
            orderBy: [],
            limit: nil,
            offset: nil
        )
        var ids = Set<String>()
        for row in rows {
            if case let .text(sourceID) = row["source_id"] ?? .null {
                ids.insert(sourceID)
            }
        }
        return ids
    }

    /// Delete every removed-source row. Used by `Corpus.destroyRecallIndex()` so
    /// a destroyed corpus leaves no orphaned removal records behind.
    public func deleteAll() async throws {
        _ = try await storage.rowStore.delete(table: "removed_sources", where: .isTrue)
    }
}
