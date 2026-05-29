import Foundation
import PersistenceKit
import PersistenceKitSQLite
@testable import LocusKit

/// Shared test helpers for constructing a storage-backed DrawerStore.
///
/// The store no longer opens a database from a URL itself; it takes an
/// injected `any Storage`. These helpers build a SQLiteStorage over a
/// temporary file (or a caller-supplied URL) so each test file does
/// not repeat the EstateConfiguration boilerplate.
enum TestStorage {

    /// A fresh temporary database URL under NSTemporaryDirectory.
    static func tempURL() -> URL {
        let name = "locuskit-test-\(UUID().uuidString).sqlite"
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
    }

    /// Construct a SQLiteStorage over `url`. The estate id is a fresh
    /// UUID per call; tests that reopen the same file pass the same
    /// url and get a distinct configuration object pointing at the
    /// same database, which is the intended reopen semantics.
    static func sqlite(_ url: URL) -> SQLiteStorage {
        // Valid temp paths never fail to open; force-try keeps the
        // common call sites terse. Tests that intentionally use a
        // bad path call `sqliteThrowing(_:)` instead.
        return try! sqliteThrowing(url)
    }

    /// Throwing variant: constructs a SQLiteStorage, surfacing the
    /// backend open failure (used by the bad-path test, where the
    /// substrate cannot open the file).
    static func sqliteThrowing(_ url: URL) throws -> SQLiteStorage {
        let config = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url)
        )
        return try SQLiteStorage(configuration: config)
    }

    /// Open a DrawerStore over a fresh SQLite file, returning both the
    /// store and the url so the caller can reopen or clean up.
    static func makeStore() async throws -> (DrawerStore, URL) {
        let url = tempURL()
        let store = try await DrawerStore(storage: sqlite(url))
        return (store, url)
    }

    /// Open a DrawerStore over an existing url (reopen path).
    static func openStore(_ url: URL) async throws -> DrawerStore {
        try await DrawerStore(storage: sqlite(url))
    }

    /// Remove a temporary database file and its WAL/SHM siblings.
    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-shm"))
    }

    /// Deterministic test UUID from a short label. Capture is a gated
    /// write requiring a UUID row identity (I-29), so tests build a
    /// well-formed UUID-v4 string from a readable label ("d1",
    /// "alice-1") instead of hard-coding raw UUIDs. Pass-through if
    /// `label` is already a parseable UUID.
    ///
    /// Uses FNV-1a 64-bit (offset basis + prime) as a mixing
    /// primitive interleaved with byte scattering across all 16
    /// output bytes — NOT a pure FNV-1a string hash, so this helper
    /// is not a substrate atomic and does not call `FNV.hash64`
    /// directly. The resulting UUIDs are stable across runs and
    /// across the 9 test files that used to each carry a private
    /// copy of this function.
    static func tid(_ label: String) -> String {
        if UUID(uuidString: label) != nil { return label }
        var bytes = [UInt8](repeating: 0, count: 16)
        var h: UInt64 = 0xcbf29ce484222325
        for (i, b) in Array(label.utf8).enumerated() {
            h ^= UInt64(b); h = h &* 0x100000001b3
            bytes[i % 16] ^= UInt8(h & 0xff)
            bytes[(i + 7) % 16] ^= UInt8((h >> 32) & 0xff)
        }
        for i in 0..<16 {
            h ^= UInt64(bytes[i]); h = h &* 0x100000001b3
            bytes[i] = bytes[i] &+ UInt8(h & 0xff)
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x40  // UUID v4 version nibble
        bytes[8] = (bytes[8] & 0x3f) | 0x80  // UUID variant nibble
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let a = hex.prefix(8), b = hex.dropFirst(8).prefix(4), c = hex.dropFirst(12).prefix(4)
        let d = hex.dropFirst(16).prefix(4), e = hex.dropFirst(20).prefix(12)
        return "\(a)-\(b)-\(c)-\(d)-\(e)"
    }
}
