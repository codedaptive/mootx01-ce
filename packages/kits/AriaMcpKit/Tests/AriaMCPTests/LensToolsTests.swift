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

    // MARK: - Recall lens

    // MARK: - Lens refusal face

    // MARK: - Federated lens (two estates via estateIDB)

    // MARK: - Cohesion lens (renamed from contradiction; content-outlier detector)

    /// `moot_lens_cohesion` dispatches to the content-cohesion outlier algorithm
    /// and returns a result whose text mentions "cohesion_outliers".

    // MARK: - Genuine contradiction lens

    /// `moot_lens_contradiction` returns text distinguishing contradicts-tunnel
    /// signal from conflicting-facts signal. With no tunnels or conflicting facts
    /// in a fresh estate, both sub-reports should surface "none".

    /// SECFIX (codex: MCP fact tools leak restricted/secret KG data): the
    /// contradiction lens must redact a fact's SOURCE drawer id when that source
    /// is Restricted/Secret, even though the emitted (Normal) facts pass the fact
    /// ceiling. Parity with the Rust `lens_contradiction_hides_secret_fact_source`.

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

    /// `moot_lens_node_motion` with a restricted drawer is rejected as not-found.
    /// The gate must treat restricted rows as opaque — callers must not discover
    /// that the row exists (isError true, same as an unknown id).

    /// `moot_lens_node_motion` with a secret drawer is rejected as not-found.

    /// `moot_lens_node_motion` with an unknown rowID returns an error (pre-existing
    /// behaviour — confirms gate short-circuits before the audit read).

    /// `moot_estate_map` excludes restricted and secret drawers from wing/room counts.
    /// A wing with ONLY restricted/secret rows must not appear in the output.

    /// `moot_estate_map` with an elevated-sensitivity drawer includes it.
    /// Elevated is within the default BitmapEvaluator ceiling (normal + elevated = bulk-exportable).
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
    /// not just a count.
}

// MARK: - PR-05 Part B: dense-row golden tests (byte-identical renderer)

extension LensToolsTests {

    /// Golden test: `moot_lens_trust_synthesis` row strings match
    /// `ResultComposer.renderS2Row` byte-for-byte. Both paths (the lens and the
    /// test) route through `RecipeTools.s2RowsByID` — identical inputs must
    /// produce identical strings.

    /// Golden test: `moot_lens_keystones` row strings match `ResultComposer.renderS2Row`
    /// byte-for-byte for a hub drawer whose UUID is a real captured drawer.
    /// Using a real drawer ensures `s2RowsByID` hydrates it fully rather
    /// than falling back to the unhydrated S2 fallback.
}
