// InMemoryConformanceTests.swift
// Runs the full ConformanceRunner fixture suite against InMemory.

import XCTest
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitConformance

final class InMemoryConformanceTests: XCTestCase {
    func testAllFixtures() async throws {
        let runner = ConformanceRunner(backendName: "InMemory") {
            InMemoryStorage(configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .inMemory
            ))
        }
        try await runner.runAll(in: self)
    }
}
