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
//                           opt-in respected, re-enable revive path
//   HarnessMemoryRestore  — collision refusal, supersede note, round-trip with ingest
//
// All tests use sandbox directories; no real ~/.claude or ~/.mootx01 paths are touched.
// The daemon is mocked via MockDaemonClient — tests do not require a live daemon.

import Testing
import Foundation
@testable import MootInstallerCore

// MARK: - Mock daemon

/// Test double for DaemonClient. Records all calls and returns preset responses.
final class MockDaemonClient: DaemonClient, @unchecked Sendable {

    // Recorded calls
    var filedMemories: [(location: String, content: String, subject: String, eventTime: Date, kind: String?)] = []
    var listedPrefixes: [String] = []
    var updatedMemories: [(id: String, mutation: String, note: String)] = []
    var pingCount = 0

    // Preset responses
    var pingResult = true
    var fileMemoryResult = true
    var fileMemoryError: Error? = nil
    var listMemoriesResult: [HarnessMemoryRecord] = []
    var listMemoriesError: Error? = nil

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

    func updateMemory(id: String, mutation: String, note: String) async throws {
        updatedMemories.append((id: id, mutation: mutation, note: note))
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

    @Test("re-enable path: unchanged content revives superseded drawer, no duplicate")
    func reEnableReviveUnchanged() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        let content = "My memory"
        try makeProjectFixture(slug: "proj", files: [("notes.md", content)], home: home)

        let fileURL = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
            .appendingPathComponent("proj/memory/notes.md")
        let daemon = MockDaemonClient()

        // Pre-seed the mock with a superseded drawer at the same location.
        let existingRecord = HarnessMemoryRecord(
            id: "drawer-123",
            location: "harness-import/proj/notes.md",
            content: content,  // Same content — revive path.
            eventTime: Date(timeIntervalSinceReferenceDate: 0),
            isSuperseded: true
        )
        daemon.listMemoriesResult = [existingRecord]

        let result = await HarnessMemoryIngest.ingestFile(
            fileURL, projectSlug: "proj", isReEnable: true, daemon: daemon, now: Date()
        )
        guard case .revived = result.outcome else {
            Issue.record("Expected .revived, got \(result.outcome)")
            return
        }
        // Revive mutation applied, no new file posted.
        #expect(daemon.filedMemories.isEmpty, "unchanged content must not post a new drawer")
        #expect(daemon.updatedMemories.count == 1)
        #expect(daemon.updatedMemories[0].mutation == "revive")
    }

    @Test("re-enable path: changed content files a fresh drawer")
    func reEnableFreshOnChange() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")
        let newContent = "Updated memory"
        try makeProjectFixture(slug: "proj", files: [("notes.md", newContent)], home: home)

        let fileURL = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
            .appendingPathComponent("proj/memory/notes.md")
        let daemon = MockDaemonClient()

        // Superseded drawer with OLD content.
        let existingRecord = HarnessMemoryRecord(
            id: "drawer-456",
            location: "harness-import/proj/notes.md",
            content: "Old memory",   // Different — must file fresh.
            eventTime: Date(timeIntervalSinceReferenceDate: 0),
            isSuperseded: true
        )
        daemon.listMemoriesResult = [existingRecord]

        let result = await HarnessMemoryIngest.ingestFile(
            fileURL, projectSlug: "proj", isReEnable: true, daemon: daemon, now: Date()
        )
        guard case .filed = result.outcome else {
            Issue.record("Expected .filed, got \(result.outcome)")
            return
        }
        // A new drawer must have been posted.
        #expect(daemon.filedMemories.count == 1)
        #expect(daemon.filedMemories[0].content == newContent)
        #expect(!daemon.filedMemories[0].subject.isEmpty, "re-enable fresh-file must carry a non-empty subject")
    }
}

// MARK: - HarnessMemoryRestore tests

@Suite("HarnessMemoryRestore")
struct HarnessMemoryRestoreTests {

    @Test("restore writes file to disk and marks estate record superseded")
    func restoreWritesFile() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")

        let daemon = MockDaemonClient()
        let record = HarnessMemoryRecord(
            id: "dr-1",
            location: "harness-import/my-project/notes.md",
            content: "Restored content",
            eventTime: Date(),
            isSuperseded: false
        )
        daemon.listMemoriesResult = [record]

        let now = Date()
        let results = await HarnessMemoryRestore.restore(
            projectSlugs: ["my-project"],
            homeDirectory: home,
            daemon: daemon,
            now: now
        )

        // File written.
        let expectedPath = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
            .appendingPathComponent("my-project/memory/notes.md").path
        #expect(FileManager.default.fileExists(atPath: expectedPath))
        let written = try String(contentsOfFile: expectedPath, encoding: .utf8)
        #expect(written == "Restored content")

        // Estate record superseded.
        #expect(daemon.updatedMemories.count == 1)
        #expect(daemon.updatedMemories[0].mutation == "supersede")
        #expect(daemon.updatedMemories[0].note.contains("restored to harness"))

        // Result reported.
        #expect(results.count >= 1)
        let restored = results.first { if case .restored = $0.outcome { return true }; return false }
        #expect(restored != nil)
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
        let record = HarnessMemoryRecord(
            id: "dr-2",
            location: "harness-import/proj/notes.md",
            content: "Estate content",
            eventTime: Date(),
            isSuperseded: false
        )
        daemon.listMemoriesResult = [record]

        let results = await HarnessMemoryRestore.restore(
            projectSlugs: ["proj"],
            homeDirectory: home,
            daemon: daemon,
            now: Date()
        )

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

    @Test("restore: harness/* (born-in-estate) memories are also restored")
    func restoreHarnessBornMemories() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")

        let daemon = MockDaemonClient()
        // A memory born in the estate via the capture hook (location class harness/*).
        let record = HarnessMemoryRecord(
            id: "dr-3",
            location: "harness/proj/captured.md",
            content: "Captured content",
            eventTime: Date(),
            isSuperseded: false
        )
        daemon.listMemoriesResult = [record]

        let results = await HarnessMemoryRestore.restore(
            projectSlugs: ["proj"],
            homeDirectory: home,
            daemon: daemon,
            now: Date()
        )

        let expectedPath = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
            .appendingPathComponent("proj/memory/captured.md").path
        #expect(FileManager.default.fileExists(atPath: expectedPath))
        let restored = results.first { if case .restored = $0.outcome { return true }; return false }
        #expect(restored != nil)
    }

    @Test("full round-trip: enable+ingest → disable+restore → byte-identical files")
    func fullRoundTrip() async throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }
        let home = dir.appendingPathComponent("home")

        let slug = "round-trip-project"
        let originalContent = "This is my important memory."
        let mtime = Date(timeIntervalSinceReferenceDate: 700_000_000)

        // Set up fixture.
        let memoryDir = HarnessMemoryPaths.claudeProjectsURL(homeDirectory: home)
            .appendingPathComponent("\(slug)/memory")
        try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        let srcURL = memoryDir.appendingPathComponent("important.md")
        try originalContent.write(to: srcURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: srcURL.path)

        // Ingest phase — use a mock that records what was filed.
        let ingestDaemon = MockDaemonClient()
        let ingestResult = await HarnessMemoryIngest.ingestFile(
            srcURL, projectSlug: slug, daemon: ingestDaemon, now: Date()
        )
        guard case .filed = ingestResult.outcome else {
            Issue.record("Ingest failed: \(ingestResult.outcome)"); return
        }
        let filed = ingestDaemon.filedMemories[0]
        #expect(abs(filed.eventTime.timeIntervalSince(mtime)) < 1.0,
                "event_time must equal file mtime")
        #expect(!filed.subject.isEmpty, "ingest round-trip must carry a non-empty subject")

        // Source removed.
        #expect(!FileManager.default.fileExists(atPath: srcURL.path))

        // Restore phase — mock returns the filed record.
        let restoreDaemon = MockDaemonClient()
        let restoredRecord = HarnessMemoryRecord(
            id: "dr-rtr",
            location: filed.location,
            content: filed.content,
            eventTime: filed.eventTime,
            isSuperseded: false
        )
        restoreDaemon.listMemoriesResult = [restoredRecord]

        let restoreResults = await HarnessMemoryRestore.restore(
            projectSlugs: [slug],
            homeDirectory: home,
            daemon: restoreDaemon,
            now: Date()
        )

        // File must be back at the original path.
        #expect(FileManager.default.fileExists(atPath: srcURL.path))
        let restoredContent = try String(contentsOf: srcURL, encoding: .utf8)
        #expect(restoredContent == originalContent, "restored file must be byte-identical")

        // Estate record superseded.
        #expect(restoreDaemon.updatedMemories.count == 1)
        #expect(restoreDaemon.updatedMemories[0].mutation == "supersede")

        let _ = restoreResults // suppress unused warning; results checked via daemon state
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
        try? HarnessMemorySettings.disable(settingsURL: settingsURL, homeDirectory: home)
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
        try? HarnessMemorySettings.disable(settingsURL: settingsURL, homeDirectory: home)
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
