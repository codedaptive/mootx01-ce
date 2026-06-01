// ConformanceTests.swift
// Smoke test that ConformanceRunner itself compiles correctly.
// Real backend runs live in each backend's test target.

import Testing
import PersistenceKitConformance

struct ConformanceTests {
    @Test func runnerExists() {
        // Compilation is the test: ConformanceRunner is importable.
        #expect(Bool(true))
    }
}
