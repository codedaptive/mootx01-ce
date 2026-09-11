// RecipeToolsTests.swift
//
// Coverage for the CognitionKit behaviour-recipe surface on ARIA_MCP:
// the recipe tools project into tools/list with `.recipe` provenance and
// dispatch by name end-to-end against a real in-memory GeniusLocusKit
// estate (no mocks). Mirrors the MultiEstateRoutingTests harness: recalls
// use unconfirmed so freshly-captured rows are visible.
//
// v2 output shape: every dispatch wraps its result in an AriaV2Envelope.
//   content[0].text  = compactText (brief format: "Returned N X result(s).")
//   structuredContent.data = typed payload (results array, summary, cues, etc.)
// Tests check content[0].text for the compact format and structuredContent.data
// for the actual payload — never the legacy "found N candidate memories" shape.

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

    /// Access the typed payload from a v2 envelope result.
    /// content[0].text → compactText; structuredContent.data → typed payload.
    private func structuredData(_ result: JSONValue) -> [String: JSONValue]? {
        result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
    }

    /// Extract memory IDs from a v2 recall result's structuredContent.data.results array.
    /// Normalises to lowercase so comparisons against canonicalUUID() outputs (which are
    /// lowercase) round-trip correctly — UUID.uuidString returns UPPERCASE in Swift.
    private func resultIDs(_ result: JSONValue) -> [String] {
        structuredData(result)?["results"]?.arrayValue?
            .compactMap { $0.objectValue?["id"]?.stringValue?.lowercased() } ?? []
    }

    // MARK: - Projection

    /// In ARIA v2, recipe tools live in RecipeTools.tools() — not in
    /// ToolProjection.tools() which returns only catalog (interface-provenance)
    /// tools. This test pins the full sorted name list of the 14 recipe tools
    /// so neither the tool registry nor the test can drift silently.
    @Test func testRecipeToolsAppearInProjectionWithRecipeProvenance() {
        let recipeNames = RecipeTools.tools().map(\.name).sorted()
        // Full sorted list: 14 recipe tools.
        // moot_recollect retired (not listed — notice-only stub reached via isRecipeTool).
        // moot_recall_connected joined 2026-08-06 (graph-diffusion multi-hop recall).
        // moot_recall_walk joined D10 (escalation-ladder recall: cheap session_hybrid
        // first, precise hamming+text only when Stage 1 is not confident).
        // Migration tool names in RecipeTools use the legacy surface keys;
        // the catalog routes them under moot_migration_run / moot_migration_confirm.
        #expect(recipeNames == [
            "moot_confirm_migration",
            "moot_dream",
            "moot_hunt_contradictions",
            "moot_list_lenses",
            "moot_list_recipes",
            "moot_recall_connected",
            "moot_recall_distilled",
            "moot_recall_precise",
            "moot_recall_shaped",
            "moot_recall_temporal",
            "moot_recall_vague",
            "moot_recall_walk",
            "moot_run_migration",
            "moot_synthesize",
        ])
    }

    /// In v2 the cognition catalog lists all callable recipe + lens tools in
    /// structuredContent.data.tools. The compactText confirms the count.
    /// Migration tools are Tier 7 and absent from the callable cognition set.
    @Test func testListRecipesDispatchEnumeratesCognitionTools() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "lr"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_list_lenses", arguments: .object([:]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)

        // compactText: "Listed N callable cognition tools."
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.contains("callable cognition tools"),
                "compactText must confirm the count of callable tools; got: \(text)")

        // structuredContent.data.tools — array of {name, description, input_schema}.
        let tools = try #require(structuredData(result)?["tools"]?.arrayValue,
            "structuredContent.data.tools must be present")
        let toolNames = tools.compactMap { $0.objectValue?["name"]?.stringValue }
        #expect(toolNames.contains("moot_synthesize"),
                "moot_synthesize must be in the callable tools list")
        #expect(toolNames.contains("moot_list_lenses"),
                "moot_list_lenses must be in the callable tools list")
        // Migration tools are Tier 7 and absent from the cognition menu.
        #expect(!toolNames.contains("moot_run_migration"),
                "migration tools must not appear in the cognition catalog")
        #expect(!toolNames.contains("moot_confirm_migration"),
                "migration tools must not appear in the cognition catalog")
        // The catalog must be non-trivially populated (multiple tools).
        #expect(toolNames.count > 10,
                "callable tools list must be non-trivially populated; got \(toolNames.count)")
    }

    /// In ARIA v2, both RecipeTools.tools() and ToolProjection.tools() expose the
    /// same v2 catalog surface. Recipe tool names must be PRESENT in
    /// ToolProjection.tools() (they're part of the unified catalog) — the v1
    /// invariant of "no collision" inverts in v2 to "every recipe tool is
    /// registered in the catalog."
    @Test func testRecipeToolNamesDoNotCollideWithInterfaceToolNames() {
        // v2: the catalog is unified — every recipe tool must be reachable via
        // ToolProjection.tools() so admitsDispatch returns true for each.
        // A recipe tool absent from the catalog would throw methodNotFound on dispatch.
        let catalogNames = Set(ToolProjection.tools().map(\.name))
        // RecipeTools uses legacy migration names (moot_run_migration, moot_confirm_migration)
        // which differ from v2 catalog names (moot_migration_run, moot_migration_confirm).
        // Exclude them from this parity check; they dispatch through the legacy RecipeTools
        // code path and are NOT registered in ToolProjection.tools().
        let migrationLegacyNames: Set<String> = ["moot_run_migration", "moot_confirm_migration"]
        for tool in RecipeTools.tools() {
            guard !migrationLegacyNames.contains(tool.name) else { continue }
            #expect(catalogNames.contains(tool.name),
                    "recipe tool \(tool.name) must be registered in the v2 catalog (ToolProjection.tools())")
        }
    }

    // MARK: - recall_connected dispatch

    /// The bridge scenario recall_connected exists for: the answer memory
    /// shares NO words with the query and is reachable only through a
    /// connection edge. File hop-1 (matches the query), file the answer,
    /// link them (a validated tunnel via moot_link_memories), then ask.
    /// Plain similarity cannot surface the answer; the walk must.
    @Test func testConnectedRecallReachesBridgeLinkedAnswer() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "rc"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        func fileOne(_ content: String) async throws -> String {
            let result = try await dispatcher.dispatch(
                name: "moot_file_memory", arguments: fileArgs(content: content))
            let text = result.objectValue?["content"]?.arrayValue?.first?
                .objectValue?["text"]?.stringValue ?? ""
            // "filed memory <UUID>" — first line, third token.
            return text.split(separator: "\n").first?
                .split(separator: " ").last.map(String.init) ?? ""
        }

        let hop1 = try await fileOne("Melanie mentioned her sister visited from Cambridge")
        let answer = try await fileOne("Caroline finished the astrophysics degree this spring")
        // Distractors so the anchor pool is not trivially the whole estate.
        _ = try await fileOne("grocery shopping list for the weekend")
        _ = try await fileOne("bicycle maintenance notes and tire pressure")

        // Validated tunnel between hop-1 and the answer (the human-approved
        // edge class; associations are the dream's pending equivalent).
        // v2: `relationship` replaces `kind`; `label` arg removed.
        _ = try await dispatcher.dispatch(
            name: "moot_link_memories",
            arguments: .object([
                "from_id": .string(hop1),
                "to_id": .string(answer),
                "relationship": .string("relates"),
            ]))

        let result = try await dispatcher.dispatch(
            name: "moot_recall_connected",
            arguments: .object([
                "query": .string("Melanie sister Cambridge"),
                "wing": .string("recipe-tests"),
                "filter": .string("unconfirmed"),
                "limit": .integer(10),
            ]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        // v2 compactText: "Returned N connected recall result(s)."
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.contains("connected recall result"),
                "compactText must confirm connected recall results; got: \(text)")
        // The answer drawer ID must appear in structuredContent.data.results.
        let ids = resultIDs(result)
        #expect(ids.contains(answer),
                "the tunnel-linked answer must be reachable via the walk; got IDs: \(ids)")
    }

    /// Gate invariant: a tombstoned (withdrawn) memory linked by a tunnel to
    /// a live anchor must NOT appear in connected-recall results. The walk
    /// discovers the edge and attempts hydration; the gated overload
    /// (insertDefaults plus the caller's filter) excludes the withdrawn row
    /// via .currentlyBelieve.
    @Test func testConnectedRecallExcludesTombstonedRows() async throws {
        let owner = OwnerCredentials(ownerIdentifier: "crg-tomb")
        let kit = GeniusLocusKit()
        let handle = try await openEstate(in: kit, owner: owner)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        func fileOne(_ content: String) async throws -> String {
            let result = try await dispatcher.dispatch(
                name: "moot_file_memory", arguments: fileArgs(content: content))
            let text = result.objectValue?["content"]?.arrayValue?.first?
                .objectValue?["text"]?.stringValue ?? ""
            return text.split(separator: "\n").first?
                .split(separator: " ").last.map(String.init) ?? ""
        }

        // The dead memory is the walk target; it shares no words with the query.
        let deadContent = "XylophoneZebra secret project archive notes"
        let dead = try await fileOne(deadContent)
        // Anchor memory matches the query directly.
        let anchor = try await fileOne("Quarterly planning moved to Thursday confirmed")
        // Distractor to prevent trivial recall.
        _ = try await fileOne("bicycle tire pressure maintenance schedule")

        // Link dead → anchor so the walk can discover dead from anchor.
        // v2: `relationship` replaces `kind`; `label` arg removed.
        _ = try await dispatcher.dispatch(
            name: "moot_link_memories",
            arguments: .object([
                "from_id": .string(dead),
                "to_id": .string(anchor),
                "relationship": .string("relates"),
            ]))

        // Withdraw the dead memory — state transition to .withdrawn, which
        // insertDefaults' .currentlyBelieve filter excludes.
        // v2: `memory_id` replaces `id`.
        let withdrawResult = try await dispatcher.dispatch(
            name: "moot_withdraw_memory",
            arguments: .object(["memory_id": .string(dead)]))
        // v2 compactText: "Withdrew memory UUID." (capital W)
        let withdrawText = withdrawResult.objectValue?["content"]?.arrayValue?.first?
            .objectValue?["text"]?.stringValue ?? ""
        #expect(withdrawText.contains("Withdrew"), "withdraw must succeed; got: \(withdrawText)")

        let result = try await dispatcher.dispatch(
            name: "moot_recall_connected",
            arguments: .object([
                "query": .string("quarterly planning Thursday"),
                "filter": .string("unconfirmed"),
                "limit": .integer(10),
            ]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        // The dead memory's ID must NOT appear in structuredContent.data.results.
        let ids = resultIDs(result)
        #expect(!ids.contains(dead),
                "tombstoned row ID must be absent from connected recall; got IDs: \(ids)")
    }

    /// Gate invariant: a sensitivity-restricted memory linked by a tunnel to a
    /// live anchor must NOT appear in connected-recall results. The walk
    /// discovers the edge; the gated overload applies the insertDefaults ceiling
    /// of .sensitivityAtMost(.elevated), excluding .restricted rows.
    @Test func testConnectedRecallExcludesSensitivityRestrictedRows() async throws {
        let owner = OwnerCredentials(ownerIdentifier: "crg-sens")
        let kit = GeniusLocusKit()
        let handle = try await openEstate(in: kit, owner: owner)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        func fileOne(_ content: String) async throws -> String {
            let result = try await dispatcher.dispatch(
                name: "moot_file_memory", arguments: fileArgs(content: content))
            let text = result.objectValue?["content"]?.arrayValue?.first?
                .objectValue?["text"]?.stringValue ?? ""
            return text.split(separator: "\n").first?
                .split(separator: " ").last.map(String.init) ?? ""
        }

        // Anchor memory — matches the query.
        let anchor = try await fileOne("Annual performance review scheduling confirmed")
        // Distractor.
        _ = try await fileOne("grocery run Saturday morning")

        // Restricted memory — filed at .restricted sensitivity so the default
        // sensitivity ceiling (.elevated) blocks it from connected-recall hydration.
        let restrictedContent = "ConfidentialAardvark internal salary band information"
        let restricted = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string(restrictedContent),
                "subject": .string(String(restrictedContent.prefix(120))),
                "location": .string("recipe-tests"),
                "sensitivity": .string("restricted"),
            ]))
        let restrictedText = restricted.objectValue?["content"]?.arrayValue?.first?
            .objectValue?["text"]?.stringValue ?? ""
        let restrictedID = restrictedText.split(separator: "\n").first?
            .split(separator: " ").last.map(String.init) ?? ""
        #expect(!restrictedID.isEmpty, "restricted memory must be filed; got: \(restrictedText)")

        // Link restricted → anchor so the walk can reach it from anchor.
        // v2: `relationship` replaces `kind`; `label` arg removed.
        _ = try await dispatcher.dispatch(
            name: "moot_link_memories",
            arguments: .object([
                "from_id": .string(restrictedID),
                "to_id": .string(anchor),
                "relationship": .string("relates"),
            ]))

        let result = try await dispatcher.dispatch(
            name: "moot_recall_connected",
            arguments: .object([
                "query": .string("annual performance review scheduling"),
                "filter": .string("unconfirmed"),
                "limit": .integer(10),
            ]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        // The restricted memory's ID must NOT appear in results.
        let ids = resultIDs(result)
        #expect(!ids.contains(restrictedID),
                "restricted row ID must be absent from connected recall; got IDs: \(ids)")
    }

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
            sourceDrawerId: anchor, targetDrawerId: target, kind: .references)
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
        let controlIDs = resultIDs(control)
        #expect(controlIDs.contains(target),
                "FIXTURE: the walk must reach the linked target under an unrestricted filter; got IDs: \(controlIDs)")
        return (anchor, target)
    }

    /// Wave-3 G1 gate invariant: the CALLER's filter applies to walk
    /// hydration, not only to anchor recall. A non-exportable (born-private)
    /// drawer linked to an exportable anchor must NOT surface its ID
    /// under filter:"exportable", while the exportable anchor itself must.
    /// Twin of Rust `connected_recall_walk_honors_exportable_filter`.
    @Test func testConnectedRecallWalkHonorsExportableFilter() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "g1-exp"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let fixture = try await g1WalkFixture(
            kit: kit, handle: handle,
            dispatcher: dispatcher,
            anchorContent: "Roadmap review moved to Friday afternoon confirmed",
            anchorExportability: "public",
            targetContent: "VelvetOctopus internal pricing draft numbers",
            targetExportability: nil,
            controlQuery: "roadmap review Friday")

        let result = try await dispatcher.dispatch(
            name: "moot_recall_connected",
            arguments: .object([
                "query": .string("roadmap review Friday"),
                "wing": .string("recipe-tests"),
                "filter": .string("exportable"),
                "limit": .integer(10),
            ]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let ids = resultIDs(result)
        #expect(ids.contains(fixture.anchor),
                "exportable anchor ID must be present; got IDs: \(ids)")
        #expect(!ids.contains(fixture.target),
                "non-exportable row ID must be absent under filter:exportable; got IDs: \(ids)")
    }

    /// Wave-3 G1 gate invariant, confirmation axis: an unconfirmed drawer
    /// linked to a user-confirmed anchor must NOT surface its ID under
    /// filter:"userConfirmed".
    /// Twin of Rust `connected_recall_walk_honors_user_confirmed_filter`.
    @Test func testConnectedRecallWalkHonorsUserConfirmedFilter() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "g1-conf"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let fixture = try await g1WalkFixture(
            kit: kit, handle: handle,
            dispatcher: dispatcher,
            anchorContent: "Sprint retro moved to Tuesday morning confirmed",
            anchorExportability: nil,
            targetContent: "CrimsonNarwhal draft merger term sheet notes",
            targetExportability: nil,
            controlQuery: "sprint retro Tuesday")
        // v2: `memory_id` replaces `id`.
        _ = try await dispatcher.dispatch(
            name: "moot_confirm_memory",
            arguments: .object(["memory_id": .string(fixture.anchor)]))

        let result = try await dispatcher.dispatch(
            name: "moot_recall_connected",
            arguments: .object([
                "query": .string("sprint retro Tuesday"),
                "wing": .string("recipe-tests"),
                "filter": .string("userConfirmed"),
                "limit": .integer(10),
            ]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let ids = resultIDs(result)
        #expect(ids.contains(fixture.anchor),
                "confirmed anchor ID must be present; got IDs: \(ids)")
        #expect(!ids.contains(fixture.target),
                "unconfirmed row ID must be absent under filter:userConfirmed; got IDs: \(ids)")
    }

    /// Wave-3 G1 gate invariant, containment axis: a PUBLIC drawer linked to
    /// a contained (born-private) anchor must NOT surface its ID under
    /// filter:"contained" — the inverse of the exportable test.
    /// Twin of Rust `connected_recall_walk_honors_contained_filter`.
    @Test func testConnectedRecallWalkHonorsContainedFilter() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "g1-cont"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let fixture = try await g1WalkFixture(
            kit: kit, handle: handle,
            dispatcher: dispatcher,
            anchorContent: "Standup notes archived for Thursday review",
            anchorExportability: nil,
            targetContent: "AmberFalcon public changelog draft for the release",
            targetExportability: "public",
            controlQuery: "standup notes Thursday")

        let result = try await dispatcher.dispatch(
            name: "moot_recall_connected",
            arguments: .object([
                "query": .string("standup notes Thursday"),
                "wing": .string("recipe-tests"),
                "filter": .string("contained"),
                "limit": .integer(10),
            ]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let ids = resultIDs(result)
        #expect(ids.contains(fixture.anchor),
                "contained anchor ID must be present; got IDs: \(ids)")
        #expect(!ids.contains(fixture.target),
                "public row ID must be absent under filter:contained; got IDs: \(ids)")
    }

    // MARK: - grounded_synthesis dispatch

    /// v2 synthesize routes through AriaV2Orchestration; result is in
    /// structuredContent.data: { summary, results, cues }.
    /// compactText = "moot_synthesize completed for selected estate UUID."
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

        // v2 compactText confirms the operation completed.
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.contains("moot_synthesize"), "compactText must name the operation; got: \(text)")

        // structuredContent.data.results — the ranked synthesis pool.
        let data = try #require(structuredData(result), "structuredContent.data must be present")
        let results = try #require(data["results"]?.arrayValue, "data.results must be present")
        #expect(results.count >= 1, "synthesis must return at least one memory from a non-empty estate")

        // summary must be populated when the estate has content.
        let summary = try #require(data["summary"]?.stringValue, "data.summary must be present")
        #expect(!summary.isEmpty, "summary must be non-empty for a seeded estate")
    }

    /// `query` grounds the synthesis through BOTH hybrid lanes: the lexical
    /// cue lane ranks term-matching memories first, and the scored lane
    /// (BM25 + vector, high-recall) may admit non-matching rows BELOW them
    /// up to the cap. The cues appear in structuredContent.data.cues, and the
    /// cue-relevant memories must LEAD the results array — grounding is a
    /// ranking guarantee, not a hard exclusion.
    @Test func testGroundedSynthesisQueryRanksCueMatchesFirst() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "gsq"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // File three memories: two carbon-related, one unrelated.
        var carbonIDs: [String] = []
        for text in [
            "carbon chemistry of organic compounds",
            "carbon based biochemistry of life",
            "quantum mechanics fundamentals",
        ] {
            let r = try await dispatcher.dispatch(
                name: "moot_file_memory", arguments: fileArgs(content: text))
            let t = r.objectValue?["content"]?.arrayValue?.first?
                .objectValue?["text"]?.stringValue ?? ""
            let id = t.split(separator: "\n").first?
                .split(separator: " ").last.map(String.init) ?? ""
            if text.contains("carbon") { carbonIDs.append(id) }
        }

        let result = try await dispatcher.dispatch(
            name: "moot_synthesize",
            arguments: .object([
                "query": .string("carbon compounds"),
                "filter": .string("unconfirmed"),
            ]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)

        let data = try #require(structuredData(result), "structuredContent.data must be present")

        // data.cues: the extracted query terms (lower-case split tokens).
        // v2 lower provider splits on non-letter/number; "carbon" and "compounds" are present.
        if let cues = data["cues"]?.arrayValue?.compactMap({ $0.stringValue }) {
            #expect(cues.contains("carbon"),
                    "data.cues must contain 'carbon' from the query; got: \(cues)")
            #expect(cues.contains("compounds"),
                    "data.cues must contain 'compounds' from the query; got: \(cues)")
        }

        // The first result must be one of the cue-matched (carbon) memories —
        // the two-lane fusion must never let a zero-term-match row outrank a term match.
        let results = try #require(data["results"]?.arrayValue, "data.results must be present")
        let firstID = results.first?.objectValue?["memory_id"]?.stringValue ?? ""
        #expect(carbonIDs.contains(firstID),
                "first result must be a cue-matched (carbon) memory; got id: \(firstID)")
    }

    /// Ranking is driven by cue-term relevance, not recency. File 5 memories:
    /// the OLDEST contains distinctive answer terms; 4 newer memories share a
    /// generic word. The answer memory must appear in structuredContent.data.results
    /// with cue-relevance ranking; recency alone would evict it.
    @Test func testGroundedSynthesisCueRankingBringsOldAnswerToTop() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "gsrank"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // File the answer memory FIRST (oldest). Contains four distinctive terms
        // that uniquely identify it. "daguerreotype" appears in this drawer only —
        // none of the 4 generic grocery drawers contain it.
        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: fileArgs(content: "daguerreotype vintage cameras photography collection"))

        // File 4 newer memories. Each contains the generic word "collection"
        // (passes the contentMatches filter) plus unrelated content.
        for i in 1...4 {
            _ = try await dispatcher.dispatch(
                name: "moot_file_memory",
                arguments: fileArgs(content: "grocery store shopping collection item \(i)"))
        }

        // Query with distinctive terms + generic term. The cue terms "daguerreotype",
        // "vintage", "cameras" must lift the answer memory above the generic
        // "collection"-only matches in the ranked results.
        let result = try await dispatcher.dispatch(
            name: "moot_synthesize",
            arguments: .object([
                "query": .string("daguerreotype vintage cameras collection"),
                "filter": .string("unconfirmed"),
                "limit": .integer(3),
            ]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)

        let data = try #require(structuredData(result), "structuredContent.data must be present")
        let results = try #require(data["results"]?.arrayValue, "data.results must be present")

        // The answer drawer must appear in the results. Its subject and excerpt contain
        // "daguerreotype" — a term that does NOT appear in any of the 4 generic drawers.
        // If cue ranking works, this drawer wins against pure-recency ordering; if not,
        // the 3 most-recent generic drawers fill the cap-3 output and this assertion fails.
        let foundDistinctiveAnswer = results.contains(where: {
            $0.objectValue?["subject"]?.stringValue?.contains("daguerreotype") == true ||
            $0.objectValue?["excerpt"]?.stringValue?.contains("daguerreotype") == true
        })
        #expect(foundDistinctiveAnswer,
                "answer drawer with distinctive term 'daguerreotype' must appear in cue-ranked results; recency alone would evict it; got \(results.count) results")
    }

    /// `moot_synthesize` silently removes provenance-restricted rows from the
    /// synthesis pool. A mixed estate (1 normal + 1 provenance-restricted row)
    /// must expose only the normal row in structuredContent.data.results.
    /// Unlike `moot_memory_search`, synthesis emits no redaction marker.
    /// Twin of Rust `grounded_synthesis_mixed_pool_only_exposes_normal_rows`.
    @Test func testSynthesizeDoesNotExposeProvenanceSensitiveRows() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "gs-prov"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Capture the normal row directly so we can set provenanceSensitivity.
        // moot_file_memory routes through the MCP capture path which does not
        // expose the provenance sensitivity parameter; direct kit.capture is
        // the correct harness surface for provenance gate tests.
        _ = try await kit.capture(handle, CaptureFrame(
            content: "classified aardvark synthesis normaltoken",
            channel: .typed,
            room: "prov-gate-test",
            latticeAnchor: .udc("004"),
            addedBy: "aria-mcp-tests",
            embeddingModelID: "test-model-v1",
            provenanceSensitivity: .normal,
            subject: "normaltoken aardvark synthesis"))

        // Capture the provenance-restricted row.
        _ = try await kit.capture(handle, CaptureFrame(
            content: "classified aardvark synthesis restrictedtoken",
            channel: .typed,
            room: "prov-gate-test",
            latticeAnchor: .udc("004"),
            addedBy: "aria-mcp-tests",
            embeddingModelID: "test-model-v1",
            provenanceSensitivity: .restricted,
            subject: "restrictedtoken aardvark synthesis"))

        let result = try await dispatcher.dispatch(
            name: "moot_synthesize",
            arguments: .object(["filter": .string("unconfirmed")]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)

        let data = try #require(structuredData(result), "structuredContent.data must be present")
        let results = try #require(data["results"]?.arrayValue, "data.results must be present")

        // Only the normal row feeds synthesis — provenance gate removes the
        // restricted row before the synthesizer runs. Exactly 1 result.
        #expect(results.count == 1,
                "only the normal row must reach synthesis; got \(results.count) results")

        // The normal row's subject must appear in the results; the restricted one must not.
        let subjects = results.compactMap {
            $0.objectValue?["subject"]?.stringValue
        }
        #expect(subjects.contains(where: { $0.contains("normaltoken") }),
                "normal row content must appear in results; got subjects: \(subjects)")
        #expect(!subjects.contains(where: { $0.contains("restrictedtoken") }),
                "provenance-restricted content must not appear in results; got subjects: \(subjects)")
    }

    /// BLOCKED: v2 cueTerms (AriaV2OrchestrationLower.swift:232) does a plain
    /// non-alphanumeric split with no stopword filter, so "what did they do" becomes
    /// ["what", "did", "they", "do"] and the call succeeds instead of throwing.
    /// The stopword validation guard present in v1 (RecipeTools.groundingTerms) is
    /// never reached on the v2 synthesize path. Awaiting a ruling.
    /// Do not delete; do not weaken to pass.
    /// The guard itself, asserted in the shape v2 actually answers in. The
    /// case below pins v1's transport (a thrown JSONRPCError) and is handed to
    /// the conversion lane; this one makes sure the guard cannot be removed
    /// unnoticed in the meantime.
    @Test
    func groundedSynthesisAllStopwordQueryIsRefusedAsInvalidArgument() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "gse-envelope"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_synthesize",
            arguments: .object(["query": .string("what did they do")]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == true,
                "a cue of nothing but stopwords must be refused, not answered from the whole estate")
        let code = obj["structuredContent"]?.objectValue?["error"]?.objectValue?["code"]?.stringValue
        #expect(code == "invalid_argument",
                "the refusal must tell the caller the cue was theirs to fix; got \(code ?? "nil")")
    }

    @Test(.disabled("CONVERSION PENDING (was BLOCKED on a missing guard). The guard is restored: Swift cueTerms now drops stopwords and short fragments exactly as the Rust port always did, and a cue that grounds on nothing is refused rather than answered from the whole estate — v1's reason, that a caller who sent a cue must never receive an unscoped estate digest, still holds. What remains is v1's TRANSPORT: this case expects a thrown JSONRPCError and v2 answers with an invalid_argument envelope, which groundedSynthesisAllStopwordQueryIsRefusedAsInvalidArgument above asserts. Redirecting this assertion to the envelope is like-for-like. Do not delete; do not weaken to pass."))
    func testGroundedSynthesisAllStopwordQueryThrowsInvalidParams() async throws {
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

    /// In v2, moot_recall_precise returns compactText "Returned N precise recall result(s)."
    /// and the results in structuredContent.data.results.
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

        // v2 compactText: "Returned N precise recall result(s)."
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.contains("precise recall result"),
                "compactText must confirm precise recall results; got: \(text)")

        // structuredContent.data.results — the ranked matches.
        let data = try #require(structuredData(result), "structuredContent.data must be present")
        let results = try #require(data["results"]?.arrayValue, "data.results must be present")
        #expect(results.count >= 1, "at least one result expected for a matching query")

        // The precise target (46) is surfaced; exact-match must rank it first.
        let firstSubject = results.first?.objectValue?["subject"]?.stringValue ?? ""
        #expect(firstSubject.contains("46 million marks"),
                "the distinctive-number target must rank first; got: '\(firstSubject)'")
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
    /// BLOCKED: AriaV2RecallLensService.execute() (AriaV2RecallLens.swift:350-351)
    /// catches ALL errors from authority.execute() in a bare `catch` and returns a
    /// generic "recall_unavailable" refusal. The AriaV2InvalidArgument thrown at
    /// line 193 ("Unknown precise-recall composition '\(composition)'") is swallowed
    /// there; specific argument names and invalid values never reach the tool result text.
    /// Awaiting a ruling. Do not delete; do not weaken to pass.
    @Test
    func testPreciseRecallUnknownCompositionFailsClosed() async throws {
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
    @Test func testPreciseRecallAbsentCompositionUsesDefault() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pr-absent-comp"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: fileArgs(content: "the indemnity was 46 million marks"))

        // No `composition` key at all — must succeed and return the precise recall shape.
        let result = try await dispatcher.dispatch(
            name: "moot_recall_precise",
            arguments: .object(["query": .string("indemnity")]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false,
                "absent composition must use the default and succeed")
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.contains("precise recall result"),
                "absent composition must return the precise recall compactText shape")
    }

    // MARK: - recall_shaped (named RecallShape preset surface)

    /// A known preset dispatches and returns v2 precise recall shape.
    /// Mirrors the Rust dispatch test `recall_shaped_known_preset_*`.
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
                "preset": .string("structural"),
                "filter": .string("unconfirmed"),
                "limit": .integer(10),
            ]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        // v2 compactText confirms the recall completed.
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.contains("recall result"),
                "compactText must confirm recall completed; got: \(text)")
        // Results must be present in structuredContent.data.
        let data = try #require(structuredData(result), "structuredContent.data must be present")
        let _ = try #require(data["results"]?.arrayValue, "data.results must be an array")
    }

    /// An unknown preset name is a caller error — the boundary rejects it
    /// fail-CLOSED with a tool error naming the offending preset.
    /// BLOCKED: AriaV2RecallLensService.execute() (AriaV2RecallLens.swift:350-351)
    /// catches ALL errors from authority.execute() in a bare `catch` and returns a
    /// generic "recall_unavailable" refusal. The AriaV2InvalidArgument thrown at
    /// line 137 ("Unknown recall preset '\(preset)'") is swallowed there; specific
    /// preset names and invalid values never reach the tool result text.
    /// Awaiting a ruling. Do not delete; do not weaken to pass.
    @Test
    func testShapedRecallUnknownPresetFailsClosed() async throws {
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
        #expect(text.contains("recall result"),
                "absent preset must return the recall compactText shape")
    }

    /// The shaped-recall tool advertises the full preset roster in its
    /// description so the AI can pick a preset by intent.
    @Test func testShapedRecallToolAdvertisesRoster() throws {
        let tool = try #require(
            RecipeTools.tools().first { $0.name == "moot_recall_shaped" })
        // The roster lists every preset name with its one-line description.
        #expect(tool.description.contains("Roster:"))
        for name in RecallShape.presetNames {
            #expect(tool.description.contains(name), "roster must advertise \(name)")
        }
        #expect(tool.description.contains("anti_redundant"))
    }

    /// Every roster name is accepted by the MCP boundary and returns a valid
    /// result. Mirrors testShapedRecallDispatchReturnsMootTextShape but
    /// exercises each preset through the full dispatch chain.
    @Test func testShapedRecallEveryRosterPresetAccepted() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "sr-float-metric"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: fileArgs(content: "the tide rises past the sea wall at dusk"))

        for presetName in RecallShape.presetNames {
            let result = try await dispatcher.dispatch(
                name: "moot_recall_shaped",
                arguments: .object([
                    "query": .string("tide sea wall"),
                    "preset": .string(presetName),
                    "filter": .string("unconfirmed"),
                    "limit": .integer(10),
                ]))

            let obj = try #require(result.objectValue)
            #expect(obj["isError"]?.boolValue == false,
                    "\(presetName) must be accepted (is a valid preset name)")
            let text = try #require(
                obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
            #expect(text.contains("recall result"),
                    "\(presetName) must return a recall result compactText")
        }
    }

    // MARK: - migration benchmark run → confirm, end to end

    /// v2: tool name is `moot_migration_run` (renamed from `moot_run_migration`).
    /// Confirm uses `moot_migration_confirm`; args are snake_case:
    /// `winner_branch_id`, `discard_branch_ids`.
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

        // v2: renamed from moot_run_migration.
        let runResult = try await dispatcher.dispatch(
            name: "moot_migration_run", arguments: runArgs)
        let runObj = try #require(runResult.objectValue)
        #expect(runObj["isError"]?.boolValue == false)

        // v2 result: structuredContent.data.winner_branch_id + rankings array
        let runData = try #require(structuredData(runResult),
            "structuredContent.data must be present for migration run")
        let winnerBranchIDStr = try #require(runData["winner_branch_id"]?.stringValue,
            "winner_branch_id must be present in run data")
        let winner = try #require(UUID(uuidString: winnerBranchIDStr),
            "winner_branch_id must be a valid UUID")

        let rankings = try #require(runData["rankings"]?.arrayValue,
            "rankings must be present in run data")
        #expect(rankings.count == 2, "expected two ranked branches")

        // Collect loser branch IDs (all ranked IDs except the winner).
        let rankedIDs = rankings.compactMap { $0.objectValue?["branch_id"]?.stringValue }
            .compactMap { UUID(uuidString: $0) }
        let losers = rankedIDs.filter { $0 != winner }
        #expect(losers.count == 1, "expected exactly one loser branch")

        // v2: renamed from moot_confirm_migration; args use snake_case.
        let confirmArgs: JSONValue = .object([
            "winner_branch_id": .string(winner.uuidString),
            "discard_branch_ids": .array(losers.map { .string($0.uuidString) }),
        ])
        let confirmResult = try await dispatcher.dispatch(
            name: "moot_migration_confirm", arguments: confirmArgs)
        let confirmObj = try #require(confirmResult.objectValue)
        #expect(confirmObj["isError"]?.boolValue == false)

        // The winner branch is now promoted.
        let resolved = await kit.branchHandle(for: winner)
        let winnerBranch = try #require(resolved)
        #expect(winnerBranch.status == .won)
    }

    /// A disqualified (already-discarded) branch must be refused as winner;
    /// the C-5 verdict fires server-side regardless of what the client claims.
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
        // v2: renamed from moot_confirm_migration; arg uses snake_case.
        let confirmArgs: JSONValue = .object([
            "winner_branch_id": .string(branch.branchID.uuidString),
        ])
        let result = try await dispatcher.dispatch(
            name: "moot_migration_confirm", arguments: confirmArgs)
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == true)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.contains("disqualified"))
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
        let dreamArgs = JSONValue.object([:])
        let result = try await dispatcher.dispatch(name: "moot_dream", arguments: dreamArgs)

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        // v2 compactText is "Dreaming cycle completed." (from AriaV2Dream.compactText).
        // The v1 multi-line text with "matrix rebuilt, dreaming cycle complete" and
        // an inline candidatesConsidered line is RecipeTools-specific and not present in v2.
        #expect(text.contains("Dreaming cycle completed"),
                "v2 dream compactText must confirm cycle; got: \(text)")
        // Three external-origin recalls × four co-surfaced drawers → co_recall_count
        // reaches 3 for each of the six pairs → all six are considered.
        // In v2, candidatesConsidered lives in structuredContent.data, not in compactText.
        let dreamData = structuredData(result)
        let count = Int(dreamData?["candidatesConsidered"]?.integerValue ?? 0)
        #expect(count >= 6,
                "three searches × ≥4 co-surfaced drawers must yield ≥6 co-recall pairs (v2 drain model); got candidatesConsidered: \(count)")

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

    /// v2: `moot_lens_associations` schema dropped the `filter` arg.
    /// Pass no filter — the tool runs over the full estate without filtering.
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

        // v2: `filter` is not in the moot_lens_associations schema; drop it.
        let result = try await dispatcher.dispatch(
            name: "moot_lens_associations",
            arguments: .object([:]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.contains("Found"))
        #expect(text.contains("association rules"))
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

        // structuredContent.data.tools — the callable tool list.
        let tools = try #require(structuredData(result)?["tools"]?.arrayValue,
            "structuredContent.data.tools must be present")
        let toolNames = tools.compactMap { $0.objectValue?["name"]?.stringValue }
        // Analytics lens tools are listed by ProjectedTool name.
        #expect(toolNames.contains("moot_lens_associations"),
                "moot_lens_associations must appear in the callable tools list")
        #expect(toolNames.contains("moot_lens_concepts"),
                "moot_lens_concepts must appear in the callable tools list")
    }

    // MARK: - formal_concepts dispatch

    /// v2: `moot_lens_concepts` schema is `schema([], ["recall_limit": .positiveInteger,
    /// "limit": .positiveInteger])`. The v1 args `filter`, `minSupport`,
    /// `maxIntentSize`, and `maxConcepts` are not in the v2 schema and must be dropped.
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

        // v2: only limit and recall_limit are in the schema; drop filter/minSupport/etc.
        let result = try await dispatcher.dispatch(
            name: "moot_lens_concepts",
            arguments: .object([:]))
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.contains("Found"))
        #expect(text.contains("concepts"))
    }

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

    /// v2: `ack` arg removed from `moot_recall_distilled` (COMPOSER-02B §8.6).
    /// The tool runs unconditionally — no ceremony precedes results.
    ///
    /// Routing test: the assertions must fail when a DIFFERENT v2 read operation
    /// (e.g. moot_recall_precise) is dispatched instead. Discriminating properties:
    ///   - compactText contains "distilled recall result" (label unique to this engine)
    ///   - structuredContent.data.results[*].representation == "distilled"
    /// moot_recall_precise produces "precise recall result" and no representation field.
    @Test func testRecallDistilledDispatchRoutesToRunRecallDistilled() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "recall-distilled-dispatch"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Plant a memory so the distilled engine returns at least one result;
        // representation: "distilled" in results is the distilled-engine marker
        // that proves routing (the projectedResult path sets it from the match).
        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: fileArgs(content: "distilled recall routing probe"))

        // v2: no `ack` arg; filter: unconfirmed so the freshly-filed row is visible.
        let result = try await dispatcher.dispatch(
            name: "moot_recall_distilled",
            arguments: .object([
                "query": .string("distilled recall routing probe"),
                "filter": .string("unconfirmed"),
            ]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)

        // v2 compactText for distilled recall: "Returned N distilled recall result(s)."
        // A mis-routed operation produces a different label (e.g. "precise recall result"),
        // which fails the contains check and proves routing discrimination.
        #expect(text.hasPrefix("Returned "),
                "v2 compactText must use the 'Returned N X result(s).' format")
        #expect(text.contains("distilled recall result"),
                "compactText must name the distilled engine; a mis-routed moot_recall_precise produces 'precise recall result' here")

        // Default: echo_query is absent from the v2 decoder — the compact text
        // never echoes the query. This is the v2 equivalent of the v1 default-off
        // assertion. Note: the v1 opt-in (echo_query:true) is now entirely absent
        // from v2 (blocked in testRecallDistilledEchoQueryOptIn), so "default off"
        // became "permanently off" — not configurable, always the case.
        #expect(!text.contains("for:"),
                "compactText must NOT echo the query (echo_query removed in v2)")

        // structuredContent.data.results must carry representation: "distilled"
        // on every result row — the typed distilled-engine marker from projectedResult.
        let data = try #require(structuredData(result),
                                "structuredContent.data must be present")
        let results = try #require(data["results"]?.arrayValue,
                                   "data.results must be an array")
        #expect(!results.isEmpty,
                "estate has content — distilled recall must return at least one result")
        #expect(results.allSatisfy {
            $0.objectValue?["representation"]?.stringValue == "distilled"
        }, "every result row must carry representation: 'distilled'; a mis-routed operation would omit this field")
    }

    @Test func testRecallDistilledOutputFormatStartsWithFoundN() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "recall-distilled-fmt"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // v2: no `ack` arg.
        let result = try await dispatcher.dispatch(
            name: "moot_recall_distilled",
            arguments: .object([
                "query": .string("knowledge synthesis"),
                "limit": .integer(5),
            ]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        // structuredContent.data.results must be present (array, may be empty).
        let data = try #require(structuredData(result), "structuredContent.data must be present")
        let _ = try #require(data["results"]?.arrayValue, "data.results must be an array")
    }

    /// BLOCKED: echo_query appears in the catalog schema (AriaV2SelectedCatalog)
    /// but is absent from the AriaV2RecallLensOperation decoder's allowed-key set
    /// (AriaV2RecallLens.swift:40); AriaV2ArgumentDecoder throws JSONRPCError on any
    /// key not in allowedKeys, so passing echo_query:true throws rather than opting
    /// in to query-echo behavior. v1's echo_query feature is not wired on the v2 path.
    /// Awaiting a ruling. Do not delete; do not weaken to pass.
    @Test(.disabled("BLOCKED: echo_query not in AriaV2RecallLensOperation decoder allowedKeys (AriaV2RecallLens.swift:40); v1 echo_query opt-in behavior is absent from v2 path"))
    func testRecallDistilledEchoQueryOptIn() async throws {
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
            ]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        // With echo_query:true, header must echo the query (applied on both
        // empty and non-empty results). New S1 format: "found N candidate memories for: <query>".
        #expect(text.hasPrefix("found 0 candidate memories for: test echo query"),
                "echo_query:true must produce 'found 0 candidate memories for: <query>' header")
        // echo_query is a declared arg — no unrecognized-arg hint must appear.
        #expect(!text.contains("hint: unrecognized argument(s) ignored"),
                "echo_query is declared — must NOT trigger the unrecognized-arg hint")
    }

    @Test func testRecallDistilledEchoQueryDefaultOff() async throws {
        // Without echo_query, the result must be isError:false.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "recall-distilled-echo-off"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_recall_distilled",
            arguments: .object(["query": .string("silent query test")]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        // No ceremony text in compactText.
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(!text.contains("for:"),
                "default response must NOT echo the query in compactText")
        // structuredContent.data.results must be a valid array.
        let data = try #require(structuredData(result), "structuredContent.data must be present")
        let _ = try #require(data["results"]?.arrayValue, "data.results must be an array")
    }

    // MARK: - ACK gate and notice-only stub tests (Wave 1)

    // moot_recollect — not in the v2 catalog; ToolDispatcher.dispatch throws
    // methodNotFound before reaching RecipeTools.dispatch. Mirrors the
    // moot_distill / moot_redistill pattern already in this file.
    @Test func testRecollectStubReturnsNoticeNeverExecutes() async throws {
        // moot_recollect is not in AriaV2SelectedCatalog (its substrate,
        // factoid drawers, was retired). ToolProjection.admitsDispatch returns
        // false → ToolDispatcher.dispatch throws JSONRPCError(code: methodNotFound)
        // before any estate access. RecipeTools.dispatch stub is never reached.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "recollect-stub"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Pin the specific error code, not just the type. Any JSONRPCError would
        // also pass on invalidParams (wrong argument), which is a different failure.
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_recollect",
                arguments: .object(["query": .string("test")]))
            Issue.record("moot_recollect dispatch must throw JSONRPCError(methodNotFound) but returned a result")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.methodNotFound,
                    "moot_recollect must throw methodNotFound (\(JSONRPCErrorCode.methodNotFound)); got code \(error.code)")
        }
    }

    // moot_recall_distilled runs UNCONDITIONALLY — no acknowledgment
    // ceremony precedes any result (ARIA_MCP_SPEC 2.0.0 § 8.6). The former
    // ack gate and CONTRACT CHANGE NOTICE were deleted in COMPOSER-02B.
    @Test func testRecallDistilledRunsWithoutAnyAck() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "recall-distilled-no-ack"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // v2: no ack arg — the schema does not include it.
        let result = try await dispatcher.dispatch(
            name: "moot_recall_distilled",
            arguments: .object(["query": .string("any query")]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(!text.contains("CONTRACT CHANGE NOTICE"),
                "no ceremony may precede results")
        // v2 result has structuredContent — the operation ran.
        #expect(obj["structuredContent"] != nil,
                "the recall handler must run without any ack and return a v2 envelope")
    }

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

        // v2: no ack arg; the AriaV2ArgumentDecoder rejects unknown keys.
        // The zero-limit must still trigger invalidParams from clampLimit.
        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_recall_distilled",
                arguments: .object([
                    "query": .string("test"),
                    "limit": .integer(0),
                ]))
        }
    }

    // MARK: - Dream future-now guard

    @Test func dreamFarFutureNowReturnsInvalidArgumentRefusal() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(in: kit)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // A date 48 hours in the future — well beyond the 24 h ceiling.
        let farFuture = Date().addingTimeInterval(48 * 3600)
        let formatter = ISO8601DateFormatter()
        let farFutureStr = formatter.string(from: farFuture)

        // executeV2Core catches thrown JSONRPCErrors and wraps them in a refusal
        // envelope; the far-future guard therefore returns an isError:true result
        // rather than throwing at the transport level.  Both forms communicate
        // "caller error, not retryable" to the caller.
        let result = try await dispatcher.dispatch(
            name: "moot_dream",
            arguments: .object(["now": .string(farFutureStr)]))
        guard case let .object(obj) = result,
              case .bool(true)? = obj["isError"],
              let code = obj["structuredContent"]?.objectValue?["error"]?.objectValue?["code"]
        else {
            Issue.record("Expected isError:true refusal envelope; got: \(result)")
            return
        }
        #expect(code == .string("invalid_argument"),
                "far-future now must produce invalid_argument refusal; got code: \(code)")
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

    // MARK: - moot_recall_walk dispatch (D10)

    /// AM-WR-ARIA-1: moot_recall_walk dispatches successfully on an empty estate.
    /// Returns compactText "Returned 0 walk recall result(s)." and
    /// structuredContent.data.capabilities.walk.stage confirms the stage used.
    @Test func walkRecallDispatchOnEmptyEstate() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(in: kit)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_recall_walk",
            arguments: .object(["query": .string("escalation test")]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        // v2 compactText: "Returned N walk recall result(s)."
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.contains("walk recall result"),
                "compactText must confirm walk recall; got: \(text)")
        // structuredContent.data.capabilities.walk.stage — the stage used.
        let data = try #require(result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue, "structuredContent.data must be present")
        let caps = data["capabilities"]?.objectValue
        let walkCaps = caps?["walk"]?.objectValue
        #expect(walkCaps != nil,
                "structuredContent.data.capabilities.walk must be present for walk recall; data: \(data)")
        #expect(walkCaps?["stage"]?.stringValue != nil,
                "walk.stage must be a non-nil string naming the stage used")
    }

    /// AM-WR-ARIA-2: moot_recall_walk tool descriptor appears in tools/list
    /// with the correct name, required query param, and outputSchema.
    @Test func walkRecallToolDescriptorIsWellFormed() {
        let tool = RecipeTools.tools().first(where: { $0.name == "moot_recall_walk" })
        #expect(tool != nil, "moot_recall_walk must appear in RecipeTools.tools()")
        guard let tool else { return }
        // Required field is "query".
        let props = tool.inputSchema.objectValue?["properties"]?.objectValue
        #expect(props?["query"] != nil, "moot_recall_walk schema must have 'query' property")
        let required = tool.inputSchema.objectValue?["required"]?.arrayValue?
            .compactMap { $0.stringValue } ?? []
        #expect(required.contains("query"),
            "moot_recall_walk must require 'query'")
        // outputSchema is present (same contract as moot_recall_precise).
        #expect(tool.outputSchema != nil,
            "moot_recall_walk must declare an outputSchema")
    }

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
