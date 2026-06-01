// InMemoryConformanceTests.swift
// Runs the full ConformanceRunner fixture suite against InMemory.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitConformance

struct InMemoryConformanceTests {
    @Test func allFixtures() async throws {
        let runner = ConformanceRunner(backendName: "InMemory") {
            InMemoryStorage(configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .inMemory
            ))
        }
        try await runner.runAll()
    }
}
