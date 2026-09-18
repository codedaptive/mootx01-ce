// CommunitySourceEstateAccessTests.swift
//
// Wave A1a: CommunitySourceEstateAccess acceptance tests.
//
// Tests the production SourceEstateAccess conformer against real plaintext
// estates created by TwentyRowEstateFixture. The fixture generates a
// twenty-drawer estate with kg_facts; every test gets a clean temp directory.
//
// Test coverage:
//   A1a-S1  readIdentity() on a plaintext fixture returns a real UUID + version
//   A1a-S2  openExclusive() claims the WAL lock; close() releases it
//   A1a-S3  checkpointTruncate() + verifyEmptyWAL() passes on a clean estate
//   A1a-S4  verifyReadOnlyOpen() on a copy returns matching identity
//   A1a-S5  census correctly identifies a daemon-owned canonical estate
//   A1a-S6  census hard-stops on a candidate with nil identity (KONG-2)

import Testing
import Foundation
@testable import MootCommunityDaemon
import MootDaemonProvider
import LocusKitEstateFixture

// MARK: - A1a-S1: readIdentity on a plaintext estate

@Test("A1a-S1: readIdentity() returns a real UUID and a non-zero schema version")
func readIdentityReturnsRealUUID() async throws {
    let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
    defer { TwentyRowEstateFixture.cleanup(manifest) }

    let access = CommunitySourceEstateAccess(estateURL: manifest.estateURL, keyBytes: nil)
    try await access.openExclusive()
    defer { try? await access.close() }

    let identity = try await access.readIdentity()

    // The estate UUID must be a real UUID (not all-zeros).
    let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    #expect(identity.estateIdentifier != zeroUUID, "estate UUID must be non-zero")

    // Schema version must be non-zero (LocusKit applies migrations on open).
    #expect(identity.schemaVersion > 0, "schema version must be > 0 after LocusKit migrations")

    // Anchor counts must match the fixture's twenty-row shape.
    // The fixture captures 20 drawers and 6 kg_facts (see TwentyRowEstateFixture.Manifest).
    #expect(
        identity.anchorCounts["drawers"] == UInt64(manifest.drawerCount),
        "drawer count must match fixture manifest"
    )
    #expect(
        identity.anchorCounts["kg_facts"] == UInt64(manifest.factCount),
        "kg_facts count must match fixture manifest"
    )
}

// MARK: - A1a-S2: openExclusive acquires lock; close releases it

@Test("A1a-S2: openExclusive() succeeds on a valid plaintext estate")
func openExclusiveSucceeds() async throws {
    let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
    defer { TwentyRowEstateFixture.cleanup(manifest) }

    let access = CommunitySourceEstateAccess(estateURL: manifest.estateURL, keyBytes: nil)
    // Must not throw on a valid estate.
    try await access.openExclusive()
    try await access.close()
}

@Test("A1a-S2b: openExclusive() throws alreadyOpen if called twice without close()")
func openExclusiveThrowsIfAlreadyOpen() async throws {
    let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
    defer { TwentyRowEstateFixture.cleanup(manifest) }

    let access = CommunitySourceEstateAccess(estateURL: manifest.estateURL, keyBytes: nil)
    try await access.openExclusive()
    defer { try? await access.close() }

    do {
        try await access.openExclusive()
        Issue.record("Second openExclusive() must throw alreadyOpen")
    } catch CommunityDaemonError.alreadyOpen {
        // Correct: already-open guard fired.
    } catch {
        Issue.record("Expected alreadyOpen, got \(error)")
    }
}

@Test("A1a-S2c: openExclusive() throws on a nonexistent path (CORE-01: never creates)")
func openExclusiveRefusesNonexistentPath() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("a1a-s2c-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let missing = tempDir.appendingPathComponent("no-estate.sqlite")
    let access = CommunitySourceEstateAccess(estateURL: missing, keyBytes: nil)

    do {
        try await access.openExclusive()
        Issue.record("openExclusive() must throw on a nonexistent path — CORE-01")
    } catch CommunityDaemonError.sqliteError {
        // Correct: SQLITE_CANTOPEN.
    } catch {
        // Any other throw is also acceptable — the point is it must NOT succeed.
    }
}

// MARK: - A1a-S3: checkpointTruncate + verifyEmptyWAL

@Test("A1a-S3: checkpointTruncate() + verifyEmptyWAL() passes on a clean plaintext estate")
func checkpointTruncateAndVerifyEmptyWAL() async throws {
    let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
    defer { TwentyRowEstateFixture.cleanup(manifest) }

    let access = CommunitySourceEstateAccess(estateURL: manifest.estateURL, keyBytes: nil)
    try await access.openExclusive()
    defer { try? await access.close() }

    // On a cleanly-closed estate (as generated by the fixture), the WAL is already
    // empty. The truncating checkpoint is idempotent.
    try await access.checkpointTruncate()
    try await access.verifyEmptyWAL()
}

// MARK: - A1a-S4: verifyReadOnlyOpen on a copy

@Test("A1a-S4: verifyReadOnlyOpen() on a file-copy returns matching identity")
func verifyReadOnlyOpenMatchesSource() async throws {
    let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
    defer { TwentyRowEstateFixture.cleanup(manifest) }

    // Make a file-level copy of the estate.
    let copyURL = manifest.estateURL.deletingLastPathComponent()
        .appendingPathComponent("estate-copy.sqlite")
    try FileManager.default.copyItem(at: manifest.estateURL, to: copyURL)
    defer { try? FileManager.default.removeItem(at: copyURL) }

    // Read identity from the source via exclusive open.
    let sourceAccess = CommunitySourceEstateAccess(estateURL: manifest.estateURL, keyBytes: nil)
    try await sourceAccess.openExclusive()
    let sourceIdentity = try await sourceAccess.readIdentity()
    try await sourceAccess.close()

    // Verify the copy. verifyReadOnlyOpen opens the copy in read-only mode,
    // runs integrity_check, then reads the identity.
    let copyAccess = CommunitySourceEstateAccess(estateURL: manifest.estateURL, keyBytes: nil)
    let copyIdentity = try await copyAccess.verifyReadOnlyOpen(destination: copyURL)

    // The identity must match the source.
    #expect(
        sourceIdentity.estateIdentifier == copyIdentity.estateIdentifier,
        "Copy must carry the same estate UUID as the source"
    )
    #expect(
        sourceIdentity.schemaVersion == copyIdentity.schemaVersion,
        "Copy must carry the same schema version as the source"
    )
    #expect(
        sourceIdentity.anchorCounts == copyIdentity.anchorCounts,
        "Copy must carry the same anchor counts as the source"
    )
}

// MARK: - A1a-S5: Census correctly identifies daemon-owned canonical estate

@Test("A1a-S5: census correctly identifies a daemon-owned canonical estate")
func censusIdentifiesCanonicalEstate() async throws {
    let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
    defer { TwentyRowEstateFixture.cleanup(manifest) }

    // Read the true identity via CommunitySourceEstateAccess.
    let access = CommunitySourceEstateAccess(estateURL: manifest.estateURL, keyBytes: nil)
    try await access.openExclusive()
    let identity = try await access.readIdentity()
    try await access.close()

    // Build a canonical candidate record carrying that identity.
    // A "canonical" estate is one where:
    //   - main file is present (isNonEmpty = true)
    //   - WAL is absent (checkpointed)
    //   - identity is verified (non-nil)
    let canonicalCandidate = CensusCandidateRecord(
        candidateClass: .canonical,
        main: .present(
            bytes: 4096,
            device: 1,
            inode: 1,
            linkCount: 1,
            digestSHA256Hex: "aaaa"
        ),
        wal: .absent,
        encryption: .plaintext,
        keyReachability: .reachableWithoutMint,
        identity: identity,
        receiptCoverage: .none
    )

    // An observation with ONLY the canonical present and NO legacy candidates
    // must judge as alreadyConverged (migration is done or never needed).
    let observation = CensusObservation(
        candidates: [],
        canonical: canonicalCandidate,
        siblings: []
    )
    let disposition = DefaultEstateCensus.judge(observation)

    #expect(
        disposition == .alreadyConverged,
        "A canonical-only observation with a verified identity must judge as alreadyConverged"
    )
}

// MARK: - A1a-S6: Census hard-stops on ambiguous input (nil identity)

@Test("A1a-S6: census hard-stops on a candidate with nil identity (KONG-2 conservatism)")
func censusHardStopsOnNilIdentity() {
    // A candidate whose identity could not be verified: identity: nil.
    // KONG-2: an unverifiable candidate MUST produce a hard stop, never an election.
    let unverifiableCandidate = CensusCandidateRecord(
        candidateClass: .swiftCE,
        main: .present(
            bytes: 4096,
            device: 1,
            inode: 1,
            linkCount: 1,
            digestSHA256Hex: "bbbb"
        ),
        wal: .absent,
        encryption: .plaintext,
        keyReachability: .reachableWithoutMint,
        identity: nil,    // identity unverifiable → hard stop
        receiptCoverage: .none
    )

    let observation = CensusObservation(
        candidates: [unverifiableCandidate],
        canonical: nil,
        siblings: []
    )
    let disposition = DefaultEstateCensus.judge(observation)

    // KONG-2: any unverifiable candidate must cause a hard stop.
    if case .multipleEstatesHardStop = disposition {
        // Correct.
    } else {
        Issue.record("Expected multipleEstatesHardStop for a nil-identity candidate, got \(disposition)")
    }
}

@Test("A1a-S6b: census hard-stops on two candidates with distinct UUIDs")
func censusHardStopsOnMultipleDistinctCandidates() async throws {
    // Two estates with different UUIDs — human authority required.
    func makeCandidate(cls: EstateCandidateClass, uuid: UUID, digest: String, inode: UInt64) -> CensusCandidateRecord {
        let identity = CensusIdentity(
            estateIdentifier: uuid,
            schemaVersion: (1 << 16) | 1,
            anchorCounts: ["drawers": 5, "kg_facts": 2]
        )
        return CensusCandidateRecord(
            candidateClass: cls,
            main: .present(bytes: 4096, device: 1, inode: inode, linkCount: 1, digestSHA256Hex: digest),
            wal: .absent,
            encryption: .plaintext,
            keyReachability: .reachableWithoutMint,
            identity: identity,
            receiptCoverage: .none
        )
    }

    let candidate1 = makeCandidate(
        cls: .community,
        uuid: UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!,
        digest: "aabb",
        inode: 1
    )
    let candidate2 = makeCandidate(
        cls: .swiftCE,
        uuid: UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!,
        digest: "ccdd",
        inode: 2
    )

    let observation = CensusObservation(candidates: [candidate1, candidate2], canonical: nil, siblings: [])
    let disposition = DefaultEstateCensus.judge(observation)

    if case .multipleEstatesHardStop = disposition {
        // Correct: multiple distinct identities require human authority.
    } else {
        Issue.record(
            "Expected multipleEstatesHardStop for two distinct UUIDs, got \(disposition)"
        )
    }
}
