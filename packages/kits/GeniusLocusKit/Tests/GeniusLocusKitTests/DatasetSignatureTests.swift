// DatasetSignatureTests.swift
// GeniusLocusKitTests
//
// MX-TAB-5: Tests for layered dataset signatures.
//
// Coverage:
//   - Preimage bytes: the anchor fixture's exact preimage bytes are traced
//     and asserted byte-by-byte so the layout is self-documenting.
//   - Cross-leg anchor: the SHA-256 of the anchor preimage is hardcoded;
//     the Rust counterpart (dataset_signatures.rs) asserts the same hex.
//   - Determinism: same input twice → identical hex strings (both tiers).
//   - Empty dataset: zero rows + zero columns produces valid signatures.
//   - Top-K sketch: frequency ordering and missing-key skipping.
//   - Column signature isolation: same column input → same preimage.
//   - Canonical value bytes: tag + payload spot-checks.

import Testing
import Foundation
import SubstrateKernel
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

// MARK: - DatasetSignatureTests

@Suite("DatasetSignatureTests")
struct DatasetSignatureTests {

    // MARK: - Fixture helpers

    /// Open a fresh GeniusLocusKit estate + dataset for testing.
    private func openEstateWithDataset(
        datasetId: UUID,
        schema: DatasetSchema,
        columns: [DatasetColumnSummary],
        rowCount: Int = 0
    ) async throws -> (
        kit: GeniusLocusKit,
        handle: EstateHandle,
        drawer: Drawer,
        datasetStore: any DatasetStore
    ) {
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let owner = OwnerCredentials(ownerIdentifier: "dataset-sig-tests")
        let estate = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let kit = GeniusLocusKit()
        let handle = try await kit.open(storage: storage, owner: owner)
        let datasetStore = storage.datasetStore
        try await datasetStore.createDataset(id: datasetId, schema: schema, indexes: [])
        let drawer = try await estate.captureDatasetHandle(
            datasetId: datasetId,
            columns: columns,
            rowCount: rowCount,
            sourceDescription: "sig-test fixture",
            room: "sig-test-room",
            addedBy: "DatasetSignatureTests",
            latticeAnchor: LatticeAnchor(udcCode: "004")
        )
        return (kit, handle, drawer, datasetStore)
    }

    // MARK: - Anchor preimage tests

    /// Verify the table signature preimage byte layout for the cross-leg anchor fixture.
    ///
    /// Fixture: columns=[{name:"n", dataType:"INTEGER"}], sampledRows=[].
    ///
    /// Expected preimage bytes (25 total):
    ///   0x10                                 1 byte  — domain tag (table)
    ///   0x00 0x00 0x00 0x01                  4 bytes — column count = 1
    ///   0x00 0x00 0x00 0x01                  4 bytes — "n" UTF-8 length = 1
    ///   0x6E                                 1 byte  — "n"
    ///   0x00 0x00 0x00 0x07                  4 bytes — "INTEGER" length = 7
    ///   0x49 0x4E 0x54 0x45 0x47 0x45 0x52  7 bytes — "INTEGER"
    ///   0x00 0x00 0x00 0x00                  4 bytes — sample_row_count = 0
    @Test("anchor table preimage: byte layout matches documented specification")
    func anchorTablePreimageBytes() {
        let cols: [DatasetColumnSummary] = [
            DatasetColumnSummary(name: "n", dataType: "INTEGER"),
        ]
        let preimage = DatasetSignatureComputer.tableSignaturePreimage(
            columns: cols, sampledRows: []
        )
        let expected: [UInt8] = [
            0x10,                                          // domain tag
            0x00, 0x00, 0x00, 0x01,                        // column count = 1
            0x00, 0x00, 0x00, 0x01,                        // "n" length = 1
            0x6E,                                          // 'n'
            0x00, 0x00, 0x00, 0x07,                        // "INTEGER" length = 7
            0x49, 0x4E, 0x54, 0x45, 0x47, 0x45, 0x52,     // "INTEGER"
            0x00, 0x00, 0x00, 0x00,                        // sample_row_count = 0
        ]
        #expect(preimage == expected,
                "table anchor preimage must match the 25-byte documented layout")
    }

    /// Verify the column signature preimage byte layout for the cross-leg anchor fixture.
    ///
    /// Fixture: name="n", dataType="INTEGER", stats=all-zero, topKValues=[].
    ///
    /// Expected preimage bytes (47 total):
    ///   0x11                                 1 byte  — domain tag (column)
    ///   0x00 0x00 0x00 0x01                  4 bytes — "n" length = 1
    ///   0x6E                                 1 byte  — "n"
    ///   0x00 0x00 0x00 0x07                  4 bytes — "INTEGER" length = 7
    ///   0x49 0x4E 0x54 0x45 0x47 0x45 0x52  7 bytes — "INTEGER"
    ///   0x00 × 8                             8 bytes — count = 0
    ///   0x00 × 8                             8 bytes — distinctCount = 0
    ///   0x00 × 8                             8 bytes — nullCount = 0
    ///   0x00                                 1 byte  — min = null tag (0x00)
    ///   0x00                                 1 byte  — max = null tag (0x00)
    ///   0x00 0x00 0x00 0x00                  4 bytes — top_k_actual = 0
    @Test("anchor column preimage: byte layout matches documented specification")
    func anchorColumnPreimageBytes() {
        let stats = ColumnStats(
            count: 0, distinctCount: 0, nullCount: 0, min: .null, max: .null
        )
        let preimage = DatasetSignatureComputer.columnSignaturePreimage(
            name: "n", dataType: "INTEGER", stats: stats, topKValues: []
        )
        let expected: [UInt8] = [
            0x11,                                              // domain tag
            0x00, 0x00, 0x00, 0x01,                            // "n" length = 1
            0x6E,                                              // 'n'
            0x00, 0x00, 0x00, 0x07,                            // "INTEGER" length = 7
            0x49, 0x4E, 0x54, 0x45, 0x47, 0x45, 0x52,         // "INTEGER"
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,   // count = 0
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,   // distinctCount = 0
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,   // nullCount = 0
            0x00,                                              // min = null
            0x00,                                              // max = null
            0x00, 0x00, 0x00, 0x00,                            // top_k_actual = 0
        ]
        #expect(preimage == expected,
                "column anchor preimage must match the 47-byte documented layout")
    }

    // MARK: - Cross-leg anchor: SHA-256 of fixed preimage

    /// Assert the SHA-256 of the table anchor preimage equals the hardcoded
    /// expected hex. The Rust counterpart in `dataset_signatures.rs` asserts
    /// the SAME hex string from the same preimage bytes.
    ///
    /// If this test fails after a preimage change, both legs must be updated
    /// together and the commit message must document the change.
    @Test("cross-leg anchor: table preimage SHA-256 matches expected hex")
    func crossLegAnchorTableHash() {
        // 25-byte anchor preimage (see anchorTablePreimageBytes for the layout).
        let preimage: [UInt8] = [
            0x10,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x01,
            0x6E,
            0x00, 0x00, 0x00, 0x07,
            0x49, 0x4E, 0x54, 0x45, 0x47, 0x45, 0x52,
            0x00, 0x00, 0x00, 0x00,
        ]
        let digest = SHA256.hash(preimage)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        #expect(hex == DatasetSignatureAnchors.tableHex,
                "SHA-256 of table anchor preimage must equal the locked cross-leg hex")
    }

    /// Assert the SHA-256 of the column anchor preimage equals the hardcoded
    /// expected hex. The Rust counterpart asserts the same hex.
    @Test("cross-leg anchor: column preimage SHA-256 matches expected hex")
    func crossLegAnchorColumnHash() {
        // 47-byte anchor preimage (see anchorColumnPreimageBytes for the layout).
        let preimage: [UInt8] = [
            0x11,
            0x00, 0x00, 0x00, 0x01,
            0x6E,
            0x00, 0x00, 0x00, 0x07,
            0x49, 0x4E, 0x54, 0x45, 0x47, 0x45, 0x52,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00,
            0x00,
            0x00, 0x00, 0x00, 0x00,
        ]
        let digest = SHA256.hash(preimage)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        #expect(hex == DatasetSignatureAnchors.columnHex,
                "SHA-256 of column anchor preimage must equal the locked cross-leg hex")
    }

    // MARK: - Determinism: same input → same bytes

    @Test("computeDatasetSignatures is deterministic: same input twice → identical hex")
    func computeSignaturesDeterminism() async throws {
        let datasetId = UUID()
        let schema = DatasetSchema(
            columns: [
                ColumnDeclaration(name: "id",   type: .int),
                ColumnDeclaration(name: "name", type: .text),
            ],
            primaryKeyColumn: nil
        )
        let columns: [DatasetColumnSummary] = [
            DatasetColumnSummary(name: "id",   dataType: "INTEGER"),
            DatasetColumnSummary(name: "name", dataType: "TEXT"),
        ]
        let (kit, handle, drawer, datasetStore) = try await openEstateWithDataset(
            datasetId: datasetId, schema: schema, columns: columns
        )
        try await datasetStore.appendRows(id: datasetId, rows: [
            ["id": .int(1), "name": .text("alice")],
            ["id": .int(2), "name": .text("bob")],
        ])
        let now = Date()
        let sampledRows = try await datasetStore.queryRows(
            id: datasetId, predicate: nil, orderBy: [],
            limit: datasetSignatureSampleSize, offset: nil, columns: nil
        )
        // Dictionary(uniqueKeysWithValues:) does not accept async closures in Swift 6.
        // Collect stats sequentially via an explicit loop.
        var statsByCol: [String: ColumnStats] = [:]
        for col in columns {
            statsByCol[col.name] = try await datasetStore.columnStats(id: datasetId, column: col.name)
        }

        // First call.
        let updated1 = try await kit.computeDatasetSignatures(
            handle: handle, drawerId: drawer.id,
            columns: columns, columnStats: statsByCol,
            sampledRows: sampledRows, now: now
        )
        let content1 = try DatasetHandleContent.decode(from: updated1.content)

        // Second call (idempotent — same drawer, same inputs).
        let updated2 = try await kit.computeDatasetSignatures(
            handle: handle, drawerId: drawer.id,
            columns: columns, columnStats: statsByCol,
            sampledRows: sampledRows, now: now
        )
        let content2 = try DatasetHandleContent.decode(from: updated2.content)

        #expect(
            content1.tableSignature == content2.tableSignature,
            "tableSignature must be identical across two calls with the same input"
        )
        #expect(
            content1.columnSignatures == content2.columnSignatures,
            "columnSignatures must be identical across two calls with the same input"
        )
        // Both signature strings must be 64-character lowercase hex (SHA-256 digest).
        #expect(content1.tableSignature?.count == 64,
                "tableSignature must be a 64-char hex string")
        for (_, sig) in content1.columnSignatures ?? [:] {
            #expect(sig.count == 64, "each column signature must be a 64-char hex string")
        }
    }

    // MARK: - Empty dataset

    @Test("empty dataset (no rows, no columns) produces valid signatures")
    func emptyDataset() async throws {
        let datasetId = UUID()
        let schema = DatasetSchema(columns: [], primaryKeyColumn: nil)
        let (kit, handle, drawer, _) = try await openEstateWithDataset(
            datasetId: datasetId, schema: schema, columns: []
        )
        let updated = try await kit.computeDatasetSignatures(
            handle: handle, drawerId: drawer.id,
            columns: [], columnStats: [:], sampledRows: [], now: Date()
        )
        let content = try DatasetHandleContent.decode(from: updated.content)
        #expect(content.tableSignature != nil,
                "tableSignature must be set even for an empty dataset")
        #expect(content.tableSignature?.count == 64,
                "tableSignature must be a 64-char SHA-256 hex string")
        #expect(content.columnSignatures?.isEmpty == true,
                "columnSignatures must be an empty map for a schema with no columns")
    }

    // MARK: - Schema content affects the signature

    @Test("different column names produce different table signatures")
    func differentColumnNamesProduceDifferentSignatures() {
        let p1 = DatasetSignatureComputer.tableSignaturePreimage(
            columns: [DatasetColumnSummary(name: "a", dataType: "INTEGER")],
            sampledRows: []
        )
        let p2 = DatasetSignatureComputer.tableSignaturePreimage(
            columns: [DatasetColumnSummary(name: "b", dataType: "INTEGER")],
            sampledRows: []
        )
        #expect(p1 != p2, "different column names must produce different preimages")
    }

    @Test("different declared types produce different column signatures")
    func differentDeclaredTypesProduceDifferentColumnSignatures() {
        let stats = ColumnStats(count: 0, distinctCount: 0, nullCount: 0,
                                min: .null, max: .null)
        let p1 = DatasetSignatureComputer.columnSignaturePreimage(
            name: "x", dataType: "INTEGER", stats: stats, topKValues: []
        )
        let p2 = DatasetSignatureComputer.columnSignaturePreimage(
            name: "x", dataType: "TEXT", stats: stats, topKValues: []
        )
        #expect(p1 != p2, "different declared types must produce different preimages")
    }

    // MARK: - Column signature isolation

    @Test("same column input always produces the same preimage bytes")
    func columnSignatureIsolation() {
        let stats = ColumnStats(count: 5, distinctCount: 3, nullCount: 2,
                                min: .int(1), max: .int(10))
        let topK: [(value: TypedValue, count: UInt64)] = [(.int(1), 3), (.int(2), 2)]
        let p1 = DatasetSignatureComputer.columnSignaturePreimage(
            name: "score", dataType: "INTEGER", stats: stats, topKValues: topK
        )
        let p2 = DatasetSignatureComputer.columnSignaturePreimage(
            name: "score", dataType: "INTEGER", stats: stats, topKValues: topK
        )
        #expect(p1 == p2, "identical inputs must produce identical column preimage bytes")
    }

    // MARK: - Top-K computation

    @Test("computeTopK returns at most K entries")
    func topKCappedAtK() {
        let rows: [StorageRow] = (0..<30).map { i in
            StorageRow(values: ["v": .int(Int64(i))])
        }
        let topK = DatasetSignatureComputer.computeTopK(
            columnName: "v", sampledRows: rows, k: 5
        )
        #expect(topK.count <= 5, "top-K count must not exceed k=5")
    }

    @Test("computeTopK: most frequent value ranks first")
    func topKFrequencyOrdering() {
        // Three occurrences of 42, one occurrence of 99.
        let rows: [StorageRow] = [
            StorageRow(values: ["x": .int(42)]),
            StorageRow(values: ["x": .int(42)]),
            StorageRow(values: ["x": .int(42)]),
            StorageRow(values: ["x": .int(99)]),
        ]
        let topK = DatasetSignatureComputer.computeTopK(
            columnName: "x", sampledRows: rows, k: 10
        )
        #expect(topK.count == 2, "expected exactly 2 distinct values")
        if case .int(let v) = topK.first?.value {
            #expect(v == 42, "most frequent value must rank first in top-K output")
        } else {
            Issue.record("expected .int(42) as first top-K entry")
        }
    }

    @Test("computeTopK: missing column key is silently skipped")
    func topKMissingKeySkipped() {
        let rows: [StorageRow] = [
            StorageRow(values: ["other": .text("x")]),   // no "target" key
            StorageRow(values: ["target": .int(1)]),
        ]
        let topK = DatasetSignatureComputer.computeTopK(
            columnName: "target", sampledRows: rows, k: 10
        )
        #expect(topK.count == 1, "row without the target key must be silently skipped")
    }

    // MARK: - Canonical value bytes spot-checks

    @Test("canonical bytes: null is a single 0x00 byte")
    func canonicalNull() {
        #expect(DatasetSignatureComputer.canonicalValueBytes(.null) == [0x00])
    }

    @Test("canonical bytes: bool true = [0x01, 0x01], false = [0x01, 0x00]")
    func canonicalBool() {
        #expect(DatasetSignatureComputer.canonicalValueBytes(.bool(true))  == [0x01, 0x01])
        #expect(DatasetSignatureComputer.canonicalValueBytes(.bool(false)) == [0x01, 0x00])
    }

    @Test("canonical bytes: int(1) = 0x02 + 8-byte big-endian i64")
    func canonicalInt() {
        let bytes = DatasetSignatureComputer.canonicalValueBytes(.int(1))
        #expect(bytes.count == 9, "tag(1) + i64(8) = 9 bytes")
        #expect(bytes[0] == 0x02, "int tag must be 0x02")
        // i64(1) big-endian: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]
        #expect(bytes[8] == 0x01, "last byte of i64(1) big-endian must be 0x01")
        #expect(bytes[1...7].allSatisfy { $0 == 0x00 }, "upper 7 bytes of i64(1) must be 0x00")
    }

    @Test("canonical bytes: int and bitmap use distinct tags (0x02 vs 0x03)")
    func canonicalIntVsBitmapTags() {
        let intBytes    = DatasetSignatureComputer.canonicalValueBytes(.int(7))
        let bitmapBytes = DatasetSignatureComputer.canonicalValueBytes(.bitmap(7))
        #expect(intBytes[0]    == 0x02, "int tag must be 0x02")
        #expect(bitmapBytes[0] == 0x03, "bitmap tag must be 0x03")
        #expect(intBytes != bitmapBytes, "int(7) and bitmap(7) must have different canonical bytes")
    }

    @Test("canonical bytes: float(1.0) = 0x04 + 0x3FF0000000000000 big-endian")
    func canonicalFloat() {
        // 1.0 in f64 has bit-pattern 0x3FF0000000000000.
        let bytes = DatasetSignatureComputer.canonicalValueBytes(.float(1.0))
        #expect(bytes.count == 9, "tag(1) + u64(8) = 9 bytes")
        #expect(bytes[0] == 0x04, "float tag must be 0x04")
        #expect(bytes[1] == 0x3F, "first byte of f64(1.0) bit-pattern big-endian must be 0x3F")
        #expect(bytes[2] == 0xF0, "second byte of f64(1.0) bit-pattern big-endian must be 0xF0")
    }

    @Test("canonical bytes: text(\"hi\") = [0x05, 0x00, 0x00, 0x00, 0x02, 0x68, 0x69]")
    func canonicalText() {
        let bytes = DatasetSignatureComputer.canonicalValueBytes(.text("hi"))
        #expect(bytes == [0x05, 0x00, 0x00, 0x00, 0x02, 0x68, 0x69])
    }

    // MARK: - Dreaming / matrix safety

    @Test("computeDatasetSignatures: returned drawer has tableSignature set (not nil)")
    func dramerSignaturesNotNil() async throws {
        let datasetId = UUID()
        let schema = DatasetSchema(
            columns: [ColumnDeclaration(name: "v", type: .int)],
            primaryKeyColumn: nil
        )
        let columns = [DatasetColumnSummary(name: "v", dataType: "INTEGER")]
        let (kit, handle, drawer, datasetStore) = try await openEstateWithDataset(
            datasetId: datasetId, schema: schema, columns: columns
        )
        try await datasetStore.appendRows(id: datasetId, rows: [["v": .int(42)]])
        let sampledRows = try await datasetStore.queryRows(
            id: datasetId, predicate: nil, orderBy: [],
            limit: datasetSignatureSampleSize, offset: nil, columns: nil
        )
        // Dictionary(uniqueKeysWithValues:) does not accept async closures in Swift 6.
        var statsMap: [String: ColumnStats] = [:]
        for col in columns {
            statsMap[col.name] = try await datasetStore.columnStats(id: datasetId, column: col.name)
        }
        let updated = try await kit.computeDatasetSignatures(
            handle: handle, drawerId: drawer.id,
            columns: columns, columnStats: statsMap,
            sampledRows: sampledRows, now: Date()
        )
        let content = try DatasetHandleContent.decode(from: updated.content)
        #expect(content.tableSignature != nil,
                "tableSignature must be non-nil after computeDatasetSignatures")
        #expect(content.columnSignatures?["v"] != nil,
                "columnSignatures[\"v\"] must be non-nil after computeDatasetSignatures")
    }
}

// MARK: - DatasetSignatureAnchors

/// Cross-leg anchor hex values.
///
/// SHA-256 of specific fixed preimages. These values are established by
/// running the Swift implementation and locked for ongoing cross-leg
/// regression. The Rust `dataset_signatures.rs` test asserts the same
/// constants.
///
/// How to update: if the preimage layout changes, compute the new SHA-256
/// manually (or from test output), update both this file and the Rust
/// equivalent, and document the change in the commit message.
///
/// Do NOT update these values without also updating the Rust counterpart.
enum DatasetSignatureAnchors {
    /// SHA-256 of the 25-byte table anchor preimage:
    ///   [0x10, 0x00,0x00,0x00,0x01, 0x00,0x00,0x00,0x01, 0x6E,
    ///    0x00,0x00,0x00,0x07, 0x49,0x4E,0x54,0x45,0x47,0x45,0x52,
    ///    0x00,0x00,0x00,0x00]
    ///
    /// Established by running the Rust leg first (which computes the actual
    /// hash), then locking both legs. Equals the Rust constant
    /// `ANCHOR_TABLE_SIG_HEX` in `dataset_signatures.rs`.
    /// Do NOT update without also updating the Rust counterpart.
    static let tableHex = "29078b656d47f2be5f6b30917265db16116fac4f2f207049a92e1d48cf5b832b"

    /// SHA-256 of the 47-byte column anchor preimage:
    ///   [0x11, 0x00,0x00,0x00,0x01, 0x6E, 0x00,0x00,0x00,0x07,
    ///    0x49,0x4E,0x54,0x45,0x47,0x45,0x52,
    ///    0x00×8, 0x00×8, 0x00×8, 0x00, 0x00,
    ///    0x00,0x00,0x00,0x00]
    ///
    /// Established by running the Rust leg first (which computes the actual
    /// hash), then locking both legs. Equals the Rust constant
    /// `ANCHOR_COLUMN_SIG_HEX` in `dataset_signatures.rs`.
    /// Do NOT update without also updating the Rust counterpart.
    static let columnHex = "8280ce98f78f9324c28c38412f0de3bd14cdf9669c2aec80871919574bccfb05"
}
