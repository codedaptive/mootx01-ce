// CommunityEstateHostTests.swift
//
// Wave A1a: CommunityEstateHost acceptance tests.
//
// Tests the production EstateLifecycleAuthority conformer against a real
// on-disk estate. Uses the TwentyRowEstateFixture pattern (per-test temp
// directory, cleaned up in defer) — never the production estate.
//
// Test coverage:
//   A1a-H1  fresh directory creates exactly one estate with a stable UUID
//   A1a-H2  reopen of the same path returns the IDENTICAL identity (no double-create)
//   A1a-H3  concurrent calls to openEstate() on the same actor return identical proof
//   A1a-H4  corrupt estate → fail-closed error (never silent success)
//   A1a-H5  closeEstate() clears state; re-open succeeds with same identity

import Testing
import Foundation
@testable import MootCommunityDaemon
import MootDaemonProvider
import LocusKit
import PersistenceKit
import PersistenceKitSQLite

// MARK: - Scratch directory helper

/// A per-test scratch directory deleted in defer.
private struct HostScratch {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("a1a-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    var estateURL: URL {
        url.appendingPathComponent("estate.sqlite")
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Plaintext key provider — returns EstateEncryptionConfig.plaintext for all URLs.
/// Used in every test; no Keychain, no encryption, no external state.
private let plaintextProvider: @Sendable (URL) throws -> EstateEncryptionConfig = { _ in
    .plaintext
}

// MARK: - A1a-H1: Fresh directory creates one estate

@Test("A1a-H1: fresh directory creates exactly one estate with a stable UUID")
func freshDirectoryCreatesEstate() async throws {
    let scratch = try HostScratch()
    defer { scratch.remove() }

    let host = CommunityEstateHost(
        estateURL: scratch.estateURL,
        ownerIdentifier: "com.mootx01.daemon.test",
        keyProvider: plaintextProvider
    )
    let proof = try await host.openEstate()

    // The estate file must now exist.
    #expect(
        FileManager.default.fileExists(atPath: scratch.estateURL.path),
        "Estate.open() should create the file on a fresh directory"
    )

    // The proof must carry a real UUID (not all-zeros) and a non-zero schema version.
    #expect(proof.estateIdentifier != UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
    #expect(proof.schemaVersion > 0, "LocusKit must have applied at least one migration")

    // Calling openEstate() a second time on the same actor returns the same proof
    // (idempotent fast-path via cached proof).
    let proof2 = try await host.openEstate()
    #expect(proof == proof2, "Second call on the same actor must return the cached proof")
}

// MARK: - A1a-H2: Reopen returns SAME identity

@Test("A1a-H2: reopen with a NEW CommunityEstateHost returns the identical estate UUID")
func reopenReturnsSameIdentity() async throws {
    let scratch = try HostScratch()
    defer { scratch.remove() }

    // First host: creates the estate.
    let host1 = CommunityEstateHost(
        estateURL: scratch.estateURL,
        ownerIdentifier: "com.mootx01.daemon.test",
        keyProvider: plaintextProvider
    )
    let proof1 = try await host1.openEstate()
    try await host1.closeEstate()

    // Second host: REOPENS the same file without creating a new one.
    let host2 = CommunityEstateHost(
        estateURL: scratch.estateURL,
        ownerIdentifier: "com.mootx01.daemon.test",
        keyProvider: plaintextProvider
    )
    let proof2 = try await host2.openEstate()

    // CORE-01: the identity must be the SAME as on the first open.
    // If the host created a new estate instead of reopening, the UUID would differ.
    #expect(
        proof1.estateIdentifier == proof2.estateIdentifier,
        "Reopen must return the SAME estate UUID — not a freshly-created replacement"
    )
    #expect(
        proof1.schemaVersion == proof2.schemaVersion,
        "Schema version must be stable across opens of the same file"
    )
}

// MARK: - A1a-H3: Concurrent calls return identical proof

@Test("A1a-H3: concurrent openEstate() calls on the same actor return the identical proof")
func concurrentOpenReturnsSameProof() async throws {
    let scratch = try HostScratch()
    defer { scratch.remove() }

    let host = CommunityEstateHost(
        estateURL: scratch.estateURL,
        ownerIdentifier: "com.mootx01.daemon.test",
        keyProvider: plaintextProvider
    )

    // Launch two concurrent callers. The actor serializes them; both see the
    // same proof (the first caller opens the estate, the second gets the cached proof).
    async let proof1 = host.openEstate()
    async let proof2 = host.openEstate()
    let (p1, p2) = try await (proof1, proof2)

    #expect(p1 == p2, "Concurrent callers must receive identical proof from the actor")
}

// MARK: - A1a-H4: Corrupt estate → fail-closed error

@Test("A1a-H4: a corrupt estate file causes openEstate() to throw, never silently succeed")
func corruptEstateFailsClosed() async throws {
    let scratch = try HostScratch()
    defer { scratch.remove() }

    // Write garbage bytes that look like a locked/corrupt SQLite file.
    // A real SQLite file starts with "SQLite format 3\0"; these bytes do not.
    let garbage = Data(repeating: 0xDE, count: 4096)
    try garbage.write(to: scratch.estateURL)

    let host = CommunityEstateHost(
        estateURL: scratch.estateURL,
        ownerIdentifier: "com.mootx01.daemon.test",
        keyProvider: plaintextProvider
    )

    // openEstate() MUST throw on a non-parseable file.
    // The exact error type varies (LocusKit may throw EstateError or StorageError),
    // but it MUST NOT return a proof with a nil or all-zero UUID.
    do {
        let proof = try await host.openEstate()
        // If we reach here, the host succeeded on garbage input — this is a failure.
        Issue.record(
            "openEstate() returned \(proof) for a garbage file — expected a throw"
        )
    } catch {
        // Any throw is the correct fail-closed outcome.
        // We do not assert a specific error type here because LocusKit and
        // SQLiteStorage both produce appropriate typed errors for corrupt input.
    }
}

// MARK: - A1a-H5: closeEstate clears state; re-open succeeds

@Test("A1a-H5: closeEstate() clears the cached proof; re-open on the same actor succeeds")
func closeAndReopenSucceeds() async throws {
    let scratch = try HostScratch()
    defer { scratch.remove() }

    let host = CommunityEstateHost(
        estateURL: scratch.estateURL,
        ownerIdentifier: "com.mootx01.daemon.test",
        keyProvider: plaintextProvider
    )

    let proof1 = try await host.openEstate()
    try await host.closeEstate()

    // After closeEstate, openEstate must re-open successfully.
    let proof2 = try await host.openEstate()

    // The UUID must remain stable across close-and-reopen.
    #expect(
        proof1.estateIdentifier == proof2.estateIdentifier,
        "Close-and-reopen must return the same estate UUID"
    )
}
