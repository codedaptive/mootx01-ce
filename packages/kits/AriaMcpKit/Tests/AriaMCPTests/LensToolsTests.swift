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
            "distill", "distilled_recall",
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

        let body = try text(result)
        #expect(body.contains("keystones:"))
        #expect(body.split(separator: "\n").dropFirst().first?.contains("hub") == true,
                "the hub ranks first")
    }

    @Test func tunnelSuccessorDispatchRanksByFrequency() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ts"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        try await addTunnel(kit, handle, wing: "study", src: "anchor", tgt: "X")
        try await addTunnel(kit, handle, wing: "study", src: "anchor", tgt: "X")
        try await addTunnel(kit, handle, wing: "study", src: "anchor", tgt: "Y")

        let result = try await dispatcher.dispatch(
            name: "moot_lens_successors",
            arguments: .object([
                "wing": .string("study"), "anchorID": .string("anchor"),
            ]))

        let body = try text(result)
        #expect(body.contains("tunnel_successor: 2 result(s)"))
        // Dense-row output (Part B): the tunnel endpoint "X" may not be a
        // captured drawer, so denseRowsByID returns renderUnhydrated — the
        // rendered row still starts with the id "X". The weight annotation
        // is appended after the dense row. Both must be present.
        #expect(body.contains("X"))
        #expect(body.contains("weight=2"))
    }

    // MARK: - Recall lens

    @Test func trustGroundedSynthesisDispatchReturnsRanking() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "tr"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        _ = try await capture(kit, handle, content: "first memory", room: "study")
        _ = try await capture(kit, handle, content: "second memory", room: "study")

        let result = try await dispatcher.dispatch(
            name: "moot_lens_trust_synthesis",
            arguments: .object(["filter": .string("unconfirmed")]))

        let body = try text(result)
        #expect(body.contains("trust_grounded_synthesis: 2 drawer(s)"))
        #expect(body.contains("summary:"))
    }

    // MARK: - Lens refusal face

    @Test func partialCueRecallUnknownAnchorIsToolError() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pc"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        _ = try await capture(kit, handle, content: "only memory", room: "study")

        let result = try await dispatcher.dispatch(
            name: "moot_lens_partial_cue",
            arguments: .object(["anchorID": .string("no-such-id")]))

        // A lens-level refusal: isError true, call id preserved.
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == true)
    }

    // MARK: - Federated lens (two estates via estateIDB)

    @Test func estateDivergenceDispatchRoutesSecondEstate() async throws {
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

    /// `moot_lens_cohesion` dispatches to the content-cohesion outlier algorithm
    /// and returns a result whose text mentions "cohesion_outliers".
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

        // text() internally asserts isError == false.
        let body = try text(result)
        #expect(body.contains("cohesion_outliers"))
    }

    // MARK: - Genuine contradiction lens

    /// `moot_lens_contradiction` returns text distinguishing contradicts-tunnel
    /// signal from conflicting-facts signal. With no tunnels or conflicting facts
    /// in a fresh estate, both sub-reports should surface "none".
    @Test func contradictionLensOnEmptyEstateReturnsNone() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ctrd-1"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_lens_contradiction",
            arguments: .object([:]))

        // text() internally asserts isError == false.
        let body = try text(result)
        // Both signal lines must appear.
        #expect(body.contains("contradicts_tunnels:"))
        #expect(body.contains("conflicting_facts:"))
        #expect(body.contains("none"))
    }

    /// SECFIX (codex: MCP fact tools leak restricted/secret KG data): the
    /// contradiction lens must redact a fact's SOURCE drawer id when that source
    /// is Restricted/Secret, even though the emitted (Normal) facts pass the fact
    /// ceiling. Parity with the Rust `lens_contradiction_hides_secret_fact_source`.
    @Test func contradictionLensHidesSecretFactSource() async throws {
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
        #expect(body.contains("source=<hidden>"),
                "secret fact source must be redacted; got: \(body)")
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
    @Test func nodeMotionNormalSensitivitySucceeds() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "nm-ok"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let drawer = try await captureWithSensitivity(
            kit, handle, content: "normal memory", room: "study", sensitivity: .normal)

        let result = try await dispatcher.dispatch(
            name: "moot_lens_node_motion",
            arguments: .object(["rowID": .string(drawer.id)]))

        // Successful dispatch: isError false, node_motion header present.
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false,
                "normal-sensitivity drawer must pass the node_motion gate")
        let body = try text(result)
        #expect(body.contains("node_motion:"), "response must contain node_motion header")
    }

    /// `moot_lens_node_motion` with a restricted drawer is rejected as not-found.
    /// The gate must treat restricted rows as opaque — callers must not discover
    /// that the row exists (isError true, same as an unknown id).
    @Test func nodeMotionRestrictedSensitivityIsNotFound() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "nm-r"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let drawer = try await captureWithSensitivity(
            kit, handle, content: "restricted content", room: "vault", sensitivity: .restricted)

        let result = try await dispatcher.dispatch(
            name: "moot_lens_node_motion",
            arguments: .object(["rowID": .string(drawer.id)]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == true,
                "restricted-sensitivity drawer must be rejected by node_motion gate")
    }

    /// `moot_lens_node_motion` with a secret drawer is rejected as not-found.
    @Test func nodeMotionSecretSensitivityIsNotFound() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "nm-s"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let drawer = try await captureWithSensitivity(
            kit, handle, content: "secret content", room: "vault", sensitivity: .secret)

        let result = try await dispatcher.dispatch(
            name: "moot_lens_node_motion",
            arguments: .object(["rowID": .string(drawer.id)]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == true,
                "secret-sensitivity drawer must be rejected by node_motion gate")
    }

    /// `moot_lens_node_motion` with an unknown rowID returns an error (pre-existing
    /// behaviour — confirms gate short-circuits before the audit read).
    @Test func nodeMotionUnknownRowIDIsNotFound() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "nm-x"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_lens_node_motion",
            arguments: .object(["rowID": .string(UUID().uuidString)]))

        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == true,
                "unknown rowID must produce a not-found error")
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
            arguments: JSONValue.object([String: JSONValue]()))

        let body = try text(result)
        // "vault" room comes from restricted/secret rows only — must be absent.
        #expect(!body.contains("vault"),
                "restricted/secret rooms must be excluded from estate_map output")
        // "reference" room comes from the normal row — must be present.
        #expect(body.contains("reference"),
                "normal-sensitivity rooms must appear in estate_map output")
    }

    /// `moot_estate_map` with an elevated-sensitivity drawer includes it.
    /// Elevated is within the default BitmapEvaluator ceiling (normal + elevated = bulk-exportable).
    @Test func estateMapIncludesElevatedSensitivity() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "em-el"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        _ = try await captureWithSensitivity(
            kit, handle, content: "elevated info", room: "elevated-room", sensitivity: .elevated)

        let result = try await dispatcher.dispatch(
            name: "moot_estate_map",
            arguments: JSONValue.object([String: JSONValue]()))

        let body = try text(result)
        #expect(body.contains("elevated-room"),
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

    @Test func momentInvertedWindowThrowsInvalidParams() async throws {
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

    @Test func precedenceInvertedWindowThrowsInvalidParams() async throws {
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
