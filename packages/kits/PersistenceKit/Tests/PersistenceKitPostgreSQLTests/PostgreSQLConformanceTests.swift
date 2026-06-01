// PostgreSQLConformanceTests.swift
// Gated on POSTGRES_TEST_URL. Each run uses a fresh schema (kit IDs
// are unique per test invocation) to avoid cross-test interference.
// When POSTGRES_TEST_URL is unset the test returns early (vacuously
// green) — the swift-testing analogue of the prior XCTSkip.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitPostgreSQL
import PersistenceKitConformance

struct PostgreSQLConformanceTests {
    @Test func allFixtures() async throws {
        guard let cs = ProcessInfo.processInfo.environment["POSTGRES_TEST_URL"] else {
            return  // POSTGRES_TEST_URL not set
        }
        let runner = ConformanceRunner(backendName: "PostgreSQL") {
            PostgreSQLStorage(configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .postgresql(connectionString: cs, poolSize: 2)
            ))
        }
        try await runner.runAll()
    }
}
