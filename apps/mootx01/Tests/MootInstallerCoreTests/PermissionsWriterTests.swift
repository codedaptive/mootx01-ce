// PermissionsWriterTests.swift
//
// Tests for PermissionsWriter: additive merge, idempotency, removal,
// and the tool-name count. All I/O uses sandbox directories.

import Testing
import Foundation
@testable import MootInstallerCore

@Suite("PermissionsWriter")
struct PermissionsWriterTests {

    // MARK: - Tool name list

    @Test("ariaToolNames has exactly 53 entries")
    func toolNameCount() {
        #expect(PermissionsWriter.ariaToolNames.count == 53)
    }

    @Test("permissionEntries all carry the mcp__mootx01__ prefix")
    func permissionEntryPrefix() {
        for entry in PermissionsWriter.permissionEntries {
            #expect(entry.hasPrefix("mcp__mootx01__"))
        }
    }

    @Test("permissionEntries has exactly 53 entries matching ariaToolNames")
    func permissionEntryCount() {
        #expect(PermissionsWriter.permissionEntries.count == 53)
        for (tool, entry) in zip(PermissionsWriter.ariaToolNames, PermissionsWriter.permissionEntries) {
            #expect(entry == "mcp__mootx01__\(tool)")
        }
    }

    // MARK: - merge

    @Test("merge creates settings.json when absent")
    func mergeCreatesFile() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let settingsURL = dir.appendingPathComponent("settings.json")
        try PermissionsWriter.merge(into: settingsURL)

        #expect(FileManager.default.fileExists(atPath: settingsURL.path))

        let data = try Data(contentsOf: settingsURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let perms = obj?["permissions"] as? [String: Any]
        let allow = perms?["allow"] as? [String] ?? []
        #expect(allow.count == 53)
    }

    @Test("merge is idempotent: second call does not duplicate entries")
    func mergeIdempotent() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let settingsURL = dir.appendingPathComponent("settings.json")
        try PermissionsWriter.merge(into: settingsURL)
        try PermissionsWriter.merge(into: settingsURL)

        let data = try Data(contentsOf: settingsURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let perms = obj?["permissions"] as? [String: Any]
        let allow = perms?["allow"] as? [String] ?? []
        #expect(allow.count == 53)
    }

    @Test("merge preserves existing permissions.allow entries")
    func mergePreservesExistingEntries() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        // Pre-existing settings with a custom entry.
        let existing: [String: Any] = [
            "permissions": ["allow": ["mcp__other__tool"]]
        ]
        let settingsURL = dir.appendingPathComponent("settings.json")
        let data = try JSONSerialization.data(withJSONObject: existing, options: [])
        try data.write(to: settingsURL)

        try PermissionsWriter.merge(into: settingsURL)

        let updated = try Data(contentsOf: settingsURL)
        let obj = try JSONSerialization.jsonObject(with: updated) as? [String: Any]
        let perms = obj?["permissions"] as? [String: Any]
        let allow = perms?["allow"] as? [String] ?? []
        #expect(allow.contains("mcp__other__tool"), "existing entry must be preserved")
        #expect(allow.count == 54) // 53 new + 1 existing
    }

    @Test("merge preserves other top-level keys in settings.json")
    func mergePreservesOtherKeys() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let existing: [String: Any] = ["theme": "dark", "fontSize": 14]
        let settingsURL = dir.appendingPathComponent("settings.json")
        let data = try JSONSerialization.data(withJSONObject: existing, options: [])
        try data.write(to: settingsURL)

        try PermissionsWriter.merge(into: settingsURL)

        let updated = try Data(contentsOf: settingsURL)
        let obj = try JSONSerialization.jsonObject(with: updated) as? [String: Any]
        #expect(obj?["theme"] as? String == "dark")
        #expect(obj?["fontSize"] as? Int == 14)
    }

    // MARK: - remove

    @Test("remove eliminates ARIA permission entries from allow list")
    func removeEliminatesEntries() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let settingsURL = dir.appendingPathComponent("settings.json")
        try PermissionsWriter.merge(into: settingsURL)
        try PermissionsWriter.remove(from: settingsURL)

        let data = try Data(contentsOf: settingsURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let perms = obj?["permissions"] as? [String: Any]
        let allow = perms?["allow"] as? [String] ?? []
        #expect(allow.isEmpty)
    }

    @Test("remove is a no-op when settings.json does not exist")
    func removeNoOpWhenAbsent() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let settingsURL = dir.appendingPathComponent("nonexistent.json")
        // Should not throw.
        try PermissionsWriter.remove(from: settingsURL)
    }

    @Test("remove preserves non-ARIA entries in allow list")
    func removePreservesOtherAllowEntries() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let existing: [String: Any] = [
            "permissions": ["allow": ["mcp__mootx01__moot_capture_drawer", "mcp__other__tool"]]
        ]
        let settingsURL = dir.appendingPathComponent("settings.json")
        let data = try JSONSerialization.data(withJSONObject: existing, options: [])
        try data.write(to: settingsURL)

        try PermissionsWriter.remove(from: settingsURL)

        let updated = try Data(contentsOf: settingsURL)
        let obj = try JSONSerialization.jsonObject(with: updated) as? [String: Any]
        let perms = obj?["permissions"] as? [String: Any]
        let allow = perms?["allow"] as? [String] ?? []
        #expect(allow.contains("mcp__other__tool"), "non-ARIA entry must be preserved")
        #expect(!allow.contains("mcp__mootx01__moot_capture_drawer"), "ARIA entry must be removed")
    }

    // MARK: - Helpers

    private func makeSandboxDir() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("permwriter-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func cleanupSandbox(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
