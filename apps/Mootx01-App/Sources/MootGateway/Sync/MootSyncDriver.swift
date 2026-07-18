import Foundation
import ConvergenceKit
import ConvergenceKitCloudKit
import OSLog
#if canImport(CloudKit)
import CloudKit
#endif

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
//
// APNs PUSH ACCELERATOR (CVK-ICLOUD P5-M2):
// When running as the Mac/iOS app (moot-mgr), the host registers for APNs
// silent push (the resident launchd process cannot). On receiving a
// CloudKit zone-change notification, the app calls:
//
//   let consumed = await MootSyncDriver.shared.handleRemoteNotification(userInfo: userInfo)
//
// This forwards the payload to CloudKitSyncEngine.handleRemoteNotification(userInfo:),
// which verifies the zone ID, emits SyncEvent.remoteWakeReceived, and calls
// nudge() — firing an immediate pull and resetting the poll tier to fast.
// If the engine is not yet enabled, handleRemoteNotification returns false
// (graceful: the polling path remains the correctness guarantee, B-11).

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

    // Retained reference to the active CloudKitSyncEngine for APNs forwarding
    // (CVK-ICLOUD P5-M2). Only non-nil while the engine is enabled. Cleared by
    // configure(.disabled) and when syncNow() tears down a failed enable. The
    // SyncController also holds this engine instance (passed via enable()); the
    // second reference here is intentional — SyncController provides no accessor
    // for its injected engine, and APNs forwarding needs the concrete type.
    private var cloudKitEngine: CloudKitSyncEngine?

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
            cloudKitEngine = nil   // clear APNs-forwarding reference (P5-M2)
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

                // Build the engine from the configured backend. For the CloudKit
                // backend, retain a typed reference for APNs forwarding (P5-M2).
                let engine: any SyncEngine
                var newCKEngine: CloudKitSyncEngine?
                switch config.backend {
                case .none:
                    // enabled=true but backend=none is not a useful combination,
                    // but handle it defensively: nothing to sync.
                    return false
                case .cloudKit(let containerIdentifier):
                    let ck = CloudKitSyncEngine(containerIdentifier: containerIdentifier)
                    engine = ck
                    newCKEngine = ck
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
                self.cloudKitEngine = newCKEngine
                enabled = true
                log.info("cloud sync enabled (ceiling: \(self.config.syncCeiling.rawValue, privacy: .public))")

                // APNs zone subscription (P5-M2): register after successful enable so
                // CloudKit silent-push notifications arrive for this engine's zone.
                // Graceful: subscription failure is logged and does not abort the sync
                // path — polling (AdaptivePollScheduler / beat-driven syncNow) remains
                // the correctness guarantee (CONVERGENCEKIT_SPEC B-11).
                if let ck = newCKEngine {
                    do {
                        try await ck.registerZoneSubscription()
                        log.info("CloudKit zone subscription registered (P5-M2)")
                    } catch {
                        log.warning("zone subscription registration skipped: \(String(describing: error), privacy: .public) — polling continues")
                    }
                }
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
            cloudKitEngine = nil   // clear APNs-forwarding reference (P5-M2)
            log.error("cloud sync skipped: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: - APNs push accelerator (CVK-ICLOUD P5-M2)

    /// Forward a remote notification payload to the active CloudKit engine.
    ///
    /// Call from the host app's notification delegate:
    /// ```swift
    /// // macOS (AppKit)
    /// func application(_ application: NSApplication,
    ///                  didReceiveRemoteNotification userInfo: [String: Any]) {
    ///     Task { await MootSyncDriver.shared.handleRemoteNotification(userInfo: userInfo) }
    /// }
    ///
    /// // iOS (UIKit)
    /// func application(_ application: UIApplication,
    ///                  didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    ///                  fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    ///     Task {
    ///         let consumed = await MootSyncDriver.shared.handleRemoteNotification(userInfo: userInfo)
    ///         completionHandler(consumed ? .newData : .noData)
    ///     }
    /// }
    /// ```
    ///
    /// Returns `true` if the payload was consumed by the active engine (zone name
    /// matched, nudge fired). Returns `false` when no engine is enabled, the
    /// payload is not a CloudKit zone-change notification, or the zone doesn't
    /// match — the caller should pass `noData` to the fetch completion handler.
    ///
    /// Graceful: if sync is not yet enabled (configure() not called, or engine
    /// failed to start), this is a no-op returning false. The polling path remains
    /// the correctness guarantee (CONVERGENCEKIT_SPEC B-11).
    @discardableResult
    public func handleRemoteNotification(userInfo: [AnyHashable: Any]) async -> Bool {
        guard let engine = cloudKitEngine else {
            // Engine not enabled — not an error. APNs accelerator is best-effort;
            // polling continues unchanged.
            return false
        }
        // [AnyHashable: Any] is not Sendable because Any is unconstrained. CloudKit
        // silent-push userInfo payloads contain only Objective-C bridge types
        // (NSString, NSDictionary, NSNumber) which are all thread-safe. Box in an
        // @unchecked Sendable wrapper so the Swift 6 region-isolation checker accepts
        // the cross-isolation forwarding into the Task.detached below.
        struct SendableUserInfo: @unchecked Sendable {
            let value: [AnyHashable: Any]
        }
        let payload = SendableUserInfo(value: userInfo)
        // Run the engine call in a detached task to leave the actor's isolation domain.
        // engine is Sendable (CloudKitSyncEngine: Sendable); payload is @unchecked Sendable.
        let consumed = await Task.detached {
            await engine.handleRemoteNotification(userInfo: payload.value)
        }.value
        if consumed {
            log.info("APNs zone-change notification consumed, nudge fired (P5-M2)")
        }
        return consumed
    }

    // MARK: - Private helpers

    private func backendName(for backend: SyncConfig.Backend) -> String {
        switch backend {
        case .none: return "none"
        case .cloudKit: return "cloudkit"
        }
    }
}
