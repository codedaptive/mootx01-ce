import Foundation
import AppIntents
import MootIntentKit

// MARK: - DailyIngestIntent  (M-ING-2 — the Shortcuts cadence hook)
//
// One unattended mining tick as an App Intent, so a personal Shortcuts
// automation (e.g. "every day at 07:00") can drive ingest cadence without
// the app's own hourly timer being the only path. perform() delegates to
// the exact tick the menu-bar timer runs.
//
// Consent posture (inherited from MinerRunLoop.tick): a tick may USE an
// existing Calendar/Contacts grant but never requests one and never
// triggers a TCC prompt — disabled and unauthorized sources are skipped
// silently. Safe to fire unattended; the first prompt can only ever come
// from an explicit user enable in Miners settings (Mine Now / Set Up).
//
// This intent lives in MootGateway (not MootIntentKit) because it wraps the
// miner executor, which is app-side; the metadata extractor picks it up from
// the linked package product the same way it does MootIntentKit's intents.

#if canImport(EventKit) && canImport(Contacts)
public struct DailyIngestIntent: MootEstateIntent {

    public static let title: LocalizedStringResource = "Run Daily Ingest"

    public static let description = IntentDescription(
        "Run one mining tick: every enabled miner whose cadence is due files new facts into the MOOT. Never prompts for access.",
        categoryName: "Memory"
    )

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let caller = try await IntentRuntimeBridge.shared.bridge()
        let summaries = await MinerRunLoop.liveLoop().tick(now: Date(), caller: caller)
        return .result(dialog: IntentDialog(stringLiteral: DailyIngestSummary.text(for: summaries)))
    }
}
#endif

// MARK: - DailyIngestSummary
//
// The dialog composition, split from perform() so the headless package
// tests can exercise it (perform() needs the App Intents runtime).

public enum DailyIngestSummary {
    /// One line per source that ran: "<id> filed N, skipped M[, failed K]".
    /// `failed` appears only when nonzero so an ordinary quiet tick never
    /// reads like an error. An empty tick names the three silent-skip
    /// reasons so "nothing happened" is explainable from the dialog alone.
    public static func text(for summaries: [MinerRunSummary]) -> String {
        guard !summaries.isEmpty else {
            return "Daily ingest: no miners were due (each source runs only when enabled, authorized, and its cadence has elapsed)."
        }
        let lines = summaries.map { summary -> String in
            var line = "\(summary.sourceID) filed \(summary.result.filed), skipped \(summary.result.skipped)"
            if summary.result.failed > 0 {
                line += ", failed \(summary.result.failed)"
            }
            return line
        }
        return "Daily ingest: " + lines.joined(separator: "; ") + "."
    }
}
