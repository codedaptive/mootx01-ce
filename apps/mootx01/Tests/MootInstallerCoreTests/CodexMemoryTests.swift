import Foundation
import Testing
@testable import MootInstallerCore

@Suite("Codex memory")
struct CodexMemoryTests {
    @Test("moot-only settings preserve unrelated TOML and restore only managed keys")
    func nativeMemoryRoundTrip() {
        let original = """
        model = "gpt-5"

        [features]
        memories = true # user choice
        shell_snapshot = true

        [memories]
        generate_memories = true
        max_rollout_chars = 1234

        [other]
        value = "keep"
        """ + "\n"
        let snapshot = CodexNativeMemorySettings.snapshot(in: original)
        let disabled = CodexNativeMemorySettings.disableNativeMemories(in: original)
        #expect(CodexNativeMemorySettings.value(in: disabled, table: "features", key: "memories") == "false")
        #expect(CodexNativeMemorySettings.value(in: disabled, table: "memories", key: "generate_memories") == "false")
        #expect(CodexNativeMemorySettings.value(in: disabled, table: "memories", key: "use_memories") == "false")
        #expect(disabled.contains("shell_snapshot = true"))
        #expect(disabled.contains("max_rollout_chars = 1234"))
        #expect(disabled.contains("value = \"keep\""))

        // A later user edit to an unrelated setting survives disable.
        let edited = disabled.replacingOccurrences(of: "value = \"keep\"", with: "value = \"later\"")
        let restored = CodexNativeMemorySettings.restore(snapshot, in: edited)
        #expect(CodexNativeMemorySettings.value(in: restored, table: "features", key: "memories") == "true # user choice")
        #expect(CodexNativeMemorySettings.value(in: restored, table: "memories", key: "generate_memories") == "true")
        #expect(CodexNativeMemorySettings.value(in: restored, table: "memories", key: "use_memories") == nil)
        #expect(restored.contains("value = \"later\""))
    }

    @Test("configuration and session state live under private MOOT storage")
    func secureState() throws {
        let home = try sandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        try CodexMemoryStore.save(CodexMemoryConfiguration(), homeDirectory: home)
        var state = CodexHookState()
        state.observedMOOTWrite = true
        try CodexMemoryStore.saveState(state, sessionID: "thread/unsafe", homeDirectory: home)
        #expect(CodexMemoryStore.load(homeDirectory: home)?.mode == .augment)
        #expect(CodexMemoryStore.loadState(sessionID: "thread/unsafe", homeDirectory: home).observedMOOTWrite)
        let stateURL = CodexMemoryPaths.stateFile(sessionID: "thread/unsafe", homeDirectory: home)
        #expect(!stateURL.lastPathComponent.contains("/"))
        let attrs = try FileManager.default.attributesOfItem(atPath: stateURL.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        CodexMemoryStore.removeState(sessionID: "thread/unsafe", homeDirectory: home)
        #expect(!FileManager.default.fileExists(atPath: stateURL.path))
    }

    @Test("Chronicle import reads Markdown only and deduplicates by SHA-256")
    func chronicleImport() async throws {
        let home = try sandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("chronicle")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "generated memory".write(to: root.appendingPathComponent("one.md"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: root.appendingPathComponent("capture.png"))
        try "hidden".write(to: root.appendingPathComponent(".hidden.md"), atomically: true, encoding: .utf8)
        let daemon = CodexMemoryMockDaemon()
        let first = await CodexChronicleImporter.run(root: root, homeDirectory: home, daemon: daemon)
        let second = await CodexChronicleImporter.run(root: root, homeDirectory: home, daemon: daemon)
        #expect(first.imported == 1)
        #expect(second.duplicates == 1)
        #expect(daemon.filed.count == 1)
        #expect(daemon.filed[0].location == "codex-chronicle/one.md")
        #expect(daemon.filed[0].content.contains("confirmation: unconfirmed"))
        #expect(daemon.filed[0].content.contains("source_sha256:"))
    }

    @Test("Codex plugin ownership requires enabled config and cached manifest")
    func codexPluginDetector() throws {
        let home = try sandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[plugins.\"mootx01@mootx01\"]\nenabled = true\n".write(
            to: config, atomically: true, encoding: .utf8)
        #expect(PluginDetector.isCodexPluginEnabled(pluginID: "mootx01@mootx01", homeDirectory: home))
        #expect(!PluginDetector.ownsCodexConnection(pluginID: "mootx01@mootx01", homeDirectory: home))

        // Legacy shared marketplaces can be installed by Codex from their
        // Claude discovery manifest; ownership detection must still converge
        // those installs to the new native Codex package.
        let manifest = home.appendingPathComponent(
            ".codex/plugins/cache/mootx01/mootx01/1.1.0-beta-19/.claude-plugin/plugin.json")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"name":"mootx01","version":"1.1.0-beta-19"}"#.write(
            to: manifest, atomically: true, encoding: .utf8)
        #expect(PluginDetector.ownsCodexConnection(pluginID: "mootx01@mootx01", homeDirectory: home))
        #expect(PluginDetector.codexInstalledVersion(homeDirectory: home) == "1.1.0-beta-19")
    }

    private func sandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-memory-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class CodexMemoryMockDaemon: DaemonClient, @unchecked Sendable {
    var filed: [(location: String, content: String)] = []
    func fileMemory(location: String, content: String, subject: String, eventTime: Date, kind: String?) async throws -> Bool {
        filed.append((location, content)); return true
    }
    func listMemories(locationPrefix: String) async throws -> [HarnessMemoryRecord] { [] }
    func updateMemory(id: String, mutation: String, note: String) async throws {}
    func ping() async -> Bool { true }
}
