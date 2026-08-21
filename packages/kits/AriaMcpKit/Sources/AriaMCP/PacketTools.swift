import AriaMCPWire

// PacketTools.swift
// AriaMcpKit
//
// MCP tool surface for agentic work packets (FAB5-I2).
//
// Four tools:
//   moot_file_packet     — create and store a WorkPacket, return drawer ID
//   moot_packet_get      — fetch a single packet by drawer ID
//   moot_packet_list     — list packets in the estate with optional limit
//   moot_packet_lineage  — BFS lineage traversal from a root drawer ID
//
// Design decisions:
//
//   GRAMMAR FIT: Packets are typed content (structuredJSON drawers in room
//   "work-packets"). Not a new noun — grammar verdict FITS GRAMMAR (Kong, FAB5-I2).
//   Tool naming follows the moot_<noun>_<verb> convention for retrieval/enumeration
//   and moot_file_<noun> for creation (consistent with moot_file_memory, moot_memory_get).
//
//   DISPATCH SHAPE: Static enum matching DatasetTools/VaultTools pattern —
//   isPacketTool(), dispatch(), tools(). Inserted in ToolDispatch.dispatch() after
//   DatasetTools and before InterfaceTools.
//
//   PROVENANCE: .interface — packet tools are user/agent-facing CRUD that target
//   a specific estate (estate handle required like all other interface tools).
//
//   STORE CONSTRUCTION: kit.estate(for:handle) → EstateAdapter(estate) →
//   WorkPacketStore(client:) — the same pattern as GeniusLocusKit consumers.
//
//   WING DEFAULT: "Agentic Memory" (LocusKit.defaultWingName). Caller may
//   override via the optional "wing" argument.
//
//   LINEAGE: moot_packet_lineage uses LineageGraph.trace, which walks
//   WorkPacket.lineageLinks (JSON-embedded, source of truth) breadth-first.
//   Tunnels are a best-effort index; this tool never touches them.

import Foundation
import GeniusLocusKit
import LocusKit
import WorkPacketKit

/// Namespace for the work-packet tool surface. No instances.
enum PacketTools {

    // MARK: - Tool name membership

    static let packetToolNames: Set<String> = [
        "moot_file_packet",
        "moot_packet_get",
        "moot_packet_list",
        "moot_packet_lineage",
    ]

    static func isPacketTool(_ name: String) -> Bool {
        packetToolNames.contains(name)
    }

    // MARK: - Dispatch

    /// Run the named packet tool. Returns a JSONValue tool result.
    ///
    /// `resolveHandle` is the same estate-routing closure used by DatasetTools and
    /// InterfaceTools — it maps optional estateID args to a registered EstateHandle.
    static func dispatch(
        name: String,
        args: [String: JSONValue],
        kit: GeniusLocusKit,
        resolveHandle: ([String: JSONValue]) throws -> EstateHandle
    ) async throws -> JSONValue {
        switch name {
        case "moot_file_packet":
            return try await runFilePacket(args: args, kit: kit, handle: try resolveHandle(args))
        case "moot_packet_get":
            return try await runPacketGet(args: args, kit: kit, handle: try resolveHandle(args))
        case "moot_packet_list":
            return try await runPacketList(args: args, kit: kit, handle: try resolveHandle(args))
        case "moot_packet_lineage":
            return try await runPacketLineage(args: args, kit: kit, handle: try resolveHandle(args))
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.methodNotFound,
                message: "Unknown packet tool: \(name)")
        }
    }

    // MARK: - Tool schema projection

    /// Four work-packet tools added to the tool list.
    static func tools() -> [ProjectedTool] {
        [
            ProjectedTool(
                name: "moot_file_packet",
                description: """
                Create and store a work packet in the estate. A work packet is a durable \
                record of an agentic objective, sources consulted, claims reached, \
                uncertainties, and next steps, with optional lineage links to prior packets. \
                Returns the estate-assigned drawer ID — supply it as targetPacketID in \
                lineageLinks of future packets, and as drawer_id for moot_packet_get / \
                moot_packet_lineage.
                """,
                inputSchema: ToolProjection.withEstateID(ToolProjection.objectSchema(
                    properties: [
                        "objective": ToolProjection.stringSchema(
                            "What this unit of work is trying to achieve."),
                        "sources": .object([
                            "type": .string("array"),
                            "description": .string(
                                "Evidence and reference material consulted. " +
                                "Each element: {\"description\":\"...\",\"kind\":\"drawer|web|file|citation\",\"uri\":\"optional\"}."),
                            "items": ToolProjection.objectSchema(
                                properties: [
                                    "description": ToolProjection.stringSchema("What this source is."),
                                    "kind": ToolProjection.stringSchema(
                                        "Source kind: drawer, web, file, citation (or any open tag)."),
                                    "uri": ToolProjection.stringSchema("Optional URI or path."),
                                ],
                                required: ["description", "kind"]),
                        ]),
                        "claims": .object([
                            "type": .string("array"),
                            "description": .string(
                                "Conclusions reached. " +
                                "Each element: {\"statement\":\"...\",\"confidence\":0.0–1.0,\"supportingSourceIDs\":[]}."),
                            "items": ToolProjection.objectSchema(
                                properties: [
                                    "statement": ToolProjection.stringSchema("The claim text."),
                                    "confidence": .object([
                                        "type": .string("number"),
                                        "description": .string("Confidence 0.0 (none) to 1.0 (certain)."),
                                    ]),
                                    "supportingSourceIDs": .object([
                                        "type": .string("array"),
                                        "description": .string("IDs of sources that support this claim."),
                                        "items": .object(["type": .string("string")]),
                                    ]),
                                ],
                                required: ["statement", "confidence"]),
                        ]),
                        "uncertainties": .object([
                            "type": .string("array"),
                            "description": .string("Known unknowns the agent identified but did not resolve."),
                            "items": .object(["type": .string("string")]),
                        ]),
                        "next_steps": .object([
                            "type": .string("array"),
                            "description": .string("Recommended follow-on actions."),
                            "items": .object(["type": .string("string")]),
                        ]),
                        "model": ToolProjection.stringSchema(
                            "Identifier of the model that produced this packet (e.g. model name/version)."),
                        "agent": ToolProjection.stringSchema(
                            "Identifier of the agent process filing this packet."),
                        "lineage_links": .object([
                            "type": .string("array"),
                            "description": .string(
                                "Typed links to prior packets. " +
                                "Each element: {\"kind\":\"derivesFrom|respondsTo\",\"targetPacketID\":\"drawer-id\"}."),
                            "items": ToolProjection.objectSchema(
                                properties: [
                                    "kind": ToolProjection.stringSchema(
                                        "Relationship: derivesFrom (built on) or respondsTo (addresses/contradicts)."),
                                    "targetPacketID": ToolProjection.stringSchema(
                                        "Estate drawer ID of the target packet (from a prior moot_file_packet response)."),
                                ],
                                required: ["kind", "targetPacketID"]),
                        ]),
                        "wing": ToolProjection.stringSchema(
                            "Optional wing name. Omit for the default wing (Agentic Memory)."),
                    ],
                    required: ["objective", "model", "agent"]
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_packet_get",
                description: """
                Fetch a single work packet by its estate drawer ID. \
                Returns the packet's objective, sources, claims, uncertainties, \
                next steps, provenance, and lineage links.
                """,
                inputSchema: ToolProjection.withEstateID(ToolProjection.objectSchema(
                    properties: [
                        "drawer_id": ToolProjection.stringSchema(
                            "Estate drawer ID returned by moot_file_packet."),
                    ],
                    required: ["drawer_id"]
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_packet_list",
                description: """
                List work packets in the estate, newest first. \
                Returns drawer ID, objective, model, and agent for each packet. \
                Use moot_packet_get for the full content of a specific packet.
                """,
                inputSchema: ToolProjection.withEstateID(ToolProjection.objectSchema(
                    properties: [
                        "limit": ToolProjection.integerSchema(
                            "Maximum packets to return (default 20, max 100)."),
                        "wing": ToolProjection.stringSchema(
                            "Optional wing name. Omit for the default wing (Agentic Memory)."),
                    ],
                    required: []
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_packet_lineage",
                description: """
                Trace the lineage of a work packet breadth-first through its lineageLinks. \
                Returns an ordered list of antecedent drawer IDs (not including the root). \
                Cycles are detected and skipped. Use moot_packet_get on each returned ID \
                to read the antecedent packet content.
                """,
                inputSchema: ToolProjection.withEstateID(ToolProjection.objectSchema(
                    properties: [
                        "drawer_id": ToolProjection.stringSchema(
                            "Estate drawer ID of the starting packet (from moot_file_packet)."),
                        "max_depth": ToolProjection.integerSchema(
                            "Maximum hops to follow (default 10, max 50)."),
                    ],
                    required: ["drawer_id"]
                )),
                provenance: .interface
            ),
        ]
    }

    // MARK: - moot_file_packet

    private static func runFilePacket(
        args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let objective = try requireString(args, "objective")
        let model = try requireString(args, "model")
        let agent = try requireString(args, "agent")
        let wing = args["wing"]?.stringValue

        let sources = try parseSources(args["sources"])
        let claims = try parseClaims(args["claims"])
        let uncertainties = parseStringArray(args["uncertainties"])
        let nextSteps = parseStringArray(args["next_steps"])
        let links = try parseLineageLinks(args["lineage_links"])

        let now = Date()
        let provenance = WorkPacketProvenance(
            model: model, agent: agent, createdAt: now, updatedAt: now)

        let packet = WorkPacket(
            objective: objective,
            sources: sources,
            claims: claims,
            uncertainties: uncertainties,
            nextSteps: nextSteps,
            provenance: provenance,
            lineageLinks: links
        )

        let estate: LocusKit.Estate
        do {
            estate = try await kit.estate(for: handle)
        } catch {
            return ToolDispatcher.errorResult(
                "moot_file_packet: estate not accessible: \(error.localizedDescription)")
        }

        let client = EstateAdapter(estate)
        let store = WorkPacketStore(
            client: client,
            wing: wing ?? LocusKit.defaultWingName)

        let drawerID: String
        do {
            drawerID = try await store.store(packet, now: now)
        } catch {
            return ToolDispatcher.errorResult(
                "moot_file_packet: store failed: \(error.localizedDescription)")
        }

        return ToolDispatcher.textResult("""
        packet_filed:
          drawer_id: \(drawerID)
          packet_id: \(packet.id)
          objective: \(objective)
          sources: \(sources.count)
          claims: \(claims.count)
          uncertainties: \(uncertainties.count)
          next_steps: \(nextSteps.count)
          lineage_links: \(links.count)
          model: \(model)
          agent: \(agent)
        """)
    }

    // MARK: - moot_packet_get

    private static func runPacketGet(
        args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let drawerID = try requireString(args, "drawer_id")

        let estate: LocusKit.Estate
        do {
            estate = try await kit.estate(for: handle)
        } catch {
            return ToolDispatcher.errorResult(
                "moot_packet_get: estate not accessible: \(error.localizedDescription)")
        }

        let store = WorkPacketStore(client: EstateAdapter(estate))
        let packet: WorkPacket?
        do {
            packet = try await store.fetch(drawerID: drawerID)
        } catch {
            return ToolDispatcher.errorResult(
                "moot_packet_get: fetch failed: \(error.localizedDescription)")
        }

        guard let p = packet else {
            return ToolDispatcher.errorResult(
                "moot_packet_get: no packet found for drawer_id \(drawerID)")
        }

        var lines: [String] = [
            "packet:",
            "  drawer_id: \(drawerID)",
            "  packet_id: \(p.id)",
            "  schema_version: \(p.schemaVersion)",
            "  objective: \(p.objective)",
            "  model: \(p.provenance.model)",
            "  agent: \(p.provenance.agent)",
            "  created_at: \(p.provenance.createdAt)",
            "  updated_at: \(p.provenance.updatedAt)",
        ]
        if !p.sources.isEmpty {
            lines.append("  sources:")
            for s in p.sources {
                lines.append("    - [\(s.kind)] \(s.description)\(s.uri.map { " (\($0))" } ?? "")")
            }
        }
        if !p.claims.isEmpty {
            lines.append("  claims:")
            for c in p.claims {
                lines.append("    - [\(String(format: "%.2f", c.confidence))] \(c.statement)")
            }
        }
        if !p.uncertainties.isEmpty {
            lines.append("  uncertainties:")
            for u in p.uncertainties { lines.append("    - \(u)") }
        }
        if !p.nextSteps.isEmpty {
            lines.append("  next_steps:")
            for s in p.nextSteps { lines.append("    - \(s)") }
        }
        if !p.lineageLinks.isEmpty {
            lines.append("  lineage_links:")
            for lk in p.lineageLinks {
                lines.append("    - [\(lk.kind.rawValue)] → \(lk.targetPacketID)")
            }
        }
        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    // MARK: - moot_packet_list

    private static func runPacketList(
        args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        // Limit: default 20, cap 100.
        let rawLimit: Int
        if let lv = args["limit"]?.integerValue {
            rawLimit = Int(lv)
        } else {
            rawLimit = 20
        }
        let limit = min(max(1, rawLimit), 100)
        let wing = args["wing"]?.stringValue ?? LocusKit.defaultWingName

        let estate: LocusKit.Estate
        do {
            estate = try await kit.estate(for: handle)
        } catch {
            return ToolDispatcher.errorResult(
                "moot_packet_list: estate not accessible: \(error.localizedDescription)")
        }

        // Bypass WorkPacketStore.list() — it returns [WorkPacket] without the estate
        // drawer ID. We need drawer.id (the estate UUID returned by WorkPacketStore.store())
        // so callers can pass it to moot_packet_get / moot_packet_lineage. Call listDrawers
        // directly via EstateAdapter and decode each drawer inline.
        let client = EstateAdapter(estate)
        let frame = RecallFrame(
            filterChain: [.currentlyBelieve, .inWing(wing), .inRoom(WorkPacketStore.room)],
            hydrationLevel: .full,
            limit: limit,
            ordering: .byCaptureTimeDesc
        )
        let drawers: [Drawer]
        do {
            drawers = try await client.listDrawers(frame)
        } catch {
            return ToolDispatcher.errorResult(
                "moot_packet_list: list failed: \(error.localizedDescription)")
        }

        if drawers.isEmpty {
            return ToolDispatcher.textResult("packets:\n  (none)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var lines: [String] = ["packets:"]
        for drawer in drawers {
            // drawer.id is the estate-assigned UUID — what moot_packet_get and
            // moot_packet_lineage require as drawer_id.
            lines.append("  - drawer_id: \(drawer.id)")
            if let data = drawer.content.data(using: .utf8),
               let p = try? decoder.decode(WorkPacket.self, from: data) {
                lines.append("    objective: \(p.objective)")
                lines.append("    model: \(p.provenance.model)")
                lines.append("    agent: \(p.provenance.agent)")
                lines.append("    lineage_count: \(p.lineageLinks.count)")
            } else {
                // Content not decodable as WorkPacket — surface the drawer ID alone
                // so the caller can still retrieve raw content via moot_memory_get.
                lines.append("    (content not decodable as WorkPacket)")
            }
        }
        lines.append("total: \(drawers.count)")
        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    // MARK: - moot_packet_lineage

    private static func runPacketLineage(
        args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let drawerID = try requireString(args, "drawer_id")
        // maxDepth: default 10, cap 50.
        let rawDepth: Int
        if let dv = args["max_depth"]?.integerValue {
            rawDepth = Int(dv)
        } else {
            rawDepth = 10
        }
        let maxDepth = min(max(1, rawDepth), 50)

        let estate: LocusKit.Estate
        do {
            estate = try await kit.estate(for: handle)
        } catch {
            return ToolDispatcher.errorResult(
                "moot_packet_lineage: estate not accessible: \(error.localizedDescription)")
        }

        let graph = LineageGraph(client: EstateAdapter(estate))
        let antecedentIDs: [String]
        do {
            antecedentIDs = try await graph.trace(from: drawerID, maxDepth: maxDepth)
        } catch {
            return ToolDispatcher.errorResult(
                "moot_packet_lineage: trace failed: \(error.localizedDescription)")
        }

        if antecedentIDs.isEmpty {
            return ToolDispatcher.textResult("""
            lineage:
              root: \(drawerID)
              antecedents: (none)
            """)
        }

        var lines: [String] = [
            "lineage:",
            "  root: \(drawerID)",
            "  antecedents:",
        ]
        for id in antecedentIDs {
            lines.append("    - \(id)")
        }
        lines.append("  count: \(antecedentIDs.count)")
        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    // MARK: - Argument helpers

    private static func requireString(
        _ args: [String: JSONValue], _ key: String
    ) throws -> String {
        guard let val = args[key]?.stringValue, !val.isEmpty else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Missing required string argument: \(key)")
        }
        return val
    }

    private static func parseStringArray(_ value: JSONValue?) -> [String] {
        value?.arrayValue?.compactMap { $0.stringValue } ?? []
    }

    private static func parseSources(_ value: JSONValue?) throws -> [WorkPacketSource] {
        guard let arr = value?.arrayValue else { return [] }
        return try arr.map { element in
            guard let obj = element.objectValue else {
                throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                    message: "moot_file_packet: each source must be a JSON object")
            }
            guard let desc = obj["description"]?.stringValue, !desc.isEmpty else {
                throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                    message: "moot_file_packet: source missing required 'description'")
            }
            let kind = obj["kind"]?.stringValue ?? "drawer"
            let uri = obj["uri"]?.stringValue
            return WorkPacketSource(description: desc, uri: uri, kind: kind)
        }
    }

    private static func parseClaims(_ value: JSONValue?) throws -> [WorkPacketClaim] {
        guard let arr = value?.arrayValue else { return [] }
        return try arr.map { element in
            guard let obj = element.objectValue else {
                throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                    message: "moot_file_packet: each claim must be a JSON object")
            }
            guard let statement = obj["statement"]?.stringValue, !statement.isEmpty else {
                throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                    message: "moot_file_packet: claim missing required 'statement'")
            }
            let confidence: Double
            switch obj["confidence"] {
            case .double(let d): confidence = d
            case .integer(let i): confidence = Double(i)
            default: confidence = 1.0
            }
            let supportingIDs = obj["supportingSourceIDs"]?.arrayValue?.compactMap {
                $0.stringValue
            } ?? []
            return WorkPacketClaim(
                statement: statement,
                confidence: confidence,
                supportingSourceIDs: supportingIDs)
        }
    }

    private static func parseLineageLinks(_ value: JSONValue?) throws -> [LineageLink] {
        guard let arr = value?.arrayValue else { return [] }
        return try arr.map { element in
            guard let obj = element.objectValue else {
                throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                    message: "moot_file_packet: each lineage_link must be a JSON object")
            }
            guard let kindStr = obj["kind"]?.stringValue,
                  let kind = LineageLinkKind(rawValue: kindStr) else {
                throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                    message: "moot_file_packet: lineage_link 'kind' must be derivesFrom or respondsTo")
            }
            guard let targetID = obj["targetPacketID"]?.stringValue, !targetID.isEmpty else {
                throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                    message: "moot_file_packet: lineage_link missing required 'targetPacketID'")
            }
            return LineageLink(kind: kind, targetPacketID: targetID)
        }
    }
}
