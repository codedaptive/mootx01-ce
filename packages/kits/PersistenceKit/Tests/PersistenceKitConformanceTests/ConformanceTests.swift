// ConformanceTests.swift
// Smoke test that ConformanceRunner itself compiles correctly.
// Real backend runs live in each backend's test target.

import XCTest
import PersistenceKitConformance

final class ConformanceTests: XCTestCase {
    func testRunnerExists() {
        // Compilation is the test: ConformanceRunner is importable.
        XCTAssertTrue(true)
    }
}
