// PostgreSQLConformanceTests.swift
// Gated on POSTGRES_TEST_URL. Each run uses a fresh schema (kit IDs
// are unique per test invocation) to avoid cross-test interference.

import XCTest
import PersistenceKit
import PersistenceKitPostgreSQL
import PersistenceKitConformance

final class PostgreSQLConformanceTests: XCTestCase {
    func testAllFixtures() async throws {
        guard let cs = ProcessInfo.processInfo.environment["POSTGRES_TEST_URL"] else {
            throw XCTSkip("POSTGRES_TEST_URL not set")
        }
        let runner = ConformanceRunner(backendName: "PostgreSQL") {
            PostgreSQLStorage(configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .postgresql(connectionString: cs, poolSize: 2)
            ))
        }
        try await runner.runAll(in: self)
    }
}
