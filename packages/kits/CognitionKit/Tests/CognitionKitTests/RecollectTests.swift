// RecollectTests.swift
//
// Tests for the Recollect recipe: fan-out from a _distilled factoid
// to its source memories via _distilled_from tunnels.
//
// Test IDs: EM-1..EM-6 (5 test functions; EM-1 and EM-2 covered in one)
// Layer discipline: estates opened via GeniusLocusKit — no direct substrate access.
// Rust mirror: cognition_kit::recollect — run_recollect follows the same
// all_drawers + recall_tunnels + _distilled_from filter sequence as this Swift recipe.
// Tests: CK-EM-1..CK-EM-5 in recollect.rs (IMM-COG-003).

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

@Suite("RecollectTests")
struct RecollectTests {

    // wing is the fixed constant LocusKit.defaultWingName ("Agentic Memory").
    // Tunnels are filed in this wing by Consolidate and captureFactoid.
    private static let ownerID = "recollect-test"
    private static let wing = LocusKit.defaultWingName

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let owner = OwnerCredentials(ownerIdentifier: Self.ownerID)
        // Estate.create must be called before kit.open so that the estate
        // schema exists in storage. Wing assignment is now driven by the fixed
        // LocusKit.defaultWingName constant, not the ownerIdentifier.
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    /// Capture a drawer and return its real UUID (required for hydrate to resolve content).
    private func capture(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        content: String, room: String = "notes"
    ) async throws -> String {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: room,
            latticeAnchor: .udc("0"),
            addedBy: "test",
            embeddingModelID: "test-v1")
        return try await kit.capture(handle, frame).id
    }

    /// Create a _distilled_from tunnel from factoid → source in the estate wing.
    private func wireTunnel(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        factoidID: String, sourceID: String, targetRoom: String = "notes"
    ) async throws {
        let estate = try await kit.estate(for: handle)
        let frame = TunnelCaptureFrame(
            sourceWing: Self.wing, sourceRoom: "notes",
            targetWing: Self.wing, targetRoom: targetRoom,
            label: "_distilled_from", addedBy: "test",
            sourceDrawerId: factoidID, targetDrawerId: sourceID,
            kind: .references)
        _ = try await estate.capture(frame)
    }

    // EM-1 / EM-2: golden path — DIST factoid + 3 source drawers + 3 _distilled_from tunnels.
    // Sources are returned in filedAt order (oldest first); prose is extracted from the header.
    @Test("golden path: 3 sources returned in filedAt order with correct prose")
    func goldenPath() async throws {
        let (kit, handle) = try await openEstate()

        // Capture 3 source drawers in sequence — natural filedAt oldest → newest
        let src1 = try await capture(kit, handle, content: "source memory one")
        let src2 = try await capture(kit, handle, content: "source memory two")
        let src3 = try await capture(kit, handle, content: "source memory three")

        // DIST header: conf=0.85, src=3, snr=6.2, delta=STATIC
        let distContent = "[DIST|conf=0.85|src=3|snr=6.2|delta=STATIC] user prefers morning coffee"
        let factoidID = try await capture(kit, handle, content: distContent, room: "distilled")

        // Wire tunnels oldest → newest
        try await wireTunnel(kit, handle, factoidID: factoidID, sourceID: src1)
        try await wireTunnel(kit, handle, factoidID: factoidID, sourceID: src2)
        try await wireTunnel(kit, handle, factoidID: factoidID, sourceID: src3)

        let out = try await Recollect().run(
            input: Recollect.Input(factoidDrawerID: factoidID),
            estate: handle, kit: kit)

        #expect(out.factoidID == factoidID)
        #expect(out.prose == "user prefers morning coffee")
        #expect(out.confidence == 0.85)
        #expect(out.sourceCount == 3)
        #expect(out.deltaType == "STATIC")
        #expect(out.sources.count == 3)
        #expect(out.sources.map(\.id) == [src1, src2, src3],
                "sources ordered oldest → newest by tunnel filedAt")
        #expect(out.sources[0].content == "source memory one")
        #expect(out.sources[1].content == "source memory two")
        #expect(out.sources[2].content == "source memory three")
    }

    // EM-3: a drawer whose content lacks a DIST header → notADistilledDrawer
    @Test("notADistilledDrawer: regular content throws")
    func notADistilledDrawerThrows() async throws {
        let (kit, handle) = try await openEstate()
        let regularID = try await capture(kit, handle, content: "just a plain note")

        await #expect(throws: RecollectError.notADistilledDrawer(id: regularID)) {
            _ = try await Recollect().run(
                input: Recollect.Input(factoidDrawerID: regularID),
                estate: handle, kit: kit)
        }
    }

    // EM-4: a drawer UUID that was never captured → factoidNotFound
    @Test("factoidNotFound: missing drawer ID throws")
    func factoidNotFoundThrows() async throws {
        let (kit, handle) = try await openEstate()
        let missingID = UUID().uuidString

        await #expect(throws: RecollectError.factoidNotFound(id: missingID)) {
            _ = try await Recollect().run(
                input: Recollect.Input(factoidDrawerID: missingID),
                estate: handle, kit: kit)
        }
    }

    // EM-5: valid DIST drawer but no _distilled_from tunnels wired → noSourceTunnels
    @Test("noSourceTunnels: DIST drawer with no tunnels throws")
    func noSourceTunnelsThrows() async throws {
        let (kit, handle) = try await openEstate()

        let distContent = "[DIST|conf=0.75|src=2|snr=4.1|delta=STATIC] a factoid with no wiring"
        let factoidID = try await capture(kit, handle, content: distContent, room: "distilled")

        await #expect(throws: RecollectError.noSourceTunnels(id: factoidID)) {
            _ = try await Recollect().run(
                input: Recollect.Input(factoidDrawerID: factoidID),
                estate: handle, kit: kit)
        }
    }

    // EM-6: a tunnel pointing at a withdrawn (non-existent) drawer is silently
    // skipped. Output.sourceCount (from DIST header, frozen at distillation time)
    // remains 3 while sources.count is 2.
    @Test("withdrawn source is silently skipped; sourceCount stays accurate")
    func withdrawnSourceSkipped() async throws {
        let (kit, handle) = try await openEstate()

        let src1 = try await capture(kit, handle, content: "live source one")
        let src2 = try await capture(kit, handle, content: "live source two")
        // Simulate a withdrawn drawer by referencing an ID that was never captured
        let withdrawnID = "withdrawn-\(UUID().uuidString)"

        // DIST header claims src=3 — matches the original distillation count
        let distContent = "[DIST|conf=0.9|src=3|snr=7.0|delta=STATIC] factoid with one withdrawn"
        let factoidID = try await capture(kit, handle, content: distContent, room: "distilled")

        try await wireTunnel(kit, handle, factoidID: factoidID, sourceID: src1)
        try await wireTunnel(kit, handle, factoidID: factoidID, sourceID: src2)
        try await wireTunnel(kit, handle, factoidID: factoidID, sourceID: withdrawnID)

        let out = try await Recollect().run(
            input: Recollect.Input(factoidDrawerID: factoidID),
            estate: handle, kit: kit)

        #expect(out.sourceCount == 3, "DIST header's src= count preserved from distillation time")
        #expect(out.sources.count == 2, "withdrawn drawer is absent from hydrate result — silently skipped")
    }

    // EM-7 (secfix/punt-g2): recollect on a restricted factoid must throw factoidNotFound.
    //
    // Parity with Rust run_recollect which now routes the factoid lookup through
    // coord.recall(frame, now) — the policy-enforcing path — so restricted/secret
    // factoids are excluded before their body reaches the MCP boundary.
    //
    // The Swift port previously used kit.hydrate(_:ids:) (the NON-frame-aware
    // overload) which bypasses insert_defaults and would return restricted content.
    // This test gates the frame-aware fix: a restricted factoid must be absent
    // from kit.hydrate(_:ids:matchingFrame:) → factoidNotFound.
    @Test("restricted factoid is not found by frame-aware hydration (secfix/punt-g2)")
    func restrictedFactoidIsNotFound() async throws {
        let (kit, handle) = try await openEstate()

        // Capture a DIST drawer at Restricted sensitivity. The frame-aware
        // hydration enforces SensitivityAtMost(Elevated) → this drawer must be
        // excluded from the admissible set, making it "not found" to the recipe.
        let distContent = "[DIST|conf=0.85|src=2|snr=4.0] Restricted factoid prose."
        var frame = CaptureFrame(
            content: distContent,
            channel: .typed,
            room: "_distilled",
            latticeAnchor: .udc("001"),
            addedBy: "test",
            embeddingModelID: "test-v1")
        frame.sensitivity = .restricted
        let factoidID = try await kit.capture(handle, frame).id

        // Recollect must raise factoidNotFound because the sensitivity ceiling
        // (SensitivityAtMost(Elevated)) excludes the restricted drawer from the
        // frame-aware hydrate call in step 1 of run().
        await #expect(throws: RecollectError.factoidNotFound(id: factoidID)) {
            _ = try await Recollect().run(
                input: Recollect.Input(factoidDrawerID: factoidID),
                estate: handle, kit: kit)
        }
    }
}
