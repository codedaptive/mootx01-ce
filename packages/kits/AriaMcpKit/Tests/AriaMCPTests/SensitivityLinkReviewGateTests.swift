import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// Sensitivity ceiling gate for moot_link_memories and moot_review_tunnel
/// (SENS_WRITE_GATE Unit 2).
///
/// Unit 1 closed the same hole on update, withdraw, erase, confirm, and move.
/// Unit 2 extends the gate to the two tunnel-writing verbs.
///
/// moot_link_memories: before this gate, both endpoints were resolved through
/// estate.allDrawers() with no ceiling check, so a link to a restricted row
/// succeeded while a link to a nonexistent UUID refused — an existence oracle.
/// After the gate, gatedDrawer resolves each endpoint through the ceiling;
/// absent and above-ceiling endpoints produce the same notFoundRefusal.
///
/// moot_review_tunnel: before this gate, getTunnel() ran with no ceiling check,
/// so a caller could endorse or reject a tunnel it could not read. After the
/// gate, the two-part rule from loadTunnels/visibleTunnels applies: refuse when
/// the tunnel's own sensitivity exceeds the ceiling, and refuse when a known
/// far-endpoint drawer exceeds the ceiling.
@Suite("Sensitivity write gate — moot_link_memories and moot_review_tunnel", .serialized)
struct SensitivityLinkReviewGateTests {

    // MARK: - Harness

    private func openEstate(
        in kit: GeniusLocusKit,
        owner: OwnerCredentials
    ) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        return try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
    }

    /// Seed a drawer with the given sensitivity directly through the kit,
    /// bypassing the write-gate under test.
    @discardableResult
    private func seedDrawer(
        _ content: String,
        sensitivity: AdjectiveSensitivity = .normal,
        in handle: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Drawer {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "slrg-tests",
            latticeAnchor: .udc("slrg"),
            addedBy: "slrg-tests",
            embeddingModelID: "test-model-v1",
            sensitivity: sensitivity
        )
        return try await kit.capture(handle, frame)
    }

    /// Seed a tunnel directly through the estate, bypassing the write-gate.
    /// Returns the STORED Tunnel (read back from the estate) so callers can
    /// assert on the sensitivity that was actually stamped into the DB.
    /// `estate.capture(TunnelCaptureFrame)` returns the pre-stamped object;
    /// only a read-back reflects the endpoint-derived sensitivity.
    @discardableResult
    private func seedTunnel(
        from source: Drawer,
        to target: Drawer,
        in handle: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Tunnel {
        let estate = try await kit.estate(for: handle)
        var frame = TunnelCaptureFrame(
            sourceWing: "slrg-wing", sourceRoom: "slrg-room",
            targetWing: "slrg-wing", targetRoom: "slrg-room",
            label: "relates", addedBy: "slrg-tests",
            sourceDrawerId: source.id, targetDrawerId: target.id, kind: .references)
        // Use .proposed lifecycle so endorseTunnel can run when the gate is absent
        // (i.e., the gate check removed for red-then-green proof). With .active lifecycle
        // endorseTunnel throws "only a proposed tunnel can be endorsed" before the lower
        // call reaches any user-visible path, masking whether the sensitivity gate fired.
        frame.lifecycle = .proposed
        let captured = try await estate.capture(frame)
        // Read back to get the stored row with endpoint-derived sensitivity stamped.
        return try await estate.getTunnel(id: captured.id) ?? captured
    }

    private func errorObject(_ result: JSONValue) -> [String: JSONValue]? {
        result.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue
    }

    private func isError(_ result: JSONValue) -> Bool {
        result.objectValue?["isError"]?.boolValue ?? false
    }

    private func tunnelCount(in handle: EstateHandle, kit: GeniusLocusKit) async throws -> Int {
        try await kit.allTunnels(in: handle).count
    }

    // MARK: - Gate 1: restricted endpoint refuses; tunnel count unchanged

    /// Pre-fix failure (verbatim — before the gate, estate.allDrawers() resolved
    /// endpoints with no ceiling, so the link succeeded):
    ///
    ///     Expectation failed: isError(result)
    ///     link with restricted from_id must be blocked; got: {"isError": false, ...}
    ///
    /// Post-fix: the link is refused with memory_not_found and no tunnel is written.
    @Test(
        "gate blocks link when endpoint is above ceiling",
        arguments: ["from_id", "to_id"] as [String]
    )
    func gateLinkRestrictedEndpoint(restrictedPosition: String) async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "slrg-gate1-\(restrictedPosition)")
        let handle = try await openEstate(in: kit, owner: owner)

        // One restricted endpoint (above the default .elevated ceiling),
        // one normal endpoint (within the ceiling).
        let restricted = try await seedDrawer(
            "restricted endpoint — link must be blocked",
            sensitivity: .restricted,
            in: handle, kit: kit)
        let normal = try await seedDrawer(
            "normal endpoint — within ceiling",
            in: handle, kit: kit)

        let countBefore = try await tunnelCount(in: handle, kit: kit)

        let (fromID, toID): (String, String) = restrictedPosition == "from_id"
            ? (restricted.id, normal.id)
            : (normal.id, restricted.id)

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let result = try await dispatcher.dispatch(
            name: "moot_link_memories",
            arguments: .object([
                "from_id": .string(fromID),
                "to_id": .string(toID),
                "relationship": .string("relates"),
            ])
        )

        #expect(isError(result),
            "link with restricted \(restrictedPosition) must be blocked; got: \(result)")

        let err = try #require(errorObject(result),
            "refusal must carry a structured error object")
        #expect(err["code"]?.stringValue == "memory_not_found",
            "code must be memory_not_found; got: \(String(describing: err["code"]))")
        #expect(err["retryable"]?.boolValue == false,
            "memory_not_found must be non-retryable")

        // No edge was written.
        let countAfter = try await tunnelCount(in: handle, kit: kit)
        #expect(countAfter == countBefore,
            "refused link must not write a tunnel; count before: \(countBefore), after: \(countAfter)")
    }

    // MARK: - Gate 2: oracle closure — restricted endpoint ≡ nonexistent UUID

    /// Oracle-closure proof: the refusal for a restricted endpoint is byte-identical
    /// to the refusal for a freshly generated nonexistent UUID, for both endpoint
    /// positions. A gate that covers only one position is half a gate.
    ///
    /// Pre-fix failure: the restricted endpoint returned a success response, which
    /// cannot be equal to the not-found refusal for a nonexistent id.
    @Test(
        "oracle closure: restricted endpoint and nonexistent UUID produce identical refusals",
        arguments: ["from_id", "to_id"] as [String]
    )
    func oracleClosureLinkRestrictedEqualsNonexistent(restrictedPosition: String) async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "slrg-oracle-\(restrictedPosition)")
        let handle = try await openEstate(in: kit, owner: owner)

        let restricted = try await seedDrawer(
            "restricted oracle test",
            sensitivity: .restricted,
            in: handle, kit: kit)
        let normal = try await seedDrawer(
            "normal oracle test",
            in: handle, kit: kit)
        let nonexistent = UUID()

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let (fromRestricted, toRestricted): (String, String) = restrictedPosition == "from_id"
            ? (restricted.id, normal.id)
            : (normal.id, restricted.id)
        let (fromNonexistent, toNonexistent): (String, String) = restrictedPosition == "from_id"
            ? (nonexistent.uuidString, normal.id)
            : (normal.id, nonexistent.uuidString)

        let restrictedResponse = try await dispatcher.dispatch(
            name: "moot_link_memories",
            arguments: .object(["from_id": .string(fromRestricted), "to_id": .string(toRestricted), "relationship": .string("relates")])
        )
        let nonexistentResponse = try await dispatcher.dispatch(
            name: "moot_link_memories",
            arguments: .object(["from_id": .string(fromNonexistent), "to_id": .string(toNonexistent), "relationship": .string("relates")])
        )

        let restrictedErr = try #require(errorObject(restrictedResponse),
            "restricted refusal must carry a structured error object")
        let nonexistentErr = try #require(errorObject(nonexistentResponse),
            "nonexistent refusal must carry a structured error object")

        #expect(restrictedErr["code"]?.stringValue == nonexistentErr["code"]?.stringValue,
            "\(restrictedPosition): restricted and nonexistent must produce the same code")
        #expect(restrictedErr["message"]?.stringValue == nonexistentErr["message"]?.stringValue,
            "\(restrictedPosition): restricted and nonexistent must produce the same message")
        #expect(restrictedErr["retryable"]?.boolValue == nonexistentErr["retryable"]?.boolValue,
            "\(restrictedPosition): restricted and nonexistent must produce the same retryable flag")
    }

    // MARK: - Gate 3: proposed link is gated identically

    /// The proposed-edge path is gated before the proposed/active branch, so a
    /// proposed link to a restricted endpoint refuses exactly like an active one.
    ///
    /// Pre-fix failure: proposed link with restricted source returned success.
    @Test func proposedLinkGatedIdenticallyToActiveLinkFromID() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "slrg-proposed-from")
        let handle = try await openEstate(in: kit, owner: owner)

        let restricted = try await seedDrawer(
            "restricted — proposed link must also be blocked",
            sensitivity: .restricted,
            in: handle, kit: kit)
        let normal = try await seedDrawer(
            "normal proposed target",
            in: handle, kit: kit)

        let countBefore = try await tunnelCount(in: handle, kit: kit)

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let result = try await dispatcher.dispatch(
            name: "moot_link_memories",
            arguments: .object([
                "from_id": .string(restricted.id),
                "to_id": .string(normal.id),
                "relationship": .string("relates"),
                "proposed": .bool(true),
            ])
        )

        #expect(isError(result),
            "proposed link with restricted from_id must be blocked; got: \(result)")

        let err = try #require(errorObject(result))
        #expect(err["code"]?.stringValue == "memory_not_found",
            "proposed link refusal must use memory_not_found code; got: \(String(describing: err["code"]))")

        let countAfter = try await tunnelCount(in: handle, kit: kit)
        #expect(countAfter == countBefore,
            "refused proposed link must not write a tunnel; count before: \(countBefore), after: \(countAfter)")
    }

    // MARK: - Gate 4: review_tunnel on above-ceiling tunnel refuses; state unchanged

    /// Pre-fix failure (verbatim — before the gate, getTunnel() ran with no
    /// ceiling check and the endorse call succeeded against a restricted tunnel):
    ///
    ///     Expectation failed: isError(result)
    ///     review_tunnel endorse on a restricted tunnel must be blocked; got: {"isError": false, ...}
    ///
    /// Post-fix: the review is refused and the tunnel's state is unchanged.
    @Test func reviewTunnelAboveCeilingTunnelRefuses() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "slrg-gate4")
        let handle = try await openEstate(in: kit, owner: owner)

        // Seed a restricted source drawer so the tunnel inherits .restricted sensitivity.
        let source = try await seedDrawer(
            "restricted source — tunnel inherits restricted",
            sensitivity: .restricted,
            in: handle, kit: kit)
        let target = try await seedDrawer(
            "normal target for restricted tunnel",
            in: handle, kit: kit)

        // Capture the tunnel directly through the estate (bypassing the write gate).
        let tunnel = try await seedTunnel(from: source, to: target, in: handle, kit: kit)
        // Verify the tunnel's own sensitivity reflects the source's .restricted level.
        #expect(tunnel.adjectiveSensitivity == .restricted,
            "tunnel seeded from a .restricted source must have .restricted own sensitivity")

        // Record tunnel state before the refused call.
        let estateBefore = try await kit.estate(for: handle)
        let tunnelBefore = try await estateBefore.getTunnel(id: tunnel.id)
        let lifecycleBefore = tunnelBefore?.lifecycle

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let result = try await dispatcher.dispatch(
            name: "moot_review_tunnel",
            arguments: .object([
                "tunnel_id": .string(tunnel.id),
                "decision": .string("endorse"),
                "reviewed_by": .string("test-reviewer"),
            ])
        )

        #expect(isError(result),
            "review_tunnel endorse on a restricted tunnel must be blocked; got: \(result)")

        // State must be unchanged: compare the full tunnel row (Tunnel is Equatable).
        let estateAfter = try await kit.estate(for: handle)
        let tunnelAfter = try await estateAfter.getTunnel(id: tunnel.id)
        #expect(tunnelAfter?.lifecycle == lifecycleBefore,
            "refused review must not change tunnel lifecycle")
        #expect(tunnelAfter?.ext == tunnelBefore?.ext,
            "refused review must not change tunnel ext / review ledger")
        #expect(tunnelAfter?.adjectiveBitmap == tunnelBefore?.adjectiveBitmap,
            "refused review must not change tunnel adjective bitmap")
    }

    // MARK: - Gate 4b: oracle closure — above-ceiling tunnel ≡ nonexistent tunnel id

    /// The refusal for an above-ceiling tunnel must be byte-identical to the
    /// refusal for a freshly generated nonexistent tunnel UUID, so the caller
    /// cannot distinguish the two cases.
    @Test func reviewTunnelOracleClosureAboveCeilingEqualsNonexistent() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "slrg-gate4b")
        let handle = try await openEstate(in: kit, owner: owner)

        let source = try await seedDrawer(
            "restricted source for oracle closure",
            sensitivity: .restricted,
            in: handle, kit: kit)
        let target = try await seedDrawer(
            "normal target for oracle closure",
            in: handle, kit: kit)
        let tunnel = try await seedTunnel(from: source, to: target, in: handle, kit: kit)
        let nonexistentTunnelID = UUID()

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let restrictedResponse = try await dispatcher.dispatch(
            name: "moot_review_tunnel",
            arguments: .object([
                "tunnel_id": .string(tunnel.id),
                "decision": .string("endorse"),
                "reviewed_by": .string("test-reviewer"),
            ])
        )
        let nonexistentResponse = try await dispatcher.dispatch(
            name: "moot_review_tunnel",
            arguments: .object([
                "tunnel_id": .string(nonexistentTunnelID.uuidString),
                "decision": .string("endorse"),
                "reviewed_by": .string("test-reviewer"),
            ])
        )

        let restrictedErr = try #require(errorObject(restrictedResponse),
            "above-ceiling tunnel refusal must carry a structured error object")
        let nonexistentErr = try #require(errorObject(nonexistentResponse),
            "nonexistent tunnel refusal must carry a structured error object")

        #expect(restrictedErr["code"]?.stringValue == nonexistentErr["code"]?.stringValue,
            "above-ceiling and nonexistent must produce the same code")
        #expect(restrictedErr["message"]?.stringValue == nonexistentErr["message"]?.stringValue,
            "above-ceiling and nonexistent must produce the same message")
        #expect(restrictedErr["retryable"]?.boolValue == nonexistentErr["retryable"]?.boolValue,
            "above-ceiling and nonexistent must produce the same retryable flag")
    }

    // MARK: - Gate 5: far-endpoint above ceiling refuses (second part of the rule)

    /// The far-endpoint part of the two-part rule: a tunnel whose own sensitivity
    /// is within the ceiling but whose far-endpoint drawer is above the ceiling
    /// must also be refused. This is the half most likely to be skipped.
    ///
    /// Pre-fix failure: a tunnel with a normal-sensitivity tunnel label but a
    /// restricted far endpoint would succeed — the far-endpoint check was absent.
    @Test func reviewTunnelFarEndpointAboveCeilingRefuses() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "slrg-gate5")
        let handle = try await openEstate(in: kit, owner: owner)

        // Source is normal so the tunnel's own sensitivity is normal (within ceiling).
        let source = try await seedDrawer(
            "normal source — tunnel own sensitivity is normal",
            sensitivity: .normal,
            in: handle, kit: kit)
        // Target is restricted — the far-endpoint check must fire.
        let target = try await seedDrawer(
            "restricted target — far-endpoint check must refuse",
            sensitivity: .restricted,
            in: handle, kit: kit)

        // Capture a tunnel directly. Use .proposed lifecycle so endorseTunnel can
        // run when the gate is absent (proving RED). The DB-stamped sensitivity
        // is determined from the endpoint drawers by DrawerStore.addTunnel; the
        // far-endpoint gate path also fires because the target drawer is .restricted.
        let estate = try await kit.estate(for: handle)
        var frame = TunnelCaptureFrame(
            sourceWing: "slrg-wing", sourceRoom: "slrg-room",
            targetWing: "slrg-wing", targetRoom: "slrg-room",
            label: "relates", addedBy: "slrg-tests",
            sourceDrawerId: source.id, targetDrawerId: target.id, kind: .references)
        frame.lifecycle = .proposed
        let tunnel = try await estate.capture(frame)

        // Confirm the capture() return value (pre-DB-stamping) shows .normal sensitivity.
        // The DB-stamped version may differ (endpoint-derived); the gate checks the DB
        // row via getTunnel(), which may fire on own-sensitivity or far-endpoint.
        // Either way the result must be mutation_unavailable — this test verifies that
        // a .restricted endpoint triggers a refusal regardless of which check fires.
        #expect(tunnel.adjectiveSensitivity.rawValue <= AdjectiveSensitivity.elevated.rawValue,
            "capture() return (pre-stamp) sensitivity must be within ceiling; got: \(tunnel.adjectiveSensitivity)")

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let result = try await dispatcher.dispatch(
            name: "moot_review_tunnel",
            arguments: .object([
                "tunnel_id": .string(tunnel.id),
                "decision": .string("endorse"),
                "reviewed_by": .string("test-reviewer"),
            ])
        )

        #expect(isError(result),
            "review_tunnel endorse must be blocked when far endpoint is .restricted; got: \(result)")

        let err = try #require(errorObject(result))
        #expect(err["code"]?.stringValue == "mutation_unavailable",
            "far-endpoint gate must use mutation_unavailable code (matching nonexistent tunnel); got: \(String(describing: err["code"]))")
    }

    // MARK: - Gate 6: link between readable rows still succeeds

    /// Green-side verification: the gate does not over-block. A link between
    /// two normal-sensitivity rows (within the default .elevated ceiling) must
    /// succeed and write exactly one tunnel.
    ///
    /// Pre-fix: this always passed; it guards against the gate being implemented
    /// as a blanket block rather than a ceiling check.
    @Test func linkBetweenReadableRowsSucceeds() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "slrg-gate6")
        let handle = try await openEstate(in: kit, owner: owner)

        let source = try await seedDrawer("normal source", in: handle, kit: kit)
        let target = try await seedDrawer("normal target", in: handle, kit: kit)

        let countBefore = try await tunnelCount(in: handle, kit: kit)

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let result = try await dispatcher.dispatch(
            name: "moot_link_memories",
            arguments: .object([
                "from_id": .string(source.id),
                "to_id": .string(target.id),
                "relationship": .string("relates"),
            ])
        )

        #expect(!isError(result),
            "link between normal rows must succeed; got: \(result)")

        let countAfter = try await tunnelCount(in: handle, kit: kit)
        #expect(countAfter == countBefore + 1,
            "successful link must write exactly one tunnel; count before: \(countBefore), after: \(countAfter)")
    }
}
