// AnswerArgDispatchTests.swift
//
// Gate tests for the `answer` argument on moot_memory_search (PACKAGER mission).
//
// The `answer` argument selects the response shape adjective (spec §2):
//   "never"  (default) — dense rows only, byte-identical to pre-packager path
//   "always"           — compose answer block + rows (L1-full)
//   "auto"             — server picks level by confidence gate (L0/L1/rowsOnly)
//
// ## What these tests prove
//   A. Unknown answer value → invalidParams (fail-closed); unknown values NEVER
//      silently coerce to "never".
//   B. answer:"never" omitted → response contains "found N memory(s)" header.
//      Byte-identical test: the response must NOT contain an "answer:" line.
//   C. answer:"never" explicit → same shape as omitted; "answer:" line absent.
//   D. Schema exposes `answer` in moot_memory_search's inputSchema.
//
// Note: answer:"always" and answer:"auto" require a live GroundedSynthesis run
// against estate content with a real embedding provider. Those paths are wired
// and build-verified (the ToolDispatch compilation already proves the code path
// is connected), but end-to-end integration tests require the corpus+vector
// harness in DurableSemanticRecallTests.swift. The scope of this test file is
// the argument decode gate and the schema surface.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("answer arg dispatch (packager adjective)", .serialized)
struct AnswerArgDispatchTests {

    // MARK: - Helpers

    private func makeDispatcher() async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "answer-arg-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (ToolDispatcher(kit: kit, handle: handle), kit, handle)
    }

    @discardableResult
    private func fileMemory(
        content: String,
        location: String,
        dispatcher: ToolDispatcher
    ) async throws -> String {
        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string(content),
                "subject": .string(String(content.prefix(120))),
                "location": .string(location),
            ])
        )
        let text = result.objectValue?["content"]?
            .arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
        return text.components(separatedBy: "\n").first?
            .replacingOccurrences(of: "filed memory ", with: "") ?? ""
    }

    // MARK: - A. Unknown answer value fails closed

    /// An unknown `answer` value must throw invalidParams — fail-closed so a typo
    /// is never silently coerced to "never" (byte-identical) and the caller
    /// receives no result when they intended a different mode.
    @Test("unknown answer value throws invalidParams (fail-closed)")
    func unknownAnswerThrowsInvalidParams() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_memory_search",
                arguments: .object([
                    "query": .string("test"),
                    "answer": .string("maybe"),
                ])
            )
            Issue.record("Unknown answer must throw invalidParams, but did not throw")
        } catch let error as JSONRPCError {
            #expect(
                error.code == JSONRPCErrorCode.invalidParams,
                "Expected invalidParams, got \(error.code)"
            )
            #expect(error.message.contains("answer"))
        }
    }

    // MARK: - B. answer omitted → byte-identical to today (no answer: line)

    /// When `answer` is omitted, the response is byte-identical to the
    /// pre-packager path: "found N memory(s)" header, dense rows, no "answer:"
    /// line. This is the golden-pin byte-identity test for answer:never default.
    @Test("omitting answer arg produces never-mode response with no answer block")
    func omittedAnswerProducesNeverModeResponse() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()
        try await fileMemory(
            content: "golden test memory for answer-never verification",
            location: "answer-tests/test",
            dispatcher: dispatcher
        )

        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("golden test memory"),
            ])
        )
        let text = result.objectValue?["content"]?
            .arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""

        // Golden pin: never mode must NOT produce an "answer:" line.
        #expect(!text.contains("\nanswer: "))
        // Header must still be present.
        #expect(text.hasPrefix("found "))
    }

    // MARK: - C. answer:"never" explicit → same as omitted

    /// Explicitly passing answer:"never" must produce the same response as
    /// omitting the argument — byte-identical to today's dense-rows path.
    @Test("answer:never explicit produces same response as omitted (byte-identity)")
    func explicitNeverAnswerMatchesOmitted() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()
        try await fileMemory(
            content: "explicit never mode byte identity test memory",
            location: "answer-tests/never",
            dispatcher: dispatcher
        )

        let neverResult = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("explicit never mode"),
                "answer": .string("never"),
            ])
        )
        let neverText = neverResult.objectValue?["content"]?
            .arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""

        let omittedResult = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("explicit never mode"),
            ])
        )
        let omittedText = omittedResult.objectValue?["content"]?
            .arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""

        // Both paths must produce the same response shape.
        // Both must contain "found N memory(s)" and no "answer:" line.
        #expect(!neverText.contains("\nanswer: "))
        #expect(!omittedText.contains("\nanswer: "))
        #expect(neverText.hasPrefix("found "))
        #expect(omittedText.hasPrefix("found "))
    }

    // MARK: - D. Schema exposes `answer` in moot_memory_search inputSchema

    /// The `answer` property must be present in `moot_memory_search`'s
    /// inputSchema so MCP clients can discover it. This is a schema surface
    /// test — the tool is exposed at the protocol boundary.
    @Test("moot_memory_search inputSchema contains answer property")
    func memorySearchSchemaExposesAnswerProperty() {
        guard let tool = ToolProjection.tools().first(where: { $0.name == "moot_memory_search" }),
              case let .object(schema) = tool.inputSchema,
              case let .object(props)? = schema["properties"]
        else {
            Issue.record("Could not read moot_memory_search inputSchema")
            return
        }
        #expect(props["answer"] != nil, "moot_memory_search schema must expose 'answer' property")
    }

    /// The `answer` property description must mention "never", "always", and "auto"
    /// so calling AIs can discover the three valid values.
    @Test("answer property description names all three valid values")
    func answerPropertyDescriptionNamesAllValues() {
        guard let tool = ToolProjection.tools().first(where: { $0.name == "moot_memory_search" }),
              case let .object(schema) = tool.inputSchema,
              case let .object(props)? = schema["properties"],
              case let .object(answerProp)? = props["answer"],
              case let .string(desc)? = answerProp["description"]
        else {
            Issue.record("Could not read moot_memory_search answer property description")
            return
        }
        #expect(desc.contains("never"), "answer description must mention 'never'; got: \(desc.prefix(200))")
        #expect(desc.contains("always"), "answer description must mention 'always'; got: \(desc.prefix(200))")
        #expect(desc.contains("auto"), "answer description must mention 'auto'; got: \(desc.prefix(200))")
    }

    // MARK: - E. answer:"always" produces serialized answer block (Finding 3)

    /// answer:"always" must produce a serialized MCP response containing an
    /// "answer: " line (the answer block). This tests the wire JSON path:
    /// ToolDispatch serializes the packager's answer block as text lines
    /// before the row table when level is L1Full or L0AnswerOnly.
    ///
    /// Fixture design (pin-B-class): exactly ONE memory is filed with content
    /// matching the query. A single-hit recall result gives m1=1.0, m3=1.0 —
    /// both well above t1_prime=0.05 and t3_prime=0.10 — so the WEAK gate
    /// never fires. m2=0.0 (LocusOnly lane, no union profile) means CONFIDENT
    /// fails; the result is classified INTERMEDIATE. With "always" mode and a
    /// non-empty composedAnswer (ContextSynthesizer always produces a non-empty
    /// "N drawers; dominant node …" string), the answer block IS emitted.
    /// This fixture therefore guarantees CONFIDENT-or-INTERMEDIATE confidence
    /// and an unconditional answer block — no OR-tolerant fallback needed.
    ///
    /// The invariant under test: the answer block serialization code path is
    /// reachable and wired to the packager output (spec §3, Adams Finding 3).
    @Test("answer:always serializes answer block in MCP response when content is present")
    func alwaysAnswerSerializesAnswerBlock() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()
        // File exactly ONE memory so the single-hit case forces m1=1.0
        // (Swift: `return top.isEmpty ? 0.0 : 1.0` for the single-element path).
        // Single hit → m1=1.0, m3=1.0 → WEAK gate does NOT fire → answer block IS emitted.
        try await fileMemory(
            content: "xenolith quartz prismatic geological crystal formation volcanic xenolith quartz",
            location: "answer-always-e/1",
            dispatcher: dispatcher
        )

        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("xenolith quartz prismatic geological"),
                "answer": .string("always"),
            ])
        )
        let text = result.objectValue?["content"]?
            .arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""

        // COMPOSER-02B: answer block is prepended BEFORE the found-N header.
        // Text layout: "answer: ...\nconfidence: ...\nsignals: ...\nfound N candidate..."
        // So we use contains(), not hasPrefix(), for the found-N header.
        #expect(text.contains("found 1 candidate memory"), "always-mode response must contain found-N header; got: \(text.prefix(120))")

        // Single-hit fixture → INTERMEDIATE confidence guaranteed → answer block emitted.
        // COMPOSER-02B: answer block is at the START of the text (no preceding newline).
        let hasAnswerLine = text.hasPrefix("answer: ")
        #expect(
            hasAnswerLine,
            "answer:always with single-hit INTERMEDIATE fixture must produce answer block; signals: \(text.prefix(300))"
        )
        // Signals line must accompany the answer block (spec §3: both always present).
        // Signals is on the third line, so it IS preceded by a newline.
        #expect(
            text.contains("\nsignals: "),
            "signals: line must accompany answer block; got: \(text.prefix(300))"
        )
    }

    // MARK: - F. near: anchor excluded from packager signals, not just from rows (Finding 1)

    /// answer:"always" with a near:<anchor_id> query: the PACKAGER must receive
    /// the post-anchor-exclusion hit list so gate signals (m1, m4) are computed
    /// on the ranked set the caller receives — not on the pre-exclusion list that
    /// includes the pivot row.
    ///
    /// Fixture design:
    ///   1. File ONE anchor memory (its content becomes the near: query).
    ///   2. File ONE non-anchor memory so there is exactly one hit after exclusion.
    ///   3. The anchor self-matches as rank-0 (highest score: query = anchor
    ///      content verbatim); the non-anchor is rank-1.
    ///   4. After exclusion the packager receives a single-hit result.
    ///      Single-hit → m1=1.0 (Swift: `return top.isEmpty ? 0.0 : 1.0`).
    ///      After round2: margin=1.0. The signals: line must say `margin=1.0`.
    ///
    /// Discriminating gate: if the packager received the PRE-exclusion list
    /// (anchor + non-anchor = 2 hits), m1 would be (anchorScore - nonAnchorScore)
    /// / anchorScore < 1.0, and the signals line would say `margin=X.XX` where
    /// X.XX < 1.0. The assertion `margin=1.0` FAILS against pre-fix behavior.
    ///
    /// FoundCount gate: the response must contain "found 1 candidate memory" — the
    /// packager's totalCount is 1 because it received only the non-anchor hit.
    /// Pre-fix totalCount would be 2 (both hits passed to packager), failing here.
    /// COMPOSER-02B: answer block is prepended before found-N, so use contains().
    @Test("near: anchor excluded from packager signals (discriminating: margin=1.0 proves post-filter)")
    func nearAnchorExcludedFromPackagerSignals() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()

        // File the anchor memory and capture its UUID from the response.
        let anchorIDRaw = try await fileMemory(
            content: "zephyr luminescent abstract pivot node proximity search anchor testing fixture",
            location: "near-tests-f/anchor",
            dispatcher: dispatcher
        )
        // fileMemory returns the UUID directly (first line, "filed memory " stripped).
        let anchorID = anchorIDRaw.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !anchorID.isEmpty, UUID(uuidString: anchorID) != nil else {
            // Anchor ID extraction failed — the filing response format may have changed.
            Issue.record("Could not extract anchor UUID from filing response: '\(anchorIDRaw)'")
            return
        }

        // File exactly ONE non-anchor memory. After anchor exclusion, this is the
        // only hit the packager sees → single-hit → m1=1.0 (guaranteed).
        try await fileMemory(
            content: "related proximity fixture memory zephyr luminescent abstract testing",
            location: "near-tests-f/related",
            dispatcher: dispatcher
        )

        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "near": .string(anchorID),
                // answer:"always" is required to surface the signals: line.
                // The single-hit post-exclusion result is NOT WEAK (m1=1.0, m3=1.0),
                // so the answer block IS emitted and signals: appears in the wire text.
                "answer": .string("always"),
            ])
        )
        let text = result.objectValue?["content"]?
            .arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""

        // FoundCount gate: only 1 hit reaches the packager after anchor exclusion.
        // Pre-fix: packager would receive 2 hits → totalCount=2 → "found 2 candidate memories".
        // COMPOSER-02B: answer block prepended before found-N, so use contains().
        #expect(
            text.contains("found 1 candidate memory"),
            "near:+answer:always must report found 1 (anchor excluded from packager input); got: \(text.prefix(120))"
        )

        // Anchor UUID must not appear in response rows (byte-identity from §F original).
        #expect(
            !text.contains(anchorID),
            "near: anchor UUID must not appear in response rows; found in: \(text.prefix(300))"
        )

        // Signals gate: single-hit post-exclusion gives m1=1.0 after round2.
        // Pre-fix (2-hit pre-exclusion input): m1 = (anchorScore-nonAnchorScore)/anchorScore
        // which is < 1.0, so this assertion FAILS against the pre-fix behavior.
        #expect(
            text.contains("margin=1.0"),
            "signals: must show margin=1.0 (single post-exclusion hit); proves packager received anchor-excluded ranked set. got: \(text.prefix(400))"
        )
    }
}
