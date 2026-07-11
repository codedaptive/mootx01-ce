// DataRetentionTests.swift
//
// Tests for DataRetention: the uninstall remove-data decision matrix, the
// reinstall existing-database decision matrix, the filesystem inventory,
// and the apply actions with an injected mover (the suite never touches
// the real Trash). The matrices are the safety contract: every branch that
// can destroy data must be reachable only through an explicit human 'yes'
// or an explicit-flag automation pair. Mirrors the Rust twins in
// commands/uninstall.rs and commands/install.rs.

import Testing
import Foundation
@testable import MootInstallerCore

@Suite("DataRetention")
struct DataRetentionTests {

    // MARK: - Helpers

    /// A prompt closure that must not be reached in the branch under test.
    private func neverCalled() -> Bool {
        Issue.record("prompt must not be reached in this branch")
        return false
    }

    /// Lock-guarded recorder so a @Sendable Mover can collect what moved.
    private final class MoveRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func record(_ name: String) {
            lock.lock()
            names.append(name)
            lock.unlock()
        }
        var moved: [String] {
            lock.lock()
            defer { lock.unlock() }
            return names
        }
    }

    private func makeDataDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mootx01-retention-\(tag)-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Uninstall decision matrix

    @Test("non-interactive without purge leaves data")
    func nonInteractiveLeaves() {
        let d = DataRetention.decideDataRemoval(
            purge: false, yes: false, interactive: false,
            offer: neverCalled, confirm: neverCalled)
        guard case .leave = d else {
            Issue.record("expected .leave, got \(d)")
            return
        }
    }

    @Test("--yes alone still leaves data (historical automation contract)")
    func yesAloneLeaves() {
        let d = DataRetention.decideDataRemoval(
            purge: false, yes: true, interactive: false,
            offer: neverCalled, confirm: neverCalled)
        guard case .leave = d else {
            Issue.record("expected .leave, got \(d)")
            return
        }
    }

    @Test("--purge --yes trashes without prompting")
    func purgeYesTrashes() {
        let d = DataRetention.decideDataRemoval(
            purge: true, yes: true, interactive: false,
            offer: neverCalled, confirm: neverCalled)
        #expect(d == .trash)
    }

    @Test("--purge without --yes on a non-TTY leaves data")
    func purgeNonInteractiveLeaves() {
        let d = DataRetention.decideDataRemoval(
            purge: true, yes: false, interactive: false,
            offer: neverCalled, confirm: neverCalled)
        guard case .leave = d else {
            Issue.record("expected .leave, got \(d)")
            return
        }
    }

    @Test("interactive offer declined leaves data")
    func offerDeclinedLeaves() {
        let d = DataRetention.decideDataRemoval(
            purge: false, yes: false, interactive: true,
            offer: { false }, confirm: neverCalled)
        guard case .leave = d else {
            Issue.record("expected .leave, got \(d)")
            return
        }
    }

    @Test("interactive offer accepted still requires typed yes")
    func offerAcceptedNeedsConfirm() {
        let aborted = DataRetention.decideDataRemoval(
            purge: false, yes: false, interactive: true,
            offer: { true }, confirm: { false })
        #expect(aborted == .aborted)
        let trashed = DataRetention.decideDataRemoval(
            purge: false, yes: false, interactive: true,
            offer: { true }, confirm: { true })
        #expect(trashed == .trash)
    }

    @Test("--purge interactive skips the offer but confirms")
    func purgeInteractiveConfirms() {
        let d = DataRetention.decideDataRemoval(
            purge: true, yes: false, interactive: true,
            offer: neverCalled, confirm: { true })
        #expect(d == .trash)
    }

    // MARK: - Install existing-database decision matrix

    @Test("no flag, non-interactive: untouched (CI harness contract)")
    func noFlagNonInteractiveUntouched() {
        let d = DataRetention.decideExistingDb(
            flag: nil, yes: false, interactive: false,
            choose: neverCalled, confirm: neverCalled)
        guard case .untouched = d else {
            Issue.record("expected .untouched, got \(d)")
            return
        }
        // --yes alone must not pick a disposition for existing data.
        let dYes = DataRetention.decideExistingDb(
            flag: nil, yes: true, interactive: false,
            choose: neverCalled, confirm: neverCalled)
        guard case .untouched = dYes else {
            Issue.record("expected .untouched, got \(dYes)")
            return
        }
    }

    @Test("--reuse-db needs no confirmation")
    func reuseFlagDirect() {
        let d = DataRetention.decideExistingDb(
            flag: .reuse, yes: false, interactive: false,
            choose: neverCalled, confirm: neverCalled)
        #expect(d == .reuse)
    }

    @Test("--replace-db obeys the yes/interactive gates")
    func replaceFlagGates() {
        #expect(DataRetention.decideExistingDb(
            flag: .replace, yes: true, interactive: false,
            choose: neverCalled, confirm: neverCalled) == .replace)
        // Non-interactive without --yes: nobody can type the confirmation.
        let untouched = DataRetention.decideExistingDb(
            flag: .replace, yes: false, interactive: false,
            choose: neverCalled, confirm: neverCalled)
        guard case .untouched = untouched else {
            Issue.record("expected .untouched, got \(untouched)")
            return
        }
        #expect(DataRetention.decideExistingDb(
            flag: .replace, yes: false, interactive: true,
            choose: neverCalled, confirm: { false }) == .aborted)
        #expect(DataRetention.decideExistingDb(
            flag: .replace, yes: false, interactive: true,
            choose: neverCalled, confirm: { true }) == .replace)
    }

    @Test("interactive prompt drives reuse and replace paths")
    func interactivePromptPaths() {
        #expect(DataRetention.decideExistingDb(
            flag: nil, yes: false, interactive: true,
            choose: { false }, confirm: neverCalled) == .reuse)
        #expect(DataRetention.decideExistingDb(
            flag: nil, yes: false, interactive: true,
            choose: { true }, confirm: { true }) == .replace)
        #expect(DataRetention.decideExistingDb(
            flag: nil, yes: false, interactive: true,
            choose: { true }, confirm: { false }) == .aborted)
    }

    // MARK: - Inventory and detection

    @Test("inventory reports default, named, and mgr; nil when empty")
    func inventoryContents() throws {
        let dir = try makeDataDir("inventory")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(DataRetention.dataInventory(in: dir.appendingPathComponent("missing")) == nil)
        #expect(DataRetention.dataInventory(in: dir) == nil)

        let fm = FileManager.default
        fm.createFile(atPath: dir.appendingPathComponent("estate.sqlite").path, contents: Data("x".utf8))
        try fm.createDirectory(
            at: dir.appendingPathComponent("databases/work"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: dir.appendingPathComponent("moot-mgr"), withIntermediateDirectories: true)
        fm.createFile(
            atPath: dir.appendingPathComponent("moot-mgr/stats.sqlite").path, contents: Data("x".utf8))

        let inv = try #require(DataRetention.dataInventory(in: dir))
        #expect(inv.contains("default estate database"))
        #expect(inv.contains("1 named estate(s)"))
        #expect(inv.contains("moot-mgr history database"))
    }

    @Test("default-estate detection covers both layouts")
    func defaultEstateDetection() throws {
        let dir = try makeDataDir("detect")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!DataRetention.defaultEstateExists(in: dir))
        // Swift flat layout.
        let fm = FileManager.default
        fm.createFile(atPath: dir.appendingPathComponent("estate.sqlite").path, contents: Data("x".utf8))
        #expect(DataRetention.defaultEstateExists(in: dir))
        try fm.removeItem(at: dir.appendingPathComponent("estate.sqlite"))
        // Rust databases/default layout (a migrated data directory).
        try fm.createDirectory(
            at: dir.appendingPathComponent("databases/default"), withIntermediateDirectories: true)
        fm.createFile(
            atPath: dir.appendingPathComponent("databases/default/estate.sqlite").path,
            contents: Data("x".utf8))
        #expect(DataRetention.defaultEstateExists(in: dir))
    }

    // MARK: - Apply actions (injected mover; never the real Trash)

    @Test("applyReplace moves estate files + mgr store, keeps named estates")
    func applyReplaceScope() throws {
        let dir = try makeDataDir("replace")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        for name in ["estate.sqlite", "estate.sqlite-wal", "estate.vectors.vec",
                     "estate.queue.sqlite"] {
            fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        try fm.createDirectory(
            at: dir.appendingPathComponent("databases/default"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: dir.appendingPathComponent("databases/work"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: dir.appendingPathComponent("moot-mgr"), withIntermediateDirectories: true)

        let recorder = MoveRecorder()
        try DataRetention.applyReplace(in: dir) { url in
            recorder.record(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }
        let moved = recorder.moved
        #expect(moved.contains("estate.sqlite"))
        #expect(moved.contains("estate.sqlite-wal"))
        #expect(moved.contains("estate.vectors.vec"))
        #expect(moved.contains("estate.queue.sqlite"))
        #expect(moved.contains("default"), "databases/default must move")
        #expect(moved.contains("moot-mgr"), "the mgr store must reset")
        #expect(!moved.contains("work"), "named estates are untouched by replace")
        // The active-estate pointer converges on default.
        #expect(try DatabaseManager.activeEstateName(in: dir) == "default")
    }

    @Test("applyReuse resets only the mgr store and repoints default")
    func applyReuseScope() throws {
        let dir = try makeDataDir("reuse")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        fm.createFile(atPath: dir.appendingPathComponent("estate.sqlite").path, contents: Data("x".utf8))
        try fm.createDirectory(
            at: dir.appendingPathComponent("moot-mgr"), withIntermediateDirectories: true)
        try DatabaseManager.setActiveEstate("work", in: dir)

        let recorder = MoveRecorder()
        try DataRetention.applyReuse(in: dir) { url in
            recorder.record(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }
        #expect(recorder.moved == ["moot-mgr"], "reuse must move ONLY the mgr store")
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("estate.sqlite").path),
                "the adopted estate must stay in place")
        #expect(try DatabaseManager.activeEstateName(in: dir) == "default")
    }
}
