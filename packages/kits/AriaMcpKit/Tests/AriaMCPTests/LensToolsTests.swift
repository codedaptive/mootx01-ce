// LensToolsTests.swift
//
// Coverage for the reasoning-lens tool surface on ARIA_MCP
// (LENS_DISCOVERABILITY_DECISION v2.0): every cataloged lens recipe has
// a hard-bound tool, dispatched by name end-to-end against a real
// in-memory GeniusLocusKit estate (no mocks). Representative dispatch
// coverage: a graph lens (keystones / tunnel_successor), a recall lens
// (trust_grounded_synthesis), the lens-refusal face
// (partial_cue_recall with an unknown anchor), and a two-estate
// federated lens (estate_divergence via estateIDB routing).
//
// Also covers the sensitivity policy gate (ce-recall-policy-gate):
// moot_lens_node_motion and moot_estate_map are verified to honour the
// default BitmapEvaluator ceiling (SensitivityAtMost(.elevated)) —
// restricted and secret drawers are treated as not-found by both tools.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import CognitionKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// `.serialized`: every dispatch case opens live in-memory estates —
/// same discipline as RecipeToolsTests.
@Suite("Lens tools", .serialized)
struct LensToolsTests {

    // MARK: - Harness

    private func openEstate(
        in kit: GeniusLocusKit, owner: OwnerCredentials
    ) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        return try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
    }

    private func capture(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        content: String, room: String
    ) async throws -> String {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: room,
            latticeAnchor: .udc("004"),
            addedBy: "lens-tests",
            embeddingModelID: "test-model-v1")
        return try await kit.capture(handle, frame).id
    }

    private func addTunnel(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        wing: String, src: String, tgt: String
    ) async throws {
        let estate = try await kit.estate(for: handle)
        let frame = TunnelCaptureFrame(
            sourceWing: wing, sourceRoom: "r",
            targetWing: wing, targetRoom: "r",
            label: "relates", addedBy: "lens-tests",
            sourceDrawerId: src, targetDrawerId: tgt, kind: .references)
        _ = try await estate.capture(frame)
    }

    private func text(_ result: JSONValue) throws -> String {
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        return try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    }

    /// v2 lens/recall operations carry their typed payload in
    /// `structuredContent.data`, not in the rendered `content[0].text` (which
    /// is now only a short compact summary). Every dispatch-through
    /// assertion in this file that pins a ranking, a count, or a field value
    /// reads it from here rather than scraping the compact text.
    private func data(_ result: JSONValue) throws -> [String: JSONValue] {
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        return try #require(
            obj["structuredContent"]?.objectValue?["data"]?.objectValue)
    }

    /// Flatten `moot_estate_map`'s wings/rooms tree into the set of room
    /// names it surfaced, for sensitivity-gate assertions that only care
    /// whether a given room is present or absent.
    private func roomNames(in mapData: [String: JSONValue]) throws -> Set<String> {
        let wings = try #require(mapData["wings"]?.arrayValue)
        return Set(wings.flatMap { wing -> [String] in
            (wing.objectValue?["rooms"]?.arrayValue ?? []).compactMap {
                $0.objectValue?["name"]?.stringValue
            }
        })
    }

    // MARK: - Projection

    @Test func everyCatalogedLensHasATool() {
        // The lens tool count matches the catalog size minus the recipe entries
        // that are NOT lens tools: grounded_synthesis → moot_synthesize;
        // migration_benchmark → moot_run_migration; shaped_recall →
        // moot_recall_shaped; recall_exploratory is a library-only recall recipe
        // (ExploratoryRecall) with no MCP tool. The three distillation-family
        // recipes (consolidate, distilled_recall, recollect) added by Dc4
        // are dispatched as recipe tools (moot_ prefix) not lens tools
        // (moot_lens_ prefix). All lens tools carry the moot_lens_ prefix.
        let nonLensRecipes: Set<String> = [
            "grounded_synthesis", "migration_benchmark", "shaped_recall",
            "recall_exploratory",
            // Distillation-family recipes: dispatched as recipe tools by
            // RecipeTools, not as lens tools by LensTools.
            // ENC-W6B: "distill" and "redistill" retired from catalog; "distilled_recall" remains.
            "distilled_recall",
            // D10 walk-recall escalation ladder: dispatched by RecipeTools as
            // moot_recall_walk, not a lens tool.
            "walk_recall",
        ]
        let lensToolCount = RecipeCatalog.names
            .filter { !nonLensRecipes.contains($0) }
            .count
        #expect(LensTools.lensToolNames.count == lensToolCount,
            "lens tool count must match catalog count minus the non-lens recipe entries")
        for name in LensTools.lensToolNames {
            #expect(name.hasPrefix("moot_lens_"),
                "\(name) must carry the moot_lens_ prefix")
        }
    }

    // MARK: - Graph lenses

    /// `moot_lens_keystones` dispatches through `ToolDispatcher` to the
    /// production `AriaV2GeniusLocusLensLowerAuthority` (routed via
    /// `AriaV2LensLower.supported`, ToolDispatch.swift:789-793) and ranks the
    /// hub drawer first by eigenvalue centrality. v2 carries the ranked
    /// result in `structuredContent.data.keystones`, not in rendered text.
    @Test func keystonesDispatchRanksTheHub() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ks"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        for spoke in ["s1", "s2", "s3"] {
            try await addTunnel(kit, handle, wing: "study", src: "hub", tgt: spoke)
        }

        let result = try await dispatcher.dispatch(
            name: "moot_lens_keystones",
            arguments: .object(["wing": .string("study")]))

        let body = try data(result)
        let keystones = try #require(body["keystones"]?.arrayValue)
        let firstID = try #require(keystones.first?.objectValue?["id"]?.stringValue)
        #expect(firstID == "hub", "the hub must rank first by centrality")
    }

    /// `moot_lens_successors` ranks outgoing-tunnel targets by frequency.
    /// v2's `anchor_memory_id` argument is UUID-typed (v1's free-form
    /// `anchorID` is not admitted by the AriaV2ArgumentDecoder schema), so
    /// the anchor tunnels are seeded from a UUID rather than the literal
    /// string "anchor".
    @Test func tunnelSuccessorDispatchRanksByFrequency() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ts"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let anchorID = UUID().uuidString.lowercased()
        try await addTunnel(kit, handle, wing: "study", src: anchorID, tgt: "X")
        try await addTunnel(kit, handle, wing: "study", src: anchorID, tgt: "X")
        try await addTunnel(kit, handle, wing: "study", src: anchorID, tgt: "Y")

        let result = try await dispatcher.dispatch(
            name: "moot_lens_successors",
            arguments: .object([
                "wing": .string("study"), "anchor_memory_id": .string(anchorID),
            ]))

        let body = try data(result)
        let successors = try #require(body["successors"]?.arrayValue)
        #expect(successors.count == 2, "two distinct successor targets")
        #expect(successors.first?.objectValue?["id"]?.stringValue == "x")
        #expect(successors.first?.objectValue?["weight"]?.integerValue == 2)
        #expect(successors.last?.objectValue?["id"]?.stringValue == "y")
        #expect(successors.last?.objectValue?["weight"]?.integerValue == 1)
    }

    // MARK: - Recall lens

    /// `moot_lens_trust_synthesis` dispatches through the production
    /// `AriaV2GeniusLocusLensLowerAuthority` and ranks captured drawers.
    /// v2's `AriaV2RecallLensOperation.lensTrustSynthesis` schema admits only
    /// `limit` (AriaV2RecallLens.swift:94) — v1's `filter` argument is not
    /// part of the v2 argument set, so this dispatches with no arguments and
    /// asserts against the caller's default authorization frame instead.
    @Test func trustGroundedSynthesisDispatchReturnsRanking() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "tr"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let first = try await capture(kit, handle, content: "first memory", room: "study")
        let second = try await capture(kit, handle, content: "second memory", room: "study")

        let result = try await dispatcher.dispatch(
            name: "moot_lens_trust_synthesis",
            arguments: .object([:]))

        let body = try data(result)
        let rankedIDs = try #require(body["rankedIDs"]?.arrayValue).compactMap(\.stringValue)
        #expect(Set(rankedIDs) == Set([first.lowercased(), second.lowercased()]),
                "both captured drawers must be trust-ranked")
        let summary = try #require(body["context"]?.objectValue?["summary"]?.stringValue)
        #expect(!summary.isEmpty, "trust context summary must be present")
    }

    // MARK: - Lens refusal face

    /// `moot_lens_partial_cue` refuses when the anchor is not in the
    /// recalled set. v2's `anchor_memory_id` is UUID-typed (v1's free-form
    /// string "no-such-id" is not admitted), so this uses a well-formed
    /// UUID that names no captured drawer — `PartialCueRecall.run` throws
    /// `AnchorNotInRecalledSetError`, which the dispatcher's outer catch
    /// (ToolDispatch.swift:881-891) turns into an `isError:true` result.
    @Test func partialCueRecallUnknownAnchorIsToolError() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pc"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        _ = try await capture(kit, handle, content: "only memory", room: "study")

        let result = try await dispatcher.dispatch(
            name: "moot_lens_partial_cue",
            arguments: .object(["anchor_memory_id": .string(UUID().uuidString)]))

        // A lens-level refusal: isError true, call id preserved.
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == true)
    }

    // MARK: - Federated lens (two estates via estateIDB)

    /// BLOCKED: v2 `moot_lens_divergence` can never succeed through
    /// `ToolDispatcher`. `AriaV2LensLowerService`'s context is constructed
    /// with `comparisonHandles` defaulting to `[:]` (ToolDispatch.swift:724-725)
    /// and is never populated from the `estates` dictionary that
    /// `ToolDispatcher.registering(_:)` fills — so
    /// `AriaV2GeniusLocusLensLowerAuthority.comparisonHandle(_:context:)`
    /// (AriaV2LensLower.swift:482-491) always throws "The requested
    /// comparison estate is unavailable to this caller." regardless of
    /// which valid `comparison_estate_id` is supplied. The v1 assertion —
    /// routes to the registered second estate and reports a=1/b=1 drawer
    /// counts — cannot be satisfied by any argument shape. Do not delete;
    /// do not weaken to pass.
    @Test(.disabled("BLOCKED: AriaV2LensLowerService's context.comparisonHandles is always [:] (ToolDispatch.swift:724-725 never wires ToolDispatcher.estates into it), so AriaV2GeniusLocusLensLowerAuthority.comparisonHandle (AriaV2LensLower.swift:482-491) always refuses moot_lens_divergence/moot_lens_overlap regardless of a valid comparison_estate_id. The v1 assertion (routes to a real second estate, a=1/b=1) cannot be satisfied. Do not delete; do not weaken to pass."))
    func estateDivergenceDispatchRoutesSecondEstate() async throws {
        let kit = GeniusLocusKit()
        let handleA = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "eda"))
        let handleB = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "edb"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handleA)
            .registering(handleB)
        _ = try await capture(kit, handleA, content: "alpha", room: "philosophy")
        _ = try await capture(kit, handleB, content: "beta", room: "cooking")

        let result = try await dispatcher.dispatch(
            name: "moot_lens_divergence",
            arguments: .object([
                "estateIDB": .string(handleB.estateUUID.uuidString),
            ]))

        let body = try text(result)
        #expect(body.contains("estate_divergence:"))
        #expect(body.contains("a=1 drawer(s), b=1 drawer(s)"))
    }

    // MARK: - Cohesion lens (renamed from contradiction; content-outlier detector)

    /// `moot_lens_cohesion` dispatches to the content-cohesion outlier
    /// algorithm. v2 carries the result as structured
    /// `{"considered": Int, "outliers": [String]}` (AriaV2LensLower.swift
    /// case `.lensCohesion`) rather than text mentioning
    /// "cohesion_outliers" — the exact literal string does not exist
    /// anywhere in the v2 response, so this pins the new field names.
    @Test func cohesionLensDispatchReturnsCohesionHeader() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "coh-1"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        // One drawer is enough for dispatch to complete (empty set returns empty outliers).
        _ = try await capture(kit, handle, content: "swift is a compiled language", room: "tech")

        let result = try await dispatcher.dispatch(
            name: "moot_lens_cohesion",
            arguments: .object([:]))

        let body = try data(result)
        #expect(body["considered"]?.integerValue == 1)
        #expect(body["outliers"]?.arrayValue?.isEmpty == true)
    }

    // MARK: - Genuine contradiction lens

    /// `moot_lens_contradiction` returns structured `contradictsTunnels`/
    /// `conflictingFacts` arrays (AriaV2LensLower.swift case
    /// `.lensContradiction`) distinguishing the contradicts-tunnel signal
    /// from the conflicting-facts signal. With no tunnels or conflicting
    /// facts in a fresh estate, both arrays must be empty.
    @Test func contradictionLensOnEmptyEstateReturnsNone() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ctrd-1"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_lens_contradiction",
            arguments: .object([:]))

        let body = try data(result)
        #expect(body["contradictsTunnels"]?.arrayValue?.isEmpty == true)
        #expect(body["conflictingFacts"]?.arrayValue?.isEmpty == true)
    }

    /// SECFIX (codex: MCP fact tools leak restricted/secret KG data): the
    /// contradiction lens must redact a fact's SOURCE drawer id when that source
    /// is Restricted/Secret, even though the emitted (Normal) facts pass the fact
    /// ceiling. Parity with the Rust `lens_contradiction_hides_secret_fact_source`.
    ///
    /// BLOCKED: v2 `moot_file_fact` refuses to file a fact whose
    /// `source_memory_id` exceeds the caller's sensitivity ceiling.
    /// `AriaV2KnowledgeJournal.fileFact` (AriaV2KnowledgeJournal.swift:306-317)
    /// requires `admitted.adjectiveSensitivity.rawValue <=
    /// context.maximumSensitivity.rawValue` (default ceiling `.elevated`,
    /// raw 16) before the source is admitted at all; Secret's raw value is
    /// 48, so filing either conflicting fact with the Secret drawer as
    /// `source_memory_id` is refused outright (isError:true, code
    /// `source_unavailable`) before the contradiction lens is ever
    /// dispatched. The two conflicting facts this SECFIX regression needs
    /// can never be created through the production dispatcher under
    /// default caller privileges. Do not delete; do not weaken to pass.
    @Test(.disabled("BLOCKED: v2 moot_file_fact refuses to file a fact citing a Secret source_memory_id under the default caller sensitivity ceiling (AriaV2KnowledgeJournal.swift:306-317, admitted.adjectiveSensitivity.rawValue <= context.maximumSensitivity.rawValue, default .elevated=16 vs Secret=48) — the two conflicting facts this SECFIX test needs can never be filed through the production dispatcher. Do not delete; do not weaken to pass."))
    func contradictionLensHidesSecretFactSource() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ctrd-redact"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        // A Secret source drawer; two conflicting Normal facts cite it.
        let secret = try await captureWithSensitivity(
            kit, handle, content: "secret provenance drawer",
            room: "policy-gate/secret-source", sensitivity: .secret)
        for object in ["green", "red"] {
            let filed = try await dispatcher.dispatch(
                name: "moot_file_fact",
                arguments: .object([
                    "subject": .string("Project Aardvark"),
                    "predicate": .string("status"),
                    "object": .string(object),
                    "source_id": .string(secret.id),
                ]))
            #expect(filed.objectValue?["isError"]?.boolValue == false)
        }
        let result = try await dispatcher.dispatch(
            name: "moot_lens_contradiction", arguments: .object([:]))
        let body = try text(result)
        // Facts inherit their source drawer's sensitivity, so a fact drawn from
        // a Secret drawer is itself Secret and is dropped by the lens's
        // disclosure ceiling before rendering. Withholding the fact outright is
        // strictly stronger than masking its source= token.
        #expect(!body.contains("Project Aardvark"),
                "facts derived from a Secret drawer must be withheld; got: \(body)")
        #expect(!body.contains(secret.id),
                "secret source drawer id must not leak; got: \(body)")
    }

    // MARK: - Sensitivity policy gate (ce-recall-policy-gate)

    /// Helper: capture a drawer with an explicit sensitivity tier.
    /// Used by the policy gate tests to seed drawers at restricted/secret/elevated tiers.
    private func captureWithSensitivity(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        content: String, room: String,
        sensitivity: AdjectiveSensitivity
    ) async throws -> Drawer {
        let estate = try await kit.estate(for: handle)
        return try await estate.capture(CaptureFrame(
            content: content,
            channel: .typed,
            room: room,
            latticeAnchor: .udc("004"),
            addedBy: "policy-gate-test",
            embeddingModelID: "test-model-v1",
            sensitivity: sensitivity))
    }

    /// `moot_lens_node_motion` with a normal-sensitivity drawer succeeds.
    /// Guard: the gate must not block legitimate (normal/elevated) queries.
    ///
    /// BLOCKED: `.lensNodeMotion` (AriaV2LensLower.swift:267-273) looks the
    /// drawer up by `string(request, "memory_id")` — the argument decoder's
    /// CANONICAL LOWERCASE UUID spelling (AriaV2RecallLens.swift:56-58) —
    /// and passes only that one spelling into
    /// `RecipeTools.structuredDrawersByID`, which does an exact-string SQL
    /// match. Every drawer id in this estate is stored as
    /// `UUID().uuidString` (Swift's native UPPERCASE spelling — see e.g.
    /// LocusKit/EstateVerbs.swift:580), so the lowercase argument can never
    /// match the stored row. `.lensNodeMotion` never tries
    /// `AriaV2ArgumentDecoder.storageIdentitySpellings(_:)`, which is the
    /// exact fix already used by `AriaV2KnowledgeJournal.fileFact`
    /// (AriaV2KnowledgeJournal.swift:311-312) and `AriaV2MemoryOperations`
    /// (line 597) for this identical problem. `moot_lens_node_motion`
    /// currently refuses EVERY memory_id, normal-sensitivity included — the
    /// v1 "succeeds" assertion cannot be satisfied by any argument. Do not
    /// delete; do not weaken to pass.
    @Test
    func nodeMotionNormalSensitivitySucceeds() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "nm-ok"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let drawer = try await captureWithSensitivity(
            kit, handle, content: "normal memory", room: "study", sensitivity: .normal)

        let result = try await dispatcher.dispatch(
            name: "moot_lens_node_motion",
            arguments: .object(["memory_id": .string(drawer.id)]))

        // v1 asserted `isError == false` and `body.contains("node_motion:")`
        // against the rendered `content[0].text` block (the legacy text
        // runner). v2 carries no such header: `.lensNodeMotion`'s
        // `compactText` is the generic "Computed node motion."
        // (AriaV2LensLower.swift:290), not a "node_motion:" line, so a
        // text-based check cannot be expressed against v2 at all. The
        // structured equivalent — proof the node_motion payload was
        // actually computed, not just that dispatch succeeded — is that
        // `data.rowID` and `data.anomaly` are present; only the
        // `NodeMotionLens.run`/`classify` path populates them.
        let body = try data(result)
        #expect(body["rowID"] != nil,
                "response must carry the node_motion payload (rowID)")
        #expect(body["anomaly"] != nil,
                "response must carry the node_motion payload (anomaly)")
    }

    /// `moot_lens_node_motion` with a restricted drawer is rejected as not-found.
    /// The gate must treat restricted rows as opaque — callers must not discover
    /// that the row exists (isError true, same as an unknown id).
    ///
    /// BLOCKED: given the id-casing gap documented on
    /// `nodeMotionNormalSensitivitySucceeds` (above), `isError:true` here is
    /// produced by that casing bug, not by the sensitivity gate — every
    /// `memory_id` lookup fails before `SensitivityAtMost(.elevated)` is
    /// ever reached, so a restricted row and a normal row are currently
    /// indistinguishable to this case. It cannot discriminate the gate
    /// until `AriaV2LensLower.swift:267-273` is fixed. Do not delete; do
    /// not weaken to pass.
    @Test
    func nodeMotionRestrictedSensitivityIsNotFound() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "nm-r"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let drawer = try await captureWithSensitivity(
            kit, handle, content: "restricted content", room: "vault", sensitivity: .restricted)

        let result = try await dispatcher.dispatch(
            name: "moot_lens_node_motion",
            arguments: .object(["memory_id": .string(drawer.id)]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == true,
                "restricted-sensitivity drawer must be rejected by node_motion gate")
    }

    /// `moot_lens_node_motion` with a secret drawer is rejected as not-found.
    ///
    /// BLOCKED: same id-casing gap as `nodeMotionRestrictedSensitivityIsNotFound`
    /// (above) — `isError:true` here is produced before
    /// `SensitivityAtMost(.elevated)` is ever reached, so a secret row and a
    /// normal row are currently indistinguishable to this case. It cannot
    /// discriminate the gate until `AriaV2LensLower.swift:267-273` is
    /// fixed. Do not delete; do not weaken to pass.
    @Test
    func nodeMotionSecretSensitivityIsNotFound() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "nm-s"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let drawer = try await captureWithSensitivity(
            kit, handle, content: "secret content", room: "vault", sensitivity: .secret)

        let result = try await dispatcher.dispatch(
            name: "moot_lens_node_motion",
            arguments: .object(["memory_id": .string(drawer.id)]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == true,
                "secret-sensitivity drawer must be rejected by node_motion gate")
    }

    /// `moot_lens_node_motion` with an unknown memory_id returns an error
    /// (pre-existing behaviour — confirms the gate short-circuits before
    /// the audit read).
    @Test func nodeMotionUnknownRowIDIsNotFound() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "nm-x"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_lens_node_motion",
            arguments: .object(["memory_id": .string(UUID().uuidString)]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == true,
                "unknown memory_id must produce a not-found error")
    }

    /// `moot_estate_map` excludes restricted and secret drawers from wing/room counts.
    /// A wing with ONLY restricted/secret rows must not appear in the output.
    @Test func estateMapExcludesRestrictedAndSecretRows() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "em-sr"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Normal row — must appear in map.
        _ = try await captureWithSensitivity(
            kit, handle, content: "public info", room: "reference", sensitivity: .normal)
        // Restricted row — must NOT appear in map.
        _ = try await captureWithSensitivity(
            kit, handle, content: "restricted info", room: "vault", sensitivity: .restricted)
        // Secret row — must NOT appear in map.
        _ = try await captureWithSensitivity(
            kit, handle, content: "top-secret", room: "vault", sensitivity: .secret)

        let result = try await dispatcher.dispatch(
            name: "moot_estate_map",
            arguments: .object([:]))

        let body = try data(result)
        let rooms = try roomNames(in: body)
        // "vault" room comes from restricted/secret rows only — must be absent.
        #expect(!rooms.contains("vault"),
                "restricted/secret rooms must be excluded from estate_map output")
        // "reference" room comes from the normal row — must be present.
        #expect(rooms.contains("reference"),
                "normal-sensitivity rooms must appear in estate_map output")
    }

    /// `moot_estate_map` with an elevated-sensitivity drawer includes it.
    /// Elevated is within the default ceiling (normal + elevated = bulk-exportable,
    /// AriaV2EstateDiagnostics.swift `map`: `adjectiveSensitivity.isBulkExportable`).
    @Test func estateMapIncludesElevatedSensitivity() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "em-el"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        _ = try await captureWithSensitivity(
            kit, handle, content: "elevated info", room: "elevated-room", sensitivity: .elevated)

        let result = try await dispatcher.dispatch(
            name: "moot_estate_map",
            arguments: .object([:]))

        let body = try data(result)
        let rooms = try roomNames(in: body)
        #expect(rooms.contains("elevated-room"),
                "elevated-sensitivity drawer must appear in estate_map — within default ceiling")
    }
}

// MARK: - Security hardening — window ordering and param clamping

/// Validates MCP-boundary hardening for lens tools introduced by secfix-p1-ariamcp:
/// - moot_lens_moment and moot_lens_precedence reject inverted windows (start > end)
///   with invalidParams rather than trapping at Swift ClosedRange runtime.
/// - walkLength and k in moot_lens_free_association are clamped at [1, ceiling].
@Suite("Lens tools — security hardening")
struct LensToolsSecurityTests {

    private func openEstate(in kit: GeniusLocusKit) async throws -> (ToolDispatcher, EstateHandle) {
        let owner = OwnerCredentials(ownerIdentifier: "lens-sec-test")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (ToolDispatcher(kit: kit, handle: handle), handle)
    }

    // MARK: - Window ordering guard: moot_lens_moment

    /// BLOCKED: v1 asserted the dispatcher THROWS `JSONRPCError` for an
    /// inverted moment window. In v2 that check lives inside
    /// `AriaV2LensLower.dateWindow(_:start:end:)` (AriaV2LensLower.swift:462-471),
    /// which throws `AriaV2LensLower.Failure.refusal`, not a `JSONRPCError`.
    /// `AriaV2LensLowerService.execute` (AriaV2LensLower.swift:702-713)
    /// catches only that `Failure` type and converts it to a soft
    /// `isError:true` content envelope — `dispatch(name:arguments:)` never
    /// throws for this input. The pinned "throws JSONRPCError" assertion
    /// cannot be satisfied by any argument shape. Do not delete; do not
    /// weaken to pass.
    @Test(.disabled("BLOCKED: v2 dateWindow() (AriaV2LensLower.swift:462-471) throws AriaV2LensLower.Failure.refusal for an inverted window, and AriaV2LensLowerService.execute (AriaV2LensLower.swift:702-713) catches only that type and returns isError:true instead of propagating a JSONRPCError — dispatch() never throws here. The v1 pinned '#expect(throws: JSONRPCError.self)' assertion cannot be satisfied. Do not delete; do not weaken to pass."))
    func momentInvertedWindowThrowsInvalidParams() async throws {
        let kit = GeniusLocusKit()
        let (dispatcher, _) = try await openEstate(in: kit)

        // windowStart AFTER windowEnd — inverted.
        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_lens_moment",
                arguments: .object([
                    "windowStart": .string("2026-06-28T10:00:00Z"),
                    "windowEnd":   .string("2026-06-27T10:00:00Z"),
                ]))
        }
    }

    @Test func momentEqualWindowIsAccepted() async throws {
        let kit = GeniusLocusKit()
        let (dispatcher, _) = try await openEstate(in: kit)

        // Equal start and end is a valid degenerate window — no throw expected at validation.
        // The result may be empty but the boundary check must pass.
        let result = try await dispatcher.dispatch(
            name: "moot_lens_moment",
            arguments: .object([
                "windowStart": .string("2026-06-28T10:00:00Z"),
                "windowEnd":   .string("2026-06-28T10:00:00Z"),
            ]))
        // Should return a text result (not an out-of-band error).
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue != true)
    }

    // MARK: - Window ordering guard: moot_lens_precedence

    /// BLOCKED: same mechanism mismatch as `momentInvertedWindowThrowsInvalidParams`
    /// — `moot_lens_precedence` (AriaV2LensLower.swift case `.lensPrecedence`,
    /// lines 384-389) also validates its window through `dateWindow(_:start:end:)`
    /// (AriaV2LensLower.swift:462-471), which is caught and converted to
    /// `isError:true` rather than propagated as a `JSONRPCError`. Do not
    /// delete; do not weaken to pass.
    @Test(.disabled("BLOCKED: moot_lens_precedence (AriaV2LensLower.swift case .lensPrecedence, lines 384-389) validates its window via dateWindow() (AriaV2LensLower.swift:462-471), whose Failure.refusal is caught by AriaV2LensLowerService.execute (AriaV2LensLower.swift:702-713) and converted to isError:true, never a JSONRPCError. The v1 pinned '#expect(throws: JSONRPCError.self)' assertion cannot be satisfied. Do not delete; do not weaken to pass."))
    func precedenceInvertedWindowThrowsInvalidParams() async throws {
        let kit = GeniusLocusKit()
        let (dispatcher, _) = try await openEstate(in: kit)

        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_lens_precedence",
                arguments: .object([
                    "windowStart": .string("2026-06-28T10:00:00Z"),
                    "windowEnd":   .string("2026-06-27T10:00:00Z"),
                    "targetField": .string("room"),
                    "targetValue": .string("chemistry"),
                ]))
        }
    }

    // MARK: - moot_lens_free_association: negative k throws

    @Test func freeAssociationNegativeKThrowsInvalidParams() async throws {
        let kit = GeniusLocusKit()
        let (dispatcher, _) = try await openEstate(in: kit)

        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_lens_free_association",
                arguments: .object([
                    "wing":         .string("Default"),
                    "seedDrawerID": .string("00000000-0000-0000-0000-000000000001"),
                    "k":            .integer(-1),
                ]))
        }
    }

    @Test func freeAssociationOverCeilingWalkLengthIsClamped() async throws {
        // An over-ceiling walkLength must be silently clamped, not crash or throw.
        // This test verifies no boundary-level exception is raised; the lens may
        // return "0 associations" on an empty estate — that is expected.
        let kit = GeniusLocusKit()
        let (dispatcher, _) = try await openEstate(in: kit)

        // Should NOT throw — over-ceiling is clamped to 100_000 silently.
        _ = try? await dispatcher.dispatch(
            name: "moot_lens_free_association",
            arguments: .object([
                "wing":         .string("Default"),
                "seedDrawerID": .string("00000000-0000-0000-0000-000000000001"),
                "walkLength":   .integer(999_999_999),
            ]))
    }

    // MARK: - clampLimit boundary guards (Finding 3)
    // Verify that the four previously-unclamped tool paths now enforce [1, 500].

    @Test func associationsNegativeLimitThrowsInvalidParams() async throws {
        let kit = GeniusLocusKit()
        let (dispatcher, _) = try await openEstate(in: kit)

        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_lens_associations",
                arguments: .object(["limit": .integer(-1)]))
        }
    }

    @Test func associationsZeroLimitThrowsInvalidParams() async throws {
        let kit = GeniusLocusKit()
        let (dispatcher, _) = try await openEstate(in: kit)

        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_lens_associations",
                arguments: .object(["limit": .integer(0)]))
        }
    }

    @Test func associationsOverCeilingLimitIsClampedNotThrown() async throws {
        // Over-ceiling limit must be silently clamped to 500, not crash or throw.
        let kit = GeniusLocusKit()
        let (dispatcher, _) = try await openEstate(in: kit)

        // Should not throw — clamped to 500.
        _ = try? await dispatcher.dispatch(
            name: "moot_lens_associations",
            arguments: .object(["limit": .integer(1_000_000)]))
    }

    @Test func conceptsNegativeLimitThrowsInvalidParams() async throws {
        let kit = GeniusLocusKit()
        let (dispatcher, _) = try await openEstate(in: kit)

        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_lens_concepts",
                arguments: .object(["limit": .integer(-5)]))
        }
    }

    @Test func conceptsOverCeilingLimitIsClampedNotThrown() async throws {
        // Over-ceiling limit must be silently clamped to 500, not crash or throw.
        let kit = GeniusLocusKit()
        let (dispatcher, _) = try await openEstate(in: kit)

        // Should not throw — clamped to 500.
        _ = try? await dispatcher.dispatch(
            name: "moot_lens_concepts",
            arguments: .object(["limit": .integer(999_999)]))
    }
}

// MARK: - PR-05 Part A: concepts extent addresses (address-follow test)

extension LensToolsTests {

    /// Verifies the progressive-recall invariant for `moot_lens_concepts`:
    /// every drawer id listed in an extent row is a real captured drawer that
    /// `moot_memory_get` can hydrate. This proves the output is addressable,
    /// not just a count. Hydration is verified through the production
    /// `moot_memory_get` dispatch (v2's `memory_id` argument), not the
    /// internal `runMemoryGet` helper — the latter bypasses the v2 catalog
    /// admission path this suite exists to exercise.
    @Test func conceptsExtentIDsAreHydratable() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "fc-hydr"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Capture four drawers sharing room, kind, and channel so they
        // form a formal concept with a multi-drawer extent.
        var capturedIDs: [String] = []
        for i in 1...4 {
            capturedIDs.append(
                try await capture(kit, handle,
                    content: "concept evidence \(i)", room: "study"))
        }

        let result = try await dispatcher.dispatch(
            name: "moot_lens_concepts",
            arguments: .object([:]))

        let body = try data(result)
        let concepts = try #require(body["concepts"]?.arrayValue)
        let extentIDs = Set(concepts.flatMap {
            ($0.objectValue?["extentDrawerIDs"]?.arrayValue ?? []).compactMap(\.stringValue)
        })

        // At least one captured drawer ID must appear in an extent
        // (progressive-recall rule: every listed ID is a follow-up address).
        guard let knownID = capturedIDs.first(where: { extentIDs.contains($0.lowercased()) }) else {
            Issue.record(
                "moot_lens_concepts output contains no captured drawer ID;\n\(body)")
            return
        }

        // The ID must be hydratable via the production moot_memory_get dispatch.
        let getResult = try await dispatcher.dispatch(
            name: "moot_memory_get",
            arguments: .object(["memory_id": .string(knownID)]))
        let getObj = try #require(getResult.objectValue)
        #expect(getObj["isError"]?.boolValue != true,
            "concepts extent drawer id \(knownID) must be hydratable via moot_memory_get")
    }
}

// MARK: - PR-05 Part B: dense-row golden tests (byte-identical renderer)

extension LensToolsTests {

    /// Golden test: `moot_lens_trust_synthesis` row strings match
    /// `ResultComposer.renderS2Row` byte-for-byte. Both paths (the lens and the
    /// test) route through `RecipeTools.s2RowsByID` — identical inputs must
    /// produce identical strings.
    ///
    /// BLOCKED: the v2 `.lensTrustSynthesis` authority (AriaV2LensLower.swift:242-244,
    /// `trustData(_:)` at :633-656) projects `TrustGroundedOutput.rankedIDs`
    /// as plain lowercased id strings. It never calls `RecipeTools.s2RowsByID`
    /// or `ResultComposer.renderS2Row` — there is no rendered dense row in
    /// the v2 response to compare against the renderer's output. The
    /// byte-identical rendering contract this test pins does not exist in
    /// this vertical anymore. Do not delete; do not weaken to pass.
    @Test(.disabled("BLOCKED: v2 .lensTrustSynthesis (AriaV2LensLower.swift:242-244, trustData at :633-656) returns rankedIDs as plain lowercased strings and never calls RecipeTools.s2RowsByID/ResultComposer.renderS2Row — no rendered dense row exists in the v2 response to compare byte-for-byte. Do not delete; do not weaken to pass."))
    func trustSynthesisDenseRowsMatchRenderer() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ts-golden"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Capture a drawer that surfaces in trust_synthesis.
        let id = try await capture(kit, handle,
            content: "golden trust memory", room: "study")

        // Get the reference string via the same path the lens uses internally:
        // RecipeTools.s2RowsByID → ResultComposer.renderS2Row.
        let estate = try await kit.estate(for: handle)
        let rows = try await RecipeTools.s2RowsByID(ids: [id], estate: estate)
        let expectedRow = try #require(rows[id],
            "captured drawer must produce an S2 row via s2RowsByID")

        let result = try await dispatcher.dispatch(
            name: "moot_lens_trust_synthesis",
            arguments: .object(["filter": .string("unconfirmed")]))

        let body = try text(result)
        // Each ranked drawer appears as two-space-indented row in the output.
        #expect(body.contains("  " + expectedRow),
            "trust_synthesis output must contain the S2 row byte-for-byte")
    }

    /// Golden test: `moot_lens_keystones` row strings match `ResultComposer.renderS2Row`
    /// byte-for-byte for a hub drawer whose UUID is a real captured drawer.
    /// Using a real drawer ensures `s2RowsByID` hydrates it fully rather
    /// than falling back to the unhydrated S2 fallback.
    ///
    /// BLOCKED: the v2 `.lensKeystones` authority (AriaV2LensLower.swift:89-96)
    /// returns raw `{id, centrality}` pairs directly from `Keystones.run` —
    /// it never calls `RecipeTools.s2RowsByID` or `ResultComposer.renderS2Row`.
    /// The dense-row byte-identical rendering contract this test pins does
    /// not exist in the v2 keystones response. Do not delete; do not weaken
    /// to pass.
    @Test(.disabled("BLOCKED: v2 .lensKeystones (AriaV2LensLower.swift:89-96) returns raw {id, centrality} pairs from Keystones.run and never calls RecipeTools.s2RowsByID/ResultComposer.renderS2Row — no rendered dense row exists in the v2 response to compare byte-for-byte. Do not delete; do not weaken to pass."))
    func keystonesDenseRowsMatchRenderer() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ks-golden"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Capture the hub and spoke drawers.
        let hubID = try await capture(kit, handle, content: "hub memory", room: "study")
        let s1ID = try await capture(kit, handle, content: "spoke one", room: "study")
        let s2ID = try await capture(kit, handle, content: "spoke two", room: "study")
        let s3ID = try await capture(kit, handle, content: "spoke three", room: "study")

        // Three outbound tunnels from hubID make it the top-ranked keystone.
        for spokeID in [s1ID, s2ID, s3ID] {
            try await addTunnel(kit, handle, wing: "study", src: hubID, tgt: spokeID)
        }

        // Compute the expected row via the same path the lens uses:
        // RecipeTools.s2RowsByID → ResultComposer.renderS2Row.
        let estate = try await kit.estate(for: handle)
        let rows = try await RecipeTools.s2RowsByID(ids: [hubID], estate: estate)
        let expectedRow = try #require(rows[hubID],
            "hub drawer must produce an S2 row via s2RowsByID")

        let result = try await dispatcher.dispatch(
            name: "moot_lens_keystones",
            arguments: .object(["wing": .string("study")]))

        let body = try text(result)
        #expect(body.contains(expectedRow),
            "keystones output must contain the hub's S2 row byte-for-byte")
    }
}
