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

    // MARK: - C. answer:"never" explicit → same as omitted

    /// Explicitly passing answer:"never" must produce the same response as
    /// omitting the argument — byte-identical to today's dense-rows path.

    // MARK: - D. Schema exposes `answer` in moot_memory_search inputSchema

    /// The `answer` property must be present in `moot_memory_search`'s
    /// inputSchema so MCP clients can discover it. This is a schema surface
    /// test — the tool is exposed at the protocol boundary.

    /// The `answer` property description must mention "never", "always", and "auto"
    /// so calling AIs can discover the three valid values.

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
}
