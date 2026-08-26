// EstateEncryption.swift
//
// The plaintext-to-encrypted estate conversion. Standalone library, shared by
// the product (`mootx01 upgrade`) and the benchmark harness.
//
//   EVERY FAILURE PATH LEAVES A WORKING ESTATE AT THE CANONICAL PATH.
//
// That invariant is the reason every function below is shaped as it is.
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
//
// PORT PARITY. `rust/src/lib.rs` is the twin. Same names, same types, same
// field sets, same failure semantics, same order of operations. When one port
// changes, the other changes in the same commit.
//
//
// PORT MAPPING. Where the two ports spell one thing differently, it is a
// language idiom and not a divergence:
//
//   Swift                         Rust
//   EstateEncryptionMigrator      the crate module itself
//   throws / Error                MigrationResult<T> / MigrationError
//   init + static let none        DaemonControl::new + DaemonControl::none
//   static var defaultTrash       fn default_trash()
//   systemTrash (macOS only)      no equivalent; retainOriginal is the default
//
// Everything else is name-for-name and field-for-field.
//
// PLATFORM. Only the system Trash seam is macOS-only; everything else builds
// everywhere. The previous version gated the entire file on macOS, which is
// what left the Rust port carrying a separate implementation.

import Foundation
import SQLCipher

public enum EstateEncryptionMigrator {

    // MARK: - Plaintext vs ciphertext detection

    /// What a file at a given path is.
    public enum EstateFileState: Equatable, Sendable {
        /// No file at that path. A first run: the caller provisions a key and
        /// creates an encrypted estate.
        case absent
        /// A readable plaintext SQLite database. Must keep opening as plaintext;
        /// migration is user-initiated through `mootx01 upgrade`.
        case plaintext
        /// Not a plaintext SQLite database. For an existing estate this means
        /// SQLCipher, whose page 1 — including the header — is encrypted.
        case ciphertext
    }

    /// The plaintext SQLite file magic: ASCII "SQLite format 3" plus the
    /// terminating zero byte, 16 bytes total. A SQLCipher database encrypts page
    /// 1 including this header, so its first 16 bytes are ciphertext and never
    /// match. This is the authoritative check consumed by CE-1.0.35-06 and -08.
    public static let plaintextSQLiteMagic: [UInt8] =
        Array("SQLite format 3".utf8) + [0x00]

    /// Classify the estate file at `url` by reading its first 16 bytes.
    ///
    /// Reads bytes DIRECTLY and never opens a SQLite connection. Two reasons:
    /// a connection cannot classify a file whose key the caller does not have,
    /// and opening one has side effects. Never guess by attempting an encrypted
    /// open and catching the error.
    ///
    /// This also guards a real hazard: MootBridge calls `loadOrCreateKey`
    /// unconditionally, so anything that points Mootx01-App at the CLI's
    /// plaintext estate would mint a key and then fail with SQLITE_NOTADB.
    /// Detection is what lets a caller notice the file is plaintext first.
    public static func detectEstateFileState(at url: URL) -> EstateFileState {
        // A directory at the estate path is not a plaintext database, and must
        // not be reported as one.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            return .absent
        }

        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            // The file exists but cannot be opened for reading. It is certainly
            // not a readable plaintext estate, and reporting .absent would tell
            // a caller to create one over the top of it.
            return .ciphertext
        }
        defer { try? handle.close() }

        let head: Data
        do {
            head = try handle.read(upToCount: plaintextSQLiteMagic.count) ?? Data()
        } catch {
            return .ciphertext
        }

        // A file too short to hold the magic cannot be a valid plaintext SQLite
        // database. Treated as ciphertext, never as absent, so a caller never
        // overwrites a partial file it does not understand.
        guard head.count == plaintextSQLiteMagic.count else {
            return .ciphertext
        }

        return Array(head) == plaintextSQLiteMagic ? .plaintext : .ciphertext
    }

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
        /// An install key file exists but is not the required length. Treated
        /// as tampered rather than regenerated: regenerating would orphan
        /// every database already encrypted under the real key.
        case installKeyMalformed(path: String, count: Int)
        /// The install key file could not be created or read.
        case installKeyUnavailable(path: String, detail: String)

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
            case let .installKeyMalformed(path, count):
                return "install key at \(path) is \(count) bytes, expected \(installKeyByteCount)"
            case let .installKeyUnavailable(path, detail):
                return "install key at \(path) is unavailable: \(detail)"
            }
        }
    }

    // MARK: - Install key file (harness only)

    // WHY THIS IS FENCED
    // The Rust port resolves a database key from a `db.key` file beside the
    // databases (PersistenceKit/rust/src/encryption.rs). The Swift product
    // resolves its key from the Keychain instead, and that difference is
    // deliberate on the product side. A benchmark harness needs neither: it
    // serves a database it converted moments earlier and deletes minutes
    // later, and a Keychain item per database is both an approval prompt and
    // durable residue.
    //
    // So the file-based key lives here, behind MOOTX01_HARNESS_KEYFILE, and is
    // absent from every production build. The condition is set only by the
    // harness's own build of the product binary; nothing in the shipping
    // product defines it. What the harness measures is retrieval over
    // encrypted pages, which does not depend on where the key came from.

    /// Length of an install key, matching the Rust port's `INSTALL_KEY_LEN`.
    public static let installKeyByteCount = 32

    /// Filename of the install key beside the databases it opens. Matches the
    /// Rust port's `INSTALL_KEY_FILE`.
    public static let installKeyFileName = "db.key"

    /// URL of the install key file for databases held in `directory`.
    public static func installKeyURL(inDirectory directory: URL) -> URL {
        directory.appendingPathComponent(installKeyFileName)
    }

    #if MOOTX01_HARNESS_KEYFILE
    /// Read the install key for `directory`, creating it if absent.
    ///
    /// Semantics mirror the Rust port's `load_or_create_install_key`: a file of
    /// the wrong length fails loud rather than being regenerated, and creation
    /// is atomic with owner-only permissions — `O_CREAT | O_EXCL` sets the mode
    /// in the inode before the directory entry is visible, so there is no
    /// window where the key is group- or world-readable, and a pre-planted
    /// symlink at the path is refused rather than followed.
    public static func loadOrCreateInstallKey(inDirectory directory: URL) throws -> Data {
        let url = installKeyURL(inDirectory: directory)

        if let existing = try? Data(contentsOf: url) {
            guard existing.count == installKeyByteCount else {
                throw MigrationError.installKeyMalformed(
                    path: url.path, count: existing.count)
            }
            return existing
        }

        // SystemRandomNumberGenerator is the platform CSPRNG, which is what
        // this needs; the key never leaves the harness's own scratch directory.
        let key = Data((0..<installKeyByteCount).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max)
        })
        try writeInstallKey(key, inDirectory: directory)
        return key
    }

    /// Write `key` as the install key for `directory`, replacing any existing
    /// one.
    ///
    /// Replacing is required, not incidental: the harness converts a database
    /// with a key it chose and then hands that same key to the server, so a
    /// file left by an earlier cell must not win. Creation is still atomic and
    /// owner-only — the old file is unlinked first so `O_EXCL` holds.
    public static func writeInstallKey(_ key: Data, inDirectory directory: URL) throws {
        let url = installKeyURL(inDirectory: directory)
        guard key.count == installKeyByteCount else {
            throw MigrationError.installKeyMalformed(path: url.path, count: key.count)
        }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            throw MigrationError.installKeyUnavailable(path: url.path, detail: "\(error)")
        }
        try? FileManager.default.removeItem(at: url)

        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw MigrationError.installKeyUnavailable(
                path: url.path, detail: "open: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        let written = key.withUnsafeBytes { write(fd, $0.baseAddress, key.count) }
        guard written == key.count else {
            throw MigrationError.installKeyUnavailable(
                path: url.path, detail: "short write (\(written) bytes)")
        }
    }
    #endif

    // MARK: - Raw-connection helpers

    /// Lowercase hex of the raw 32-byte estate key, for `KEY "x'<hex>'"`.
    /// Never log or embed the result in errors.
    public static func keyHex(_ key: Data) -> String {
        key.map { String(format: "%02x", $0) }.joined()
    }

    /// Escape a path for embedding in a single-quoted SQL string literal.
    public static func sqlQuoted(_ path: String) -> String {
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
    public static func openRaw(path: String, keyHex: String? = nil) throws -> OpaquePointer {
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
    public static func exec(_ db: OpaquePointer, sql: String, step: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let detail = errMsg.map { String(cString: $0) } ?? "unknown sqlite error"
            if let errMsg { sqlite3_free(errMsg) }
            throw MigrationError.sqlite(step: step, detail: detail)
        }
    }

    /// Remove a database file and its `-wal`/`-shm` siblings, best-effort.
    public static func removeDatabase(at url: URL) {
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

        /// The launchd seam lives with the app, which owns LaunchAgent:
        /// `MootInstallerCore` extends this type with `launchd(homeDirectory:)`.

        /// A no-daemon environment (also the test default).
        public static let none = DaemonControl(
            isRunning: { false }, stop: { true }, start: { true })
    }

    /// Trash seam. Production is `FileManager.trashItem`; tests inject a
    /// recorder or a fault thrower. Returns the item's new URL in the Trash.
    public typealias TrashItem = @Sendable (URL) throws -> URL

    /// The production trash seam. `FileManager.trashItem` is macOS-only, so
    /// this is the single platform-gated member of the library.
    #if os(macOS)
        public static func systemTrash(_ url: URL) throws -> URL {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return (resulting as URL?) ?? url
        }
    #endif

    /// Retains the original beside the estate instead of trashing it, and
    /// reports where it stayed. This is the default where no system Trash
    /// exists, and it is the behaviour the Rust port has always had.
    public static func retainOriginal(_ url: URL) throws -> URL { url }

    /// The trash seam used when a caller does not supply one: the system
    /// Trash on macOS, retention elsewhere. `SwapOutcome` records which
    /// happened, so a caller never has to infer it from the platform.
    public static var defaultTrash: TrashItem {
        #if os(macOS)
            return systemTrash
        #else
            return retainOriginal
        #endif
    }

    /// What the swap did, reported exactly. `untrashedOriginalPath` is
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
        trash: TrashItem = defaultTrash
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
        trash: TrashItem = defaultTrash
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

    /// Every non-table schema object (index, trigger, view) by name.
    ///
    /// Row counts cannot see these. An index dropped by a conversion preserves
    /// every row, passes an integrity check, and passes a table-by-table count
    /// comparison — and changes retrieval, because the planner no longer has
    /// the index. `sqlcipher_export()` copies indexes and triggers, so this
    /// comparison is expected to hold; it is here because the failure it
    /// catches is silent in every other check.
    public static func schemaObjects(atPath path: String, keyHex: String? = nil) throws -> [String] {
        let db = try openRaw(path: path, keyHex: keyHex)
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT type || ':' || name FROM sqlite_master "
            + "WHERE type IN ('index','trigger','view') AND name NOT LIKE 'sqlite_%' "
            + "ORDER BY type, name;",
            -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw MigrationError.sqlite(
                step: "list schema objects", detail: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { names.append(String(cString: c)) }
        }
        return names
    }

    /// Every user table (name → TOTAL row count) of the database at `path`,
    /// enumerated from `sqlite_master`. Enumerated, not listed: a gate built
    /// on a fixed table list goes silently incomplete the day the schema
    /// grows a table (audit history, diary, erasure ledger…), and an
    /// unfaithful copy could then pass by preserving only the listed four.
    public static func allTableCounts(atPath path: String, keyHex: String? = nil) throws -> [String: Int] {
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
    public static func assertIntegrity(atPath path: String, keyHex: String? = nil) throws {
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
    public static func countRows(_ db: OpaquePointer, table: String) throws -> Int {
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
            // Indexes and triggers first: a dropped index is invisible to every
            // row-count comparison below it.
            let sourceSchema = try schemaObjects(atPath: original.path)
            let copySchema = try schemaObjects(atPath: encryptedCopy.path, keyHex: keyHex(key))
            guard sourceSchema == copySchema else {
                let missing = Set(sourceSchema).subtracting(copySchema).sorted()
                let extra = Set(copySchema).subtracting(sourceSchema).sorted()
                throw MigrationError.verificationFailed(
                    source: "\(sourceSchema.count) schema objects"
                        + (missing.isEmpty ? "" : "; missing from copy: " + missing.joined(separator: " ")),
                    copy: "\(copySchema.count) schema objects"
                        + (extra.isEmpty ? "" : "; not in source: " + extra.joined(separator: " ")))
            }
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
    public static func tableCountsDescription(
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
        guard detectEstateFileState(at: source) == .plaintext else {
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
