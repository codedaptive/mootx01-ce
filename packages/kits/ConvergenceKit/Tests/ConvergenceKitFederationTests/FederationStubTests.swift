// FederationStubTests.swift
import XCTest
import ConvergenceKit
import ConvergenceKitFederation

final class FederationStubTests: XCTestCase {
    func testStubExists() async {
        let engine = FederationSyncEngine()
        if case .disabled = await engine.state {
            // ok
        } else {
            XCTFail("expected disabled")
        }
    }
}
