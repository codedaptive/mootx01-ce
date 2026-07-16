import Foundation
import MootIntentKit
import OSLog

// MARK: - ShareInboxDrain  (A4b — host side of the Share-Sheet handoff)
//
// The host-app drain moments call this: window launch, iOS foregrounding /
// background refresh, and the macOS hourly miner tick. Each pass files every
// spooled share into the estate through the live bridge (CaptureSink), so
// content shared while the app was closed lands at the next app run.
//
// Failure posture: an unavailable group container (a build without the
// app-group entitlement) or an unconfigured runtime logs and returns nil —
// the drain moments are ambient, so they must never crash the app — but the
// condition is named in the log, never silently swallowed.

public enum ShareInboxDrain {

    private static let log = Logger(subsystem: "com.codedaptive.mootx01", category: "share-inbox")

    /// Drain the app-group share spool into the estate. Returns what the
    /// pass did, or nil when the spool or bridge is unavailable.
    @discardableResult
    public static func drainNow() async -> ShareInboxSpool.DrainOutcome? {
        let spool: ShareInboxSpool
        do {
            spool = try ShareInboxSpool.groupSpool()
        } catch {
            log.error("share spool unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard let bridge = try? await GatewayRuntime.shared.bridge() else {
            log.error("share drain skipped: gateway bridge unavailable")
            return nil
        }
        let outcome = await spool.drain(using: bridge)
        if outcome.captured > 0 || outcome.remaining > 0 {
            log.info("share drain: captured \(outcome.captured), remaining \(outcome.remaining)")
        }
        return outcome
    }
}
