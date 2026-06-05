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
/// runs multi-step capture/run/confirm sequences; preserve the
/// one-at-a-time execution the suite ran under XCTest.
@Suite("Recipe tools", .serialized)
struct RecipeToolsTests {

    // MARK: - Harness

    private func openEstate(
        in kit: GeniusLocusKit, owner: OwnerCredentials
    ) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        return try await kit.open(storage: storage, owner: owner)
    }

    private func fileArgs(content: String) -> JSONValue {
        .object([
            "content": .string(content),
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
        #expect(recipeNames == [
            "moot_confirm_migration",
            "moot_lens_anticipate",
            "moot_lens_associations",
            "moot_lens_bias",
            "moot_lens_concepts",
            "moot_lens_constellation",
            "moot_lens_contradiction",
            "moot_lens_divergence",
            "moot_lens_drift",
            "moot_lens_free_association",
            "moot_lens_keystones",
            "moot_lens_latent_themes",
            "moot_lens_overlap",
            "moot_lens_partial_cue",
            "moot_lens_successors",
            "moot_lens_theme_weather",
            "moot_lens_trust_synthesis",
            "moot_list_lenses",
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
        #expect(text.contains("18 cognition tools"))
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
                    "tags": .array([]),
                ]),
                .object([
                    "id": .string("b"),
                    "content": .string("beta topic about canines"),
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

        // Derive a real branch so its id resolves; name it as both winner
        // and disqualified — the C-5 guard must refuse with isError.
        let branch = try await NeuronKit.deriveBranch(
            name: "p", from: handle, in: kit)
        let confirmArgs: JSONValue = .object([
            "winnerBranchID": .string(branch.branchID.uuidString),
            "disqualifiedBranchIDs": .array([.string(branch.branchID.uuidString)]),
        ])
        let result = try await dispatcher.dispatch(
            name: "moot_confirm_migration", arguments: confirmArgs)
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == true)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.contains("silentConceptLoss"))
        // Never promoted.
        #expect(branch.status == .active)
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
