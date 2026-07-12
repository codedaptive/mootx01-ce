import Testing
import Foundation
import ConvergenceKit
import ConvergenceKitNone
@testable import MootGateway

// MARK: - SyncController tests
//
// Drives the controller with ConvergenceKit's real NoSyncEngine over a live
// in-memory estate — the same wiring pattern AriaMcpKit's EstateStatusSyncTests
// uses. Proves the controller enables against the estate's own Storage and
// gates push/pull on being enabled; the CloudKit engine swaps in for real
// devices without changing this contract.

@Suite("SyncController — drives an injected SyncEngine over the estate storage")
struct SyncControllerTests {

    private func manifest() -> SyncManifest {
        // Empty table list: NoSyncEngine ignores it, and this test asserts
        // orchestration, not schema mapping (real table names are a
        // schema-verified caller concern, not guessed here).
        SyncManifest(kitID: "mootx01-app-test", schemaVersion: 1,
                     zoneIdentifier: "test.zone", tables: [])
    }

    @Test("enable wires the estate's own storage; push/pull run through the engine")
    func enablePushPull() async throws {
        let bridge = try await MootBridge.attachInMemory()
        let controller = SyncController(bridge: bridge)

        try await controller.enable(engine: NoSyncEngine(), manifest: manifest())
        _ = try await controller.push()   // no-op engine: must not throw once enabled
        _ = try await controller.pull()
        let (pulled, pushed) = try await controller.sync()
        #expect(pulled.pushed == 0 && pushed.pushed == 0, "the no-op engine moves nothing")
    }

    @Test("push before enable throws — never a silent no-op")
    func pushBeforeEnableThrows() async throws {
        let bridge = try await MootBridge.attachInMemory()
        let controller = SyncController(bridge: bridge)
        await #expect(throws: SyncController.SyncControllerError.self) {
            _ = try await controller.push()
        }
    }

    @Test("disable clears the engine; a later push throws again")
    func disableClears() async throws {
        let bridge = try await MootBridge.attachInMemory()
        let controller = SyncController(bridge: bridge)
        try await controller.enable(engine: NoSyncEngine(), manifest: manifest())
        try await controller.disable()
        await #expect(throws: SyncController.SyncControllerError.self) {
            _ = try await controller.pull()
        }
    }
}
