import Foundation
import ConvergenceKit
import ConvergenceKitCloudKit
import OSLog

// MARK: - MootSyncDriver  (app-lifecycle sync, CloudKit)
//
// Drives ConvergenceKit's CloudKitSyncEngine from the app's ambient beats
// (launch, foregrounding, on-power tick) — the same moments ShareInboxDrain
// and WidgetSnapshotRefresher use. Enables once against the estate's live
// Storage (via SyncController), then push/pulls each beat.
//
// Inert until the iCloud container is provisioned: without an available
// CloudKit account enable() fails, the driver logs and stays disabled, and
// retries on the next beat — it never fabricates a sync. So this is safe to
// wire now; it activates when the container lands.

public actor MootSyncDriver {

    public static let shared = MootSyncDriver()

    /// The provisioned CloudKit container (declared in project.yml entitlements).
    public static let containerIdentifier = "iCloud.com.codedaptive.mootx01"

    private var controller: SyncController?
    private var enabled = false
    private let log = Logger(subsystem: "com.codedaptive.mootx01", category: "sync-driver")

    private init() {}

    /// Enable-if-needed, then sync. Called on the app's ambient beats.
    @discardableResult
    public func syncNow() async -> Bool {
        do {
            if !enabled {
                guard let bridge = try? await GatewayRuntime.shared.bridge() else { return false }
                let controller = SyncController(bridge: bridge)
                let engine = CloudKitSyncEngine(containerIdentifier: Self.containerIdentifier)
                try await controller.enable(
                    engine: engine, manifest: MootEstateSyncManifest.standard())
                self.controller = controller
                enabled = true
                log.info("cloud sync enabled")
            }
            let (pulled, pushed) = try await controller!.sync()
            if pulled.pulled > 0 || pushed.pushed > 0 {
                log.info("cloud sync: pulled \(pulled.pulled), pushed \(pushed.pushed)")
            }
            return true
        } catch {
            // No container / no iCloud account / zone error: stay disabled and
            // retry next beat. Never a fabricated success.
            enabled = false
            controller = nil
            log.error("cloud sync skipped: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
