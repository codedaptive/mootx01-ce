// SQLiteConnection.swift
//
// Thin Swift wrapper around the C sqlite3 API. Per-estate single
// connection (SQLite WAL mode handles multi-reader concurrency).

import Foundation
import SubstrateTypes
import SQLite3
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

    init(url: URL, busyTimeout: TimeInterval) throws {
        self.url = url
        self.busyTimeout = busyTimeout
        // Ensure parent directory exists.
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw StorageError.backendError(underlying: "sqlite open: \(msg)")
        }

        // Apple Data Protection: the OS stores the estate encrypted at rest
        // under a Secure Enclave-derived key (the device passcode is the root
        // secret). This is the Apple-native at-rest encryption — the Rust port
        // uses SQLCipher; each port uses its platform's mechanism and the files
        // are never shared. We bypass Core Data per PERSISTENCEKIT_SPEC
        // invariant I-2, so we set directly the protection class Core Data would
        // otherwise request via NSPersistentStoreFileProtectionKey.
        Self.applyDataProtection(to: url)

        // WAL mode and busy timeout.
        // Durability pragmas per SQLiteDurabilityTail (cookbook § 4.3.3):
        // WAL for crash-safe concurrent reads, NORMAL fsync,
        // wal_autocheckpoint truncates the WAL every 1000 frames.
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = NORMAL;")
        try exec("PRAGMA wal_autocheckpoint = 1000;")
        try exec("PRAGMA busy_timeout = \(Int(busyTimeout * 1000));")
        try exec("PRAGMA foreign_keys = ON;")
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    func close() {
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

    var lastErrorMessage: String {
        guard let handle else { return "(closed)" }
        return String(cString: sqlite3_errmsg(handle))
    }
}

final class SQLiteStatement {
    var stmt: OpaquePointer?
    weak var connection: SQLiteConnection?

    init(stmt: OpaquePointer, connection: SQLiteConnection) {
        self.stmt = stmt
        self.connection = connection
    }

    deinit { if let stmt { sqlite3_finalize(stmt) } }

    func finalize() {
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
            sqlite3_bind_int64(stmt, index, sqlite3_int64(hlc.packed))
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

    static func string(from date: Date) -> String {
        formatterWithFraction.string(from: date)
    }

    /// Parse an ISO-8601 string, accepting both fractional-second and
    /// whole-second forms. Returns `nil` only when neither form succeeds,
    /// which means the string is not a valid ISO-8601 timestamp at all.
    static func date(from string: String) -> Date? {
        formatterWithFraction.date(from: string)
            ?? formatterWithoutFraction.date(from: string)
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
