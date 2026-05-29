// SQLiteConformanceTests.swift
// Runs the full ConformanceRunner fixture suite against SQLite.

import XCTest
import PersistenceKit
import PersistenceKitSQLite
import PersistenceKitConformance

final class SQLiteConformanceTests: XCTestCase {
    func testAllFixtures() async throws {
        let runner = ConformanceRunner(backendName: "SQLite") {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("storagekit-conf-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("estate.sqlite")
            return try SQLiteStorage(configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .sqlite(url: file)
            ))
        }
        try await runner.runAll(in: self)
    }
}
