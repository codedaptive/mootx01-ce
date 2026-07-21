// LegacyCorpusFixtures.swift
//
// Frozen legacy corpus-lane fixture (GLK shared-content 1.1, P0).
//
// The historical composite-v7 layout (the 1.0.0-ship era: LocusKit v2 +
// VectorKit v3 + CorpusKit/BundleStore v2) differs from the current
// pre-cutover corpus lane in exactly the marks the P4 legacy detector
// keys on:
//
//   - `chunks` has the `ext` slot but NO `content_hash` column (v2);
//   - there is NO `corpus_metadata` table (added at BundleStore v3);
//   - `vectors` lacks the v4 `idx_vectors_filed_at_item` index.
//
// The declarations below are LITERAL reconstructions of that era's layout
// — they must never be edited to track the live declarations (that would
// erase the very difference detection needs). Their canonical layout
// signature is frozen cross-port in
// `Tests/Fixtures/legacy_v7_corpus_lane_signature.txt`, asserted
// byte-identically by the Rust twin
// (`legacy_corpus_fixture_tests.rs`).
//
// `buildLegacyV7CorpusLane` populates a storage with deterministic
// legacy-shaped rows: verbatim chunk text keyed by content-addressed
// chunk UUIDs, and chunk-keyed vector rows — the exact artifacts the
// migration must inventory, delete selectively, and rebuild under Drawer
// IDs.

import Foundation
import PersistenceKit
import SubstrateTypes
import EngramLib
import VectorKit

@testable import CorpusKit

enum LegacyCorpusFixtures {

    // MARK: - Era declarations (literal, frozen)

    /// CorpusKit BundleStore schema as of v2 (pre content-hash, pre
    /// corpus_metadata).
    static let legacyChunksDeclaration = SchemaDeclaration(
        kitID: "CorpusKit",
        version: 2,
        tables: [
            TableDeclaration(
                name: "chunks",
                columns: [
                    .uuid("id"),
                    .text("source_id", nullable: false),
                    .int("start_offset", nullable: false),
                    .int("length", nullable: false),
                    .text("text", nullable: false),
                    ColumnDeclaration(name: "hlc", type: .hlc, nullable: false),
                    .json("metadata", nullable: false),
                    .timestamp("created_at", nullable: false),
                    .json("ext", nullable: true)
                ],
                primaryKey: ["id"]
            )
        ],
        indices: [
            IndexDeclaration(name: "idx_chunks_source", table: "chunks", columns: ["source_id"]),
            IndexDeclaration(name: "idx_chunks_hlc", table: "chunks", columns: ["hlc"])
        ]
    )

    /// VectorKit schema as of v3 (pre idx_vectors_filed_at_item).
    static let legacyVectorsDeclaration = SchemaDeclaration(
        kitID: "VectorKit",
        version: 3,
        tables: [
            TableDeclaration(
                name: "vectors",
                columns: [
                    .uuid("id"),
                    .text("item_id", nullable: false),
                    .int("vector_index", nullable: false),
                    .text("model_id", nullable: false),
                    .text("model_version", nullable: false),
                    .int("kind", nullable: false),
                    .int("dim", nullable: false),
                    .blob("payload", nullable: false),
                    .float("scale", nullable: true),
                    .timestamp("filed_at", nullable: false),
                    .json("ext", nullable: true)
                ],
                primaryKey: ["id"],
                uniqueConstraints: [["item_id", "vector_index", "model_id"]]
            )
        ],
        indices: [
            IndexDeclaration(name: "idx_vectors_item", table: "vectors",
                             columns: ["item_id"], unique: false),
            IndexDeclaration(name: "idx_vectors_model_item", table: "vectors",
                             columns: ["model_id", "item_id"], unique: false)
        ]
    )

    /// The combined legacy corpus-lane declaration whose layout signature is
    /// frozen cross-port — the structural identity of a v7-era corpus lane.
    static var legacyCorpusLaneDeclaration: SchemaDeclaration {
        SchemaDeclaration(
            kitID: "LegacyCorpusLane",
            version: legacyChunksDeclaration.version + legacyVectorsDeclaration.version,
            tables: legacyChunksDeclaration.tables + legacyVectorsDeclaration.tables,
            indices: legacyChunksDeclaration.indices + legacyVectorsDeclaration.indices
        )
    }

    /// The current pre-cutover corpus-lane declaration, from the LIVE
    /// declarations — the comparison target for detection tests.
    static var currentCorpusLaneDeclaration: SchemaDeclaration {
        SchemaDeclaration(
            kitID: "CurrentCorpusLane",
            version: BundleStore.schemaDeclaration.version + VectorStore.schemaDeclaration.version,
            tables: BundleStore.schemaDeclaration.tables + VectorStore.schemaDeclaration.tables,
            indices: BundleStore.schemaDeclaration.indices + VectorStore.schemaDeclaration.indices
        )
    }

    // MARK: - Deterministic legacy content

    static let fixtureNow = Date(timeIntervalSince1970: 1_600_000_000)

    /// The legacy sources and their verbatim text, in insertion order.
    static let legacySources: [(sourceID: String, text: String)] = [
        ("drawer-legacy-1", "First legacy drawer content preserved verbatim in the chunk lane."),
        ("drawer-legacy-2", "Second legacy drawer content, also copied into chunks.")
    ]

    /// Populate `storage` with a deterministic v7-era corpus lane: legacy
    /// chunk rows (verbatim text, content-addressed chunk UUIDs) and
    /// chunk-keyed binary vector rows under the deterministic model ID.
    ///
    /// Returns the chunk IDs per source — the exact-key deletion inventory
    /// a migration must capture.
    @discardableResult
    static func buildLegacyV7CorpusLane(
        storage: any Storage
    ) async throws -> [String: [UUID]] {
        try await storage.migrate(to: legacyChunksDeclaration)
        try await storage.migrate(to: legacyVectorsDeclaration)

        var chunkIDsBySource: [String: [UUID]] = [:]
        var hlcCounter: Int64 = 1
        for (sourceID, text) in legacySources {
            let chunkID = Chunk.deriveID(sourceID: sourceID, startOffset: 0, text: text)
            chunkIDsBySource[sourceID, default: []].append(chunkID)
            _ = try await storage.rowStore.insert(table: "chunks", values: [
                "id": .uuid(chunkID),
                "source_id": .text(sourceID),
                "start_offset": .int(0),
                "length": .int(Int64(text.count)),
                "text": .text(text),
                "hlc": .hlc(HLC(physicalTime: hlcCounter, logicalCount: 0, nodeID: 1)),
                "metadata": .json(Data("{}".utf8)),
                "created_at": .timestamp(fixtureNow),
                "ext": .null
            ])
            // Chunk-keyed binary vector row (vector_index 0) — the legacy
            // CorpusKit artifact class the migration deletes by exact key.
            _ = try await storage.rowStore.insert(table: "vectors", values: [
                "id": .uuid(UUID(uuidString: "00000000-0000-4000-8000-\(String(format: "%012d", hlcCounter))")!),
                "item_id": .text(chunkID.uuidString),
                "vector_index": .int(0),
                "model_id": .text("corpus-deterministic-v1"),
                "model_version": .text("1.0.0"),
                "kind": .int(0),
                "dim": .int(256),
                "payload": .blob(Data(repeating: UInt8(truncatingIfNeeded: hlcCounter), count: 32)),
                "scale": .null,
                "filed_at": .timestamp(fixtureNow)
            ])
            hlcCounter += 1
        }
        return chunkIDsBySource
    }
}
