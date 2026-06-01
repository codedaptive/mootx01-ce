// CloudKitStubTests.swift
import Testing
import ConvergenceKit
import ConvergenceKitCloudKit

@Suite("CloudKitSyncEngine stub")
struct CloudKitStubTests {
    @Test("engine starts disabled")
    func stubExists() async {
        let engine = CloudKitSyncEngine()
        guard case .disabled = await engine.state else {
            Issue.record("expected disabled")
            return
        }
    }
}
