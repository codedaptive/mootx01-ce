// PacketToolsTests.swift
// AriaMcpKit
//
// Tests for the work-packet MCP tool surface (FAB5-I2).
//
// Coverage:
//   - Tool projection: 4 packet tools present, all carry .interface provenance.
//   - moot_file_packet → moot_packet_get round-trip: objective, model, agent survive.
//   - moot_packet_list: filed packet appears in list output.
//   - moot_packet_lineage: two-packet chain returns one antecedent.
//   - Required-arg enforcement: missing objective/model/agent → isError response.
//   - Unknown drawer_id: moot_packet_get returns isError.
//   - Read gate: adjective restricted/secret packets are not-found by default,
//     a live grant lifts the adjective ceiling, provenance Restricted/Secret is
//     never returned, the not-found shape matches a missing id, lineage gates
//     its root and omits gated antecedents, and `wing` routes get/lineage.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// `.serialized`: each test case opens a live in-memory estate — same discipline
/// as DatasetToolsTests and LensToolsTests.
@Suite("Packet tools", .serialized)
struct PacketToolsTests {

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

    /// Extract isError:false text content from a tool result.
    private func text(_ result: JSONValue) throws -> String {
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false,
            "Expected isError: false; result: \(result)")
        return try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    }

    /// True when the result carries isError: true.
    private func isError(_ result: JSONValue) -> Bool {
        result.objectValue?["isError"]?.boolValue == true
    }

    /// The text body of a result regardless of its isError flag.
    private func body(_ result: JSONValue) -> String {
        result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
    }

    /// A minimal WorkPacket v1 JSON body as `moot_file_packet` would store it,
    /// so a drawer can be seeded straight into the estate with chosen
    /// sensitivity bits (the packet tools expose no sensitivity argument).
    private func packetJSON(objective: String, lineageTargets: [String] = []) -> String {
        let links = lineageTargets
            .map { "{\"kind\":\"derivesFrom\",\"targetPacketID\":\"\($0)\"}" }
            .joined(separator: ",")
        return "{\"schemaVersion\":1,\"id\":\"\(UUID().uuidString)\",\"objective\":\"\(objective)\","
            + "\"sources\":[],\"claims\":[],\"uncertainties\":[],\"nextSteps\":[],"
            + "\"provenance\":{\"model\":\"seed-model\",\"agent\":\"seed-agent\","
            + "\"createdAt\":\"2023-11-14T22:13:20Z\",\"updatedAt\":\"2023-11-14T22:13:20Z\"},"
            + "\"lineageLinks\":[\(links)]}"
    }

    /// Seed a packet drawer directly into the packets room of the default wing
    /// with full control over both sensitivity axes: the adjective axis (bits
    /// 6-11, gated by the RecallFrame ceiling) and the provenance axis (bits
    /// 30-35, gated unconditionally). Mirrors `MemoryGetTests.seed`.
    @discardableResult
    private func seedPacket(
        objective: String,
        lineageTargets: [String] = [],
        sensitivity: AdjectiveSensitivity = .normal,
        provenanceSensitivity: LocusKit.Sensitivity = .normal,
        in handle: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Drawer {
        // "work-packets" is WorkPacketStore.room — the room moot_file_packet files into.
        var frame = CaptureFrame(
            content: packetJSON(objective: objective, lineageTargets: lineageTargets),
            channel: .actuator,
            room: "work-packets",
            latticeAnchor: .udc("004"),
            addedBy: "PacketToolsTests",
            embeddingModelID: "none",
            sensitivity: sensitivity,
            kind: .structuredJSON,
            provenanceSensitivity: provenanceSensitivity
        )
        frame.wing = LocusKit.defaultWingName
        return try await kit.capture(handle, frame)
    }

    /// Parse a "  key: value" or "  - key: value" line from a multi-line response body.
    private func extractValue(key: String, from body: String) -> String? {
        let prefix = "\(key): "
        let listPrefix = "- \(key): "
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count))
            }
            if trimmed.hasPrefix(listPrefix) {
                return String(trimmed.dropFirst(listPrefix.count))
            }
        }
        return nil
    }

    // MARK: - Tool projection

    @Test func toolListContainsFourPacketTools() {
        let names = Set(ToolProjection.tools().map(\.name))
        #expect(names.contains("moot_file_packet"))
        #expect(names.contains("moot_packet_get"))
        #expect(names.contains("moot_packet_list"))
        #expect(names.contains("moot_packet_lineage"))
    }

    @Test func packetToolsCarryInterfaceProvenance() {
        let packetTools = ToolProjection.tools().filter {
            PacketTools.isPacketTool($0.name)
        }
        #expect(packetTools.count == 4)
        for tool in packetTools {
            #expect(tool.provenance == .interface,
                "\(tool.name) must carry .interface provenance")
        }
    }

    // MARK: - moot_file_packet → moot_packet_get round-trip

    @Test func filePacketGetRoundTrip() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pkt-rtrip"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let fileArgs: JSONValue = .object([
            "objective": .string("Verify the round-trip serialisation of work packets."),
            "model":     .string("claude-sonnet-4-6"),
            "agent":     .string("PacketToolsTests"),
            "sources": .array([
                .object([
                    "description": .string("AriaMcpKit source tree"),
                    "kind":        .string("file"),
                    "uri":         .string("packages/kits/AriaMcpKit"),
                ])
            ]),
            "claims": .array([
                .object([
                    "statement":  .string("WorkPacket round-trips through the estate."),
                    "confidence": .double(0.95),
                ])
            ]),
            "uncertainties": .array([.string("Edge behaviour under concurrent writers.")]),
            "next_steps":    .array([.string("Expand to concurrent-write test.")]),
        ])

        let fileResult = try await dispatcher.dispatch(
            name: "moot_file_packet",
            arguments: fileArgs)
        let fileBody = try text(fileResult)

        #expect(fileBody.hasPrefix("packet_filed:"),
            "moot_file_packet must return packet_filed: header; got: \(fileBody)")
        #expect(fileBody.contains("sources: 1"))
        #expect(fileBody.contains("claims: 1"))
        #expect(fileBody.contains("uncertainties: 1"))
        #expect(fileBody.contains("next_steps: 1"))

        let drawerID = try #require(extractValue(key: "drawer_id", from: fileBody),
            "packet_filed response must include drawer_id:")
        #expect(!drawerID.isEmpty)

        // Retrieve the packet and confirm objective survives the round-trip.
        let getResult = try await dispatcher.dispatch(
            name: "moot_packet_get",
            arguments: .object(["drawer_id": .string(drawerID)]))
        let getBody = try text(getResult)

        #expect(getBody.hasPrefix("packet:"),
            "moot_packet_get must return packet: header; got: \(getBody)")
        #expect(getBody.contains("drawer_id: \(drawerID)"))
        #expect(getBody.contains("Verify the round-trip serialisation of work packets."))
        #expect(getBody.contains("claude-sonnet-4-6"))
        #expect(getBody.contains("PacketToolsTests"))
    }

    // MARK: - moot_packet_list

    @Test func listPacketsContainsFiledPacket() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pkt-list"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // File a packet.
        let fileArgs: JSONValue = .object([
            "objective": .string("List-test objective."),
            "model":     .string("test-model"),
            "agent":     .string("test-agent"),
        ])
        let fileResult = try await dispatcher.dispatch(
            name: "moot_file_packet",
            arguments: fileArgs)
        #expect(!isError(fileResult), "moot_file_packet must not return isError")

        // List should include the packet.
        let listResult = try await dispatcher.dispatch(
            name: "moot_packet_list",
            arguments: .object([:]))
        let listBody = try text(listResult)

        #expect(listBody.hasPrefix("packets:"),
            "moot_packet_list must return packets: header; got: \(listBody)")
        #expect(listBody.contains("List-test objective."),
            "Listed packets must include the filed packet's objective")
        #expect(listBody.contains("total: 1"))

        // Verify drawer_id is present and usable in a subsequent moot_packet_get.
        // This is the key list→get round-trip: the IDs emitted by list must be
        // the estate drawer IDs, not the WorkPacket's own UUID.
        let drawerID = try #require(extractValue(key: "drawer_id", from: listBody),
            "moot_packet_list must emit a drawer_id: line per packet")
        #expect(!drawerID.isEmpty)

        let getResult = try await dispatcher.dispatch(
            name: "moot_packet_get",
            arguments: .object(["drawer_id": .string(drawerID)]))
        #expect(!isError(getResult),
            "drawer_id from moot_packet_list must be usable in moot_packet_get; got isError for drawer_id=\(drawerID)")
        let getBody = try text(getResult)
        #expect(getBody.contains("List-test objective."),
            "moot_packet_get via list drawer_id must return the correct packet")
    }

    // MARK: - moot_packet_lineage

    @Test func packetLineageTwoNodeChain() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pkt-lineage"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // File ancestor packet.
        let ancestorResult = try await dispatcher.dispatch(
            name: "moot_file_packet",
            arguments: .object([
                "objective": .string("Ancestor packet."),
                "model":     .string("m1"),
                "agent":     .string("a1"),
            ]))
        let ancestorBody = try text(ancestorResult)
        let ancestorDrawerID = try #require(
            extractValue(key: "drawer_id", from: ancestorBody))

        // File descendant packet that derives from the ancestor.
        let descendantResult = try await dispatcher.dispatch(
            name: "moot_file_packet",
            arguments: .object([
                "objective": .string("Descendant packet."),
                "model":     .string("m2"),
                "agent":     .string("a2"),
                "lineage_links": .array([
                    .object([
                        "kind":          .string("derivesFrom"),
                        "targetPacketID": .string(ancestorDrawerID),
                    ])
                ]),
            ]))
        let descendantBody = try text(descendantResult)
        let descendantDrawerID = try #require(
            extractValue(key: "drawer_id", from: descendantBody))

        // Trace lineage from descendant — should return ancestor.
        let lineageResult = try await dispatcher.dispatch(
            name: "moot_packet_lineage",
            arguments: .object(["drawer_id": .string(descendantDrawerID)]))
        let lineageBody = try text(lineageResult)

        #expect(lineageBody.hasPrefix("lineage:"),
            "moot_packet_lineage must return lineage: header; got: \(lineageBody)")
        #expect(lineageBody.contains(ancestorDrawerID),
            "Lineage trace must include the ancestor drawer ID")
        #expect(lineageBody.contains("count: 1"))
    }

    // MARK: - Required-arg enforcement

    @Test func filePacketMissingObjectiveIsError() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pkt-req-obj"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        // `objective` is required — omitting it must throw a JSONRPCError
        // before the store is reached (so no isError tool result — the
        // dispatcher propagates the JSONRPCError directly).
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_file_packet",
                arguments: .object([
                    "model": .string("m"),
                    "agent": .string("a"),
                ]))
            Issue.record("Expected a JSONRPCError for missing objective")
        } catch is JSONRPCError {
            // Expected path — missing required arg throws.
        }
    }

    @Test func getPacketMissingDrawerIDIsError() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pkt-req-did"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_packet_get",
                arguments: .object([:]))
            Issue.record("Expected a JSONRPCError for missing drawer_id")
        } catch is JSONRPCError {
            // Expected.
        }
    }

    @Test func getPacketUnknownDrawerIDReturnsError() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pkt-unknown"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let result = try await dispatcher.dispatch(
            name: "moot_packet_get",
            arguments: .object(["drawer_id": .string(UUID().uuidString)]))
        #expect(isError(result), "Non-existent drawer_id must return isError: true")
    }

    // MARK: - Read gate: moot_packet_get

    /// The not-found text the gate must reproduce exactly, so a gated id and a
    /// missing id are indistinguishable to the caller.
    private func notFound(_ id: String) -> String {
        "moot_packet_get: no packet found for drawer_id \(id)"
    }

    @Test func getPacketAdjectiveRestrictedIsReportedNotFound() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pkt-adj-restricted"))
        let objective = "restricted packet body that must not leak through packet-get"
        let drawer = try await seedPacket(
            objective: objective, sensitivity: .restricted, in: handle, kit: kit)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_packet_get",
            arguments: .object(["drawer_id": .string(drawer.id)]))
        #expect(isError(result), "adjective-restricted packet must be reported not-found; got: \(result)")
        #expect(body(result) == notFound(drawer.id),
            "gated rows use the same not-found shape as a missing id")
        #expect(!body(result).contains(objective))
    }

    @Test func getPacketAdjectiveSecretIsReportedNotFound() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pkt-adj-secret"))
        let objective = "secret packet body that must not leak through packet-get"
        let drawer = try await seedPacket(
            objective: objective, sensitivity: .secret, in: handle, kit: kit)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_packet_get",
            arguments: .object(["drawer_id": .string(drawer.id)]))
        #expect(isError(result))
        #expect(body(result) == notFound(drawer.id))
        #expect(!body(result).contains(objective))
    }

    @Test func getPacketNotFoundShapeMatchesMissingID() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pkt-shape"))
        let gated = try await seedPacket(
            objective: "gated", sensitivity: .restricted, in: handle, kit: kit)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let missingID = UUID().uuidString

        let gatedResult = try await dispatcher.dispatch(
            name: "moot_packet_get",
            arguments: .object(["drawer_id": .string(gated.id)]))
        let missingResult = try await dispatcher.dispatch(
            name: "moot_packet_get",
            arguments: .object(["drawer_id": .string(missingID)]))
        // Identical up to the echoed id — no field, flag, or wording differs.
        #expect(body(gatedResult).replacingOccurrences(of: gated.id, with: "ID")
            == body(missingResult).replacingOccurrences(of: missingID, with: "ID"))
        #expect(isError(gatedResult) && isError(missingResult))
    }

    @Test func getPacketRestrictedGrantLiftsAdjectiveCeiling() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pkt-grant-restricted"))
        let restricted = try await seedPacket(
            objective: "restricted packet visible under a restricted grant",
            sensitivity: .restricted, in: handle, kit: kit)
        let secret = try await seedPacket(
            objective: "secret packet stays hidden under a restricted grant",
            sensitivity: .secret, in: handle, kit: kit)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Locked: hidden.
        let locked = try await dispatcher.dispatch(
            name: "moot_packet_get", arguments: .object(["drawer_id": .string(restricted.id)]))
        #expect(isError(locked))

        // Restricted grant: restricted visible, secret still hidden. The grant
        // is a ceiling — it lifts exactly one tier, as it does for moot_memory_get.
        await dispatcher.sensitivityUnlockLedger.grantRestricted(now: Date())
        let lifted = try await dispatcher.dispatch(
            name: "moot_packet_get", arguments: .object(["drawer_id": .string(restricted.id)]))
        #expect(try text(lifted).contains("restricted packet visible under a restricted grant"))
        let secretUnderRestricted = try await dispatcher.dispatch(
            name: "moot_packet_get", arguments: .object(["drawer_id": .string(secret.id)]))
        #expect(isError(secretUnderRestricted))

        // Secret grant: both visible.
        await dispatcher.sensitivityUnlockLedger.grantSecret(now: Date())
        let liftedSecret = try await dispatcher.dispatch(
            name: "moot_packet_get", arguments: .object(["drawer_id": .string(secret.id)]))
        #expect(try text(liftedSecret).contains("secret packet stays hidden under a restricted grant"))

        // Lock: hidden again.
        await dispatcher.sensitivityUnlockLedger.lock()
        let relocked = try await dispatcher.dispatch(
            name: "moot_packet_get", arguments: .object(["drawer_id": .string(restricted.id)]))
        #expect(isError(relocked))
    }

    @Test func getPacketProvenanceSecretIsNotFoundEvenUnderSecretGrant() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pkt-prov-secret"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        // The widest grant lifts the adjective axis only.
        await dispatcher.sensitivityUnlockLedger.grantSecret(now: Date())

        for tier: LocusKit.Sensitivity in [.restricted, .secret] {
            let objective = "provenance-\(tier) packet body must never be returned"
            let drawer = try await seedPacket(
                objective: objective, provenanceSensitivity: tier, in: handle, kit: kit)
            let result = try await dispatcher.dispatch(
                name: "moot_packet_get",
                arguments: .object(["drawer_id": .string(drawer.id)]))
            #expect(isError(result), "provenance \(tier) must be reported not-found; got: \(result)")
            #expect(body(result) == notFound(drawer.id))
            #expect(!body(result).contains(objective))
        }
    }

    @Test func getPacketProvenanceNormalAndElevatedAreReturned() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pkt-prov-open"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        for tier: LocusKit.Sensitivity in [.normal, .elevated] {
            let objective = "provenance-\(tier) packet body is returned in full"
            let drawer = try await seedPacket(
                objective: objective, provenanceSensitivity: tier, in: handle, kit: kit)
            let result = try await dispatcher.dispatch(
                name: "moot_packet_get",
                arguments: .object(["drawer_id": .string(drawer.id)]))
            #expect(try text(result).contains(objective))
        }
    }

    @Test func getPacketWingArgumentRoutesToTheFiledWing() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pkt-wing"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let fileResult = try await dispatcher.dispatch(
            name: "moot_file_packet",
            arguments: .object([
                "objective": .string("Packet filed into a custom wing."),
                "model":     .string("m"),
                "agent":     .string("a"),
                "wing":      .string("Research"),
            ]))
        let drawerID = try #require(extractValue(key: "drawer_id", from: try text(fileResult)))

        // The read frame carries the wing, so the default wing does not see it...
        let defaultWing = try await dispatcher.dispatch(
            name: "moot_packet_get",
            arguments: .object(["drawer_id": .string(drawerID)]))
        #expect(isError(defaultWing))
        // ...and the filed wing does — same optional `wing` moot_packet_list takes.
        let filedWing = try await dispatcher.dispatch(
            name: "moot_packet_get",
            arguments: .object(["drawer_id": .string(drawerID), "wing": .string("Research")]))
        #expect(try text(filedWing).contains("Packet filed into a custom wing."))
    }

    // MARK: - Read gate: moot_packet_lineage

    @Test func lineageRestrictedRootIsReportedNotFound() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pkt-lin-root"))
        let ancestor = try await seedPacket(objective: "open ancestor", in: handle, kit: kit)
        let root = try await seedPacket(
            objective: "restricted root", lineageTargets: [ancestor.id],
            sensitivity: .restricted, in: handle, kit: kit)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_packet_lineage",
            arguments: .object(["drawer_id": .string(root.id)]))
        #expect(isError(result), "a gated root must not be traversed; got: \(result)")
        #expect(body(result) == "moot_packet_lineage: no packet found for drawer_id \(root.id)")
        #expect(!body(result).contains(ancestor.id),
            "a gated root's antecedents must not be enumerated")
    }

    @Test func lineageOmitsGatedAntecedents() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pkt-lin-antecedent"))
        let open = try await seedPacket(objective: "open ancestor", in: handle, kit: kit)
        let restricted = try await seedPacket(
            objective: "restricted ancestor", sensitivity: .restricted, in: handle, kit: kit)
        let provenanceSecret = try await seedPacket(
            objective: "provenance-secret ancestor", provenanceSensitivity: .secret,
            in: handle, kit: kit)
        let root = try await seedPacket(
            objective: "open root",
            lineageTargets: [open.id, restricted.id, provenanceSecret.id],
            in: handle, kit: kit)
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let locked = try await dispatcher.dispatch(
            name: "moot_packet_lineage",
            arguments: .object(["drawer_id": .string(root.id)]))
        let lockedBody = try text(locked)
        #expect(lockedBody.contains(open.id))
        #expect(!lockedBody.contains(restricted.id), "adjective-restricted antecedent must be omitted")
        #expect(!lockedBody.contains(provenanceSecret.id), "provenance-secret antecedent must be omitted")
        #expect(lockedBody.contains("count: 1"))

        // A restricted grant admits the adjective-restricted antecedent only.
        await dispatcher.sensitivityUnlockLedger.grantRestricted(now: Date())
        let granted = try await dispatcher.dispatch(
            name: "moot_packet_lineage",
            arguments: .object(["drawer_id": .string(root.id)]))
        let grantedBody = try text(granted)
        #expect(grantedBody.contains(open.id))
        #expect(grantedBody.contains(restricted.id))
        #expect(!grantedBody.contains(provenanceSecret.id))
        #expect(grantedBody.contains("count: 2"))
    }

    // MARK: - End-to-end round-trip over MCP surface (Part 2)

    /// MCP round-trip proof: file a packet via moot_file_packet, then retrieve it
    /// via BOTH the generic memory surface (moot_memory_get) AND the packet-specific
    /// surface (moot_packet_get). This confirms packets are first-class drawers
    /// reachable through the full estate substrate.
    @Test func e2eFilePacketRetrievableViaMemoryGetAndPacketGet() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "pkt-e2e"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // File a packet with representative fields.
        let fileResult = try await dispatcher.dispatch(
            name: "moot_file_packet",
            arguments: .object([
                "objective": .string("Prove the MCP surface round-trip for work packets."),
                "model":     .string("claude-sonnet-4-6"),
                "agent":     .string("PacketToolsTests/e2e"),
                "claims": .array([
                    .object([
                        "statement":  .string("Packets are reachable via the generic memory surface."),
                        "confidence": .double(1.0),
                    ])
                ]),
                "next_steps": .array([.string("Deploy to production.")]),
            ]))
        let fileBody = try text(fileResult)
        #expect(fileBody.hasPrefix("packet_filed:"))

        let drawerID = try #require(extractValue(key: "drawer_id", from: fileBody))
        #expect(!drawerID.isEmpty)

        // Retrieve via the GENERIC memory surface (moot_memory_get).
        // Packets are structuredJSON drawers; moot_memory_get retrieves any drawer by ID.
        let memGetResult = try await dispatcher.dispatch(
            name: "moot_memory_get",
            arguments: .object(["id": .string(drawerID)]))
        let memGetBody = try text(memGetResult)
        // The generic memory view returns the raw drawer content — the packet JSON.
        // Verify the objective text survives in the drawer content.
        #expect(memGetBody.contains("Prove the MCP surface round-trip for work packets."),
            "moot_memory_get must return the packet's objective in drawer content")

        // Retrieve via the PACKET-SPECIFIC surface (moot_packet_get).
        let pkgGetResult = try await dispatcher.dispatch(
            name: "moot_packet_get",
            arguments: .object(["drawer_id": .string(drawerID)]))
        let pkgGetBody = try text(pkgGetResult)
        #expect(pkgGetBody.contains("Prove the MCP surface round-trip for work packets."),
            "moot_packet_get must decode the objective from the packet JSON")
        #expect(pkgGetBody.contains("claude-sonnet-4-6"))
        #expect(pkgGetBody.contains("Packets are reachable via the generic memory surface."),
            "moot_packet_get must decode claims from the packet JSON")
        #expect(pkgGetBody.contains("Deploy to production."),
            "moot_packet_get must decode next_steps from the packet JSON")
    }
}
