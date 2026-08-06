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

    @Test func testRecipeToolsAppearInProjectionWithRecipeProvenance() {
        let tools = ToolProjection.tools()
        let recipeNames = tools
            .filter { if case .recipe = $0.provenance { return true } else { return false } }
            .map(\.name)
            .sorted()
        // Full sorted list: alphabetically moot_confirm_* < moot_lens_* < moot_list_* <
        // moot_run_* < moot_synthesize. RecipeTool names interleave with LensTool names.
        // 35 total: 12 recipe tools + 23 lens tools. moot_distill is the sole
        // distillation-sweep name (its compatibility alias is gone — Phase 2 of
        // SPEC_DISTILLATION_STORAGE §3) and moot_recollect retired with the
        // factoid tier (§3/§11).
        #expect(recipeNames == [
            "moot_confirm_migration",
            "moot_distill",
            "moot_dream",
            "moot_hunt_contradictions",
            "moot_lens_anticipate",
            "moot_lens_apriori",
            "moot_lens_associations",
            "moot_lens_bias",
            "moot_lens_cohesion",
            "moot_lens_complexity",
            "moot_lens_concepts",
            "moot_lens_constellation",
            "moot_lens_contradiction",
            "moot_lens_divergence",
            "moot_lens_drift",
            "moot_lens_free_association",
            "moot_lens_keystones",
            "moot_lens_latent_themes",
            "moot_lens_moment",
            "moot_lens_node_motion",
            "moot_lens_overlap",
            "moot_lens_partial_cue",
            "moot_lens_precedence",
            "moot_lens_rhythm",
            "moot_lens_successors",
            "moot_lens_theme_weather",
            "moot_lens_trust_synthesis",
            "moot_list_lenses",
            "moot_list_recipes",
            "moot_recall_distilled",
            "moot_recall_precise",
            "moot_recall_shaped",
            "moot_recall_vague",
            "moot_run_migration",
            "moot_synthesize",
        ])
    }

    @Test func testListRecipesDispatchEnumeratesCognitionTools() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "lr"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_list_lenses", arguments: .object([:]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        // Listing uses ProjectedTool names and descriptions (not catalog names).
        #expect(text.contains("moot_synthesize"))
        #expect(text.contains("moot_list_lenses"))
        // Migration tools are Tier 7 and intentionally absent from the cognition menu.
        #expect(!text.contains("moot_run_migration"))
        #expect(!text.contains("moot_confirm_migration"))
        #expect(text.contains("27 cognition tools"))
    }

    @Test func testRecipeToolNamesDoNotCollideWithInterfaceToolNames() {
        // Recipe and lens tools sit above the interface tier — no recipe/lens name
        // must match any of the 19 AI-client interface tool names.
        let interfaceNames = Set(
            ToolProjection.tools()
                .filter { if case .interface = $0.provenance { return true } else { return false } }
                .map(\.name)
        )
        for tool in ToolProjection.tools() {
            guard case .recipe = tool.provenance else { continue }
            #expect(!interfaceNames.contains(tool.name),
                    "recipe tool \(tool.name) must not collide with an interface tool name")
        }
    }

    // MARK: - grounded_synthesis dispatch

    @Test func testGroundedSynthesisDispatchReturnsContext() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "gs"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // File three memories through the AI-client surface.
        for text in [
            "carbon chemistry of organic compounds",
            "carbon based biochemistry of life",
            "quantum mechanics fundamentals",
        ] {
            _ = try await dispatcher.dispatch(
                name: "moot_file_memory", arguments: fileArgs(content: text))
        }

        let result = try await dispatcher.dispatch(
            name: "moot_synthesize",
            arguments: .object(["filter": .string("unconfirmed")]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.contains("grounded_synthesis: 3 drawer"))
        #expect(text.contains("patterns:"))
        #expect(text.contains("carbon"))
    }

    /// `query` scopes the recalled pool: only memories whose content matches
    /// a distinctive term feed the synthesis, and the response names the cue
    /// (a grounded synthesis and an estate digest are different measurements).
    @Test func testGroundedSynthesisQueryScopesTheRecalledPool() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "gsq"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        for text in [
            "carbon chemistry of organic compounds",
            "carbon based biochemistry of life",
            "quantum mechanics fundamentals",
        ] {
            _ = try await dispatcher.dispatch(
                name: "moot_file_memory", arguments: fileArgs(content: text))
        }

        let result = try await dispatcher.dispatch(
            name: "moot_synthesize",
            arguments: .object([
                "query": .string("carbon compounds"),
                "filter": .string("unconfirmed"),
            ]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        // Both carbon memories match a term; the quantum memory matches none.
        #expect(text.contains("grounded_synthesis: 2 drawer"))
        #expect(text.contains("query: carbon compounds"))
        #expect(!text.contains("quantum"))
    }

    /// A query whose every token is a stopword or too short must be rejected
    /// (invalidParams), never silently degraded to an unscoped digest.
    @Test func testGroundedSynthesisAllStopwordQueryThrowsInvalidParams() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "gse"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        await #expect(throws: JSONRPCError.self) {
            let args: JSONValue = .object(["query": .string("what did they do")])
            _ = try await dispatcher.dispatch(name: "moot_synthesize", arguments: args)
        }
    }

    /// The term extractor's contract, pinned so both ports cannot drift:
    /// stopwords and short fragments drop, digit-bearing short tokens stay,
    /// tokens lowercase and dedupe in first-appearance order, cap at 12.
    @Test func testGroundingTermsContract() {
        // Stopwords and 2-char fragments drop; content words survive lowercased.
        #expect(RecipeTools.groundingTerms(from: "What did Melanie buy at Trader Joe's?")
            == ["melanie", "buy", "trader", "joe"])
        // Digit-bearing short tokens are distinctive and survive.
        #expect(RecipeTools.groundingTerms(from: "was it 46 or 3b") == ["46", "3b"])
        // Dedupe preserves first-appearance order.
        #expect(RecipeTools.groundingTerms(from: "carbon Carbon CARBON life")
            == ["carbon", "life"])
        // All-stopword input yields no terms (the dispatch layer rejects it).
        #expect(RecipeTools.groundingTerms(from: "what did they do").isEmpty)
        // Cap at 12 terms.
        let long = (1...20).map { "uniqueterm\($0)" }.joined(separator: " ")
        #expect(RecipeTools.groundingTerms(from: long).count == 12)
    }

    // MARK: - recall_precise dispatch

    @Test func testPreciseRecallDispatchReturnsMootTextShape() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pr"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // File three near-duplicate memories that differ only by figure.
        for text in [
            "the indemnity was 11 million marks",
            "the indemnity was 46 million marks",
            "the indemnity was 23 million marks",
        ] {
            _ = try await dispatcher.dispatch(
                name: "moot_file_memory", arguments: fileArgs(content: text))
        }

        let result = try await dispatcher.dispatch(
            name: "moot_recall_precise",
            arguments: .object([
                "query": .string("the indemnity was 46 million marks"),
                "filter": .string("unconfirmed"),
                "limit": .integer(10),
            ]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        // Same shape as moot_memory_search: a `found N memory(s)` header then
        // one `id  [room]  preview` line per hit. The mootText parser keys on
        // exactly this shape.
        #expect(text.hasPrefix("found "))
        #expect(text.contains("memory(s)"))
        // The precise target (46) is surfaced; the recipe ranks it first, so
        // its content appears in the first hit line after the header.
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count >= 2, "header plus at least one hit line")
        #expect(lines[1].contains("46 million marks"),
                "the distinctive-number target must rank first")
    }

    // MARK: - recall_precise composition validation (fail-closed parity)
    //
    // These three tests mirror the Rust dispatch test contract exactly:
    //   recall_precise_unknown_composition_fails_closed  (unknown → tool error)
    //   recall_precise_named_composition_is_accepted      (known → success)
    //   recall_precise_default_composition_returns_memory_shape (absent → success)
    // Rust commit 94a62696; see packages/kits/AriaMcpKit/rust/tests/dispatch_tests.rs.

    /// An unknown composition name is a caller error. The boundary rejects it
    /// fail-CLOSED: isError:true tool result naming the offending composition.
    /// Parity: Rust test `recall_precise_unknown_composition_fails_closed`.
    @Test func testPreciseRecallUnknownCompositionFailsClosed() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pr-unknown-comp"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        _ = try await dispatcher.dispatch(
            name: "moot_file_memory", arguments: fileArgs(content: "any content"))

        let result = try await dispatcher.dispatch(
            name: "moot_recall_precise",
            arguments: .object([
                "query": .string("anything"),
                "composition": .string("no-such-composition"),
            ]))

        let obj = try #require(result.objectValue)
        // Unknown composition must produce a tool error, not a success result.
        #expect(obj["isError"]?.boolValue == true,
                "unknown composition must return a tool error (fail closed)")
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.contains("unknown composition"),
                "the error message must name the offending composition")
        #expect(text.contains("no-such-composition"),
                "the error message must include the invalid value the caller sent")
    }

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

        // "dense-fused" is a known grid composition — must succeed.
        let result = try await dispatcher.dispatch(
            name: "moot_recall_precise",
            arguments: .object([
                "query": .string("indemnity"),
                "composition": .string("dense-fused"),
            ]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false,
                "a known composition must dispatch without error")
    }

    /// Absent `composition` arg keeps the default (`text`) behavior unchanged.
    /// Absence ≠ unknown: no composition arg must never produce an error.
    @Test func testPreciseRecallAbsentCompositionUsesDefault() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pr-absent-comp"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: fileArgs(content: "the indemnity was 46 million marks"))

        // No `composition` key at all — must succeed and return the mootText shape.
        let result = try await dispatcher.dispatch(
            name: "moot_recall_precise",
            arguments: .object(["query": .string("indemnity")]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false,
                "absent composition must use the default and succeed")
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.hasPrefix("found "),
                "absent composition must return the mootText header shape")
    }

    // MARK: - recall_shaped (named RecallShape preset surface)

    /// A known preset dispatches and returns the moot_memory_search plain-text
    /// shape. Mirrors the Rust dispatch test `recall_shaped_known_preset_*`.
    @Test func testShapedRecallDispatchReturnsMootTextShape() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "sr"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        for text in [
            "the river flows north past the old mill",
            "the mountain trail climbs steeply at dawn",
        ] {
            _ = try await dispatcher.dispatch(
                name: "moot_file_memory", arguments: fileArgs(content: text))
        }

        let result = try await dispatcher.dispatch(
            name: "moot_recall_shaped",
            arguments: .object([
                "query": .string("river mill"),
                "preset": .string("conceptual"),
                "filter": .string("unconfirmed"),
                "limit": .integer(10),
            ]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.hasPrefix("found "))
        #expect(text.contains("memory(s)"))
    }

    /// An unknown preset name is a caller error — the boundary rejects it
    /// fail-CLOSED with a tool error naming the offending preset.
    @Test func testShapedRecallUnknownPresetFailsClosed() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "sr-unknown"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        _ = try await dispatcher.dispatch(
            name: "moot_file_memory", arguments: fileArgs(content: "any content"))

        let result = try await dispatcher.dispatch(
            name: "moot_recall_shaped",
            arguments: .object([
                "query": .string("anything"),
                "preset": .string("no-such-preset"),
            ]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == true,
                "unknown preset must return a tool error (fail closed)")
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.contains("unknown preset"))
        #expect(text.contains("no-such-preset"))
    }

    /// An absent `preset` arg uses the unsteered balanced default and succeeds.
    /// Absence ≠ unknown: no preset arg must never produce an error.
    @Test func testShapedRecallAbsentPresetUsesBalanced() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "sr-absent"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: fileArgs(content: "the harbour lights flicker in the fog"))

        let result = try await dispatcher.dispatch(
            name: "moot_recall_shaped",
            arguments: .object(["query": .string("harbour")]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false,
                "absent preset must use balanced and succeed")
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.hasPrefix("found "))
    }

    /// The shaped-recall tool advertises the full preset roster in its
    /// description so the AI can pick a preset by intent.
    @Test func testShapedRecallToolAdvertisesRoster() throws {
        let tool = try #require(
            RecipeTools.tools().first { $0.name == "moot_recall_shaped" })
        // The roster lists every preset name with its one-line description.
        #expect(tool.description.contains("conceptual"))
        #expect(tool.description.contains("anti_redundant"))
        #expect(tool.description.contains("Roster:"))
    }

    // MARK: - migration benchmark run → confirm, end to end

    @Test func testMigrationBenchmarkRunThenConfirmDispatch() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "mb"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let runArgs: JSONValue = .object([
            "corpusName": .string("src"),
            "entries": .array([
                .object([
                    "id": .string("a"),
                    "content": .string("alpha topic about felines"),
                    "subject": .string("alpha topic about felines"),
                    "tags": .array([]),
                ]),
                .object([
                    "id": .string("b"),
                    "content": .string("beta topic about canines"),
                    "subject": .string("beta topic about canines"),
                    "tags": .array([]),
                ]),
            ]),
            "plans": .array([
                .object([
                    "name": .string("flat"),
                    "room": .string("r1"),
                    "latticeCode": .string("000"),
                    "embeddingModelID": .string("test-v1"),
                ]),
                .object([
                    "name": .string("nested"),
                    "room": .string("r2"),
                    "latticeCode": .string("100"),
                    "embeddingModelID": .string("test-v1"),
                ]),
            ]),
        ])

        let runResult = try await dispatcher.dispatch(
            name: "moot_run_migration", arguments: runArgs)
        let runObj = try #require(runResult.objectValue)
        #expect(runObj["isError"]?.boolValue == false)
        let runText = try #require(
            runObj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        // Both clean plans survive and a winner is named.
        #expect(runText.contains("winner: plan"))
        #expect(runText.contains("rankings:"))

        // Recover the winner + loser branch ids from the surfaced text the
        // way an MCP client would. The winner id appears twice (the
        // "winner:" line and its own ranking line), so dedup preserving
        // order: two distinct ranked branches → two unique ids.
        let ids = Self.uniqueUUIDs(in: runText)
        #expect(ids.count == 2, "expected two distinct ranked branch ids in run output")

        // The winner line names the winner id; confirm with that.
        let winnerLine = runText.split(separator: "\n").first { $0.contains("winner: plan") } ?? ""
        let winner = try #require(Self.uuids(in: String(winnerLine)).first)
        let losers = ids.filter { $0 != winner }
        #expect(losers.count == 1, "expected exactly one loser branch")

        let confirmArgs: JSONValue = .object([
            "winnerBranchID": .string(winner.uuidString),
            "discardBranchIDs": .array(losers.map { .string($0.uuidString) }),
        ])
        let confirmResult = try await dispatcher.dispatch(
            name: "moot_confirm_migration", arguments: confirmArgs)
        let confirmObj = try #require(confirmResult.objectValue)
        #expect(confirmObj["isError"]?.boolValue == false)

        // The winner branch is now promoted.
        let resolved = await kit.branchHandle(for: winner)
        let winnerBranch = try #require(resolved)
        #expect(winnerBranch.status == .won)
    }

    @Test func testConfirmRefusesDisqualifiedWinner() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "dq"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Derive a real branch and discard it (what the benchmark run does
        // to a disqualified plan). Confirm it as winner while OMITTING any
        // disqualification argument — the exact reported bypass shape. The
        // server-side C-5 verdict must refuse with isError; no
        // client-supplied claim participates.
        let branch = try await NeuronKit.deriveBranch(
            name: "p", from: handle, in: kit)
        try await branch.discard()
        let confirmArgs: JSONValue = .object([
            "winnerBranchID": .string(branch.branchID.uuidString),
        ])
        let result = try await dispatcher.dispatch(
            name: "moot_confirm_migration", arguments: confirmArgs)
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == true)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.contains("silentConceptLoss"))
        // Never promoted.
        #expect(branch.status == .discarded)
    }

    // MARK: - dream dispatch

    /// `moot_dream` rebuilds the matrix tier and runs one dreaming cycle. With
    /// several drawers sharing a room there are co-occurrence pairs to mine, so
    /// the cycle considers candidates. Before the dream the estate has no
    /// registered matrix tier (the `matrix` recall lane reads 0.0); after it the
    /// tier is built — this is the "starved vs weak" un-starving the gauntlet
    /// re-ablation measures end-to-end.
    @Test func testDreamDispatchRebuildsMatrixAndRunsCycle() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "dream-dispatch"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // File four drawers so they co-surface on external-origin recall.
        for text in [
            "the treaty fixed the indemnity at 46 million marks",
            "the treaty ceded the eastern province in 1871",
            "the armistice was signed at Versailles in January",
            "the provisional government ratified the terms in March",
        ] {
            _ = try await dispatcher.dispatch(
                name: "moot_file_memory",
                arguments: .object([
                    "content": .string(text),
                    "subject": .string(String(text.prefix(120))),
                    "location": .string("history/treaty"),
                ]))
        }

        // Fire 3 external-origin recalls (moot_memory_search) to enqueue co-recall
        // windows. Each search surfaces all four drawers and writes one DreamingItem
        // to the estate's dreaming queue (v2 drain-fed model: candidates come ONLY
        // from draining the dreaming queue, not from a co-occurrence reader pass).
        // After 3 searches, co_recall_count for each of the C(4,2)=6 drawer pairs
        // reaches 3, meeting DreamingPolicy.default minAttempts=3.
        for _ in 0..<3 {
            _ = try await dispatcher.dispatch(
                name: "moot_memory_search",
                arguments: .object(["query": .string("treaty indemnity province armistice")]))
        }

        // Deterministic instant so the cycle (diary timestamp, reward window)
        // is reproducible.
        let dreamArgs = JSONValue.object(["now": .string("2026-06-11T00:00:00Z")])
        let result = try await dispatcher.dispatch(name: "moot_dream", arguments: dreamArgs)

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.contains("matrix rebuilt, dreaming cycle complete"))
        // Three external-origin recalls × four co-surfaced drawers → co_recall_count
        // reaches 3 for each of the six pairs → all six are considered.
        // Extract and verify the count is ≥ 6 (estate may include additional seed
        // drawers, so the count can exceed 6 without being wrong).
        let candidatesLine = text.components(separatedBy: "\n")
            .first(where: { $0.hasPrefix("consideredCandidates: ") }) ?? ""
        let countStr = candidatesLine.replacingOccurrences(of: "consideredCandidates: ", with: "")
        let count = Int(countStr.trimmingCharacters(in: .whitespaces)) ?? 0
        #expect(count >= 6,
                "three searches × ≥4 co-surfaced drawers must yield ≥6 co-recall pairs (v2 drain model); got: \(text)")

        // Idempotent: a second dream over unchanged state emits no NEW proposals
        // (every candidate already proposed or suppressed). The tool still
        // succeeds and the matrix rebuild is a deterministic no-op.
        let second = try await dispatcher.dispatch(name: "moot_dream", arguments: dreamArgs)
        let secondObj = try #require(second.objectValue)
        #expect(secondObj["isError"]?.boolValue == false)
    }

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

    @Test func testAssociationRulesDispatchReturnsOutput() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ar-dispatch"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // File some memories so there's co-occurrence to mine.
        for _ in 0..<3 {
            _ = try await dispatcher.dispatch(
                name: "moot_file_memory",
                arguments: .object([
                    "content": .string("study content"),
                    "subject": .string("study content"),
                    "location": .string("study"),
                ]))
        }

        let result = try await dispatcher.dispatch(
            name: "moot_lens_associations",
            arguments: .object(["filter": .string("unconfirmed")]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.contains("association_rules:"))
        #expect(text.contains("drawer(s)"))
    }

    @Test func testAnalyticsLensToolsAppearInListLenses() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ar-list"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_list_lenses", arguments: .object([:]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        // Analytics lens tools are listed by ProjectedTool name.
        #expect(text.contains("moot_lens_associations"))
        #expect(text.contains("moot_lens_concepts"))
    }

    // MARK: - formal_concepts dispatch

    @Test func testFormalConceptsDispatchReturnsOutput() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "fc-dispatch"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        for _ in 0..<2 {
            _ = try await dispatcher.dispatch(
                name: "moot_file_memory",
                arguments: .object([
                    "content": .string("study content"),
                    "subject": .string("study content"),
                    "location": .string("study"),
                ]))
        }

        let result = try await dispatcher.dispatch(
            name: "moot_lens_concepts",
            arguments: .object([
                "filter": .string("unconfirmed"),
                "minSupport": .integer(1),
                "maxIntentSize": .integer(8),
                "maxConcepts": .integer(10),
            ]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.contains("formal_concepts:"))
        #expect(text.contains("drawer(s)"))
    }

    // MARK: - isRecipeTool

    @Test func testIsRecipeToolCoversDistillationTools() {
        #expect(RecipeTools.isRecipeTool("moot_distill"))
        // moot_consolidate is out of the routing set entirely (alias removed,
        // SPEC_DISTILLATION_STORAGE §3 Phase 2) — the name reserves for the
        // multi-item consolidation feature.
        #expect(!RecipeTools.isRecipeTool("moot_consolidate"))
        #expect(RecipeTools.isRecipeTool("moot_recall_distilled"))
        // moot_recollect is in the routing set as a notice-only stub (Wave 1 ACK
        // gate): it must reach dispatch to return the removal notice. Not listed.
        #expect(RecipeTools.isRecipeTool("moot_recollect"))
    }

    // MARK: - tools() count

    @Test func testRecipeToolsCount() {
        // 12 recipe tools: listRecipes, listRecipesCatalog, groundedSynthesis,
        // preciseRecall, shapedRecall, vagueRecall, runMigration,
        // confirmMigration, dream, distill, recallDistilled,
        // huntContradictions.
        #expect(RecipeTools.tools().count == 12)
        let names = RecipeTools.tools().map(\.name)
        #expect(names.contains("moot_distill"))
        #expect(!names.contains("moot_consolidate"))
        #expect(!names.contains("moot_recollect"))
    }

    // MARK: - moot_distill dispatch

    @Test func testDistillDispatchRoutesToRunDistill() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "distill-dispatch"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Empty estate has no eligible items — sweep completes with 0.
        let result = try await dispatcher.dispatch(
            name: "moot_distill",
            arguments: .object([:]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.contains("moot_distill: sweep complete"))
        #expect(text.contains("itemsDistilled: 0"))
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

    @Test func testRecallDistilledDispatchRoutesToRunRecallDistilled() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "recall-distilled-dispatch"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Empty estate returns 0 matches — format starts correctly.
        // ack: "recall_distilled/v2" passes the ACK gate (Wave 1 contract change).
        let result = try await dispatcher.dispatch(
            name: "moot_recall_distilled",
            arguments: .object([
                "query": .string("any query"),
                "ack": .string("recall_distilled/v2"),
            ]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        // Default output starts with "found N memory(s)" — no query echo
        // and, since PR-03, no [distilled] tag (deviation-only narration:
        // distilled service is this verb's norm, only fallback rows carry
        // a marker). (echo_query:true opt-in restores the "for:" suffix.)
        #expect(text.hasPrefix("found "),
                "moot_recall_distilled output must start with 'found N memory(s)'")
        #expect(text.contains("memory(s)"),
                "output header must include 'memory(s)'")
        #expect(!text.contains("[distilled]"),
                "PR-03: the [distilled] header tag is retired")
        #expect(!text.contains("] for:"),
                "default response must NOT echo the query in the header")
    }

    @Test func testRecallDistilledOutputFormatStartsWithFoundN() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "recall-distilled-fmt"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_recall_distilled",
            arguments: .object([
                "query": .string("knowledge synthesis"),
                "limit": .integer(5),
                "ack": .string("recall_distilled/v2"),
            ]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        // First line must start with "found" per mission test requirements.
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        #expect(firstLine.hasPrefix("found "),
                "first line must start with 'found N memory(s) [distilled]'")
    }

    @Test func testRecallDistilledEchoQueryOptIn() async throws {
        // echo_query:true restores the "for: {query}" suffix that is OFF by default.
        // This test also proves echo_query is DECODED — if it were silently ignored
        // the header would stay short and the assertion at line 2 would fail.
        // If it were treated as unrecognized, the unknown-arg hint mechanism would
        // append "hint: unrecognized argument(s) ignored: echo_query" — line 3 catches that.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "recall-distilled-echo-optin"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_recall_distilled",
            arguments: .object([
                "query": .string("test echo query"),
                "echo_query": .bool(true),
                "ack": .string("recall_distilled/v2"),
            ]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        // With echo_query:true, header must echo the query.
        #expect(text.hasPrefix("found 0 memory(s) for: test echo query"),
                "echo_query:true must restore 'for: {query}' suffix in header")
        // echo_query is a declared arg — no unrecognized-arg hint must appear.
        #expect(!text.contains("hint: unrecognized argument(s) ignored"),
                "echo_query is declared — must NOT trigger the unrecognized-arg hint")
    }

    @Test func testRecallDistilledEchoQueryDefaultOff() async throws {
        // Without echo_query (or echo_query:false), header must NOT contain the query.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "recall-distilled-echo-off"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_recall_distilled",
            arguments: .object([
                "query": .string("silent query test"),
                "ack": .string("recall_distilled/v2"),
            ]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        // Default (no echo_query) must omit the query from the header.
        #expect(!text.contains("] for:"),
                "default response must NOT echo the query in the header")
        #expect(text.contains("found 0 memory(s)"),
                "header must still contain the count line")
    }

    // MARK: - ACK gate and notice-only stub tests (Wave 1)

    // moot_recollect — always returns the removed notice; no estate access.
    @Test func testRecollectStubReturnsNoticeNeverExecutes() async throws {
        // The tool must return the removal notice regardless of what args are
        // passed — even with ack or arbitrary extra parameters. No estate is
        // opened (notice fires before resolveHandle).
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "recollect-stub"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_recollect",
            arguments: .object(["ack": .string("anything"), "query": .string("test")]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text == RecipeTools.recollectRemovedNotice,
                "moot_recollect must return the exact removal notice, no more")
        // Confirm the notice does NOT start with "CONTRACT CHANGE NOTICE:" (it
        // is a removal statement, not a change gate — different wording).
        #expect(!text.hasPrefix("CONTRACT CHANGE NOTICE:"),
                "removal stub notice must be a removal statement, not a contract-change gate")
        #expect(text.contains("moot_recollect was removed"),
                "notice must state the tool was removed")
    }

    // moot_recall_distilled — notice when ack absent.
    @Test func testRecallDistilledWithoutAckReturnsContractNotice() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "recall-distilled-no-ack"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_recall_distilled",
            arguments: .object(["query": .string("any query")]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text == RecipeTools.recallDistilledContractNotice,
                "absent ack must return the exact CONTRACT CHANGE NOTICE text")
        #expect(text.hasPrefix("CONTRACT CHANGE NOTICE:"),
                "notice must start with CONTRACT CHANGE NOTICE:")
        #expect(text.contains(#"ack: "recall_distilled/v2""#),
                "notice must quote the current token")
        // Side-effect check: notice fires before estate access.
        #expect(!text.contains("found "),
                "no recall must have run — estate must be untouched")
    }

    // moot_recall_distilled — notice when ack is wrong/stale token.
    @Test func testRecallDistilledWithWrongAckReturnsContractNotice() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "recall-distilled-wrong-ack"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_recall_distilled",
            arguments: .object([
                "query": .string("any query"),
                "ack": .string("recall_distilled/v1"),
            ]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text == RecipeTools.recallDistilledContractNotice,
                "wrong ack token must return the same CONTRACT CHANGE NOTICE")
        #expect(text.contains(#"ack: "recall_distilled/v2""#),
                "notice must always quote the current token, not the caller's stale one")
    }

    // Schema: moot_recall_distilled exposes ack parameter.
    @Test func testRecallDistilledSchemaExposesAckParam() throws {
        let tool = RecipeTools.tools().first(where: { $0.name == "moot_recall_distilled" })
        let tool_ = try #require(tool, "moot_recall_distilled must appear in tools()")
        let props = tool_.inputSchema.objectValue?["properties"]?.objectValue
        let props_ = try #require(props, "moot_recall_distilled schema must have properties")
        #expect(props_["ack"] != nil,
                "moot_recall_distilled schema must expose 'ack' parameter")
        // The ack property must be a string type.
        let ackType = props_["ack"]?.objectValue?["type"]?.stringValue
        #expect(ackType == "string",
                "ack param must be type: string")
    }

    // Description: moot_recall_distilled description documents the current token.
    @Test func testRecallDistilledDescriptionContainsToken() throws {
        let tool = RecipeTools.tools().first(where: { $0.name == "moot_recall_distilled" })
        let tool_ = try #require(tool)
        #expect(tool_.description.contains("recall_distilled/v2"),
                "moot_recall_distilled description must document the current ack token")
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

    @Test func shapedRecallNegativeLimitThrows() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(in: kit)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_recall_shaped",
                arguments: .object([
                    "query": .string("test"),
                    "limit": .integer(-1),
                ]))
        }
    }

    @Test func distilledRecallNegativeLimitThrows() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(in: kit)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // ack: "recall_distilled/v2" passes the ACK gate (Wave 1 contract change)
        // so the call reaches the limit-validation guard, which must still throw.
        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_recall_distilled",
                arguments: .object([
                    "query": .string("test"),
                    "limit": .integer(0),
                    "ack": .string("recall_distilled/v2"),
                ]))
        }
    }

    // MARK: - Dream future-now guard

    @Test func dreamFarFutureNowThrowsInvalidParams() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(in: kit)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // A date 48 hours in the future — well beyond the 24 h ceiling.
        let farFuture = Date().addingTimeInterval(48 * 3600)
        let formatter = ISO8601DateFormatter()
        let farFutureStr = formatter.string(from: farFuture)

        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_dream",
                arguments: .object(["now": .string(farFutureStr)]))
        }
    }

    @Test func dreamNowWithinCeilingIsAccepted() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(in: kit)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // A date 12 hours in the future — within the 24 h ceiling.
        let nearFuture = Date().addingTimeInterval(12 * 3600)
        let formatter = ISO8601DateFormatter()
        let nearFutureStr = formatter.string(from: nearFuture)

        // Should NOT throw — the future-now guard allows up to 24 h.
        // The dream itself may fail (empty estate) but must not fail at the
        // boundary validation.
        _ = try? await dispatcher.dispatch(
            name: "moot_dream",
            arguments: .object(["now": .string(nearFutureStr)]))
    }

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
}
