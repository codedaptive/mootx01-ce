// UpgradeReclaimSetTests.swift
//
// `mootx01 upgrade` reclaims the vector rows of the retired audition families
// through `VectorStore.reclaimRetiredVectorRows(retiredModelIDs:)`, fed by
// `UpgradeCommand.retiredDenseFamilyModelIDs`. LSA is the second signal of
// the default ensemble, so every populated estate carries live `lsa-v1` float
// rows and the reclaim must leave them in place. SwiftPM cannot `@testable
// import` the executable target, so this test reads the constant's literal
// out of UpgradeCommand.swift (the same source seam
// UpgradeCommandSourceTests uses) and drives the real store with exactly the
// set the command ships. A set that names `lsa-v1` fails on the surviving-row
// assertion, not on the count.

import Foundation
import Testing
import PersistenceKit
import PersistenceKitSQLite
import SynapseKit

@Suite("Upgrade vector reclaim keeps the live LSA lane", .serialized)
struct UpgradeReclaimSetTests {

    private static let filedAt = Date(timeIntervalSince1970: 1_700_000_000)

    /// The retired-model set exactly as `UpgradeCommand.swift` declares it.
    private static func shippedRetiredModelIDs() throws -> [String] {
        let commandURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MootInstallerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // apps/mootx01
            .appendingPathComponent("Sources/mootx01/Commands/UpgradeCommand.swift")
        let source = try String(contentsOf: commandURL, encoding: .utf8)
        let marker = "static let retiredDenseFamilyModelIDs = ["
        let start = try #require(source.range(of: marker)?.upperBound,
                                 "UpgradeCommand.swift declares retiredDenseFamilyModelIDs")
        let end = try #require(source[start...].firstIndex(of: "]"))
        return source[start..<end]
            .split(separator: ",")
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                  .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            .filter { !$0.isEmpty }
    }

    /// A float32 payload in the little-endian byte layout the float lane writes.
    private static func floatPayload(_ values: [Float]) -> VectorPayload {
        var bytes: [UInt8] = []
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
        }
        return VectorPayload(kind: .float32, dim: UInt32(values.count), bytes: bytes)
    }

    /// Every `model_id` left in the `vectors` table, one entry per row.
    private static func modelIDs(in storage: SQLiteStorage) async throws -> [String] {
        try await storage.rowStore.query(
            table: "vectors", where: .isTrue, orderBy: [], limit: nil, offset: nil)
            .compactMap { row -> String? in
                if case let .text(id) = row["model_id"] ?? .null { return id }
                return nil
            }
    }

    @Test("an estate carrying lsa-v1 float rows keeps them through the upgrade reclaim while its ppmi-v1 row goes")
    func liveLSARowsSurviveTheReclaim() async throws {
        let retired = try Self.shippedRetiredModelIDs()
        #expect(retired.contains("ppmi-v1"),
                "precondition: the shipped set retires ppmi-v1; got \(retired)")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mootx01-upgrade-reclaim-set-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let configuration = EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: url, busyTimeout: 5.0))

        // Seed: two live LSA float rows beside one retired-family row.
        let seed = try SQLiteStorage(configuration: configuration)
        try await seed.open(schema: VectorStore.schemaDeclaration)
        let seedStore = VectorStore(storage: seed)
        try await seedStore.addPayload(
            itemID: "drawer-a", vectorIndex: 1, payload: Self.floatPayload([1, 0, 0, 0]),
            modelID: "lsa-v1", modelVersion: "1.1.0", filedAt: Self.filedAt)
        try await seedStore.addPayload(
            itemID: "drawer-b", vectorIndex: 1, payload: Self.floatPayload([0, 1, 0, 0]),
            modelID: "lsa-v1", modelVersion: "1.1.0", filedAt: Self.filedAt)
        try await seedStore.addPayload(
            itemID: "drawer-a", vectorIndex: 1, payload: Self.floatPayload([0, 0, 1, 0]),
            modelID: "ppmi-v1", modelVersion: "1.1.0", filedAt: Self.filedAt)
        try await seedStore.flush()
        await seed.close()

        // The upgrade's reclaim on a fresh connection, opened the way
        // runVectorReclaim opens it, with the set the command ships.
        let reclaimStorage = try SQLiteStorage(configuration: configuration)
        try await reclaimStorage.open(schema: VectorStore.schemaDeclaration)
        let vectors = VectorStore(storage: reclaimStorage)
        let counts = try await vectors.reclaimRetiredVectorRows(retiredModelIDs: retired)
        let survivors = try await Self.modelIDs(in: reclaimStorage)
        await reclaimStorage.close()

        #expect(counts.retiredModelRows == 1, "only the ppmi-v1 row is retired; got \(counts)")
        #expect(survivors.filter { $0 == "lsa-v1" }.count == 2,
                "both live lsa-v1 rows survive the reclaim; rows left: \(survivors)")
        #expect(!survivors.contains("ppmi-v1"), "the ppmi-v1 row is gone; rows left: \(survivors)")
    }
}
