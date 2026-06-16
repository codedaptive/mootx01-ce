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

    @Test("merge tolerates a leading UTF-8 BOM and preserves existing settings")
    func mergeToleratesUTF8BOM() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        // A settings.json written by Windows PowerShell 5.1's
        // `Set-Content -Encoding UTF8` carries a UTF-8 BOM. JSONSerialization
        // rejects it; without BOM stripping the merge would parse to an empty
        // object and silently overwrite the user's existing settings.
        let settingsURL = dir.appendingPathComponent("settings.json")
        let body: [String: Any] = ["theme": "dark", "permissions": ["allow": ["mcp__other__tool"]]]
        var bytes = Data([0xEF, 0xBB, 0xBF]) // UTF-8 BOM
        bytes.append(try JSONSerialization.data(withJSONObject: body, options: []))
        try bytes.write(to: settingsURL)

        try PermissionsWriter.merge(into: settingsURL)

        let updated = try Data(contentsOf: settingsURL)
        #expect(Array(updated.prefix(3)) != [0xEF, 0xBB, 0xBF], "BOM should be gone after rewrite")
        let obj = try JSONSerialization.jsonObject(with: updated) as? [String: Any]
        #expect(obj?["theme"] as? String == "dark", "existing top-level keys must survive")
        let allow = (obj?["permissions"] as? [String: Any])?["allow"] as? [String] ?? []
        #expect(allow.contains("mcp__other__tool"), "existing allow entry must survive")
        #expect(allow.count == 54) // 53 new + 1 existing
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
