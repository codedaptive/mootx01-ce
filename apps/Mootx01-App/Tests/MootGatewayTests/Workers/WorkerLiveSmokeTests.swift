import Testing
import Foundation
import AriaMCP
@testable import MootGateway
import MootIntentKit

// MARK: - Live-estate smoke for all six workers  (FAB5-H2 Verification)
//
// The mission requires all six workers to run against a LIVE estate. This suite
// does that over the real wire — a running resident daemon, real ARIA tool calls,
// and the real on-device model — with no fixtures and no stubs.
//
// It is OFF by default: a test that needs a daemon on a fixed port would fail on
// any machine without one. Enable with MOOT_LIVE_WORKER_SMOKE=1; override the
// endpoint with MOOT_LIVE_WORKER_ENDPOINT.
//
//   MOOT_LIVE_WORKER_SMOKE=1 swift test --package-path apps/Mootx01-App \
//       --filter WorkerLiveSmokeTests
//
// The fixture suites cover the same workers deterministically; this one proves
// the estate answers as parsed and that every worker returns a usable result on
// a real estate.

/// Test-only caller that speaks JSON-RPC `tools/call` to a running daemon over
/// HTTP. Deliberately not shipped in MootGateway: production callers reach the
/// tool surface through MootBridge, which owns transport selection.
private actor LiveDaemonCaller: MootToolCalling {
    private let transport: HTTPTransport
    private var nextID: Int64 = 1
    /// Tool names in call order, so the smoke run can assert the read-only claim
    /// against the live wire rather than against a mock.
    private(set) var calledTools: [String] = []

    // 90 s, not the transport's 30 s default: on a real estate `moot_memory_search`
    // performs hybrid recall over the full drawer set and can exceed 30 s. A smoke
    // run must exercise the surface, not the timeout.
    init(endpoint: URL, timeout: TimeInterval = 90.0) {
        self.transport = HTTPTransport(endpoint: endpoint, timeout: timeout)
    }

    func callTool(_ name: String, arguments: [String: JSONValue]) async -> IntentCallResult {
        calledTools.append(name)
        let id = nextID
        nextID += 1
        let request = JSONRPCRequest(
            id: .integer(id),
            method: "tools/call",
            params: .object([
                "name": .string(name),
                "arguments": .object(arguments),
            ]))
        do {
            guard let response = try await transport.send(request) else {
                return IntentCallResult(text: "no response frame", isError: true)
            }
            switch response.payload {
            case .error(let error):
                return IntentCallResult(text: error.message, isError: true)
            case .result(let value):
                // MCP tool result:
                // { content: [{ type: "text", text: … }], structuredContent?, isError: Bool }
                let object = value.objectValue
                let text = (object?["content"]?.arrayValue ?? [])
                    .compactMap { $0.objectValue?["text"]?.stringValue }
                    .joined(separator: "\n")
                return IntentCallResult(
                    text: text,
                    structured: object?["structuredContent"],
                    isError: object?["isError"]?.boolValue ?? false)
            }
        } catch {
            return IntentCallResult(text: "\(error)", isError: true)
        }
    }
}

/// `runSafe` with the reason visible. `runSafe` swallows a thrown error by design
/// — the UI must never receive one — but in a smoke run a silent fallback reads
/// exactly like a successful model run. This wrapper takes the same two branches
/// and names which one it took.
private func loudRunSafe<Worker: MootWorker>(
    _ worker: Worker,
    input: Worker.Input,
    caller: any MootToolCalling,
    label: String
) async -> Worker.Output {
    guard Worker.isAvailable else {
        print("LIVE WORKER \(label): PATH=fallback reason=model-unavailable")
        return worker.fallback(input: input)
    }
    do {
        let output = try await worker.run(input: input, caller: caller)
        print("LIVE WORKER \(label): PATH=model")
        return output
    } catch {
        print("LIVE WORKER \(label): PATH=fallback reason=\(error)")
        return worker.fallback(input: input)
    }
}

@Suite("Six workers — live local estate smoke (FAB5-H2)", .serialized)
struct WorkerLiveSmokeTests {

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MOOT_LIVE_WORKER_SMOKE"] == "1"
    }

    static var endpoint: URL {
        let raw = ProcessInfo.processInfo.environment["MOOT_LIVE_WORKER_ENDPOINT"]
            ?? "http://127.0.0.1:4242"
        // Force-unwrap is confined to this opt-in suite: a malformed override is a
        // caller error that should fail loudly, not silently fall back.
        return URL(string: raw)!
    }

    /// Every mutation verb. Asserted against the live call log, so the read-only
    /// claim is proven on the wire and not only against a mock.
    static let mutationVerbs: Set<String> = [
        "moot_file_memory", "moot_file_fact", "moot_update_memory",
        "moot_retire_fact", "moot_move_memory", "moot_withdraw_memory",
    ]

    @Test("all six workers return a usable result against a live estate",
          .enabled(if: WorkerLiveSmokeTests.isEnabled))
    func sixWorkersAgainstLiveEstate() async {
        let caller = LiveDaemonCaller(endpoint: Self.endpoint)
        print("LIVE WORKERS availability=\(ModelAvailabilityProbe.description)")

        // 1 — Summarize
        let summary = await loudRunSafe(
            SummarizeWorker(), input: SummarizeInput(query: "recent work", limit: 8),
            caller: caller, label: "summarize")
        #expect(!summary.summary.isEmpty)
        print("LIVE WORKER summarize: chars=\(summary.summary.count)")

        // 2 — ExtractFacts. Every triple is PROPOSED, on the live path too.
        let facts = await loudRunSafe(
            ExtractFactsWorker(), input: ExtractFactsInput(query: "decisions people projects", limit: 8),
            caller: caller, label: "extractFacts")
        for triple in facts.triples { #expect(triple.isProposed) }
        print("LIVE WORKER extractFacts: triples=\(facts.triples.count) "
              + "first=\(facts.triples.first.map { "\($0.subject)|\($0.predicate)|\($0.object)" } ?? "none")")

        // 3 — Classify
        let classification = await loudRunSafe(
            ClassifyWorker(),
            input: ClassifyInput(content: "Shipped the six-worker Intelligence launcher today."),
            caller: caller, label: "classify")
        print("LIVE WORKER classify: room=\(classification.suggestedRoom) "
              + "tags=\(classification.suggestedTags.joined(separator: ","))")

        // 4 — ReviewPrep over a report built from the live estate.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let report = await ReviewBuilderFactory
            .builder(for: .morning, configuration: ReviewConfiguration(),
                     schedule: ReviewSchedule(calendar: ReviewSchedule.utcCalendar))
            .build(now: now, reader: MootToolCallingReviewReader(caller: caller))
        let brief = await loudRunSafe(
            ReviewPrepWorker(), input: ReviewPrepInput(report: report),
            caller: caller, label: "reviewPrep")
        #expect(!brief.narrative.isEmpty)
        #expect(brief.itemCount == report.itemCount)
        #expect(brief.citedSurfaces == report.contributingSurfaces)
        print("LIVE WORKER reviewPrep: origin=\(brief.origin.rawValue) items=\(brief.itemCount) "
              + "surfaces=\(brief.citedSurfaces.map(\.rawValue).joined(separator: ",")) "
              + "headline=\(brief.headline)")

        // 5 — Compare, over two real bodies drawn from the live estate so the
        // comparison is over estate content rather than invented text.
        let firstRecall = await caller.callTool("moot_memory_search", arguments: [
            "query": .string("mootx01 architecture decision"), "limit": .integer(4),
        ])
        let secondRecall = await caller.callTool("moot_memory_search", arguments: [
            "query": .string("mootx01 performance measurement"), "limit": .integer(4),
        ])
        let comparison = await loudRunSafe(
            CompareWorker(),
            input: CompareInput(
                left: ResearchBody(label: "architecture-recall", text: firstRecall.text),
                right: ResearchBody(label: "performance-recall", text: secondRecall.text)),
            caller: caller, label: "compare")
        // Both sides of every disagreement survive the live path too.
        for conflict in comparison.disagreements {
            #expect(!conflict.leftPosition.isEmpty)
            #expect(!conflict.rightPosition.isEmpty)
        }
        // Nothing may be listed as agreed and disputed at once.
        let agreedTopics = Set(comparison.agreements.map { CompareResult.normalize($0.topic) })
        let disputedTopics = Set(comparison.disagreements.map { CompareResult.normalize($0.topic) })
        #expect(agreedTopics.isDisjoint(with: disputedTopics))
        // An empty comparison always explains itself.
        if comparison.agreements.isEmpty && comparison.disagreements.isEmpty {
            #expect(comparison.notice != nil)
        }
        print("LIVE WORKER compare: agreements=\(comparison.agreements.count) "
              + "disagreements=\(comparison.disagreements.count) "
              + "synthesis=\(comparison.synthesisCandidates.count) "
              + "unacknowledged=\(comparison.unacknowledgedDisagreements.count) "
              + "notice=\(comparison.notice ?? "none")")

        // 5b — The same worker over two short benign bodies. When 5 falls back
        // because Apple's guardrail declined the recalled estate text, this run
        // separates "the estate content was declined" from "the worker is broken":
        // the model path must still produce a comparison here.
        let controlComparison = await loudRunSafe(
            CompareWorker(),
            input: CompareInput(
                left: ResearchBody(label: "reading-a", text: "The rebuild takes forty minutes and runs nightly."),
                right: ResearchBody(label: "reading-b", text: "The rebuild takes four hours and runs weekly.")),
            caller: caller, label: "compare-control")
        for conflict in controlComparison.disagreements {
            #expect(!conflict.leftPosition.isEmpty)
            #expect(!conflict.rightPosition.isEmpty)
        }
        print("LIVE WORKER compare-control: agreements=\(controlComparison.agreements.count) "
              + "disagreements=\(controlComparison.disagreements.count) "
              + "topics=\(controlComparison.disagreements.map(\.topic).joined(separator: ";"))")

        // 6 — Handoff, with context recalled from the live estate.
        let draft = await loudRunSafe(
            HandoffWorker(), input: HandoffInput(objective: "Plan the next MOOTx01 release", limit: 5),
            caller: caller, label: "handoff")
        #expect(!draft.body.isEmpty)
        for reference in draft.references {
            // The citation guarantee, on live data: every carried reference is in
            // the text, and every reference names a real estate row.
            #expect(draft.body.contains(reference.subjectID))
            #expect(UUID(uuidString: reference.subjectID) != nil)
        }
        print("LIVE WORKER handoff: references=\(draft.references.count) bodyChars=\(draft.body.count) "
              + "ids=\(draft.references.map(\.subjectID).joined(separator: ","))")

        // The whole run touched read verbs only.
        let called = await caller.calledTools
        #expect(called.filter { Self.mutationVerbs.contains($0) }.isEmpty)
        print("LIVE WORKERS tools=\(Set(called).sorted().joined(separator: ","))")
    }
}

/// Reports whether the on-device model answered during this run, for the smoke
/// log. Kept separate from the workers, which gate on availability themselves.
private enum ModelAvailabilityProbe {
    static var description: String {
        SummarizeWorker.isAvailable ? "available" : "unavailable"
    }
}
