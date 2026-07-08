import Foundation
import MootIntentKit
import AriaMCP   // JSONValue

// MARK: - MinerEngine  (M-ING-2 Part 1 — core + idempotency)
//
// The platform-mining pipeline's engine (Bob's vision, estate 36EF26B4):
// pull structured samples from platform sources (Health, Calendar, Contacts)
// and file them into the KG FACT lane — not prose drawers — so daily
// re-mining converges instead of duplicating.
//
// Source abstraction: concrete miners (EventKit/HealthKit/Contacts) conform
// to MinerSource and are NOT in this file — framework reads need TCC consent
// and live behind the per-source toggles (M-ING-2 Part 2). The engine and
// its idempotency contract are framework-free and fully testable against
// fixtures on any host.
//
// Idempotency contract: every MinedFact carries a subject that is UNIQUE per
// real-world sample (miners encode the sample date/identity in it, e.g.
// "health.weight.2026-07-07"). The engine skips filing when an active fact
// already matches that subject, so run-twice files zero new facts. The
// sample key also rides moot_file_fact's source_id for provenance.

/// One structured sample, already shaped as a KG triple by its miner.
public struct MinedFact: Sendable, Equatable {
    /// Unique per sample (miners encode identity + date here) — the dedup key.
    public let subject: String
    public let predicate: String
    public let object: String

    public init(subject: String, predicate: String, object: String) {
        self.subject = subject
        self.predicate = predicate
        self.object = object
    }
}

/// A platform source the engine can drain. Implementations own TCC consent.
public protocol MinerSource: Sendable {
    /// Stable identifier ("calendar", "health", "birthdays") — provenance tag.
    var sourceID: String { get }
    /// Collect the current sample set. Called on every mining run; the
    /// ENGINE dedups, so sources may re-emit history freely.
    func collect() async throws -> [MinedFact]
}

public enum MinerEngine {

    public struct RunResult: Sendable, Equatable {
        public let filed: Int
        public let skipped: Int
        public let failed: Int
    }

    /// Drain one source into the estate's fact lane, idempotently.
    public static func run(
        _ source: any MinerSource, caller: any MootToolCalling
    ) async throws -> RunResult {
        let samples = try await source.collect()
        var filed = 0, skipped = 0, failed = 0
        for sample in samples {
            if await factExists(subject: sample.subject, caller: caller) {
                skipped += 1
                continue
            }
            let result = await caller.callTool("moot_file_fact", arguments: [
                "subject": .string(sample.subject),
                "predicate": .string(sample.predicate),
                "object": .string(sample.object),
                // Provenance: which miner asserted this fact.
                "source_id": .string("miner:\(source.sourceID)"),
            ])
            if result.isError { failed += 1 } else { filed += 1 }
        }
        return RunResult(filed: filed, skipped: skipped, failed: failed)
    }

    /// True when an ACTIVE fact already matches this sample subject.
    /// moot_fact_search substring-scans subject/predicate/object and reports
    /// `facts matching "<q>": N` on its first line; subjects are unique per
    /// sample by contract, so any nonzero count means "already filed".
    static func factExists(subject: String, caller: any MootToolCalling) async -> Bool {
        let result = await caller.callTool("moot_fact_search", arguments: [
            "query": .string(subject),
        ])
        guard !result.isError,
              let firstLine = result.text.split(separator: "\n").first,
              let colon = firstLine.lastIndex(of: ":"),
              let count = Int(firstLine[firstLine.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces))
        else {
            // Unreadable search result: file rather than silently drop data —
            // a duplicate is recoverable (retire_fact); a lost sample is not.
            return false
        }
        return count > 0
    }
}
