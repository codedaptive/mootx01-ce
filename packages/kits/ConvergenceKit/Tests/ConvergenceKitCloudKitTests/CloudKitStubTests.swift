// CloudKitStubTests.swift
import XCTest
import ConvergenceKit
import ConvergenceKitCloudKit

final class CloudKitStubTests: XCTestCase {
    func testStubExists() async {
        let engine = CloudKitSyncEngine()
        if case .disabled = await engine.state {
            // ok
        } else {
            XCTFail("expected disabled")
        }
    }
}
