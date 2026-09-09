import Foundation
import PersistenceKit
import PersistenceKitSQLite
import Testing

struct FrozenSchemaRepresentationTests {
    @Test("frozen admission accepts migrated TEXT JSON without rewriting it")
    func migratedJSONText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: directory.appendingPathComponent("estate.sqlite"), busyTimeout: 5)))
        func schema(_ type: ColumnType) -> SchemaDeclaration {
            SchemaDeclaration(kitID: "MigratedJSON", version: 1, tables: [
                TableDeclaration(name: "vectors", columns: [
                    .text("id", nullable: false), ColumnDeclaration(name: "ext", type: type)
                ], primaryKey: ["id"])
            ])
        }
        try await storage.open(schema: schema(.text))
        _ = try await storage.rowStore.insert(table: "vectors", values: ["id": .text("one"), "ext": .text("{\"cv\":\"legacy\"}")])
        try await storage.openExisting(schema: schema(.json))
        let rows = try await storage.rowStore.query(table: "vectors", where: .eq(Column(table: "vectors", name: "id"), .text("one")))
        #expect(rows.count == 1)
        #expect(rows.first?["ext"] == .text("{\"cv\":\"legacy\"}"))
        // The compatibility exception is specific to JSON, not arbitrary types.
        await #expect(throws: (any Error).self) { try await storage.openExisting(schema: schema(.int)) }
        // Admission must leave the physical TEXT representation usable as-is.
        try await storage.openExisting(schema: schema(.text))
        await storage.close()
    }
}
