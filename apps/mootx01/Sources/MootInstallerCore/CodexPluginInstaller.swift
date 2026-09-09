import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A bounded, noninteractive Codex invocation. Nil means unavailable or failed.
public protocol CodexPluginCLIRunning: Sendable {
    func run(arguments: [String], homeDirectory: URL) -> String?
}

/// Uses the requested user's Codex configuration; tests substitute a runner.
public struct ProcessCodexPluginCLIRunner: CodexPluginCLIRunning {
    public init() {}

    public func run(arguments: [String], homeDirectory: URL) -> String? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: output.path, contents: nil,
            attributes: [.posixPermissions: 0o600]),
            let handle = try? FileHandle(forWritingTo: output) else { return nil }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["codex"] + arguments
        var environment = ProcessInfo.processInfo.environment
        if homeDirectory.standardizedFileURL != FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL {
            environment["CODEX_HOME"] = homeDirectory.appendingPathComponent(".codex").path
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        if finished.wait(timeout: .now() + 60) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return try? String(contentsOf: output, encoding: .utf8)
    }
}

/// Registers the embedded package with Codex; a loose directory is insufficient.
public enum CodexPluginInstaller {
    /// Upgrade only touches a registered, enabled plugin. An explicit install
    /// registers a fresh package. CLI failure leaves working MCP/skills available.
    public static func apply(
        homeDirectory: URL, binaryPath: String, upgradeOnly: Bool,
        vaultOff: Bool = false,
        runner: CodexPluginCLIRunning = ProcessCodexPluginCLIRunner()
    ) throws -> DepthOutcome {
        if upgradeOnly {
            guard let listing = runner.run(arguments: ["plugin", "list", "--json"], homeDirectory: homeDirectory),
                  let data = listing.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let installed = root["installed"] as? [[String: Any]] else {
                print("  ⓘ Codex: could not check installed plugins; plugin refresh skipped.")
                return .server
            }
            guard let plugin = installed.first(where: {
                $0["pluginId"] as? String == "mootx01@mootx01" && $0["installed"] as? Bool == true
            }) else { return .server }
            guard plugin["enabled"] as? Bool == true else {
                print("  ⓘ Codex: plugin is disabled; cache refresh deferred to preserve that setting.")
                return .server
            }
        }
        let outcome = try DepthInstaller.apply(clientID: "codex", depth: .plugin,
            homeDirectory: homeDirectory, binaryPath: binaryPath, vaultOff: vaultOff)
        guard case let .plugin(path) = outcome else { return outcome }
        // The embedded package contains the plugin manifest; the installer owns
        // the local marketplace registration, as it does for Claude Code.
        let manifest: [String: Any] = ["name": "mootx01",
            "owner": ["name": "Codedaptive"],
            "plugins": [["name": "mootx01", "source": "./"]]]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: URL(fileURLWithPath: path)
            .appendingPathComponent(".codex-plugin/marketplace.json"), options: .atomic)
        let commands = [
            ["plugin", "marketplace", "add", path],
            ["plugin", "add", "mootx01@mootx01"],
        ]
        for arguments in commands {
            guard runner.run(arguments: arguments, homeDirectory: homeDirectory) != nil else {
                let skill = try DepthInstaller.apply(clientID: "codex", depth: .skills,
                    homeDirectory: homeDirectory, binaryPath: binaryPath)
                if case let .skills(skillPath) = skill {
                    return .pluginFellBackToSkills(path: skillPath,
                        reason: "Codex registration failed; run codex plugin marketplace add \"\(path)\", then codex plugin add mootx01@mootx01")
                }
                return skill
            }
        }
        let pluginManifest = try Data(contentsOf: URL(fileURLWithPath: path)
            .appendingPathComponent(".codex-plugin/plugin.json"))
        let expected = try JSONSerialization.jsonObject(with: pluginManifest) as? [String: Any]
        guard let listing = runner.run(arguments: ["plugin", "list", "--json"], homeDirectory: homeDirectory),
              let data = listing.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let installed = root["installed"] as? [[String: Any]],
              let expectedVersion = expected?["version"] as? String,
              installed.contains(where: {
                  $0["pluginId"] as? String == "mootx01@mootx01"
                      && $0["installed"] as? Bool == true && $0["enabled"] as? Bool == true
                      && $0["version"] as? String == expectedVersion
              }) else {
            throw NSError(domain: "CodexPluginInstaller", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Codex did not report the bundled plugin version installed and enabled; direct MCP wiring retained."])
        }
        // Only retire installer-owned default wiring after the plugin is verified.
        // The existing cleanup keeps custom endpoints and estate selections intact.
        let usesDefaultCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map {
            URL(fileURLWithPath: $0).standardizedFileURL == homeDirectory.appendingPathComponent(".codex").standardizedFileURL
        } ?? true
        if homeDirectory.standardizedFileURL != FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            || usesDefaultCodexHome {
            switch Installer.cleanupRedundantCodexDirectEntry(homeDirectory: homeDirectory) {
            case let .retainedForeign(reason): print("  ⓘ Codex: kept custom MCP wiring (\(reason)).")
            case let .failed(message): print("  ⓘ Codex: \(message)")
            default: break
            }
        }
        return outcome
    }
}
