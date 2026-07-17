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
// DISABLED BY DEFAULT (CVK-ICLOUD P5-M1):
// The driver initialises with SyncConfig.disabled. Sync only activates when
// the app explicitly calls configure(_:) with an enabled config. This ensures:
//   - No CloudKit calls at launch without a provisioned container.
//   - No entitlement requirement for builds that don't configure sync.
//   - Tests that don't call configure() see a completely inert driver.
//
// To activate CloudKit sync:
//   await MootSyncDriver.shared.configure(.cloudKitDefault)
//   await MootSyncDriver.shared.syncNow()
//
// Graceful degradation: when the CloudKit container is absent or the iCloud
// account is not signed in, enable() throws, the driver logs and stays
// disabled, and retries on the next beat. It never fabricates a sync.

public actor MootSyncDriver {

    public static let shared = MootSyncDriver()

    /// The provisioned CloudKit container (declared in project.yml entitlements).
    public static let containerIdentifier = "iCloud.com.codedaptive.mootx01"

    /// Runtime sync configuration. Defaults to `.disabled`.
    ///
    /// Updated atomically via `configure(_:)`. Changing from `.disabled` to
    /// an enabled config takes effect on the next `syncNow()` call (or
    /// immediately if called while `syncNow()` is running — the running call
    /// sees the old config; the next call sees the new one).
    private var config: SyncConfig = .disabled

    private var controller: SyncController?
    private var enabled = false
    private let log = Logger(subsystem: "com.codedaptive.mootx01", category: "sync-driver")

    private init() {}

    /// Update the sync configuration.
    ///
    /// Call this at app launch (or in test setup) to activate iCloud sync.
    /// Calling with `.disabled` administratively disables sync — the next
    /// `syncNow()` call will dismantle the current engine if one is active.
    ///
    /// - Parameter newConfig: The runtime sync configuration to apply.
    public func configure(_ newConfig: SyncConfig) async {
        // If the new config disables sync, tear down the active engine
        // so the next syncNow() doesn't re-enable it.
        if !newConfig.enabled, enabled {
            try? await controller?.disable()
            controller = nil
            enabled = false
            log.info("sync disabled via configure()")
        }
        config = newConfig
    }

    /// Enable-if-needed, then sync. Called on the app's ambient beats.
    ///
    /// Returns `false` when:
    ///   - The current config is `.disabled`.
    ///   - CloudKit is unavailable (no container, no account, network error).
    ///   - The estate bridge is not yet available.
    ///
    /// Returns `true` when push/pull completes successfully, including the
    /// zero-delta case (nothing to sync).
    @discardableResult
    public func syncNow() async -> Bool {
        // Administratively disabled — do not attempt sync.
        guard config.enabled else {
            return false
        }

        do {
            if !enabled {
                guard let bridge = try? await GatewayRuntime.shared.bridge() else { return false }
                let controller = SyncController(bridge: bridge)

                // Build the engine from the configured backend.
                let engine: any SyncEngine
                switch config.backend {
                case .none:
                    // enabled=true but backend=none is not a useful combination,
                    // but handle it defensively: nothing to sync.
                    return false
                case .cloudKit(let containerIdentifier):
                    engine = CloudKitSyncEngine(containerIdentifier: containerIdentifier)
                }

                // Enable with the sensitivity ceiling from config.
                // SyncController.enable() wraps storage in SensitivityFilteredStorage
                // (Perkins Amendment 1) and registers with GeniusLocusKit for status.
                try await controller.enable(
                    engine: engine,
                    manifest: MootEstateSyncManifest.standard(),
                    ceiling: config.syncCeiling,
                    backendName: backendName(for: config.backend)
                )
                self.controller = controller
                enabled = true
                log.info("cloud sync enabled (ceiling: \(self.config.syncCeiling.rawValue, privacy: .public))")
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

    // MARK: - Private helpers

    private func backendName(for backend: SyncConfig.Backend) -> String {
        switch backend {
        case .none: return "none"
        case .cloudKit: return "cloudkit"
        }
    }
}
