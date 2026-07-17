import Foundation
import SubstrateTypes
import Testing
@testable import LocusKit

// MARK: - DatasetHandleTests

/// Tests for the dataset handle creation seam (MX-TAB-4).
///
/// Coverage:
///   - `DatasetHandleContent` encode/decode roundtrip + JSON key names
///   - `captureDatasetHandle` bitmap and payload fields
///   - `findDatasetHandles` by datasetId
///   - `resolveActiveDatasetHandle` — active, not-found, and withdrawn paths
///   - Belief lifecycle (contest → resolve → supersede) on dataset-kind drawers
@Suite("DatasetHandleTests")
struct DatasetHandleTests {

    // MARK: - Fixture helpers

    private func makeEstate() async throws -> (Estate, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locuskit-dataset-handle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("estate.sqlite3")
        let estate = try await Estate.create(
            storage: TestStorage.sqlite(path),
            owner: OwnerCredentials(ownerIdentifier: "test-owner")
        )
        return (estate, path)
    }

    /// Create a dataset handle in `estate` with a fresh `datasetId`.
    private func captureHandle(
        _ estate: Estate,
        datasetId: UUID = UUID()
    ) async throws -> (Drawer, UUID) {
        let columns: [DatasetColumnSummary] = [
            DatasetColumnSummary(name: "user_id", dataType: "INTEGER"),
            DatasetColumnSummary(name: "label",   dataType: "TEXT"),
        ]
        let drawer = try await estate.captureDatasetHandle(
            datasetId:         datasetId,
            columns:           columns,
            rowCount:          42,
            sourceDescription: "test fixture CSV",
            room:              "test-room",
            addedBy:           "test-agent",
            sensitivity:       .normal,
            latticeAnchor:     LatticeAnchor(udcCode: "004")
        )
        return (drawer, datasetId)
    }

    // MARK: - DatasetHandleContent encode / decode

    @Test("DatasetHandleContent round-trips through JSON without data loss")
    func contentRoundTrip() throws {
        let id = UUID()
        let original = DatasetHandleContent(
            datasetId:         id,
            columns:           [DatasetColumnSummary(name: "ts", dataType: "REAL")],
            rowCount:          99,
            sourceDescription: "fixture",
            tableSignature:    nil,
            columnSignatures:  nil
        )
        let json   = try original.encode()
        let decoded = try DatasetHandleContent.decode(from: json)
        #expect(decoded == original)
    }

    @Test("DatasetHandleContent JSON keys are camelCase to match Rust serde")
    func contentJsonKeys() throws {
        // Swift Codable default produces camelCase; Rust uses
        // #[serde(rename_all = "camelCase")] — keys must be byte-identical.
        let content = DatasetHandleContent(
            datasetId:         UUID(),
            columns:           [],
            rowCount:          0,
            sourceDescription: "",
            tableSignature:    nil,
            columnSignatures:  nil
        )
        let json = try content.encode()
        #expect(json.contains("\"datasetId\""),        "expected 'datasetId' key in: \(json)")
        #expect(json.contains("\"rowCount\""),         "expected 'rowCount' key in: \(json)")
        #expect(json.contains("\"sourceDescription\""), "expected 'sourceDescription' key in: \(json)")
        #expect(json.contains("\"columns\""),          "expected 'columns' key in: \(json)")
    }

    @Test("DatasetColumnSummary serialises 'dataType' in camelCase")
    func columnSummaryDataTypeKey() throws {
        let col = DatasetColumnSummary(name: "age", dataType: "INTEGER")
        let content = DatasetHandleContent(
            datasetId:         UUID(),
            columns:           [col],
            rowCount:          0,
            sourceDescription: "",
            tableSignature:    nil,
            columnSignatures:  nil
        )
        let json = try content.encode()
        // 'dataType' (camelCase) must appear; 'data_type' (snake_case) must not.
        #expect(json.contains("\"dataType\""),     "expected camelCase 'dataType' key")
        #expect(!json.contains("\"data_type\""),   "unexpected snake_case 'data_type' key")
    }

    @Test("DatasetHandleContent decode rejects malformed JSON with invalidContent error")
    func contentDecodeBadJson() {
        #expect(throws: LocusKitError.self) {
            try DatasetHandleContent.decode(from: "not json at all")
        }
    }

    @Test("datasetHandleEmbeddingModelID sentinel is non-empty")
    func sentinelModelIDNonEmpty() {
        #expect(!datasetHandleEmbeddingModelID.isEmpty)
        #expect(datasetHandleEmbeddingModelID == "dataset-handle")
    }

    // MARK: - captureDatasetHandle bitmap verification

    @Test("captureDatasetHandle sets contentKind to .dataset")
    func captureSetContentKind() async throws {
        let (estate, _) = try await makeEstate()
        let (drawer, _) = try await captureHandle(estate)
        // Drawer.contentKind reads bits 6–11 of operationalBitmap via BitField.
        #expect(drawer.contentKind == .dataset,
                "expected .dataset, got \(drawer.contentKind)")
    }

    @Test("captureDatasetHandle sets captureChannel to .typed")
    func captureSetsTypedChannel() async throws {
        let (estate, _) = try await makeEstate()
        let (drawer, _) = try await captureHandle(estate)
        // Drawer.captureChannel reads bits 0–5 of operationalBitmap.
        #expect(drawer.captureChannel == .typed,
                "expected .typed channel, got \(drawer.captureChannel)")
    }

    @Test("captureDatasetHandle initialises state to .active")
    func captureInitialisesActiveState() async throws {
        let (estate, _) = try await makeEstate()
        let (drawer, _) = try await captureHandle(estate)
        #expect(drawer.state == .active)
    }

    @Test("captureDatasetHandle sets sensitivity in adjectiveBitmap")
    func captureSensitivity() async throws {
        let (estate, _) = try await makeEstate()
        let datasetId = UUID()
        let columns = [DatasetColumnSummary(name: "v", dataType: "INTEGER")]
        let drawer = try await estate.captureDatasetHandle(
            datasetId:         datasetId,
            columns:           columns,
            rowCount:          0,
            sourceDescription: "test",
            room:              "test-room",
            addedBy:           "test-agent",
            sensitivity:       .restricted,
            latticeAnchor:     LatticeAnchor(udcCode: "004")
        )
        // Drawer.adjectiveSensitivity reads bits 6–11 of adjectiveBitmap (cookbook §2.3).
        // (Named 'adjectiveSensitivity' to avoid collision with provenance sensitivity.)
        #expect(drawer.adjectiveSensitivity == .restricted,
                "expected .restricted, got \(drawer.adjectiveSensitivity)")
    }

    @Test("captureDatasetHandle uses dataset-handle sentinel as embeddingModelID")
    func captureEmbeddingModelIDIsSentinel() async throws {
        let (estate, _) = try await makeEstate()
        let (drawer, _) = try await captureHandle(estate)
        #expect(drawer.embeddingModelID == datasetHandleEmbeddingModelID)
    }

    @Test("captureDatasetHandle stores DatasetHandleContent as JSON in content field")
    func captureContentFieldDecodes() async throws {
        let (estate, _) = try await makeEstate()
        let datasetId = UUID()
        let columns = [DatasetColumnSummary(name: "ts", dataType: "REAL")]
        let (drawer, _) = try await captureHandle(estate, datasetId: datasetId)
        let decoded = try DatasetHandleContent.decode(from: drawer.content)
        #expect(decoded.datasetId == datasetId)
        // Row count and description from captureHandle fixture.
        #expect(decoded.rowCount == 42)
        #expect(decoded.sourceDescription == "test fixture CSV")
        _ = columns // suppress unused-variable warning
    }

    @Test("captureDatasetHandle throws invalidContent when room is empty")
    func captureEmptyRoomThrows() async throws {
        let (estate, _) = try await makeEstate()
        await #expect(throws: LocusKitError.self) {
            _ = try await estate.captureDatasetHandle(
                datasetId:         UUID(),
                columns:           [],
                rowCount:          0,
                sourceDescription: "",
                room:              "",         // <-- invalid
                addedBy:           "agent",
                latticeAnchor:     LatticeAnchor(udcCode: "004")
            )
        }
    }

    @Test("captureDatasetHandle throws invalidContent when addedBy is empty")
    func captureEmptyAddedByThrows() async throws {
        let (estate, _) = try await makeEstate()
        await #expect(throws: LocusKitError.self) {
            _ = try await estate.captureDatasetHandle(
                datasetId:         UUID(),
                columns:           [],
                rowCount:          0,
                sourceDescription: "",
                room:              "room",
                addedBy:           "",         // <-- invalid
                latticeAnchor:     LatticeAnchor(udcCode: "004")
            )
        }
    }

    @Test("captureDatasetHandle throws invalidContent when udcCode is empty")
    func captureEmptyUdcCodeThrows() async throws {
        let (estate, _) = try await makeEstate()
        await #expect(throws: LocusKitError.self) {
            _ = try await estate.captureDatasetHandle(
                datasetId:         UUID(),
                columns:           [],
                rowCount:          0,
                sourceDescription: "",
                room:              "room",
                addedBy:           "agent",
                latticeAnchor:     LatticeAnchor(udcCode: "") // <-- invalid
            )
        }
    }

    // MARK: - findDatasetHandles

    @Test("findDatasetHandles returns the created handle by datasetId")
    func findByDatasetId() async throws {
        let (estate, _) = try await makeEstate()
        let (drawer, datasetId) = try await captureHandle(estate)
        let found = try await estate.findDatasetHandles(datasetId: datasetId)
        #expect(found.count == 1)
        #expect(found.first?.id == drawer.id)
    }

    @Test("findDatasetHandles returns empty for an unknown datasetId")
    func findUnknownDatasetId() async throws {
        let (estate, _) = try await makeEstate()
        // Capture one handle so the estate is non-empty.
        _ = try await captureHandle(estate)
        let found = try await estate.findDatasetHandles(datasetId: UUID())
        #expect(found.isEmpty)
    }

    // MARK: - resolveActiveDatasetHandle

    @Test("resolveActiveDatasetHandle returns the active handle")
    func resolveActive() async throws {
        let (estate, _) = try await makeEstate()
        let (drawer, datasetId) = try await captureHandle(estate)
        let resolved = try await estate.resolveActiveDatasetHandle(datasetId: datasetId)
        #expect(resolved.id == drawer.id)
    }

    @Test("resolveActiveDatasetHandle throws drawerNotFound for unknown datasetId")
    func resolveNotFound() async throws {
        let (estate, _) = try await makeEstate()
        await #expect(throws: LocusKitError.self) {
            _ = try await estate.resolveActiveDatasetHandle(datasetId: UUID())
        }
    }

    @Test("resolveActiveDatasetHandle throws withdrawnDatasetHandle after withdraw")
    func resolveAfterWithdraw() async throws {
        let (estate, _) = try await makeEstate()
        let (drawer, datasetId) = try await captureHandle(estate)
        try await estate.withdraw(rowID: drawer.id, reason: "test withdrawal")
        await #expect(throws: LocusKitError.withdrawnDatasetHandle(datasetId: datasetId)) {
            _ = try await estate.resolveActiveDatasetHandle(datasetId: datasetId)
        }
    }

    // MARK: - Belief lifecycle on dataset-kind drawers

    @Test("contest transitions dataset handle to .contested (still cluster A)")
    func beliefContest() async throws {
        let (estate, _) = try await makeEstate()
        let (drawer, datasetId) = try await captureHandle(estate)
        try await estate.mutate(rowID: drawer.id, kind: .contest)
        // .contested is cluster A — handle is still resolvable.
        let resolved = try await estate.resolveActiveDatasetHandle(datasetId: datasetId)
        #expect(resolved.state == .contested)
    }

    @Test("resolve-contest transitions dataset handle back to .active")
    func beliefResolveContest() async throws {
        let (estate, _) = try await makeEstate()
        let (drawer, datasetId) = try await captureHandle(estate)
        try await estate.mutate(rowID: drawer.id, kind: .contest)
        try await estate.mutate(rowID: drawer.id, kind: .resolve)
        let resolved = try await estate.resolveActiveDatasetHandle(datasetId: datasetId)
        #expect(resolved.state == .active)
    }

    @Test("supersede transitions dataset handle to cluster B; resolve throws")
    func beliefSupersede() async throws {
        let (estate, _) = try await makeEstate()
        let (drawer, datasetId) = try await captureHandle(estate)
        try await estate.mutate(rowID: drawer.id, kind: .supersede)
        await #expect(throws: LocusKitError.withdrawnDatasetHandle(datasetId: datasetId)) {
            _ = try await estate.resolveActiveDatasetHandle(datasetId: datasetId)
        }
    }

    // MARK: - drawerById

    @Test("drawerById returns the stored drawer for a known id")
    func drawerByIdFound() async throws {
        let (estate, _) = try await makeEstate()
        let (drawer, _) = try await captureHandle(estate)
        let found = try await estate.drawerById(rowID: drawer.id)
        #expect(found?.id == drawer.id)
    }

    @Test("drawerById returns nil for an unknown id")
    func drawerByIdNotFound() async throws {
        let (estate, _) = try await makeEstate()
        let found = try await estate.drawerById(rowID: UUID().uuidString)
        #expect(found == nil)
    }
}
