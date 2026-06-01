// EncryptionModeTests.swift
//
// Mission ENC-01 — at-rest encryption modes 1–3.
// Verifies the shape of EstateEncryptionConfig per encryption mode:
// plaintext mints no key; the two encrypting modes mint a key and a
// stable identifier. Mode 4 (database + threshold) is out of scope and
// absent from the enum — guarded by an exhaustive switch below.

import Testing
import PersistenceKit

struct EncryptionModeTests {

    /// Mode 1: plaintext stores neither a key nor an identifier.
    @Test func plaintextStoresNoKey() {
        let config = EstateEncryptionConfig(.plaintext)
        #expect(config.mode == .plaintext)
        #expect(config.keyIdentifier == nil)
        // `key` is package-scoped; the test target is in-package so it can
        // assert the key was not minted.
        #expect(config.key == nil)
    }

    /// Mode 2: row encryption mints a fresh key and a stable identifier.
    @Test func rowEncryptionGeneratesKeyAndIdentifier() {
        let config = EstateEncryptionConfig(.rowEncryption)
        #expect(config.mode == .rowEncryption)
        #expect(config.keyIdentifier != nil)
        #expect(!(config.keyIdentifier?.isEmpty ?? true))
        #expect(config.key != nil)
    }

    /// Mode 3: full-database encryption mints a fresh key and identifier.
    @Test func fullDatabaseGeneratesKeyAndIdentifier() {
        let config = EstateEncryptionConfig(.fullDatabase)
        #expect(config.mode == .fullDatabase)
        #expect(config.keyIdentifier != nil)
        #expect(!(config.keyIdentifier?.isEmpty ?? true))
        #expect(config.key != nil)
    }

    /// Mode 4 (database + threshold) is explicitly out of scope for v1.0.
    /// This exhaustive switch is the compile-time guard: if a fourth case
    /// is ever added to EncryptionMode, this test stops compiling and forces
    /// a deliberate review rather than silently shipping an unbuilt mode.
    /// It also confirms two distinct modes are not equal.
    @Test func modeFourIsAbsentAndModesAreDistinct() {
        for mode in [EncryptionMode.plaintext, .rowEncryption, .fullDatabase] {
            switch mode {
            case .plaintext, .rowEncryption, .fullDatabase:
                break
            }
        }
        #expect(EncryptionMode.plaintext != .rowEncryption)
        #expect(EncryptionMode.rowEncryption != .fullDatabase)
    }
}
