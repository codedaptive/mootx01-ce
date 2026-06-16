import Foundation

// PalaceDriftDetector.swift — fixes the benchmarker's GAP F (no drift
// detection). At pump start the orchestrator calls MemPalace `tools/list` and
// diffs the live tool surface against the manifest of tools+args the pump was
// written for. If MemPalace's MCP surface has changed under us — a renamed
// tool, a removed required argument, a new required argument the pump does not
// send — the pump HALTS with a precise diff rather than writing garbage.
//
// The manifest is the small, authoritative subset the pump actually drives:
// `add_drawer` (write), `get_drawer` (verify), `list_drawers`/`search` if the
// pump enumerates. We assert NAME presence and REQUIRED-ARG presence, the two
// shape facts a faithful write depends on. We do NOT assert the full schema
// (optional args may be added freely; that is forward-compatible), only that
// every tool+required-arg the pump relies on still exists and that no NEW
// required arg appeared that the pump does not supply.

/// One tool the pump depends on, with the argument facts a faithful call
/// requires: the tool must exist, every `requiredArgs` entry must still be
/// required-or-accepted, and `suppliedArgs` is the set the pump actually
/// sends (so a newly-required arg outside this set is a breaking drift).
public struct PalaceExpectedTool: Sendable, Equatable {
    /// The MCP tool name (e.g. `mempalace_add_drawer`).
    public let name: String
    /// The arguments the pump treats as required — they must remain present
    /// in the live schema's required set (removal is breaking drift).
    public let requiredArgs: Set<String>
    /// Every argument the pump can supply for this tool. A live required arg
    /// outside this set is breaking drift (the pump cannot satisfy it).
    public let suppliedArgs: Set<String>

    public init(name: String, requiredArgs: Set<String>, suppliedArgs: Set<String>) {
        self.name = name
        self.requiredArgs = requiredArgs
        self.suppliedArgs = suppliedArgs
    }
}

/// The live shape of one tool as read from `tools/list`: its name and its
/// `inputSchema.required` set. Optional properties are not modeled — only the
/// two facts drift detection asserts.
public struct PalaceLiveTool: Sendable, Equatable {
    /// The live MCP tool name.
    public let name: String
    /// The live `inputSchema.required` argument names.
    public let requiredArgs: Set<String>

    public init(name: String, requiredArgs: Set<String>) {
        self.name = name
        self.requiredArgs = requiredArgs
    }

    /// Parse the live tools from a `tools/list` result's `tools` array (as a
    /// loosely-typed JSON value). Each entry contributes its `name` and its
    /// `inputSchema.required` (empty when absent). Tolerant of extra keys.
    public static func parse(toolsListJSON: Data) throws -> [PalaceLiveTool] {
        guard let root = try JSONSerialization.jsonObject(with: toolsListJSON) as? [String: Any],
              let tools = (root["tools"] ?? (root["result"] as? [String: Any])?["tools"]) as? [[String: Any]]
        else {
            throw PalaceDriftError.unreadableToolsList
        }
        return tools.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let schema = entry["inputSchema"] as? [String: Any]
            let required = Set((schema?["required"] as? [String])?.map { $0 } ?? [])
            return PalaceLiveTool(name: name, requiredArgs: required)
        }
    }
}

/// A single drift finding — what changed, named precisely so the operator can
/// see exactly which tool/arg moved.
public enum PalaceDriftFinding: Sendable, Equatable, CustomStringConvertible {
    /// An expected tool is absent from the live surface (renamed/removed).
    case toolMissing(name: String)
    /// An arg the pump treats as required is no longer in the live required
    /// set — the pump's assumptions about the tool no longer hold.
    case requiredArgRemoved(tool: String, arg: String)
    /// The live schema requires an arg the pump does not supply — the pump
    /// would write an incomplete call.
    case newRequiredArgUnsupplied(tool: String, arg: String)

    public var description: String {
        switch self {
        case .toolMissing(let name):
            return "tool '\(name)' is missing from the live MemPalace surface (renamed or removed)"
        case .requiredArgRemoved(let tool, let arg):
            return "tool '\(tool)' no longer requires '\(arg)' that the pump depends on"
        case .newRequiredArgUnsupplied(let tool, let arg):
            return "tool '\(tool)' now requires '\(arg)', which the pump does not supply"
        }
    }
}

/// Error surfaced when the tools/list payload itself cannot be read.
public enum PalaceDriftError: Error, Sendable, Equatable {
    case unreadableToolsList
}

/// Diffs the live MemPalace tool surface against the pump's expected manifest.
/// Pure and deterministic — the orchestrator does the `tools/list` I/O and
/// hands the parsed shapes here. No instances.
public enum PalaceDriftDetector {

    /// The manifest the pump is written against: every tool the canonical
    /// four-noun pump drives and the arg facts a faithful call depends on.
    /// Verified against the live mempalace-mcp surface (v3.3.3, 2026-06).
    ///
    /// Write tools (one per noun):
    ///   - `add_drawer` requires wing+room+content (optional source_file,
    ///     added_by).
    ///   - `create_tunnel` requires the four endpoint wing/room args (optional
    ///     drawer-id endpoints + label).
    ///   - `kg_add` requires subject+predicate+object (optional valid_from,
    ///     source_closet — the unbounded field the lossless envelope rides).
    ///   - `diary_write` requires agent_name+entry (optional topic, wing).
    /// Read / verify tools:
    ///   - `get_drawer` requires drawer_id (drawer round-trip by id).
    ///   - `list_tunnels` requires nothing (tunnel verify by listing a wing).
    ///   - `kg_query` requires entity (KG-fact verify by querying the subject).
    ///   - `diary_read` requires agent_name (diary verify by reading the agent).
    ///   - `list_drawers` / `search` are drawer enumeration surfaces.
    public static let expectedManifest: [PalaceExpectedTool] = [
        // --- write tools, one per noun ---
        PalaceExpectedTool(
            name: "mempalace_add_drawer",
            requiredArgs: ["wing", "room", "content"],
            suppliedArgs: ["wing", "room", "content", "source_file", "added_by"]
        ),
        PalaceExpectedTool(
            name: "mempalace_create_tunnel",
            requiredArgs: ["source_wing", "source_room", "target_wing", "target_room"],
            suppliedArgs: ["source_wing", "source_room", "target_wing", "target_room",
                           "source_drawer_id", "target_drawer_id", "label"]
        ),
        PalaceExpectedTool(
            name: "mempalace_kg_add",
            requiredArgs: ["subject", "predicate", "object"],
            suppliedArgs: ["subject", "predicate", "object", "valid_from", "source_closet"]
        ),
        PalaceExpectedTool(
            name: "mempalace_diary_write",
            requiredArgs: ["agent_name", "entry"],
            suppliedArgs: ["agent_name", "entry", "topic", "wing"]
        ),
        // --- read / verify tools ---
        PalaceExpectedTool(
            name: "mempalace_get_drawer",
            requiredArgs: ["drawer_id"],
            suppliedArgs: ["drawer_id"]
        ),
        PalaceExpectedTool(
            name: "mempalace_list_tunnels",
            requiredArgs: [],
            suppliedArgs: ["wing", "room", "limit", "offset"]
        ),
        PalaceExpectedTool(
            name: "mempalace_kg_query",
            requiredArgs: ["entity"],
            suppliedArgs: ["entity", "limit"]
        ),
        PalaceExpectedTool(
            name: "mempalace_diary_read",
            requiredArgs: ["agent_name"],
            suppliedArgs: ["agent_name", "topic", "limit"]
        ),
        PalaceExpectedTool(
            name: "mempalace_list_drawers",
            requiredArgs: [],
            suppliedArgs: ["wing", "room", "limit", "offset"]
        ),
        PalaceExpectedTool(
            name: "mempalace_search",
            requiredArgs: ["query"],
            suppliedArgs: ["query", "limit", "wing", "room", "max_distance", "context"]
        ),
    ]

    /// Diff the live tools against an expected manifest. Returns every
    /// finding, in a deterministic order (manifest order, then arg name).
    /// An empty result means the live surface satisfies the pump's
    /// assumptions and it is safe to write.
    ///
    /// - Parameters:
    ///   - live: the parsed live tools from `tools/list`.
    ///   - expected: the manifest to assert (defaults to
    ///     ``expectedManifest``).
    /// - Returns: the drift findings, empty when there is no breaking drift.
    public static func diff(
        live: [PalaceLiveTool],
        expected: [PalaceExpectedTool] = expectedManifest
    ) -> [PalaceDriftFinding] {
        var findings: [PalaceDriftFinding] = []
        let liveByName = Dictionary(uniqueKeysWithValues: live.map { ($0.name, $0) })
        for tool in expected {
            guard let liveTool = liveByName[tool.name] else {
                findings.append(.toolMissing(name: tool.name))
                continue
            }
            // A required arg the pump depends on must still be required.
            for arg in tool.requiredArgs.sorted() where !liveTool.requiredArgs.contains(arg) {
                findings.append(.requiredArgRemoved(tool: tool.name, arg: arg))
            }
            // A live required arg the pump cannot supply is breaking.
            for arg in liveTool.requiredArgs.sorted() where !tool.suppliedArgs.contains(arg) {
                findings.append(.newRequiredArgUnsupplied(tool: tool.name, arg: arg))
            }
        }
        return findings
    }
}
