// PermissionsWriterTests.swift
//
// Tests for PermissionsWriter: tier classification, tiered merge, allow-all
// merge, idempotency, user-placement precedence, and prefix-based removal.
// Tool names are injected (the real caller derives them from the linked
// AriaMCP ToolProjection at runtime), so tests use a fixed fixture list.
// All I/O uses sandbox directories.

import Testing
import Foundation
@testable import MootInstallerCore

@Suite("PermissionsWriter")
struct PermissionsWriterTests {

    /// Fixture surface exercising all three tiers.
    private let toolNames = [
        "moot_estate_ping",      // allow (diagnostic)
        "moot_estate_status",    // allow (diagnostic)
        "moot_list_lenses",      // allow (pure listing)
        "moot_memory_search",    // ask (read)
        "moot_file_memory",      // ask (write)
        "moot_erase_memory",     // deny (destructive)
    ]

    // MARK: - Classification

    @Test("classify: diagnostics allow, reads/writes ask, destructive deny")
    func classifyTiers() {
        #expect(PermissionsWriter.classify("moot_estate_ping") == .allow)
        #expect(PermissionsWriter.classify("moot_drain_status") == .allow)
        #expect(PermissionsWriter.classify("moot_list_recipes") == .allow)
        #expect(PermissionsWriter.classify("moot_memory_search") == .ask)
        #expect(PermissionsWriter.classify("moot_file_memory") == .ask)
        #expect(PermissionsWriter.classify("moot_withdraw_memory") == .ask, "withdraw is reversible — ask, not deny")
        #expect(PermissionsWriter.classify("moot_erase_memory") == .deny)
        #expect(PermissionsWriter.classify("moot_expunge_drawer") == .deny)
        // A brand-new unknown tool must land in the safe middle.
        #expect(PermissionsWriter.classify("moot_future_tool") == .ask)
    }

    @Test("permissionEntries all carry the mcp__mootx01__ prefix")
    func permissionEntryPrefix() {
        for entry in PermissionsWriter.permissionEntries(toolNames: toolNames) {
            #expect(entry.hasPrefix("mcp__mootx01__"))
        }
    }

    // MARK: - mergeTiered (the install default)

    @Test("mergeTiered writes each tool into its tier")
    func mergeTieredWritesTiers() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let settingsURL = dir.appendingPathComponent("settings.json")
        let added = try PermissionsWriter.mergeTiered(into: settingsURL, toolNames: toolNames)
        #expect(added.allow == 3 && added.ask == 2 && added.deny == 1)

        let perms = try readPermissions(settingsURL)
        #expect((perms["allow"] as? [String])?.contains("mcp__mootx01__moot_estate_ping") == true)
        #expect((perms["ask"] as? [String])?.contains("mcp__mootx01__moot_memory_search") == true)
        #expect((perms["deny"] as? [String])?.contains("mcp__mootx01__moot_erase_memory") == true)
    }

    @Test("mergeTiered is idempotent")
    func mergeTieredIdempotent() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let settingsURL = dir.appendingPathComponent("settings.json")
        _ = try PermissionsWriter.mergeTiered(into: settingsURL, toolNames: toolNames)
        let second = try PermissionsWriter.mergeTiered(into: settingsURL, toolNames: toolNames)
        #expect(second.allow == 0 && second.ask == 0 && second.deny == 0)

        let perms = try readPermissions(settingsURL)
        #expect((perms["allow"] as? [String])?.count == 3)
        #expect((perms["ask"] as? [String])?.count == 2)
        #expect((perms["deny"] as? [String])?.count == 1)
    }

    @Test("mergeTiered respects the user's existing placement over our default")
    func mergeTieredRespectsUserPlacement() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        // The user already allowed a tool we default to ask, and already
        // allowed one we default to deny. Their placement must survive.
        let existing: [String: Any] = [
            "permissions": ["allow": [
                "mcp__mootx01__moot_memory_search",
                "mcp__mootx01__moot_erase_memory",
            ]]
        ]
        let settingsURL = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: existing).write(to: settingsURL)

        _ = try PermissionsWriter.mergeTiered(into: settingsURL, toolNames: toolNames)

        let perms = try readPermissions(settingsURL)
        let allow = perms["allow"] as? [String] ?? []
        #expect(allow.contains("mcp__mootx01__moot_memory_search"), "user's allow must survive")
        #expect(allow.contains("mcp__mootx01__moot_erase_memory"), "user's allow must survive even for deny-default tools")
        #expect((perms["ask"] as? [String])?.contains("mcp__mootx01__moot_memory_search") != true, "must not duplicate into ask")
        #expect((perms["deny"] as? [String])?.contains("mcp__mootx01__moot_erase_memory") != true, "must not duplicate into deny")
    }

    // MARK: - merge (allow-all opt-in)

    @Test("merge creates settings.json and allows every tool")
    func mergeCreatesFile() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let settingsURL = dir.appendingPathComponent("settings.json")
        try PermissionsWriter.merge(into: settingsURL, toolNames: toolNames)

        let perms = try readPermissions(settingsURL)
        #expect((perms["allow"] as? [String])?.count == toolNames.count)
    }

    @Test("merge is idempotent and preserves existing + other keys")
    func mergeIdempotentPreserving() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let existing: [String: Any] = [
            "theme": "dark",
            "permissions": ["allow": ["mcp__other__tool"]],
        ]
        let settingsURL = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: existing).write(to: settingsURL)

        try PermissionsWriter.merge(into: settingsURL, toolNames: toolNames)
        try PermissionsWriter.merge(into: settingsURL, toolNames: toolNames)

        let data = try Data(contentsOf: settingsURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["theme"] as? String == "dark")
        let allow = (obj?["permissions"] as? [String: Any])?["allow"] as? [String] ?? []
        #expect(allow.contains("mcp__other__tool"), "existing entry must be preserved")
        #expect(allow.count == toolNames.count + 1)
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

        try PermissionsWriter.merge(into: settingsURL, toolNames: toolNames)

        let updated = try Data(contentsOf: settingsURL)
        #expect(Array(updated.prefix(3)) != [0xEF, 0xBB, 0xBF], "BOM should be gone after rewrite")
        let obj = try JSONSerialization.jsonObject(with: updated) as? [String: Any]
        #expect(obj?["theme"] as? String == "dark", "existing top-level keys must survive")
        let allow = (obj?["permissions"] as? [String: Any])?["allow"] as? [String] ?? []
        #expect(allow.contains("mcp__other__tool"), "existing allow entry must survive")
    }

    // MARK: - remove

    @Test("remove strips mcp__mootx01__ entries from all three tiers")
    func removeStripsAllTiers() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let settingsURL = dir.appendingPathComponent("settings.json")
        _ = try PermissionsWriter.mergeTiered(into: settingsURL, toolNames: toolNames)
        try PermissionsWriter.remove(from: settingsURL)

        let data = try Data(contentsOf: settingsURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let perms = obj?["permissions"] as? [String: Any] ?? [:]
        for key in ["allow", "ask", "deny"] {
            let list = perms[key] as? [String] ?? []
            #expect(!list.contains { $0.hasPrefix("mcp__mootx01__") }, "\(key) must hold none of ours")
        }
    }

    @Test("remove is prefix-based: cleans renamed/stale tools too")
    func removeCleansStaleNames() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        // A tool name granted by an OLD version (renamed since) must still be
        // removed — removal keys on the mcp__mootx01__ prefix, not a name list.
        let existing: [String: Any] = [
            "permissions": ["allow": ["mcp__mootx01__moot_capture_drawer", "mcp__other__tool"]]
        ]
        let settingsURL = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: existing).write(to: settingsURL)

        try PermissionsWriter.remove(from: settingsURL)

        let data = try Data(contentsOf: settingsURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let allow = (obj?["permissions"] as? [String: Any])?["allow"] as? [String] ?? []
        #expect(allow.contains("mcp__other__tool"), "non-ARIA entry must be preserved")
        #expect(!allow.contains("mcp__mootx01__moot_capture_drawer"), "stale ARIA entry must be removed")
    }

    @Test("remove is a no-op when settings.json does not exist")
    func removeNoOpWhenAbsent() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let settingsURL = dir.appendingPathComponent("nonexistent.json")
        // Should not throw.
        try PermissionsWriter.remove(from: settingsURL)
    }

    // MARK: - Helpers

    private func readPermissions(_ settingsURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["permissions"] as? [String: Any] ?? [:]
    }

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
