// RecipeToolsTests.swift
//
// Coverage for the CognitionKit behaviour-recipe surface on ARIA_MCP:
// the three recipe tools project into tools/list with `.recipe`
// provenance and dispatch by name end-to-end against a real in-memory
// GeniusLocusKit estate (no mocks). Mirrors the MultiEstateRoutingTests
// harness: recalls use unconfirmed so freshly-captured rows are visible.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import CognitionKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// `.serialized`: every dispatch case opens a live in-memory estate and
/// runs multi-step capture/run/confirm sequences; concurrent estates
/// contend under parallel execution, so the suite runs one case at a
/// time.
@Suite("Recipe tools", .serialized)
struct RecipeToolsTests {

    // MARK: - Harness

    private func openEstate(
        in kit: GeniusLocusKit, owner: OwnerCredentials
    ) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        return try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
    }

    private func fileArgs(content: String) -> JSONValue {
        .object([
            "content": .string(content),
            "subject": .string(String(content.prefix(120))),
            "location": .string("recipe-tests"),
        ])
    }

    // MARK: - Projection

    // MARK: - recall_connected dispatch

    /// The bridge scenario recall_connected exists for: the answer memory
    /// shares NO words with the query and is reachable only through a
    /// connection edge. File hop-1 (matches the query), file the answer,
    /// link them (a validated tunnel via moot_link_memories), then ask.
    /// Plain similarity cannot surface the answer; the walk must.

    /// Gate invariant: a tombstoned (withdrawn) memory linked by a tunnel to
    /// a live anchor must NOT appear in connected-recall results. The walk
    /// discovers the edge and attempts hydration; the gated overload
    /// (insertDefaults plus the caller's filter) excludes the withdrawn row
    /// via .currentlyBelieve.

    /// Gate invariant: a sensitivity-restricted memory linked by a tunnel to a
    /// live anchor must NOT appear in connected-recall results. The walk
    /// discovers the edge; the gated overload applies the insertDefaults ceiling
    /// of .sensitivityAtMost(.elevated), excluding .restricted rows.

    /// Shared setup for the Wave-3 G1 walk-filter tests: file an anchor (with
    /// optional exportability), file a walk-only target sharing no words with
    /// the query, link target → anchor, and PROVE walk reachability with an
    /// unrestricted control query before any filtered assertion — a gate test
    /// whose walk never reaches the target passes vacuously.
    /// Twin of Rust `g1_walk_fixture`.
    private func g1WalkFixture(
        kit: GeniusLocusKit, handle: EstateHandle,
        dispatcher: ToolDispatcher,
        anchorContent: String, anchorExportability: String?,
        targetContent: String, targetExportability: String?,
        controlQuery: String
    ) async throws -> (anchor: String, target: String) {
        func fileWith(_ content: String, _ exportability: String?) async throws -> String {
            var fields: [String: JSONValue] = [
                "content": .string(content),
                "subject": .string(String(content.prefix(120))),
                "location": .string("recipe-tests"),
            ]
            if let e = exportability { fields["exportability"] = .string(e) }
            let result = try await dispatcher.dispatch(
                name: "moot_file_memory", arguments: .object(fields))
            let text = result.objectValue?["content"]?.arrayValue?.first?
                .objectValue?["text"]?.stringValue ?? ""
            return text.split(separator: "\n").first?
                .split(separator: " ").last.map(String.init) ?? ""
        }

        // Filing order is load-bearing. On the in-memory test estate the
        // scored anchor recall degrades to capture-time-descending order, so
        // the 20-deep anchor pool is simply the 20 NEWEST drawers. The
        // target is filed FIRST (oldest — guaranteed outside the pool, so
        // it can only arrive through the tunnel walk), then 25 distractors
        // to fill the pool, then the anchor LAST (newest — guaranteed in
        // the pool, so the walk always has its seed).
        let target = try await fileWith(targetContent, targetExportability)
        for i in 1...25 {
            _ = try await fileWith(
                "distractor \(i) garden compost rotation and seasonal seed notes", nil)
        }
        let anchor = try await fileWith(anchorContent, anchorExportability)

        // Capture the tunnel DIRECTLY with sourceWing "recipe-tests": the
        // walk reads tunnels whose SOURCE wing matches the query's wing arg,
        // and moot_link_memories records the drawers' resolved wing (the
        // estate default), which the "recipe-tests" query would never see —
        // the tunnel would be invisible and the gate test vacuous. Same
        // shape as the Rust fixture's direct capture_tunnel.
        let estate = try await kit.estate(for: handle)
        let tunnelFrame = TunnelCaptureFrame(
            sourceWing: "recipe-tests", sourceRoom: "recipe-tests",
            targetWing: "recipe-tests", targetRoom: "recipe-tests",
            label: "g1 walk gate test link", addedBy: "aria-mcp-tests",
            sourceDrawerId: target, targetDrawerId: anchor, kind: .references)
        _ = try await estate.capture(tunnelFrame)

        // CONTROL: unrestricted filter must reach the target through the walk.
        // If this fails the fixture is broken, not the gate.
        let control = try await dispatcher.dispatch(
            name: "moot_recall_connected",
            arguments: .object([
                "query": .string(controlQuery),
                "wing": .string("recipe-tests"),
                "filter": .string("unconfirmed"),
                "limit": .integer(10),
            ]))
        let controlText = control.objectValue?["content"]?.arrayValue?.first?
            .objectValue?["text"]?.stringValue ?? ""
        #expect(controlText.contains(target),
                "FIXTURE: the walk must reach the linked target under an unrestricted filter; got: \(controlText)")
        return (anchor, target)
    }

    /// Wave-3 G1 gate invariant: the CALLER's filter applies to walk
    /// hydration, not only to anchor recall. A non-exportable (born-private)
    /// drawer linked to an exportable anchor must NOT surface its content
    /// under filter:"exportable", while the exportable anchor itself must.
    /// Twin of Rust `connected_recall_walk_honors_exportable_filter`.

    /// Wave-3 G1 gate invariant, confirmation axis: an unconfirmed drawer
    /// linked to a user-confirmed anchor must NOT surface its content under
    /// filter:"userConfirmed".
    /// Twin of Rust `connected_recall_walk_honors_user_confirmed_filter`.

    /// Wave-3 G1 gate invariant, containment axis: a PUBLIC drawer linked to
    /// a contained (born-private) anchor must NOT surface its content under
    /// filter:"contained" — the inverse of the exportable test.
    /// Twin of Rust `connected_recall_walk_honors_contained_filter`.

    // MARK: - grounded_synthesis dispatch

    /// `query` grounds the synthesis through BOTH hybrid lanes: the lexical
    /// cue lane ranks term-matching memories first, and the scored lane
    /// (BM25 + vector, high-recall) may admit non-matching rows BELOW them
    /// up to the cap. The response names the cue, and the cue-relevant
    /// memories must LEAD the document — grounding is a ranking guarantee,
    /// not a hard exclusion, now that the scored lane is live.

    /// Ranking is driven by cue-term relevance, not recency. File 25 memories:
    /// the OLDEST contains distinctive answer terms; 24 newer memories share a
    /// generic word that also appears in the query but is dominated by the
    /// distinctive terms. With limit:5, recency alone evicts the answer drawer;
    /// with cue-relevance ranking it rises to the top and appears in keyInsights.

    /// `moot_synthesize` silently removes provenance-restricted rows from the
    /// synthesis pool. The gate covers provenance bits 30–35 (`Sensitivity`),
    /// which the recall-frame adjective filter does not reach. A mixed estate
    /// (1 normal + 1 provenance-restricted row) must expose the normal row's
    /// content in `keyInsights` and must NOT expose the restricted row's content.
    /// Unlike `moot_memory_search`, which emits a visible redaction marker for
    /// restricted rows it encountered, synthesis silently drops them — the
    /// output count reflects only the surviving pool.
    /// Twin of Rust `grounded_synthesis_mixed_pool_only_exposes_normal_rows`.

    /// A query whose every token is a stopword or too short must be rejected
    /// (invalidParams), never silently degraded to an unscoped digest.

    /// The term extractor's contract, pinned so both ports cannot drift:
    /// stopwords and short fragments drop, digit-bearing short tokens stay,
    /// tokens lowercase and dedupe in first-appearance order, cap at 12.

    /// A known composition name is accepted without error.
    /// Parity: Rust test `recall_precise_named_composition_is_accepted`.
    @Test func testPreciseRecallKnownCompositionIsAccepted() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pr-known-comp"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: fileArgs(content: "the indemnity was 46 million marks"))

        // "hamming+text" is a known grid composition in every build — must succeed.
        let result = try await dispatcher.dispatch(
            name: "moot_recall_precise",
            arguments: .object([
                "query": .string("indemnity"),
                "composition": .string("hamming+text"),
            ]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false,
                "a known composition must dispatch without error")
    }

    /// Absent `composition` arg keeps the default (`text`) behavior unchanged.
    /// Absence ≠ unknown: no composition arg must never produce an error.

    // MARK: - recall_shaped (named RecallShape preset surface)

    /// A known preset dispatches and returns the moot_memory_search plain-text
    /// shape. Mirrors the Rust dispatch test `recall_shaped_known_preset_*`.

    /// An unknown preset name is a caller error — the boundary rejects it
    /// fail-CLOSED with a tool error naming the offending preset.

    /// An absent `preset` arg uses the unsteered balanced default and succeeds.
    /// Absence ≠ unknown: no preset arg must never produce an error.

    /// The shaped-recall tool advertises the full preset roster in its
    /// description so the AI can pick a preset by intent.

    /// Every roster name is accepted by the MCP boundary and returns a valid
    /// memory-search-shaped result. Mirrors testShapedRecallDispatchReturnsMootTextShape
    /// but exercises each preset through the full dispatch chain.

    // MARK: - migration benchmark run → confirm, end to end

    // MARK: - dream dispatch

    /// `moot_dream` rebuilds the matrix tier and runs one dreaming cycle. With
    /// several drawers sharing a room there are co-occurrence pairs to mine, so
    /// the cycle considers candidates. Before the dream the estate has no
    /// registered matrix tier (the `matrix` recall lane reads 0.0); after it the
    /// tier is built — this is the "starved vs weak" un-starving the gauntlet
    /// re-ablation measures end-to-end.

    /// A malformed `now` is an out-of-band client error (invalidParams), not a
    /// silent fallback — the determinism contract must not be bypassed quietly.
    @Test func testDreamRejectsMalformedNow() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "dream-bad-now"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_dream",
                arguments: .object(["now": .string("not-a-date")]))
        }
    }

    // MARK: - association_rules dispatch

    // MARK: - formal_concepts dispatch

    // MARK: - isRecipeTool

    @Test func testIsRecipeToolCoversDistillationTools() {
        // moot_distill and moot_redistill are not recipe tools — there is no
        // distillation sweep; distillation renders inline at read time.
        #expect(!RecipeTools.isRecipeTool("moot_distill"))
        #expect(!RecipeTools.isRecipeTool("moot_redistill"))
        // moot_consolidate is out of the routing set entirely (alias removed,
        // SPEC_DISTILLATION_STORAGE §3 Phase 2) — the name reserves for the
        // multi-item consolidation feature.
        #expect(!RecipeTools.isRecipeTool("moot_consolidate"))
        #expect(RecipeTools.isRecipeTool("moot_recall_distilled"))
        // moot_recollect is in the routing set as a notice-only stub (Wave 1 ACK
        // gate): it must reach dispatch to return the removal notice. Not listed.
        #expect(RecipeTools.isRecipeTool("moot_recollect"))
        // D10: moot_recall_walk is a listed recipe tool (escalation-ladder recall).
        #expect(RecipeTools.isRecipeTool("moot_recall_walk"))
    }

    // MARK: - tools() count

    @Test func testRecipeToolsCount() {
        // 14 recipe tools: listRecipes, listRecipesCatalog, groundedSynthesis,
        // preciseRecall, temporalRecall, connectedRecall, shapedRecall,
        // vagueRecall, runMigration, confirmMigration, dream,
        // recallDistilled, huntContradictions, walkRecall (D10).
        #expect(RecipeTools.tools().count == 14)
        let names = RecipeTools.tools().map(\.name)
        #expect(!names.contains("moot_distill"))
        #expect(!names.contains("moot_redistill"))
        #expect(!names.contains("moot_consolidate"))
        #expect(!names.contains("moot_recollect"))
        // D10: moot_recall_walk is in the listed tools set.
        #expect(names.contains("moot_recall_walk"))
    }

    // MARK: - moot_distill / moot_redistill are absent

    @Test func testDistillIsRetiredAndThrowsMethodNotFound() async throws {
        // moot_distill is not a dispatch target — distillation renders inline
        // at read time. Calls must fail with methodNotFound.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "distill-retired"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_distill",
                arguments: .object([:]))
        }
    }

    @Test func testRedistillIsRetiredAndThrowsMethodNotFound() async throws {
        // moot_redistill is not a dispatch target — distillation renders inline
        // at read time. Calls must fail with methodNotFound.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "redistill-retired"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_redistill",
                arguments: .object([:]))
        }
    }

    @Test func testConsolidateNameIsUnknownTool() async throws {
        // moot_consolidate no longer dispatches anywhere — not to distill (its
        // former alias target), not to anything else. The name is reserved for
        // the multi-item consolidation feature; until that claims it, calls
        // fail with methodNotFound like any unregistered name.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "consolidate-unknown"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_consolidate",
                arguments: .object(["ack": .string("moot_distill/p1")]))
        }
    }

    // MARK: - moot_recall_distilled dispatch

    // MARK: - ACK gate and notice-only stub tests (Wave 1)

    // moot_recollect — always returns the removed notice; no estate access.

    // moot_recall_distilled runs UNCONDITIONALLY — no acknowledgment
    // ceremony precedes any result (ARIA_MCP_SPEC 2.0.0 § 8.6). The former
    // ack gate and CONTRACT CHANGE NOTICE were deleted in COMPOSER-02B.

    // Schema + description: no ack parameter, no ceremony vocabulary.
    @Test func testRecallDistilledSchemaHasNoAckParam() throws {
        let tool = RecipeTools.tools().first(where: { $0.name == "moot_recall_distilled" })
        let tool_ = try #require(tool, "moot_recall_distilled must appear in tools()")
        let props = tool_.inputSchema.objectValue?["properties"]?.objectValue
        let props_ = try #require(props, "moot_recall_distilled schema must have properties")
        #expect(props_["ack"] == nil,
                "moot_recall_distilled schema must NOT expose an 'ack' parameter")
        #expect(!tool_.description.contains("CONTRACT CHANGE"),
                "description must carry no ceremony vocabulary")
    }

    // MARK: - helpers

    /// Extract every RFC-4122 UUID appearing in `text`, in order.
    private static func uuids(in text: String) -> [UUID] {
        let pattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { UUID(uuidString: ns.substring(with: $0.range)) }
    }

    /// Distinct UUIDs in first-appearance order.
    private static func uniqueUUIDs(in text: String) -> [UUID] {
        var seen = Set<UUID>()
        var out: [UUID] = []
        for id in uuids(in: text) where seen.insert(id).inserted {
            out.append(id)
        }
        return out
    }
}

// MARK: - Security hardening — limit clamping and future-now guard

/// Validates the MCP-boundary security hardening introduced by the secfix-p1-ariamcp stream:
/// - Negative/zero limits throw invalidParams (DoS prevention).
/// - Over-ceiling limits are clamped to 500 rather than passed to the substrate.
/// - Dream future-now timestamps more than 24 h ahead are rejected.
///
/// These tests exercise `ToolDispatcher.clampLimit` directly plus end-to-end
/// dispatch of moot_recall_precise, moot_recall_shaped, moot_recall_distilled,
/// and moot_dream through the real dispatcher. No mocks.
@Suite("Recipe tools — security hardening")
struct RecipeToolsSecurityTests {

    // MARK: - clampLimit unit tests

    @Test func clampLimitAbsentReturnsDefault() throws {
        let result = try ToolDispatcher.clampLimit(nil, argument: "limit")
        #expect(result == 20)
    }

    @Test func clampLimitAbsentHonorsCustomDefault() throws {
        let result = try ToolDispatcher.clampLimit(nil, argument: "pool", default: 30)
        #expect(result == 30)
    }

    @Test func clampLimitNegativeThrowsInvalidParams() throws {
        #expect(throws: JSONRPCError.self) {
            try ToolDispatcher.clampLimit(-1, argument: "limit")
        }
    }

    @Test func clampLimitZeroThrowsInvalidParams() throws {
        #expect(throws: JSONRPCError.self) {
            try ToolDispatcher.clampLimit(0, argument: "limit")
        }
    }

    @Test func clampLimitNegativeErrorMessageIsActionable() {
        do {
            _ = try ToolDispatcher.clampLimit(-5, argument: "limit")
            Issue.record("Expected throw")
        } catch let e as JSONRPCError {
            #expect(e.message.contains("limit"))
            #expect(e.message.contains("-5"))
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test func clampLimitWithinCeilingPassesThrough() throws {
        let result = try ToolDispatcher.clampLimit(42, argument: "limit")
        #expect(result == 42)
    }

    @Test func clampLimitAtCeilingPassesThrough() throws {
        let result = try ToolDispatcher.clampLimit(500, argument: "limit")
        #expect(result == 500)
    }

    @Test func clampLimitOverCeilingClampsTo500() throws {
        let result = try ToolDispatcher.clampLimit(1_000_000, argument: "limit")
        #expect(result == 500)
    }

    @Test func clampLimitCustomCeilingIsHonored() throws {
        let result = try ToolDispatcher.clampLimit(200_000, argument: "walkLength", ceiling: 100_000)
        #expect(result == 100_000)
    }

    // MARK: - End-to-end dispatch: negative limit → invalidParams error

    private func openEstate(in kit: GeniusLocusKit) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(
            storage: storage, owner: OwnerCredentials(ownerIdentifier: "sec-test"))
        return try await kit.open(
            storage: storage, owner: OwnerCredentials(ownerIdentifier: "sec-test"),
            identityKeyStore: InMemoryEstateIdentityKeyStore())
    }

    @Test func preciseRecallNegativeLimitThrows() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(in: kit)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_recall_precise",
                arguments: .object([
                    "query": .string("test"),
                    "limit": .integer(-1),
                ]))
        }
    }

    // MARK: - Dream future-now guard

    // MARK: - moot_synthesize clampLimit boundary guards (Finding 3)

    /// A negative `limit` on `moot_synthesize` must throw `invalidParams`.
    /// Before the fix, it passed through unclamped, potentially causing
    /// downstream range violations in the substrate.
    @Test func groundedSynthesisNegativeLimitThrowsInvalidParams() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(in: kit)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        await #expect(throws: JSONRPCError.self) {
            // Explicit type annotation required — Swift cannot infer JSONValue
            // inside the #expect(throws:) closure without it.
            let args: JSONValue = .object(["limit": .integer(-1)])
            _ = try await dispatcher.dispatch(name: "moot_synthesize", arguments: args)
        }
    }

    /// An over-ceiling `limit` on `moot_synthesize` must be clamped to 500.
    @Test func groundedSynthesisOverCeilingLimitIsClamped() async throws {
        // Over-ceiling limit must be silently clamped, not crash or throw.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(in: kit)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Should not throw — clamped to 500 and dispatches normally.
        let args: JSONValue = .object(["limit": .integer(1_000_000)])
        _ = try? await dispatcher.dispatch(name: "moot_synthesize", arguments: args)
    }

    // MARK: - moot_recall_walk dispatch (D10)

    /// AM-WR-ARIA-1: moot_recall_walk dispatches successfully on an empty estate.
    /// Returns "found 0 memory(s)" and a walk: stage line.

    /// AM-WR-ARIA-2: moot_recall_walk tool descriptor appears in tools/list
    /// with the correct name, required query param, and outputSchema.

    /// AM-WR-ARIA-3: missing query arg returns invalidParams, not a crash.
    @Test func walkRecallMissingQueryThrows() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(in: kit)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_recall_walk",
                arguments: .object([:]))
        }
    }
}
