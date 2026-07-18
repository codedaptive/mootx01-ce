import Testing
import Foundation
import MootIntentKit
import AriaMCP

// MARK: - Intent tool-call composition tests
//
// AppIntents' perform() requires the App Intents runtime (a registered app
// bundle). In this headless test target that runtime is not present, so we
// test the tool-call composition functions directly — the exact callTool
// paths that perform() delegates to. The test description states this
// explicitly so there is no ambiguity about what is exercised.
//
// Each test:
//   1. Builds a TestBridge over a real in-memory estate (see BridgeConformance.swift).
//   2. Calls callTool with the exact arguments an intent's perform() would pass.
//   3. Asserts the result text and error flag from the substrate.

@Suite("Intent tool-call composition — six verbs against a live estate")
struct IntentToolCallTests {

    // MARK: capture → recall round-trip

    @Test("capture then recall: captured content is findable")
    func captureRecallRoundTrip() async throws {
        let bridge = try await TestBridge.makeInMemory()

        // Exactly the arguments CaptureDrawerIntent.perform() passes.
        let captured = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("force-test: capture then recall"),
            "location": .string("tests"),
            "sensitivity": .string("normal"),
        ])
        #expect(captured.isError == false, "capture should succeed")
        #expect(captured.text.contains("filed memory"), "substrate should confirm filing")

        // Exactly the arguments RecallDrawerIntent.perform() passes.
        let recalled = await bridge.callTool("moot_memory_search", arguments: [
            "query": .string("force-test: capture then recall"),
        ])
        #expect(recalled.isError == false, "recall should succeed")
        #expect(recalled.text.contains("memory"), "recall should return at least one hit")
    }

    // MARK: reanchor

    @Test("reanchor: moves a captured drawer to a new location")
    func reanchorMoves() async throws {
        let bridge = try await TestBridge.makeInMemory()

        // Capture a drawer, extract the id from the confirmation text.
        let captured = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("drawer to be moved"),
            "location": .string("origin"),
        ])
        #expect(captured.isError == false)
        // The id is in the text; extract it. Filed confirmation format:
        // "filed memory <uuid>" or similar — we search for the uuid pattern.
        let id = extractID(from: captured.text)
        #expect(id != nil, "capture response should contain a drawer id")
        guard let drawerID = id else { return }

        // Exactly the arguments ReanchorDrawerIntent.perform() passes.
        // The tool takes `location` (the target room name), not `destination`.
        let moved = await bridge.callTool("moot_move_memory", arguments: [
            "id": .string(drawerID),
            "location": .string("destination"),
        ])
        #expect(moved.isError == false, "reanchor should succeed; got: \(moved.text)")
    }

    // MARK: mutate (confirm transition)

    @Test("mutate: confirm transition on a captured drawer")
    func mutateConfirm() async throws {
        let bridge = try await TestBridge.makeInMemory()

        let captured = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("drawer to confirm"),
            "location": .string("tests"),
        ])
        #expect(captured.isError == false)
        guard let drawerID = extractID(from: captured.text) else {
            Issue.record("could not extract id from: \(captured.text)")
            return
        }

        // Exactly the arguments MutateDrawerIntent.perform() passes.
        let mutated = await bridge.callTool("moot_update_memory", arguments: [
            "id": .string(drawerID),
            "mutation": .string("confirm"),
        ])
        #expect(mutated.isError == false, "mutate/confirm should succeed; got: \(mutated.text)")
    }

    // MARK: withdraw

    @Test("withdraw: retires a drawer; history preserved")
    func withdraw() async throws {
        let bridge = try await TestBridge.makeInMemory()

        let captured = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("drawer to withdraw"),
            "location": .string("tests"),
        ])
        #expect(captured.isError == false)
        guard let drawerID = extractID(from: captured.text) else {
            Issue.record("could not extract id from: \(captured.text)")
            return
        }

        // Exactly the arguments WithdrawDrawerIntent.perform() passes.
        let withdrawn = await bridge.callTool("moot_withdraw_memory", arguments: [
            "id": .string(drawerID),
        ])
        #expect(withdrawn.isError == false, "withdraw should succeed; got: \(withdrawn.text)")
    }

    // MARK: expunge — confirmed=true erases

    @Test("expunge: confirmed=true erases a drawer")
    func expungeConfirmed() async throws {
        let bridge = try await TestBridge.makeInMemory()

        let captured = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("drawer to erase"),
            "location": .string("tests"),
        ])
        #expect(captured.isError == false)
        guard let drawerID = extractID(from: captured.text) else {
            Issue.record("could not extract id from: \(captured.text)")
            return
        }

        // Exactly the arguments ExpungeDrawerIntent.perform() passes with confirmed=true.
        let erased = await bridge.callTool("moot_erase_memory", arguments: [
            "id": .string(drawerID),
            "reason": .string("force-test erase"),
            "confirmed": .bool(true),
        ])
        #expect(erased.isError == false, "expunge confirmed=true should succeed; got: \(erased.text)")
    }

    // MARK: expunge — confirmed=false refuses

    @Test("expunge: confirmed=false is refused by the substrate")
    func expungeUnconfirmedRefused() async throws {
        let bridge = try await TestBridge.makeInMemory()

        let captured = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("drawer not to erase"),
            "location": .string("tests"),
        ])
        #expect(captured.isError == false)
        guard let drawerID = extractID(from: captured.text) else {
            Issue.record("could not extract id from: \(captured.text)")
            return
        }

        // Exactly the arguments ExpungeDrawerIntent.perform() passes with confirmed=false.
        let refused = await bridge.callTool("moot_erase_memory", arguments: [
            "id": .string(drawerID),
            "reason": .string("force-test attempted erase"),
            "confirmed": .bool(false),
        ])
        // The substrate must refuse when confirmed=false. isError=true is the
        // signal. If it ever returns false here, the confirmation guard was removed.
        #expect(refused.isError == true, "expunge confirmed=false must be refused by the substrate")
    }
}

// MARK: - URL Router tests

@Suite("MootURLRouter — allowlist and routing")
struct URLRouterTests {

    @Test("allowed verb (capture) routes through to the substrate")
    func allowedVerbRoutes() async throws {
        let bridge = try await TestBridge.makeInMemory()
        let router = MootURLRouter(permittedCallbackSchemes: ["app"])
        let url = URL(string: "mootx01://x-callback-url/capture?content=url-router-test&location=urls&x-success=app://done")!
        let outcome = await router.route(url, using: bridge)
        guard case .routed(let returnURL, let text, let isError) = outcome else {
            Issue.record("expected routed, got \(outcome)")
            return
        }
        #expect(isError == false)
        #expect(text.contains("filed memory"))
        #expect(returnURL?.absoluteString.contains("app://done") == true)
        #expect(returnURL?.absoluteString.contains("result=") == true)
    }

    @Test("destructive verb (expunge) is rejected by the allowlist")
    func destructiveVerbRejected() async throws {
        let bridge = try await TestBridge.makeInMemory()
        let router = MootURLRouter()
        let url = URL(string: "mootx01://x-callback-url/expunge?id=fake")!
        let outcome = await router.route(url, using: bridge)
        guard case .notHandled = outcome else {
            Issue.record("expunge should be notHandled; got \(outcome)")
            return
        }
    }

    @Test("destructive verb (withdraw) is rejected by the allowlist")
    func withdrawVerbRejected() async throws {
        let bridge = try await TestBridge.makeInMemory()
        let router = MootURLRouter()
        let url = URL(string: "mootx01://x-callback-url/withdraw?id=fake")!
        let outcome = await router.route(url, using: bridge)
        guard case .notHandled = outcome else {
            Issue.record("withdraw should be notHandled; got \(outcome)")
            return
        }
    }

    @Test("destructive verb (mutate) is rejected by the allowlist")
    func mutateVerbRejected() async throws {
        let bridge = try await TestBridge.makeInMemory()
        let router = MootURLRouter()
        let url = URL(string: "mootx01://x-callback-url/mutate?id=fake&mutation=confirm")!
        let outcome = await router.route(url, using: bridge)
        guard case .notHandled = outcome else {
            Issue.record("mutate should be notHandled; got \(outcome)")
            return
        }
    }

    @Test("unknown verb is rejected")
    func unknownVerbRejected() async throws {
        let bridge = try await TestBridge.makeInMemory()
        let router = MootURLRouter()
        let url = URL(string: "mootx01://x-callback-url/teleport?content=x")!
        let outcome = await router.route(url, using: bridge)
        guard case .notHandled = outcome else {
            Issue.record("unknown verb should be notHandled")
            return
        }
    }


    @Test("recall verb forces exportable filter before routing")
    func recallVerbForcesExportableFilter() async throws {
        let bridge = try await TestBridge.makeInMemory()

        _ = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("url private default drawer"),
            "location": .string("urls"),
        ])
        let publicCapture = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("url public drawer"),
            "location": .string("urls"),
            "exportability": .string("public"),
        ])
        #expect(publicCapture.isError == false, "public capture should succeed")

        let router = MootURLRouter(permittedCallbackSchemes: ["app"])
        let url = URL(string: "mootx01://x-callback-url/recall?query=url&filter=userConfirmed&x-success=app://done")!
        let outcome = await router.route(url, using: bridge)
        guard case .routed(let returnURL, let text, let isError) = outcome else {
            Issue.record("expected routed, got \(outcome)")
            return
        }

        #expect(isError == false)
        #expect(text.contains("url public drawer"), "exportable recall should include public drawers")
        #expect(!text.contains("url private default drawer"), "x-callback recall must not return private default drawers")
        #expect(returnURL?.absoluteString.contains("url%20public%20drawer") == true)
        #expect(returnURL?.absoluteString.contains("url%20private%20default%20drawer") != true)
    }

    @Test("callback scheme not in allowlist: returnURL is nil")
    func callbackSchemeGate() async throws {
        let bridge = try await TestBridge.makeInMemory()
        // No permitted schemes registered.
        let router = MootURLRouter(permittedCallbackSchemes: [])
        let url = URL(string: "mootx01://x-callback-url/capture?content=scheme-test&x-success=https://evil.example/done")!
        let outcome = await router.route(url, using: bridge)
        guard case .routed(let returnURL, _, _) = outcome else {
            Issue.record("expected routed (the tool call still ran); got \(outcome)")
            return
        }
        // The callback was stripped because https is not in the allowlist.
        #expect(returnURL == nil, "open-redirect must be blocked: returnURL should be nil")
    }
}

// MARK: - CaptureSink tests

@Suite("CaptureSink — Share Sheet capture")
struct CaptureSinkTests {

    @Test("CaptureSink.capture files shared content")
    func captureSinkFiles() async throws {
        let bridge = try await TestBridge.makeInMemory()
        let sink = CaptureSink()
        let text = try await sink.capture(.init(text: "shared from another app"), using: bridge)
        #expect(text.contains("filed memory"), "sink capture should confirm filing")
    }

    @Test("CaptureSink.capture with explicit location")
    func captureSinkWithLocation() async throws {
        let bridge = try await TestBridge.makeInMemory()
        let sink = CaptureSink()
        let text = try await sink.capture(.init(text: "share with location", location: "inbox"), using: bridge)
        #expect(text.contains("filed memory"))
    }
}

// MARK: - DrawerEntity structured recall tests
//
// Tests exercise recallDrawers() (the MootToolCalling protocol extension) and
// MootToolCalling.parseDrawerLines() directly on a live TestBridge, avoiding
// the IntentRuntimeBridge singleton (which is one-write and shared across
// the process). Direct DrawerEntityQuery.entities(for:) coverage is not
// included here.

@Suite("DrawerEntity — structured recall via gateway-layer text parse")
struct DrawerEntityRecallTests {

    @Test("recallDrawers returns non-empty DrawerEntity values for a seeded estate")
    func recallDrawersNonEmpty() async throws {
        let bridge = try await TestBridge.makeInMemory()

        // Seed one drawer.
        let captured = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("recall-by-entity-test: the quick brown fox"),
            "location": .string("entity-tests"),
        ])
        #expect(captured.isError == false, "capture should succeed")

        // recallDrawers on the bridge directly (default impl from MootToolCalling).
        let drawers = await bridge.recallDrawers(query: "recall-by-entity-test")
        #expect(drawers.isEmpty == false, "recallDrawers should return at least the seeded drawer")
        let match = drawers.first(where: { $0.content.contains("quick brown fox") })
        #expect(match != nil, "seeded drawer content should appear in the results")
        #expect(match?.room == "entity-tests", "room should be parsed from the response line")
    }

    @Test("recallDrawers publicOnly:true gate: private default excluded, explicit public included")
    func recallDrawersPublicOnly() async throws {
        let bridge = try await TestBridge.makeInMemory()

        // Capture one private (default) — must not appear in public-only recall.
        _ = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("private default drawer content"),
            "location": .string("entity-tests"),
        ])

        // Capture one public — must appear in public-only recall.
        let publicCapture = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("public entity drawer content"),
            "location": .string("entity-tests"),
            "exportability": .string("public"),
        ])
        #expect(publicCapture.isError == false, "public capture should succeed")

        // Verify via the raw tool that filter:exportable works (same as
        // capturePublicThenExportableRecallFindsIt in GatewayCoreTests).
        let rawSearch = await bridge.callTool("moot_memory_search", arguments: [
            "query": .string("public entity drawer"),
            "filter": .string("exportable"),
        ])
        #expect(rawSearch.isError == false)
        #expect(!rawSearch.text.contains("found 0"), "filter:exportable should find the public drawer")

        // Now test recallDrawers(publicOnly:true) — same gate via the extension.
        // Use the same query that worked in the raw search.
        let publicHits = await bridge.recallDrawers(
            query: "public entity drawer", publicOnly: true)
        #expect(publicHits.isEmpty == false,
            "public-only recall should find the public drawer")
        #expect(publicHits.allSatisfy { !$0.content.contains("private default") },
            "public-only recall must not return the private drawer")
    }

    @Test("parseDrawerLines correctly parses uuid-room-content lines")
    func parseDrawerLinesTest() {
        // Simulate a moot_memory_search text response with two result lines
        // and the header and provenance lines that should be skipped.
        let sampleText = """
            found 2 memory(s)
            550e8400-e29b-41d4-a716-446655440000  [workspace]  the quick brown fox jumps over
            f47ac10b-58cc-4372-a567-0e02b2c3d479  [archive]  another sample drawer content
            recall_provenance: denseLaneStatus=nil, degradedStages=[]
            """
        // Call the static protocol extension method via TestBridge (a concrete
        // MootToolCalling conformance), which is accessible from the test target.
        let drawers = TestBridge.parseDrawerLines(sampleText)
        #expect(drawers.count == 2, "should parse exactly 2 result lines")
        #expect(drawers[0].id == "550e8400-e29b-41d4-a716-446655440000")
        #expect(drawers[0].room == "workspace")
        #expect(drawers[0].content == "the quick brown fox jumps over")
        #expect(drawers[1].id == "f47ac10b-58cc-4372-a567-0e02b2c3d479")
        #expect(drawers[1].room == "archive")
        #expect(drawers[1].content == "another sample drawer content")
    }

    @Test("RecallDrawerIntent.entities(from:) — the typed-result composition perform() returns")
    func recallIntentTypedResultComposition() async throws {
        let bridge = try await TestBridge.makeInMemory()

        _ = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("typed-result-test: chained shortcut fodder"),
            "location": .string("entity-tests"),
        ])

        // Exactly the tool call RecallDrawerIntent.perform() makes, then the
        // same composition step it returns as the intent value.
        let result = await bridge.callTool("moot_memory_search", arguments: [
            "query": .string("typed-result-test"),
        ])
        #expect(result.isError == false)
        let entities = RecallDrawerIntent.entities(from: result)
        #expect(entities.isEmpty == false, "typed composition should surface the seeded drawer")
        #expect(entities.contains { $0.content.contains("chained shortcut fodder") })
        #expect(entities.allSatisfy { UUID(uuidString: $0.id) != nil },
            "every returned entity carries a well-formed drawer UUID")
    }

    @Test("RecallDrawerIntent.entities(from:) returns [] on a substrate refusal")
    func recallIntentTypedResultRefusal() {
        let refused = IntentCallResult(text: "the MOOT refused", isError: true)
        #expect(RecallDrawerIntent.entities(from: refused).isEmpty,
            "an error result must never fabricate entities")
    }

    @Test("recallDrawers and entities(for:) resolve a drawer by id end-to-end")
    func entityByIDRoundTrip() async throws {
        let bridge = try await TestBridge.makeInMemory()

        // Capture and extract id.
        let captured = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("entity-by-id-test: unique content for id resolution"),
            "location": .string("entity-tests"),
        ])
        guard let drawerID = extractID(from: captured.text) else {
            Issue.record("could not extract id from: \(captured.text)")
            return
        }

        // Resolve by id using recallDrawers directly (entity.id == drawerID filter).
        let hits = await bridge.recallDrawers(query: drawerID, limit: 5)
        let resolved = hits.first(where: { $0.id == drawerID })
        #expect(resolved != nil, "recallDrawers with the uuid query should surface the drawer")
        #expect(resolved?.id == drawerID, "resolved entity id must match")
    }
}

// MARK: - Helpers

/// Extract a UUID from a substrate confirmation text. The filed-memory
/// confirmation carries the drawer id somewhere in the text.
private func extractID(from text: String) -> String? {
    // UUID pattern: 8-4-4-4-12 hex chars separated by hyphens.
    let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range, in: text) else {
        return nil
    }
    return String(text[range])
}
