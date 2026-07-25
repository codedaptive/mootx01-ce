// EstateFileDetection.swift
//
// The authoritative answer to "is the estate file on disk encrypted?", consumed
// by CE-1.0.35-06 (which must keep opening an existing plaintext estate) and
// CE-1.0.35-08 (which must only offer to migrate a plaintext one).
//
// It reads the file header directly. It does NOT open a SQLite connection and it
// does NOT probe by attempting an encrypted open and catching the error. Both of
// those are wrong here: a connection cannot classify a file whose key the caller
// does not have, and guess-then-catch turns an unrelated failure into a
// misclassification, which in the migration path would mean acting on a file the
// code does not actually understand.

import Foundation

extension EstateKeyProvider {

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
}
