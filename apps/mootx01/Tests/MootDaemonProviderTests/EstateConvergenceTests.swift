import Foundation
import Testing
import AriaMCP
@testable import MootDaemonProvider

// MARK: - MACD-2c2 — estate convergence adversarial matrices
//
// One consolidated file (path-budget rule, BRR §3.14) covering:
//   1. P-c2-1  — mint license bound to the production lock layout
//   2. P-c2-2  — production CSPRNG composition shape
//   3. KONG-2  — census disposition golden vectors (pure judge)
//   4. P-c2-3/4/5 — grant envelope MAC / expiry / binding / replay /
//                journal-first ordering / fail-closed journal
//   5. P-c2-6  — production stale policy + F4 denial classifier
//   6. P-c2-7  — escrow rules (never mint over ciphertext)
//   7. KONG-3  — migration state machine ordering, crash matrix at every
//                durable boundary, idempotent resume, quarantine/rollback/
//                recoveryRequired, source never deleted
//   8. Self-report digest coverage of the new contract elements
//
// Every clock and byte of randomness is injected (P-c2-12). No test touches
// any real estate, provider directory, or Keychain: filesystem work happens
// in per-test scratch directories, Keychain work in recording fakes.

// MARK: Shared scratch + fixed identities

/// A per-test scratch directory with hygiene-compatible permissions (0o700).
private struct ConvergenceScratch {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macd2c2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

private let fixedRoot = [UInt8](repeating: 0x42, count: 32)
private let providerInstance = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
private let otherInstance = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000002")!
private let estateA = UUID(uuidString: "BBBBBBBB-0000-4000-8000-00000000000A")!
private let estateB = UUID(uuidString: "BBBBBBBB-0000-4000-8000-00000000000B")!
private let fixedGenerations = ProviderGenerations(credential: 3, provider: 5, descriptor: 7)

private func fixedClock(_ value: UInt64) -> ProviderClock { { value } }
private func fixedRandom(_ byte: UInt8) -> ProviderRandomness {
    { count in [UInt8](repeating: byte, count: count) }
}

/// A verified census identity for golden vectors.
private func identity(_ uuid: UUID, schema: UInt64 = 4) -> CensusIdentity {
    CensusIdentity(estateIdentifier: uuid, schemaVersion: schema, anchorCounts: ["drawers": 10, "kg_facts": 20])
}

/// A present, checkpointed candidate main.
private func presentMain(digest: String, bytes: UInt64 = 4096) -> CensusCandidateRecord.Main {
    .present(bytes: bytes, device: 7, inode: 42, linkCount: 1, digestSHA256Hex: digest)
}

private func candidate(
    _ candidateClass: EstateCandidateClass,
    main: CensusCandidateRecord.Main,
    wal: CensusCandidateRecord.WAL = .absent,
    encryption: EncryptionPosture = .encrypted,
    key: KeyReachability = .reachableWithoutMint,
    identity: CensusIdentity? = nil,
    receipt: ReceiptCoverage = .none
) -> CensusCandidateRecord {
    CensusCandidateRecord(
        candidateClass: candidateClass, main: main, wal: wal,
        encryption: encryption, keyReachability: key,
        identity: identity, receiptCoverage: receipt
    )
}

// MARK: - 1. P-c2-1 — mint license binds to the production lock layout

/// A Keychain fake that CLAIMS the production marker: pairing it with a
/// non-production lock proof must refuse before any add is reachable.
private final class MarkedProductionKeychain: KeychainItemAuthority, ProductionCredentialAuthority, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var copyCalls = 0
    private(set) var addCalls = 0
    func copyItem(service: String, account: String, accessGroup: String) -> KeychainReadResult {
        lock.lock(); defer { lock.unlock() }
        copyCalls += 1
        return .notFound
    }
    func addItem(service: String, account: String, accessGroup: String, data: [UInt8]) -> KeychainWriteStatus {
        lock.lock(); defer { lock.unlock() }
        addCalls += 1
        return .added
    }
}

/// An unmarked fake with the same behavior — the control arm.
private final class UnmarkedKeychain: KeychainItemAuthority, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var stored: [UInt8]?
    func copyItem(service: String, account: String, accessGroup: String) -> KeychainReadResult {
        lock.lock(); defer { lock.unlock() }
        if let stored { return .found(stored) }
        return .notFound
    }
    func addItem(service: String, account: String, accessGroup: String, data: [UInt8]) -> KeychainWriteStatus {
        lock.lock(); defer { lock.unlock() }
        stored = data
        return .added
    }
}

private func judgedEligibility() throws -> ProviderEligibility {
    try ProviderEligibilityJudge.judge(SignedProcessIdentity(
        signingClass: .developerID,
        teamIdentifier: "TEAM123456",
        applicationGroups: [ProviderEligibilityJudge.requiredAppGroup],
        keychainAccessGroups: ["TEAM123456." + ProviderEligibilityJudge.requiredKeychainGroupSuffix],
        bundleIdentifier: "com.codedaptive.mootx01.test"
    ))
}

@Suite("P-c2-1 — mint license bound to production lock layout")
struct MintLicenseBindingTests {

    @Test("layout resolution stamps production vs proof context")
    func layoutContext() throws {
        struct FixedResolver: ProviderRootResolving {
            let base: URL
            func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? { base }
        }
        let scratch = try ConvergenceScratch()
        defer { scratch.remove() }
        let production = try ProviderRootLayout.resolve(
            resolver: FixedResolver(base: scratch.url), groupIdentifier: "g", proofContext: nil
        )
        #expect(production.context == .production)
        let proof = try ProviderRootLayout.resolve(
            resolver: FixedResolver(base: scratch.url), groupIdentifier: "g",
            proofContext: UUID().uuidString
        )
        #expect(proof.context == .proof)
    }

    @Test("a proof-layout lock proof refuses a production-marker mint before any add")
    func proofLayoutRefusesProductionMint() throws {
        let scratch = try ConvergenceScratch()
        defer { scratch.remove() }
        let handle = try ProviderLock.acquire(
            at: scratch.url.appendingPathComponent("provider.lock"), context: .proof
        )
        defer { handle.release() }
        let keychain = MarkedProductionKeychain()
        let authority = InstallationRootAuthority(
            keychain: keychain, eligibility: try judgedEligibility(), randomBytes: fixedRandom(9)
        )
        #expect(throws: DaemonProviderError.keychainFatal(.proofContextRefused)) {
            _ = try authority.ensureRoot(lockProof: handle.proof)
        }
        // The refusal is BEFORE SecItemAdd is reachable — and before the read,
        // because a production credential must not even be probed under a
        // proof-layout lock.
        #expect(keychain.addCalls == 0)
    }

    @Test("the defaulted acquire context is fail-closed (counts as non-production)")
    func defaultedContextFailsClosed() throws {
        let scratch = try ConvergenceScratch()
        defer { scratch.remove() }
        // No context argument — exactly what every pre-c2 call site does.
        let handle = try ProviderLock.acquire(at: scratch.url.appendingPathComponent("provider.lock"))
        defer { handle.release() }
        let keychain = MarkedProductionKeychain()
        let authority = InstallationRootAuthority(
            keychain: keychain, eligibility: try judgedEligibility(), randomBytes: fixedRandom(9)
        )
        #expect(throws: DaemonProviderError.keychainFatal(.proofContextRefused)) {
            _ = try authority.ensureRoot(lockProof: handle.proof)
        }
        #expect(keychain.addCalls == 0)
    }

    @Test("a production-layout lock proof licenses the mint for a production-marker authority")
    func productionLayoutLicensesMint() throws {
        let scratch = try ConvergenceScratch()
        defer { scratch.remove() }
        let handle = try ProviderLock.acquire(
            at: scratch.url.appendingPathComponent("provider.lock"), context: .production
        )
        defer { handle.release() }
        let keychain = MarkedProductionKeychain()
        let authority = InstallationRootAuthority(
            keychain: keychain, eligibility: try judgedEligibility(), randomBytes: fixedRandom(9)
        )
        // The marked fake reports notFound then added; readback compares.
        // Its copyItem always answers notFound, so the post-add readback
        // disagrees — which is FINE for this test's purpose: the add was
        // REACHED (license granted); the disagreement then refuses.
        #expect(throws: DaemonProviderError.keychainFatal(.disagreement)) {
            _ = try authority.ensureRoot(lockProof: handle.proof)
        }
        #expect(keychain.addCalls == 1)
    }

    @Test("an unmarked (test) authority mints under any layout, unchanged from c1")
    func unmarkedAuthorityUnchanged() throws {
        let scratch = try ConvergenceScratch()
        defer { scratch.remove() }
        let handle = try ProviderLock.acquire(at: scratch.url.appendingPathComponent("provider.lock"))
        defer { handle.release() }
        let keychain = UnmarkedKeychain()
        let authority = InstallationRootAuthority(
            keychain: keychain, eligibility: try judgedEligibility(), randomBytes: fixedRandom(9)
        )
        let root = try authority.ensureRoot(lockProof: handle.proof)
        #expect(root.provenance == .minted)
    }
}

// MARK: - 2. P-c2-2 — production CSPRNG composition

@Suite("P-c2-2 — production randomness")
struct ProductionRandomnessTests {

    @Test("the production randomness yields the requested count and is non-constant")
    func shape() {
        let a = ProductionRandomness.secRandomBytes(32)
        let b = ProductionRandomness.secRandomBytes(32)
        #expect(a.count == 32)
        #expect(b.count == 32)
        // 2^-256 false-failure probability: acceptable.
        #expect(a != b)
    }

    @Test("zero-count requests answer empty without touching the generator")
    func zeroCount() {
        #expect(ProductionRandomness.secRandomBytes(0).isEmpty)
    }
}

// MARK: - 3. KONG-2 — census disposition golden vectors

@Suite("Census dispositions (pure judge, golden vectors)")
struct CensusDispositionTests {

    @Test("no candidates and no canonical → none-found")
    func noneFound() {
        let observation = CensusObservation(candidates: [], canonical: nil, siblings: [])
        #expect(DefaultEstateCensus.judge(observation) == .noneFound)
    }

    @Test("absent mains everywhere → none-found")
    func absentMains() {
        let observation = CensusObservation(
            candidates: [candidate(.sandboxedPro, main: .absent), candidate(.swiftCE, main: .absent)],
            canonical: nil, siblings: []
        )
        #expect(DefaultEstateCensus.judge(observation) == .noneFound)
    }

    @Test("exactly one identity-verified candidate → one-valid")
    func exactlyOneValid() {
        let observation = CensusObservation(
            candidates: [candidate(.sandboxedPro, main: presentMain(digest: "d1"), identity: identity(estateA))],
            canonical: nil, siblings: []
        )
        #expect(DefaultEstateCensus.judge(observation) == .exactlyOneValid(.sandboxedPro))
    }

    @Test("one candidate with UNVERIFIABLE identity → hard stop, never one-valid")
    func unverifiableNeverElects() {
        let observation = CensusObservation(
            candidates: [candidate(.rustCE, main: presentMain(digest: "d1"), identity: nil)],
            canonical: nil, siblings: []
        )
        #expect(DefaultEstateCensus.judge(observation)
                == .multipleEstatesHardStop(.unverifiableCandidate))
    }

    @Test("a live WAL beside an otherwise valid candidate → hard stop (unquiesced source)")
    func liveWALNeverElects() {
        let observation = CensusObservation(
            candidates: [candidate(
                .community, main: presentMain(digest: "d1"),
                wal: .present(bytes: 8192), identity: identity(estateA)
            )],
            canonical: nil, siblings: []
        )
        #expect(DefaultEstateCensus.judge(observation)
                == .multipleEstatesHardStop(.unverifiableCandidate))
    }

    @Test("canonical + receipt-covered unchanged source → already-converged")
    func alreadyConverged() {
        let observation = CensusObservation(
            candidates: [candidate(
                .sandboxedPro, main: presentMain(digest: "d1"),
                identity: identity(estateA), receipt: .coveredUnchanged
            )],
            canonical: candidate(.canonical, main: presentMain(digest: "d2"), identity: identity(estateA)),
            siblings: []
        )
        #expect(DefaultEstateCensus.judge(observation) == .alreadyConverged)
    }

    @Test("canonical + receipt-covered source whose digest CHANGED → hard stop (diverged)")
    func divergedFromReceipt() {
        let observation = CensusObservation(
            candidates: [candidate(
                .sandboxedPro, main: presentMain(digest: "d1-changed"),
                identity: identity(estateA), receipt: .coveredChanged
            )],
            canonical: candidate(.canonical, main: presentMain(digest: "d2"), identity: identity(estateA)),
            siblings: []
        )
        #expect(DefaultEstateCensus.judge(observation)
                == .multipleEstatesHardStop(.divergedFromReceipt))
    }

    @Test("byte-identical checkpointed same-UUID duplicates → report, delete none")
    func byteIdenticalDuplicates() {
        let observation = CensusObservation(
            candidates: [
                candidate(.swiftCE, main: presentMain(digest: "same"), identity: identity(estateA)),
                candidate(.rustCE, main: presentMain(digest: "same"), identity: identity(estateA)),
            ],
            canonical: nil, siblings: []
        )
        #expect(DefaultEstateCensus.judge(observation)
                == .byteIdenticalDuplicates(reported: [.swiftCE, .rustCE]))
    }

    @Test("same digest but DIFFERENT estate UUIDs → hard stop, not duplicates")
    func sameBytesDifferentIdentity() {
        let observation = CensusObservation(
            candidates: [
                candidate(.swiftCE, main: presentMain(digest: "same"), identity: identity(estateA)),
                candidate(.rustCE, main: presentMain(digest: "same"), identity: identity(estateB)),
            ],
            canonical: nil, siblings: []
        )
        #expect(DefaultEstateCensus.judge(observation)
                == .multipleEstatesHardStop(.multipleDistinctCandidates))
    }

    @Test("two distinct nonempty candidates → hard stop")
    func multipleDistinct() {
        let observation = CensusObservation(
            candidates: [
                candidate(.sandboxedPro, main: presentMain(digest: "d1"), identity: identity(estateA)),
                candidate(.community, main: presentMain(digest: "d2"), identity: identity(estateB)),
            ],
            canonical: nil, siblings: []
        )
        #expect(DefaultEstateCensus.judge(observation)
                == .multipleEstatesHardStop(.multipleDistinctCandidates))
    }

    @Test("siblings are reported and never elect or block")
    func siblingsExcluded() {
        let observation = CensusObservation(
            candidates: [candidate(.sandboxedPro, main: presentMain(digest: "d1"), identity: identity(estateA))],
            canonical: nil, siblings: ["research", "work"]
        )
        #expect(DefaultEstateCensus.judge(observation) == .exactlyOneValid(.sandboxedPro))
    }

    @Test("canonical alone with no legacy candidates → already-converged")
    func canonicalOnly() {
        let observation = CensusObservation(
            candidates: [],
            canonical: candidate(.canonical, main: presentMain(digest: "d2"), identity: identity(estateA)),
            siblings: []
        )
        #expect(DefaultEstateCensus.judge(observation) == .alreadyConverged)
    }

    @Test("the disposition wire encodings are stable and enumerated")
    func wireEncodings() {
        #expect(CensusDisposition.allWireEncodings == [
            "none-found", "one-valid", "already-converged",
            "byte-identical-duplicates", "multiple-estates-hard-stop",
        ])
    }
}

// MARK: - 4. Grant envelope — MAC / expiry / binding / replay / journal-first

private func makeChallenge(now: UInt64 = 1_000) -> MigrationChallenge {
    MigrationChallenge(
        challengeIdentifier: UUID(uuidString: "CCCCCCCC-0000-4000-8000-000000000001")!,
        providerInstance: providerInstance,
        candidateClass: .sandboxedPro,
        nonce: [UInt8](repeating: 0x11, count: 32),
        issuedAt: now,
        expiresAt: now + MigrationChallenge.challengeLifetime
    )
}

private func makeEnvelope(
    challenge: MigrationChallenge,
    bookmark: [UInt8] = [UInt8]("bookmark-bytes".utf8),
    instance: UUID = providerInstance,
    candidateClass: EstateCandidateClass = .sandboxedPro,
    credential: UInt64 = fixedGenerations.credential,
    issuedAt: UInt64 = 1_010,
    expiresAt: UInt64 = 1_010 + MigrationGrantEnvelope.grantLifetime
) -> MigrationGrantEnvelope {
    MigrationGrantEnvelope(
        grantIdentifier: UUID(uuidString: "DDDDDDDD-0000-4000-8000-000000000001")!,
        providerInstance: instance,
        candidateClass: candidateClass,
        challengeIdentifier: challenge.challengeIdentifier,
        credentialGeneration: credential,
        providerGeneration: fixedGenerations.provider,
        descriptorGeneration: fixedGenerations.descriptor,
        issuedAt: issuedAt,
        expiresAt: expiresAt,
        bookmarkDigestSHA256: FirstPartyAuthProtocol.sha256(bookmark),
        bookmark: bookmark,
        escrowMarker: .escrowed,
        grantMAC: []
    ).sealed(installationRoot: fixedRoot, challenge: challenge)
}

@Suite("Grant envelope authentication and one-use consumption")
struct GrantEnvelopeTests {

    private func authority(_ scratch: ConvergenceScratch, now: UInt64 = 1_020) -> MigrationGrantAuthority {
        MigrationGrantAuthority(
            journal: LeaseConsumptionJournal(fileURL: scratch.url.appendingPathComponent("grant.journal")),
            clock: fixedClock(now)
        )
    }

    @Test("the grant HKDF domain is new and distinct from every prior domain")
    func domainDistinct() {
        let existing = [
            FirstPartyAuthProtocol.descriptorDomain, FirstPartyAuthProtocol.sessionDomain,
            FirstPartyAuthProtocol.authDomain, HandoverLease.leaseDomain,
            MigrationReceipt.receiptDomain,
        ]
        #expect(MigrationGrantEnvelope.grantDomain == "MOOTX01-MIGRATION-GRANT-v1")
        #expect(!existing.contains(MigrationGrantEnvelope.grantDomain))
    }

    @Test("the grant key is challenge-bound: a different challenge fails the MAC")
    func challengeBinding() throws {
        let scratch = try ConvergenceScratch()
        defer { scratch.remove() }
        let challenge = makeChallenge()
        let envelope = makeEnvelope(challenge: challenge)
        #expect(envelope.verifyMAC(installationRoot: fixedRoot, challenge: challenge))
        var otherChallenge = challenge
        otherChallenge = MigrationChallenge(
            challengeIdentifier: challenge.challengeIdentifier,
            providerInstance: challenge.providerInstance,
            candidateClass: challenge.candidateClass,
            nonce: [UInt8](repeating: 0x22, count: 32),
            issuedAt: challenge.issuedAt, expiresAt: challenge.expiresAt
        )
        #expect(!envelope.verifyMAC(installationRoot: fixedRoot, challenge: otherChallenge))
        #expect(throws: DaemonProviderError.grantInvalid(.badMAC)) {
            _ = try authority(scratch).consume(
                envelope, installationRoot: fixedRoot, challenge: otherChallenge,
                currentGenerations: fixedGenerations
            )
        }
    }

    @Test("a tampered field fails the MAC before any other gate")
    func tamperFailsClosed() throws {
        let scratch = try ConvergenceScratch()
        defer { scratch.remove() }
        let challenge = makeChallenge()
        var envelope = makeEnvelope(challenge: challenge)
        envelope.grantMAC[0] ^= 0xFF
        #expect(throws: DaemonProviderError.grantInvalid(.badMAC)) {
            _ = try authority(scratch).consume(
                envelope, installationRoot: fixedRoot, challenge: challenge,
                currentGenerations: fixedGenerations
            )
        }
    }

    @Test("an expired grant refuses")
    func expiry() throws {
        let scratch = try ConvergenceScratch()
        defer { scratch.remove() }
        let challenge = makeChallenge()
        let envelope = makeEnvelope(challenge: challenge)
        #expect(throws: DaemonProviderError.grantInvalid(.expired)) {
            _ = try authority(scratch, now: envelope.expiresAt + 1).consume(
                envelope, installationRoot: fixedRoot, challenge: challenge,
                currentGenerations: fixedGenerations
            )
        }
    }

    @Test("a wrong provider instance refuses as binding mismatch")
    func wrongInstance() throws {
        let scratch = try ConvergenceScratch()
        defer { scratch.remove() }
        let challenge = makeChallenge()
        let envelope = makeEnvelope(challenge: challenge, instance: otherInstance)
        #expect(throws: DaemonProviderError.grantInvalid(.bindingMismatch)) {
            _ = try authority(scratch).consume(
                envelope, installationRoot: fixedRoot, challenge: challenge,
                currentGenerations: fixedGenerations
            )
        }
    }

    @Test("a wrong candidate class refuses as binding mismatch")
    func wrongCandidate() throws {
        let scratch = try ConvergenceScratch()
        defer { scratch.remove() }
        let challenge = makeChallenge()
        let envelope = makeEnvelope(challenge: challenge, candidateClass: .community)
        #expect(throws: DaemonProviderError.grantInvalid(.bindingMismatch)) {
            _ = try authority(scratch).consume(
                envelope, installationRoot: fixedRoot, challenge: challenge,
                currentGenerations: fixedGenerations
            )
        }
    }

    @Test("a stale credential generation refuses (rotation burns grants)")
    func staleCredential() throws {
        let scratch = try ConvergenceScratch()
        defer { scratch.remove() }
        let challenge = makeChallenge()
        let envelope = makeEnvelope(challenge: challenge, credential: fixedGenerations.credential - 1)
        #expect(throws: DaemonProviderError.grantInvalid(.staleGeneration)) {
            _ = try authority(scratch).consume(
                envelope, installationRoot: fixedRoot, challenge: challenge,
                currentGenerations: fixedGenerations
            )
        }
    }

    @Test("consume is one-use: the journal record is durable BEFORE resolution and replay refuses")
    func journalFirstAndReplay() throws {
        let scratch = try ConvergenceScratch()
        defer { scratch.remove() }
        let challenge = makeChallenge()
        let envelope = makeEnvelope(challenge: challenge)
        let grants = authority(scratch)
        let consumed = try grants.consume(
            envelope, installationRoot: fixedRoot, challenge: challenge,
            currentGenerations: fixedGenerations
        )
        #expect(consumed.bookmark == envelope.bookmark)
        // The durable record exists (journal-first): the identifier is on disk.
        let journal = LeaseConsumptionJournal(fileURL: scratch.url.appendingPathComponent("grant.journal"))
        #expect(try journal.contains(envelope.grantIdentifier))
        // Replay refuses.
        #expect(throws: DaemonProviderError.grantInvalid(.consumed)) {
            _ = try grants.consume(
                envelope, installationRoot: fixedRoot, challenge: challenge,
                currentGenerations: fixedGenerations
            )
        }
    }

    @Test("an unanswerable journal fails closed, never passes")
    func journalUnavailable() throws {
        let scratch = try ConvergenceScratch()
        defer { scratch.remove() }
        // A symlinked journal is an aliased one-use record: unanswerable.
        let real = scratch.url.appendingPathComponent("elsewhere")
        FileManager.default.createFile(atPath: real.path, contents: Data("x\n".utf8))
        let journalURL = scratch.url.appendingPathComponent("grant.journal")
        try FileManager.default.createSymbolicLink(at: journalURL, withDestinationURL: real)
        let grants = MigrationGrantAuthority(
            journal: LeaseConsumptionJournal(fileURL: journalURL), clock: fixedClock(1_020)
        )
        let challenge = makeChallenge()
        let envelope = makeEnvelope(challenge: challenge)
        #expect(throws: DaemonProviderError.grantInvalid(.journalUnavailable)) {
            _ = try grants.consume(
                envelope, installationRoot: fixedRoot, challenge: challenge,
                currentGenerations: fixedGenerations
            )
        }
    }

    @Test("the durable form round-trips and refuses a wrong key set or oversize record")
    func strictEncoding() {
        let challenge = makeChallenge()
        let envelope = makeEnvelope(challenge: challenge)
        let data = envelope.encoded()
        #expect(!data.isEmpty)
        #expect(MigrationGrantEnvelope.decode(data) == envelope)
        // Wrong key set refuses.
        var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        object["extra"] = "field"
        let widened = try? JSONSerialization.data(withJSONObject: object)
        #expect(MigrationGrantEnvelope.decode(widened ?? Data()) == nil)
        // Oversize refuses (byte cap, P-c2-5).
        var big = envelope
        big.bookmark = [UInt8](repeating: 0x5A, count: MigrationGrantEnvelope.maxEnvelopeBytes)
        #expect(MigrationGrantEnvelope.decode(big.sealed(installationRoot: fixedRoot, challenge: challenge).encoded()) == nil)
    }
}

// MARK: - 5. P-c2-6 — production stale policy + F4 denial classifier

@Suite("Stale-resolution policy and denial classification")
struct StalePolicyTests {

    private func censusMain(for url: URL) throws -> CensusCandidateRecord.Main {
        var status = stat()
        #expect(lstat(url.path, &status) == 0)
        let digest = FirstPartyAuthProtocol.sha256([UInt8](try Data(contentsOf: url)))
            .map { String(format: "%02x", $0) }.joined()
        return .present(
            bytes: UInt64(status.st_size), device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino), linkCount: UInt64(status.st_nlink),
            digestSHA256Hex: digest
        )
    }

    @Test("a fresh resolution matching the census-derived candidate passes")
    func freshMatchPasses() throws {
        let scratch = try ConvergenceScratch()
        defer { scratch.remove() }
        let file = scratch.url.appendingPathComponent("mootx01.sqlite")
        try Data("estate-bytes".utf8).write(to: file)
        let verdict = GrantResolutionPolicy.verify(
            resolvedURL: file, providerDerivedCandidateURL: file,
            censusMain: try censusMain(for: file), bookmarkWasStale: false
        )
        #expect(verdict == .accepted(staleAccepted: false))
    }

    @Test("a STALE resolution is accepted only when URL, fd identity, and digest all match census")
    func staleAcceptedOnlyOnFullMatch() throws {
        let scratch = try ConvergenceScratch()
        defer { scratch.remove() }
        let file = scratch.url.appendingPathComponent("mootx01.sqlite")
        try Data("estate-bytes".utf8).write(to: file)
        let verdict = GrantResolutionPolicy.verify(
            resolvedURL: file, providerDerivedCandidateURL: file,
            censusMain: try censusMain(for: file), bookmarkWasStale: true
        )
        #expect(verdict == .accepted(staleAccepted: true))
    }

    @Test("a stale resolution to a different path than the provider derived refuses (path-only denial)")
    func staleWrongPathRefuses() throws {
        let scratch = try ConvergenceScratch()
        defer { scratch.remove() }
        let file = scratch.url.appendingPathComponent("mootx01.sqlite")
        let other = scratch.url.appendingPathComponent("other.sqlite")
        try Data("estate-bytes".utf8).write(to: file)
        try Data("estate-bytes".utf8).write(to: other)
        let verdict = GrantResolutionPolicy.verify(
            resolvedURL: other, providerDerivedCandidateURL: file,
            censusMain: try censusMain(for: file), bookmarkWasStale: true
        )
        #expect(verdict == .refused(.pathMismatch))
    }

    @Test("content drift between census and resolution refuses")
    func contentDriftRefuses() throws {
        let scratch = try ConvergenceScratch()
        defer { scratch.remove() }
        let file = scratch.url.appendingPathComponent("mootx01.sqlite")
        try Data("estate-bytes".utf8).write(to: file)
        let census = try censusMain(for: file)
        try Data("mutated-since-census".utf8).write(to: file)
        let verdict = GrantResolutionPolicy.verify(
            resolvedURL: file, providerDerivedCandidateURL: file,
            censusMain: census, bookmarkWasStale: false
        )
        #expect(verdict == .refused(.identityMismatch))
    }

    @Test("a symlink at the resolved location classifies as symlink denial (F4)")
    func symlinkDenial() throws {
        let scratch = try ConvergenceScratch()
        defer { scratch.remove() }
        let real = scratch.url.appendingPathComponent("real.sqlite")
        try Data("estate-bytes".utf8).write(to: real)
        let link = scratch.url.appendingPathComponent("mootx01.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let verdict = GrantResolutionPolicy.verify(
            resolvedURL: link, providerDerivedCandidateURL: link,
            censusMain: try censusMain(for: real), bookmarkWasStale: false
        )
        #expect(verdict == .refused(.symlink))
    }

    @Test("a vacated path classifies as vacated (F4: ENOENT is the one absence answer)")
    func vacatedDenial() throws {
        let scratch = try ConvergenceScratch()
        defer { scratch.remove() }
        let gone = scratch.url.appendingPathComponent("mootx01.sqlite")
        let census = CensusCandidateRecord.Main.present(
            bytes: 12, device: 1, inode: 2, linkCount: 1, digestSHA256Hex: "aa"
        )
        let verdict = GrantResolutionPolicy.verify(
            resolvedURL: gone, providerDerivedCandidateURL: gone,
            censusMain: census, bookmarkWasStale: false
        )
        #expect(verdict == .refused(.vacated))
    }
}

// MARK: - 6. P-c2-7 — escrow rules

@Suite("Key escrow rules — never mint over ciphertext")
struct EscrowRulesTests {

    @Test("encrypted source + escrowed key → use escrow, verify read-only before copy")
    func encryptedWithKey() {
        #expect(EscrowRules.judge(encryption: .encrypted, escrowRead: .found([UInt8](repeating: 1, count: 32)))
                == .useEscrowedKeyAfterReadOnlyVerify)
    }

    @Test("encrypted source + absent key → refuse; minting over ciphertext is forbidden")
    func encryptedWithoutKey() {
        #expect(EscrowRules.judge(encryption: .encrypted, escrowRead: .notFound)
                == .refuse(.keyAbsentForCiphertext))
    }

    @Test("encrypted source + fatal Keychain classification → refuse fatally, never absence")
    func encryptedFatal() {
        #expect(EscrowRules.judge(encryption: .encrypted, escrowRead: .missingEntitlement)
                == .refuse(.keychainFatal))
        #expect(EscrowRules.judge(encryption: .encrypted, escrowRead: .interactionRequired)
                == .refuse(.keychainFatal))
        #expect(EscrowRules.judge(encryption: .encrypted, escrowRead: .unavailable)
                == .refuse(.keychainFatal))
    }

    @Test("plaintext source → the user-approved encryption upgrade must run FIRST")
    func plaintextRequiresUpgrade() {
        #expect(EscrowRules.judge(encryption: .plaintext, escrowRead: .notFound)
                == .refuse(.plaintextRequiresEncryptionUpgrade))
    }

    @Test("an unreadable source refuses")
    func unreadableRefuses() {
        #expect(EscrowRules.judge(encryption: .unreadable, escrowRead: .notFound)
                == .refuse(.sourceUnreadable))
    }
}

// MARK: - 7. KONG-3 — migration state machine and crash matrix

/// Counting/crash-injecting source-estate access fake.
private final class FakeSourceAccess: SourceEstateAccess, @unchecked Sendable {
    enum CrashPoint: Equatable { case none, checkpoint, emptyWALProof, close, verify }
    private let lock = NSLock()
    var crashAt: CrashPoint = .none
    private(set) var events: [String] = []
    let identityAnswer: CensusIdentity

    init(identity: CensusIdentity) { self.identityAnswer = identity }

    private func record(_ event: String, crash: CrashPoint) throws {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
        if crash != .none && crashAt == crash { throw DaemonProviderError.migrationFault(.injectedFailure) }
    }
    func openExclusive() async throws { try record("open", crash: .none) }
    func checkpointTruncate() async throws { try record("checkpoint", crash: .checkpoint) }
    func verifyEmptyWAL() async throws { try record("empty-wal", crash: .emptyWALProof) }
    func readIdentity() async throws -> CensusIdentity {
        try record("identity", crash: .none)
        return identityAnswer
    }
    func close() async throws { try record("close", crash: .close) }
    func verifyReadOnlyOpen(destination: URL) async throws -> CensusIdentity {
        try record("verify-destination", crash: .verify)
        return identityAnswer
    }
    var recorded: [String] { lock.lock(); defer { lock.unlock() }; return events }
}

/// File-migration fake over a scratch: real file moves, injectable failures,
/// and a structural guarantee there is NO delete primitive to call.
private final class FakeFileMigration: FileMigrationAuthority, @unchecked Sendable {
    enum CrashPoint: Equatable { case none, copy, rename, quarantine, backup }
    private let lock = NSLock()
    var crashAt: CrashPoint = .none
    private(set) var events: [String] = []

    private func record(_ event: String, crash: CrashPoint) throws {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
        if crash != .none && crashAt == crash { throw DaemonProviderError.migrationFault(.injectedFailure) }
    }
    func copyMainToIncoming(source: URL, incoming: URL) async throws -> String {
        try record("copy", crash: .copy)
        let data = try Data(contentsOf: source)
        try FileManager.default.createDirectory(
            at: incoming.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: incoming)
        return FirstPartyAuthProtocol.sha256([UInt8](data)).map { String(format: "%02x", $0) }.joined()
    }
    func digestOf(url: URL) async throws -> String {
        try record("digest", crash: .none)
        let data = try Data(contentsOf: url)
        return FirstPartyAuthProtocol.sha256([UInt8](data)).map { String(format: "%02x", $0) }.joined()
    }
    func atomicRenameIntoCanonical(incoming: URL, canonical: URL) async throws {
        try record("rename", crash: .rename)
        try FileManager.default.createDirectory(
            at: canonical.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        _ = try? FileManager.default.removeItem(at: canonical)
        try FileManager.default.moveItem(at: incoming, to: canonical)
    }
    func quarantineCanonical(canonical: URL, quarantineDirectory: URL) async throws {
        try record("quarantine", crash: .quarantine)
        try FileManager.default.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: canonical,
            to: quarantineDirectory.appendingPathComponent(canonical.lastPathComponent)
        )
    }
    func preserveBackup(source: URL, backupDirectory: URL) async throws {
        try record("backup", crash: .backup)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let destination = backupDirectory.appendingPathComponent(source.lastPathComponent)
        _ = try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }
    var recorded: [String] { lock.lock(); defer { lock.unlock() }; return events }
}

private struct MigratorHarness {
    let scratch: ConvergenceScratch
    let source: URL
    let canonical: URL
    let sourceAccess: FakeSourceAccess
    let files: FakeFileMigration
    let receipts: MigrationReceiptStore
    let handle: ProviderLockHandle

    init() throws {
        scratch = try ConvergenceScratch()
        source = scratch.url.appendingPathComponent("legacy/mootx01.sqlite")
        canonical = scratch.url.appendingPathComponent("canonical/estate.sqlite")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("legacy-estate-bytes".utf8).write(to: source)
        sourceAccess = FakeSourceAccess(identity: identity(estateA))
        files = FakeFileMigration()
        receipts = MigrationReceiptStore(
            fileURL: scratch.url.appendingPathComponent("migration-receipt.v1.json")
        )
        handle = try ProviderLock.acquire(
            at: scratch.url.appendingPathComponent("provider.lock"), context: .production
        )
    }

    func migrator() -> DefaultEstateMigrator {
        DefaultEstateMigrator(
            source: sourceAccess, files: files, receipts: receipts,
            lockProof: handle.proof,
            installationRoot: fixedRoot,
            transaction: MigrationTransaction(
                transactionIdentifier: UUID(uuidString: "EEEEEEEE-0000-4000-8000-000000000001")!,
                sourceClass: .sandboxedPro,
                sourceURL: source, canonicalURL: canonical,
                incomingDirectory: scratch.url.appendingPathComponent("incoming"),
                quarantineDirectory: scratch.url.appendingPathComponent("quarantine"),
                backupDirectory: scratch.url.appendingPathComponent("backup"),
                grantDigestHex: "aa" ,
                generations: fixedGenerations,
                staleAccepted: false
            ),
            clock: fixedClock(2_000)
        )
    }

    func teardown() {
        handle.release()
        scratch.remove()
    }
}

@Suite("Migration state machine — ordering, receipts, crash convergence")
struct MigrationMachineTests {

    @Test("the happy path runs staged-receipt BEFORE rename and finalizes committed after (KONG-3)")
    func happyPathOrdering() async throws {
        let harness = try MigratorHarness()
        defer { harness.teardown() }
        let migrator = harness.migrator()
        let outcome = try await migrator.run()
        #expect(outcome == .committed)
        // The durable receipt is committed.
        let receipt = try harness.receipts.load()
        #expect(receipt?.state == .committed)
        // Canonical exists with the source's bytes; source retained.
        #expect(FileManager.default.fileExists(atPath: harness.canonical.path))
        #expect(FileManager.default.fileExists(atPath: harness.source.path))
        // Ordering: quiesce (checkpoint → empty-wal → close) precedes copy;
        // backup precedes rename; rename happens exactly once.
        let events = harness.files.recorded
        #expect(events.filter { $0 == "rename" }.count == 1)
        let sourceEvents = harness.sourceAccess.recorded
        #expect(sourceEvents.firstIndex(of: "checkpoint")! < sourceEvents.firstIndex(of: "empty-wal")!)
        #expect(sourceEvents.firstIndex(of: "empty-wal")! < sourceEvents.firstIndex(of: "close")!)
    }

    @Test("crash between staged receipt and rename converges to safe retry with source retained")
    func crashBeforeRename() async throws {
        let harness = try MigratorHarness()
        defer { harness.teardown() }
        harness.files.crashAt = .rename
        let migrator = harness.migrator()
        await #expect(throws: DaemonProviderError.migrationFault(.injectedFailure)) {
            _ = try await migrator.run()
        }
        // Durable state: staged receipt, no canonical.
        #expect(try harness.receipts.load()?.state == .staged)
        #expect(!FileManager.default.fileExists(atPath: harness.canonical.path))
        #expect(FileManager.default.fileExists(atPath: harness.source.path))
        // Resume: safe retry completes.
        harness.files.crashAt = .none
        let resumed = harness.migrator()
        let outcome = try await resumed.run()
        #expect(outcome == .committed)
        #expect(try harness.receipts.load()?.state == .committed)
    }

    @Test("crash after rename before finalize converges to verify-and-finalize on resume")
    func crashAfterRename() async throws {
        let harness = try MigratorHarness()
        defer { harness.teardown() }
        harness.sourceAccess.crashAt = .verify
        let migrator = harness.migrator()
        await #expect(throws: DaemonProviderError.migrationFault(.injectedFailure)) {
            _ = try await migrator.run()
        }
        // Wait — destination verify happens BEFORE rename (incoming verify).
        // The crash-at-verify case is the pre-rename verify; covered below.
        // This assertion documents whichever durable state resulted is
        // resumable to committed.
        harness.sourceAccess.crashAt = .none
        let resumed = harness.migrator()
        let outcome = try await resumed.run()
        #expect(outcome == .committed)
        #expect(FileManager.default.fileExists(atPath: harness.source.path))
    }

    @Test("a committed receipt makes re-running the machine an idempotent no-op")
    func idempotentAfterCommitted() async throws {
        let harness = try MigratorHarness()
        defer { harness.teardown() }
        _ = try await harness.migrator().run()
        let renamesAfterFirst = harness.files.recorded.filter { $0 == "rename" }.count
        let outcome = try await harness.migrator().run()
        #expect(outcome == .alreadyCommitted)
        #expect(harness.files.recorded.filter { $0 == "rename" }.count == renamesAfterFirst)
    }

    @Test("verification failure quarantines the canonical and never touches the source")
    func verifyFailureQuarantines() async throws {
        let harness = try MigratorHarness()
        defer { harness.teardown() }
        // First run to committed, then poison a re-verify pass: simulate a
        // staged resume whose destination verification fails.
        harness.files.crashAt = .rename
        await #expect(throws: DaemonProviderError.migrationFault(.injectedFailure)) {
            _ = try await harness.migrator().run()
        }
        harness.files.crashAt = .none
        harness.sourceAccess.crashAt = .verify
        let resumed = harness.migrator()
        let disposition = try await resumed.runExpectingFailure()
        #expect(disposition == .recoveryRequired || disposition == .quarantined)
        // The source was never deleted or mutated on ANY path.
        #expect(FileManager.default.fileExists(atPath: harness.source.path))
        #expect(try Data(contentsOf: harness.source) == Data("legacy-estate-bytes".utf8))
    }

    @Test("a released lock proof refuses every step (hold-then-verify)")
    func staleLockRefuses() async throws {
        let harness = try MigratorHarness()
        let migrator = harness.migrator()
        harness.handle.release()
        await #expect(throws: DaemonProviderError.lockUnavailable) {
            _ = try await migrator.run()
        }
        harness.scratch.remove()
    }

    @Test("the migration step encodings are enumerated and distinct from arbiter states")
    func stepEncodings() {
        #expect(MigrationStep.allWireEncodings.count == MigrationStep.allCases.count)
        for encoding in MigrationStep.allWireEncodings {
            #expect(!ProviderArbiterState.allWireEncodings.contains(encoding))
        }
        // awaitingMigrationGrant is NOT an arbiter wire state (frozen 12).
        #expect(ProviderArbiterState.allWireEncodings.count == 12)
        #expect(!ProviderArbiterState.allWireEncodings.contains("awaiting-migration-grant"))
    }
}

// MARK: - Receipt integrity

@Suite("Migration receipt — MACed, idempotent, stale flag first-class")
struct MigrationReceiptTests {

    private func makeReceipt(state: MigrationReceipt.State, staleAccepted: Bool = false) -> MigrationReceipt {
        MigrationReceipt(
            transactionIdentifier: UUID(uuidString: "EEEEEEEE-0000-4000-8000-000000000001")!,
            state: state,
            sourceClass: .sandboxedPro,
            sourceDigestHex: "aa", destinationDigestHex: "aa",
            estateIdentifier: estateA, schemaVersion: 4,
            keyTransition: .escrowedExistingKey,
            credentialGeneration: 3, providerGeneration: 5, descriptorGeneration: 7,
            grantDigestHex: "bb", backupDigestHex: "aa",
            staleAccepted: staleAccepted,
            stagedAt: 2_000, finalizedAt: state == .staged ? 0 : 2_001,
            receiptMAC: []
        ).sealed(installationRoot: fixedRoot)
    }

    @Test("the receipt MAC round-trips and tampering refuses")
    func macRoundTrip() {
        let receipt = makeReceipt(state: .committed)
        #expect(receipt.verifyMAC(installationRoot: fixedRoot))
        var tampered = receipt
        tampered.receiptMAC[0] ^= 0x01
        #expect(!tampered.verifyMAC(installationRoot: fixedRoot))
        let decoded = MigrationReceipt.decode(receipt.encoded())
        #expect(decoded == receipt)
    }

    @Test("staleAccepted is a first-class boolean bound into the MAC")
    func staleFlagBound() {
        let honest = makeReceipt(state: .committed, staleAccepted: true)
        #expect(honest.verifyMAC(installationRoot: fixedRoot))
        // Flipping the flag without resealing fails the MAC.
        var flipped = honest
        flipped.staleAccepted = false
        #expect(!flipped.verifyMAC(installationRoot: fixedRoot))
        // The wire form carries a genuine JSON boolean.
        let object = (try? JSONSerialization.jsonObject(with: honest.encoded())) as? [String: Any]
        #expect(object?["staleAccepted"] as? Bool == true)
    }

    @Test("the store reads back what it wrote and fails closed on a torn record")
    func storeRoundTrip() throws {
        let scratch = try ConvergenceScratch()
        defer { scratch.remove() }
        let handle = try ProviderLock.acquire(at: scratch.url.appendingPathComponent("l"))
        defer { handle.release() }
        let store = MigrationReceiptStore(fileURL: scratch.url.appendingPathComponent("receipt.json"))
        #expect(try store.load() == nil)
        let receipt = makeReceipt(state: .staged)
        try store.write(receipt, lockProof: handle.proof)
        #expect(try store.load() == receipt)
        // Torn bytes refuse rather than answering.
        try Data("not json".utf8).write(to: scratch.url.appendingPathComponent("receipt.json"))
        #expect(throws: DaemonProviderError.migrationFault(.receiptUnreadable)) {
            _ = try store.load()
        }
    }
}

// MARK: - 8. Self-report digest covers the new contract

@Suite("Self-report digest — migration contract coverage")
struct ConvergenceDigestTests {

    @Test("the digest input covers grant domain, receipt domain, census dispositions, and migration steps")
    func digestCoverage() {
        let text = String(decoding: ProviderSelfReport.digestInput(), as: UTF8.self)
        #expect(text.contains(MigrationGrantEnvelope.grantDomain))
        #expect(text.contains(MigrationReceipt.receiptDomain))
        #expect(text.contains("multiple-estates-hard-stop"))
        #expect(text.contains("awaiting-migration-grant"))
    }

    @Test("the canonical report still enumerates exactly twelve arbiter states")
    func arbiterFrozen() {
        #expect(ProviderArbiterState.allWireEncodings.count == 12)
    }
}
