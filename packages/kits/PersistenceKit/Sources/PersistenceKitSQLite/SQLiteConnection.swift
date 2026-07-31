// SQLiteConnection.swift
//
// Thin Swift wrapper around the C sqlite3 API. Per-estate single
// connection (SQLite WAL mode handles multi-reader concurrency).

import Foundation
import OSLog
import SubstrateTypes
import SQLCipher
import PersistenceKit
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────

final class SQLiteConnection: @unchecked Sendable {
    var handle: OpaquePointer?
    let url: URL
    let busyTimeout: TimeInterval

    init(url: URL, busyTimeout: TimeInterval, keyHex: String? = nil) throws {
        self.url = url
        self.busyTimeout = busyTimeout
        // Ensure parent directory exists.
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        // CAND-052: Symlink refusal — reject a pre-planted symlink at the DB path.
        //
        // A symlink at the database location can redirect SQLite writes to an
        // arbitrary file (e.g. /etc/passwd or another estate's SQLite). Refuse
        // before opening. `resourceValues(forKeys:)` uses `lstat` semantics
        // when asked for `isSymbolicLink` — it does NOT follow the symlink,
        // so it correctly identifies the symlink itself rather than its target.
        // Non-existent paths return `.resourceNotFound` or a missing key; both
        // are safe to ignore (new-file creation path).
        //
        // Apple Data Protection (applied below after open) covers the DB file
        // and its WAL sidecars at rest under the Secure Enclave key. This guard
        // addresses the symlink-redirection attack surface (CAND-052), which is
        // orthogonal to at-rest encryption.
        if let attrs = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
           attrs.isSymbolicLink == true {
            throw StorageError.backendError(
                underlying: "sqlite open: refusing to open \(url.lastPathComponent) " +
                            "— path is a symbolic link. Pre-planted symlinks are a " +
                            "security risk (CAND-052)."
            )
        }

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw StorageError.backendError(underlying: "sqlite open: \(msg)")
        }

        // Whole-database at-rest encryption (Mode 3 / FullDatabase): supply the
        // estate key before any other access so SQLCipher can decrypt page 1
        // (the schema) and every content page. This MUST be the first statement
        // on the connection. With no key (modes 1/2) it is skipped and the file
        // is a normal unencrypted SQLite database. `PRAGMA key = "x'<hex>'"` uses
        // the 32 raw bytes directly as the cipher key (no passphrase KDF — the
        // key is already full-entropy). Mirrors the Rust SqliteStorage chokepoint.
        if let keyHex {
            // Execute the key PRAGMA directly instead of through exec() so
            // that a failure does not leak the hex key material in the error
            // message (exec interpolates the SQL into StorageError).
            let keySql = "PRAGMA key = \"x'\(keyHex)'\";"
            var keyErrMsg: UnsafeMutablePointer<CChar>? = nil
            let keyRc = sqlite3_exec(handle, keySql, nil, nil, &keyErrMsg)
            if keyRc != SQLITE_OK {
                let msg = keyErrMsg.map { String(cString: $0) } ?? "key pragma failed"
                if let keyErrMsg { sqlite3_free(keyErrMsg) }
                throw StorageError.backendError(underlying: "PRAGMA key failed: \(msg)")
            }
        }

        // Apple Data Protection: the OS stores the estate encrypted at rest
        // under a Secure Enclave-derived key (the device passcode is the root
        // secret). This layers Apple-native Data Protection on top of the
        // SQLCipher whole-file key applied above (when keyHex is set); the
        // Rust port uses SQLCipher only. We bypass Core Data per PERSISTENCEKIT_SPEC
        // invariant I-2, so we set directly the protection class Core Data would
        // otherwise request via NSPersistentStoreFileProtectionKey.
        Self.applyDataProtection(to: url)

        // Lock database files to owner-only (0600). The default SQLite
        // creation mode is 0644 (world-readable), which lets any process read
        // the file with sqlite3. 0600 blocks other users; for same-user AI
        // agent subprocesses, the instruction-file prohibition ("NEVER touch
        // the database directly") is the primary defense, and SQLCipher
        // (Mode 3) makes raw reads return ciphertext. The permissions cover
        // the main DB, WAL, and SHM files.
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: path)
        }

        // WAL mode and busy timeout.
        // Durability pragmas per SQLiteDurabilityTail (cookbook § 4.3.3):
        // WAL for crash-safe concurrent reads, NORMAL fsync,
        // wal_autocheckpoint truncates the WAL every 1000 frames.
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = NORMAL;")
        try exec("PRAGMA wal_autocheckpoint = 1000;")
        try exec("PRAGMA busy_timeout = \(Int(busyTimeout * 1000));")
        try exec("PRAGMA foreign_keys = ON;")
        // memory-map the database file so SQLite reads go through
        // the OS page cache instead of malloc'd copies. This is the single
        // change that eliminates multi-GB heap allocations for vector BLOBs
        // and BM25 term-frequency reads — the OS manages which pages are
        // resident in physical RAM based on actual access patterns. 2GB
        // mmap window covers any realistic estate size; pages beyond the
        // window fall back to normal read() I/O. Compatible with WAL mode
        // and SQLCipher (mmap applies after decryption).
        try exec("PRAGMA mmap_size = 2147483648;")

        // Restore SQLITE_LIMIT_LENGTH to the compile-time maximum (INT_MAX as the
        // new-val is silently clamped to SQLITE_MAX_LENGTH = 1,000,000,000 by the
        // SQLite engine). This call is defensive: it ensures no earlier
        // sqlite3_limit call on this handle has accidentally lowered the per-connection
        // limit below the compile-time default (MXE-BB / ee#49). In the normal case
        // where no prior call lowered the limit, this is a harmless no-op.
        // The real fix for the 1 GB ceiling is chunked basis persistence (Parts 1+2).
        // sqlite3_limit returns the previous value; discarded intentionally.
        _ = sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 0x7fffffff)
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    func close() {
        // Destroy cached statements BEFORE closing: sqlite3_close_v2 defers the
        // real close while statements remain, leaving a zombie connection.
        for (_, stmt) in statementCache { stmt.destroy() }
        statementCache.removeAll()
        if let handle {
            sqlite3_close_v2(handle)
        }
        handle = nil
    }

    /// Best-effort application of Apple Data Protection to the database file.
    ///
    /// Sets `completeUntilFirstUserAuthentication`: the OS stores the file
    /// encrypted at rest under a Secure Enclave-derived key, while keeping it
    /// accessible to the resident/background process after the first device
    /// unlock (so background work — dreaming, sync — is not locked out). Failure
    /// is non-fatal: on a volume or platform without Data Protection support
    /// (for example a development Mac running `swift test` without the
    /// `com.apple.developer.default-data-protection` entitlement) the attribute
    /// is simply not enforced. The shipping app's entitlement default is what
    /// makes the OS honor protection for this file and for the `-wal`/`-shm`
    /// sidecars SQLite creates on first write (they inherit the app's default
    /// protection class).
    private static func applyDataProtection(to url: URL) {
        let attributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }

    // MARK: - Direct exec

    func exec(_ sql: String) throws {
        guard let handle else { throw StorageError.backendError(underlying: "connection closed") }
        var errMsg: UnsafeMutablePointer<CChar>? = nil
        let rc = sqlite3_exec(handle, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "exec failed"
            if let errMsg { sqlite3_free(errMsg) }
            throw StorageError.backendError(underlying: "exec(\(sql)): \(msg)")
        }
    }

    // MARK: - Prepared statements

    /// Per-connection statement cache keyed by SQL text (best-practices §5:
    /// prepared statements reused via the kit). The SQL for a given (table,
    /// column-set / predicate-shape) is identical across a bulk loop, so parsing
    /// per call (sqlite3_prepare_v2 → parser) was a measured hot spot on 50k-row
    /// imports. Bounded: at capacity the whole cache is destroyed and rebuilt —
    /// crude but O(1) amortized, and the estate schema's statement variety
    /// (~a few per table) sits far below the cap in practice. Mirrors the Rust
    /// port's rusqlite prepare_cached (capacity 128).
    private var statementCache: [String: SQLiteStatement] = [:]
    private static let statementCacheCapacity = 128

    func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let handle else { throw StorageError.backendError(underlying: "connection closed") }
        var stmt: OpaquePointer? = nil
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(handle))
            sqlite3_finalize(stmt)
            throw StorageError.backendError(underlying: "prepare(\(sql)): \(msg)")
        }
        return SQLiteStatement(stmt: stmt, connection: self)
    }

    /// Cached twin of `prepare`. Returns a reusable statement for `sql`,
    /// reset + bindings cleared, parsing it only on first use. The returned
    /// statement's `finalize()` RETURNS it to the cache (reset) instead of
    /// destroying it, so existing `defer { stmt.finalize() }` call sites work
    /// unchanged. Never hold a cached statement across an await/suspension —
    /// the storage actor serializes callers, so per-call scope is safe.
    func prepareCached(_ sql: String) throws -> SQLiteStatement {
        // CHECKOUT semantics (mirrors rusqlite): the statement is REMOVED from
        // the cache while in use and returned by its finalize(). A reentrant
        // call with the same SQL therefore misses the (empty) slot and prepares
        // a fresh statement rather than clobbering the in-flight one mid-step.
        if let cached = statementCache.removeValue(forKey: sql), cached.stmt != nil {
            cached.resetForReuse()
            return cached
        }
        let stmt = try prepare(sql)
        stmt.isCached = true
        stmt.cacheKey = sql
        return stmt
    }

    /// Return a checked-out cached statement to the cache (called by the
    /// statement's `finalize()`). At capacity the whole cache is destroyed and
    /// rebuilt — crude but O(1) amortized; the estate schema's statement variety
    /// sits far below the cap. A same-key statement already back in the slot
    /// (reentrant duplicate) destroys the returner instead.
    func returnToCache(_ stmt: SQLiteStatement) {
        guard let key = stmt.cacheKey, stmt.stmt != nil else { return }
        if statementCache[key] != nil {
            stmt.destroy()
            return
        }
        if statementCache.count >= Self.statementCacheCapacity {
            for (_, s) in statementCache { s.destroy() }
            statementCache.removeAll()
        }
        stmt.resetForReuse()
        statementCache[key] = stmt
    }

    var lastErrorMessage: String {
        guard let handle else { return "(closed)" }
        return String(cString: sqlite3_errmsg(handle))
    }
}

final class SQLiteStatement {
    var stmt: OpaquePointer?
    weak var connection: SQLiteConnection?
    /// True when this statement belongs to the connection's statement cache.
    /// `finalize()` on a cached statement RETURNS it to the cache (reset for
    /// reuse) instead of destroying it, so call sites keep their
    /// `defer { stmt.finalize() }` shape whether the statement came from
    /// `prepare` or `prepareCached`.
    var isCached = false
    /// The cache key (the SQL text) for a cached statement — used by
    /// `SQLiteConnection.returnToCache` on finalize.
    var cacheKey: String?

    init(stmt: OpaquePointer, connection: SQLiteConnection) {
        self.stmt = stmt
        self.connection = connection
    }

    deinit { if let stmt { sqlite3_finalize(stmt) } }

    func finalize() {
        if isCached {
            // Return to the cache (or destroy if the connection is gone).
            if let connection {
                connection.returnToCache(self)
            } else {
                destroy()
            }
            return
        }
        if let stmt { sqlite3_finalize(stmt) }
        stmt = nil
    }

    /// Reset execution state + clear bindings so the compiled statement can be
    /// re-executed with fresh binds (the cache-reuse path).
    func resetForReuse() {
        guard let stmt else { return }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    /// Destroy the underlying sqlite3_stmt unconditionally — used by the cache
    /// on eviction and at connection close (a cached statement's `finalize()`
    /// deliberately does not destroy).
    func destroy() {
        if let stmt { sqlite3_finalize(stmt) }
        stmt = nil
    }

    // MARK: - Bind

    func bind(_ value: TypedValue, at index: Int32) throws {
        guard let stmt else { throw StorageError.backendError(underlying: "stmt finalized") }
        switch value {
        case .null:
            sqlite3_bind_null(stmt, index)
        case .bool(let b):
            sqlite3_bind_int64(stmt, index, b ? 1 : 0)
        case .int(let i):
            sqlite3_bind_int64(stmt, index, sqlite3_int64(i))
        case .bitmap(let i):
            sqlite3_bind_int64(stmt, index, sqlite3_int64(i))
        case .float(let d):
            sqlite3_bind_double(stmt, index, d)
        case .text(let s):
            sqlite3_bind_text(stmt, index, s, -1, SQLITE_TRANSIENT)
        case .blob(let data):
            try data.withUnsafeBytes { buf in
                let rc = sqlite3_bind_blob(stmt, index, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT)
                if rc != SQLITE_OK { throw StorageError.backendError(underlying: "bind blob") }
            }
        case .uuid(let u):
            sqlite3_bind_text(stmt, index, u.uuidString, -1, SQLITE_TRANSIENT)
        case .timestamp(let d):
            let iso = ISO8601.string(from: d)
            sqlite3_bind_text(stmt, index, iso, -1, SQLITE_TRANSIENT)
        case .json(let data):
            try data.withUnsafeBytes { buf in
                let rc = sqlite3_bind_blob(stmt, index, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT)
                if rc != SQLITE_OK { throw StorageError.backendError(underlying: "bind json") }
            }
        case .hlc(let hlc):
            // Int64(bitPattern:) preserves the bit pattern when the
            // node byte sets the top bit (e.g. nodeID -1 → 0xFF <<
            // 56). The bare Int64() traps with "Not enough bits".
            // The read side already uses UInt64(bitPattern:) (line
            // 792 of SQLiteStorage.swift) — this keeps write/read
            // symmetric.
            sqlite3_bind_int64(stmt, index, Int64(bitPattern: hlc.packed))
        case .fingerprint(let fp):
            // Store as 32-byte blob, big-endian for stability.
            var data = Data(capacity: 32)
            for block in [fp.block0, fp.block1, fp.block2, fp.block3] {
                var be = block.bigEndian
                data.append(Data(bytes: &be, count: 8))
            }
            try data.withUnsafeBytes { buf in
                let rc = sqlite3_bind_blob(stmt, index, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT)
                if rc != SQLITE_OK { throw StorageError.backendError(underlying: "bind fingerprint") }
            }
        case .array(let values):
            // Serialize as JSON array.
            let encoded = try JSONEncoder().encode(values.map { JSONTypedValue($0) })
            try encoded.withUnsafeBytes { buf in
                let rc = sqlite3_bind_blob(stmt, index, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT)
                if rc != SQLITE_OK { throw StorageError.backendError(underlying: "bind array") }
            }
        }
    }

    func step() throws -> Bool {
        guard let stmt else { throw StorageError.backendError(underlying: "stmt finalized") }
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        let msg = connection?.lastErrorMessage ?? "step failed"
        throw StorageError.backendError(underlying: "step: \(msg)")
    }

    // MARK: - Column readers

    func columnCount() -> Int32 {
        guard let stmt else { return 0 }
        return sqlite3_column_count(stmt)
    }

    func columnName(_ index: Int32) -> String {
        guard let stmt, let p = sqlite3_column_name(stmt, index) else { return "" }
        return String(cString: p)
    }

    func columnType(_ index: Int32) -> Int32 {
        guard let stmt else { return SQLITE_NULL }
        return sqlite3_column_type(stmt, index)
    }

    func columnInt64(_ index: Int32) -> Int64 {
        guard let stmt else { return 0 }
        return Int64(sqlite3_column_int64(stmt, index))
    }

    func columnDouble(_ index: Int32) -> Double {
        guard let stmt else { return 0 }
        return sqlite3_column_double(stmt, index)
    }

    func columnText(_ index: Int32) -> String? {
        guard let stmt, let p = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: p)
    }

    func columnBlob(_ index: Int32) -> Data? {
        guard let stmt else { return nil }
        // sqlite3_column_type SQLITE_NULL means the column IS NULL (key absent).
        // An empty blob (zero bytes) has type SQLITE_BLOB with count 0 — return
        // Data() rather than nil so callers can distinguish "absent" from "empty".
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        let bytes = sqlite3_column_blob(stmt, index)
        let count = sqlite3_column_bytes(stmt, index)
        guard count > 0, let bytes else { return Data() }
        return Data(bytes: bytes, count: Int(count))
    }
}

// SQLITE_TRANSIENT tells sqlite to copy the data before returning.
let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

// Internal so sibling files in PersistenceKitSQLite (e.g. SQLiteStorage.swift)
// can share the same logger without a second OSLog allocation.
let sqliteConnectionLog = Logger(subsystem: "com.mootx01.kit", category: "SQLiteConnection")

// ─────────────────────────────────────────────────────────────────
// Write-boundary clamp constants — mirrors Rust iso8601() in sqlite.rs.
//
// ISO8601DateFormatter (the read side) only accepts four-digit years
// (0001–9999). An extreme Date — e.g. from a millisecond epoch that
// was accidentally treated as seconds, or a bad Vault frontmatter
// `created` field — can cause formatterWithFraction.string(from:) to
// produce "+59009-..." which formatterWithFraction.date(from:) cannot
// parse back. To prevent this, Date values are clamped to the
// RFC-3339-parseable range before formatting. The clamped value is
// wrong-but-readable; the warning log is the signal to fix the upstream.
//
// Seconds since 1970-01-01T00:00:00Z:
//   MIN_ROUND_TRIP_SECS = 0001-01-01T00:00:00Z (−62135596800)
//   MAX_ROUND_TRIP_SECS = 9999-12-31T23:59:59Z (+253402300799)
// ─────────────────────────────────────────────────────────────────
private let kMinRoundTripSecs: TimeInterval = -62_135_596_800
private let kMaxRoundTripSecs: TimeInterval = 253_402_300_799

enum ISO8601 {
    // Cached formatters — initialised once at first use, never mutated after.
    // ISO8601DateFormatter is thread-safe for concurrent reads after
    // configuration (Apple documentation). Creating a new instance per call
    // triggers udat_open (ICU date format init) every time — prohibitively
    // expensive at scale (pegs the process when reading thousands of rows).
    // nonisolated(unsafe): options are set once at declaration time; the
    // instance is thereafter read-only, making concurrent access safe.
    //
    // Two parsers cover the two valid ISO-8601 shapes written by this kit
    // and by external tools:
    //   (1) withFractionalSeconds: "2026-06-12T18:02:48.000Z"  ← kit-canonical
    //   (2) withoutFractionalSeconds: "2026-06-12T18:02:48Z"   ← valid ISO-8601
    // Writing always uses shape (1) so stored values are canonical; reading
    // accepts both so rows written by other tools or older kit versions parse.
    nonisolated(unsafe) private static let formatterWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let formatterWithoutFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Format a `Date` as an RFC-3339 string for storage in a TEXT timestamp
    /// column.
    ///
    /// ## Write-boundary clamp (data-integrity invariant)
    ///
    /// `ISO8601DateFormatter` (the read side) only accepts four-digit years
    /// (0001–9999). An extreme `Date` — e.g. from a millisecond epoch stored
    /// where seconds were expected, or a bad Vault frontmatter `created` field
    /// — can cause the formatter to produce `+59009-...` which cannot be parsed
    /// back. To prevent this, `date` is clamped to the RFC-3339-parseable range
    /// before formatting. The clamped value is wrong-but-readable; the warning
    /// log is the signal to investigate the upstream source.
    static func string(from date: Date) -> String {
        let secs = date.timeIntervalSince1970
        let clamped: Date
        if secs < kMinRoundTripSecs {
            sqliteConnectionLog.warning(
                "ISO8601: timestamp \(secs, privacy: .public) is below year 0001 (RFC-3339 minimum); clamping to \(kMinRoundTripSecs, privacy: .public). Investigate the upstream source."
            )
            clamped = Date(timeIntervalSince1970: kMinRoundTripSecs)
        } else if secs > kMaxRoundTripSecs {
            sqliteConnectionLog.warning(
                "ISO8601: timestamp \(secs, privacy: .public) exceeds year 9999 (RFC-3339 maximum); clamping to \(kMaxRoundTripSecs, privacy: .public). Investigate the upstream source."
            )
            clamped = Date(timeIntervalSince1970: kMaxRoundTripSecs)
        } else {
            clamped = date
        }
        return formatterWithFraction.string(from: clamped)
    }

    /// Parse an ISO-8601 string, accepting both fractional-second and
    /// whole-second forms. Returns `nil` only when neither form succeeds,
    /// which means the string is not a valid ISO-8601 timestamp at all.
    ///
    /// Hot-path note: `NSISO8601DateFormatter` (`ISO8601DateFormatter`) is FAR
    /// TOO SLOW to use in this situation. Its `date(from:)` is ICU-backed
    /// (`udat`/calendar machinery) and costs microseconds per call even with
    /// the formatter instance cached. The Merkle rollup re-decodes every drawer
    /// in a room on each insert, so this parse runs O(N²) times during a large
    /// import — a stack sample showed it consuming ≈80% of total CPU and
    /// producing a visibly decelerating import. `fastParseCanonicalUTC` handles
    /// the exact shape this kit writes
    /// (`YYYY-MM-DDTHH:MM:SS[.fff…]Z`, UTC) without touching ICU; anything it
    /// does not confidently recognize (numeric offsets, malformed input)
    /// falls back to the formatters, which preserves the previous behavior
    /// exactly — including returning `nil` for genuinely corrupt values. The
    /// fast path is verified against the formatters in `ISO8601ParseTests`.
    static func date(from string: String) -> Date? {
        if let fast = fastParseCanonicalUTC(string) {
            return fast
        }
        return formatterWithFraction.date(from: string)
            ?? formatterWithoutFraction.date(from: string)
    }

    /// Fast, allocation-free parse of the canonical UTC RFC-3339 shape this
    /// kit emits: `YYYY-MM-DDTHH:MM:SSZ` or `YYYY-MM-DDTHH:MM:SS.fff…Z`.
    /// Returns `nil` for ANY deviation (offsets, lowercase markers, invalid
    /// calendar dates, trailing garbage) so the caller falls back to the
    /// reference formatters. For the shapes this kit writes (≤ millisecond
    /// fractions) the result is identical to `ISO8601DateFormatter`. Fractional
    /// seconds are retained at FULL sub-second precision — the "super fine"
    /// date — so for finer-than-millisecond fractions (only possible from
    /// externally-authored timestamps) the fast path is deliberately more
    /// precise than `ISO8601DateFormatter`, which caps at milliseconds. That is
    /// the correct, non-lossy behavior; it never loses precision the formatter
    /// would have kept.
    private static func fastParseCanonicalUTC(_ string: String) -> Date? {
        let u = Array(string.utf8)
        // Shortest accepted form "YYYY-MM-DDTHH:MM:SSZ" is 20 bytes.
        guard u.count >= 20 else { return nil }

        // ASCII digit at index i → its value, else nil.
        func digit(_ i: Int) -> Int? {
            let c = u[i]
            return (c >= 48 && c <= 57) ? Int(c - 48) : nil
        }
        // Fixed-width unsigned integer from `len` digits starting at `start`.
        func uint(_ start: Int, _ len: Int) -> Int? {
            var v = 0
            for i in start..<(start + len) {
                guard let d = digit(i) else { return nil }
                v = v * 10 + d
            }
            return v
        }

        // Structural separators: '-' '-' 'T' ':' ':' (uppercase T only — the
        // canonical form; lowercase/space falls back to the formatter).
        guard u[4] == 45, u[7] == 45, u[10] == 84, u[13] == 58, u[16] == 58 else { return nil }
        guard let year = uint(0, 4), let month = uint(5, 2), let day = uint(8, 2),
              let hour = uint(11, 2), let minute = uint(14, 2), let second = uint(17, 2)
        else { return nil }

        // Range + calendar-validity checks (reject what the formatter rejects).
        guard month >= 1, month <= 12, hour <= 23, minute <= 59, second <= 60 else { return nil }
        guard day >= 1, day <= daysInMonth(month, year: year) else { return nil }

        // Optional fractional seconds: '.' followed by ≥1 digit.
        var idx = 19
        var fractional = 0.0
        if idx < u.count, u[idx] == 46 {
            idx += 1
            var scale = 0.1
            var sawDigit = false
            while idx < u.count, let d = digit(idx) {
                fractional += Double(d) * scale
                scale /= 10
                idx += 1
                sawDigit = true
            }
            guard sawDigit else { return nil }
        }

        // Canonical fast path is UTC 'Z' only; offsets fall back.
        guard idx == u.count - 1, u[idx] == 90 else { return nil }

        // Days since 1970-01-01 (Howard Hinnant's days_from_civil — proleptic
        // Gregorian, matches Unix-epoch day counting and the formatter output).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468

        let seconds = Double(days * 86400 + hour * 3600 + minute * 60 + second) + fractional
        return Date(timeIntervalSince1970: seconds)
    }

    /// Days in `month` (1–12) for `year`, proleptic-Gregorian leap rule.
    private static func daysInMonth(_ month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
            return leap ? 29 : 28
        default: return 0
        }
    }
}

// JSON-encodable TypedValue facade for .array values.
struct JSONTypedValue: Codable {
    let type: String
    let value: String

    init(_ tv: TypedValue) {
        self.type = tv.typeDescription
        switch tv {
        case .null: self.value = ""
        case .bool(let b): self.value = b ? "true" : "false"
        case .int(let i): self.value = String(i)
        case .bitmap(let i): self.value = String(i)
        case .float(let d): self.value = String(d)
        case .text(let s): self.value = s
        case .blob(let d): self.value = d.base64EncodedString()
        case .uuid(let u): self.value = u.uuidString
        case .timestamp(let d): self.value = ISO8601.string(from: d)
        case .json(let d): self.value = String(data: d, encoding: .utf8) ?? ""
        case .hlc(let h): self.value = String(h.packed)
        case .fingerprint(let fp): self.value = "\(fp.block0):\(fp.block1):\(fp.block2):\(fp.block3)"
        case .array: self.value = "[nested]"
        }
    }
}
