// EncryptionMode.swift
//
// At-rest encryption modes 1–3 per
// DECISION_FEDERATION_SHARING_MODEL_2026-05-21.md Appendix A.2.
// These types live in PersistenceKit core (not LocusKit) because the
// SQLite backend consumes them and the kit dependency runs one way
// (LocusKit → PersistenceKit). LocusKit already imports PersistenceKit, so the
// types stay visible to it.
//
// Mode 4 (database + threshold) is the FedRAMP-tier experimental gate
// and is deliberately NOT a case here: see Appendix A.3 ("the capability
// is absent from the build"). Adding a fourth case is a deliberate,
// reviewed act, not a silent extension.

import Foundation
import CryptoKit

/// The estate's at-rest encryption mode. One mechanism, three
/// key-distribution choices — not three systems (Appendix A.2).
public enum EncryptionMode: Sendable, Equatable {
    /// Mode 1 — plaintext at rest; encryption happens only at the share
    /// fence. The content column is stored verbatim and crypto is a no-op.
    case plaintext
    /// Mode 2 — per-row content ciphertext under a per-row or per-estate
    /// key; the row carries the key identifier.
    case rowEncryption
    /// Mode 3 — the whole estate under a per-install key (hardware-wrapped
    /// where available). Mechanically identical per-row crypto to mode 2 at
    /// this layer; the distinction is key provenance (one per-install key).
    case fullDatabase
}

/// Per-estate encryption configuration. Carries the mode, the public key
/// identifier recorded on each encrypted row, and the data key itself.
///
/// The key is `package`-scoped, not `public`: it must reach
/// `SQLiteBackend` in the sibling `PersistenceKitSQLite` target, but it is
/// never part of PersistenceKit's exported public API. (`internal` would not
/// cross the module boundary.) `.plaintext` mints neither key nor
/// identifier; the two encrypting modes mint a fresh 256-bit key and a
/// UUID identifier.
public struct EstateEncryptionConfig: Sendable {
    /// The at-rest encryption mode.
    public let mode: EncryptionMode
    /// Stable identifier recorded in the row's keyID column and the key
    /// registry. `nil` for `.plaintext`.
    public let keyIdentifier: String?
    /// The AES-GCM-256 data key. `package`-scoped so the SQLite backend can
    /// use it without exporting it. `nil` for `.plaintext`.
    package let key: SymmetricKey?

    /// Designated initializer. `package` so callers outside the package use
    /// the mode-based convenience initializer, which enforces the
    /// key/identifier invariants per mode.
    package init(mode: EncryptionMode, keyIdentifier: String?, key: SymmetricKey?) {
        self.mode = mode
        self.keyIdentifier = keyIdentifier
        self.key = key
    }

    /// Build a config for `mode`. `.plaintext` carries no key; the two
    /// encrypting modes generate a fresh full-entropy 256-bit key and a
    /// UUID key identifier (the FileVault / crypto-wallet model from
    /// Appendix A.1 — the key is generated for the user, never chosen as a
    /// passphrase).
    public init(_ mode: EncryptionMode) {
        switch mode {
        case .plaintext:
            self.init(mode: .plaintext, keyIdentifier: nil, key: nil)
        case .rowEncryption, .fullDatabase:
            self.init(
                mode: mode,
                keyIdentifier: UUID().uuidString,
                key: SymmetricKey(size: .bits256)
            )
        }
    }

    /// The default, zero-change configuration: plaintext at rest.
    public static let plaintext = EstateEncryptionConfig(.plaintext)
}
