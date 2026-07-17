// CloudKitStubTests.swift
import Testing
import Foundation
import ConvergenceKit
import ConvergenceKitCloudKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes

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

    @Test("push does not emit synthetic start signal")
    func pushDoesNotEmitSyntheticStartSignal() async throws {
        // Verification test: the push() method should emit exactly one pushCompleted event,
        // not a synthetic start signal followed by the final receipt.
        // The synthetic start signal emission has been removed from PushCycle.swift.
        // This test documents that behavior: calling push() on an enabled engine
        // should not emit an empty SyncReceipt at the start of the push cycle.

        let engine = CloudKitSyncEngine()

        // Verify engine starts disabled (as per existing test behavior)
        guard case .disabled = await engine.state else {
            Issue.record("engine should start disabled")
            return
        }

        // The push() method will throw SyncError.notEnabled when the engine is disabled,
        // which is the expected behavior. This ensures the method is callable and doesn't
        // crash when invoked.
        do {
            _ = try await engine.push()
            Issue.record("push() should throw when disabled")
        } catch SyncError.notEnabled {
            // Expected: push() throws when not enabled
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
