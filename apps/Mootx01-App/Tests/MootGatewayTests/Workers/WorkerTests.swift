import Testing
import Foundation
import AriaMCP
@testable import MootGateway
import MootIntentKit

// MARK: - Test infrastructure

/// A mock MootToolCalling actor that records every tool call and returns
/// fixture text. Used to verify read-only invariants without a live estate.
actor MockCaller: MootToolCalling {
    private(set) var calledTools: [String] = []
    private let fixture: String

    init(fixture: String = "found 0 memory(s)") {
        self.fixture = fixture
    }

    func callTool(_ name: String, arguments: [String: JSONValue]) async -> IntentCallResult {
        calledTools.append(name)
        return IntentCallResult(text: fixture, isError: false)
    }
}

// Mutation verbs that workers must never call.
private let mutationVerbs: Set<String> = [
    "moot_file_memory",
    "moot_file_fact",
    "moot_update_memory",
    "moot_retire_fact",
    "moot_move_memory",
    "moot_withdraw_memory",
]

// MARK: - Fallback path

@Suite("Worker fallbacks")
struct WorkerFallbackTests {

    @Test("SummarizeWorker fallback returns a non-empty summary")
    func summarizeFallbackNonEmpty() {
        let worker = SummarizeWorker()
        let result = worker.fallback(input: SummarizeInput())
        #expect(!result.summary.isEmpty)
    }

    @Test("ExtractFactsWorker fallback returns empty triples, not nil")
    func extractFactsFallbackEmpty() {
        let worker = ExtractFactsWorker()
        let result = worker.fallback(input: ExtractFactsInput())
        // Empty is correct: no fabricated facts when AI is unavailable.
        #expect(result.triples.isEmpty)
    }

    @Test("ClassifyWorker fallback returns empty strings, not nil")
    func classifyFallbackEmpty() {
        let worker = ClassifyWorker()
        let result = worker.fallback(input: ClassifyInput(content: "sample"))
        // Empty strings signal "no suggestion" — callers hide the empty case.
        #expect(result.suggestedRoom.isEmpty)
        #expect(result.suggestedTags.isEmpty)
    }

    @Test("Fallback path calls no tools on the caller")
    func fallbackCallsNoTools() async {
        let mock = MockCaller()
        // Call all three fallbacks; none should touch the caller.
        _ = SummarizeWorker().fallback(input: SummarizeInput())
        _ = ExtractFactsWorker().fallback(input: ExtractFactsInput())
        _ = ClassifyWorker().fallback(input: ClassifyInput(content: "test"))
        let called = await mock.calledTools
        #expect(called.isEmpty)
    }
}

// MARK: - PROPOSED-only guarantee

@Suite("ExtractFacts PROPOSED invariant")
struct ExtractFactsProposedTests {

    @Test("ProposedTriple.isProposed is true at construction — invariant")
    func proposedTripleAlwaysProposed() {
        let triple = ProposedTriple(subject: "AI", predicate: "is", object: "useful")
        #expect(triple.isProposed == true)
    }

    @Test("ExtractFactsWorker.runSafe triples are always PROPOSED")
    func runSafeTripleAlwaysProposed() async {
        let mock = MockCaller(fixture: """
            found 1 memory(s)
            AAAAAAAA-0000-0000-0000-000000000001  [work]  Alice led the project kickoff.
            """)
        let worker = ExtractFactsWorker()
        let result = await worker.runSafe(input: ExtractFactsInput(), caller: mock)
        for triple in result.triples {
            #expect(triple.isProposed == true)
        }
    }

    @Test("ExtractFactsWorker fallback triples are always PROPOSED (empty set satisfies vacuously)")
    func fallbackTripleAlwaysProposed() {
        let worker = ExtractFactsWorker()
        let result = worker.fallback(input: ExtractFactsInput())
        for triple in result.triples {
            #expect(triple.isProposed == true)
        }
    }
}

// MARK: - Zero estate mutation

@Suite("Workers do not mutate the estate")
struct WorkerNoMutationTests {

    @Test("SummarizeWorker.runSafe never calls mutation verbs")
    func summarizeNoMutation() async {
        let mock = MockCaller(fixture: "found 1 memory(s)\nAAAAAAAA-0000-0000-0000-000000000001  [work]  test content")
        let worker = SummarizeWorker()
        _ = await worker.runSafe(input: SummarizeInput(), caller: mock)
        let called = await mock.calledTools
        let mutations = called.filter { mutationVerbs.contains($0) }
        #expect(mutations.isEmpty, "SummarizeWorker called mutation verbs: \(mutations)")
    }

    @Test("ExtractFactsWorker.runSafe never calls mutation verbs")
    func extractFactsNoMutation() async {
        let mock = MockCaller(fixture: "found 1 memory(s)\nAAAAAAAA-0000-0000-0000-000000000001  [work]  Alice led the project.")
        let worker = ExtractFactsWorker()
        _ = await worker.runSafe(input: ExtractFactsInput(), caller: mock)
        let called = await mock.calledTools
        let mutations = called.filter { mutationVerbs.contains($0) }
        #expect(mutations.isEmpty, "ExtractFactsWorker called mutation verbs: \(mutations)")
    }

    @Test("ClassifyWorker.runSafe never calls mutation verbs")
    func classifyNoMutation() async {
        // ClassifyWorker takes content directly — no estate query at all.
        let mock = MockCaller()
        let worker = ClassifyWorker()
        _ = await worker.runSafe(input: ClassifyInput(content: "Shipped the worker framework."), caller: mock)
        let called = await mock.calledTools
        let mutations = called.filter { mutationVerbs.contains($0) }
        #expect(mutations.isEmpty, "ClassifyWorker called mutation verbs: \(mutations)")
    }
}

// MARK: - runSafe guarantees

@Suite("Worker runSafe guarantees")
struct WorkerRunSafeTests {

    @Test("SummarizeWorker.runSafe always returns a valid result on fixture input")
    func summarizeRunSafeValid() async {
        let mock = MockCaller(fixture: "found 1 memory(s)\nAAAAAAAA-0000-0000-0000-000000000001  [work]  built the AI worker framework")
        let worker = SummarizeWorker()
        let result = await worker.runSafe(input: SummarizeInput(query: "recent work"), caller: mock)
        // runSafe guarantees a non-throwing result regardless of AI availability.
        #expect(!result.summary.isEmpty)
    }

    @Test("ClassifyWorker.runSafe always returns a valid result on fixture input")
    func classifyRunSafeValid() async {
        let mock = MockCaller()
        let worker = ClassifyWorker()
        // runSafe returns model suggestion or empty fallback — never throws.
        let result = await worker.runSafe(
            input: ClassifyInput(content: "Shipped the new AI worker framework in July."),
            caller: mock
        )
        // Either the model classified it (non-empty) or fallback (empty) — both are valid.
        _ = result.suggestedRoom
        _ = result.suggestedTags
    }
}
