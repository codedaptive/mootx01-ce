// EncryptionModeTests.swift
//
// Mission ENC-01 — at-rest encryption modes 1–3.
// Verifies the shape of EstateEncryptionConfig per encryption mode:
// plaintext mints no key; the two encrypting modes mint a key and a
// stable identifier. Mode 4 (database + threshold) is out of scope and
// absent from the enum — guarded by an exhaustive switch below.

import XCTest
import PersistenceKit

final class EncryptionModeTests: XCTestCase {

    /// Mode 1: plaintext stores neither a key nor an identifier.
    func testPlaintextStoresNoKey() {
        let config = EstateEncryptionConfig(.plaintext)
        XCTAssertEqual(config.mode, .plaintext)
        XCTAssertNil(config.keyIdentifier)
        // `key` is package-scoped; the test target is in-package so it can
        // assert the key was not minted.
        XCTAssertNil(config.key)
    }

    /// Mode 2: row encryption mints a fresh key and a stable identifier.
    func testRowEncryptionGeneratesKeyAndIdentifier() {
        let config = EstateEncryptionConfig(.rowEncryption)
        XCTAssertEqual(config.mode, .rowEncryption)
        XCTAssertNotNil(config.keyIdentifier)
        XCTAssertFalse(config.keyIdentifier?.isEmpty ?? true)
        XCTAssertNotNil(config.key)
    }

    /// Mode 3: full-database encryption mints a fresh key and identifier.
    func testFullDatabaseGeneratesKeyAndIdentifier() {
        let config = EstateEncryptionConfig(.fullDatabase)
        XCTAssertEqual(config.mode, .fullDatabase)
        XCTAssertNotNil(config.keyIdentifier)
        XCTAssertFalse(config.keyIdentifier?.isEmpty ?? true)
        XCTAssertNotNil(config.key)
    }

    /// Mode 4 (database + threshold) is explicitly out of scope for v1.0.
    /// This exhaustive switch is the compile-time guard: if a fourth case
    /// is ever added to EncryptionMode, this test stops compiling and forces
    /// a deliberate review rather than silently shipping an unbuilt mode.
    /// It also confirms two distinct modes are not equal.
    func testModeFourIsAbsentAndModesAreDistinct() {
        for mode in [EncryptionMode.plaintext, .rowEncryption, .fullDatabase] {
            switch mode {
            case .plaintext, .rowEncryption, .fullDatabase:
                break
            }
        }
        XCTAssertNotEqual(EncryptionMode.plaintext, .rowEncryption)
        XCTAssertNotEqual(EncryptionMode.rowEncryption, .fullDatabase)
    }
}
