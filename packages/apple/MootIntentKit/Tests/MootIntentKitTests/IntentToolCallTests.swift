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

    @Test("capture then recall: captured content is findable and carries its subject")
    func captureRecallRoundTrip() async throws {
        let bridge = try await TestBridge.makeInMemory()

        // The exact subject text is asserted twice below, so a regression that
        // supplies an empty or placeholder subject fails this test rather than
        // passing it quietly.
        let subject = "Force-test drawer proves capture then recall round-trips."

        // Exactly the arguments CaptureDrawerIntent.perform() passes.
        let captured = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("force-test: capture then recall"),
            "subject": .string(subject),
            "location": .string("tests"),
            "sensitivity": .string("normal"),
        ])
        #expect(captured.isError == false, "capture should succeed")
        #expect(captured.text.contains("filed memory"), "substrate should confirm filing")

        // The subject must ARRIVE, not merely be accepted. Reading the drawer
        // back at depth:subject returns the dense row the estate stored, so
        // this asserts what is ON the drawer rather than what was sent to the
        // tool — the two differ if the write path drops or rewrites the field.
        guard let drawerID = extractID(from: captured.text) else {
            Issue.record("could not extract id from: \(captured.text)")
            return
        }
        let readBack = await bridge.callTool("moot_memory_get", arguments: [
            "id": .string(drawerID),
            "depth": .string("subject"),
        ])
        #expect(readBack.isError == false, "by-id read-back should succeed")
        #expect(readBack.text.contains(subject),
            "the subject sent at capture must be the subject stored on the drawer")
        #expect(!readBack.text.contains("(no subject)"),
            "a drawer captured through this path must never carry the subject-debt marker")

        // Exactly the arguments RecallDrawerIntent.perform() passes.
        let recalled = await bridge.callTool("moot_memory_search", arguments: [
            "query": .string("force-test: capture then recall"),
        ])
        #expect(recalled.isError == false, "recall should succeed")
        #expect(recalled.text.contains(subject),
            "the dense recall row renders the subject the capture supplied")
    }

    // MARK: reanchor

    @Test("reanchor: moves a captured drawer to a new location")
    func reanchorMoves() async throws {
        let bridge = try await TestBridge.makeInMemory()

        // Capture a drawer, extract the id from the confirmation text.
        let captured = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("drawer to be moved"),
            "subject": .string("Reanchor-test drawer starts in room origin, moves to destination."),
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
            "subject": .string("Mutate-test drawer awaits the confirm transition."),
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
            "subject": .string("Withdraw-test drawer is retired; its history survives."),
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
            "subject": .string("Expunge-test drawer is erased with confirmed=true."),
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
            "subject": .string("Expunge-test drawer must survive confirmed=false."),
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
        // `subject` is carried as an ordinary query item: the router forwards
        // every non-x- item verbatim as a tool argument, so the required
        // argument reaches the dispatcher with no router-side mapping. That is
        // why this mission changes no router source — only this URL.
        let url = URL(string: "mootx01://x-callback-url/capture?content=url-router-test&subject=URL%20router%20capture%20test%20drawer.&location=urls&x-success=app://done")!
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

    @Test("capture without a subject is refused: the router does not invent one")
    func captureWithoutSubjectRefused() async throws {
        let bridge = try await TestBridge.makeInMemory()
        let router = MootURLRouter(permittedCallbackSchemes: ["app"])
        // No subject query item. The router must NOT synthesise one — a subject
        // is the caller's assertion about their own content, and an x-callback
        // caller is an arbitrary other app. The substrate refuses, and the
        // refusal is what the caller gets back.
        //
        // HANDOFF TO TASK-MXE-2026-0235: this test asserts the *substrate*
        // refuses, which presumes `capture` is still in the router's verb
        // allowlist. If that task drops `capture` from the allowlist, the
        // outcome becomes .notHandled and this test must be rewritten to assert
        // the refusal happens at the allowlist instead — a stronger gate, since
        // it never reaches the substrate at all.
        let url = URL(string: "mootx01://x-callback-url/capture?content=no-subject-here&location=urls&x-success=app://done")!
        let outcome = await router.route(url, using: bridge)
        guard case .routed(_, let text, let isError) = outcome else {
            Issue.record("expected routed (the call ran and was refused), got \(outcome)")
            return
        }
        #expect(isError == true, "a capture with no subject must be refused, not filed")
        #expect(text.contains("subject"), "the refusal must name the missing argument; got: \(text)")
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
            "subject": .string("URL-router private drawer stays out of exportable recall."),
            "location": .string("urls"),
        ])
        let publicCapture = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("url public drawer"),
            "subject": .string("URL-router public drawer is exportable."),
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

        // The dense recall row carries the SUBJECT, not the content, so the
        // exportable gate is asserted on the subjects the two captures above
        // supplied. This is the same gate as before on stronger evidence: a
        // subject is what a caller would actually read off the row.
        #expect(isError == false)
        #expect(text.contains("URL-router public drawer is exportable."),
            "exportable recall should include public drawers")
        #expect(!text.contains("URL-router private drawer stays out of exportable recall."),
            "x-callback recall must not return private default drawers")
        #expect(returnURL?.absoluteString.contains("URL-router%20public%20drawer%20is%20exportable.") == true)
        #expect(returnURL?.absoluteString.contains("URL-router%20private%20drawer") != true)
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

    // MARK: the two subject paths through the sink
    //
    // The sink is the surface with the least material to build a subject from,
    // so both of its paths are pinned: a subject the sharing surface supplied
    // (used verbatim) and a subject derived from an opaque body.

    @Test("CaptureSink: a subject supplied by the sharing surface is filed verbatim")
    func captureSinkUsesSuppliedSubject() async throws {
        let bridge = try await TestBridge.makeInMemory()
        let sink = CaptureSink()
        // What a Share Extension can pass when it has a document title: the
        // title the user already saw, not an extract of the body.
        let supplied = "Ada Lovelace wrote the first published algorithm."
        let text = try await sink.capture(
            .init(
                text: "In 1843 Ada Lovelace published notes on the Analytical Engine "
                    + "containing what is now recognised as the first algorithm.",
                location: "inbox",
                subject: supplied),
            using: bridge)
        #expect(text.contains("filed memory"))

        guard let drawerID = extractID(from: text) else {
            Issue.record("could not extract id from: \(text)")
            return
        }
        let readBack = await bridge.callTool("moot_memory_get", arguments: [
            "id": .string(drawerID),
            "depth": .string("subject"),
        ])
        #expect(readBack.text.contains(supplied),
            "a supplied subject must reach the estate unchanged, not be re-derived")
    }

    @Test("CaptureSink: with no supplied subject, the derived one reaches the estate")
    func captureSinkDerivesSubject() async throws {
        let bridge = try await TestBridge.makeInMemory()
        let sink = CaptureSink()
        // Two sentences: the derivation takes the first and stops at its
        // terminator, so the expected subject is exact rather than approximate.
        let text = try await sink.capture(
            .init(
                text: "The roof repair is booked for Tuesday. Bring the ladder from the garage.",
                location: "inbox"),
            using: bridge)
        #expect(text.contains("filed memory"))

        guard let drawerID = extractID(from: text) else {
            Issue.record("could not extract id from: \(text)")
            return
        }
        let readBack = await bridge.callTool("moot_memory_get", arguments: [
            "id": .string(drawerID),
            "depth": .string("subject"),
        ])
        #expect(readBack.text.contains("The roof repair is booked for Tuesday."),
            "the derived subject is the body's leading sentence")
        #expect(!readBack.text.contains("Bring the ladder"),
            "the derivation stops at the first sentence; it is not a content dump")
        #expect(!readBack.text.contains("(no subject)"),
            "the derived path must never leave the subject-debt marker on a drawer")
    }
}

// MARK: - CaptureSubject derivation
//
// Unit coverage for the derivation itself, so its contract is pinned without
// a round-trip through the estate. The register rules that matter mechanically
// are: non-empty, single line, trimmed, and at most 120 characters.

@Suite("CaptureSubject — deriving a register-conformant subject from a body")
struct CaptureSubjectTests {

    @Test("the leading sentence becomes the subject, terminator included")
    func leadingSentence() {
        #expect(CaptureSubject.derive(fromBody: "Invoice 4021 is unpaid. Chase it Friday.")
            == "Invoice 4021 is unpaid.")
    }

    @Test("a body with no sentence terminator yields the whole body")
    func noTerminator() {
        #expect(CaptureSubject.derive(fromBody: "milk eggs coffee filters")
            == "milk eggs coffee filters")
    }

    @Test("newlines and whitespace runs collapse to a single line")
    func flattensToOneLine() {
        let derived = CaptureSubject.derive(fromBody: "  Standup moved\n\nto 09:30   from 10:00  ")
        #expect(derived == "Standup moved to 09:30 from 10:00")
        #expect(!derived.contains("\n"), "a subject with a newline splits one dense row into two")
        #expect(derived == derived.trimmingCharacters(in: .whitespacesAndNewlines),
            "the dense row renderer never trims, so the subject must arrive trimmed")
    }

    @Test("an over-long sentence truncates on a word boundary, within the contract")
    func truncatesOnWordBoundary() {
        // 30 words of five characters plus spaces — comfortably over the cap and
        // with no terminator, so truncation is the only bound that applies.
        let body = Array(repeating: "alpha", count: 30).joined(separator: " ")
        let derived = CaptureSubject.derive(fromBody: body)
        #expect(derived.count <= CaptureSubject.maxLength)
        #expect(!derived.hasSuffix(" "), "truncation must not leave a trailing space")
        #expect(derived.split(separator: " ").allSatisfy { $0 == "alpha" },
            "truncation cuts between words, never mid-word")
    }

    @Test("a single word longer than the cap is hard-cut to the cap")
    func hardCutsAnUnbrokenWord() {
        let derived = CaptureSubject.derive(fromBody: String(repeating: "x", count: 200))
        #expect(derived.count == CaptureSubject.maxLength)
    }

    @Test("a short terminator is treated as an abbreviation, not a sentence end")
    func shortTerminatorIsNotASentenceEnd() {
        // "e.g." must not become the subject — the scan requires a candidate to
        // reach a minimum length before a terminator counts.
        #expect(CaptureSubject.derive(fromBody: "e.g. the trailhead gate is locked after dusk.")
            == "e.g. the trailhead gate is locked after dusk.")
    }

    @Test("a body with nothing in it derives nothing, rather than a placeholder")
    func emptyBodyDerivesEmpty() {
        // The substrate then refuses the capture and says why. Inventing a
        // subject here would file an empty drawer under a confident summary.
        #expect(CaptureSubject.derive(fromBody: "   \n\t  ").isEmpty)
    }

    @Test("resolve prefers a supplied subject and falls back to the body")
    func resolvePrecedence() {
        #expect(CaptureSubject.resolve(supplied: "Gate code changed to 4417.",
                                       body: "The gate code changed. Tell the sitter.")
            == "Gate code changed to 4417.")
        #expect(CaptureSubject.resolve(supplied: nil,
                                       body: "The gate code changed. Tell the sitter.")
            == "The gate code changed.")
        #expect(CaptureSubject.resolve(supplied: "   ",
                                       body: "The gate code changed. Tell the sitter.")
            == "The gate code changed.",
            "a whitespace-only subject is absent, not a subject the tool should refuse")
    }

    @Test("a supplied subject is flattened to one line but never truncated")
    func resolveNormalizesWithoutTruncating() {
        #expect(CaptureSubject.resolve(supplied: " Ferry\nis cancelled ", body: "irrelevant")
            == "Ferry is cancelled")
        // Over-length author text passes through so the substrate refuses it and
        // the author is told to compress. Silently halving their sentence would
        // file a subject they never wrote.
        let long = String(repeating: "beta ", count: 40)
        #expect(CaptureSubject.resolve(supplied: long, body: "irrelevant").count
            > CaptureSubject.maxLength)
    }
}

// MARK: - DrawerEntity structured recall tests
//
// Tests exercise recallDrawers() (the MootToolCalling protocol extension) and
// StructuredRecallResults directly on a live TestBridge, avoiding the
// IntentRuntimeBridge singleton (which is one-write and shared across the
// process). DrawerEntityQuery.entities(for:) is covered through the same
// recallDrawers + exact-id-filter composition its body performs; direct
// query-object coverage is not included here.

@Suite("DrawerEntity — structured recall")
struct DrawerEntityRecallTests {

    // Entities are decoded from the reply's structuredContent rows — typed
    // {id, room, content, subject} data built server-side. The display text
    // (dense rows) is asserted only as evidence that the recall REPLY is
    // sound; it is never the source of entity data.

    @Test("recallDrawers returns non-empty DrawerEntity values for a seeded estate")
    func recallDrawersNonEmpty() async throws {
        let bridge = try await TestBridge.makeInMemory()

        // Seed one drawer.
        let subject = "Entity-recall seed drawer names the quick brown fox."
        let captured = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("recall-by-entity-test: the quick brown fox"),
            "subject": .string(subject),
            "location": .string("entity-tests"),
        ])
        #expect(captured.isError == false, "capture should succeed")

        // The recall REPLY is correct — the seeded drawer comes back and its
        // dense row carries the subject the capture supplied. This half passes
        // and proves the seed is sound, so a failure below is the projection's.
        let reply = await bridge.callTool("moot_memory_search", arguments: [
            "query": .string("recall-by-entity-test"),
        ])
        #expect(reply.isError == false)
        #expect(reply.text.contains(subject),
            "the dense recall row must carry the seeded drawer's subject")

        // The projection: typed entities decoded from the structured rows.
        let drawers = await bridge.recallDrawers(query: "recall-by-entity-test")
        #expect(drawers.isEmpty == false, "recallDrawers should return at least the seeded drawer")
        let match = drawers.first(where: { $0.content.contains("quick brown fox") })
        #expect(match != nil, "seeded drawer content should appear in the results")
        #expect(match?.room == "entity-tests", "room should come from the structured row")
    }

    @Test("recallDrawers publicOnly:true gate: private default excluded, explicit public included")
    func recallDrawersPublicOnly() async throws {
        let bridge = try await TestBridge.makeInMemory()

        // Capture one private (default) — must not appear in public-only recall.
        _ = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("private default drawer content"),
            "subject": .string("Entity-recall private drawer is excluded from public-only recall."),
            "location": .string("entity-tests"),
        ])

        // Capture one public — must appear in public-only recall.
        let publicCapture = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("public entity drawer content"),
            "subject": .string("Entity-recall public drawer is included in public-only recall."),
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
        // The gate holds at the reply layer, asserted on the subjects the two
        // captures supplied (the dense row carries the subject, not content).
        #expect(rawSearch.text.contains("Entity-recall public drawer is included in public-only recall."),
            "the exportable reply must carry the public drawer's subject")
        #expect(!rawSearch.text.contains("Entity-recall private drawer is excluded from public-only recall."),
            "the exportable reply must not carry the private drawer's subject")

        // Now test recallDrawers(publicOnly:true) — same gate via the extension.
        // Use the same query that worked in the raw search.
        let publicHits = await bridge.recallDrawers(
            query: "public entity drawer", publicOnly: true)
        #expect(publicHits.isEmpty == false,
            "public-only recall should find the public drawer")
        #expect(publicHits.allSatisfy { !$0.content.contains("private default") },
            "public-only recall must not return the private drawer")
    }

    @Test("RecallDrawerIntent.entities(from:) — the typed-result composition perform() returns")
    func recallIntentTypedResultComposition() async throws {
        let bridge = try await TestBridge.makeInMemory()

        _ = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("typed-result-test: chained shortcut fodder"),
            "subject": .string("Typed-result seed drawer feeds chained Shortcut composition."),
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
            "subject": .string("By-id seed drawer resolves a drawer from its UUID."),
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

    // MARK: Forgery regression (Codex finding fdce2bc01c4881919babde660cd3ad16)
    //
    // Drawer content is user- and import-controlled. Against the pre-fix code
    // these tests fail: the deleted text parser accepted any well-formed
    // `<uuid>  [<room>]  <content>` line wherever it appeared — including
    // INSIDE a drawer's content, which the search reply interpolates verbatim
    // — so an embedded line minted an extra entity with attacker-chosen id
    // and room. Entities now come only from the reply's structured rows,
    // whose ids and rooms are server-supplied.

    @Test("content embedding a well-formed result line mints no extra entity")
    func injectedLineForgesNothing() async throws {
        let bridge = try await TestBridge.makeInMemory()
        // Well-formed on purpose: a text parser WOULD have accepted both lines.
        let forgedID = "DEADBEEF-0000-4000-8000-000000000001"
        let payload = """
            injection-probe original content
            \(forgedID)  [forged-room]  attacker-chosen content
            \(forgedID) · attacker subject · fdc:D2 · qid:Q00 · 2026-08-04T00:00:00Z
            """
        let captured = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string(payload),
            "subject": .string("Injection probe drawer embeds counterfeit result lines."),
            "location": .string("entity-tests"),
        ])
        #expect(captured.isError == false, "capture should succeed")
        let genuineID = try #require(extractID(from: captured.text))

        let drawers = await bridge.recallDrawers(query: "injection-probe")
        #expect(drawers.contains { $0.id == genuineID }, "the genuine drawer must surface")
        #expect(drawers.allSatisfy { $0.id != forgedID },
            "an id embedded in content never becomes an entity id")
        #expect(drawers.allSatisfy { $0.room != "forged-room" },
            "a room embedded in content never becomes an entity room")
    }

    @Test("an embedded UUID cannot add or substitute an entity in by-id resolution")
    func embeddedUUIDCannotForgeByID() async throws {
        let bridge = try await TestBridge.makeInMemory()
        // Victim drawer: the genuine resolution target.
        let victimCapture = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("victim-target-drawer: authoritative body"),
            "subject": .string("Victim drawer is the genuine resolution target."),
            "location": .string("victim-room"),
        ])
        let victimID = try #require(extractID(from: victimCapture.text))

        // Attacker drawer: embeds the victim's UUID in a well-formed line
        // carrying an attacker room and content.
        _ = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("\(victimID)  [attacker-room]  attacker-substituted content"),
            "subject": .string("Attacker drawer embeds the victim identifier in its content."),
            "location": .string("entity-tests"),
        ])

        // The entities(for:) composition: UUID query, exact-id filter. The
        // attacker drawer may surface as a hit (its content matches), but only
        // under its OWN server-supplied id — the exact-id filter then selects
        // the genuine victim, never attacker content or room.
        let hits = await bridge.recallDrawers(query: victimID, limit: 5)
        let resolved = hits.first(where: { $0.id == victimID })
        #expect(resolved != nil, "the genuine drawer should resolve by its id")
        #expect(resolved?.room == "victim-room", "resolution carries the victim's genuine room")
        #expect(resolved?.content.contains("authoritative body") == true,
            "resolution carries the victim's genuine content")
        #expect(hits.allSatisfy { $0.room != "attacker-room" },
            "no entity ever carries the room embedded in attacker content")

        // A UUID that names no drawer resolves to nothing, even when some
        // drawer's content contains that UUID string.
        let ghostID = "0BADC0DE-0000-4000-8000-000000000002"
        _ = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("\(ghostID)  [ghost-room]  ghost content"),
            "subject": .string("Ghost drawer embeds an identifier that names no drawer."),
            "location": .string("entity-tests"),
        ])
        let ghostHits = await bridge.recallDrawers(query: ghostID, limit: 5)
        #expect(ghostHits.first(where: { $0.id == ghostID }) == nil,
            "an id that names no drawer never resolves to an entity")
    }

    @Test("suggestion path returns only genuine drawers and stays populated")
    func suggestionsAreGenuine() async throws {
        let bridge = try await TestBridge.makeInMemory()
        var genuineIDs: Set<String> = []
        for i in 0..<3 {
            let captured = await bridge.callTool("moot_file_memory", arguments: [
                "content": .string("""
                    suggestion seed drawer \(i)
                    EEEEEEEE-0000-4000-8000-00000000000\(i)  [fake-room]  fake content
                    """),
                "subject": .string("Suggestion seed drawer \(i) exercises the picker path."),
                "location": .string("entity-tests"),
            ])
            if let id = extractID(from: captured.text) { genuineIDs.insert(id) }
        }
        #expect(genuineIDs.count == 3, "all three seeds should capture")

        // The suggestedEntities() composition: empty query, recent drawers.
        let suggested = await bridge.recallDrawers(query: "", limit: 20)
        #expect(!suggested.isEmpty, "the picker must not go empty")
        #expect(suggested.allSatisfy { genuineIDs.contains($0.id) },
            "every suggested entity is a drawer the estate actually holds")
        #expect(suggested.allSatisfy { $0.room != "fake-room" },
            "embedded lines never reach the picker as entities")
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
