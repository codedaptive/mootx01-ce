import Foundation
import Testing
@testable import MootInstallerCore

@Suite("Codex plugin registration")
struct CodexPluginInstallerTests {
    final class Runner: CodexPluginCLIRunning, @unchecked Sendable {
        let listing: String?
        let failAt: Int?
        private let lock = NSLock()
        private var calls: [[String]] = []
        init(listing: String? = registeredListing, failAt: Int? = nil) {
            self.listing = listing; self.failAt = failAt
        }
        var arguments: [[String]] { lock.lock(); defer { lock.unlock() }; return calls }
        func run(arguments: [String], homeDirectory: URL) -> String? {
            lock.lock(); defer { lock.unlock() }
            calls.append(arguments)
            if calls.count == failAt { return nil }
            return arguments == ["plugin", "list", "--json"] ? listing : "{}"
        }
    }

    static var registeredListing: String {
        let contents = InstallBundle.embedded.packageFiles(forHostID: "codex")[".codex-plugin/plugin.json"]!
        let manifest = try! JSONSerialization.jsonObject(with: Data(contents.utf8)) as! [String: Any]
        let row: [String: Any] = ["pluginId": "mootx01@mootx01", "installed": true,
            "enabled": true, "version": manifest["version"]!]
        return String(data: try! JSONSerialization.data(withJSONObject: ["installed": [row]]), encoding: .utf8)!
    }

    @Test func installRegistersEmbeddedPackage() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = Runner()
        let result = try CodexPluginInstaller.apply(homeDirectory: home,
            binaryPath: "/safe/mootx01", upgradeOnly: false, runner: runner)
        guard case let .plugin(path) = result else { Issue.record("plugin not registered"); return }
        #expect(runner.arguments == [["plugin", "marketplace", "add", path],
            ["plugin", "add", "mootx01@mootx01"], ["plugin", "list", "--json"]])
        let manifest = URL(fileURLWithPath: path).appendingPathComponent(".codex-plugin/marketplace.json")
        let data = try Data(contentsOf: manifest)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["name"] as? String == "mootx01")
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: path)
            .appendingPathComponent(".codex-plugin/plugin.json").path))
    }

    @Test(arguments: ["{\"installed\":[]}",
        "{\"installed\":[{\"pluginId\":\"mootx01@mootx01\",\"installed\":true,\"enabled\":false}]}",
        "{\"available\":[{\"pluginId\":\"mootx01@mootx01\",\"installed\":true,\"enabled\":true}]}",
        "invalid"])
    func upgradeDoesNotCreateOrEnablePlugin(listing: String) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runner = Runner(listing: listing)
        let result = try CodexPluginInstaller.apply(homeDirectory: home,
            binaryPath: "/safe/mootx01", upgradeOnly: true, runner: runner)
        #expect(result == .server)
        #expect(runner.arguments == [["plugin", "list", "--json"]])
        #expect(!FileManager.default.fileExists(atPath: home.path))
    }

    @Test func upgradeFindsMarketplaceInstallWithoutLooseDirectory() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = Runner()
        let result = try CodexPluginInstaller.apply(homeDirectory: home,
            binaryPath: "/safe/mootx01", upgradeOnly: true, runner: runner)
        guard case .plugin = result else { Issue.record("upgrade not registered"); return }
        #expect(runner.arguments.count == 4)
        #expect(runner.arguments.last == ["plugin", "list", "--json"])
    }

    @Test(arguments: [1, 2]) func failedRegistrationReportsSkillsFallback(failAt: Int) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = Runner(failAt: failAt)
        let result = try CodexPluginInstaller.apply(homeDirectory: home,
            binaryPath: "/safe/mootx01", upgradeOnly: false, runner: runner)
        guard case let .pluginFellBackToSkills(path, _) = result else {
            Issue.record("failure falsely reported as installed"); return
        }
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(runner.arguments.count == failAt)
    }

    @Test func successfulCommandsWithoutRegistrationFailReadback() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "[mcp_servers.mootx01]\nurl = \"http://127.0.0.1:4242/mcp\"\n"
        try original.write(to: config, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) {
            try CodexPluginInstaller.apply(homeDirectory: home, binaryPath: "/safe/mootx01",
                upgradeOnly: false, runner: Runner(listing: "{\"installed\":[]}"))
        }
        #expect(try String(contentsOf: config, encoding: .utf8) == original)
    }
}
