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

public enum MinerEngineError: Error, Equatable {
    case duplicateSampleIdentity(subject: String, predicate: String)
    case factInventoryUnavailable(String)
    case factInventoryTruncated(expected: Int, returned: Int)
}

private struct ExistingMinedFact: Sendable, Equatable {
    let id: String
    let subject: String
    let predicate: String
    let object: String

    var identity: String { "\(subject)\u{1f}\(predicate)" }
}

/// A platform source the engine can drain. Implementations own TCC consent.
public protocol MinerSource: Sendable {
    /// Stable identifier ("calendar", "health", "birthdays") — provenance tag.
    var sourceID: String { get }
    /// Collect the current sample set. Called on every mining run; the
    /// ENGINE dedups, so sources may re-emit history freely.
    func collect() async throws -> [MinedFact]
    func authorizationStatus() async -> MinerAuthorizationStatus
    func requestAuthorization() async -> MinerAuthorizationStatus
}

public enum MinerAuthorizationStatus: String, Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case unavailable
}

public enum MinerSourceError: Error, Equatable {
    case authorizationRequired(MinerAuthorizationStatus)
}

public extension MinerSource {
    func authorizationStatus() async -> MinerAuthorizationStatus { .authorized }
    func requestAuthorization() async -> MinerAuthorizationStatus {
        await authorizationStatus()
    }
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
        var incomingByIdentity: [String: MinedFact] = [:]
        for sample in samples {
            let identity = identity(of: sample)
            if incomingByIdentity[identity] != nil {
                throw MinerEngineError.duplicateSampleIdentity(
                    subject: sample.subject,
                    predicate: sample.predicate
                )
            }
            incomingByIdentity[identity] = sample
        }

        let sourceTag = "miner:\(source.sourceID)"
        let existing = try await existingFacts(sourceTag: sourceTag, caller: caller)
        let existingByIdentity = Dictionary(grouping: existing, by: \.identity)
        var filed = 0, skipped = 0, failed = 0
        for identity in incomingByIdentity.keys.sorted() {
            guard let sample = incomingByIdentity[identity] else { continue }
            let prior = existingByIdentity[identity] ?? []
            if let unchanged = prior.first(where: { $0.object == sample.object }) {
                skipped += 1
                for stale in prior where stale.id != unchanged.id {
                    if !(await retire(stale.id, caller: caller)) { failed += 1 }
                }
                continue
            }
            let result = await caller.callTool("moot_file_fact", arguments: [
                "subject": .string(sample.subject),
                "predicate": .string(sample.predicate),
                "object": .string(sample.object),
                // Provenance: which miner asserted this fact.
                "source_id": .string(sourceTag),
            ])
            if result.isError {
                failed += 1
                continue
            }
            filed += 1
            // Replacement is intentionally file-then-retire: a failed file
            // leaves the last known fact active instead of losing the sample.
            for stale in prior {
                if !(await retire(stale.id, caller: caller)) { failed += 1 }
            }
        }

        // Anything previously asserted by this miner but absent from its
        // current snapshot has been deleted at the source.
        for stale in existing where incomingByIdentity[stale.identity] == nil {
            if !(await retire(stale.id, caller: caller)) { failed += 1 }
        }
        return RunResult(filed: filed, skipped: skipped, failed: failed)
    }

    private static func identity(of fact: MinedFact) -> String {
        "\(fact.subject)\u{1f}\(fact.predicate)"
    }

    private static func existingFacts(
        sourceTag: String,
        caller: any MootToolCalling
    ) async throws -> [ExistingMinedFact] {
        let result = await caller.callTool("moot_fact_search", arguments: [
            "source_id_exact": .string(sourceTag),
            "limit": .integer(500),
        ])
        guard !result.isError else {
            throw MinerEngineError.factInventoryUnavailable(result.text)
        }
        let lines = result.text.split(separator: "\n", omittingEmptySubsequences: true)
        guard let header = lines.first,
              let colon = header.lastIndex(of: ":"),
              let expected = Int(header[header.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)) else {
            throw MinerEngineError.factInventoryUnavailable(result.text)
        }
        let records = lines.dropFirst().compactMap(parseFactLine)
        guard records.count == expected else {
            throw MinerEngineError.factInventoryTruncated(
                expected: expected,
                returned: records.count
            )
        }
        return records
    }

    private static func parseFactLine(_ line: Substring) -> ExistingMinedFact? {
        let text = String(line)
        let pattern = #"^([^ ]+)  \[([^\]]+)\] ([^ ]+) \[(.*)\]  filed=.*  source=.*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ) else { return nil }
        func field(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        guard let id = field(1), let subject = field(2),
              let predicate = field(3), let object = field(4) else { return nil }
        return ExistingMinedFact(id: id, subject: subject, predicate: predicate, object: object)
    }

    private static func retire(_ id: String, caller: any MootToolCalling) async -> Bool {
        let result = await caller.callTool("moot_retire_fact", arguments: [
            "id": .string(id),
        ])
        return !result.isError
    }
}
