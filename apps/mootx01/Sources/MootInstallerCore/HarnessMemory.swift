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
//   HarnessMemoryFrontMatter: front matter `metadata:` line inject / strip (pure);
//                            carries moot_memory_id and moot_generated_index
//   RestoreResult          — per-file outcome from restore on disable
//   HarnessMemoryIngest    : ingest walker: file → confirm write → delete source;
//                            a restored file is matched to its estate row by id
//   HarnessMemoryRestore   : restore: estate → disk, id carried in front matter,
//                            estate rows left untouched; a marked MEMORY.md index
//                            is generated per slug when no captured one exists
//
// Observability emit points (MXE-HM-2: ObserverSink wiring out of scope for
// this mission; names reserved here so the follow-up wires without archaeology):
//   harness.capture.count         — captures by hook-capture command per session
//   harness.ingest.filed.count    — memories filed during ingest walker
//   harness.ingest.removed.count  — source files removed after confirmed write
//   harness.restore.count         — files written back to disk on disable
//   harness.ingest.matched.count: restored files whose row still holds the content (re-enable)
//   harness.hook.fire.rate        — hook fire rate over time (teaching-decay curve)

import Foundation
import MootProductIdentity
import os

private let log = Logger(subsystem: MootProductIdentity.Logging.subsystem, category: "MootInstallerCore.HarnessMemory")

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
    ///   - subject: one-line telegraphic assertion (≤120 chars) for recall result
    ///     lists. Required by the estate since PR-02.
    ///   - eventTime: temporal anchor; for ingest this is the file mtime.
    ///   - kind: optional content kind hint (`"list"` for MEMORY.md index files).
    func fileMemory(location: String, content: String, subject: String, eventTime: Date, kind: String?) async throws -> Bool

    /// List estate memories whose location begins with `prefix`.
    /// Returns active records only, complete across every server page. The
    /// server never lists a superseded row, so `isSuperseded` is false on
    /// every record this call returns.
    func listMemories(locationPrefix: String) async throws -> [HarnessMemoryRecord]

    /// Fetch one estate record by id.
    /// Returns nil when the server reports the id unknown, which is also the
    /// answer for a superseded row (the server hides superseded rows from
    /// `moot_memory_get`). Throws on transport failure.
    func getMemory(id: String) async throws -> HarnessMemoryRecord?

    /// Quick liveness check. Returns true if the daemon responded within the
    /// client's configured timeout; false on any network or timeout error.
    func ping() async -> Bool
}

/// Errors surfaced by `LiveDaemonClient`.
public enum DaemonError: Error, Sendable {
    /// The HTTP response status code was not 200.
    case httpError(Int)
    /// The response body could not be decoded as JSON-RPC 2.0, or a tool
    /// result lacked a field the contract requires (a list page without
    /// `has_more`, a get without a parsable record).
    case parseError
    /// The daemon said no. Two frame shapes, one case, identical in Rust:
    ///   - an ARIA v2 refusal: HTTP 200, no JSON-RPC error, `result.isError`
    ///     true and `result.structuredContent.error` carrying the code
    ///     (`code` is empty when the frame names none);
    ///   - a top-level JSON-RPC `error` object: `code` is `"rpc_error"`.
    /// A refusal is never an empty result; callers decide per code what to do.
    case refused(code: String, message: String)
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

    /// Testing initializer — injects a custom URLSession (e.g. backed by a mock
    /// URLProtocol). Not for production use; production code uses the port-based inits.
    init(baseURL: URL, session: URLSession) {
        self.baseURL = baseURL
        self.session = session
    }

    public func fileMemory(
        location: String,
        content: String,
        subject: String,
        eventTime: Date,
        kind: String?
    ) async throws -> Bool {
        var arguments: [String: Any] = [
            "location": location,
            "content": content,
            "subject": subject,
            "event_time": formatISO8601(eventTime),
        ]
        if let kind { arguments["kind"] = kind }
        return try await callTool("moot_file_memory", arguments: arguments) != nil
    }

    public func listMemories(locationPrefix: String) async throws -> [HarnessMemoryRecord] {
        // moot_memory_list (ARIA v2): file memories are stored in the "Agentic Memory"
        // wing regardless of their location prefix; `room` equals the full location
        // string (not a sub-segment). Strip any leading slashes from the caller's
        // prefix before matching so "/" and "" both return an empty list rather
        // than trapping on an empty parts[0] subscript.
        let normalized = locationPrefix.drop(while: { $0 == "/" })
        let prefix = String(normalized)
        guard !prefix.isEmpty else { return [] }

        // For an exact file location (3+ path components, no trailing slash), supply
        // the full location as the room filter so the server does the match.
        // For a directory prefix (trailing slash), omit room and filter client-side.
        let endsWithSlash = locationPrefix.hasSuffix("/")
        let componentCount = prefix.split(separator: "/").count
        // `limit` is the server maximum (1..200); larger wings page.
        var baseArguments: [String: Any] = ["wing": "Agentic Memory", "limit": 200]
        if !endsWithSlash && componentCount >= 3 {
            baseArguments["room"] = prefix
        }

        // Page through the wing. The server answers `has_more` and `next_cursor`;
        // the next request carries that cursor. A `cursor_stale` or
        // `cursor_expired` refusal means the inventory moved under the cursor:
        // the ids collected so far are discarded and enumeration restarts from
        // the first page, at most `maxRestarts` times. Any other refusal
        // propagates. A cursor already seen fails the whole call with
        // DaemonError.parseError, discarding every id collected so far, so a
        // misbehaving server cannot spin this client forever.
        let maxRestarts = 3
        var restarts = 0
        var ids: [String] = []
        while true {
            do {
                ids = try await enumerateIds(baseArguments: baseArguments)
                break
            } catch DaemonError.refused(let code, _)
                where (code == "cursor_stale" || code == "cursor_expired") && restarts < maxRestarts {
                restarts += 1
            }
        }

        // Client-side prefix filter for directory queries where room was omitted.
        return try await fetchMemoryRecords(ids: ids).filter { $0.location.hasPrefix(prefix) }
    }

    /// One full pass over `moot_memory_list` pages. Returns every distinct id
    /// in server order. A page without `memories` or `has_more` is a parse
    /// error, not an empty page; so is `has_more` true with no `next_cursor`
    /// or with a cursor already used, because the rest of the wing is
    /// unreachable and a partial answer would be reported as the whole wing.
    private func enumerateIds(baseArguments: [String: Any]) async throws -> [String] {
        var ids: [String] = []
        var seenIds = Set<String>()
        var seenCursors = Set<String>()
        var cursor: String? = nil
        while true {
            var arguments = baseArguments
            if let cursor { arguments["cursor"] = cursor }
            guard let result = try await callTool("moot_memory_list", arguments: arguments),
                  let data = dataObject(from: result),
                  let array = data["memories"] as? [[String: Any]],
                  let hasMore = data["has_more"] as? Bool else {
                throw DaemonError.parseError
            }
            // Each list row has: memory_id, fetch, subject?, provenance?
            // Location and content require the moot_memory_get follow-up.
            for item in array {
                guard let memoryId = item["memory_id"] as? String,
                      seenIds.insert(memoryId).inserted else { continue }
                ids.append(memoryId)
            }
            if !hasMore { break }
            // has_more without a fresh cursor cannot be walked. Report it rather
            // than return the pages read so far as the whole wing; the Rust twin
            // (estate_list) answers the same frame with "malformed page".
            guard let next = data["next_cursor"] as? String,
                  seenCursors.insert(next).inserted else {
                throw DaemonError.parseError
            }
            cursor = next
        }
        return ids
    }

    /// Fetch full records for `ids` via `moot_memory_get` in batches of 50
    /// (the server's `memory_ids` ceiling), so `ceil(n / 50)` calls. The order
    /// of the returned records follows the server's answer. A batch that
    /// answers fewer records than it was asked for throws
    /// `DaemonError.refused(code: "memory_not_found")` naming the missing ids;
    /// no record is ever dropped silently.
    private func fetchMemoryRecords(ids: [String]) async throws -> [HarnessMemoryRecord] {
        let batchSize = 50
        var records: [HarnessMemoryRecord] = []
        var offset = 0
        while offset < ids.count {
            let chunk = Array(ids[offset..<min(offset + batchSize, ids.count)])
            offset += batchSize
            guard let result = try await callTool("moot_memory_get", arguments: ["memory_ids": chunk]),
                  let data = dataObject(from: result),
                  let memories = data["memories"] as? [[String: Any]] else {
                throw DaemonError.parseError
            }
            var answered = Set<String>()
            for item in memories {
                if let record = parseMemoryRecord(item) {
                    records.append(record)
                    answered.insert(record.id)
                }
            }
            let missing = chunk.filter { !answered.contains($0) }
            guard missing.isEmpty else {
                throw DaemonError.refused(
                    code: "memory_not_found",
                    message: "moot_memory_get answered \(answered.count) of \(chunk.count) ids; missing: \(missing.joined(separator: ","))"
                )
            }
        }
        return records
    }

    public func getMemory(id: String) async throws -> HarnessMemoryRecord? {
        let result: Any?
        do {
            result = try await callTool("moot_memory_get", arguments: ["memory_id": id])
        } catch DaemonError.refused(let code, _) where code == "memory_not_found" {
            // The server refuses with `memory_not_found` for an unknown id and
            // for a superseded row alike; both mean "no live row with this id".
            // Every other refusal, and every transport error, propagates.
            return nil
        }
        guard let result,
              let data = dataObject(from: result),
              let memories = data["memories"] as? [[String: Any]],
              let item = memories.first,
              let record = parseMemoryRecord(item) else {
            throw DaemonError.parseError
        }
        return record
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
            throw DaemonError.refused(code: "rpc_error", message: msg)
        }
        let result = json["result"]
        // ARIA v2 refusal: HTTP 200, no JSON-RPC error, the tool result itself
        // says no. `structuredContent.error` carries the code; `isError` is the
        // MCP-level flag. Either one makes this a refusal, never a result.
        if let obj = result as? [String: Any] {
            let structured = obj["structuredContent"] as? [String: Any]
            let refusal = structured?["error"] as? [String: Any]
            if refusal != nil || (obj["isError"] as? Bool) == true {
                let code = refusal?["code"] as? String ?? ""
                let contentText = ((obj["content"] as? [[String: Any]])?.first?["text"] as? String)
                let message = refusal?["message"] as? String ?? contentText ?? ""
                throw DaemonError.refused(code: code, message: message)
            }
        }
        return result
    }

    // MARK: - v2 envelope parsing

    /// Unwrap `result.structuredContent.data` from a v2 tool result.
    private func dataObject(from result: Any) -> [String: Any]? {
        guard let obj = result as? [String: Any],
              let structured = obj["structuredContent"] as? [String: Any],
              let data = structured["data"] as? [String: Any] else {
            return nil
        }
        return data
    }

    /// Parse one element of `moot_memory_get`'s `data.memories` into a record.
    /// `placement.room` is the original location string; `state` is "active"
    /// or "superseded" (absent defaults to active). Returns nil when any
    /// required field is missing.
    private func parseMemoryRecord(_ item: [String: Any]) -> HarnessMemoryRecord? {
        guard let memoryId = item["memory_id"] as? String,
              let placement = item["placement"] as? [String: Any],
              let location = placement["room"] as? String,
              let content = item["content"] as? String,
              let timeStr = item["event_time"] as? String,
              let eventTime = parseISO8601(timeStr) else {
            return nil
        }
        let isSuperseded = (item["state"] as? String) == "superseded"
        return HarnessMemoryRecord(
            id: memoryId, location: location, content: content,
            eventTime: eventTime, isSuperseded: isSuperseded
        )
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
    /// The filename must be the final path component — paths with additional
    /// segments after the filename (e.g. traversal sequences like `z/../../..`)
    /// are rejected so the daemon-down allow fallback cannot fire for targets
    /// the harness does not fully govern.
    public static func match(path: String) -> (projectSlug: String, fileName: String)? {
        let components = path.components(separatedBy: "/")
        // Minimum: ..., ".claude", "projects", "<slug>", "memory", "<name>"
        guard components.count >= 5 else { return nil }

        // Walk backward to find "memory" with a filename after it.
        for i in stride(from: components.count - 2, through: 3, by: -1) {
            guard components[i] == "memory" else { continue }
            // Require the filename to be the LAST component. If there are additional
            // segments after it (e.g. `memory/z/../../settings.json`), the path
            // resolves outside the governed tree and must not receive an explicit
            // allow — fall through to normal permission handling.
            guard i + 1 == components.count - 1 else { return nil }
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

// MARK: - Front matter (metadata line carrier)

/// Byte-exact front matter carrier for one `<key>: <value>` line under the
/// YAML `metadata:` mapping of a file on disk.
///
/// Two keys ride on it. Restore writes each file with a `moot_memory_id` line
/// so a later re-enable can match the file to its row without listing
/// superseded rows (the server never returns them). Restore marks the
/// `MEMORY.md` index it generates with `moot_generated_index: true` so a later
/// re-enable discards that index instead of filing it as a memory. Three
/// cases, line-based, `\n` only, no regex and no YAML parser:
///   1. Block present with a `metadata:` line: the key line goes directly
///      after `metadata:` (Claude Code memory files have this shape).
///   2. Block present without `metadata:`: `metadata:` plus the key line go
///      directly before the closing fence.
///   3. No block (MEMORY.md): a block of four lines is prepended, two fences
///      around `metadata:` and the key line.
/// `strip` is the exact byte inverse of `inject` for the same key. A shared
/// vector pins both ports to identical bytes.
public enum HarnessMemoryFrontMatter {

    /// The front matter key that carries the estate memory id.
    public static let key = "moot_memory_id"

    /// The front matter key that marks a `MEMORY.md` index written by restore.
    /// Its value is always `true`; ingest removes such a file without filing it.
    public static let generatedIndexKey = "moot_generated_index"

    private static let fenceLine = "---\n"
    private static let fence = "---"
    private static let metadataLine = "metadata:"

    /// A carried line is a child of `metadata:`, so it carries the two-space indent.
    private static func linePrefix(for key: String) -> String {
        "  \(key): "
    }

    /// Return `content` with `moot_memory_id: <memoryId>` under `metadata:`.
    /// Thin wrapper over `inject(_:key:value:)` for the memory id key.
    public static func inject(_ content: String, memoryId: String) -> String {
        inject(content, key: key, value: memoryId)
    }

    /// Split `content` into its `moot_memory_id` (if any) and the remaining body.
    /// Thin wrapper over `strip(_:key:)` for the memory id key.
    public static func strip(_ content: String) -> (memoryId: String?, body: String) {
        let (value, body) = strip(content, key: key)
        return (value, body)
    }

    /// Return `content` with `<key>: <value>` under `metadata:`.
    ///
    /// When `content` opens a front matter block (`---\n` first, and a later
    /// line that is exactly `---`), the key line is inserted after an existing
    /// `metadata:` line, or `metadata:` and the key line are inserted before the
    /// closing fence. Otherwise a new block holding only `metadata:` and the
    /// key line is prepended. Every other byte of `content` is preserved.
    public static func inject(_ content: String, key: String, value: String) -> String {
        let keyLine = linePrefix(for: key) + value
        guard let (blockStart, closingStart) = blockBounds(of: content) else {
            return fenceLine + metadataLine + "\n" + keyLine + "\n" + fenceLine + content
        }
        var lines = blockLines(content[blockStart..<closingStart])
        if let index = lines.firstIndex(of: metadataLine) {
            lines.insert(keyLine, at: index + 1)
        } else {
            lines.append(metadataLine)
            lines.append(keyLine)
        }
        return fenceLine + joined(lines) + content[closingStart...]
    }

    /// Split `content` into the value of `<key>` (if any) and the remaining body.
    ///
    /// The first `  <key>: <value>` line inside a leading front matter block is
    /// removed. A `metadata:` line directly above it is removed too when
    /// nothing indented follows it any more. When the block is then empty both
    /// fence lines are removed. The body is byte-identical to `content` apart
    /// from those removals. Without the key line the result is `(nil, content)`.
    public static func strip(_ content: String, key: String) -> (value: String?, body: String) {
        let prefix = linePrefix(for: key)
        guard let (blockStart, closingStart) = blockBounds(of: content) else {
            return (nil, content)
        }
        var lines = blockLines(content[blockStart..<closingStart])
        guard let index = lines.firstIndex(where: { $0.hasPrefix(prefix) }) else {
            return (nil, content)
        }
        let value = lines[index].dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespaces)
        lines.remove(at: index)
        if index > 0, lines[index - 1] == metadataLine {
            // `metadata:` stays only while it still has an indented child.
            let childFollows = index < lines.count && lines[index].hasPrefix("  ")
            if !childFollows { lines.remove(at: index - 1) }
        }
        if lines.isEmpty {
            // Block held only our lines: drop both fence lines.
            var bodyStart = content.index(closingStart, offsetBy: fence.count)
            if bodyStart < content.endIndex, content[bodyStart] == "\n" {
                bodyStart = content.index(after: bodyStart)
            }
            return (value, String(content[bodyStart...]))
        }
        return (value, fenceLine + joined(lines) + content[closingStart...])
    }

    // MARK: - Private helpers

    /// `(blockStart, closingStart)` when `content` opens with `---\n` and a
    /// later line is exactly `---`. `blockStart` is the index after the opening
    /// fence line; `closingStart` is the index of the closing fence line.
    private static func blockBounds(of content: String) -> (String.Index, String.Index)? {
        guard content.hasPrefix(fenceLine) else { return nil }
        let blockStart = content.index(content.startIndex, offsetBy: fenceLine.count)
        var lineStart = blockStart
        while lineStart < content.endIndex {
            let lineEnd = content[lineStart...].firstIndex(of: "\n") ?? content.endIndex
            if content[lineStart..<lineEnd] == fence { return (blockStart, lineStart) }
            guard lineEnd < content.endIndex else { break }
            lineStart = content.index(after: lineEnd)
        }
        return nil
    }

    /// The block's lines without their newlines. The block always ends with a
    /// newline (the closing fence starts a line), so the trailing empty piece
    /// from the split is dropped.
    private static func blockLines(_ block: Substring) -> [String] {
        guard !block.isEmpty else { return [] }
        var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeLast()
        return lines
    }

    /// Inverse of `blockLines`: every line followed by its newline.
    private static func joined(_ lines: [String]) -> String {
        lines.map { $0 + "\n" }.joined()
    }
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
        /// The file's `moot_memory_id` row already holds this content: source
        /// file removed, row untouched, nothing written to the estate.
        case matched
        /// A `MEMORY.md` written by `HarnessMemoryRestore` (marked
        /// `moot_generated_index: true`, no memory id): source file removed,
        /// nothing written to the estate. The index is a client artifact; the
        /// estate is the inventory.
        case discardedIndex
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
    /// A file written by `HarnessMemoryRestore` carries its estate id in
    /// `moot_memory_id` front matter. The front matter is stripped first; the
    /// estate only ever sees the body. When that id resolves to a live row at
    /// this file's own location (`harness-import/<slug>/<name>` or
    /// `harness/<slug>/<name>`):
    ///   - body equals the row content → `.matched`: file removed, row untouched.
    ///   - body differs → `.filed`: the old row is left untouched (harness
    ///     memory never supersedes and never revives) and the new body is
    ///     filed fresh at the row's location via a single `moot_file_memory`
    ///     call, so the estate gains a second row for that (slug, filename)
    ///     pair.
    /// No id, an unknown id, or a row at another location also files the body
    /// fresh, at `harness-import/<slug>/<name>`.
    ///
    /// A `MEMORY.md` (case-insensitive) with no memory id and the
    /// `moot_generated_index: true` marker is the index restore generated for
    /// the slug: it is removed and reported `.discardedIndex` with no estate
    /// call, so a disable → enable cycle adds no row. A `MEMORY.md` with
    /// neither marker (authored, first enable) is filed with kind `list`.
    /// (observability: harness.ingest.matched.count, harness.ingest.filed.count, MXE-HM-2)
    ///
    /// - Parameters:
    ///   - fileURL: URL of the source file.
    ///   - projectSlug: the project directory name (used in the location hint).
    ///   - daemon: estate client; injected for testability.
    ///   - now: current time, passed as a parameter for determinism in tests.
    public static func ingestFile(
        _ fileURL: URL,
        projectSlug: String,
        daemon: some DaemonClient,
        now: Date = Date()
    ) async -> IngestResult {
        let fileName = fileURL.lastPathComponent
        func result(_ outcome: IngestResult.Outcome) -> IngestResult {
            IngestResult(
                filePath: fileURL.path, projectSlug: projectSlug, fileName: fileName,
                outcome: outcome
            )
        }

        // Location hint format: harness-import/<slug>/<filename>
        // The exact hint IS the reconstruction key for restore on disable —
        // filename and slug are preserved verbatim so restore lands at the
        // original path. Rows born in the estate via the capture hook live at
        // harness/<slug>/<filename> and restore to the same disk path.
        let importLocation = "harness-import/\(projectSlug)/\(fileName)"
        let capturedLocation = "harness/\(projectSlug)/\(fileName)"
        // MEMORY.md index files use kind=list so the estate grades them
        // differently from prose memories.
        let kind: String? = fileName.lowercased() == "memory.md" ? "list" : nil

        // Read the file's modification time for temporally correct event_time.
        let mtime: Date
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            mtime = attrs[.modificationDate] as? Date ?? now
        } catch {
            return result(.failed("Could not read mtime: \(error)"))
        }

        let rawContent: String
        do {
            rawContent = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            return result(.failed("Could not read file: \(error)"))
        }
        let (memoryId, body) = HarnessMemoryFrontMatter.strip(rawContent)

        // Restore-generated index: a client artifact, never an estate row.
        if memoryId == nil, kind == "list",
           HarnessMemoryFrontMatter.strip(body, key: HarnessMemoryFrontMatter.generatedIndexKey).value == "true" {
            removeSource(fileURL)
            return result(.discardedIndex)
        }

        // Restored file: match it to its row by id.
        if let memoryId {
            let existing: HarnessMemoryRecord?
            do {
                existing = try await daemon.getMemory(id: memoryId)
            } catch {
                // A transport failure leaves the question open; filing fresh here
                // could duplicate a row the estate still holds.
                return result(.failed("Estate lookup failed for \(memoryId): \(error)"))
            }
            if let row = existing,
               row.location == importLocation || row.location == capturedLocation {
                if row.content == body {
                    removeSource(fileURL)
                    return result(.matched)
                }
                // Content changed on disk: file the new body as a fresh memory
                // at the same location. Harness memory never supersedes and
                // never revives — the old row is left untouched, and the new
                // content lands as its own row via a single moot_file_memory call.
                if let reason = await fileBody(
                    body, location: row.location, fileName: fileName,
                    mtime: mtime, kind: kind, daemon: daemon
                ) {
                    return result(.failed(reason))
                }
                removeSource(fileURL)
                return result(.filed)
            }
        }

        // File to estate — confirm — delete source.
        // (observability: harness.ingest.filed.count, harness.ingest.removed.count — MXE-HM-2)
        if let reason = await fileBody(
            body, location: importLocation, fileName: fileName,
            mtime: mtime, kind: kind, daemon: daemon
        ) {
            return result(.failed(reason))
        }
        removeSource(fileURL)
        return result(.filed)
    }

    /// File `body` at `location`. Returns nil on a confirmed write, otherwise
    /// the failure reason for the caller's `.failed` outcome.
    private static func fileBody(
        _ body: String,
        location: String,
        fileName: String,
        mtime: Date,
        kind: String?,
        daemon: some DaemonClient
    ) async -> String? {
        let subject = extractSubject(from: body, fileName: fileName)
        do {
            let confirmed = try await daemon.fileMemory(
                location: location, content: body, subject: subject, eventTime: mtime, kind: kind
            )
            return confirmed ? nil : "Estate write not confirmed"
        } catch {
            return "Estate write failed: \(error)"
        }
    }

    /// Remove the source file after the estate confirmed it holds the content.
    /// A removal failure is logged, not reported: the estate write stands and
    /// the stray file is swept on the next enable.
    private static func removeSource(_ fileURL: URL) {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            log.warning(
                "Source removal failed after the estate confirmed the content (\(fileURL.path, privacy: .public)): \(error)"
            )
        }
    }

    /// One summary line over a set of ingest results, in the words and order
    /// the Rust port prints per project: `filed N, matched N, discarded indexes N,
    /// removed N, skipped N`. `filed` counts `.filed` (rows the estate gained),
    /// `matched` counts `.matched` (nothing written), `removed` counts every
    /// source file that left the disk (filed, matched, discarded), and
    /// `skipped` counts `.skipped` and `.failed` (the file is still on disk).
    /// A matched file never contributes to `filed`.
    public static func summaryLine(_ results: [IngestResult]) -> String {
        var filed = 0, matched = 0, discarded = 0, skipped = 0
        for result in results {
            switch result.outcome {
            case .filed: filed += 1
            case .matched: matched += 1
            case .discardedIndex: discarded += 1
            case .skipped, .failed: skipped += 1
            }
        }
        let removed = filed + matched + discarded
        return "filed \(filed), matched \(matched), discarded indexes \(discarded), removed \(removed), skipped \(skipped)"
    }

    /// Generate a subject line for estate filing from file content.
    ///
    /// Returns the first non-blank, non-heading (`#`) line of `content`, trimmed
    /// and truncated to 120 characters. Falls back to the filename stem (dropping
    /// `.md` extension) when the content contains only blank lines or headings.
    /// The 120-char cap matches the estate's subject length contract.
    public static func extractSubject(from content: String, fileName: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        if let line = lines.first(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(trimmed.prefix(120))
        }
        // Fallback: filename stem when content is all headings or blank lines.
        let stem = fileName.hasSuffix(".md") ? String(fileName.dropLast(3)) : fileName
        return String(stem.prefix(120))
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
        /// File written to disk with `moot_memory_id` front matter; the estate
        /// row is left untouched.
        case restored
        /// Not restored (reason given); nothing written on disk.
        case skipped(String)
        /// Write failed; nothing written on disk.
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
/// Every restored file carries its estate id as `moot_memory_id` front matter
/// so a later re-enable matches the file to its row instead of filing a
/// duplicate. Estate rows are left untouched: no mutation is applied and
/// nothing is deleted.
public enum HarnessMemoryRestore {

    /// Location prefixes whose rows restore to `~/.claude/projects/<slug>/memory/<name>`.
    static let locationPrefixes: Set<String> = ["harness-import", "harness"]

    /// Restore every active harness memory in the estate back to disk.
    ///
    /// Discovery is one `listMemories(locationPrefix: "harness")` query. When
    /// that query throws (a refusal, a transport failure, a malformed page)
    /// the result is exactly one `.failed` entry and nothing is written: a
    /// refusal is a failure of the disable, never an empty wing. A row
    /// is restored when its location has the exact shape `<prefix>/<slug>/<name>`
    /// with a prefix in `locationPrefixes` and a slug and name that contain no
    /// `..` and do not start with a dot. Rows are deduplicated by id and
    /// superseded rows are skipped.
    /// Refuses to overwrite an existing file (reports the collision as `.skipped`).
    /// Generates a `MEMORY.md` per slug, marked `moot_generated_index: true`,
    /// unless a captured MEMORY.md row was restored for that slug.
    ///
    /// - Parameters:
    ///   - homeDirectory: user's home directory.
    ///   - daemon: estate client; injected for testability.
    public static func restore(
        homeDirectory: URL,
        daemon: some DaemonClient
    ) async -> [RestoreResult] {
        let projectsURL = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: homeDirectory)
        var results: [RestoreResult] = []

        let records: [HarnessMemoryRecord]
        do {
            records = try await daemon.listMemories(locationPrefix: "harness")
        } catch {
            results.append(RestoreResult(
                location: "harness", filePath: "",
                outcome: .failed("Estate enumeration failed: \(error)")
            ))
            return results
        }

        // Group restorable rows by slug, first occurrence of each id wins.
        var seenIds = Set<String>()
        var bySlug: [String: [(record: HarnessMemoryRecord, fileName: String)]] = [:]
        for record in records where !record.isSuperseded {
            guard seenIds.insert(record.id).inserted else { continue }
            guard let target = restoreTarget(location: record.location) else {
                // Only rows under our prefixes are worth reporting; anything
                // else the "harness" prefix matched belongs to someone else.
                let head = record.location.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
                if locationPrefixes.contains(head) {
                    results.append(RestoreResult(
                        location: record.location, filePath: "",
                        outcome: .skipped("Cannot derive file path from location '\(record.location)'")
                    ))
                }
                continue
            }
            bySlug[target.slug, default: []].append((record, target.fileName))
        }

        for slug in bySlug.keys.sorted() {
            var slugResults: [RestoreResult] = []
            for entry in bySlug[slug] ?? [] {
                slugResults.append(restoreRecord(
                    entry.record, slug: slug, fileName: entry.fileName, projectsURL: projectsURL
                ))
            }
            results.append(contentsOf: slugResults)

            // Generate a marked MEMORY.md unless a captured one was restored verbatim.
            let memoryDirURL = projectsURL
                .appendingPathComponent(slug, isDirectory: true)
                .appendingPathComponent("memory", isDirectory: true)
            let memoryMDURL = memoryDirURL.appendingPathComponent("MEMORY.md")
            if FileManager.default.fileExists(atPath: memoryDirURL.path),
               !FileManager.default.fileExists(atPath: memoryMDURL.path) {
                regenerateMemoryMD(at: memoryMDURL, results: slugResults, slug: slug)
            }
        }

        return results
    }

    /// Split a location into `(slug, fileName)` when it has the restorable
    /// shape `<prefix>/<slug>/<name>`: exactly three components, a prefix in
    /// `locationPrefixes`, and no traversal or hidden component. Returns nil
    /// otherwise.
    static func restoreTarget(location: String) -> (slug: String, fileName: String)? {
        let parts = location.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, locationPrefixes.contains(String(parts[0])) else { return nil }
        let slug = String(parts[1])
        let fileName = String(parts[2])
        guard !slug.isEmpty, !fileName.isEmpty,
              !slug.hasPrefix("."), !fileName.hasPrefix("."),
              !slug.contains(".."), !fileName.contains("..") else { return nil }
        return (slug, fileName)
    }

    // MARK: - Private helpers

    /// Write one row to `<projectsURL>/<slug>/memory/<fileName>` with its id in
    /// front matter. Makes no estate call.
    /// (observability: harness.restore.count, MXE-HM-2)
    private static func restoreRecord(
        _ record: HarnessMemoryRecord,
        slug: String,
        fileName: String,
        projectsURL: URL
    ) -> RestoreResult {
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

        let onDisk = HarnessMemoryFrontMatter.inject(record.content, memoryId: record.id)
        do {
            try FileManager.default.createDirectory(
                at: memoryDirURL, withIntermediateDirectories: true
            )
            try onDisk.write(to: targetURL, atomically: true, encoding: .utf8)
        } catch {
            return RestoreResult(
                location: record.location, filePath: targetURL.path,
                outcome: .failed("Write failed: \(error)")
            )
        }

        return RestoreResult(
            location: record.location, filePath: targetURL.path, outcome: .restored
        )
    }

    /// Write a `MEMORY.md` index listing the files restored for one slug.
    /// `results` must already be limited to that slug.
    ///
    /// Bytes are pinned in both ports: a front matter block holding only
    /// `moot_generated_index: true`, then `# Memory Index`, a blank line, and
    /// one `- [<name>](<name>)` line per restored file other than `MEMORY.md`,
    /// sorted by file name in byte order. The marker lets a later re-enable
    /// discard the file instead of filing it; the estate holds the inventory.
    /// Nothing is written when no file was restored for the slug.
    private static func regenerateMemoryMD(
        at url: URL,
        results: [RestoreResult],
        slug: String
    ) {
        let restoredNames = results.compactMap { r -> String? in
            guard case .restored = r.outcome else { return nil }
            let name = URL(fileURLWithPath: r.filePath).lastPathComponent
            guard name != "MEMORY.md" else { return nil }
            return name
        }
        guard !restoredNames.isEmpty else { return }
        // Byte order, not locale order: the Rust port sorts the same way.
        let sortedNames = restoredNames.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let body = "# Memory Index\n\n" + sortedNames.map { "- [\($0)](\($0))\n" }.joined()
        let index = HarnessMemoryFrontMatter.inject(
            body, key: HarnessMemoryFrontMatter.generatedIndexKey, value: "true"
        )
        try? index.write(to: url, atomically: true, encoding: .utf8)
    }
}
