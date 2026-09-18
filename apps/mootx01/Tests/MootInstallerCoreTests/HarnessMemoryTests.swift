// HarnessMemoryTests.swift
//
// Swift Testing suite for MootInstallerCore's Harness Memory Mode logic.
//
// Coverage:
//   HarnessMemorySettings — settings.json merge/remove, idempotence, backup,
//                           round-trip (enable → disable → semantic equality)
//   HarnessMemoryCLAUDE   — sentinel block merge/remove, idempotence
//   HarnessMemoryHook     — script content, install/remove
//   HarnessMemoryMatcher  — path matching, slug/filename extraction
//   HarnessMemoryIngest   — mtime round-trip, move-after-confirm, failure-leaves-rest,
//                           opt-in respected, re-enable match by moot_memory_id or file
//                           fresh on changed content (never supersedes, never revives),
//                           restore-generated MEMORY.md discarded without filing
//   HarnessMemoryRestore  : collision refusal, rows left untouched, id in front matter,
//                           generated index bytes (pinned in both ports), round-trip with ingest
//   HarnessMemoryFrontMatter: the shared inject / strip vector (pinned in both ports),
//                           a second key beside moot_memory_id
//   LiveDaemonClient      : v2 envelope, paging, batch get, refusal frames, through
//                           QueuedResponseProtocol (no network)
//
// All tests use sandbox directories; no real ~/.claude or ~/.mootx01 paths are touched.
// The daemon is mocked via MockDaemonClient — tests do not require a live daemon.
// One env-gated suite (MOOT_HARNESS_LIVE_PORT) round-trips against a running daemon.

import Testing
import Foundation
@testable import MootInstallerCore

// MARK: - Mock daemon

/// Test double for DaemonClient. Records all calls and returns preset responses.
final class MockDaemonClient: DaemonClient, @unchecked Sendable {

    // Recorded calls
    var filedMemories: [(location: String, content: String, subject: String, eventTime: Date, kind: String?)] = []
    var listedPrefixes: [String] = []
    var gottenIds: [String] = []
    var pingCount = 0

    // Preset responses
    var pingResult = true
    var fileMemoryResult = true
    var fileMemoryError: Error? = nil
    var listMemoriesResult: [HarnessMemoryRecord] = []
    var listMemoriesError: Error? = nil
    /// Records answered by `getMemory(id:)`; an id absent here answers nil (unknown).
    var getMemoryResult: [String: HarnessMemoryRecord] = [:]
    var getMemoryError: Error? = nil

    func ping() async -> Bool {
        pingCount += 1
        return pingResult
    }

    func fileMemory(
        location: String, content: String, subject: String, eventTime: Date, kind: String?
    ) async throws -> Bool {
        if let err = fileMemoryError { throw err }
        filedMemories.append((location: location, content: content, subject: subject, eventTime: eventTime, kind: kind))
        return fileMemoryResult
    }

    func listMemories(locationPrefix: String) async throws -> [HarnessMemoryRecord] {
        if let err = listMemoriesError { throw err }
        listedPrefixes.append(locationPrefix)
        return listMemoriesResult.filter { $0.location.hasPrefix(locationPrefix) }
    }

    func getMemory(id: String) async throws -> HarnessMemoryRecord? {
        if let err = getMemoryError { throw err }
        gottenIds.append(id)
        return getMemoryResult[id]
    }
}

// MARK: - Sandbox helpers

private func makeSandboxDir(tag: String = "harness-memory-test") throws -> URL {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(tag)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
}

private func cleanupSandbox(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// A Claude Code memory file as the harness writes it: a YAML block with
/// name, description and a `metadata:` mapping, then the body.
private let kMemoryFileBody = "---\nname: bob-viewport\ndescription: \"wide\"\nmetadata:\n  node_type: memory\n  type: user\n  originSessionId: ca2fd6e7\n---\nbody\n"

/// The same file after an edit on disk (body changed, block intact).
private let kMemoryFileBodyChanged = "---\nname: bob-viewport\ndescription: \"wide\"\nmetadata:\n  node_type: memory\n  type: user\n  originSessionId: ca2fd6e7\n---\nbody, revised\n"

/// A MEMORY.md index has no front matter block.
private let kMemoryIndexBody = "# Memory Index\n"

/// The front matter block restore puts on the MEMORY.md it generates.
private let kGeneratedIndexPrefix = "---\nmetadata:\n  moot_generated_index: true\n---\n"

private func makeRecord(
    id: String, location: String, content: String, isSuperseded: Bool = false
) -> HarnessMemoryRecord {
    HarnessMemoryRecord(
        id: id, location: location, content: content,
        eventTime: Date(timeIntervalSinceReferenceDate: 0), isSuperseded: isSuperseded
    )
}

// MARK: - HarnessMemorySettings tests

@Suite("HarnessMemorySettings")
struct HarnessMemorySettingsTests {

    // MARK: Hook presence detection

    @Test("hasHookEntry returns false when hooks key absent")
    func hookAbsent() {
        let settings: [String: Any] = [:]
        #expect(!HarnessMemorySettings.hasHookEntry(in: settings, commandPath: "/foo/bar.sh"))
    }

    @Test("hasHookEntry returns false when PreToolUse absent")
    func preToolUseAbsent() {
        let settings: [String: Any] = ["hooks": [:] as [String: Any]]
        #expect(!HarnessMemorySettings.hasHookEntry(in: settings, commandPath: "/foo/bar.sh"))
    }

    @Test("hasHookEntry returns true when our command is present")
    func hookPresent() {
        let settings: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "Write|Edit|MultiEdit",
                        "hooks": [["type": "command", "command": "/foo/bar.sh"] as [String: Any]]
                    ] as [String: Any]
                ]
            ] as [String: Any]
        ]
        #expect(HarnessMemorySettings.hasHookEntry(in: settings, commandPath: "/foo/bar.sh"))
    }

    @Test("hasHookEntry returns false when a different command is present")
    func hookDifferentCommand() {
        let settings: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "Write",
                        "hooks": [["type": "command", "command": "/other/hook.sh"] as [String: Any]]
                    ] as [String: Any]
                ]
            ] as [String: Any]
        ]
        #expect(!HarnessMemorySettings.hasHookEntry(in: settings, commandPath: "/foo/bar.sh"))
    }

    // MARK: Add hook entry

    @Test("addHookEntry appends a new matcher-group")
    func addHookEntry() {
        let root = HarnessMemorySettings.addHookEntry(to: [:], commandPath: "/my/hook.sh")
        #expect(HarnessMemorySettings.hasHookEntry(in: root, commandPath: "/my/hook.sh"))
        // Must not clobber an existing unrelated group.
        let withExisting: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "Bash",
                        "hooks": [["type": "command", "command": "/other.sh"] as [String: Any]]
                    ] as [String: Any]
                ]
            ] as [String: Any]
        ]
        let result = HarnessMemorySettings.addHookEntry(to: withExisting, commandPath: "/my/hook.sh")
        // Both hooks must be present.
        let hooks = (result["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] ?? []
        #expect(hooks.count == 2)
    }

    // MARK: Remove hook entry

    @Test("removeHookEntry removes our group and leaves others intact")
    func removeHookEntry() {
        let settings: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "Write|Edit|MultiEdit",
                        "hooks": [["type": "command", "command": "/our/hook.sh"] as [String: Any]]
                    ] as [String: Any],
                    [
                        "matcher": "Bash",
                        "hooks": [["type": "command", "command": "/other.sh"] as [String: Any]]
                    ] as [String: Any],
                ]
            ] as [String: Any]
        ]
        let result = HarnessMemorySettings.removeHookEntry(from: settings, commandPath: "/our/hook.sh")
        #expect(!HarnessMemorySettings.hasHookEntry(in: result, commandPath: "/our/hook.sh"))
        // Other group must survive.
        let hooks = (result["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] ?? []
        #expect(hooks.count == 1)
        let remaining = hooks.first?["hooks"] as? [[String: Any]]
        #expect(remaining?.first?["command"] as? String == "/other.sh")
    }

    @Test("removeHookEntry cleans up empty hooks key")
    func removeHookEntryCleanup() {
        var root: [String: Any] = [:]
        root = HarnessMemorySettings.addHookEntry(to: root, commandPath: "/our/hook.sh")
        let result = HarnessMemorySettings.removeHookEntry(from: root, commandPath: "/our/hook.sh")
        #expect(result["hooks"] == nil)
    }

    // MARK: File-level enable / disable

    @Test("enable writes autoMemoryEnabled:false and hook entry; disable reverses to semantic equality")
    func enableDisableRoundTrip() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let home = dir.appendingPathComponent("home")
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true
        )

        // Pre-populate with some existing content so we verify merge, not overwrite.
        let initial: [String: Any] = ["permissions": ["allow": ["mcp__mootx01__moot_ping"]]]
        let initialData = try JSONSerialization.data(withJSONObject: initial, options: .prettyPrinted)
        try initialData.write(to: settingsURL)

        try HarnessMemorySettings.enable(settingsURL: settingsURL, homeDirectory: home)

        // Verify auto-memory disabled and hook present.
        let afterEnable = try HarnessMemorySettings.readSettings(at: settingsURL)
        #expect(afterEnable[HarnessMemorySettings.autoMemoryKey] as? Bool == false)
        #expect(HarnessMemorySettings.hasHookEntry(
            in: afterEnable,
            commandPath: HarnessMemorySettings.hookCommandPath(homeDirectory: home)
        ))
        // Pre-existing permissions entry must be preserved.
        let perms = afterEnable["permissions"] as? [String: Any]
        let allow = perms?["allow"] as? [String]
        #expect(allow?.contains("mcp__mootx01__moot_ping") == true)

        try HarnessMemorySettings.disable(settingsURL: settingsURL, homeDirectory: home)

        // After disable: auto-memory key gone, hook gone, original content preserved.
        let afterDisable = try HarnessMemorySettings.readSettings(at: settingsURL)
        #expect(afterDisable[HarnessMemorySettings.autoMemoryKey] == nil)
        #expect(!HarnessMemorySettings.hasHookEntry(
            in: afterDisable,
            commandPath: HarnessMemorySettings.hookCommandPath(homeDirectory: home)
        ))
        let perms2 = afterDisable["permissions"] as? [String: Any]
        let allow2 = perms2?["allow"] as? [String]
        #expect(allow2?.contains("mcp__mootx01__moot_ping") == true)
    }

    @Test("enable is idempotent: second call returns false and does not duplicate hook")
    func enableIdempotent() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true
        )

        let changed1 = try HarnessMemorySettings.enable(settingsURL: settingsURL, homeDirectory: home)
        let changed2 = try HarnessMemorySettings.enable(settingsURL: settingsURL, homeDirectory: home)
        #expect(changed1 == true)
        #expect(changed2 == false)

        // Exactly one hook group.
        let root = try HarnessMemorySettings.readSettings(at: settingsURL)
        let hooks = (root["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] ?? []
        #expect(hooks.count == 1)
    }

    @Test("disable is idempotent: second call returns false")
    func disableIdempotent() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true
        )

        try HarnessMemorySettings.enable(settingsURL: settingsURL, homeDirectory: home)
        let changed1 = try HarnessMemorySettings.disable(settingsURL: settingsURL, homeDirectory: home)
        let changed2 = try HarnessMemorySettings.disable(settingsURL: settingsURL, homeDirectory: home)
        #expect(changed1 == true)
        #expect(changed2 == false)
    }

    @Test("enable creates a backup before modifying settings.json")
    func enableCreatesBackup() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        let claudeDir = home.appendingPathComponent(".claude")
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        // Write a known file first.
        let original = "{\"existing\": true}"
        try original.write(to: settingsURL, atomically: true, encoding: .utf8)

        try HarnessMemorySettings.enable(settingsURL: settingsURL, homeDirectory: home)

        // At least one backup file should exist.
        let backups = try FileManager.default.contentsOfDirectory(atPath: claudeDir.path)
            .filter { $0.contains("mootx01-bak") }
        #expect(!backups.isEmpty, "A backup file must be created before the first write")
    }

    @Test("disable is a clean no-op when settings.json does not exist")
    func disableNoopWhenAbsent() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        let settingsURL = home.appendingPathComponent(".claude/settings.json")

        let changed = try HarnessMemorySettings.disable(settingsURL: settingsURL, homeDirectory: home)
        #expect(changed == false)
    }
}

// MARK: - HarnessMemoryCLAUDE tests

@Suite("HarnessMemoryCLAUDE")
struct HarnessMemoryCLAUDETests {

    @Test("mergeBlock appends block when absent")
    func mergeBlockAppends() {
        let initial = "# Existing content\n"
        let result = HarnessMemoryCLAUDE.mergeBlock(into: initial)
        #expect(result.contains(HarnessMemoryCLAUDE.beginMarker))
        #expect(result.contains(HarnessMemoryCLAUDE.endMarker))
        #expect(result.hasPrefix(initial))
    }

    @Test("mergeBlock is idempotent")
    func mergeBlockIdempotent() {
        let initial = "# Existing content\n"
        let once = HarnessMemoryCLAUDE.mergeBlock(into: initial)
        let twice = HarnessMemoryCLAUDE.mergeBlock(into: once)
        #expect(once == twice)
    }

    @Test("removeBlock removes our sentinel block")
    func removeBlockRemoves() {
        let initial = "# Before\n"
        let withBlock = HarnessMemoryCLAUDE.mergeBlock(into: initial)
        let result = HarnessMemoryCLAUDE.removeBlock(from: withBlock)
        #expect(!result.contains(HarnessMemoryCLAUDE.beginMarker))
        #expect(!result.contains(HarnessMemoryCLAUDE.endMarker))
        // Pre-existing content must survive.
        #expect(result.contains("# Before"))
    }

    @Test("removeBlock is idempotent: no-op when block absent")
    func removeBlockIdempotent() {
        let content = "# Some content\n"
        let result = HarnessMemoryCLAUDE.removeBlock(from: content)
        #expect(result == content)
    }

    @Test("hasBlock returns false when block absent")
    func hasBlockFalse() {
        #expect(!HarnessMemoryCLAUDE.hasBlock(in: "# Nothing here"))
    }

    @Test("hasBlock returns true when block present")
    func hasBlockTrue() {
        let content = HarnessMemoryCLAUDE.mergeBlock(into: "")
        #expect(HarnessMemoryCLAUDE.hasBlock(in: content))
    }

    @Test("enable + disable file round-trip")
    func fileRoundTrip() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        let url = HarnessMemoryPaths.globalCLAUDEMDURL(homeDirectory: home)

        // Enable on a non-existent file.
        try HarnessMemoryCLAUDE.enable(at: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let afterEnable = try String(contentsOf: url, encoding: .utf8)
        #expect(HarnessMemoryCLAUDE.hasBlock(in: afterEnable))

        // Disable removes the block.
        try HarnessMemoryCLAUDE.disable(at: url)
        let afterDisable = try String(contentsOf: url, encoding: .utf8)
        #expect(!HarnessMemoryCLAUDE.hasBlock(in: afterDisable))
    }

    @Test("enable on existing CLAUDE.md preserves pre-existing content")
    func enablePreservesExistingContent() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        let url = HarnessMemoryPaths.globalCLAUDEMDURL(homeDirectory: home)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let existing = "# My rules\nDo the thing.\n"
        try existing.write(to: url, atomically: true, encoding: .utf8)

        try HarnessMemoryCLAUDE.enable(at: url)
        let result = try String(contentsOf: url, encoding: .utf8)
        #expect(result.contains("# My rules"))
        #expect(result.contains(HarnessMemoryCLAUDE.beginMarker))
    }
}

// MARK: - HarnessMemoryHook tests

@Suite("HarnessMemoryHook")
struct HarnessMemoryHookTests {

    @Test("scriptContent contains the binary path and exec invocation")
    func scriptContent() {
        let content = HarnessMemoryHook.scriptContent(binaryPath: "/home/user/.mootx01/bin/mootx01")
        #expect(content.contains("/home/user/.mootx01/bin/mootx01"))
        #expect(content.contains("hook-capture"))
        #expect(content.hasPrefix("#!/bin/sh"))
    }

    @Test("install writes executable script; remove deletes it")
    func installRemove() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        let url = HarnessMemoryPaths.hookScriptURL(homeDirectory: home)

        try HarnessMemoryHook.install(at: url, binaryPath: "/usr/local/bin/mootx01")
        #expect(FileManager.default.fileExists(atPath: url.path))

        // Verify executable bit.
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = attrs[.posixPermissions] as? Int16 ?? 0
        #expect(perms & 0o111 != 0, "hook script must be executable (mode 0755)")

        try HarnessMemoryHook.remove(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("remove is a no-op when script does not exist")
    func removeNoopWhenAbsent() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        let url = HarnessMemoryPaths.hookScriptURL(homeDirectory: home)
        // Must not throw.
        try HarnessMemoryHook.remove(at: url)
    }
}

// MARK: - HarnessMemoryMatcher tests

@Suite("HarnessMemoryMatcher")
struct HarnessMemoryMatcherTests {

    @Test("match extracts slug and filename from a valid project-memory path")
    func matchValid() {
        let path = "/Users/alice/.claude/projects/my-project/memory/MEMORY.md"
        let result = HarnessMemoryMatcher.match(path: path)
        #expect(result?.projectSlug == "my-project")
        #expect(result?.fileName == "MEMORY.md")
    }

    @Test("match accepts URL-encoded project slugs")
    func matchURLEncoded() {
        let path = "/Users/alice/.claude/projects/%2FUsers%2Fbob%2FDevlop%2Frepo/memory/notes.md"
        let result = HarnessMemoryMatcher.match(path: path)
        #expect(result?.projectSlug == "%2FUsers%2Fbob%2FDevlop%2Frepo")
        #expect(result?.fileName == "notes.md")
    }

    @Test("match returns nil for a path outside project memory")
    func matchRejectsNonMemory() {
        let paths = [
            "/Users/alice/.claude/settings.json",
            "/Users/alice/.claude/projects/myproject/context.md",
            "/Users/alice/Documents/notes.md",
            "/Users/alice/.claude/projects/myproject/memory",  // directory, no filename
        ]
        for path in paths {
            #expect(HarnessMemoryMatcher.match(path: path) == nil, "Should not match: \(path)")
        }
    }

    @Test("match rejects dotfile filenames")
    func matchRejectsDotfile() {
        let path = "/Users/alice/.claude/projects/myproject/memory/.hidden"
        #expect(HarnessMemoryMatcher.match(path: path) == nil)
    }

    @Test("match rejects traversal in filename")
    func matchRejectsTraversal() {
        let path = "/Users/alice/.claude/projects/myproject/memory/../../../evil"
        // The ".." component is in the path but not necessarily in "memory/<name>"
        // depending on parse. Either way, traversal-containing paths must be refused.
        if let result = HarnessMemoryMatcher.match(path: path) {
            #expect(!result.fileName.contains(".."), "filename must not contain traversal")
        }
        // A nil match is also acceptable.
    }

    @Test("match rejects traversal with valid filename prefix (daemon-down regression)")
    func matchRejectsTraversalWithValidPrefix() {
        // Regression: `memory/z/../../settings.json` — "z" looks like a valid filename
        // but the path resolves outside the governed tree. match() must return nil so
        // the daemon-down allow fallback in handleWrite never fires for this path.
        let path = "/Users/alice/.claude/projects/myproject/memory/z/../../settings.json"
        #expect(HarnessMemoryMatcher.match(path: path) == nil,
                "traversal with valid filename prefix must be rejected")
    }
}

// MARK: - HarnessMemoryIngest tests

@Suite("HarnessMemoryIngest")
struct HarnessMemoryIngestTests {

    // Build a sandbox with a fake ~/.claude/projects/<slug>/memory/ layout.
    private func makeProjectFixture(
        slug: String,
        files: [(name: String, content: String)],
        home: URL,
        modificationDate: Date? = nil
    ) throws {
        let memoryDir = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        for (name, content) in files {
            let fileURL = memoryDir.appendingPathComponent(name)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            if let date = modificationDate {
                try FileManager.default.setAttributes(
                    [.modificationDate: date], ofItemAtPath: fileURL.path
                )
            }
        }
    }

    @Test("scanProjects finds memory files grouped by project slug")
    func scanProjectsFindsFiles() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")

        try makeProjectFixture(slug: "proj-a", files: [("notes.md", "Hello"), ("MEMORY.md", "# Index")], home: home)
        try makeProjectFixture(slug: "proj-b", files: [("facts.md", "World")], home: home)

        let result = HarnessMemoryIngest.scanProjects(homeDirectory: home)
        #expect(result["proj-a"]?.count == 2)
        #expect(result["proj-b"]?.count == 1)
    }

    @Test("scanProjects excludes hidden files")
    func scanProjectsExcludesHidden() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        try makeProjectFixture(slug: "proj", files: [(".hidden", "x"), ("visible.md", "y")], home: home)

        let result = HarnessMemoryIngest.scanProjects(homeDirectory: home)
        // Only the visible file should appear.
        let files = result["proj"] ?? []
        #expect(files.count == 1)
        #expect(files.first?.lastPathComponent == "visible.md")
    }

    @Test("ingestFile uses file mtime as event_time (temporally correct)")
    func ingestFileMtimeRoundTrip() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")

        // Use a fixed historical date as the file's mtime.
        let mtime = Date(timeIntervalSinceReferenceDate: 800_000_000) // ~2026-05-10
        try makeProjectFixture(
            slug: "myproject",
            files: [("notes.md", "My note")],
            home: home,
            modificationDate: mtime
        )

        let fileURL = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
            .appendingPathComponent("myproject/memory/notes.md")
        let daemon = MockDaemonClient()

        let result = await HarnessMemoryIngest.ingestFile(
            fileURL, projectSlug: "myproject", daemon: daemon, now: Date()
        )

        guard case .filed = result.outcome else {
            Issue.record("Expected .filed, got \(result.outcome)")
            return
        }
        #expect(daemon.filedMemories.count == 1)
        let filed = daemon.filedMemories[0]
        #expect(filed.location == "harness-import/myproject/notes.md")
        #expect(filed.content == "My note")
        #expect(!filed.subject.isEmpty, "subject must be non-empty")
        // Event time must match the file mtime (within 1 second tolerance for
        // filesystem mtime precision).
        #expect(abs(filed.eventTime.timeIntervalSince(mtime)) < 1.0,
                "event_time must be the file mtime, not ingestion time")
    }

    @Test("ingestFile removes source file only after confirmed estate write (MOVE semantics)")
    func ingestFileMoveSemantics() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        try makeProjectFixture(slug: "proj", files: [("test.md", "content")], home: home)

        let fileURL = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
            .appendingPathComponent("proj/memory/test.md")
        let daemon = MockDaemonClient()

        // Confirmed write → source removed.
        daemon.fileMemoryResult = true
        let result = await HarnessMemoryIngest.ingestFile(
            fileURL, projectSlug: "proj", daemon: daemon, now: Date()
        )
        guard case .filed = result.outcome else {
            Issue.record("Expected .filed, got \(result.outcome)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: fileURL.path),
                "source must be removed after confirmed write")
    }

    @Test("ingestFile leaves source intact when estate write fails")
    func ingestFileFailureLeavesSource() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        try makeProjectFixture(slug: "proj", files: [("fail.md", "content")], home: home)

        let fileURL = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
            .appendingPathComponent("proj/memory/fail.md")
        let daemon = MockDaemonClient()
        daemon.fileMemoryError = URLError(.networkConnectionLost)

        let result = await HarnessMemoryIngest.ingestFile(
            fileURL, projectSlug: "proj", daemon: daemon, now: Date()
        )
        guard case .failed = result.outcome else {
            Issue.record("Expected .failed, got \(result.outcome)")
            return
        }
        // Source must survive.
        #expect(FileManager.default.fileExists(atPath: fileURL.path),
                "source must be left intact when estate write fails")
    }

    @Test("ingestFile leaves other files intact when one fails mid-run")
    func ingestFileFailureLeavesRest() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        try makeProjectFixture(
            slug: "proj",
            files: [("ok.md", "good"), ("fail.md", "bad")],
            home: home
        )

        let projectsURL = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
        let okURL = projectsURL.appendingPathComponent("proj/memory/ok.md")
        let failURL = projectsURL.appendingPathComponent("proj/memory/fail.md")

        // ok.md succeeds; fail.md fails.
        let successDaemon = MockDaemonClient()
        let failDaemon = MockDaemonClient()
        failDaemon.fileMemoryError = URLError(.networkConnectionLost)

        let okResult = await HarnessMemoryIngest.ingestFile(
            okURL, projectSlug: "proj", daemon: successDaemon, now: Date()
        )
        let failResult = await HarnessMemoryIngest.ingestFile(
            failURL, projectSlug: "proj", daemon: failDaemon, now: Date()
        )

        guard case .filed = okResult.outcome else {
            Issue.record("Expected ok.md to be filed"); return
        }
        guard case .failed = failResult.outcome else {
            Issue.record("Expected fail.md to fail"); return
        }
        #expect(!FileManager.default.fileExists(atPath: okURL.path))
        #expect(FileManager.default.fileExists(atPath: failURL.path))
    }

    @Test("ingestFile uses kind=list for MEMORY.md files")
    func ingestFileMEMORYMDKind() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        try makeProjectFixture(slug: "proj", files: [("MEMORY.md", "# Index")], home: home)

        let fileURL = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
            .appendingPathComponent("proj/memory/MEMORY.md")
        let daemon = MockDaemonClient()
        _ = await HarnessMemoryIngest.ingestFile(fileURL, projectSlug: "proj", daemon: daemon, now: Date())

        #expect(daemon.filedMemories.first?.kind == "list")
        #expect(!(daemon.filedMemories.first?.subject.isEmpty ?? true), "MEMORY.md ingest must carry a non-empty subject")
    }

    @Test("ingestFile: an authored MEMORY.md (no id, no generated marker) is filed with kind=list")
    func ingestFileAuthoredIndexFiles() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        // Authored by hand with its own front matter; neither carrier key present.
        let authored = "---\nname: index\nmetadata:\n  type: list\n---\n# Memory Index\n\n- [a.md](a.md)\n"
        try makeProjectFixture(slug: "proj", files: [("MEMORY.md", authored)], home: home)

        let fileURL = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
            .appendingPathComponent("proj/memory/MEMORY.md")
        let daemon = MockDaemonClient()
        let result = await HarnessMemoryIngest.ingestFile(fileURL, projectSlug: "proj", daemon: daemon, now: Date())

        guard case .filed = result.outcome else {
            Issue.record("Expected .filed, got \(result.outcome)"); return
        }
        #expect(daemon.filedMemories.count == 1)
        #expect(daemon.filedMemories.first?.kind == "list")
        #expect(daemon.filedMemories.first?.content == authored, "authored bytes reach the estate unchanged")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: Re-enable: restored files carry their estate id in front matter

    private func makeRestoredFile(
        slug: String, name: String, body: String, memoryId: String, home: URL
    ) throws -> URL {
        let onDisk = HarnessMemoryFrontMatter.inject(body, memoryId: memoryId)
        try makeProjectFixture(slug: slug, files: [(name, onDisk)], home: home)
        return HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
            .appendingPathComponent("\(slug)/memory/\(name)")
    }

    @Test("re-enable: unchanged content matches its row, file removed, no estate write")
    func reEnableMatchedUnchanged() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        let fileURL = try makeRestoredFile(
            slug: "proj", name: "notes.md", body: kMemoryFileBody, memoryId: "id-1", home: home
        )
        let daemon = MockDaemonClient()
        daemon.getMemoryResult["id-1"] = makeRecord(
            id: "id-1", location: "harness-import/proj/notes.md", content: kMemoryFileBody
        )

        let result = await HarnessMemoryIngest.ingestFile(fileURL, projectSlug: "proj", daemon: daemon)

        guard case .matched = result.outcome else {
            Issue.record("Expected .matched, got \(result.outcome)"); return
        }
        #expect(daemon.gottenIds == ["id-1"])
        #expect(daemon.filedMemories.isEmpty, "a matched row is never re-filed")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path), "matched file is removed")
    }

    @Test("summary line: two matched files print as matched, never as filed, with zero filings")
    func summaryLineMatchedIsNotFiled() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        let daemon = MockDaemonClient()
        var results: [IngestResult] = []
        for (id, name) in [("id-a", "a.md"), ("id-b", "b.md")] {
            let fileURL = try makeRestoredFile(slug: "proj", name: name, body: kMemoryFileBody, memoryId: id, home: home)
            daemon.getMemoryResult[id] = makeRecord(id: id, location: "harness-import/proj/\(name)", content: kMemoryFileBody)
            results.append(await HarnessMemoryIngest.ingestFile(fileURL, projectSlug: "proj", daemon: daemon))
        }
        // The Rust port prints exactly this line for the same two inputs.
        #expect(HarnessMemoryIngest.summaryLine(results) == "filed 0, matched 2, discarded indexes 0, removed 2, skipped 0")
        #expect(daemon.filedMemories.isEmpty, "zero moot_file_memory calls back the printed word")
    }

    @Test("re-enable: changed content files fresh at the row's location; the old row is left untouched")
    func reEnableFilesFreshOnChange() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        let fileURL = try makeRestoredFile(
            slug: "proj", name: "notes.md", body: kMemoryFileBodyChanged, memoryId: "id-2", home: home
        )
        let daemon = MockDaemonClient()
        daemon.getMemoryResult["id-2"] = makeRecord(
            id: "id-2", location: "harness-import/proj/notes.md", content: kMemoryFileBody
        )

        let result = await HarnessMemoryIngest.ingestFile(fileURL, projectSlug: "proj", daemon: daemon)

        guard case .filed = result.outcome else {
            Issue.record("Expected .filed, got \(result.outcome)"); return
        }
        #expect(daemon.filedMemories.count == 1, "exactly one moot_file_memory call, no mutation call of any kind")
        #expect(daemon.filedMemories.first?.location == "harness-import/proj/notes.md")
        #expect(daemon.filedMemories.first?.content == kMemoryFileBodyChanged,
                "the filed content is the stripped body, without moot_memory_id")
        #expect(!(daemon.filedMemories.first?.content.contains("moot_memory_id") ?? true))
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("re-enable: a failed filing on changed content leaves the file on disk and touches no row")
    func reEnableFilingFailsLeavesFile() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        let fileURL = try makeRestoredFile(
            slug: "proj", name: "notes.md", body: kMemoryFileBodyChanged, memoryId: "id-3", home: home
        )
        let daemon = MockDaemonClient()
        daemon.getMemoryResult["id-3"] = makeRecord(
            id: "id-3", location: "harness-import/proj/notes.md", content: kMemoryFileBody
        )
        daemon.fileMemoryError = URLError(.networkConnectionLost)

        let result = await HarnessMemoryIngest.ingestFile(fileURL, projectSlug: "proj", daemon: daemon)

        guard case .failed = result.outcome else {
            Issue.record("Expected .failed, got \(result.outcome)"); return
        }
        #expect(daemon.filedMemories.isEmpty, "the failed call never confirmed a write")
        #expect(FileManager.default.fileExists(atPath: fileURL.path), "file stays for the next sweep")
    }

    @Test("re-enable: unknown id files the stripped body fresh")
    func reEnableUnknownIdFilesFresh() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        let fileURL = try makeRestoredFile(
            slug: "proj", name: "notes.md", body: kMemoryFileBody, memoryId: "id-4", home: home
        )
        let daemon = MockDaemonClient()   // no row for id-4: getMemory answers nil

        let result = await HarnessMemoryIngest.ingestFile(fileURL, projectSlug: "proj", daemon: daemon)

        guard case .filed = result.outcome else {
            Issue.record("Expected .filed, got \(result.outcome)"); return
        }
        #expect(daemon.gottenIds == ["id-4"])
        #expect(daemon.filedMemories.count == 1)
        #expect(daemon.filedMemories.first?.location == "harness-import/proj/notes.md")
        #expect(daemon.filedMemories.first?.content == kMemoryFileBody)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("ingest: a file without moot_memory_id files unchanged and never asks the estate")
    func noFrontMatterIdFilesFresh() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        try makeProjectFixture(slug: "proj", files: [("notes.md", kMemoryFileBody)], home: home)
        let fileURL = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
            .appendingPathComponent("proj/memory/notes.md")
        let daemon = MockDaemonClient()

        let result = await HarnessMemoryIngest.ingestFile(fileURL, projectSlug: "proj", daemon: daemon)

        guard case .filed = result.outcome else {
            Issue.record("Expected .filed, got \(result.outcome)"); return
        }
        #expect(daemon.gottenIds.isEmpty, "no id, no lookup")
        #expect(daemon.filedMemories.count == 1)
        #expect(daemon.filedMemories.first?.content == kMemoryFileBody, "content filed byte-identical")
    }

    @Test("re-enable: a row at another location does not match; the body files fresh")
    func reEnableRowElsewhereFilesFresh() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        let fileURL = try makeRestoredFile(
            slug: "proj", name: "notes.md", body: kMemoryFileBody, memoryId: "id-6", home: home
        )
        let daemon = MockDaemonClient()
        daemon.getMemoryResult["id-6"] = makeRecord(
            id: "id-6", location: "harness-import/other-project/notes.md", content: kMemoryFileBody
        )

        let result = await HarnessMemoryIngest.ingestFile(fileURL, projectSlug: "proj", daemon: daemon)

        guard case .filed = result.outcome else {
            Issue.record("Expected .filed, got \(result.outcome)"); return
        }
        #expect(daemon.filedMemories.first?.location == "harness-import/proj/notes.md")
    }

    @Test("re-enable: a hook-captured row (harness/<slug>/<name>) matches too")
    func reEnableCapturedRowMatches() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        let fileURL = try makeRestoredFile(
            slug: "proj", name: "captured.md", body: kMemoryFileBody, memoryId: "id-7", home: home
        )
        let daemon = MockDaemonClient()
        daemon.getMemoryResult["id-7"] = makeRecord(
            id: "id-7", location: "harness/proj/captured.md", content: kMemoryFileBody
        )

        let result = await HarnessMemoryIngest.ingestFile(fileURL, projectSlug: "proj", daemon: daemon)

        guard case .matched = result.outcome else {
            Issue.record("Expected .matched, got \(result.outcome)"); return
        }
        #expect(daemon.filedMemories.isEmpty)
    }

    @Test("re-enable: a changed hook-captured row files fresh at the row's own harness/ location")
    func reEnableCapturedRowChangedFilesInPlace() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        let fileURL = try makeRestoredFile(
            slug: "proj", name: "note.md", body: kMemoryFileBodyChanged, memoryId: "id-9", home: home
        )
        let daemon = MockDaemonClient()
        daemon.getMemoryResult["id-9"] = makeRecord(
            id: "id-9", location: "harness/proj/note.md", content: kMemoryFileBody
        )

        let result = await HarnessMemoryIngest.ingestFile(fileURL, projectSlug: "proj", daemon: daemon)

        guard case .filed = result.outcome else {
            Issue.record("Expected .filed, got \(result.outcome)"); return
        }
        #expect(daemon.filedMemories.count == 1, "exactly one moot_file_memory call, no mutation call of any kind")
        #expect(daemon.filedMemories[0].location == "harness/proj/note.md", "a harness/ row stays a harness/ row")
        #expect(daemon.filedMemories[0].content == kMemoryFileBodyChanged)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("re-enable: a failed lookup leaves the file and files nothing (no duplicate risk)")
    func reEnableLookupFailureLeavesFile() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        let fileURL = try makeRestoredFile(
            slug: "proj", name: "notes.md", body: kMemoryFileBody, memoryId: "id-8", home: home
        )
        let daemon = MockDaemonClient()
        daemon.getMemoryError = URLError(.networkConnectionLost)

        let result = await HarnessMemoryIngest.ingestFile(fileURL, projectSlug: "proj", daemon: daemon)

        guard case .failed = result.outcome else {
            Issue.record("Expected .failed, got \(result.outcome)"); return
        }
        #expect(daemon.filedMemories.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }
}

// MARK: - HarnessMemoryRestore tests

@Suite("HarnessMemoryRestore")
struct HarnessMemoryRestoreTests {

    private func restoredResults(_ results: [RestoreResult]) -> [RestoreResult] {
        results.filter { if case .restored = $0.outcome { return true }; return false }
    }

    @Test("restore writes the file with moot_memory_id front matter and leaves the row untouched")
    func restoreWritesFile() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")

        let daemon = MockDaemonClient()
        daemon.listMemoriesResult = [
            makeRecord(id: "dr-1", location: "harness-import/my-project/notes.md", content: kMemoryFileBody)
        ]

        let results = await HarnessMemoryRestore.restore(homeDirectory: home, daemon: daemon)

        let expectedPath = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
            .appendingPathComponent("my-project/memory/notes.md").path
        #expect(FileManager.default.fileExists(atPath: expectedPath))
        let written = try String(contentsOfFile: expectedPath, encoding: .utf8)
        #expect(written == HarnessMemoryFrontMatter.inject(kMemoryFileBody, memoryId: "dr-1"))
        let stripped = HarnessMemoryFrontMatter.strip(written)
        #expect(stripped.memoryId == "dr-1")
        #expect(stripped.body == kMemoryFileBody)

        #expect(daemon.listedPrefixes == ["harness"], "one discovery query covers both location classes")
        #expect(restoredResults(results).count == 1)
    }

    @Test("restore refuses to overwrite an existing file (collision refusal)")
    func restoreRefusesOverwrite() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")

        // Pre-create the target file.
        let memoryDir = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
            .appendingPathComponent("proj/memory")
        try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        let existingContent = "Existing content"
        try existingContent.write(
            to: memoryDir.appendingPathComponent("notes.md"),
            atomically: true, encoding: .utf8
        )

        let daemon = MockDaemonClient()
        daemon.listMemoriesResult = [
            makeRecord(id: "dr-2", location: "harness-import/proj/notes.md", content: kMemoryFileBody)
        ]

        let results = await HarnessMemoryRestore.restore(homeDirectory: home, daemon: daemon)

        // File must not be overwritten.
        let path = memoryDir.appendingPathComponent("notes.md").path
        let onDisk = try String(contentsOfFile: path, encoding: .utf8)
        #expect(onDisk == existingContent, "existing file must not be overwritten")

        // Result must report a collision skip.
        let skipped = results.first {
            if case .skipped = $0.outcome { return true }; return false
        }
        #expect(skipped != nil)
    }

    @Test("restore: harness/* (born-in-estate) memories are also restored, with their id")
    func restoreHarnessBornMemories() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")

        let daemon = MockDaemonClient()
        // A memory born in the estate via the capture hook (location class harness/*).
        daemon.listMemoriesResult = [
            makeRecord(id: "dr-3", location: "harness/proj/captured.md", content: kMemoryFileBody)
        ]

        let results = await HarnessMemoryRestore.restore(homeDirectory: home, daemon: daemon)

        let expectedPath = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
            .appendingPathComponent("proj/memory/captured.md").path
        let written = try String(contentsOfFile: expectedPath, encoding: .utf8)
        #expect(written == HarnessMemoryFrontMatter.inject(kMemoryFileBody, memoryId: "dr-3"))
        #expect(restoredResults(results).count == 1)
    }

    @Test("restore dedupes by id, skips superseded rows, rejects traversal, ignores other prefixes")
    func restoreFiltersDiscovery() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")

        let daemon = MockDaemonClient()
        daemon.listMemoriesResult = [
            makeRecord(id: "dup", location: "harness-import/proj/a.md", content: "A"),
            makeRecord(id: "dup", location: "harness-import/proj/a.md", content: "A"),
            makeRecord(id: "old", location: "harness-import/proj/b.md", content: "B", isSuperseded: true),
            makeRecord(id: "trav", location: "harness-import/../escape.md", content: "X"),
            makeRecord(id: "hidden", location: "harness/proj/.secret.md", content: "X"),
            makeRecord(id: "deep", location: "harness-import/proj/sub/c.md", content: "X"),
            makeRecord(id: "other", location: "harness-other/proj/d.md", content: "X"),
        ]

        let results = await HarnessMemoryRestore.restore(homeDirectory: home, daemon: daemon)

        let memoryDir = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
            .appendingPathComponent("proj/memory")
        let onDisk = Set((try? FileManager.default.contentsOfDirectory(atPath: memoryDir.path)) ?? [])
        #expect(onDisk == ["a.md", "MEMORY.md"], "one file plus the regenerated index; got \(onDisk)")
        #expect(restoredResults(results).count == 1)
        let skipped = results.filter { if case .skipped = $0.outcome { return true }; return false }
        #expect(skipped.map(\.location).sorted() == [
            "harness-import/../escape.md", "harness-import/proj/sub/c.md", "harness/proj/.secret.md",
        ], "rows under our prefixes with an unrestorable shape are reported")
        #expect(!results.contains { $0.location == "harness-other/proj/d.md" },
                "rows under another prefix are not ours to report")
        #expect(!FileManager.default.fileExists(
            atPath: HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home).appendingPathComponent("escape.md").path))
    }

    @Test("restore: a failed enumeration is one .failed result and writes nothing")
    func restoreEnumerationFailure() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")

        let daemon = MockDaemonClient()
        daemon.listMemoriesError = DaemonError.refused(code: "estate_unavailable", message: "closed")
        daemon.listMemoriesResult = [
            makeRecord(id: "dr-x", location: "harness-import/proj/notes.md", content: kMemoryFileBody)
        ]

        let results = await HarnessMemoryRestore.restore(homeDirectory: home, daemon: daemon)

        #expect(results.count == 1)
        guard case .failed(let reason) = results[0].outcome else {
            Issue.record("Expected .failed, got \(results[0].outcome)"); return
        }
        #expect(reason.hasPrefix("Estate enumeration failed:"))
        let projectsURL = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
        #expect(!FileManager.default.fileExists(atPath: projectsURL.path), "nothing written")
    }

    @Test("restore regenerates one MEMORY.md per slug listing only that slug's files")
    func restoreMemoryIndexPerSlug() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")

        let daemon = MockDaemonClient()
        daemon.listMemoriesResult = [
            makeRecord(id: "a1", location: "harness-import/alpha/one.md", content: "1"),
            makeRecord(id: "b1", location: "harness-import/beta/two.md", content: "2"),
            makeRecord(id: "b2", location: "harness/beta/three.md", content: "3"),
        ]

        _ = await HarnessMemoryRestore.restore(homeDirectory: home, daemon: daemon)

        let projectsURL = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
        let alphaIndex = try String(
            contentsOf: projectsURL.appendingPathComponent("alpha/memory/MEMORY.md"), encoding: .utf8)
        let betaIndex = try String(
            contentsOf: projectsURL.appendingPathComponent("beta/memory/MEMORY.md"), encoding: .utf8)
        #expect(alphaIndex == kGeneratedIndexPrefix + "# Memory Index\n\n- [one.md](one.md)\n")
        // Names are sorted in byte order, not in the order the estate listed the rows.
        #expect(betaIndex == kGeneratedIndexPrefix + "# Memory Index\n\n- [three.md](three.md)\n- [two.md](two.md)\n")
    }

    @Test("restore: generated MEMORY.md bytes are pinned (shared vector, both ports)")
    func restoreGeneratedIndexBytes() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")

        let daemon = MockDaemonClient()
        daemon.listMemoriesResult = [
            makeRecord(id: "id-b", location: "harness-import/slug/b.md", content: "B"),
            makeRecord(id: "id-a", location: "harness-import/slug/a.md", content: "A"),
        ]
        _ = await HarnessMemoryRestore.restore(homeDirectory: home, daemon: daemon)

        let indexURL = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
            .appendingPathComponent("slug/memory/MEMORY.md")
        let index = try String(contentsOf: indexURL, encoding: .utf8)
        #expect(index == "---\nmetadata:\n  moot_generated_index: true\n---\n# Memory Index\n\n- [a.md](a.md)\n- [b.md](b.md)\n")
        let marker = HarnessMemoryFrontMatter.strip(index, key: HarnessMemoryFrontMatter.generatedIndexKey)
        #expect(marker.value == "true")
        #expect(HarnessMemoryFrontMatter.strip(index).memoryId == nil, "a generated index carries no memory id")
    }

    @Test("restore then re-ingest: the generated MEMORY.md is discarded, both files match, nothing filed")
    func restoreThenReIngestDiscardsGeneratedIndex() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")

        let rows = [
            makeRecord(id: "id-a", location: "harness-import/slug/a.md", content: "A"),
            makeRecord(id: "id-b", location: "harness-import/slug/b.md", content: "B"),
        ]
        let restoreDaemon = MockDaemonClient()
        restoreDaemon.listMemoriesResult = rows
        _ = await HarnessMemoryRestore.restore(homeDirectory: home, daemon: restoreDaemon)

        let memoryDir = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
            .appendingPathComponent("slug/memory")
        let names = try FileManager.default.contentsOfDirectory(atPath: memoryDir.path).sorted()
        #expect(names == ["MEMORY.md", "a.md", "b.md"])
        let index = try String(contentsOf: memoryDir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        #expect(index == "---\nmetadata:\n  moot_generated_index: true\n---\n# Memory Index\n\n- [a.md](a.md)\n- [b.md](b.md)\n")

        let reEnableDaemon = MockDaemonClient()
        for row in rows { reEnableDaemon.getMemoryResult[row.id] = row }
        var outcomes: [String] = []
        for name in ["a.md", "b.md", "MEMORY.md"] {
            let result = await HarnessMemoryIngest.ingestFile(
                memoryDir.appendingPathComponent(name), projectSlug: "slug", daemon: reEnableDaemon)
            switch result.outcome {
            case .matched: outcomes.append("matched")
            case .discardedIndex: outcomes.append("discardedIndex")
            default: outcomes.append("\(result.outcome)")
            }
        }
        #expect(outcomes == ["matched", "matched", "discardedIndex"])
        #expect(reEnableDaemon.filedMemories.isEmpty, "a disable → enable cycle adds no estate row")
        #expect(reEnableDaemon.gottenIds.sorted() == ["id-a", "id-b"], "the index makes no estate call")
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: memoryDir.path)) ?? ["unreadable"]
        #expect(remaining.isEmpty, "directory empty after re-ingest; got \(remaining)")
    }

    @Test("full round-trip: ingest → restore → ingest leaves every id in place, nothing re-filed")
    func fullRoundTrip() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")

        let slug = "round-trip-project"
        let mtime = Date(timeIntervalSinceReferenceDate: 700_000_000)

        // Set up fixture: a memory file plus the MEMORY.md index.
        let memoryDir = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
            .appendingPathComponent("\(slug)/memory")
        try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        let noteURL = memoryDir.appendingPathComponent("important.md")
        let indexURL = memoryDir.appendingPathComponent("MEMORY.md")
        try kMemoryFileBody.write(to: noteURL, atomically: true, encoding: .utf8)
        try kMemoryIndexBody.write(to: indexURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: noteURL.path)

        // Ingest phase — use a mock that records what was filed.
        let ingestDaemon = MockDaemonClient()
        for url in [noteURL, indexURL] {
            let ingestResult = await HarnessMemoryIngest.ingestFile(url, projectSlug: slug, daemon: ingestDaemon)
            guard case .filed = ingestResult.outcome else {
                Issue.record("Ingest failed: \(ingestResult.outcome)"); return
            }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        #expect(ingestDaemon.filedMemories.count == 2)
        let filedNote = ingestDaemon.filedMemories[0]
        #expect(abs(filedNote.eventTime.timeIntervalSince(mtime)) < 1.0, "event_time must equal file mtime")
        #expect(!filedNote.subject.isEmpty, "ingest round-trip must carry a non-empty subject")
        #expect(ingestDaemon.filedMemories[1].kind == "list")

        // Restore phase: the mock returns the filed records with their estate ids.
        let restoreDaemon = MockDaemonClient()
        let rows = ingestDaemon.filedMemories.enumerated().map { index, filed in
            makeRecord(id: "row-\(index)", location: filed.location, content: filed.content)
        }
        restoreDaemon.listMemoriesResult = rows
        let restoreResults = await HarnessMemoryRestore.restore(homeDirectory: home, daemon: restoreDaemon)
        #expect(restoredResults(restoreResults).count == 2)

        // Files are back at their paths with the id in front matter and the body intact.
        let restoredNote = try String(contentsOf: noteURL, encoding: .utf8)
        #expect(restoredNote == HarnessMemoryFrontMatter.inject(kMemoryFileBody, memoryId: "row-0"))
        let restoredIndex = try String(contentsOf: indexURL, encoding: .utf8)
        #expect(restoredIndex == HarnessMemoryFrontMatter.inject(kMemoryIndexBody, memoryId: "row-1"))

        // Re-enable: every file matches its row; nothing is filed or mutated.
        let reEnableDaemon = MockDaemonClient()
        for row in rows { reEnableDaemon.getMemoryResult[row.id] = row }
        for url in [noteURL, indexURL] {
            let again = await HarnessMemoryIngest.ingestFile(url, projectSlug: slug, daemon: reEnableDaemon)
            guard case .matched = again.outcome else {
                Issue.record("Expected .matched for \(url.lastPathComponent), got \(again.outcome)"); return
            }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        #expect(reEnableDaemon.gottenIds.sorted() == ["row-0", "row-1"])
        #expect(reEnableDaemon.filedMemories.isEmpty, "ids unchanged: nothing re-filed")
    }
}

// MARK: - HarnessMemoryFrontMatter tests (shared vector, pinned in both ports)

@Suite("HarnessMemoryFrontMatter")
struct HarnessMemoryFrontMatterTests {

    private let vector1 = kMemoryFileBody
    private let vector2 = "---\nname: x\n---\nbody\n"
    private let vector3 = "# Memory Index\n"

    @Test("inject: block with metadata: gets the id line directly after metadata:")
    func injectAfterMetadata() {
        let out = HarnessMemoryFrontMatter.inject(vector1, memoryId: "abc")
        #expect(out == "---\nname: bob-viewport\ndescription: \"wide\"\nmetadata:\n  moot_memory_id: abc\n  node_type: memory\n  type: user\n  originSessionId: ca2fd6e7\n---\nbody\n")
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.filter { $0 == "---" }.count == 2, "exactly one front matter document")
        #expect(lines.filter { $0 == "metadata:" }.count == 1)
        let topKeys = lines[1..<8].filter { !$0.hasPrefix("  ") }.map { String($0.split(separator: ":")[0]) }
        #expect(topKeys == ["name", "description", "metadata"])
        let metadataKeys = lines[1..<8].filter { $0.hasPrefix("  ") }.map {
            String($0.dropFirst(2).split(separator: ":")[0])
        }
        #expect(Set(metadataKeys) == ["moot_memory_id", "node_type", "type", "originSessionId"])
        let stripped = HarnessMemoryFrontMatter.strip(out)
        #expect(stripped.memoryId == "abc")
        #expect(stripped.body == vector1)
    }

    @Test("inject: block without metadata: gains metadata: and the id line before the closing fence")
    func injectBeforeClosingFence() {
        let out = HarnessMemoryFrontMatter.inject(vector2, memoryId: "abc")
        #expect(out == "---\nname: x\nmetadata:\n  moot_memory_id: abc\n---\nbody\n")
        let stripped = HarnessMemoryFrontMatter.strip(out)
        #expect(stripped.memoryId == "abc")
        #expect(stripped.body == vector2)
    }

    @Test("inject: no block (MEMORY.md) gains a four-line block holding only the id")
    func injectPrependsBlock() {
        let out = HarnessMemoryFrontMatter.inject(vector3, memoryId: "abc")
        #expect(out == "---\nmetadata:\n  moot_memory_id: abc\n---\n# Memory Index\n")
        let stripped = HarnessMemoryFrontMatter.strip(out)
        #expect(stripped.memoryId == "abc")
        #expect(stripped.body == vector3)
    }

    @Test("strip: no id line leaves the content unchanged and answers nil")
    func stripWithoutIdIsIdentity() {
        for content in [vector1, vector2, vector3, "", "---\n", "---\nmetadata:\n---\n"] {
            let stripped = HarnessMemoryFrontMatter.strip(content)
            #expect(stripped.memoryId == nil)
            #expect(stripped.body == content)
        }
    }

    @Test("strip: id value is trimmed; a metadata: line keeps its other children")
    func stripTrimsAndKeepsSiblings() {
        let content = "---\nmetadata:\n  moot_memory_id:   spaced  \n  type: user\n---\nbody\n"
        let stripped = HarnessMemoryFrontMatter.strip(content)
        #expect(stripped.memoryId == "spaced")
        #expect(stripped.body == "---\nmetadata:\n  type: user\n---\nbody\n")
    }

    @Test("inject / strip with a second key leaves an existing moot_memory_id line untouched")
    func secondKeyRoundTripKeepsMemoryId() {
        let withId = HarnessMemoryFrontMatter.inject(vector1, memoryId: "abc")
        let out = HarnessMemoryFrontMatter.inject(
            withId, key: HarnessMemoryFrontMatter.generatedIndexKey, value: "true")
        #expect(out == "---\nname: bob-viewport\ndescription: \"wide\"\nmetadata:\n  moot_generated_index: true\n  moot_memory_id: abc\n  node_type: memory\n  type: user\n  originSessionId: ca2fd6e7\n---\nbody\n")

        let marker = HarnessMemoryFrontMatter.strip(out, key: HarnessMemoryFrontMatter.generatedIndexKey)
        #expect(marker.value == "true")
        #expect(marker.body == withId, "stripping the second key is the byte inverse of injecting it")
        #expect(HarnessMemoryFrontMatter.strip(out).memoryId == "abc")
        #expect(HarnessMemoryFrontMatter.strip(marker.body).body == vector1)
        let absent = HarnessMemoryFrontMatter.strip(withId, key: HarnessMemoryFrontMatter.generatedIndexKey)
        #expect(absent.value == nil)
        #expect(absent.body == withId)
    }
}

// MARK: - Uninstall cleanup (Finding 2)
//
// Verifies that the three cleanup calls made by UninstallCommand's full-teardown
// block (HarnessMemorySettings.disable + HarnessMemoryHook.remove +
// HarnessMemoryCLAUDE.disable) leave the system clean when harness-memory was
// enabled, and are no-ops when it was not.

@Suite("HarnessMemory uninstall cleanup")
struct HarnessMemoryUninstallTests {

    @Test("uninstall on enabled fixture removes hook entry, hook script, and sentinel")
    func uninstallOnEnabledFixtureCleans() throws {
        let sandbox = try makeSandboxDir(tag: "uninstall-enabled")
        defer { cleanupSandbox(sandbox) }

        let home = sandbox.appendingPathComponent("home")
        let fm = FileManager.default

        // Settings.json with hook entry + autoMemoryEnabled:false.
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let hookPath = HarnessMemoryPaths.hookScriptURL(homeDirectory: home).path
        var settings: [String: Any] = ["autoMemoryEnabled": false]
        let hookEntry: [String: Any] = [
            "matcher": "Write|Edit|MultiEdit",
            "hooks": [["type": "command", "command": hookPath] as [String: Any]]
        ]
        settings["hooks"] = ["PreToolUse": [hookEntry]] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: settings, options: .prettyPrinted)
        try data.write(to: settingsURL)

        // CLAUDE.md with sentinel block.
        let claudeURL = HarnessMemoryPaths.globalCLAUDEMDURL(homeDirectory: home)
        let sentinel = HarnessMemoryCLAUDE.mergeBlock(into: "# Existing content\n")
        try sentinel.write(to: claudeURL, atomically: true, encoding: .utf8)

        // Hook script on disk.
        let hookURL = HarnessMemoryPaths.hookScriptURL(homeDirectory: home)
        try fm.createDirectory(at: hookURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexec mootx01 hook-capture\n".write(to: hookURL, atomically: true, encoding: .utf8)

        // --- Run the same cleanup sequence as UninstallCommand ---
        _ = try? HarnessMemorySettings.disable(settingsURL: settingsURL, homeDirectory: home)
        try? HarnessMemoryHook.remove(at: hookURL)
        try? HarnessMemoryCLAUDE.disable(at: claudeURL)

        // settings.json must have no hook entry.
        let updatedData = try Data(contentsOf: settingsURL)
        let updated = try JSONSerialization.jsonObject(with: updatedData) as! [String: Any]
        #expect(!HarnessMemorySettings.hasHookEntry(in: updated, commandPath: hookPath),
                "hook entry must be removed from settings.json")

        // CLAUDE.md must have no sentinel.
        let updatedClaude = try String(contentsOf: claudeURL, encoding: .utf8)
        #expect(!HarnessMemoryCLAUDE.hasBlock(in: updatedClaude),
                "CLAUDE.md sentinel must be removed")

        // Hook script must not exist.
        #expect(!fm.fileExists(atPath: hookURL.path),
                "hook script must be deleted on uninstall")
    }

    @Test("uninstall on clean fixture is a no-op")
    func uninstallOnCleanFixtureIsNoop() throws {
        let sandbox = try makeSandboxDir(tag: "uninstall-clean")
        defer { cleanupSandbox(sandbox) }

        let home = sandbox.appendingPathComponent("home")
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        let claudeURL = HarnessMemoryPaths.globalCLAUDEMDURL(homeDirectory: home)
        let hookURL = HarnessMemoryPaths.hookScriptURL(homeDirectory: home)

        // Nothing exists — cleanup must not crash.
        _ = try? HarnessMemorySettings.disable(settingsURL: settingsURL, homeDirectory: home)
        try? HarnessMemoryHook.remove(at: hookURL)
        try? HarnessMemoryCLAUDE.disable(at: claudeURL)

        // No files should have been created.
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: settingsURL.path), "settings.json must not be created")
        #expect(!fm.fileExists(atPath: hookURL.path), "hook script must not be created")
    }
}

// MARK: - extractSubject tests

@Suite("HarnessMemoryIngest.extractSubject")
struct ExtractSubjectTests {

    @Test("returns first non-blank non-heading line from multi-line markdown")
    func returnsFirstContentLine() {
        let content = """
        # Project Notes

        This is the first real line.
        And another line.
        """
        let result = HarnessMemoryIngest.extractSubject(from: content, fileName: "notes.md")
        #expect(result == "This is the first real line.")
    }

    @Test("truncates long first content line at 120 characters")
    func truncatesAt120Chars() {
        let longLine = String(repeating: "x", count: 200)
        let content = "# Heading\n\(longLine)"
        let result = HarnessMemoryIngest.extractSubject(from: content, fileName: "notes.md")
        #expect(result.count == 120)
        #expect(result == String(repeating: "x", count: 120))
    }

    @Test("falls back to filename stem when content is all headings")
    func fallbackOnHeadingOnlyContent() {
        let content = """
        # Heading One
        ## Heading Two
        ### Heading Three
        """
        let result = HarnessMemoryIngest.extractSubject(from: content, fileName: "my-notes.md")
        #expect(result == "my-notes")
    }

    @Test("falls back to filename stem when content is all blank lines")
    func fallbackOnBlankContent() {
        let result = HarnessMemoryIngest.extractSubject(from: "\n\n\n", fileName: "ideas.md")
        #expect(result == "ideas")
    }

    @Test("falls back to filename stem for non-.md files")
    func fallbackForNonMdFile() {
        let result = HarnessMemoryIngest.extractSubject(from: "", fileName: "config.json")
        #expect(result == "config.json")
    }

    @Test("trims whitespace from content line")
    func trimsWhitespace() {
        let content = "   leading and trailing spaces   "
        let result = HarnessMemoryIngest.extractSubject(from: content, fileName: "notes.md")
        #expect(result == "leading and trailing spaces")
    }
}

// MARK: - LiveDaemonClient v2 parser tests

/// Mock URLProtocol that returns a queue of pre-baked HTTP responses and
/// records every JSON-RPC request body it receives.
/// Used to drive LiveDaemonClient through the v2 envelope without a live daemon.
final class QueuedResponseProtocol: URLProtocol, @unchecked Sendable {
    /// Shared queue of (statusCode, body) pairs consumed in FIFO order.
    nonisolated(unsafe) static var responseQueue: [(Int, Data)] = []
    /// Every request body received since the last `enqueue`, decoded as JSON.
    nonisolated(unsafe) static var recordedRequests: [[String: Any]] = []
    static let lock = NSLock()

    static func enqueue(_ pairs: [(Int, Data)]) {
        lock.lock(); defer { lock.unlock() }
        responseQueue = pairs
        recordedRequests = []
    }

    /// Tool name of a recorded request (`params.name`).
    static func toolName(of request: [String: Any]) -> String? {
        (request["params"] as? [String: Any])?["name"] as? String
    }

    /// Tool arguments of a recorded request (`params.arguments`).
    static func arguments(of request: [String: Any]) -> [String: Any] {
        (request["params"] as? [String: Any])?["arguments"] as? [String: Any] ?? [:]
    }

    /// Recorded requests for one tool, in order.
    static func requests(for tool: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return recordedRequests.filter { toolName(of: $0) == tool }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// URLSession hands a URLProtocol the body as a stream, never as `httpBody`.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override func startLoading() {
        QueuedResponseProtocol.lock.lock()
        if let body = QueuedResponseProtocol.body(of: request),
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            QueuedResponseProtocol.recordedRequests.append(json)
        }
        let pair: (Int, Data)?
        if QueuedResponseProtocol.responseQueue.isEmpty {
            pair = nil
        } else {
            pair = QueuedResponseProtocol.responseQueue.removeFirst()
        }
        QueuedResponseProtocol.lock.unlock()

        let (code, body) = pair ?? (500, Data())
        let resp = HTTPURLResponse(
            url: request.url!, statusCode: code, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Makes a URLSession wired to QueuedResponseProtocol so tests never hit a network.
private func makeQueuedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [QueuedResponseProtocol.self]
    config.timeoutIntervalForRequest = 5
    return URLSession(configuration: config)
}

private func makeQueuedClient() -> LiveDaemonClient {
    LiveDaemonClient(baseURL: URL(string: "http://localhost:9999")!, session: makeQueuedSession())
}

// MARK: Fixture frames recorded from the v2 binaries

/// Bytes of a fixture under distribution/plugin/tests/fixtures/ (full JSON-RPC body).
private func fixtureData(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("distribution/plugin/tests/fixtures/\(name)")
    return try Data(contentsOf: url)
}

/// `result.structuredContent.data` of a fixture frame.
private func fixtureDataObject(_ frame: Data) throws -> [String: Any] {
    let json = try JSONSerialization.jsonObject(with: frame) as? [String: Any] ?? [:]
    let result = json["result"] as? [String: Any] ?? [:]
    let structured = result["structuredContent"] as? [String: Any] ?? [:]
    return structured["data"] as? [String: Any] ?? [:]
}

/// `(memory_id, subject)` of every row on a list page.
private func pageRows(_ frame: Data) throws -> [(id: String, subject: String)] {
    let rows = try fixtureDataObject(frame)["memories"] as? [[String: Any]] ?? []
    return rows.compactMap { row in
        guard let id = row["memory_id"] as? String else { return nil }
        return (id, row["subject"] as? String ?? id)
    }
}

/// A `moot_memory_list` success frame for `rows` (v2 envelope shape).
private func makeListFrame(rows: [[String: Any]], hasMore: Bool, nextCursor: String?) throws -> Data {
    var data: [String: Any] = ["memories": rows, "has_more": hasMore, "revision": "r1"]
    if let nextCursor { data["next_cursor"] = nextCursor }
    let frame: [String: Any] = [
        "jsonrpc": "2.0", "id": 1,
        "result": [
            "isError": false,
            "structuredContent": ["surface_version": "v2", "tool": "moot_memory_list", "data": data, "meta": [:]],
            "content": [["type": "text", "text": "Enumerated \(rows.count) memories."]],
        ] as [String: Any],
    ]
    return try JSONSerialization.data(withJSONObject: frame)
}

/// A synthesized `moot_memory_get` success frame answering `rows` in order at
/// `harness-import/bigslug/<subject>.md`. The recorded batch fixture holds 50
/// records that do not align with the 50-id chunks of the page fixtures, so
/// the paging tests synthesize every get body from the page ids.
private func makeGetFrame(rows: [(id: String, subject: String)]) throws -> Data {
    let memories: [[String: Any]] = rows.map { row in
        [
            "memory_id": row.id,
            "placement": ["wing": "Agentic Memory", "room": "harness-import/bigslug/\(row.subject).md"],
            "content": "# \(row.subject)\nbody \(row.subject)\n",
            "event_time": "2026-09-01T00:00:00Z",
            "state": "active",
            "subject": row.subject,
        ]
    }
    let frame: [String: Any] = [
        "jsonrpc": "2.0", "id": 1,
        "result": [
            "isError": false,
            "structuredContent": ["surface_version": "v2", "tool": "moot_memory_get", "data": ["memories": memories], "meta": [:]],
            "content": [["type": "text", "text": "Fetched \(rows.count) memories."]],
        ] as [String: Any],
    ]
    return try JSONSerialization.data(withJSONObject: frame)
}

/// Get frames for `rows` in chunks of 50, the client's batch size.
private func makeGetFrames(rows: [(id: String, subject: String)]) throws -> [(Int, Data)] {
    var frames: [(Int, Data)] = []
    for offset in stride(from: 0, to: rows.count, by: 50) {
        let chunk = Array(rows[offset..<min(offset + 50, rows.count)])
        frames.append((200, try makeGetFrame(rows: chunk)))
    }
    return frames
}

/// The exact v2 refusal frame shape: HTTP 200, no JSON-RPC error, isError true.
private func makeRefusalFrame(tool: String, code: String, message: String, retryable: Bool) -> Data {
    """
    {"jsonrpc":"2.0","id":1,"result":{"isError":true,"content":[{"type":"text","text":"\(message)"}],"structuredContent":{"surface_version":"v2","tool":"\(tool)","error":{"code":"\(code)","message":"\(message)","retryable":\(retryable)},"meta":{}}}}
    """.data(using: .utf8)!
}

private let kCursorStaleFrame = """
{"jsonrpc":"2.0","id":1,"result":{"isError":true,"content":[{"type":"text","text":"The inventory changed; restart moot_memory_list without the cursor."}],"structuredContent":{"surface_version":"v2","tool":"moot_memory_list","error":{"code":"cursor_stale","message":"The inventory changed; restart moot_memory_list without the cursor.","retryable":true},"meta":{}}}}
""".data(using: .utf8)!

private let kMemoryNotFoundFrame = makeRefusalFrame(
    tool: "moot_memory_get", code: "memory_not_found", message: "memory not found", retryable: false)

// v2 JSON-RPC response bodies used by the parser tests below.
// These shapes match the fixtures captured from the v2 binaries at
// distribution/plugin/tests/fixtures/swift_memory_list.json and swift_memory_get.json.
private let kV2ListResponse = """
{"jsonrpc":"2.0","id":1,"result":{"isError":false,"structuredContent":{"surface_version":"v2","tool":"moot_memory_list","data":{"has_more":false,"memories":[{"memory_id":"test-id-1","fetch":{"tool":"moot_memory_get","arguments":{"memory_id":"test-id-1"}},"subject":"MEMORY.md index","provenance":"imported"}],"revision":"abc"}},"content":[{"type":"text","text":"Enumerated 1 memory."}]}}
""".data(using: .utf8)!

private let kV2GetResponse = """
{"jsonrpc":"2.0","id":1,"result":{"isError":false,"structuredContent":{"surface_version":"v2","tool":"moot_memory_get","data":{"memories":[{"memory_id":"test-id-1","placement":{"wing":"Agentic Memory","room":"harness-import/testslug/MEMORY.md"},"content":"# Memory Index for testslug","event_time":"2026-09-09T00:00:00Z","state":"active","subject":"MEMORY.md index"}]}},"content":[{"type":"text","text":"Retrieved memory."}]}}
""".data(using: .utf8)!

private let kV2GetResponseSuperseded = """
{"jsonrpc":"2.0","id":1,"result":{"isError":false,"structuredContent":{"surface_version":"v2","tool":"moot_memory_get","data":{"memories":[{"memory_id":"test-id-sup","placement":{"wing":"Agentic Memory","room":"harness-import/testslug/notes.md"},"content":"# Old notes","event_time":"2026-09-09T00:00:00Z","state":"superseded","subject":"notes"}]}},"content":[{"type":"text","text":"Retrieved memory."}]}}
""".data(using: .utf8)!

@Suite(.serialized)
struct LiveDaemonClientV2ParserTests {

    /// Page fixtures: 200 rows with a cursor, then 7 rows, 207 distinct ids.
    private func pageFixtures() throws -> (page1: Data, page2: Data, rows: [(id: String, subject: String)], cursor: String) {
        let page1 = try fixtureData("swift_memory_list_page1.json")
        let page2 = try fixtureData("swift_memory_list_page2.json")
        let rows = try pageRows(page1) + pageRows(page2)
        let cursor = try fixtureDataObject(page1)["next_cursor"] as? String ?? ""
        return (page1, page2, rows, cursor)
    }

    @Test("listMemories reads v2 envelope: result.structuredContent.data.memories")
    func listMemoriesReadsV2Envelope() async throws {
        // Feed list response + get follow-up through the actual LiveDaemonClient parser.
        // Proves the parser reads result.structuredContent.data.memories (not result.memories).
        QueuedResponseProtocol.enqueue([
            (200, kV2ListResponse),
            (200, kV2GetResponse),
        ])
        let client = makeQueuedClient()
        let records = try await client.listMemories(locationPrefix: "harness-import/testslug/MEMORY.md")
        #expect(records.count == 1, "must return 1 record after get follow-up")
        #expect(records[0].id == "test-id-1")
        #expect(records[0].location == "harness-import/testslug/MEMORY.md", "location from placement.room")
        #expect(records[0].content == "# Memory Index for testslug")
        #expect(!records[0].isSuperseded)
        let lists = QueuedResponseProtocol.requests(for: "moot_memory_list")
        #expect(lists.count == 1)
        let args = QueuedResponseProtocol.arguments(of: lists[0])
        #expect(args["wing"] as? String == "Agentic Memory")
        #expect(args["limit"] as? Int == 200)
        #expect(args["room"] as? String == "harness-import/testslug/MEMORY.md", "exact file: room filter sent")
    }

    @Test("listMemories empty prefix returns empty without calling daemon")
    func listMemoriesEmptyPrefixReturnsEmpty() async throws {
        QueuedResponseProtocol.enqueue([])
        let client = makeQueuedClient()
        let records = try await client.listMemories(locationPrefix: "")
        #expect(records.isEmpty, "empty prefix must return empty list")
        #expect(QueuedResponseProtocol.recordedRequests.isEmpty)
    }

    @Test("listMemories leading slash normalized: same result as without slash")
    func listMemoriesLeadingSlashNormalized() async throws {
        QueuedResponseProtocol.enqueue([
            (200, kV2ListResponse),
            (200, kV2GetResponse),
        ])
        let client = makeQueuedClient()
        // Leading slash must be stripped; prefix "harness-import/testslug/MEMORY.md" matches.
        let records = try await client.listMemories(locationPrefix: "/harness-import/testslug/MEMORY.md")
        #expect(records.count == 1, "leading slash must be stripped; result same as without slash")
    }

    @Test("listMemories state=superseded sets isSuperseded=true")
    func listMemoriesSupersededFlag() async throws {
        let listWithSup = """
        {"jsonrpc":"2.0","id":1,"result":{"isError":false,"structuredContent":{"surface_version":"v2","tool":"moot_memory_list","data":{"has_more":false,"memories":[{"memory_id":"test-id-sup","fetch":{"tool":"moot_memory_get","arguments":{"memory_id":"test-id-sup"}},"subject":"notes","provenance":"imported"}],"revision":"abc"}},"content":[]}}
        """.data(using: .utf8)!
        QueuedResponseProtocol.enqueue([
            (200, listWithSup),
            (200, kV2GetResponseSuperseded),
        ])
        let client = makeQueuedClient()
        let records = try await client.listMemories(locationPrefix: "harness-import/testslug/notes.md")
        #expect(records.count == 1)
        #expect(records[0].isSuperseded, "state=superseded must produce isSuperseded=true")
    }

    // MARK: Paging and batch get

    @Test("listMemories pages with the server cursor and fetches records in chunks of 50")
    func listMemoriesPagesAndBatches() async throws {
        let fx = try pageFixtures()
        #expect(fx.rows.count == 207)
        QueuedResponseProtocol.enqueue([(200, fx.page1), (200, fx.page2)] + (try makeGetFrames(rows: fx.rows)))
        let client = makeQueuedClient()

        let records = try await client.listMemories(locationPrefix: "harness-import/")

        #expect(records.count == 207)
        #expect(records.map(\.id) == fx.rows.map(\.id), "records follow server order")
        #expect(records.allSatisfy { $0.location.hasPrefix("harness-import/bigslug/") })

        let lists = QueuedResponseProtocol.requests(for: "moot_memory_list")
        #expect(lists.count == 2)
        #expect(QueuedResponseProtocol.arguments(of: lists[0])["cursor"] == nil, "first page: no cursor")
        #expect(QueuedResponseProtocol.arguments(of: lists[1])["cursor"] as? String == fx.cursor,
                "second page sends page1's next_cursor")
        #expect(QueuedResponseProtocol.arguments(of: lists[1])["room"] == nil, "directory prefix: no room filter")

        let gets = QueuedResponseProtocol.requests(for: "moot_memory_get")
        let sizes = gets.map { (QueuedResponseProtocol.arguments(of: $0)["memory_ids"] as? [String])?.count ?? -1 }
        #expect(sizes == [50, 50, 50, 50, 7])
    }

    @Test("batch get: no request carries more than 50 ids and there are ceil(n/50) requests")
    func batchGetChunking() async throws {
        let fx = try pageFixtures()
        QueuedResponseProtocol.enqueue([(200, fx.page1), (200, fx.page2)] + (try makeGetFrames(rows: fx.rows)))
        let client = makeQueuedClient()

        _ = try await client.listMemories(locationPrefix: "harness-import/")

        let gets = QueuedResponseProtocol.requests(for: "moot_memory_get")
        let n = fx.rows.count
        #expect(gets.count == (n + 49) / 50)
        var covered: [String] = []
        for get in gets {
            let ids = QueuedResponseProtocol.arguments(of: get)["memory_ids"] as? [String] ?? []
            #expect(ids.count <= 50)
            #expect(ids.count > 0)
            #expect(Set(ids).count == ids.count, "no duplicate ids in a batch")
            #expect(QueuedResponseProtocol.arguments(of: get)["memory_id"] == nil, "memory_ids and memory_id are exclusive")
            covered += ids
        }
        #expect(covered == fx.rows.map(\.id), "every listed id is fetched exactly once, in order")
    }

    @Test("batch get consumes the recorded swift_memory_get_batch fixture (50 records)")
    func batchGetConsumesBatchFixture() async throws {
        let batch = try fixtureData("swift_memory_get_batch.json")
        let batchRecords = try fixtureDataObject(batch)["memories"] as? [[String: Any]] ?? []
        let ids = batchRecords.compactMap { $0["memory_id"] as? String }
        #expect(ids.count == 50)
        let rows: [[String: Any]] = ids.map { id in
            ["memory_id": id, "fetch": ["tool": "moot_memory_get", "arguments": ["memory_id": id]]]
        }
        QueuedResponseProtocol.enqueue([
            (200, try makeListFrame(rows: rows, hasMore: false, nextCursor: nil)),
            (200, batch),
        ])
        let client = makeQueuedClient()

        let records = try await client.listMemories(locationPrefix: "harness-import/bigslug/")

        #expect(records.count == 50)
        #expect(Set(records.map(\.id)) == Set(ids))
        #expect(records.allSatisfy { $0.location.hasPrefix("harness-import/bigslug/") }, "placement.room is the location")
        #expect(records.allSatisfy { !$0.isSuperseded && !$0.content.isEmpty })
        let gets = QueuedResponseProtocol.requests(for: "moot_memory_get")
        #expect(gets.count == 1)
        #expect(QueuedResponseProtocol.arguments(of: gets[0])["memory_ids"] as? [String] == ids)
    }

    @Test("listMemories: swift_memory_list fixture with a partial get answer refuses, naming the missing id")
    func listMemoriesFixturePartialGetRefuses() async throws {
        // The recorded list page names two ids; the recorded get answers one of them.
        // A batch that answers fewer records than asked is a refusal, never a short list.
        let list = try fixtureData("swift_memory_list.json")
        let get = try fixtureData("swift_memory_get.json")
        let listed = try pageRows(list).map(\.id)
        let answered = (try fixtureDataObject(get)["memories"] as? [[String: Any]] ?? [])
            .compactMap { $0["memory_id"] as? String }
        #expect(listed.count == 2 && answered.count == 1)
        QueuedResponseProtocol.enqueue([(200, list), (200, get)])
        let client = makeQueuedClient()

        do {
            _ = try await client.listMemories(locationPrefix: "harness-import/")
            Issue.record("expected DaemonError.refused(memory_not_found)")
        } catch DaemonError.refused(let code, let message) {
            #expect(code == "memory_not_found")
            let missing = listed.filter { !answered.contains($0) }
            #expect(missing.count == 1)
            #expect(message.contains(missing[0]), "the refusal names the missing id")
        }
        let gets = QueuedResponseProtocol.requests(for: "moot_memory_get")
        #expect(QueuedResponseProtocol.arguments(of: gets[0])["memory_ids"] as? [String] == listed)
    }

    @Test("getMemory consumes the recorded swift_memory_get fixture")
    func getMemoryConsumesFixture() async throws {
        QueuedResponseProtocol.enqueue([(200, try fixtureData("swift_memory_get.json"))])
        let client = makeQueuedClient()

        let record = try await client.getMemory(id: "84de1bc0-ee45-4054-9eb8-f308d938172b")

        #expect(record?.id == "84de1bc0-ee45-4054-9eb8-f308d938172b")
        #expect(record?.location == "harness-import/testslug/notes.md", "placement.room is the location")
        #expect(record?.content == "# Notes for testslug")
        #expect(record?.isSuperseded == false)
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        #expect(record?.eventTime == fmt.date(from: "2026-09-09T00:01:00Z"))
        let gets = QueuedResponseProtocol.requests(for: "moot_memory_get")
        #expect(gets.count == 1)
        #expect(QueuedResponseProtocol.arguments(of: gets[0])["memory_id"] as? String == "84de1bc0-ee45-4054-9eb8-f308d938172b")
        #expect(QueuedResponseProtocol.arguments(of: gets[0])["memory_ids"] == nil)
    }

    // MARK: Refusal frames

    @Test("getMemory: memory_not_found refusal answers nil; any other refusal throws")
    func getMemoryRefusals() async throws {
        QueuedResponseProtocol.enqueue([(200, kMemoryNotFoundFrame)])
        let client = makeQueuedClient()
        let missing = try await client.getMemory(id: "no-such-id")
        #expect(missing == nil)

        QueuedResponseProtocol.enqueue([(200, makeRefusalFrame(
            tool: "moot_memory_get", code: "estate_unavailable", message: "estate closed", retryable: true))])
        do {
            _ = try await client.getMemory(id: "any-id")
            Issue.record("expected DaemonError.refused(estate_unavailable)")
        } catch DaemonError.refused(let code, let message) {
            #expect(code == "estate_unavailable")
            #expect(message == "estate closed")
        }
    }

    @Test("getMemory: a top-level JSON-RPC error is a refusal with code rpc_error, not an unknown id")
    func getMemoryRpcErrorThrows() async throws {
        let body = """
        {"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"memory not found"}}
        """.data(using: .utf8)!
        QueuedResponseProtocol.enqueue([(200, body)])
        let client = makeQueuedClient()
        do {
            _ = try await client.getMemory(id: "x")
            Issue.record("expected DaemonError.refused(rpc_error)")
        } catch DaemonError.refused(let code, let message) {
            #expect(code == "rpc_error")
            #expect(message == "memory not found")
        }
    }

    @Test("listMemories restarts without a cursor on cursor_stale, at most three times")
    func listMemoriesRestartsOnStaleCursor() async throws {
        let fx = try pageFixtures()
        QueuedResponseProtocol.enqueue(
            [(200, fx.page1), (200, kCursorStaleFrame), (200, fx.page1), (200, fx.page2)]
            + (try makeGetFrames(rows: fx.rows)))
        let client = makeQueuedClient()

        let records = try await client.listMemories(locationPrefix: "harness-import/")

        #expect(records.count == 207)
        let lists = QueuedResponseProtocol.requests(for: "moot_memory_list").map { QueuedResponseProtocol.arguments(of: $0) }
        #expect(lists.count == 4)
        #expect(lists[0]["cursor"] == nil)
        #expect(lists[1]["cursor"] as? String == fx.cursor)
        #expect(lists[2]["cursor"] == nil, "restart after cursor_stale carries no cursor")
        #expect(lists[3]["cursor"] as? String == fx.cursor)

        // Four stale answers exhaust the three restarts: the refusal propagates.
        QueuedResponseProtocol.enqueue([
            (200, fx.page1), (200, kCursorStaleFrame),
            (200, fx.page1), (200, kCursorStaleFrame),
            (200, fx.page1), (200, kCursorStaleFrame),
            (200, fx.page1), (200, kCursorStaleFrame),
        ])
        do {
            _ = try await client.listMemories(locationPrefix: "harness-import/")
            Issue.record("expected DaemonError.refused(cursor_stale)")
        } catch DaemonError.refused(let code, _) {
            #expect(code == "cursor_stale")
        }
        #expect(QueuedResponseProtocol.requests(for: "moot_memory_list").count == 8)
    }

    @Test("listMemories: a refusal other than a cursor code propagates; a page without has_more is a parse error")
    func listMemoriesRefusalAndMalformedPage() async throws {
        let client = makeQueuedClient()
        QueuedResponseProtocol.enqueue([(200, makeRefusalFrame(
            tool: "moot_memory_list", code: "estate_unavailable", message: "closed", retryable: true))])
        do {
            _ = try await client.listMemories(locationPrefix: "harness-import/")
            Issue.record("expected DaemonError.refused(estate_unavailable)")
        } catch DaemonError.refused(let code, _) {
            #expect(code == "estate_unavailable")
        }

        let noHasMore = """
        {"jsonrpc":"2.0","id":1,"result":{"isError":false,"structuredContent":{"surface_version":"v2","tool":"moot_memory_list","data":{"memories":[],"revision":"abc"}},"content":[]}}
        """.data(using: .utf8)!
        QueuedResponseProtocol.enqueue([(200, noHasMore)])
        do {
            _ = try await client.listMemories(locationPrefix: "harness-import/")
            Issue.record("expected DaemonError.parseError")
        } catch DaemonError.parseError {
            // A page that does not say whether more follow is not an empty wing.
        }
    }

    @Test("listMemories: has_more true without next_cursor is an error, not a truncated wing")
    func listMemoriesHasMoreWithoutCursorThrows() async throws {
        let client = makeQueuedClient()
        let page1 = try fixtureData("swift_memory_list_page1.json")
        let rows = Array((try fixtureDataObject(page1)["memories"] as? [[String: Any]] ?? []).prefix(3))
        QueuedResponseProtocol.enqueue([(200, try makeListFrame(rows: rows, hasMore: true, nextCursor: nil))])
        do {
            _ = try await client.listMemories(locationPrefix: "harness-import/")
            Issue.record("expected DaemonError.parseError; the rest of the wing is unreachable")
        } catch DaemonError.parseError {
            // The Rust twin answers the same frame with Transport("malformed page").
        }
    }

    @Test("listMemories: a repeated next_cursor is an error, not a truncated wing")
    func listMemoriesRepeatedCursorThrows() async throws {
        let client = makeQueuedClient()
        let page1 = try fixtureData("swift_memory_list_page1.json")
        let rows = Array((try fixtureDataObject(page1)["memories"] as? [[String: Any]] ?? []).prefix(3))
        QueuedResponseProtocol.enqueue([
            (200, try makeListFrame(rows: Array(rows.prefix(2)), hasMore: true, nextCursor: "c1")),
            (200, try makeListFrame(rows: Array(rows.suffix(1)), hasMore: true, nextCursor: "c1")),
        ])
        do {
            _ = try await client.listMemories(locationPrefix: "harness-import/")
            Issue.record("expected DaemonError.parseError on a cursor already used")
        } catch DaemonError.parseError {
            // Two pages were read; neither is returned as the whole wing.
        }
        #expect(QueuedResponseProtocol.requests(for: "moot_memory_list").count == 2)
    }

    @Test("listMemories: an alternating cursor (c1, c2, c1) throws rather than spinning")
    func listMemoriesAlternatingCursorThrowsRatherThanSpinning() async throws {
        // The third page repeats the FIRST cursor, not the one immediately
        // before it. A single-value "last cursor" comparison walks straight
        // past this and loops forever; only tracking every cursor seen (a
        // Set) catches it. Distinct rows on each page so the pages cannot be
        // mistaken for one another.
        let client = makeQueuedClient()
        let page1 = try fixtureData("swift_memory_list_page1.json")
        let rows = Array((try fixtureDataObject(page1)["memories"] as? [[String: Any]] ?? []).prefix(3))
        QueuedResponseProtocol.enqueue([
            (200, try makeListFrame(rows: [rows[0]], hasMore: true, nextCursor: "c1")),
            (200, try makeListFrame(rows: [rows[1]], hasMore: true, nextCursor: "c2")),
            (200, try makeListFrame(rows: [rows[2]], hasMore: true, nextCursor: "c1")),
        ])
        do {
            _ = try await client.listMemories(locationPrefix: "harness-import/")
            Issue.record("expected DaemonError.parseError on a cursor already used")
        } catch DaemonError.parseError {
            // Three pages were read; the client must not spin past the repeat.
        }
        let lists = QueuedResponseProtocol.requests(for: "moot_memory_list")
        #expect(lists.count == 3, "the loop must stop at the third page, not spin forever")
        #expect(QueuedResponseProtocol.arguments(of: lists[1])["cursor"] as? String == "c1", "second request carries page1's cursor")
        #expect(QueuedResponseProtocol.arguments(of: lists[2])["cursor"] as? String == "c2", "third request carries page2's cursor")
    }

    @Test("restore through LiveDaemonClient: has_more without a cursor is one failed result and zero files")
    func restoreThroughClientUnreachableTailWritesNothing() async throws {
        let dir = try makeSandboxDir(tag: "restore-live-tail")
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        let page1 = try fixtureData("swift_memory_list_page1.json")
        let rows = Array((try fixtureDataObject(page1)["memories"] as? [[String: Any]] ?? []).prefix(3))
        QueuedResponseProtocol.enqueue([(200, try makeListFrame(rows: rows, hasMore: true, nextCursor: nil))])
        let client = makeQueuedClient()

        let results = await HarnessMemoryRestore.restore(homeDirectory: home, daemon: client)

        #expect(results.count == 1)
        guard case .failed(let reason) = results[0].outcome else {
            Issue.record("expected one .failed result, got \(results.map(\.outcome))"); return
        }
        #expect(reason.hasPrefix("Estate enumeration failed:"))
        let projectsURL = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
        #expect(!FileManager.default.fileExists(atPath: projectsURL.path), "zero files written")
    }

    // MARK: Restore through the live client (files on disk are the assertion)

    @Test("restore through LiveDaemonClient: cursor_stale restart, every record lands on disk")
    func restoreThroughClientRestartsAndWritesAll() async throws {
        let dir = try makeSandboxDir(tag: "restore-live-client")
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        let fx = try pageFixtures()
        QueuedResponseProtocol.enqueue(
            [(200, fx.page1), (200, kCursorStaleFrame), (200, fx.page1), (200, fx.page2)]
            + (try makeGetFrames(rows: fx.rows)))
        let client = makeQueuedClient()

        let results = await HarnessMemoryRestore.restore(homeDirectory: home, daemon: client)

        let restored = results.filter { if case .restored = $0.outcome { return true }; return false }
        #expect(restored.count == fx.rows.count)
        let memoryDir = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
            .appendingPathComponent("bigslug/memory")
        let names = try FileManager.default.contentsOfDirectory(atPath: memoryDir.path)
        // Every record's file, plus the MEMORY.md index restore regenerates for the slug.
        var idsOnDisk = Set<String>()
        for name in names where name != "MEMORY.md" {
            let raw = try String(contentsOf: memoryDir.appendingPathComponent(name), encoding: .utf8)
            if let id = HarnessMemoryFrontMatter.strip(raw).memoryId { idsOnDisk.insert(id) }
        }
        #expect(idsOnDisk.count == fx.rows.count)
        #expect(idsOnDisk == Set(fx.rows.map(\.id)))
        #expect(names.contains("MEMORY.md"))
        #expect(names.count == fx.rows.count + 1)

        let lists = QueuedResponseProtocol.requests(for: "moot_memory_list").map { QueuedResponseProtocol.arguments(of: $0) }
        #expect(lists.count == 4)
        #expect(lists[2]["cursor"] == nil, "the third list request restarts without a cursor")
        #expect(QueuedResponseProtocol.requests(for: "moot_update_memory").isEmpty, "restore mutates nothing")
    }

    @Test("restore through LiveDaemonClient: a get refusal is one failed result and zero files")
    func restoreThroughClientRefusalWritesNothing() async throws {
        let dir = try makeSandboxDir(tag: "restore-live-refusal")
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        // page1 fixture cut to three rows with has_more false.
        let page1 = try fixtureData("swift_memory_list_page1.json")
        let rows = Array((try fixtureDataObject(page1)["memories"] as? [[String: Any]] ?? []).prefix(3))
        #expect(rows.count == 3)
        QueuedResponseProtocol.enqueue([
            (200, try makeListFrame(rows: rows, hasMore: false, nextCursor: nil)),
            (200, kMemoryNotFoundFrame),
        ])
        let client = makeQueuedClient()

        let results = await HarnessMemoryRestore.restore(homeDirectory: home, daemon: client)

        #expect(results.count == 1)
        guard case .failed(let reason) = results[0].outcome else {
            Issue.record("expected one .failed result, got \(results.map(\.outcome))"); return
        }
        #expect(reason.hasPrefix("Estate enumeration failed:"))
        #expect(reason.contains("memory_not_found"))
        let projectsURL = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
        #expect(!FileManager.default.fileExists(atPath: projectsURL.path), "zero files written")
    }
}

// MARK: - Live round trip (env-gated)

/// Runs only with `MOOT_HARNESS_LIVE_PORT=<port>` set: restore the daemon's
/// harness memories into a temp home, ingest every restored file back, and
/// prove the estate's id set is unchanged. Nothing under the real home is touched.
@Suite("HarnessMemory live round trip")
struct HarnessMemoryLiveRoundTripTests {

    @Test("restore then ingest against the live daemon leaves every id in place",
          .enabled(if: ProcessInfo.processInfo.environment["MOOT_HARNESS_LIVE_PORT"] != nil))
    func liveRoundTrip() async throws {
        let port = try #require(Int(ProcessInfo.processInfo.environment["MOOT_HARNESS_LIVE_PORT"] ?? ""))
        let client = LiveDaemonClient(port: port)
        let dir = try makeSandboxDir(tag: "live-round-trip")
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")

        let before = try await client.listMemories(locationPrefix: "harness")
        let beforeIds = Set(before.map(\.id))
        var byId: [String: HarnessMemoryRecord] = [:]
        for record in before { byId[record.id] = record }

        let results = await HarnessMemoryRestore.restore(homeDirectory: home, daemon: client)
        let restored = results.filter { if case .restored = $0.outcome { return true }; return false }
        if before.count > 200 {
            #expect(restored.count > 200, "paging: more than one server page restored")
        }

        for result in restored {
            let url = URL(fileURLWithPath: result.filePath)
            let raw = try String(contentsOf: url, encoding: .utf8)
            let stripped = HarnessMemoryFrontMatter.strip(raw)
            let id = try #require(stripped.memoryId, "restored file carries its id: \(result.filePath)")
            let record = try #require(byId[id], "restored id was listed before restore")
            #expect(stripped.body == record.content, "body matches the row: \(result.location)")
            #expect(record.location == result.location)
        }

        // Re-enable ingests every file in every restored directory, the generated
        // MEMORY.md indexes included: those are discarded, every other file matches.
        var matched = 0
        var discardedIndexes = 0
        let projectsURL = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
        let slugs = try FileManager.default.contentsOfDirectory(atPath: projectsURL.path).sorted()
        for slug in slugs {
            let memoryDir = projectsURL.appendingPathComponent(slug).appendingPathComponent("memory")
            for name in try FileManager.default.contentsOfDirectory(atPath: memoryDir.path).sorted() {
                let url = memoryDir.appendingPathComponent(name)
                let ingest = await HarnessMemoryIngest.ingestFile(url, projectSlug: slug, daemon: client)
                switch ingest.outcome {
                case .matched: matched += 1
                case .discardedIndex: discardedIndexes += 1
                case .filed: Issue.record("re-enable filed a fresh row for \(slug)/\(name)")
                default: Issue.record("expected .matched or .discardedIndex for \(slug)/\(name), got \(ingest.outcome)")
                }
            }
        }

        let after = try await client.listMemories(locationPrefix: "harness")
        let afterIds = Set(after.map(\.id))
        #expect(beforeIds == afterIds, "the estate's id set is unchanged")
        let locations = after.map(\.location)
        #expect(Set(locations).count == locations.count, "no duplicate locations after re-enable")
        #expect(matched == restored.count)
        print("LIVE ROUND TRIP \(port): before=\(before.count) after=\(after.count) restored=\(restored.count) matched=\(matched) discarded_indexes=\(discardedIndexes) ids=\(afterIds.sorted().joined(separator: ","))")
    }
}
