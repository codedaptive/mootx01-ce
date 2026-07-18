import Foundation
import MootIntentKit
import OSLog
#if canImport(WidgetKit)
import WidgetKit
#endif

// MARK: - WidgetSnapshotRefresher  (recall widget, app side)
//
// Rewrites the widget's derived projection from a publicOnly recall and asks
// WidgetKit to reload. Called at the same ambient moments as ShareInboxDrain
// (launch, iOS foregrounding/refresh, macOS hourly tick) — the projection's
// staleness is bounded by those moments plus WidgetKit's own timeline cadence.
//
// Export policy: the recall runs with publicOnly:true (filter:exportable),
// the same §6.2 serve-out gate Spotlight donation applies. Private drawers
// can never reach the projection file, regardless of what the widget does.
//
// RelevantEntities (wwdc2026-345) is deliberately NOT wired: the shipping
// AppIntents interface offers only an audio AppEntityContext, and donating
// memory drawers under an audio context would be contextual theater. The
// donation slots in here (beside the WidgetKit reload) once a fitting
// context ships.

public enum WidgetSnapshotRefresher {

    private static let log = Logger(subsystem: "com.codedaptive.mootx01", category: "widget-snapshot")

    /// How many entries the projection carries — enough for the largest
    /// widget family the app ships (systemMedium shows up to 4).
    public static let projectionLimit = 6

    /// Refresh the projection. Returns the entry count written, or nil when
    /// the group container or bridge is unavailable (logged, never fatal —
    /// these are ambient moments).
    @discardableResult
    public static func refreshNow() async -> Int? {
        let store: WidgetSnapshotStore
        do {
            store = try WidgetSnapshotStore.groupStore()
        } catch {
            log.error("widget snapshot store unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard let bridge = try? await GatewayRuntime.shared.bridge() else {
            log.error("widget snapshot skipped: gateway bridge unavailable")
            return nil
        }
        let drawers = await bridge.recallDrawers(query: "", publicOnly: true, limit: projectionLimit)
        do {
            try store.write(.from(drawers: drawers, updatedAt: Date()))
        } catch {
            log.error("widget snapshot write failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        return drawers.count
    }
}
