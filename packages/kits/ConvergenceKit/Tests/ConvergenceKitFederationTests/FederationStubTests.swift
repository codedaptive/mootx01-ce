// FederationStubTests.swift
import Testing
import ConvergenceKit
import ConvergenceKitFederation

@Suite("FederationSyncEngine stub")
struct FederationStubTests {
    @Test("engine starts disabled")
    func stubExists() async {
        let engine = FederationSyncEngine()
        guard case .disabled = await engine.state else {
            Issue.record("expected disabled")
            return
        }
    }
}
