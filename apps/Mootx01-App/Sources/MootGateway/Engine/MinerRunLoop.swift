import Foundation
import MootIntentKit

// MARK: - MinerRunLoop  (M-ING-2 — the executor)
//
// Ties the pieces together: per-source settings (enabled/cadence, read
// straight from the miner.<id>.* defaults the settings view writes) ×
// MinerScheduler (is a run due?) × MinerEngine (idempotent fact filing).
//
// Consent posture: constructing a live miner does NOT touch EventKit or
// Contacts — only collect() during an actual run does, and only for sources
// the user enabled (shipped default is disabled). So ticking the loop is
// always safe; the first TCC prompt can only follow an explicit user
// enable. Wing/room from MinerSourceConfig are drawer-capture targeting
// (M-ING-1) reserved for future prose summaries; the fact lane facts file
// today carries provenance instead, so the executor does not consume them
// yet.

public struct MinerRunSummary: Sendable, Equatable {
    public let sourceID: String
    public let result: MinerEngine.RunResult
}

public final class MinerRunLoop: @unchecked Sendable {

    private let sources: [any MinerSource]
    // UserDefaults is itself thread-safe; runs are serialized per loop by
    // the callers (one tick task / one Mine Now at a time), so no extra
    // locking is needed around the lastRun write.
    private let defaults: UserDefaults

    public init(sources: [any MinerSource], defaults: UserDefaults = .standard) {
        self.sources = sources
        self.defaults = defaults
    }

    // Settings keys shared with MinerSourceConfig (GatewayUI writes, this
    // reads): miner.<id>.enabled / .cadence; lastRun is executor-owned.
    private func enabledKey(_ id: String) -> String { "miner.\(id).enabled" }
    private func cadenceKey(_ id: String) -> String { "miner.\(id).cadence" }
    private func lastRunKey(_ id: String) -> String { "miner.\(id).lastRun" }

    func cadence(for id: String) -> MiningCadence {
        MiningCadence(rawValue: defaults.string(forKey: cadenceKey(id)) ?? "") ?? .daily
    }

    public func lastRun(for id: String) -> Date? {
        defaults.object(forKey: lastRunKey(id)) as? Date
    }

    /// One scheduler tick: run every ENABLED source whose cadence says it is
    /// due. Skips disabled and not-yet-due sources silently.
    public func tick(now: Date, caller: any MootToolCalling) async -> [MinerRunSummary] {
        var summaries: [MinerRunSummary] = []
        for source in sources {
            let id = source.sourceID
            guard defaults.bool(forKey: enabledKey(id)) else { continue }
            guard MinerScheduler.isDue(lastRun: lastRun(for: id), cadence: cadence(for: id), now: now) else { continue }
            if let summary = await runOne(source, now: now, caller: caller) {
                summaries.append(summary)
            }
        }
        return summaries
    }

    /// "Mine Now": run one enabled source immediately, cadence ignored
    /// (manual-cadence sources run ONLY through this path).
    public func runNow(sourceID: String, now: Date, caller: any MootToolCalling) async -> MinerRunSummary? {
        guard let source = sources.first(where: { $0.sourceID == sourceID }),
              defaults.bool(forKey: enabledKey(sourceID)) else { return nil }
        return await runOne(source, now: now, caller: caller)
    }

    private func runOne(_ source: any MinerSource, now: Date, caller: any MootToolCalling) async -> MinerRunSummary? {
        guard let result = try? await MinerEngine.run(source, caller: caller) else {
            // A failed collect (consent denied, framework error) records no
            // lastRun, so the next tick retries rather than silently waiting
            // out a full cadence interval.
            return nil
        }
        defaults.set(now, forKey: lastRunKey(source.sourceID))
        return MinerRunSummary(sourceID: source.sourceID, result: result)
    }
}

#if os(macOS) && canImport(EventKit) && canImport(Contacts)
extension MinerRunLoop {
    /// The app's live loop: the two shipping sources. Constructing live
    /// miners performs no reads (see consent posture above).
    public static func liveLoop() -> MinerRunLoop {
        MinerRunLoop(sources: [CalendarMiner.live(), BirthdayMiner.live()])
    }
}
#endif
