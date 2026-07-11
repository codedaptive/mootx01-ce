// MemoryToolAdapter.swift
//
// M-MEMTOOL-1: Anthropic memory_20250818 tool adapter.
//
// Registers a single `memory` tool on the MCP surface that matches
// Anthropic's memory tool contract exactly. Six commands dispatch to
// existing ARIA estate verbs. See the journal entry for the full design.

import Foundation
import LocusKit
import GeniusLocusKit
import SubstrateTypes
import OSLog

private let memLog = Logger(subsystem: "com.mootx01.kit", category: "MemoryToolAdapter")

/// The dedicated wing for memory-tool-managed content.
private let memoryAdapterWing = "memories"
/// Maximum file content size (100 KB).
private let maxFileSize = 100 * 1024
/// Prefix marking adapter-managed drawers in sourceFile.
private let sourcePrefix = "memory-adapter:"
/// The virtual filesystem root.
private let memoriesRoot = "/memories"

// MARK: - Tool projection

extension ToolProjection {
    static func memoryTool() -> ProjectedTool {
        ProjectedTool(
            name: "memory",
            description: """
                Anthropic memory_20250818 compatible. Manages a virtual /memories \
                filesystem backed by the MOOTx01 estate with governance: audit \
                trail, lineage, sensitivity, confirmation state. Commands: view, \
                create, str_replace, insert, delete, rename.
                """,
            inputSchema: withEstateID(objectSchema(
                properties: [
                    "command": stringSchema("One of: view, create, str_replace, insert, delete, rename."),
                    "path": stringSchema("Virtual path under /memories."),
                    "file_text": stringSchema("File content for create."),
                    "old_str": stringSchema("Text to find for str_replace."),
                    "new_str": stringSchema("Replacement text for str_replace. Omit to delete old_str."),
                    "view_range": stringSchema("Optional 'start,end' for view line range. Use -1 for EOF."),
                    "insert_line": integerSchema("Line number after which to insert (0 = beginning)."),
                    "insert_text": stringSchema("Text to insert."),
                    "old_path": stringSchema("Source path for rename."),
                    "new_path": stringSchema("Destination path for rename."),
                ],
                required: ["command"]
            )),
            provenance: .interface
        )
    }
}

// MARK: - Dispatch

extension ToolDispatcher {

    func runMemoryTool(_ args: [String: JSONValue]) async throws -> JSONValue {
        guard case .string(let command) = args["command"] else {
            return Self.textResult("Error: missing or invalid 'command' parameter")
        }
        switch command {
        case "view":        return try await memoryView(args)
        case "create":      return try await memoryCreate(args)
        case "str_replace": return try await memoryStrReplace(args)
        case "insert":      return try await memoryInsert(args)
        case "delete":      return try await memoryDelete(args)
        case "rename":      return try await memoryRename(args)
        default:
            return Self.textResult("Error: unknown command \(command)")
        }
    }

    // MARK: - Path helpers

    private func validateMemPath(_ args: [String: JSONValue], key: String = "path") throws -> String {
        guard case .string(let path) = args[key] else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams, message: "Missing '\(key)' parameter")
        }
        let lower = path.lowercased()
        if lower.contains("%2e") || lower.contains("%2f") {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams, message: "URL-encoded traversal in path: \(path)")
        }
        if path.contains("..") {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams, message: "Path traversal detected: \(path)")
        }
        guard path.hasPrefix(memoriesRoot) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams, message: "Path must start with \(memoriesRoot): \(path)")
        }
        return path
    }

    private func memPathToRoom(_ path: String) -> String {
        let relative = String(path.dropFirst(memoriesRoot.count + 1))
        let parts = relative.split(separator: "/")
        if parts.count <= 1 { return "root" }
        return parts.dropLast().joined(separator: "/")
    }

    /// Convert a path to a unique room name for the adapter wing.
    /// /memories/foo.txt → "foo.txt", /memories/sub/bar.txt → "sub/bar.txt"
    private func memRoomForPath(_ path: String) -> String {
        let relative = String(path.dropFirst(memoriesRoot.count + 1))
        return relative.isEmpty ? "root" : relative
    }

    /// Sensitivity gate for the `memory` surface: only Normal-tier drawers
    /// (adjective sensitivity `.normal` / `.elevated`) are visible. `memory`
    /// is a bulk, path-addressed read/write surface with no grant ceremony,
    /// so it matches BitmapEvaluator's default no-claims recall posture
    /// (`.sensitivityAtMost(.elevated)`, ADR-007 Decision 2): `.restricted`
    /// and `.secret` drawers neither list nor resolve here. The adjective
    /// axis is the access-gate-relevant tier (spec § 7.9.2) — the provenance
    /// sensitivity axis is deliberately NOT consulted. Mirrors
    /// `drawer_visible_to_adapter` in the Rust memory_adapter.rs.
    private func isMemoryAdapterVisible(_ drawer: Drawer) -> Bool {
        drawer.tombstonedAt == nil && !drawer.isKnewPast && !drawer.isTerminal
            && drawer.adjectiveSensitivity.isBulkExportable
    }

    /// Find an active, normally recallable drawer by wing="memories" + room
    /// matching the path.
    private func findMemDrawer(_ path: String) async throws -> Drawer? {
        let room = memRoomForPath(path)
        let estate = try await kit.estate(for: handle)
        let all = try await estate.allDrawers(hydrationLevel: .full, limit: nil)
        let nodeNames = try await estate.resolveNodeNames(parentNodeIds: all.map(\.parentNodeId))
        return all.first {
            isMemoryAdapterVisible($0)
            && nodeNames[$0.parentNodeId]?.wing == memoryAdapterWing
            && nodeNames[$0.parentNodeId]?.room == room
        }
    }

    /// List all active, normally recallable drawers in the adapter wing.
    private func listMemDrawers() async throws -> [(drawer: Drawer, room: String)] {
        let estate = try await kit.estate(for: handle)
        let all = try await estate.allDrawers(hydrationLevel: .structured, limit: nil)
        let nodeNames = try await estate.resolveNodeNames(parentNodeIds: all.map(\.parentNodeId))
        return all.compactMap { d -> (Drawer, String)? in
            guard isMemoryAdapterVisible(d),
                  let names = nodeNames[d.parentNodeId],
                  names.wing == memoryAdapterWing
            else { return nil }
            return (d, names.room)
        }
    }

    /// Reconstruct virtual path from a drawer's room name.
    private func memVPathFromRoom(_ room: String) -> String {
        return "\(memoriesRoot)/\(room)"
    }

    // MARK: - Commands

    private func memoryView(_ args: [String: JSONValue]) async throws -> JSONValue {
        let path = try validateMemPath(args)

        // Directory view.
        if path == memoriesRoot || path == memoriesRoot + "/" {
            let drawers = try await listMemDrawers()
            var listing = ["4.0K\t\(memoriesRoot)"]
            var seenDirs: Set<String> = []
            for (_, room) in drawers {
                let vp = memVPathFromRoom(room)
                listing.append("1.0K\t\(vp)")
                let parts = vp.dropFirst(memoriesRoot.count + 1).split(separator: "/")
                if parts.count > 1 {
                    let parent = "\(memoriesRoot)/\(parts[0])"
                    if seenDirs.insert(parent).inserted {
                        listing.insert("4.0K\t\(parent)", at: 1)
                    }
                }
            }
            return Self.textResult(
                "Here're the files and directories up to 2 levels deep in \(path), "
                + "excluding hidden items and node_modules:\n"
                + listing.joined(separator: "\n"))
        }

        // File view.
        guard let drawer = try await findMemDrawer(path) else {
            // Subdirectory?
            let drawers = try await listMemDrawers()
            let prefix = path.hasSuffix("/") ? path : path + "/"
            let children = drawers.filter { memVPathFromRoom($0.room).hasPrefix(prefix) }
            if !children.isEmpty {
                var listing = ["4.0K\t\(path)"]
                for c in children { listing.append("1.0K\t\(memVPathFromRoom(c.room))") }
                return Self.textResult(
                    "Here're the files and directories up to 2 levels deep in \(path), "
                    + "excluding hidden items and node_modules:\n"
                    + listing.joined(separator: "\n"))
            }
            return Self.textResult("The path \(path) does not exist. Please provide a valid path.")
        }

        var lines = drawer.content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var startOffset = 1

        // view_range: passed as "start,end" string or array.
        if case .string(let rangeStr) = args["view_range"] {
            let parts = rangeStr.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2 {
                let s = max(1, parts[0])
                let e = parts[1] == -1 ? lines.count : min(parts[1], lines.count)
                lines = Array(lines[(s - 1)..<e])
                startOffset = s
            }
        } else if case .array(let arr) = args["view_range"], arr.count == 2 {
            let s: Int, e: Int
            if case .integer(let sv) = arr[0] { s = max(1, Int(sv)) } else { s = 1 }
            if case .integer(let ev) = arr[1] { e = Int(ev) == -1 ? lines.count : min(Int(ev), lines.count) } else { e = lines.count }
            lines = Array(lines[(s - 1)..<e])
            startOffset = s
        }

        if lines.count > 999_999 {
            return Self.textResult("File \(path) exceeds maximum line limit of 999,999 lines.")
        }

        let numbered = lines.enumerated().map { i, line in
            String(format: "%6d\t%@", i + startOffset, line)
        }
        return Self.textResult(
            "Here's the content of \(path) with line numbers:\n" + numbered.joined(separator: "\n"))
    }

    private func memoryCreate(_ args: [String: JSONValue]) async throws -> JSONValue {
        let path = try validateMemPath(args)
        guard case .string(let fileText) = args["file_text"] else {
            return Self.textResult("Error: missing 'file_text' parameter")
        }
        if fileText.utf8.count > maxFileSize {
            return Self.textResult("Error: File content exceeds maximum size of \(maxFileSize) bytes")
        }
        if let _ = try await findMemDrawer(path) {
            return Self.textResult("Error: File \(path) already exists")
        }

        let room = memRoomForPath(path)
        let frame = CaptureFrame(
            content: fileText,
            channel: .actuator,
            room: room,
            latticeAnchor: .udc("000"),
            addedBy: serverIdentity,
            embeddingModelID: "fdc-simhash-v1",
            sensitivity: .normal,
            provenanceChannel: .mcpAgent,
            sourceType: .imported,
            wing: memoryAdapterWing
        )
        _ = try await kit.capture(handle, frame, mode: .regular)
        memLog.info("memory create: \(path, privacy: .public)")
        return Self.textResult("File created successfully at: \(path)")
    }

    private func memoryStrReplace(_ args: [String: JSONValue]) async throws -> JSONValue {
        let path = try validateMemPath(args)
        guard case .string(let oldStr) = args["old_str"] else {
            return Self.textResult("Error: missing 'old_str' parameter")
        }
        let newStr: String
        if case .string(let s) = args["new_str"] { newStr = s } else { newStr = "" }

        guard let drawer = try await findMemDrawer(path) else {
            return Self.textResult("Error: The path \(path) does not exist. Please provide a valid path.")
        }
        let content = drawer.content
        guard content.contains(oldStr) else {
            return Self.textResult(
                "No replacement was performed, old_str `\(oldStr)` did not appear verbatim in \(path).")
        }
        let occurrences = content.components(separatedBy: oldStr).count - 1
        if occurrences > 1 {
            let lineNums = content.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated().filter { $0.element.contains(oldStr) }
                .map { String($0.offset + 1) }
            return Self.textResult(
                "No replacement was performed. Multiple occurrences of old_str "
                + "`\(oldStr)` in lines: \(lineNums.joined(separator: ", ")). "
                + "Please ensure it is unique")
        }

        let newContent = content.replacingOccurrences(of: oldStr, with: newStr)
        let room = memRoomForPath(path)
        let frame = CaptureFrame(
            content: newContent,
            channel: .actuator,
            room: room,
            latticeAnchor: .udc("000"),
            addedBy: serverIdentity,
            embeddingModelID: "fdc-simhash-v1",
            // Carry the source drawer's tier forward — a re-capture with a
            // hardcoded .normal silently DOWNGRADED elevated drawers on edit.
            sensitivity: drawer.adjectiveSensitivity,
            provenanceChannel: .mcpAgent,
            sourceType: .imported,
            wing: memoryAdapterWing
        )
        _ = try await kit.capture(handle, frame, mode: .regular)
        try await kit.withdraw(handle, WithdrawFrame(rowID: drawer.id, reason: "memory str_replace supersession"))
        memLog.info("memory str_replace: \(path, privacy: .public)")
        return Self.textResult("The memory file has been edited.")
    }

    private func memoryInsert(_ args: [String: JSONValue]) async throws -> JSONValue {
        let path = try validateMemPath(args)
        guard case .integer(let insertLineNum) = args["insert_line"] else {
            return Self.textResult("Error: missing 'insert_line' parameter")
        }
        let insertLine = Int(insertLineNum)
        guard case .string(let insertText) = args["insert_text"] else {
            return Self.textResult("Error: missing 'insert_text' parameter")
        }

        guard let drawer = try await findMemDrawer(path) else {
            return Self.textResult("Error: The path \(path) does not exist")
        }

        var lines = drawer.content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if insertLine < 0 || insertLine > lines.count {
            return Self.textResult(
                "Error: Invalid `insert_line` parameter: \(insertLine). "
                + "It should be within the range of lines of the file: [0, \(lines.count)]")
        }

        let newLines = insertText.hasSuffix("\n")
            ? String(insertText.dropLast()).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            : insertText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.insert(contentsOf: newLines, at: insertLine)
        let newContent = lines.joined(separator: "\n")

        let room = memRoomForPath(path)
        let frame = CaptureFrame(
            content: newContent,
            channel: .actuator,
            room: room,
            latticeAnchor: .udc("000"),
            addedBy: serverIdentity,
            embeddingModelID: "fdc-simhash-v1",
            // Carry the source drawer's tier forward — a re-capture with a
            // hardcoded .normal silently DOWNGRADED elevated drawers on edit.
            sensitivity: drawer.adjectiveSensitivity,
            provenanceChannel: .mcpAgent,
            sourceType: .imported,
            wing: memoryAdapterWing
        )
        _ = try await kit.capture(handle, frame, mode: .regular)
        try await kit.withdraw(handle, WithdrawFrame(rowID: drawer.id, reason: "memory insert supersession"))
        memLog.info("memory insert: \(path, privacy: .public)")
        return Self.textResult("The file \(path) has been edited.")
    }

    private func memoryDelete(_ args: [String: JSONValue]) async throws -> JSONValue {
        let path = try validateMemPath(args)
        if path == memoriesRoot || path == memoriesRoot + "/" {
            return Self.textResult("Error: Cannot delete the memory root directory")
        }

        if let drawer = try await findMemDrawer(path) {
            try await kit.withdraw(handle, WithdrawFrame(rowID: drawer.id, reason: "memory delete: \(path)"))
            memLog.info("memory delete: \(path, privacy: .public)")
            return Self.textResult("Successfully deleted \(path)")
        }

        // Recursive directory delete.
        let drawers = try await listMemDrawers()
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let children = drawers.filter { memVPathFromRoom($0.room).hasPrefix(prefix) }
        if children.isEmpty {
            return Self.textResult("Error: The path \(path) does not exist")
        }
        for child in children {
            try await kit.withdraw(handle, WithdrawFrame(rowID: child.drawer.id, reason: "memory delete (recursive): \(path)"))
        }
        memLog.info("memory delete (recursive): \(path, privacy: .public) — \(children.count) drawers")
        return Self.textResult("Successfully deleted \(path)")
    }

    private func memoryRename(_ args: [String: JSONValue]) async throws -> JSONValue {
        let oldPath = try validateMemPath(args, key: "old_path")
        let newPath = try validateMemPath(args, key: "new_path")

        if oldPath == memoriesRoot {
            return Self.textResult("Error: Cannot rename the memory root directory")
        }
        guard let drawer = try await findMemDrawer(oldPath) else {
            return Self.textResult("Error: The path \(oldPath) does not exist")
        }
        if let _ = try await findMemDrawer(newPath) {
            return Self.textResult("Error: The destination \(newPath) already exists")
        }

        // Supersede with new path: capture same content under new room, withdraw old.
        let newRoom = memRoomForPath(newPath)
        let frame = CaptureFrame(
            content: drawer.content,
            channel: .actuator,
            room: newRoom,
            latticeAnchor: .udc("000"),
            addedBy: serverIdentity,
            embeddingModelID: "fdc-simhash-v1",
            // Carry the source drawer's tier forward — a re-capture with a
            // hardcoded .normal silently DOWNGRADED elevated drawers on edit.
            sensitivity: drawer.adjectiveSensitivity,
            provenanceChannel: .mcpAgent,
            sourceType: .imported,
            wing: memoryAdapterWing
        )
        _ = try await kit.capture(handle, frame, mode: .regular)
        try await kit.withdraw(handle, WithdrawFrame(rowID: drawer.id, reason: "memory rename: \(oldPath) → \(newPath)"))
        memLog.info("memory rename: \(oldPath, privacy: .public) → \(newPath, privacy: .public)")
        return Self.textResult("Successfully renamed \(oldPath) to \(newPath)")
    }
}
