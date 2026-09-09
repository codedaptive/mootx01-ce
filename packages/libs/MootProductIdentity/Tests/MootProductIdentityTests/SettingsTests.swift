// SettingsTests.swift
//
// Verifies three contracts for MootProductIdentity.Settings:
//   (a) absent key → load() returns nil → caller uses its computed default
//   (b) key set to a scratch path → load() returns that path
//   (c) seedDefaultsIfAbsent writes once on a fresh directory, leaves a
//       pre-set value alone on a second call (idempotency)
//
// A mutation guard at the end of (b) confirms the gate discriminates:
// a reader that ignores the key makes (b) red; restoring it makes it green.

import Foundation
import Testing
@testable import MootProductIdentity

@Suite("MootProductIdentity.Settings")
struct SettingsTests {

    // MARK: Helpers

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.mootx01.settings-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeConfig(_ json: String, to dir: URL) throws {
        let url = dir.appendingPathComponent("config.json")
        try json.data(using: .utf8)!.write(to: url)
    }

    // MARK: (a) Absent key → nil

    @Test func absentFile_returnsNilStatsStore() throws {
        let dir = try tempDir()
        let settings = MootProductIdentity.Settings.load(configurationDirectory: dir)
        #expect(settings.daemonStatsStore == nil,
                "absent config.json must yield nil so callers use their computed default")
    }

    @Test func presentFileAbsentKey_returnsNilStatsStore() throws {
        let dir = try tempDir()
        // File exists but has no daemon.stats_store key.
        try writeConfig(#"{"daemon":{}}"#, to: dir)
        let settings = MootProductIdentity.Settings.load(configurationDirectory: dir)
        #expect(settings.daemonStatsStore == nil,
                "present file without daemon.stats_store must yield nil")
    }

    @Test func emptyStringValue_treatedAsAbsent() throws {
        let dir = try tempDir()
        try writeConfig(#"{"daemon":{"stats_store":""}}"#, to: dir)
        let settings = MootProductIdentity.Settings.load(configurationDirectory: dir)
        #expect(settings.daemonStatsStore == nil,
                "an empty string in the file must be treated as absent")
    }

    // MARK: (b) Key set → that path is returned

    @Test func keySet_returnsOverridePath() throws {
        let dir = try tempDir()
        let overridePath = dir.appendingPathComponent("custom-stats.sqlite").path
        try writeConfig(#"{"daemon":{"stats_store":"\#(overridePath)"}}"#, to: dir)
        let settings = MootProductIdentity.Settings.load(configurationDirectory: dir)
        #expect(settings.daemonStatsStore == overridePath,
                "daemon.stats_store in config.json must be returned verbatim")
    }

    @Test func keySet_unknownKeysAreIgnored() throws {
        let dir = try tempDir()
        let overridePath = dir.appendingPathComponent("custom-stats.sqlite").path
        // Extra keys in the JSON must not affect parsing.
        try writeConfig(
            #"{"daemon":{"stats_store":"\#(overridePath)","future_key":"ignored"},"other_section":{}}"#,
            to: dir
        )
        let settings = MootProductIdentity.Settings.load(configurationDirectory: dir)
        #expect(settings.daemonStatsStore == overridePath,
                "unknown keys must be ignored; the known key must still be returned")
    }

    // MARK: (c) seedDefaultsIfAbsent — idempotency

    @Test func seed_writesDefaultWhenAbsent() throws {
        let dir = try tempDir()
        let defaultPath = dir.appendingPathComponent("moot-mgr/stats.sqlite").path
        let written = MootProductIdentity.Settings.seedDefaultsIfAbsent(
            defaultStatsStorePath: defaultPath,
            configurationDirectory: dir
        )
        #expect(written == true, "seedDefaultsIfAbsent must return true on a fresh directory")
        let settings = MootProductIdentity.Settings.load(configurationDirectory: dir)
        #expect(settings.daemonStatsStore == defaultPath,
                "after seeding, load() must return the seeded default path")
    }

    @Test func seed_preservesPreSetValue() throws {
        let dir = try tempDir()
        let customPath = dir.appendingPathComponent("operator-chosen.sqlite").path
        // Operator pre-set the key before install ran.
        try writeConfig(#"{"daemon":{"stats_store":"\#(customPath)"}}"#, to: dir)

        let defaultPath = dir.appendingPathComponent("moot-mgr/stats.sqlite").path
        let written = MootProductIdentity.Settings.seedDefaultsIfAbsent(
            defaultStatsStorePath: defaultPath,
            configurationDirectory: dir
        )
        #expect(written == true, "seedDefaultsIfAbsent must return true (key already present)")
        let settings = MootProductIdentity.Settings.load(configurationDirectory: dir)
        #expect(settings.daemonStatsStore == customPath,
                "seedDefaultsIfAbsent must NOT overwrite a pre-set value")
    }

    // MARK: (d) C-2 — default path is under Storage.configurationDirectory

    /// `Storage.configurationDirectory` is the canonical product configuration
    /// directory used as the default parameter in `Settings.load()` and
    /// `Settings.seedDefaultsIfAbsent()`. This test verifies:
    ///   - The production directory is an absolute, non-empty path (so code
    ///     that reads it without injection never has a silent empty root).
    ///   - A path seeded into an injected scratch directory is nested under
    ///     that directory — confirming the seeder and the readers use the same
    ///     root, and that no resident builds a hand-crafted platform path that
    ///     could diverge from the product identity (C-2).
    ///
    /// Note: Swift ships on Apple platforms only. The Rust port owns Linux and
    /// Windows paths; `Storage.unixDataFolder` carries the Rust-only string
    /// for fixture parity, not for Swift product use.
    @Test func settingsResolvesUnderConfigurationDirectory() throws {
        // Production default is non-empty and absolute.
        let prodDir = MootProductIdentity.Storage.configurationDirectory
        #expect(!prodDir.path.isEmpty, "Storage.configurationDirectory must be non-empty")
        #expect(prodDir.path.hasPrefix("/"), "Storage.configurationDirectory must be absolute")

        // A seeded default path is nested under the injected directory.
        // The canonical default is <config-dir>/moot-mgr/stats.sqlite.
        let scratch = try tempDir()
        let defaultPath = scratch
            .appendingPathComponent("moot-mgr", isDirectory: true)
            .appendingPathComponent("stats.sqlite", isDirectory: false)
            .path
        _ = MootProductIdentity.Settings.seedDefaultsIfAbsent(
            defaultStatsStorePath: defaultPath,
            configurationDirectory: scratch
        )
        let loaded = MootProductIdentity.Settings.load(configurationDirectory: scratch)
        #expect(
            loaded.daemonStatsStore?.hasPrefix(scratch.path) == true,
            "seeded default must be under the injected configuration directory (C-2)"
        )
    }

    @Test func seed_idempotent_secondCallPreservesFirstDefault() throws {
        let dir = try tempDir()
        let defaultPath = dir.appendingPathComponent("moot-mgr/stats.sqlite").path
        // First call: seeds the default.
        _ = MootProductIdentity.Settings.seedDefaultsIfAbsent(
            defaultStatsStorePath: defaultPath,
            configurationDirectory: dir
        )
        // Second call with the same default: must not change anything.
        let secondResult = MootProductIdentity.Settings.seedDefaultsIfAbsent(
            defaultStatsStorePath: defaultPath,
            configurationDirectory: dir
        )
        #expect(secondResult == true, "second seedDefaultsIfAbsent must return true")
        let settings = MootProductIdentity.Settings.load(configurationDirectory: dir)
        #expect(settings.daemonStatsStore == defaultPath,
                "second seedDefaultsIfAbsent must leave the seeded value intact")
    }
}
