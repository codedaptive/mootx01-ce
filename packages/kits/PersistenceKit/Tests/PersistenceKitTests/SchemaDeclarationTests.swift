// SchemaDeclarationTests.swift
//
// Schema and default-value coverage for PersistenceKit core types.
// Pins the ColumnDeclaration convenience constructors (`.uuid`/`.bitmap`/… factories),
// struct defaults (TableDeclaration.appendOnly, IndexDeclaration.unique,
// SchemaDeclaration.indices/migrations), Migration, and EstateConfiguration's
// default encryption mode. SQLite encryption behavior (Mode 1/2/3) lives in
// `EncryptionWiringTests.swift`.

import Testing
import Foundation
import PersistenceKit

struct SchemaDeclarationTests {

    // MARK: - ColumnDeclaration convenience constructors

    @Test func columnFactoriesSetTypeAndDefaults() {
        let id = ColumnDeclaration.uuid("id")
        #expect(id.type == .uuid)
        #expect(id.nullable == false)
        #expect(id.defaultValue == nil)

        // bitmap mints a default of .bitmap(0) unless overridden.
        #expect(ColumnDeclaration.bitmap("flags").defaultValue == .bitmap(0))
        #expect(ColumnDeclaration.bitmap("flags", default: 7).defaultValue == .bitmap(7))

        let notes = ColumnDeclaration.text("notes", nullable: true)
        #expect(notes.type == .text)
        #expect(notes.nullable == true)
    }

    @Test func everyColumnFactoryMapsToItsType() {
        #expect(ColumnDeclaration.timestamp("t").type == .timestamp)
        #expect(ColumnDeclaration.int("i").type == .int)
        #expect(ColumnDeclaration.float("f").type == .float)
        #expect(ColumnDeclaration.bool("b").type == .bool)
        #expect(ColumnDeclaration.blob("bl").type == .blob)
        #expect(ColumnDeclaration.json("j").type == .json)
        #expect(ColumnDeclaration.hlc("h").type == .hlc)
        #expect(ColumnDeclaration.fingerprint("fp").type == .fingerprint)
    }

    // MARK: - Struct defaults

    @Test func tableDeclarationDefaults() {
        let t = TableDeclaration(
            name: "drawers",
            columns: [.uuid("id")],
            primaryKey: ["id"]
        )
        #expect(t.uniqueConstraints.isEmpty)
        #expect(t.generatedColumns.isEmpty)
        #expect(t.appendOnly == false)
    }

    @Test func indexDeclarationDefaultsToNonUnique() {
        let idx = IndexDeclaration(name: "idx", table: "drawers", columns: ["adjective"])
        #expect(idx.unique == false)
        #expect(idx.columns == ["adjective"])
    }

    @Test func schemaDeclarationDefaultsEmptyIndicesAndMigrations() {
        let schema = SchemaDeclaration(
            kitID: "K",
            version: 1,
            tables: [TableDeclaration(name: "t", columns: [.uuid("id")], primaryKey: ["id"])]
        )
        #expect(schema.indices.isEmpty)
        #expect(schema.migrations.isEmpty)
        #expect(schema.version == 1)
    }

    @Test func migrationCarriesVersionsAndOperations() {
        let m = Migration(
            fromVersion: 1,
            toVersion: 2,
            operations: [.addColumn(table: "drawers", column: .text("notes", nullable: true))]
        )
        #expect(m.fromVersion == 1)
        #expect(m.toVersion == 2)
        #expect(m.operations.count == 1)
    }

    // MARK: - EstateConfiguration

    @Test func estateConfigurationDefaultsToPlaintext() {
        let cfg = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        #expect(cfg.encryptionConfig.mode == .plaintext)
    }

    @Test func estateConfigurationPreservesEstateID() {
        let id = UUID()
        let cfg = EstateConfiguration(estateID: id, backend: .inMemory)
        #expect(cfg.estateID == id)
    }
}
