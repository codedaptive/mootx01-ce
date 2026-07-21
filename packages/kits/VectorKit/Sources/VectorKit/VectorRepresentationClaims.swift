// VectorRepresentationClaims.swift
//
// Executable representation-ownership manifest
// (GLK shared-content 1.1, P0 — vector representation ownership gate).
//
// The `vectors` table has no lane-owner field, and GLK and CorpusKit
// already use overlapping model IDs — so "same model ID" is NOT proof of
// ownership, and a Drawer-keyed vector may be a shared representation
// consumed by several lanes. This ledger records, per REPRESENTATION KEY
// (modelID, modelVersion, vectorIndex), which consumers produced or
// consume that representation:
//
//   - a representation with one claimant is EXCLUSIVE to that consumer:
//     the consumer may delete its rows by exact key;
//   - a representation with several claimants is SHARED: deleting one
//     consumer's index releases that consumer's claim only, and a vector
//     row may be deleted only when no retained lane still claims the
//     representation.
//
// This is deliberately a CONSUMER LEDGER, not a payload copy, not a
// lane-specific ID scheme, and not a model-ID naming convention: claims
// are explicit rows a lifecycle path must write and release.
//
// The ledger lives in its own SchemaDeclaration (kit ID
// "VectorKitClaims") so estates adopt it additively via `migrate(to:)`,
// exactly like the CorpusKit sidecar stores.
//
// Rust twin: `vector_kit::representation_claims`.

import Foundation
import PersistenceKit

/// One representation key: the identity of a stored vector representation,
/// independent of which items carry it.
public struct VectorRepresentationKey: Sendable, Hashable, Comparable {
    public let modelID: String
    public let modelVersion: String
    /// Lane position (0 = binary engram, 1 = dense float by CorpusKit
    /// convention).
    public let vectorIndex: Int

    public init(modelID: String, modelVersion: String, vectorIndex: Int) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.vectorIndex = vectorIndex
    }

    public static func < (lhs: VectorRepresentationKey, rhs: VectorRepresentationKey) -> Bool {
        if lhs.modelID != rhs.modelID { return lhs.modelID < rhs.modelID }
        if lhs.modelVersion != rhs.modelVersion { return lhs.modelVersion < rhs.modelVersion }
        return lhs.vectorIndex < rhs.vectorIndex
    }
}

/// Durable consumer-claims ledger over vector representations.
public actor VectorRepresentationClaims {

    /// Additive ledger schema. Applied via `storage.migrate(to:)` like the
    /// other sidecar declarations; not part of any composite schema until
    /// the attached-profile composition (P3) adopts it.
    public static let schemaDeclaration = SchemaDeclaration(
        kitID: "VectorKitClaims",
        version: 1,
        tables: [
            TableDeclaration(
                name: "vector_rep_claims",
                columns: [
                    .text("model_id", nullable: false),
                    .text("model_version", nullable: false),
                    .int("vector_index", nullable: false),
                    // The claiming lane, e.g. "corpus" or "glk-encode".
                    // Free-form but stable per consumer.
                    .text("consumer", nullable: false),
                    .timestamp("claimed_at", nullable: false)
                ],
                primaryKey: ["model_id", "model_version", "vector_index", "consumer"]
            )
        ],
        indices: [
            IndexDeclaration(
                name: "idx_vector_rep_claims_consumer",
                table: "vector_rep_claims",
                columns: ["consumer"]
            )
        ]
    )

    private let storage: any Storage

    public init(storage: any Storage) {
        self.storage = storage
    }

    /// Record that `consumer` produces or consumes `key`. Idempotent
    /// (upsert on the full primary key); re-claiming refreshes `claimed_at`.
    public func registerClaim(
        consumer: String, key: VectorRepresentationKey, now: Date
    ) async throws {
        _ = try await storage.rowStore.upsert(
            table: "vector_rep_claims",
            values: [
                "model_id": .text(key.modelID),
                "model_version": .text(key.modelVersion),
                "vector_index": .int(Int64(key.vectorIndex)),
                "consumer": .text(consumer),
                "claimed_at": .timestamp(now)
            ],
            conflictColumns: ["model_id", "model_version", "vector_index", "consumer"]
        )
    }

    /// Release `consumer`'s claim on `key`. No-op when not claimed.
    public func releaseClaim(consumer: String, key: VectorRepresentationKey) async throws {
        _ = try await storage.rowStore.delete(
            table: "vector_rep_claims",
            where: .and([
                .eq(Column(table: "vector_rep_claims", name: "model_id"), .text(key.modelID)),
                .eq(Column(table: "vector_rep_claims", name: "model_version"), .text(key.modelVersion)),
                .eq(Column(table: "vector_rep_claims", name: "vector_index"), .int(Int64(key.vectorIndex))),
                .eq(Column(table: "vector_rep_claims", name: "consumer"), .text(consumer))
            ])
        )
    }

    /// Release every claim held by `consumer` (index teardown).
    public func releaseAllClaims(consumer: String) async throws {
        _ = try await storage.rowStore.delete(
            table: "vector_rep_claims",
            where: .eq(Column(table: "vector_rep_claims", name: "consumer"), .text(consumer))
        )
    }

    /// The consumers currently claiming `key`, sorted.
    public func claimants(key: VectorRepresentationKey) async throws -> [String] {
        let rows = try await storage.rowStore.query(
            table: "vector_rep_claims",
            where: .and([
                .eq(Column(table: "vector_rep_claims", name: "model_id"), .text(key.modelID)),
                .eq(Column(table: "vector_rep_claims", name: "model_version"), .text(key.modelVersion)),
                .eq(Column(table: "vector_rep_claims", name: "vector_index"), .int(Int64(key.vectorIndex)))
            ]),
            orderBy: [], limit: nil, offset: nil)
        return rows.compactMap { row in
            if case let .text(consumer)? = row["consumer"] { return consumer }
            return nil
        }.sorted()
    }

    /// Every representation key `consumer` currently claims, sorted.
    public func claims(consumer: String) async throws -> [VectorRepresentationKey] {
        let rows = try await storage.rowStore.query(
            table: "vector_rep_claims",
            where: .eq(Column(table: "vector_rep_claims", name: "consumer"), .text(consumer)),
            orderBy: [], limit: nil, offset: nil)
        return rows.compactMap { row -> VectorRepresentationKey? in
            guard case let .text(modelID)? = row["model_id"],
                  case let .text(modelVersion)? = row["model_version"],
                  case let .int(vectorIndex)? = row["vector_index"] else { return nil }
            return VectorRepresentationKey(
                modelID: modelID, modelVersion: modelVersion, vectorIndex: Int(vectorIndex))
        }.sorted()
    }

    /// True when `consumer` is the SOLE claimant of `key` — the precondition
    /// for deleting the representation's rows rather than merely releasing
    /// the claim. False when unclaimed (deleting unclaimed state is a
    /// caller decision, not an ownership proof).
    public func isExclusive(consumer: String, key: VectorRepresentationKey) async throws -> Bool {
        try await claimants(key: key) == [consumer]
    }

    /// True when no consumer claims `key` — the release-side precondition
    /// for physically deleting a shared representation's remaining rows.
    public func isUnclaimed(key: VectorRepresentationKey) async throws -> Bool {
        try await claimants(key: key).isEmpty
    }
}
