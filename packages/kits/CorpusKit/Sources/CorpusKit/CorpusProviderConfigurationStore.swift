// CorpusProviderConfigurationStore.swift
//
// A last-written attestation for current-runtime provider reconciliation.
// It is deliberately separate from historical estate migration state.

import Foundation
import PersistenceKit

/// Records that the configured provider generations have completed their
/// coverage backfill. The singleton is written only after vectors, coverage,
/// and representation claims are durable, so equality is a safe O(1) normal
/// open path. A crash before this write simply causes reconciliation to retry.
public actor CorpusProviderConfigurationStore {
    public static let schemaDeclaration = SchemaDeclaration(
        kitID: "CorpusKitProviderConfiguration",
        version: 1,
        tables: [
            TableDeclaration(
                name: "corpus_provider_configuration",
                columns: [
                    .int("singleton_id", nullable: false),
                    .text("generation_token", nullable: false),
                    .timestamp("updated_at", nullable: false)
                ],
                primaryKey: ["singleton_id"])
        ])

    private let storage: any Storage

    public init(storage: any Storage) {
        self.storage = storage
    }

    public func generationToken() async throws -> String? {
        let rows = try await storage.rowStore.query(
            table: "corpus_provider_configuration",
            where: .eq(
                Column(table: "corpus_provider_configuration", name: "singleton_id"),
                .int(1)),
            orderBy: [], limit: 1, offset: nil)
        guard let row = rows.first, case let .text(token)? = row["generation_token"] else {
            return nil
        }
        return token
    }

    public func markCurrent(_ token: String, now: Date) async throws {
        _ = try await storage.rowStore.upsert(
            table: "corpus_provider_configuration",
            values: [
                "singleton_id": .int(1),
                "generation_token": .text(token),
                "updated_at": .timestamp(now)
            ],
            conflictColumns: ["singleton_id"])
    }

    public func invalidate() async throws {
        _ = try await storage.rowStore.delete(
            table: "corpus_provider_configuration", where: .isTrue)
    }
}
