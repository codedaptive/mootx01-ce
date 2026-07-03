// ClaudeDesktopExtension.swift
//
// Installs mootx01 as a Claude Desktop extension — Desktop's equivalent of a
// plugin. Desktop does NOT read a plugin directory or ~/.claude/settings.json;
// it discovers extensions from its OWN registry inside the Claude data dir. A
// .mcpb double-click writes three things, and this reproduces them
// programmatically so `mootx01 install` (and therefore the .pkg, which runs it)
// wires Desktop with no manual step:
//
//   1. Claude Extensions/<id>/manifest.json      — the unpacked bundle manifest
//   2. extensions-installations.json  <id> entry — the registry record
//   3. Claude Extensions Settings/<id>.json      — {"isEnabled": true}
//
// The registry `source` is "local" and `signatureInfo` is unsigned — both
// accepted for sideloaded extensions. The manifest's mcp_config.command is the
// real installed binary path, resolved at install time, so nothing is
// hardcoded and the same code works on any machine.
//
// macOS only. This is the Swift install vertical (macOS/Linux); Windows ships
// the Rust vertical and registers the Desktop extension in the Rust installer.
// Linux has no Claude Desktop, so the whole file is gated to macOS.

import Foundation

#if os(macOS)
// CryptoKit (system framework), not swift-crypto: this file also builds inside
// the Mootx01-Setup package, whose dependency tree does not carry swift-crypto.
import CryptoKit

public enum ClaudeDesktopExtension {

    /// Stable extension id. Every install path (this installer, a .mcpb
    /// double-click, the marketplace) MUST use the same id/name so Desktop
    /// collapses them to a single entry rather than showing duplicates.
    ///
    /// NOT arbitrary: Desktop derives sideloaded ids as
    /// `local.mcpb.<sanitized author.name>.<sanitized manifest.name>` and its
    /// install-from-file path rejects a mismatch — so the manifest's
    /// author/name below must never change without re-deriving this id
    /// (verified against the Desktop app's own install code, 2026-07-03).
    public static let id = "local.mcpb.codedaptive.mootx01"

    /// Install (or refresh) the Desktop extension in the main Claude data dir
    /// AND every Parall sandboxed instance (each Parall/<name>/ dir is a full
    /// Claude data dir with its own extension registry — extension installs
    /// are per-instance, exactly like the raw config wiring). Returns the dirs
    /// written; empty when Claude Desktop is not present. Throws only on a
    /// genuine write failure.
    @discardableResult
    public static func install(binaryPath: String, version: String, homeDirectory: URL) throws -> [String] {
        let fm = FileManager.default
        let appSupport = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)

        var claudeDirs = [appSupport.appendingPathComponent("Claude", isDirectory: true)]
        // Parall instances: any Parall/<instance>/ holding a Claude Desktop
        // config is a sandboxed Claude data dir (mirrors Installer.parallConfigPaths).
        let parallRoot = appSupport.appendingPathComponent("Parall", isDirectory: true)
        if let instances = try? fm.contentsOfDirectory(
            at: parallRoot, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
            claudeDirs += instances
                .filter { fm.fileExists(atPath: $0.appendingPathComponent("claude_desktop_config.json").path) }
                .sorted { $0.path < $1.path }
        }

        var written: [String] = []
        for claudeDir in claudeDirs where fm.fileExists(atPath: claudeDir.path) {
            try writeExtension(into: claudeDir, binaryPath: binaryPath, version: version)
            written.append(claudeDir.path)
        }
        return written
    }

    /// The three writes, into one Claude data dir.
    private static func writeExtension(into claudeDir: URL, binaryPath: String, version: String) throws {
        let fm = FileManager.default

        // Manifest — display_name matches `name` ("mootx01") so this collapses
        // with the raw mcpServers entry mootx01 install also writes.
        let manifest: [String: Any] = [
            "manifest_version": "0.2",
            "name": "mootx01",
            "display_name": "mootx01",
            "version": version,
            "description": "MOOTx01 as active long-term memory and a low-token reasoning substrate: recall, analyze, contradiction-check, and write back durable knowledge.",
            "author": ["name": "Codedaptive", "url": "https://mootx01.ai"],
            "homepage": "https://mootx01.ai",
            "server": [
                "type": "binary",
                "entry_point": "mootx01",
                "mcp_config": [
                    "command": binaryPath,
                    "args": ["proxy"],
                    "env": [String: String](),
                ],
            ],
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])

        // 1. Unpack the manifest into the extensions dir.
        let extDir = claudeDir
            .appendingPathComponent("Claude Extensions", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: extDir, withIntermediateDirectories: true)
        try manifestData.write(to: extDir.appendingPathComponent("manifest.json"), options: .atomic)

        // 2. Register it (merge — never clobber other installed extensions). The
        //    hash is a record only: Desktop discards the .mcpb after unpacking
        //    and zip output is non-deterministic, so it cannot re-derive it on
        //    load — a stable sha256 of the manifest serves.
        let regURL = claudeDir.appendingPathComponent("extensions-installations.json", isDirectory: false)
        var reg: [String: Any] = [:]
        if let data = try? Data(contentsOf: regURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            reg = obj
        }
        var exts = reg["extensions"] as? [String: Any] ?? [:]
        let hash = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
        exts[id] = [
            "id": id,
            "version": version,
            "hash": hash,
            "installedAt": iso8601Now(),
            "manifest": manifest,
            "signatureInfo": ["status": "unsigned"],
            "source": "local",
        ]
        reg["extensions"] = exts
        let regData = try JSONSerialization.data(
            withJSONObject: reg, options: [.prettyPrinted, .sortedKeys])
        try regData.write(to: regURL, options: .atomic)

        // 3. Enable it — the enabled flag lives in a separate settings file, and
        //    an absent file reads as DISABLED (the extension would install but
        //    stay off until the user toggles it).
        let settingsDir = claudeDir.appendingPathComponent("Claude Extensions Settings", isDirectory: true)
        try fm.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        let enabled = try JSONSerialization.data(withJSONObject: ["isEnabled": true])
        try enabled.write(to: settingsDir.appendingPathComponent("\(id).json"), options: .atomic)
    }

    private static func iso8601Now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
#endif
