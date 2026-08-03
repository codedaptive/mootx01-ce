// DenseRowSensitivityGateTests.swift
//
// MXE-DM — the dense-row hydration boundary refuses stale-tunnel endpoints
// (Codex finding 9352f983dea081919f83885bdbf77d40).
//
// A tunnel inherits its endpoints' adjective sensitivity ONCE, at capture.
// `CorrectSensitivity` later rewrites only the drawer's adjective bitmap and
// never reclassifies existing tunnels — so a Normal tunnel outlives its
// endpoint's Normal status and keeps pointing at a now-Restricted drawer.
// Every graph-lens arm that hydrates an id off that graph must refuse to
// render its subject, while still emitting the id and its ranking value.
//
// ONE test per behaviour at the HELPER, not one near-duplicate per arm.
// All six lens arms in `LensTools`, the four recall arms in `RecipeTools`,
// and the two tunnel-citation arms in `ToolDispatch` — twelve call sites —
// route through `RecipeTools.denseRowsByID`, so proving the helper gates
// covers every one of them by construction.
// `lensArmInheritsTheHelperGate` then pins one real arm end-to-end so the
// routing itself cannot silently change.
//
// The gate here is the empty `filterChain` in `denseRowsByID`, which
// `BitmapEvaluator.insertDefaults` turns into `.sensitivityAtMost(.elevated)`
// on the adjective axis. Twin of the Rust `dense_row::rows_by_id` tests in
// dispatch_tests.rs (`dm_*`).

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// `.serialized`: every case opens a live in-memory estate — same
/// discipline as LensToolsTests and RecipeToolsTests.
@Suite("Dense-row sensitivity gate", .serialized)
struct DenseRowSensitivityGateTests {

    /// The canary lives in the SUBJECT, not the content: `DenseRow.render`
    /// renders `subject`, so a canary in the body would prove nothing.
    private static let canary = "dm stale-edge target SUBJECTCANARY"

    // MARK: - Harness

    private func openEstate(
        in kit: GeniusLocusKit, owner: OwnerCredentials
    ) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        return try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
    }

    /// Build the stale-edge state: two Normal drawers linked while BOTH are
    /// Normal (so the tunnel inherits Normal), then the target corrected to
    /// `sensitivity` — which leaves the tunnel's own classification stale.
    private func staleEdge(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        sensitivity: AdjectiveSensitivity
    ) async throws -> (src: String, tgt: String) {
        let estate = try await kit.estate(for: handle)
        let src = try await estate.capture(CaptureFrame(
            content: "dm stale-edge source memory", channel: .typed, room: "r",
            latticeAnchor: .udc("004"), addedBy: "dm-tests",
            embeddingModelID: "test-model-v1",
            subject: "dm stale-edge source subject")).id
        let tgt = try await estate.capture(CaptureFrame(
            content: "dm stale-edge target memory", channel: .typed, room: "r",
            latticeAnchor: .udc("004"), addedBy: "dm-tests",
            embeddingModelID: "test-model-v1",
            subject: Self.canary)).id
        _ = try await estate.capture(TunnelCaptureFrame(
            sourceWing: "study", sourceRoom: "r",
            targetWing: "study", targetRoom: "r",
            label: "relates", addedBy: "dm-tests",
            sourceDrawerId: src, targetDrawerId: tgt, kind: .references))
        try await estate.mutate(rowID: tgt, kind: .correctSensitivity(sensitivity))
        return (src, tgt)
    }

    private func text(_ result: JSONValue) throws -> String {
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        return try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    }

    // MARK: - The helper gate (covers all twelve callers by construction)

    /// A drawer restricted AFTER its tunnels were created is absent from the
    /// helper's map — so every caller's `renderUnhydrated` fallback fires.
    /// Absent rather than substituted: the map is how a caller learns the row
    /// is gated, and substituting a redaction string here would hand every
    /// arm a second, unreviewed disclosure format.
    @Test func helperOmitsStaleRestrictedEndpoint() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "dm-h-r"))
        let ids = try await staleEdge(kit, handle, sensitivity: .restricted)
        let estate = try await kit.estate(for: handle)

        let rows = try await RecipeTools.denseRowsByID(
            ids: [ids.src, ids.tgt], estate: estate)

        #expect(rows[ids.tgt] == nil,
                "a restricted endpoint must be absent from the map")
        #expect(rows[ids.src] != nil,
                "its Normal sibling must still hydrate — the gate is not a wall")
        #expect(rows.values.contains { $0.contains("SUBJECTCANARY") } == false,
                "no rendered row may carry the gated subject")
    }

    /// Same for Secret — the ceiling is `> elevated`, not `!= restricted`.
    @Test func helperOmitsStaleSecretEndpoint() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "dm-h-s"))
        let ids = try await staleEdge(kit, handle, sensitivity: .secret)
        let estate = try await kit.estate(for: handle)

        let rows = try await RecipeTools.denseRowsByID(
            ids: [ids.src, ids.tgt], estate: estate)

        #expect(rows[ids.tgt] == nil,
                "a secret endpoint must be absent from the map")
        #expect(rows.values.contains { $0.contains("SUBJECTCANARY") } == false,
                "no rendered row may carry the gated subject")
    }

    /// The gate must not become a wall. Normal and Elevated are both inside
    /// the Normal tier and must hydrate completely, subject included.
    private func expectHydratesWithinCeiling(
        _ sensitivity: AdjectiveSensitivity, owner: String
    ) async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: owner))
        let ids = try await staleEdge(kit, handle, sensitivity: sensitivity)
        let estate = try await kit.estate(for: handle)

        let rows = try await RecipeTools.denseRowsByID(
            ids: [ids.src, ids.tgt], estate: estate)

        let row = try #require(rows[ids.tgt],
                               "\(sensitivity) is within the ceiling and must hydrate")
        #expect(row.contains("SUBJECTCANARY"),
                "\(sensitivity) must render its subject in full")
    }

    @Test func helperHydratesNormalEndpoint() async throws {
        try await expectHydratesWithinCeiling(.normal, owner: "dm-h-ok-n")
    }

    /// Elevated is the ceiling itself, not above it — the boundary case that
    /// catches a gate written as `!= normal`.
    @Test func helperHydratesElevatedEndpoint() async throws {
        try await expectHydratesWithinCeiling(.elevated, owner: "dm-h-ok-e")
    }

    // MARK: - One arm end-to-end, so the routing cannot silently change

    /// `moot_lens_successors` reads straight off the tunnel graph — the arm
    /// most exposed to a stale edge. The gated endpoint STILL APPEARS by id
    /// and STILL CARRIES its ranking value; only the subject is withheld.
    /// Dropping the row would change result counts and rankings and make the
    /// gate itself an oracle.
    @Test func lensArmInheritsTheHelperGate() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "dm-arm"))
        let ids = try await staleEdge(kit, handle, sensitivity: .restricted)

        let body = try text(try await ToolDispatcher(kit: kit, handle: handle)
            .dispatch(name: "moot_lens_successors",
                      arguments: .object([
                        "wing": .string("study"),
                        "anchorID": .string(ids.src)])))

        #expect(body.contains(ids.tgt),
                "the gated endpoint must still appear by id; got: \(body)")
        #expect(body.contains("weight="),
                "it must keep its ranking value; got: \(body)")
        #expect(!body.contains("SUBJECTCANARY"),
                "it must not render its subject; got: \(body)")
        #expect(body.contains(DenseRow.renderUnhydrated(id: ids.tgt)),
                "it must render the unhydrated row byte-for-byte; got: \(body)")
    }
}
