// EstateEncryptionMigrator.swift
//
// CE-1.0.35-08: the machinery behind `mootx01 upgrade`'s offer to encrypt a
// plaintext default estate. This is the highest-risk surface in the 1.0.35
// set — a bug here costs someone their memories — so the design invariant is
// stated once, here, and every function below serves it:
//
//   EVERY FAILURE PATH LEAVES A WORKING ESTATE AT THE CANONICAL PATH.
//
// The clone is PHYSICAL, via SQLCipher's sqlcipher_export() over an ATTACHed
// encrypted database — never a logical re-import through the capture seam. A
// logical clone would mint new row ids and lose trace rows, fingerprints, and
// the Merkle rollup, and would force a full re-encode. sqlcipher_export()
// copies every table, index, and trigger byte-for-byte at the row level, so
// the encrypted copy is the same estate, not a re-telling of it.
//
// This file talks to the raw sqlite3 C API (vendored SQLCipher amalgamation)
// on purpose: PersistenceKitSQLite's connection type is internal, and the
// migration needs ATTACH/DETACH and count queries on files it must never
// route through the substrate's open path (which has side effects like WAL
// conversion and permission stamping). The amalgamation registers
// sqlcipher_export() as an auto-extension, so it is available on every
// connection with no manual registration.

import Foundation
import SQLCipher

#if os(macOS)

public enum EstateEncryptionMigrator {

    // MARK: - Errors

    /// Why a migration step refused or failed. Messages never carry key
    /// material: the ATTACH statement embeds the key hex, so raw SQL is
    /// deliberately excluded from every error path.
    public enum MigrationError: Error, CustomStringConvertible, Equatable {
        /// The source file is not a readable plaintext SQLite database.
        /// Migrating anything else is refused outright.
        case sourceNotPlaintext(path: String)
        /// A sqlite3 call failed. `step` names the operation, not the SQL.
        case sqlite(step: String, detail: String)
        /// The encrypted copy's row counts did not match the original's.
        /// The copy has been deleted; the original is untouched.
        case verificationFailed(source: String, copy: String)
        /// The swap could not complete. The plaintext original is back at
        /// (or never left) the canonical path.
        case swapFailed(detail: String)

        public var description: String {
            switch self {
            case let .sourceNotPlaintext(path):
                return "refusing to migrate \(path): it is not a readable plaintext SQLite database"
            case let .sqlite(step, detail):
                return "estate encryption \(step) failed: \(detail)"
            case let .verificationFailed(source, copy):
                return """
                    the encrypted copy does not match the original and has been \
                    deleted; the original estate is untouched. original: \(source) \
                    copy: \(copy)
                    """
            case let .swapFailed(detail):
                return "estate swap failed — the original plaintext estate is still in place: \(detail)"
            }
        }
    }

    // MARK: - Raw-connection helpers

    /// Lowercase hex of the raw 32-byte estate key, for `KEY "x'<hex>'"`.
    /// Never log or embed the result in errors.
    static func keyHex(_ key: Data) -> String {
        key.map { String(format: "%02x", $0) }.joined()
    }

    /// Escape a path for embedding in a single-quoted SQL string literal.
    static func sqlQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// Open a raw sqlite3 connection.
    ///
    /// CREATE is included because ATTACHed databases inherit the main
    /// connection's open flags, and the export's ATTACH must be able to
    /// create the encrypted destination. The hazard CREATE would normally
    /// carry — silently minting an empty database over a missing estate —
    /// is closed by the caller: every migration entry point classifies the
    /// source with `detectEstateFileState` first and refuses anything that
    /// is not an existing readable plaintext database.
    static func openRaw(path: String, keyHex: String? = nil) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(
            path, &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let db = handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed (rc \(rc))"
            sqlite3_close(handle)
            throw MigrationError.sqlite(step: "open", detail: detail)
        }
        if let keyHex {
            // Keyed exactly like SQLiteConnection: raw 32 bytes as the cipher
            // key, no passphrase KDF. Executed without embedding the SQL in
            // any error so key hex never leaks.
            if sqlite3_exec(db, "PRAGMA key = \"x'\(keyHex)'\";", nil, nil, nil) != SQLITE_OK {
                let detail = String(cString: sqlite3_errmsg(db))
                sqlite3_close_v2(db)
                throw MigrationError.sqlite(step: "keying", detail: detail)
            }
        }
        return db
    }

    /// Run one statement, mapping failure to `MigrationError`. `step` is the
    /// human name reported on failure; the SQL itself is never reported.
    static func exec(_ db: OpaquePointer, sql: String, step: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let detail = errMsg.map { String(cString: $0) } ?? "unknown sqlite error"
            if let errMsg { sqlite3_free(errMsg) }
            throw MigrationError.sqlite(step: step, detail: detail)
        }
    }

    /// Remove a database file and its `-wal`/`-shm` siblings, best-effort.
    static func removeDatabase(at url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        for suffix in ["-wal", "-shm"] {
            try? fm.removeItem(at: url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + suffix))
        }
    }

    // MARK: - Part 4: swap seams

    /// Daemon control seam. The real implementation is launchd
    /// (`DaemonControl.launchd(homeDirectory:)`); tests inject recorders and
    /// fault throwers so every failure path is drivable without launchd.
    public struct DaemonControl: Sendable {
        public var isRunning: @Sendable () -> Bool
        public var stop: @Sendable () -> Bool
        public var start: @Sendable () -> Bool

        public init(
            isRunning: @escaping @Sendable () -> Bool,
            stop: @escaping @Sendable () -> Bool,
            start: @escaping @Sendable () -> Bool
        ) {
            self.isRunning = isRunning
            self.stop = stop
            self.start = start
        }

        /// The production seam: launchctl via LaunchAgent.
        public static func launchd(homeDirectory: URL) -> DaemonControl {
            DaemonControl(
                isRunning: { LaunchAgent.isDaemonRunning() },
                stop: { LaunchAgent.stopDaemon() },
                start: { LaunchAgent.startDaemon(homeDirectory: homeDirectory) })
        }

        /// A no-daemon environment (also the test default).
        public static let none = DaemonControl(
            isRunning: { false }, stop: { true }, start: { true })
    }

    /// Trash seam. Production is `FileManager.trashItem`; tests inject a
    /// recorder or a fault thrower. Returns the item's new URL in the Trash.
    public typealias TrashItem = @Sendable (URL) throws -> URL

    /// The production trash seam.
    public static func systemTrash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return (resulting as URL?) ?? url
    }

    /// What the swap did, for honest reporting. `untrashedOriginalPath` is
    /// non-nil when the plaintext original could NOT be moved to the Trash
    /// and is still sitting beside the estate — the caller MUST surface it.
    public struct SwapOutcome: Sendable {
        public let daemonWasRunning: Bool
        public let daemonRestarted: Bool
        public let trashedOriginalURL: URL?
        public let untrashedOriginalPath: String?
    }

    // MARK: - Part 4: atomic swap and Trash

    /// Swap the verified encrypted copy onto the canonical estate path and
    /// move the plaintext original to the Trash.
    ///
    /// FILE WORK ONLY: the caller (`migrate`) owns the daemon lifecycle and
    /// has already stopped it — before the export, so no write can land in
    /// the original after the copy was taken.
    ///
    /// Sequence, chosen so the canonical path holds a complete, openable
    /// estate at every instant — including across a crash of this process:
    ///
    ///   1. move the original's `-wal`/`-shm` siblings aside (they belong to
    ///      the plaintext file and must never sit next to the encrypted one)
    ///   2. HARD-LINK the original to an aside name — the original's bytes
    ///      now have two directory entries, so step 3 can atomically replace
    ///      the canonical entry without ever orphaning the plaintext data
    ///   3. `rename()` the encrypted copy onto the canonical path (atomic
    ///      replace; the path stays constant for the launchd plist and every
    ///      client config)
    ///   4. move the aside original (+ siblings) to the Trash
    ///
    /// A failure in 1–3 unwinds to the plaintext original at the canonical
    /// path (and deletes the copy). A trash failure is reported, not fatal:
    /// the encrypted estate is already in place and working.
    public static func swapInEncryptedCopy(
        original: URL,
        encryptedCopy: URL,
        trash: TrashItem = systemTrash
    ) throws -> (trashedOriginalURL: URL?, untrashedOriginalPath: String?) {
        let fm = FileManager.default
        let dir = original.deletingLastPathComponent()
        let asideName = original.lastPathComponent + ".pre-encryption"
        let aside = dir.appendingPathComponent(asideName)

        // Unwind helper for failures before the rename lands.
        func unwind(_ movedSiblings: [(from: URL, to: URL)], linked: Bool) {
            for pair in movedSiblings.reversed() { try? fm.moveItem(at: pair.to, to: pair.from) }
            if linked { try? fm.removeItem(at: aside) }
            removeDatabase(at: encryptedCopy)
        }

        // 1. Plaintext siblings aside. Normally absent after the export's
        //    checkpoint(TRUNCATE); moved rather than deleted so an unwind can
        //    put them back exactly as found.
        var movedSiblings: [(from: URL, to: URL)] = []
        for suffix in ["-wal", "-shm"] {
            let sibling = dir.appendingPathComponent(original.lastPathComponent + suffix)
            guard fm.fileExists(atPath: sibling.path) else { continue }
            let sidelined = dir.appendingPathComponent(asideName + suffix)
            do {
                try? fm.removeItem(at: sidelined)
                try fm.moveItem(at: sibling, to: sidelined)
                movedSiblings.append((from: sibling, to: sidelined))
            } catch {
                unwind(movedSiblings, linked: false)
                throw MigrationError.swapFailed(
                    detail: "could not set aside \(sibling.lastPathComponent): \(error)")
            }
        }

        // 3. Second directory entry for the original's bytes. After this,
        //    replacing the canonical entry cannot orphan the plaintext data.
        do {
            try? fm.removeItem(at: aside)
            try fm.linkItem(at: original, to: aside)
        } catch {
            unwind(movedSiblings, linked: false)
            throw MigrationError.swapFailed(
                detail: "could not link the original aside: \(error)")
        }

        // 4. The swap itself. POSIX rename() atomically replaces the
        //    canonical entry; FileManager.moveItem refuses existing
        //    destinations, so the syscall is used directly.
        if rename(encryptedCopy.path, original.path) != 0 {
            let err = String(cString: strerror(errno))
            unwind(movedSiblings, linked: true)
            throw MigrationError.swapFailed(
                detail: "atomic rename onto \(original.path) failed: \(err)")
        }

        // 4. Trash the plaintext original and any sidelined siblings. The
        //    trashed copy is STILL UNENCRYPTED — the caller's success message
        //    must say so, so emptying the Trash reads as the final step of
        //    the migration and not optional cleanup.
        var trashedURL: URL?
        var untrashedPath: String?
        do {
            trashedURL = try trash(aside)
            for pair in movedSiblings { _ = try? trash(pair.to) }
        } catch {
            // Keep the original in place and report its path rather than
            // proceeding silently.
            untrashedPath = aside.path
        }

        return (trashedOriginalURL: trashedURL, untrashedOriginalPath: untrashedPath)
    }

    // MARK: - The full migration

    /// End-to-end migration for a plaintext estate at `estateURL`:
    /// stop daemon → clone → verify → swap → restart → trash, with `key`
    /// already provisioned by the caller (EstateKeyProvider owns key
    /// custody; this type never touches the Keychain). Throws on any
    /// failure that left the plaintext original in place; the error says so
    /// explicitly.
    ///
    /// The daemon stops BEFORE the export (Bob's ruling: never lose data).
    /// Stopping only at swap time would leave a window where rows written
    /// after the copy was taken exist only in the original that goes to the
    /// Trash. With the daemon quiesced first, the encrypted copy is
    /// guaranteed complete relative to every write that ever committed.
    public static func migrate(
        estateURL: URL,
        key: Data,
        daemon: DaemonControl,
        trash: TrashItem = systemTrash
    ) throws -> (counts: VerificationCounts, swap: SwapOutcome) {
        let copy = estateURL.deletingLastPathComponent()
            .appendingPathComponent(estateURL.lastPathComponent + ".encrypting")
        // A stale copy from an interrupted earlier run is untrusted by
        // definition — regenerate rather than resume.
        removeDatabase(at: copy)

        // Quiesce FIRST, so nothing can write to the original once the
        // clone exists. Refusing to proceed when the daemon will not stop
        // is the safe direction: nothing has been touched yet.
        let wasRunning = daemon.isRunning()
        if wasRunning, !daemon.stop() {
            throw MigrationError.swapFailed(
                detail: "the resident daemon would not stop; nothing was changed")
        }

        do {
            try exportEncryptedCopy(from: estateURL, to: copy, key: key)
            let counts = try verifyEncryptedCopy(
                original: estateURL, encryptedCopy: copy, key: key)
            let files = try swapInEncryptedCopy(
                original: estateURL, encryptedCopy: copy, trash: trash)
            // Bring the daemon back over the encrypted estate. Failure here
            // is reported, never fatal: the migration itself has succeeded.
            let restarted = wasRunning ? daemon.start() : false
            return (counts, SwapOutcome(
                daemonWasRunning: wasRunning,
                daemonRestarted: restarted,
                trashedOriginalURL: files.trashedOriginalURL,
                untrashedOriginalPath: files.untrashedOriginalPath))
        } catch {
            // Every failure between stop and swap leaves the plaintext
            // original at the canonical path; put the daemon back over it.
            if wasRunning { _ = daemon.start() }
            throw error
        }
    }

    // MARK: - Part 3: verification counts

    /// The four row counts that gate the swap. Drawer, fact, tunnel, and
    /// recall-trace rows are what a user cannot regenerate; if any of them
    /// differs between the original and the encrypted copy, the copy is
    /// wrong and must never be swapped in.
    public struct VerificationCounts: Equatable, Sendable, CustomStringConvertible {
        public let drawers: Int
        public let kgFacts: Int
        public let tunnels: Int
        public let recallTraces: Int

        public var description: String {
            "drawers=\(drawers) kg_facts=\(kgFacts) tunnels=\(tunnels) recall_trace=\(recallTraces)"
        }
    }

    /// TOTAL row counts (including tombstoned rows) of the four gated
    /// tables. Totals, not active-only: the physical clone must preserve
    /// every row, tombstoned included, so the strictest comparable number
    /// is the right gate.
    ///
    /// Table names are the substrate schema's (LocusKitSchema.swift):
    /// `drawers`, `kg_facts`, `tunnels`, `recall_trace`.
    public static func verificationCounts(atPath path: String, keyHex: String? = nil) throws -> VerificationCounts {
        let db = try openRaw(path: path, keyHex: keyHex)
        defer { sqlite3_close_v2(db) }
        return VerificationCounts(
            drawers: try countRows(db, table: "drawers"),
            kgFacts: try countRows(db, table: "kg_facts"),
            tunnels: try countRows(db, table: "tunnels"),
            recallTraces: try countRows(db, table: "recall_trace"))
    }

    /// Every user table (name → TOTAL row count) of the database at `path`,
    /// enumerated from `sqlite_master`. Enumerated, not listed: a gate built
    /// on a fixed table list goes silently incomplete the day the schema
    /// grows a table (audit history, diary, erasure ledger…), and an
    /// unfaithful copy could then pass by preserving only the listed four.
    static func allTableCounts(atPath path: String, keyHex: String? = nil) throws -> [String: Int] {
        let db = try openRaw(path: path, keyHex: keyHex)
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name;",
            -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw MigrationError.sqlite(
                step: "list tables", detail: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                names.append(String(cString: c))
            }
        }
        var counts: [String: Int] = [:]
        for table in names {
            counts[table] = try countRows(db, table: table)
        }
        return counts
    }

    /// `PRAGMA integrity_check` on the database at `path`. Throws unless the
    /// result is exactly the single row "ok". Structural soundness is a
    /// precondition the row-count gate cannot see: counts read intact B-tree
    /// paths and say nothing about corruption elsewhere in a page.
    static func assertIntegrity(atPath path: String, keyHex: String? = nil) throws {
        let db = try openRaw(path: path, keyHex: keyHex)
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            throw MigrationError.sqlite(
                step: "integrity_check", detail: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var findings: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                findings.append(String(cString: c))
            }
        }
        guard findings == ["ok"] else {
            throw MigrationError.sqlite(
                step: "integrity_check",
                detail: findings.isEmpty ? "no result rows" : findings.joined(separator: "; "))
        }
    }

    /// `SELECT COUNT(*)` on one table. A missing table (or a wrong key,
    /// which makes page 1 undecodable) surfaces as a thrown error, never
    /// as zero — a fabricated zero could make a truncated copy "match" an
    /// empty table.
    static func countRows(_ db: OpaquePointer, table: String) throws -> Int {
        var stmt: OpaquePointer?
        // Table names come from the fixed list above, never from input.
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \"\(table)\";", -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            throw MigrationError.sqlite(
                step: "count \(table)", detail: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw MigrationError.sqlite(
                step: "count \(table)", detail: String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Part 3's gate: compare the plaintext original against the encrypted
    /// copy. Throws `.verificationFailed` (after deleting the copy) on any
    /// difference — the original is never touched by this function.
    ///
    /// The gate is three layers, strongest first (hardened per Codex 06fa2bc2
    /// once the swap became live: this comparison is now the only thing
    /// standing between an unfaithful copy and the plaintext original going
    /// to the Trash):
    ///   1. `PRAGMA integrity_check` on the encrypted copy — structural
    ///      soundness of every page, which row counts cannot see.
    ///   2. Schema-complete comparison — every user table in either database
    ///      by name, TOTAL rows each. Catches dropped tables, gained tables,
    ///      and row loss anywhere in the estate (audit history, diary,
    ///      erasure ledger, snapshots), not just the four headline tables.
    ///   3. The four headline counts, returned for display and logging.
    public static func verifyEncryptedCopy(
        original: URL, encryptedCopy: URL, key: Data
    ) throws -> VerificationCounts {
        do {
            try assertIntegrity(atPath: encryptedCopy.path, keyHex: keyHex(key))
            let sourceTables = try allTableCounts(atPath: original.path)
            let copyTables = try allTableCounts(atPath: encryptedCopy.path, keyHex: keyHex(key))
            guard sourceTables == copyTables else {
                throw MigrationError.verificationFailed(
                    source: tableCountsDescription(sourceTables, versus: copyTables),
                    copy: tableCountsDescription(copyTables, versus: sourceTables))
            }
        } catch {
            // Any failed layer condemns the copy: never leave a ciphertext
            // file that failed verification where a retry could adopt it.
            removeDatabase(at: encryptedCopy)
            throw error
        }
        let source = try verificationCounts(atPath: original.path)
        let copy = try verificationCounts(atPath: encryptedCopy.path, keyHex: keyHex(key))
        guard source == copy else {
            removeDatabase(at: encryptedCopy)
            throw MigrationError.verificationFailed(
                source: "\(source)", copy: "\(copy)")
        }
        return copy
    }

    /// One side of a failed table-complete comparison, with the tables that
    /// differ from `other` singled out so the error names the divergence
    /// instead of dumping two full maps.
    static func tableCountsDescription(
        _ counts: [String: Int], versus other: [String: Int]
    ) -> String {
        let differing = counts
            .filter { other[$0.key] != $0.value }
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        let missing = other.keys
            .filter { counts[$0] == nil }
            .sorted()
            .map { "\($0)=absent" }
        let parts = differing + missing
        return parts.isEmpty
            ? "\(counts.count) tables, all matching"
            : "\(counts.count) tables; differing: " + parts.joined(separator: " ")
    }

    // MARK: - Part 2: the clone

    /// Clone the plaintext estate at `source` into a NEW encrypted database
    /// at `destination`, keyed with `key`, via `sqlcipher_export()`.
    ///
    /// The destination must not exist yet; it is created by the ATTACH and
    /// removed again (with siblings) on any failure, so a failed export
    /// leaves no partial ciphertext behind. The source is opened read-write
    /// (sqlite requires it for the WAL checkpoint) but its content is never
    /// modified.
    public static func exportEncryptedCopy(from source: URL, to destination: URL, key: Data) throws {
        // Refuse anything that is not a readable plaintext database. The
        // caller already checked; check again here because this function is
        // public and the cost of migrating garbage is unbounded.
        guard EstateKeyProvider.detectEstateFileState(at: source) == .plaintext else {
            throw MigrationError.sourceNotPlaintext(path: source.path)
        }

        let db = try openRaw(path: source.path)
        defer { sqlite3_close_v2(db) }

        do {
            // Fold the WAL into the main file first so the plaintext original
            // that later goes to the Trash is self-contained, and so no
            // sibling files carry rows the main file lacks.
            try exec(db, sql: "PRAGMA wal_checkpoint(TRUNCATE);", step: "checkpoint")
            // ATTACH creates the encrypted destination; sqlcipher_export
            // copies every table, index, and trigger into it row-by-row.
            try exec(
                db,
                sql: "ATTACH \(sqlQuoted(destination.path)) AS encrypted KEY \"x'\(keyHex(key))'\";",
                step: "attach")
            try exec(db, sql: "SELECT sqlcipher_export('encrypted');", step: "export")
            try exec(db, sql: "DETACH encrypted;", step: "detach")
        } catch {
            // No partial ciphertext may outlive a failed export.
            removeDatabase(at: destination)
            throw error
        }
    }
}

#endif
