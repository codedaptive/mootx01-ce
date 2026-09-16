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

    /// Security (Codex 7441be4c, tightened for the brew-postinstall hang):
    /// under --yes with no explicit flag the prompt is never shown — the
    /// prompt's default (reuse, non-destructive) is taken, so a wrapper that
    /// runs `install --yes` with a TTY attached cannot block, and replace is
    /// unreachable without the explicit --replace-db flag. The typed
    /// destruction confirmation is skipped ONLY on the explicit
    /// --replace-db --yes automation path.
    @Test("--yes answers the prompt with reuse; replace needs the explicit flag")
    func yesAnswersPromptWithReuse() {
        // --yes + no flag + interactive: reuse, without ever prompting.
        #expect(DataRetention.decideExistingDb(
            flag: nil, yes: true, interactive: true,
            choose: neverCalled, confirm: neverCalled) == .reuse,
            "--yes must take the non-destructive default without prompting")
        // Explicit-flag path unchanged: --replace-db --yes skips confirm.
        #expect(DataRetention.decideExistingDb(
            flag: .replace, yes: true, interactive: true,
            choose: neverCalled, confirm: neverCalled) == .replace)
        // Explicit --replace-db WITHOUT --yes still gates on the typed
        // confirmation (destruction is never a silent default).
        #expect(DataRetention.decideExistingDb(
            flag: .replace, yes: false, interactive: true,
            choose: neverCalled, confirm: { false }) == .aborted)
    }

    // MARK: - Inventory and detection

    @Test("inventory reports default, named, and mgr; nil when empty")
    func inventoryContents() throws {
        let dir = try makeDataDir("inventory")
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaultDB = dir.appendingPathComponent("databases/default/estate.sqlite")
        let workDB = dir.appendingPathComponent("databases/work/estate.sqlite")
        #expect(DataRetention.dataInventory(
            defaultDatabaseURL: defaultDB, namedDatabaseURLs: [workDB],
            configurationDirectory: dir.appendingPathComponent("missing")) == nil)
        #expect(DataRetention.dataInventory(
            defaultDatabaseURL: defaultDB, namedDatabaseURLs: [workDB], configurationDirectory: dir) == nil)

        let fm = FileManager.default
        try fm.createDirectory(at: defaultDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: defaultDB.path, contents: Data("x".utf8))
        try fm.createDirectory(at: workDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: workDB.path, contents: Data("x".utf8))
        // A registered estate whose database was never created does not count.
        let emptyDB = dir.appendingPathComponent("databases/empty/estate.sqlite")
        try fm.createDirectory(
            at: dir.appendingPathComponent("moot-mgr"), withIntermediateDirectories: true)
        fm.createFile(
            atPath: dir.appendingPathComponent("moot-mgr/stats.sqlite").path, contents: Data("x".utf8))

        let inv = try #require(DataRetention.dataInventory(
            defaultDatabaseURL: defaultDB, namedDatabaseURLs: [workDB, emptyDB], configurationDirectory: dir))
        #expect(inv.contains("default estate database"))
        #expect(inv.contains("1 named estate(s)"))
        #expect(inv.contains("moot-mgr history database"))
    }

    @Test("estate detection is the record's database file")
    func estateDetection() throws {
        let dir = try makeDataDir("detect")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("databases/default/estate.sqlite")
        #expect(!DataRetention.estateExists(databaseURL: db))
        let fm = FileManager.default
        try fm.createDirectory(at: db.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: db.path, contents: Data("x".utf8))
        #expect(DataRetention.estateExists(databaseURL: db))
    }

    // MARK: - Apply actions (injected mover; never the real Trash)

    @Test("uninstall trashes external registered estates and collapses in-tree estates")
    func uninstallTrashScope() throws {
        let dir = try makeDataDir("uninstall")
        let external = try makeDataDir("uninstall-external")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: external)
        }
        let fm = FileManager.default
        let inTree = dir.appendingPathComponent("databases/default/estate.sqlite")
        let externalDB = external.appendingPathComponent("work/estate.sqlite")
        let absentExternalDB = external.appendingPathComponent("absent/estate.sqlite")
        for database in [inTree, externalDB] {
            try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: database.path, contents: Data("x".utf8))
        }

        let recorder = MoveRecorder()
        try DataRetention.trashDataDirectory(
            dir,
            registeredDatabaseURLs: [inTree, externalDB, externalDB, absentExternalDB]
        ) { url in
            recorder.record(url.path)
            try fm.removeItem(at: url)
        }

        #expect(Set(recorder.moved) == Set([dir.path, externalDB.deletingLastPathComponent().path]))
        #expect(recorder.moved.last == dir.path, "the catalog moves only after external estates")
        #expect(!fm.fileExists(atPath: dir.path))
        #expect(!fm.fileExists(atPath: externalDB.path))
    }

    @Test("applyReplace moves the estate's files + mgr store, keeps the directory and other estates")
    func applyReplaceScope() throws {
        let dir = try makeDataDir("replace")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let estateDir = dir.appendingPathComponent("databases/default", isDirectory: true)
        try fm.createDirectory(at: estateDir, withIntermediateDirectories: true)
        let present = ["estate.sqlite", "estate.sqlite-wal", "estate.vectors.vec", "estate.queue.sqlite", "no-encrypt"]
        for name in present {
            fm.createFile(atPath: estateDir.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        let estateFiles = (present + ["estate.json", "estate.pid"]).map { estateDir.appendingPathComponent($0) }
        try fm.createDirectory(
            at: dir.appendingPathComponent("databases/work"), withIntermediateDirectories: true)
        fm.createFile(atPath: dir.appendingPathComponent("databases/work/estate.sqlite").path, contents: Data("x".utf8))
        try fm.createDirectory(
            at: dir.appendingPathComponent("moot-mgr"), withIntermediateDirectories: true)

        let recorder = MoveRecorder()
        try DataRetention.applyReplace(estateFiles: estateFiles, configurationDirectory: dir) { url in
            recorder.record(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }
        let moved = recorder.moved
        #expect(Set(moved) == Set(present + ["moot-mgr"]), "every present estate file and the mgr store move; absent files are skipped")
        #expect(fm.fileExists(atPath: estateDir.path), "the estate directory stays for the first serve")
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("databases/work/estate.sqlite").path),
                "other estates are untouched by replace")
    }

    @Test("applyReuse resets only the mgr store")
    func applyReuseScope() throws {
        let dir = try makeDataDir("reuse")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let db = dir.appendingPathComponent("databases/default/estate.sqlite")
        try fm.createDirectory(at: db.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: db.path, contents: Data("x".utf8))
        try fm.createDirectory(
            at: dir.appendingPathComponent("moot-mgr"), withIntermediateDirectories: true)

        let recorder = MoveRecorder()
        try DataRetention.applyReuse(configurationDirectory: dir) { url in
            recorder.record(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }
        #expect(recorder.moved == ["moot-mgr"], "reuse must move ONLY the mgr store")
        #expect(fm.fileExists(atPath: db.path), "the adopted estate must stay in place")
    }
}
