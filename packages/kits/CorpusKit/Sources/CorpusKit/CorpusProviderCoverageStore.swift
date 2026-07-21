// CorpusProviderCoverageStore.swift
//
// Per-provider coverage checkpoints (GLK shared-content 1.1 corrective
// pass). The content checkpoint (`corpus_index_state`) records that a
// Drawer's structural derivations (BM25 + passages) reflect a
// (revision, digest, indexVersion); it says NOTHING about which embedding
// providers cover the Drawer under which basis generation. This table is
// that missing dimension: one row per (content, provider) recording the
// BASIS DIGEST the provider's stored vectors were produced under.
//
// Contracts:
//   - a coverage row is written AFTER the provider's vector rows for that
//     content are durably upserted — a cursor or progress figure may LAG
//     coverage, but coverage never overstates the vectors table;
//   - coverage is the resume authority for provider backfill: the missing
//     set is (indexed content) minus (covered under the CURRENT basis
//     digest), so a crashed backfill continues exactly where the durable
//     rows stopped, and a basis-digest mismatch re-covers precisely the
//     stale (content, provider) pairs;
//   - rows carry NO text and are rebuildable derived state (present in
//     both schema profiles alongside the other sidecar stores).
//
// Rust twin: `rust/src/provider_coverage_store.rs`.

import Foundation
import PersistenceKit

/// Durable store over `corpus_provider_coverage`.
public actor CorpusProviderCoverageStore {

    public static let schemaDeclaration = SchemaDeclaration(
        kitID: "CorpusKitProviderCoverage",
        version: 1,
        tables: [
            TableDeclaration(
                name: "corpus_provider_coverage",
                columns: [
                    .text("content_id", nullable: false),
                    .text("model_id", nullable: false),
                    .text("basis_digest", nullable: false),
                    .timestamp("updated_at", nullable: false)
                ],
                primaryKey: ["content_id", "model_id"]
            )
        ]
    )

    private let storage: any Storage

    public init(storage: any Storage) {
        self.storage = storage
    }

    /// Upsert one batch of coverage rows. Idempotent; call AFTER the
    /// corresponding vector rows are durably written.
    public func markCovered(
        _ entries: [(contentID: CorpusContentID, modelID: String, basisDigest: String)],
        now: Date
    ) async throws {
        for entry in entries {
            _ = try await storage.rowStore.upsert(
                table: "corpus_provider_coverage",
                values: [
                    "content_id": .text(entry.contentID),
                    "model_id": .text(entry.modelID),
                    "basis_digest": .text(entry.basisDigest),
                    "updated_at": .timestamp(now)
                ],
                conflictColumns: ["content_id", "model_id"])
        }
    }

    /// Content IDs covered by `modelID` under EXACTLY `basisDigest`.
    /// Rows under a different digest are stale coverage and excluded, so
    /// the caller's missing-set arithmetic re-covers them.
    public func coveredContentIDs(
        modelID: String, basisDigest: String
    ) async throws -> Set<CorpusContentID> {
        let rows = try await storage.rowStore.query(
            table: "corpus_provider_coverage",
            where: .eq(Column(table: "corpus_provider_coverage", name: "model_id"),
                       .text(modelID)),
            orderBy: [], limit: nil, offset: nil)
        var out: Set<CorpusContentID> = []
        out.reserveCapacity(rows.count)
        for row in rows {
            guard case let .text(id)? = row["content_id"],
                  case let .text(digest)? = row["basis_digest"],
                  digest == basisDigest else { continue }
            out.insert(id)
        }
        return out
    }

    /// Count of content IDs covered by `modelID` under `basisDigest` —
    /// the verification-gate figure.
    public func coveredCount(modelID: String, basisDigest: String) async throws -> Int {
        try await coveredContentIDs(modelID: modelID, basisDigest: basisDigest).count
    }

    /// This content's coverage rows (modelID → basisDigest).
    public func coverage(for contentID: CorpusContentID) async throws -> [String: String] {
        let rows = try await storage.rowStore.query(
            table: "corpus_provider_coverage",
            where: .eq(Column(table: "corpus_provider_coverage", name: "content_id"),
                       .text(contentID)),
            orderBy: [], limit: nil, offset: nil)
        var out: [String: String] = [:]
        for row in rows {
            guard case let .text(model)? = row["model_id"],
                  case let .text(digest)? = row["basis_digest"] else { continue }
            out[model] = digest
        }
        return out
    }

    /// Remove one content's coverage rows (the removal/expunge path).
    public func clear(contentID: CorpusContentID) async throws {
        _ = try await storage.rowStore.delete(
            table: "corpus_provider_coverage",
            where: .eq(Column(table: "corpus_provider_coverage", name: "content_id"),
                       .text(contentID)))
    }

    /// Remove every coverage row (recall-index destruction).
    public func clearAll() async throws {
        _ = try await storage.rowStore.delete(
            table: "corpus_provider_coverage", where: .isTrue)
    }
}
