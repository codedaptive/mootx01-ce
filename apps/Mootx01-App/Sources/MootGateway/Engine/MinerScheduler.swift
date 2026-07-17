import Foundation

// MARK: - MinerScheduler  (M-ING-2 — cadence policy)
//
// User-configurable cadence per Bob ruling D7: daily / weekly / manual.
// Pure next-run computation so the policy is unit-testable; the executors
// (menu-bar-mode timer on macOS per D9, BGTaskScheduler on the iOS leg)
// consume `nextRun(after:)` and own nothing but the clock.

/// Per-source mining cadence. Raw values are the persisted setting.
public enum MiningCadence: String, Sendable, CaseIterable {
    /// Mine once per day.
    case daily
    /// Mine once per week.
    case weekly
    /// Never scheduled — the user fires "Mine Now" explicitly.
    case manual

    /// Seconds between runs; nil means never scheduled.
    public var interval: TimeInterval? {
        switch self {
        case .daily: return 86_400
        case .weekly: return 7 * 86_400
        case .manual: return nil
        }
    }
}

public enum MinerScheduler {

    /// When the next run is due. `lastRun == nil` (never mined) is due
    /// immediately for scheduled cadences; manual is never due.
    public static func nextRun(after lastRun: Date?, cadence: MiningCadence, now: Date) -> Date? {
        guard let interval = cadence.interval else { return nil }
        guard let lastRun else { return now }
        return lastRun.addingTimeInterval(interval)
    }

    /// True when a scheduled run should fire at `now`.
    public static func isDue(lastRun: Date?, cadence: MiningCadence, now: Date) -> Bool {
        guard let next = nextRun(after: lastRun, cadence: cadence, now: now) else { return false }
        return next <= now
    }
}
