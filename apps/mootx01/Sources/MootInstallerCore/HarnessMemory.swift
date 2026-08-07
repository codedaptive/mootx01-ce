// HarnessMemory.swift
//
// Harness Memory Mode — routes Claude Code project memories into the
// MOOTx01 estate instead of writing to ~/.claude/projects/*/memory/.
//
// Enabling (`mootx01 enable harness-memory`) performs three changes:
//   (a) Disables Claude Code's harness auto-memory: sets "autoMemoryEnabled": false
//       in ~/.claude/settings.json. Verified key per recon 2026-08-07;
//       env alternative: CLAUDE_CODE_DISABLE_AUTO_MEMORY=1.
//   (b) Installs a PreToolUse hook that intercepts Write/Edit/MultiEdit targeting
//       ~/.claude/projects/*/memory/* — the hook POSTs the write body to the
//       estate daemon and denies the disk write with a teaching message. If the
//       daemon is unreachable it allows the write (losing the memory is worse
//       than a temporary stray file; re-running enable sweeps stragglers).
//   (c) Merges a sentinel-marked block into ~/.claude/CLAUDE.md so every
//       session knows to use moot_file_memory / moot_memory_search directly.
//
// Disabling reverses (a)-(c) and offers to restore estate memories back to disk.
//
// Public surface:
//   HarnessMemoryPaths     — URLs for hook dir, CLAUDE.md, projects root
//   HarnessMemorySettings  — settings.json hook + auto-memory merge/remove (pure)
//   HarnessMemoryCLAUDE    — CLAUDE.md sentinel block merge/remove (pure)
//   HarnessMemoryHook      — hook script content + install/remove
//   DaemonClient           — protocol for estate HTTP calls (mockable in tests)
//   HarnessMemoryRecord    — estate memory record returned by list queries
//   LiveDaemonClient       — live JSON-RPC 2.0 over HTTP implementation
//   DaemonError            — errors from daemon communication
//   IngestResult           — per-file outcome from the ingest walker
//   RestoreResult          — per-file outcome from restore on disable
//   HarnessMemoryIngest    — ingest walker: file → confirm write → delete source
//   HarnessMemoryRestore   — restore: estate → disk, mark estate records superseded
//
// Observability emit points (MXE-HM-2: ObserverSink wiring out of scope for
// this mission; names reserved here so the follow-up wires without archaeology):
//   harness.capture.count         — captures by hook-capture command per session
//   harness.ingest.filed.count    — memories filed during ingest walker
//   harness.ingest.removed.count  — source files removed after confirmed write
//   harness.restore.count         — files written back to disk on disable
//   harness.revive.count          — existing drawers revived unchanged on re-enable
//   harness.hook.fire.rate        — hook fire rate over time (teaching-decay curve)

import Foundation
import os

private let log = Logger(subsystem: "com.mootx01.kit", category: "HarnessMemory")

// MARK: - Paths

/// Path constants for harness-memory feature files.
/// All functions are pure path math — no filesystem access.
public enum HarnessMemoryPaths {

    /// Directory where the capture hook script lives.
    /// (`<home>/.mootx01/hooks/`)
    public static func hooksDirURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".mootx01", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
    }

    /// Absolute path of the capture hook shell script.
    /// (`<home>/.mootx01/hooks/capture-harness-memory.sh`)
    public static func hookScriptURL(homeDirectory: URL) -> URL {
        hooksDirURL(homeDirectory: homeDirectory)
            .appendingPathComponent("capture-harness-memory.sh", isDirectory: false)
    }

    /// `~/.claude/CLAUDE.md` — the global Claude Code instructions file
    /// where the memory-governance sentinel block is merged.
    public static func globalCLAUDEMDURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("CLAUDE.md", isDirectory: false)
    }

    /// `~/.claude/projects/` — root of Claude Code per-project data directories.
    public static func claudeProjectsURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }
}

// MARK: - Settings.json merge / remove

/// Pure functions for merging and removing harness-memory entries from
/// `~/.claude/settings.json`. No side effects beyond file I/O; pure in the
/// sense that the merge logic itself (hasHookEntry, addHookEntry, removeHookEntry)
/// operates on in-memory dictionaries — filesystem calls are isolated to
/// `enable(settingsURL:homeDirectory:)` and `disable(settingsURL:homeDirectory:)`.
public enum HarnessMemorySettings {

    /// The settings.json key that disables Claude Code harness auto-memory.
    /// Value: false. Verified against Claude Code documentation, 2026-08-07.
    /// Env alternative: CLAUDE_CODE_DISABLE_AUTO_MEMORY=1.
    public static let autoMemoryKey = "autoMemoryEnabled"

    /// Absolute path of the hook script, used as the identity key for
    /// our hook entry. An entry is "ours" iff its `command` equals this path.
    public static func hookCommandPath(homeDirectory: URL) -> String {
        HarnessMemoryPaths.hookScriptURL(homeDirectory: homeDirectory).path
    }

    /// Merge harness-memory settings into the settings file at `settingsURL`.
    /// Creates the file if absent; backs up to `settings.json.mootx01-bak-<ISO8601>`
    /// before any write. Idempotent: a second call with the same state returns
    /// `false` (no writes performed).
    ///
    /// Changes applied:
    ///   1. `"autoMemoryEnabled": false` — disables harness auto-memory.
    ///   2. A dedicated PreToolUse hook matcher-group (identified by command path).
    ///
    /// - Returns: true if the settings file was actually changed.
    @discardableResult
    public static func enable(settingsURL: URL, homeDirectory: URL) throws -> Bool {
        let hookPath = hookCommandPath(homeDirectory: homeDirectory)
        var root = try readSettings(at: settingsURL)

        // Snapshot: check before touching anything.
        let alreadyDisabled = root[autoMemoryKey] as? Bool == false
        let hookPresent = hasHookEntry(in: root, commandPath: hookPath)
        guard !alreadyDisabled || !hookPresent else { return false }

        // Back up before the first write.
        try backupIfPresent(settingsURL: settingsURL)

        if !alreadyDisabled {
            root[autoMemoryKey] = false
        }
        if !hookPresent {
            root = addHookEntry(to: root, commandPath: hookPath)
        }

        try writeSettings(root, to: settingsURL)
        return true
    }

    /// Remove harness-memory entries from the settings file at `settingsURL`.
    /// Idempotent: if neither entry is present, returns `false`.
    ///
    /// Reverses `enable`:
    ///   1. Removes `"autoMemoryEnabled"` (absent key = Claude Code default = enabled).
    ///   2. Removes our PreToolUse hook matcher-group only (other groups untouched).
    ///
    /// - Returns: true if the settings file was actually changed.
    @discardableResult
    public static func disable(settingsURL: URL, homeDirectory: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return false }
        let hookPath = hookCommandPath(homeDirectory: homeDirectory)
        var root = try readSettings(at: settingsURL)

        let autoMemoryPresent = root[autoMemoryKey] != nil
        let hookPresent = hasHookEntry(in: root, commandPath: hookPath)
        guard autoMemoryPresent || hookPresent else { return false }

        if autoMemoryPresent { root.removeValue(forKey: autoMemoryKey) }
        if hookPresent { root = removeHookEntry(from: root, commandPath: hookPath) }

        try writeSettings(root, to: settingsURL)
        return true
    }

    // MARK: - Pure merge logic (internal for tests via @testable import)

    /// Returns true if our hook entry (identified by `commandPath`) is already
    /// present in the settings dictionary's `hooks.PreToolUse` array.
    static func hasHookEntry(in settings: [String: Any], commandPath: String) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any],
              let preToolUse = hooks["PreToolUse"] as? [[String: Any]] else {
            return false
        }
        return preToolUse.contains { group in
            guard let innerHooks = group["hooks"] as? [[String: Any]] else { return false }
            return innerHooks.contains { $0["command"] as? String == commandPath }
        }
    }

    /// Return a new settings dictionary with our dedicated matcher-group appended
    /// to `hooks.PreToolUse`. Hook entry shape per Claude Code documentation
    /// (recon 2026-08-07): matcher is a pipe-separated string of exact tool names.
    static func addHookEntry(to root: [String: Any], commandPath: String) -> [String: Any] {
        var result = root
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []

        // Our dedicated matcher-group. Identified on removal by the command path.
        let entry: [String: Any] = [
            "matcher": "Write|Edit|MultiEdit",
            "hooks": [
                ["type": "command", "command": commandPath] as [String: Any]
            ]
        ]
        preToolUse.append(entry)
        hooks["PreToolUse"] = preToolUse
        result["hooks"] = hooks
        return result
    }

    /// Return a new settings dictionary with our matcher-group removed from
    /// `hooks.PreToolUse`. Other groups — including any groups we didn't add —
    /// are preserved exactly. Cleans up empty `PreToolUse` and `hooks` keys.
    static func removeHookEntry(from root: [String: Any], commandPath: String) -> [String: Any] {
        var result = root
        guard var hooks = root["hooks"] as? [String: Any],
              var preToolUse = hooks["PreToolUse"] as? [[String: Any]] else {
            return root
        }

        preToolUse = preToolUse.filter { group in
            guard let innerHooks = group["hooks"] as? [[String: Any]] else { return true }
            // A group is "ours" when it contains our command. If it also contains
            // other commands (unlikely but possible for a manually-edited file),
            // we still remove the whole group — the discriminating signal is the
            // hook command path, not the matcher string.
            return !innerHooks.contains { $0["command"] as? String == commandPath }
        }

        if preToolUse.isEmpty {
            hooks.removeValue(forKey: "PreToolUse")
        } else {
            hooks["PreToolUse"] = preToolUse
        }

        if hooks.isEmpty {
            result.removeValue(forKey: "hooks")
        } else {
            result["hooks"] = hooks
        }
        return result
    }

    // MARK: - File I/O

    /// Back up `settingsURL` to `<path>.mootx01-bak-<ISO8601>` if it exists.
    /// The backup timestamp uses seconds precision in UTC — readable and sortable.
    static func backupIfPresent(settingsURL: URL) throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        // Replace colons in timestamp: some filesystems don't support colon in names.
        let stamp = fmt.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("\(settingsURL.lastPathComponent).mootx01-bak-\(stamp)")
        try FileManager.default.copyItem(at: settingsURL, to: backupURL)
    }

    static func readSettings(at settingsURL: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL).strippingLeadingUTF8BOM
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func writeSettings(_ root: [String: Any], to settingsURL: URL) throws {
        let dir = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: settingsURL, options: .atomic)
    }
}

// MARK: - CLAUDE.md sentinel block

/// Pure functions for merging and removing the memory-governance block from
/// `~/.claude/CLAUDE.md`. The block is delimited by sentinel HTML comments
/// so disable removes exactly our content and nothing else.
public enum HarnessMemoryCLAUDE {

    // Sentinel markers — HTML comments that are visible to language models but
    // do not render in Markdown previews. These are the removal key for disable.
    static let beginMarker = "<!-- mootx01:harness-memory:begin -->"
    static let endMarker   = "<!-- mootx01:harness-memory:end -->"

    /// The block content injected into CLAUDE.md.
    /// Uses explicit variable interpolation to ensure the markers are canonical.
    static var block: String {
        """

        \(beginMarker)
        # Memory Governance — MOOTx01 Harness Memory Mode

        File memories with `moot_file_memory` (location: `harness/<project>/<name>`) and recall
        them with `moot_memory_search` / `moot_recall_*`. Do NOT write markdown files to
        `~/.claude/projects/*/memory/` — those writes are intercepted and routed to the estate.

        The estate provides semantic recall, temporal grading, contradiction hunting, and
        cross-session linking that the flat project-memory directory never had.
        \(endMarker)
        """
    }

    // MARK: - Pure string transforms

    /// Returns true if our sentinel block is already present in `content`.
    public static func hasBlock(in content: String) -> Bool {
        content.contains(beginMarker)
    }

    /// Return `content` with our sentinel block appended.
    /// Idempotent: if the block is already present, returns `content` unchanged.
    public static func mergeBlock(into content: String) -> String {
        guard !hasBlock(in: content) else { return content }
        return content + block
    }

    /// Return `content` with our sentinel block removed.
    /// Removes from the newline before `beginMarker` through to the line
    /// containing `endMarker` (inclusive). If the block is absent, returns
    /// `content` unchanged.
    public static func removeBlock(from content: String) -> String {
        guard hasBlock(in: content),
              let beginRange = content.range(of: beginMarker),
              let endRange = content.range(of: endMarker) else {
            return content
        }

        // Extend begin backward to include the leading newline (part of `block`).
        var removeStart = beginRange.lowerBound
        if removeStart > content.startIndex {
            let prev = content.index(before: removeStart)
            if content[prev].isNewline {
                removeStart = prev
            }
        }

        // Extend end forward past the trailing newline, if any.
        var removeEnd = endRange.upperBound
        if removeEnd < content.endIndex, content[removeEnd].isNewline {
            removeEnd = content.index(after: removeEnd)
        }

        var result = content
        result.removeSubrange(removeStart..<removeEnd)
        return result
    }

    // MARK: - File I/O

    /// Merge block into the CLAUDE.md at `url`, creating the file and its
    /// parent directory if absent. No-op if block is already present.
    public static func enable(at url: URL) throws {
        let existing: String
        if FileManager.default.fileExists(atPath: url.path) {
            existing = try String(contentsOf: url, encoding: .utf8)
        } else {
            existing = ""
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        let updated = mergeBlock(into: existing)
        guard updated != existing else { return }
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Remove our sentinel block from the CLAUDE.md at `url`.
    /// No-op if the file is absent or the block is not present.
    public static func disable(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let existing = try String(contentsOf: url, encoding: .utf8)
        let updated = removeBlock(from: existing)
        guard updated != existing else { return }
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Hook script

/// Hook script installation. The script is a thin shim that delegates all
/// logic to `mootx01 hook-capture` — no interpreter assumption (python3,
/// jq, etc.) because the mootx01 binary is the only guaranteed runtime
/// in the hook environment.
public enum HarnessMemoryHook {

    /// Shell script content for the capture hook.
    /// - Parameter binaryPath: absolute path to the installed `mootx01` binary.
    public static func scriptContent(binaryPath: String) -> String {
        // Quotes around binaryPath handle spaces in the home directory path.
        """
        #!/bin/sh
        # capture-harness-memory.sh
        # Installed by: mootx01 enable harness-memory
        # Re-generated on each enable — do not edit manually.
        #
        # Reads Claude Code PreToolUse JSON from stdin. If the target path is
        # inside ~/.claude/projects/*/memory/*, captures the write body into the
        # MOOTx01 estate and denies the disk write with a teaching message.
        # If the estate daemon is unreachable, allows the write so the session
        # is not blocked; mootx01 enable harness-memory re-runs the ingest
        # sweep to move any stragglers into the estate later.
        exec "\(binaryPath)" hook-capture
        """
    }

    /// Write the hook script to `url`, creating parent directories and
    /// marking the file executable (mode 0755).
    public static func install(at url: URL, binaryPath: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let content = scriptContent(binaryPath: binaryPath)
        try content.write(to: url, atomically: true, encoding: .utf8)
        // chmod +x: posixPermissions 0o755 = rwxr-xr-x
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755 as NSNumber],
            ofItemAtPath: url.path
        )
    }

    /// Remove the hook script. No-op if the file does not exist.
    public static func remove(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

// MARK: - Daemon client protocol

/// A memory record retrieved from the estate.
public struct HarnessMemoryRecord: Sendable {
    public let id: String
    public let location: String
    public let content: String
    public let eventTime: Date
    public let isSuperseded: Bool

    public init(
        id: String,
        location: String,
        content: String,
        eventTime: Date,
        isSuperseded: Bool
    ) {
        self.id = id
        self.location = location
        self.content = content
        self.eventTime = eventTime
        self.isSuperseded = isSuperseded
    }
}

/// Abstraction over the estate MCP HTTP transport.
/// The live implementation posts JSON-RPC 2.0 to `http://127.0.0.1:4242`.
/// Tests inject a mock that records calls and returns preset responses without
/// a running daemon.
public protocol DaemonClient: Sendable {
    /// File a memory with the estate. Returns true if the write was confirmed.
    /// - Parameters:
    ///   - location: location hint, e.g. `harness/<slug>/<name>` or
    ///     `harness-import/<slug>/<name>`.
    ///   - content: verbatim file body (byte-exact for restore round-trips).
    ///   - eventTime: temporal anchor; for ingest this is the file mtime.
    ///   - kind: optional content kind hint (`"list"` for MEMORY.md index files).
    func fileMemory(location: String, content: String, eventTime: Date, kind: String?) async throws -> Bool

    /// List estate memories whose location begins with `prefix`.
    /// Returns active (non-superseded) AND superseded records; callers filter
    /// by `isSuperseded` based on their use-case (ingest checks superseded for
    /// revive; restore lists only active).
    func listMemories(locationPrefix: String) async throws -> [HarnessMemoryRecord]

    /// Apply a mutation to an existing estate record.
    /// - Parameters:
    ///   - id: the estate drawer ID.
    ///   - mutation: one of `"supersede"` or `"revive"`.
    ///   - note: human-readable rationale appended to the estate audit trail.
    func updateMemory(id: String, mutation: String, note: String) async throws

    /// Quick liveness check. Returns true if the daemon responded within the
    /// client's configured timeout; false on any network or timeout error.
    func ping() async -> Bool
}

/// Errors surfaced by `LiveDaemonClient`.
public enum DaemonError: Error, Sendable {
    /// The HTTP response status code was not 200.
    case httpError(Int)
    /// The response body could not be decoded as JSON-RPC 2.0.
    case parseError
    /// The JSON-RPC response contained an error object.
    case rpcError(String)
}

/// Live implementation of `DaemonClient` that POSTs JSON-RPC 2.0 requests
/// to the resident daemon at `http://127.0.0.1:<port>`.
///
/// Call shape per recon 2026-08-07:
/// ```json
/// { "jsonrpc": "2.0", "id": 1, "method": "tools/call",
///   "params": { "name": "<tool>", "arguments": { ... } } }
/// ```
public struct LiveDaemonClient: DaemonClient {
    private let baseURL: URL
    private let session: URLSession

    /// - Parameter port: the daemon's HTTP port (defaults to `MootPaths.defaultResidentPort`).
    ///
    /// General-purpose initializer: 5s request / 10s resource timeouts, appropriate
    /// for ingest, restore, and enable/disable paths where long lens calls are possible.
    public init(port: Int = MootPaths.defaultResidentPort) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config)
    }

    /// Hook-path initializer: caller-specified timeouts.
    ///
    /// The in-session PreToolUse hook MUST NOT freeze Claude Code while waiting
    /// for a slow or unreachable daemon. Use `timeoutIntervalForRequest: 1,
    /// timeoutIntervalForResource: 2` for hook-capture. The general init keeps
    /// 5/10s for ingest/restore/enable paths where long lens calls are possible.
    public init(
        port: Int,
        timeoutIntervalForRequest: Double,
        timeoutIntervalForResource: Double
    ) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutIntervalForRequest
        config.timeoutIntervalForResource = timeoutIntervalForResource
        self.session = URLSession(configuration: config)
    }

    public func fileMemory(
        location: String,
        content: String,
        eventTime: Date,
        kind: String?
    ) async throws -> Bool {
        var arguments: [String: Any] = [
            "location": location,
            "content": content,
            "event_time": formatISO8601(eventTime),
        ]
        if let kind { arguments["kind"] = kind }
        return try await callTool("moot_file_memory", arguments: arguments) != nil
    }

    public func listMemories(locationPrefix: String) async throws -> [HarnessMemoryRecord] {
        // moot_memory_list with a location_prefix filter to scope results.
        // Parameter name inferred from the estate's query conventions.
        let arguments: [String: Any] = ["location_prefix": locationPrefix]
        guard let result = try await callTool("moot_memory_list", arguments: arguments) else {
            return []
        }
        return parseMemoryRecords(from: result)
    }

    public func updateMemory(id: String, mutation: String, note: String) async throws {
        let arguments: [String: Any] = ["id": id, "mutation": mutation, "note": note]
        _ = try await callTool("moot_update_memory", arguments: arguments)
    }

    public func ping() async -> Bool {
        return (try? await callTool("moot_estate_ping", arguments: [:])) != nil
    }

    // MARK: - JSON-RPC

    @discardableResult
    private func callTool(_ name: String, arguments: [String: Any]) async throws -> Any? {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": name, "arguments": arguments] as [String: Any],
        ]
        let requestData = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestData

        let (responseData, httpResponse) = try await session.data(for: request)
        guard let http = httpResponse as? HTTPURLResponse, http.statusCode == 200 else {
            throw DaemonError.httpError((httpResponse as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw DaemonError.parseError
        }
        if let error = json["error"] {
            let msg = (error as? [String: Any])?["message"] as? String ?? String(describing: error)
            throw DaemonError.rpcError(msg)
        }
        return json["result"]
    }

    private func parseMemoryRecords(from result: Any) -> [HarnessMemoryRecord] {
        // Expected estate response shape: { "memories": [{ "id": "...",
        // "location": "...", "content": "...", "event_time": "...",
        // "superseded": bool }, ...] }
        guard let obj = result as? [String: Any],
              let array = obj["memories"] as? [[String: Any]] else {
            return []
        }
        return array.compactMap { item -> HarnessMemoryRecord? in
            guard let id       = item["id"] as? String,
                  let location = item["location"] as? String,
                  let content  = item["content"] as? String,
                  let timeStr  = item["event_time"] as? String,
                  let eventTime = parseISO8601(timeStr) else {
                return nil
            }
            return HarnessMemoryRecord(
                id: id, location: location, content: content,
                eventTime: eventTime,
                isSuperseded: item["superseded"] as? Bool ?? false
            )
        }
    }

    // MARK: - Date helpers

    private func formatISO8601(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: date)
    }

    private func parseISO8601(_ string: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: string) { return d }
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: string)
    }
}

// MARK: - Path matching (hook-capture)

/// Pattern matching for the hook-capture command: decides whether a write
/// target is a Claude Code project memory file that should be intercepted.
public enum HarnessMemoryMatcher {

    /// Returns the `(projectSlug, fileName)` pair if `path` matches
    /// `<any>/.claude/projects/<slug>/memory/<name>`, otherwise returns nil.
    ///
    /// Matching is path-component based, not regex, so no traversal escapes.
    /// Hidden components (dotfiles) in the slug or filename are rejected.
    public static func match(path: String) -> (projectSlug: String, fileName: String)? {
        let components = path.components(separatedBy: "/")
        // Minimum: ..., ".claude", "projects", "<slug>", "memory", "<name>"
        guard components.count >= 5 else { return nil }

        // Walk backward to find "memory" with a filename after it.
        for i in stride(from: components.count - 2, through: 3, by: -1) {
            guard components[i] == "memory" else { continue }
            let fileName = components[i + 1]
            let slug = components[i - 1]
            // Sanity: the component before slug should be "projects", and before
            // that should be ".claude". Enforce to avoid false matches on paths
            // that happen to contain a "memory" component.
            guard i >= 3,
                  components[i - 2] == "projects",
                  components[i - 3] == ".claude" else { continue }
            // Reject dotfiles and traversal.
            guard !fileName.hasPrefix("."), !fileName.contains(".."),
                  !slug.hasPrefix("."), !slug.contains("..") else { return nil }
            return (projectSlug: slug, fileName: fileName)
        }
        return nil
    }

    /// The teaching message shown when a write is intercepted and routed
    /// to the estate. Explains why and where to file directly next time.
    public static let teachingMessage = """
        Captured to the estate this time. \
        File directly with moot_file_memory \
        (location harness/<project>/<name>) — \
        direct filing gets semantic recall, temporal grading, \
        contradiction hunting, and linking this directory never had.
        """
}

// MARK: - Ingest result

/// Outcome of ingesting a single file from `~/.claude/projects/*/memory/`.
public struct IngestResult: Sendable {
    public let filePath: String
    public let projectSlug: String
    public let fileName: String
    public let outcome: Outcome

    public enum Outcome: Sendable {
        /// Posted to estate AND source file removed.
        case filed
        /// Source file revived in estate (unchanged content, re-enable path).
        case revived
        /// Not ingested (reason given); source file untouched.
        case skipped(String)
        /// Estate write or source removal failed; source file untouched.
        case failed(String)
    }
}

// MARK: - Ingest walker

/// Scans `~/.claude/projects/*/memory/` and ingests files into the estate
/// with MOVE semantics: file → confirmed estate write → delete source.
/// Failure at any step leaves the source untouched.
public enum HarnessMemoryIngest {

    /// Scan for project memory files. Returns a dictionary mapping project
    /// slug → array of file URLs. Hidden files are excluded.
    public static func scanProjects(homeDirectory: URL) -> [String: [URL]] {
        let projectsURL = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: homeDirectory)
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var result: [String: [URL]] = [:]
        for projectDir in projectDirs {
            guard (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { continue }
            let slug = projectDir.lastPathComponent
            let memoryDir = projectDir.appendingPathComponent("memory", isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: memoryDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            // Path validation: no dotfiles, no traversal.
            // (Mirrors moot-memory-adapter's _validate posture.)
            let valid = files.filter { url in
                let name = url.lastPathComponent
                return !name.hasPrefix(".") && !name.contains("..")
            }
            if !valid.isEmpty { result[slug] = valid }
        }
        return result
    }

    /// Ingest a single file from a project's memory directory into the estate.
    ///
    /// MOVE semantics (Bob's ruling, 2026-08-07): estate write → confirm →
    /// delete source. Source is NEVER deleted before a confirmed write.
    ///
    /// Re-enable path: if `isReEnable` is true and a superseded drawer with the
    /// same location already exists in the estate, the file's content is compared.
    /// Unchanged → `mutation=revive` (no duplicate drawer).
    /// Changed → file fresh (new drawer, current event_time).
    ///
    /// - Parameters:
    ///   - fileURL: URL of the source file.
    ///   - projectSlug: the project directory name (used in the location hint).
    ///   - isReEnable: true when enabling while already enabled (re-enable sweep).
    ///   - daemon: estate client; injected for testability.
    ///   - now: current time, passed as a parameter for determinism in tests.
    public static func ingestFile(
        _ fileURL: URL,
        projectSlug: String,
        isReEnable: Bool = false,
        daemon: some DaemonClient,
        now: Date = Date()
    ) async -> IngestResult {
        let fileName = fileURL.lastPathComponent

        // Location hint format: harness-import/<slug>/<filename>
        // The exact hint IS the reconstruction key for restore on disable —
        // filename and slug are preserved verbatim so restore lands at the
        // original path.
        let location = "harness-import/\(projectSlug)/\(fileName)"
        // MEMORY.md index files use kind=list so the estate grades them
        // differently from prose memories.
        let kind: String? = fileName.lowercased() == "memory.md" ? "list" : nil

        // Read the file's modification time for temporally correct event_time.
        let mtime: Date
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            mtime = attrs[.modificationDate] as? Date ?? now
        } catch {
            return IngestResult(
                filePath: fileURL.path, projectSlug: projectSlug, fileName: fileName,
                outcome: .failed("Could not read mtime: \(error)")
            )
        }

        let content: String
        do {
            content = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            return IngestResult(
                filePath: fileURL.path, projectSlug: projectSlug, fileName: fileName,
                outcome: .failed("Could not read file: \(error)")
            )
        }

        // Re-enable path: check for an existing superseded drawer.
        // (observability: harness.revive.count — MXE-HM-2)
        if isReEnable {
            do {
                let existing = try await daemon.listMemories(locationPrefix: location)
                if let superseded = existing.first(where: {
                    $0.location == location && $0.isSuperseded
                }) {
                    if superseded.content == content {
                        // Content unchanged — revive instead of creating a duplicate.
                        try await daemon.updateMemory(
                            id: superseded.id,
                            mutation: "revive",
                            note: "re-enabled harness-memory; content unchanged"
                        )
                        try? FileManager.default.removeItem(at: fileURL)
                        return IngestResult(
                            filePath: fileURL.path, projectSlug: projectSlug,
                            fileName: fileName, outcome: .revived
                        )
                    }
                    // Content changed: fall through to file a fresh drawer.
                }
            } catch {
                // Non-fatal: log and fall through to fresh file.
                log.warning("Re-enable drawer lookup failed for \(location, privacy: .public): \(error)")
            }
        }

        // File to estate — confirm — delete source.
        // (observability: harness.ingest.filed.count, harness.ingest.removed.count — MXE-HM-2)
        do {
            let confirmed = try await daemon.fileMemory(
                location: location, content: content, eventTime: mtime, kind: kind
            )
            guard confirmed else {
                return IngestResult(
                    filePath: fileURL.path, projectSlug: projectSlug, fileName: fileName,
                    outcome: .failed("Estate write not confirmed")
                )
            }
        } catch {
            return IngestResult(
                filePath: fileURL.path, projectSlug: projectSlug, fileName: fileName,
                outcome: .failed("Estate write failed: \(error)")
            )
        }

        // Confirmed: remove source.
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            // Write confirmed but removal failed — log, return filed.
            // The stray file will be swept on the next re-enable.
            log.warning(
                "Source removal failed after confirmed estate write (\(fileURL.path, privacy: .public)): \(error)"
            )
        }

        return IngestResult(
            filePath: fileURL.path, projectSlug: projectSlug, fileName: fileName,
            outcome: .filed
        )
    }

    /// Remove a project's `memory/` directory if it is empty (all files moved).
    /// Leaves the project directory and everything else intact.
    public static func removeEmptyMemoryDir(projectSlug: String, homeDirectory: URL) {
        let memoryDirURL = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: homeDirectory)
            .appendingPathComponent(projectSlug, isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(
            atPath: memoryDirURL.path)) ?? []
        if contents.isEmpty {
            try? FileManager.default.removeItem(at: memoryDirURL)
        }
    }
}

// MARK: - Restore result

/// Outcome of restoring a single estate memory record back to disk.
public struct RestoreResult: Sendable {
    public let location: String
    public let filePath: String
    public let outcome: Outcome

    public enum Outcome: Sendable {
        /// File written to disk; estate record marked superseded.
        case restored
        /// Not restored (reason given); source file untouched on disk.
        case skipped(String)
        /// Write failed; source file untouched on disk.
        case failed(String)
    }
}

// MARK: - Restore (disable path)

/// Restores estate memories back to disk on `mootx01 disable harness-memory`.
///
/// Both location classes are restored:
///   - `harness-import/<slug>/<name>` — memories originally on disk, moved in by ingest.
///   - `harness/<slug>/<name>` — memories born in the estate via the capture hook.
///
/// For each restored file the estate record is marked `mutation=supersede` with
/// note `"restored to harness <ISO8601>"`. Estate records are NEVER deleted.
public enum HarnessMemoryRestore {

    /// Restore all estate memories for `projectSlugs` back to disk.
    ///
    /// Refuses to overwrite an existing file (reports collision as `.skipped`).
    /// After each confirmed file write, marks the estate record superseded.
    /// Regenerates `MEMORY.md` unless a captured MEMORY.md drawer was restored.
    ///
    /// - Parameters:
    ///   - projectSlugs: slugs to restore (all if empty is passed, caller decides).
    ///   - homeDirectory: user's home directory.
    ///   - daemon: estate client; injected for testability.
    ///   - now: current time for the supersede note timestamp.
    public static func restore(
        projectSlugs: [String],
        homeDirectory: URL,
        daemon: some DaemonClient,
        now: Date
    ) async -> [RestoreResult] {
        let projectsURL = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: homeDirectory)
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let nowStr = fmt.string(from: now)

        var results: [RestoreResult] = []

        for slug in projectSlugs {
            // Both location-hint classes for this project.
            let prefixes = ["harness-import/\(slug)/", "harness/\(slug)/"]
            for prefix in prefixes {
                let records: [HarnessMemoryRecord]
                do {
                    records = try await daemon.listMemories(locationPrefix: prefix)
                } catch {
                    results.append(RestoreResult(
                        location: prefix, filePath: "",
                        outcome: .failed("List query failed: \(error)")
                    ))
                    continue
                }

                for record in records where !record.isSuperseded {
                    let fileResult = await restoreRecord(
                        record, projectsURL: projectsURL, nowStr: nowStr, daemon: daemon
                    )
                    results.append(fileResult)
                }
            }

            // Regenerate MEMORY.md unless one was already restored verbatim.
            let memoryDirURL = projectsURL
                .appendingPathComponent(slug, isDirectory: true)
                .appendingPathComponent("memory", isDirectory: true)
            let memoryMDURL = memoryDirURL.appendingPathComponent("MEMORY.md")
            if FileManager.default.fileExists(atPath: memoryDirURL.path),
               !FileManager.default.fileExists(atPath: memoryMDURL.path) {
                regenerateMemoryMD(at: memoryMDURL, results: results, slug: slug)
            }
        }

        return results
    }

    // MARK: - Private helpers

    private static func restoreRecord(
        _ record: HarnessMemoryRecord,
        projectsURL: URL,
        nowStr: String,
        daemon: some DaemonClient
    ) async -> RestoreResult {
        // Derive file path from location hint.
        // Shape: `harness-import/<slug>/<filename>` or `harness/<slug>/<filename>`.
        let parts = record.location.split(separator: "/", maxSplits: 2)
        guard parts.count == 3 else {
            return RestoreResult(
                location: record.location, filePath: "",
                outcome: .skipped("Cannot derive file path from location '\(record.location)'")
            )
        }
        let slug = String(parts[1])
        let fileName = String(parts[2])

        let memoryDirURL = projectsURL
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        let targetURL = memoryDirURL.appendingPathComponent(fileName)

        // Refuse to overwrite.
        if FileManager.default.fileExists(atPath: targetURL.path) {
            return RestoreResult(
                location: record.location, filePath: targetURL.path,
                outcome: .skipped("File already exists — not overwriting")
            )
        }

        // Write the file.
        do {
            try FileManager.default.createDirectory(
                at: memoryDirURL, withIntermediateDirectories: true
            )
            try record.content.write(to: targetURL, atomically: true, encoding: .utf8)
        } catch {
            return RestoreResult(
                location: record.location, filePath: targetURL.path,
                outcome: .failed("Write failed: \(error)")
            )
        }

        // Supersede the estate record.
        // (observability: harness.restore.count — MXE-HM-2)
        do {
            try await daemon.updateMemory(
                id: record.id,
                mutation: "supersede",
                note: "restored to harness \(nowStr)"
            )
        } catch {
            // Non-fatal: the file was written. Log and continue.
            log.warning(
                "Could not supersede estate record \(record.id, privacy: .public) after restore: \(error)"
            )
        }

        return RestoreResult(
            location: record.location, filePath: targetURL.path, outcome: .restored
        )
    }

    private static func regenerateMemoryMD(
        at url: URL,
        results: [RestoreResult],
        slug: String
    ) {
        let restoredNames = results.compactMap { r -> String? in
            guard case .restored = r.outcome else { return nil }
            let name = URL(fileURLWithPath: r.filePath).lastPathComponent
            guard name != "MEMORY.md" else { return nil }
            return "- \(name)"
        }
        guard !restoredNames.isEmpty else { return }
        let index = "# Memory Index\n\n" + restoredNames.joined(separator: "\n") + "\n"
        try? index.write(to: url, atomically: true, encoding: .utf8)
    }
}
