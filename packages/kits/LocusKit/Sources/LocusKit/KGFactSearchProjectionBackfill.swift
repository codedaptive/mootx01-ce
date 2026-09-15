// KGFactSearchProjectionBackfill.swift
//
// One-shot, re-runnable backfill that populates `kg_facts.searchProjection`
// and `kg_facts.searchProjectionVersion` for rows the v19 → v20 migration
// added those columns to. A fact with an empty `searchProjection` is
// invisible to any consumer that filters on the projection (the contract:
// a row must carry a non-empty, current-version projection to participate
// in fact-search results).
//
// Run ONLY by `mootx01 upgrade` — Bob's ruling makes upgrade the sole
// migration vehicle: no detection or prompting lives anywhere else (not
// serve, not install, not the App, not an MCP tool).
//
// Design invariant, inherited from EstateEncryptionMigrator:
//
//   EVERY FAILURE PATH LEAVES A WORKING ESTATE AT THE CANONICAL PATH.
//
// Met without a clone → verify → swap shape because filling two columns is
// per-row atomic: each UPDATE sets searchProjection and
// searchProjectionVersion together, so the row is always in one of two
// readable shapes (empty/empty or projection/version). A crash mid-run is
// completed by the next run. Idempotence: rows whose
// searchProjectionVersion already equals the target version are skipped —
// a second run over a fully-projected estate reports scanned: 0.
//
// Alias note: the build function is called with aliases:[] for all backfilled
// rows. The aliases a fresh extraction would have computed are not stored in
// any column and cannot be recovered. A backfilled fact matches subject,
// predicate, and object tokens but not alias synonyms — it ranks slightly
// below a freshly extracted fact but is no longer invisible to recall.

import Foundation
import PersistenceKit

/// Per-row counts from one backfill run.
public struct KGFactSearchProjectionBackfillReport: Sendable, Equatable {
    /// Rows examined (those whose searchProjectionVersion differs from the
    /// target version, i.e. rows that need a projection written or refreshed).
    public var scanned: Int = 0
    /// Rows updated (projection written successfully).
    public var updated: Int = 0

    public init() {}
}

/// The backfill. Stateless; all evidence comes from the estate itself plus
/// the injected build and version parameters.
public enum KGFactSearchProjectionBackfill {

    /// Run the backfill against `storage`.
    ///
    /// Opening the store applies the LocusKit schema ladder first — the
    /// v19 → v20 migration adds the searchProjection columns to estates
    /// that predate them.
    ///
    /// - Parameters:
    ///   - storage: The estate's storage backend, already keyed.
    ///   - buildProjection: Given (subject, predicate, object), returns the
    ///     search-projection string. The caller injects
    ///     `FactSearchProjection.build(subject:predicate:object:aliases:)`
    ///     from FactExtractionKit — injected because LocusKit sits below
    ///     FactExtractionKit and must not depend on it.
    ///   - projectionVersion: The version token that marks a row as
    ///     already projected. The caller injects `FactSearchProjection.version`
    ///     from FactExtractionKit — same layering rationale as above.
    /// - Returns: Scanned and updated counts for the upgrade transcript.
    public static func run(
        storage: any Storage,
        buildProjection: @Sendable (String, String, String) -> String,
        projectionVersion: String
    ) async throws -> KGFactSearchProjectionBackfillReport {
        // DrawerStore's init runs `storage.open(schema:)`, which applies
        // the v19 → v20 addColumn migration on a pre-v20 estate before
        // any row below is read or written.
        let store = try await DrawerStore(storage: storage)

        // Every fact, retired included: a retired fact's missing projection
        // is still a missing projection.
        let facts = try await store.allKGFactsIncludingRetired()

        var report = KGFactSearchProjectionBackfillReport()
        for fact in facts {
            // Idempotence: skip rows that already carry the current version.
            guard fact.searchProjectionVersion != projectionVersion else { continue }
            report.scanned += 1

            // Build the projection with empty aliases — aliases are derived
            // at extraction time and are not stored anywhere; we cannot
            // recover them. Passing [] means the backfilled fact matches
            // s/p/o tokens but not alias synonyms.
            let projection = buildProjection(fact.subject, fact.predicate, fact.object)

            _ = try await storage.rowStore.update(
                table: "kg_facts",
                values: [
                    "searchProjection": .text(projection),
                    "searchProjectionVersion": .text(projectionVersion),
                ],
                where: .eq(Column(table: "kg_facts", name: "id"), .text(fact.id)))
            report.updated += 1
        }
        return report
    }
}
