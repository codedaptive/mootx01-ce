// LadderHoleTests.swift
//
// The runner's refusal for a stored version its ladder has no hop for, and
// the repair surface for an estate stamped current while a hop was skipped.
// Twin of Rust `ladder_hole_tests.rs`.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitSQLite

@Suite("Ladder holes and repair")
struct LadderHoleTests {

    private func makeStorage(_ url: URL) throws -> SQLiteStorage {
        try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0)
        ))
    }

    private func tempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ladder-hole-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("estate.sqlite")
    }

    private static let things = TableDeclaration(
        name: "things", columns: [.text("id"), .text("name")], primaryKey: ["id"])

    /// Version `v` of a kit whose only table is `things`, carrying `hops`.
    private static func kit(version: Int, hops: [Migration]) -> SchemaDeclaration {
        SchemaDeclaration(kitID: "HoleKit", version: version, tables: [things], migrations: hops)
    }

    private static func addColumn(_ name: String) -> SchemaOperation {
        .addColumn(table: "things", column: .text(name, nullable: true))
    }

    @Test("a hole is a nonzero stored version inside the ladder's range with no hop")
    func holeDefinition() {
        let ladder = Self.kit(version: 20, hops: [
            Migration(fromVersion: 10, toVersion: 19, operations: [Self.addColumn("a")]),
            Migration(fromVersion: 19, toVersion: 20, operations: [Self.addColumn("b")]),
        ])
        #expect(!ladder.ladderHasHole(atStoredVersion: 0), "fresh is never a hole")
        #expect(!ladder.ladderHasHole(atStoredVersion: 10))
        #expect(!ladder.ladderHasHole(atStoredVersion: 19))
        #expect(!ladder.ladderHasHole(atStoredVersion: 20), "current is never a hole")
        #expect(!ladder.ladderHasHole(atStoredVersion: 21), "newer than declared is not a hole")
        for inside in 11...18 {
            #expect(ladder.ladderHasHole(atStoredVersion: inside), "\(inside) has no hop")
        }
        #expect(!ladder.ladderHasHole(atStoredVersion: 3), "below every hop is the base-CREATE convention")
        let bare = Self.kit(version: 4, hops: [])
        #expect(!bare.ladderHasHole(atStoredVersion: 2), "no ladder, no hole")
    }

    @Test("ladder columns are every addColumn from the requested hop up, once each")
    func ladderColumns() {
        let ladder = Self.kit(version: 20, hops: [
            Migration(fromVersion: 10, toVersion: 19, operations: [Self.addColumn("a"), Self.addColumn("a")]),
            Migration(fromVersion: 19, toVersion: 20, operations: [Self.addColumn("b"), .dropColumn(table: "things", columnName: "z")]),
        ])
        #expect(ladder.ladderColumns(fromVersion: 10) == [
            LadderColumn(table: "things", column: "a"), LadderColumn(table: "things", column: "b"),
        ])
        #expect(ladder.ladderColumns(fromVersion: 19) == [LadderColumn(table: "things", column: "b")])
    }

    @Test("opening at a hole is refused and the ledger is left where it was")
    func holeRefused() async throws {
        let url = tempURL()
        do {
            // Stamp 12 with a ladder-less declaration: no hop, no hole.
            let stamp = try makeStorage(url)
            try await stamp.open(schema: Self.kit(version: 12, hops: []))
            #expect(try await stamp.currentSchemaVersion(for: "HoleKit") == 12)
            await stamp.close()
        }
        let storage = try makeStorage(url)
        let ladder = Self.kit(version: 20, hops: [
            Migration(fromVersion: 10, toVersion: 19, operations: [Self.addColumn("a")]),
            Migration(fromVersion: 19, toVersion: 20, operations: [Self.addColumn("b")]),
        ])
        await #expect(throws: StorageError.self) {
            try await storage.open(schema: ladder)
        }
        // Nothing moved: the ledger still says 12 and the hop's column was
        // never added — so the estate cannot read as current without it.
        #expect(try await storage.currentSchemaVersion(for: "HoleKit") == 12)
        #expect(try await storage.missingLadderColumns(schema: ladder, fromVersion: 10).count == 2)
        await storage.close()
    }

    @Test("a stored version below every hop still opens by the base-CREATE convention")
    func belowLadderOpens() async throws {
        let url = tempURL()
        do {
            let stamp = try makeStorage(url)
            try await stamp.open(schema: Self.kit(version: 1, hops: []))
            await stamp.close()
        }
        let storage = try makeStorage(url)
        let ladder = Self.kit(version: 3, hops: [
            Migration(fromVersion: 2, toVersion: 3, operations: [Self.addColumn("late")]),
        ])
        try await storage.open(schema: ladder)
        #expect(try await storage.currentSchemaVersion(for: "HoleKit") == 3)
        #expect(try await storage.missingLadderColumns(schema: ladder, fromVersion: 2).isEmpty)
        await storage.close()
    }

    @Test("an estate stamped current without its objects is repaired by replaying the ladder")
    func stampedWithoutObjectsIsRepaired() async throws {
        let url = tempURL()
        let ladder = Self.kit(version: 20, hops: [
            Migration(fromVersion: 10, toVersion: 19, operations: [Self.addColumn("a")]),
            Migration(fromVersion: 19, toVersion: 20, operations: [Self.addColumn("b")]),
        ])
        do {
            // The pre-fix runner's outcome: ledger 20, `things` without a or b.
            let stamp = try makeStorage(url)
            try await stamp.open(schema: Self.kit(version: 20, hops: []))
            await stamp.close()
        }
        let storage = try makeStorage(url)
        try await storage.open(schema: ladder)   // current: nothing to migrate
        let missing = try await storage.missingLadderColumns(schema: ladder, fromVersion: 10)
        #expect(missing == [LadderColumn(table: "things", column: "a"), LadderColumn(table: "things", column: "b")])
        try await storage.replayLadder(schema: ladder, fromVersion: 10)
        #expect(try await storage.missingLadderColumns(schema: ladder, fromVersion: 10).isEmpty)
        #expect(try await storage.currentSchemaVersion(for: "HoleKit") == 20, "the ledger is not touched by a replay")
        // A second replay on the healthy estate is a no-op.
        try await storage.replayLadder(schema: ladder, fromVersion: 10)
        #expect(try await storage.missingLadderColumns(schema: ladder, fromVersion: 10).isEmpty)
        await storage.close()
    }
}
