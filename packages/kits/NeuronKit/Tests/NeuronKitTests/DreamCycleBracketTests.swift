import Foundation
import Testing
import GeniusLocusKit
@testable import NeuronKit

/// A3 dream-cycle bracket markers (benchmark reset 2026-08-13).
///
/// The daemon mints ONE session id per cycle and calls the sink's
/// `dreamCycleWillStart` / `dreamCycleDidEnd` hooks with it — start before
/// step 1, end after the cycle's last write — so a production sink
/// (`EstateDreamingSink`) can bracket the cycle in the estate audit log and
/// CYCLE-dreamt time becomes attributable from the audit log alone.
///
/// The Rust suite mirrors these cases in `dreaming_cycle.rs`
/// (`dream_cycle_brackets_*`).
@Suite("DreamCycleBracketTests")
struct DreamCycleBracketTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// Records the lifecycle hook calls the daemon makes, in order.
    private actor BracketRecordingSink: DreamingProposalSink {
        private(set) var events: [(hook: String, sessionID: String, now: Date)] = []

        func propose(_ frame: ProposeFrame) async throws {}
        func recordCycleDiary(_ entry: DiaryEntry) async throws {}
        func pruneRecallTraces(olderThan cutoff: Date) async throws -> Int { 0 }
        func dreamCycleWillStart(sessionID: String, now: Date) async {
            events.append(("start", sessionID, now))
        }
        func dreamCycleDidEnd(sessionID: String, now: Date) async {
            events.append(("end", sessionID, now))
        }
        func recorded() -> [(hook: String, sessionID: String, now: Date)] { events }
    }

    private actor EmptyReader: DreamingSubstrateReader {
        func recentRecallTraces(since: Date, now: Date) async throws -> [RecallTraceItem] { [] }
        func drainDreamingWindow() async throws -> [[String]] { [] }
        func existingTunnels() async throws -> [Tunnel] { [] }
    }

    @Test("one cycle emits exactly one start/end pair sharing a session id")
    func cycleBracketsShareSession() async throws {
        try await withIntellectusLock {
            let sink = BracketRecordingSink()
            let daemon = NeuronKit.dreamingDaemon(
                reader: EmptyReader(),
                sink: sink,
                policyStore: InMemoryDreamingPolicyStore())

            _ = try await daemon.triggerDreamingCycle(now: t0)

            let events = await sink.recorded()
            #expect(events.count == 2, "exactly one start and one end per cycle")
            #expect(events.first?.hook == "start")
            #expect(events.last?.hook == "end")
            // Both ends of the bracket carry the SAME minted session id.
            #expect(events.first?.sessionID == events.last?.sessionID)
            #expect(events.first?.sessionID.isEmpty == false)
            // Both hooks receive the cycle's deterministic `now`.
            #expect(events.allSatisfy { $0.now == t0 })
        }
    }

    @Test("two cycles mint distinct session ids")
    func cyclesMintDistinctSessions() async throws {
        try await withIntellectusLock {
            let sink = BracketRecordingSink()
            let daemon = NeuronKit.dreamingDaemon(
                reader: EmptyReader(),
                sink: sink,
                policyStore: InMemoryDreamingPolicyStore())

            _ = try await daemon.triggerDreamingCycle(now: t0)
            _ = try await daemon.triggerDreamingCycle(now: t0.addingTimeInterval(60))

            let events = await sink.recorded()
            #expect(events.count == 4)
            let first = events[0].sessionID
            let second = events[2].sessionID
            #expect(first != second, "each cycle brackets under its own session id")
        }
    }
}
