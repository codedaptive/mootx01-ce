// EnableCommand.swift
//
// `mootx01 enable <feature>` / `mootx01 disable <feature>`
//
// Toggles optional features on the running daemon by setting environment
// variables in the launchd plist and restarting the daemon. Currently
// supports: memory-tool (Anthropic memory_20250818 adapter).

import ArgumentParser
import Foundation
import MootInstallerCore

struct EnableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Enable an optional feature on the mootx01 daemon.",
        discussion: """
        Available features:
          memory-tool    Anthropic memory_20250818 adapter — governed /memories backend
        """
    )

    @Argument(help: "Feature to enable (e.g. memory-tool).")
    var feature: String

    func run() async throws {
        switch feature {
        case "memory-tool":
            try await toggleFeature(envVar: "MOOTX01_MEMORY_TOOL", value: "1", label: "memory tool")
        default:
            print("Unknown feature: \(feature)")
            print("Available features: memory-tool")
            throw ExitCode.failure
        }
    }
}

struct DisableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Disable an optional feature on the mootx01 daemon.",
        discussion: """
        Available features:
          memory-tool    Anthropic memory_20250818 adapter — governed /memories backend
        """
    )

    @Argument(help: "Feature to disable (e.g. memory-tool).")
    var feature: String

    func run() async throws {
        switch feature {
        case "memory-tool":
            try await toggleFeature(envVar: "MOOTX01_MEMORY_TOOL", value: "0", label: "memory tool")
        default:
            print("Unknown feature: \(feature)")
            print("Available features: memory-tool")
            throw ExitCode.failure
        }
    }
}

/// Set an environment variable in the daemon's launchd plist and restart.
private func toggleFeature(envVar: String, value: String, label: String) async throws {
    let enabled = value != "0"
    let verb = enabled ? "Enabling" : "Disabling"
    print("\(verb) \(label)...")

    #if os(macOS)
    let home = FileManager.default.homeDirectoryForCurrentUser
    let plistURL = MootPaths.daemonPlistURL(homeDirectory: home)
    let plistPath = plistURL.path
    guard FileManager.default.fileExists(atPath: plistPath) else {
        print("  ✗ daemon plist not found at \(plistPath)")
        print("  Run `mootx01 install` first.")
        throw ExitCode.failure
    }

    // Read the plist, update the EnvironmentVariables dict, write back.
    guard var plist = NSDictionary(contentsOfFile: plistPath) as? [String: Any] else {
        print("  ✗ could not read plist")
        throw ExitCode.failure
    }

    var env = plist["EnvironmentVariables"] as? [String: String] ?? [:]
    if enabled {
        env[envVar] = value
    } else {
        env.removeValue(forKey: envVar)
    }
    plist["EnvironmentVariables"] = env

    let data = try PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: URL(fileURLWithPath: plistPath))

    // Restart the daemon so it picks up the new env.
    let uid = getuid()
    let domain = "gui/\(uid)"
    let serviceLabel = MootPaths.daemonLabel

    let bootout = Process()
    bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    bootout.arguments = ["bootout", "\(domain)/\(serviceLabel)"]
    try? bootout.run()
    bootout.waitUntilExit()

    // Brief pause for clean shutdown.
    try await Task.sleep(for: .seconds(1))

    let bootstrap = Process()
    bootstrap.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    bootstrap.arguments = ["bootstrap", domain, plistPath]
    try bootstrap.run()
    bootstrap.waitUntilExit()

    if bootstrap.terminationStatus == 0 {
        let status = enabled ? "enabled" : "disabled"
        print("  ✓ \(label) \(status) — daemon restarted")
    } else {
        print("  ✗ daemon restart failed (exit \(bootstrap.terminationStatus))")
        throw ExitCode.failure
    }

    #else
    // Linux/Windows: write to a config file instead of launchd plist.
    let home = FileManager.default.homeDirectoryForCurrentUser
    let configDir = home.appendingPathComponent(".mootx01").path
    let configPath = configDir + "/features.env"
    var lines: [String] = []
    if FileManager.default.fileExists(atPath: configPath),
       let content = try? String(contentsOfFile: configPath, encoding: .utf8) {
        lines = content.components(separatedBy: "\n").filter {
            !$0.hasPrefix("\(envVar)=")
        }
    }
    if enabled {
        lines.append("\(envVar)=\(value)")
    }
    let content = lines.joined(separator: "\n") + "\n"
    try? FileManager.default.createDirectory(
        atPath: configDir, withIntermediateDirectories: true)
    try content.write(toFile: configPath, atomically: true, encoding: .utf8)
    let status = enabled ? "enabled" : "disabled"
    print("  ✓ \(label) \(status)")
    print("  Restart the daemon for the change to take effect.")
    #endif
}
