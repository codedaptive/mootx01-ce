import ConvergenceKit
import ConvergenceKitAppleSecurity
import CryptoKit
import Foundation
import Testing

@Suite("SecretSync cross-provider golden vectors")
struct SecretSyncCrossProviderGoldenVectorTests {
  @Test("public digest provider matches SHA-256 and the frozen U2 vector")
  func digestVector() throws {
    let provider = try SecretSyncSHA256DigestProvider(suite: U7GoldenVectors.suite())
    let digest = try provider.digest(canonicalBytes: U7GoldenVectors.digestInput)

    #expect(digest.bytes == U7GoldenVectors.digestOutput)
    #expect(digest.bytes == Data(SHA256.hash(data: U7GoldenVectors.digestInput)))
  }

  @Test("public signature provider accepts the frozen raw64 low-S vector")
  func signatureVector() throws {
    let provider = try SecretSyncP256SignatureProvider(suite: U7GoldenVectors.suite())

    #expect(
      try provider.verify(
        signature: U7GoldenVectors.lowSRawSignature,
        canonicalBytes: U7GoldenVectors.signatureMessage,
        signingPublicKey: U7GoldenVectors.signingDescriptor()
      )
    )
  }

  @Test("routine and recovery U2 HPKE vectors open one usable generation key")
  func hpkeVectors() throws {
    let suite = try U7GoldenVectors.suite()
    let hpke = try SecretSyncHPKEEnvelopeProvider(suite: suite)
    let aes = try SecretSyncAESGCMProvider(suite: suite)
    let recipientKey = try hpke.openRecipientGenerationKey(
      U7GoldenVectors.recipientWrappedKey,
      using: P256.KeyAgreement.PrivateKey(
        rawRepresentation: U7GoldenVectors.recipientPrivateKeyBytes
      ),
      context: U7GoldenVectors.recipientContext()
    )
    let recoveryKey = try hpke.openRecoveryGenerationKey(
      U7GoldenVectors.recoveryWrappedKey,
      using: P256.KeyAgreement.PrivateKey(
        rawRepresentation: U7GoldenVectors.recoveryPrivateKeyBytes
      ),
      context: U7GoldenVectors.recoveryContext()
    )
    let plaintext = Data("u7-cross-provider-proof".utf8)
    let sealed = try aes.seal(
      plaintext: plaintext,
      using: recipientKey,
      context: U7GoldenVectors.boundContext()
    )

    #expect(
      try aes.open(
        sealedBytes: sealed,
        using: recoveryKey,
        context: U7GoldenVectors.boundContext()
      ) == plaintext
    )
  }
}

/// Frozen cross-provider bytes inherited from SECRET-UPSTREAM-U2-R1. U7A
/// consumes these verbatim as provenance-bearing compatibility fixtures; it
/// never regenerates them from the Apple implementation under test.
enum U7GoldenVectors {
  static let provenance = "SECRET-UPSTREAM-U2-R1/frozen-cross-provider-v1"
  static let scopeID = SecretScopeID(
    UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
  )
  static let generationID = SecretGenerationID(
    UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
  )
  static let recipientCredentialID = DeviceCredentialID(
    UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
  )
  static let recoveryRecipientID = UUID(
    uuidString: "99999999-8888-7777-6666-555555555555"
  )!
  static let snapshotDigest = try! SecretRecordDigest(bytes: Data(0x00...0x1f))
  static let policyDigest = try! SecretRecordDigest(bytes: Data(0x20...0x3f))

  static let recipientPrivateKeyBytes = data(
    "0000000000000000000000000000000000000000000000000000000000000001"
  )
  static let recipientPublicKeyBytes = data(
    "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"
  )
  static let recipientWrappedKey = data(
    "04a000e65f42f8f318280803dc7cda6b856a6260000e30159b144aec05c20d8f86466ae8fa31eac834d87f7e10c6b6b2ce96d7c1d35efca965332b9bda063684ca2b37ec6a587df1cdd2464e3b673bc54e549b2ef7ba9b89ca43ba97b799abeed104fb4f7d522ac01daa3c9507858fa22d"
  )
  static let recoveryPrivateKeyBytes = data(
    "0000000000000000000000000000000000000000000000000000000000000002"
  )
  static let recoveryPublicKeyBytes = data(
    "047cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc4766997807775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1"
  )
  static let recoveryWrappedKey = data(
    "04a81b2ed1365e61ca0d34f2c4749c44fed214d3c86e2673fa6f254fa0df39240778e1821cbdbcabb6db07ee8445c728a7568cb5de0035fab1336236bb4ac2f51102f8df1a20c0cc0bcae6797ddbc882365a6c2ebd6e61d31c6ac5c35b04223d50e59830a5f764682a1c051a643bdf48e8"
  )
  static let signingPublicKey = data(
    "045ecbe4d1a6330a44c8f7ef951d4bf165e6c6b721efada985fb41661bc6e7fd6c8734640c4998ff7e374b06ce1a64a2ecd82ab036384fb83d9a79b127a27d5032"
  )
  static let signatureMessage = data(
    "7365637265742d73796e63206669786564207369676e6174757265206d657373616765"
  )
  static let lowSRawSignature = data(
    "6ec984e668c95ae614ed319fc1406b8adbd576fa4d72934cd525d2bbd6c0cc2b215dfcfb675a70a46cda7eb878b36d8c28d8757903ec9790c136a82f660ceda2"
  )
  static let digestInput = data(
    "7365637265742d73796e632073686132353620666978656420696e707574"
  )
  static let digestOutput = data(
    "8978a71cc74c1381ae4ca8f26adba67522d077fba45f997af7875533e023d558"
  )

  static func suite() throws -> SecretSyncAlgorithmSuite {
    try SecretSyncAlgorithmRegistry.resolve(
      SecretSyncAlgorithmSuiteIdentifiers(
        suiteID: SecretSyncAlgorithmRegistry.suiteID,
        suiteNameUTF8: Array(SecretSyncAlgorithmRegistry.suiteName.utf8),
        version: SecretSyncAlgorithmRegistry.version,
        digestUTF8: Array(SecretSyncAlgorithmRegistry.digestAlgorithm.utf8),
        signatureUTF8: Array(SecretSyncAlgorithmRegistry.signatureAlgorithm.utf8),
        publicKeyEncodingUTF8: Array(SecretSyncAlgorithmRegistry.publicKeyEncoding.utf8),
        keyEnvelopeUTF8: Array(SecretSyncAlgorithmRegistry.keyEnvelopeAlgorithm.utf8),
        payloadUTF8: Array(SecretSyncAlgorithmRegistry.payloadAlgorithm.utf8)
      ),
      availability: .available
    )
  }

  static func boundContext(
    scopeID: SecretScopeID = scopeID,
    snapshotDigest: SecretRecordDigest = snapshotDigest,
    policyEpoch: UInt64 = 42,
    policyDigest: SecretRecordDigest = policyDigest,
    generationID: SecretGenerationID = generationID
  ) throws -> SecretSyncV1BoundContext {
    try SecretSyncV1BoundContext(
      scopeID: scopeID,
      scopeSnapshotDigest: snapshotDigest,
      policyEpoch: policyEpoch,
      policyDigest: policyDigest,
      generationID: generationID,
      formatVersion: 1
    )
  }

  static func recipientContext(
    credentialID: DeviceCredentialID = recipientCredentialID,
    boundContext: SecretSyncV1BoundContext? = nil
  ) throws -> SecretSyncRecipientEnvelopeContext {
    SecretSyncRecipientEnvelopeContext(
      boundContext: try boundContext ?? self.boundContext(),
      recipientCredentialID: credentialID
    )
  }

  static func recoveryContext(
    recipientID: UUID = recoveryRecipientID,
    boundContext: SecretSyncV1BoundContext? = nil
  ) throws -> SecretSyncRecoveryEnvelopeContext {
    SecretSyncRecoveryEnvelopeContext(
      boundContext: try boundContext ?? self.boundContext(),
      recoveryRecipientID: recipientID
    )
  }

  static func recipientDescriptor(
    bytes: Data = recipientPublicKeyBytes
  ) throws -> KeyAgreementPublicKeyDescriptor {
    try KeyAgreementPublicKeyDescriptor(
      algorithmIdentifier: SecretSyncAlgorithmRegistry.publicKeyEncoding,
      keyIdentifier: Data("recipient-fixture".utf8),
      publicKeyBytes: bytes
    )
  }

  static func recoveryDescriptor(
    bytes: Data = recoveryPublicKeyBytes
  ) throws -> KeyAgreementPublicKeyDescriptor {
    try KeyAgreementPublicKeyDescriptor(
      algorithmIdentifier: SecretSyncAlgorithmRegistry.publicKeyEncoding,
      keyIdentifier: Data("recovery-fixture".utf8),
      publicKeyBytes: bytes
    )
  }

  static func signingDescriptor() throws -> SigningPublicKeyDescriptor {
    try SigningPublicKeyDescriptor(
      algorithmIdentifier: SecretSyncAlgorithmRegistry.publicKeyEncoding,
      keyIdentifier: Data("signing-fixture".utf8),
      publicKeyBytes: signingPublicKey
    )
  }

  static func digest(_ fill: UInt8) throws -> SecretRecordDigest {
    try SecretRecordDigest(bytes: Data(repeating: fill, count: 32))
  }

  static func data(_ hex: String) -> Data {
    precondition(hex.count.isMultiple(of: 2))
    var result = Data()
    result.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      result.append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }
    return result
  }
}

/// Complete immutable policy graph used through the public validator and store.
struct U7PolicyFixture: Sendable {
  let entry: SecretPolicyStoreEntry
  let snapshot: SecretControlSnapshot
  let generationKey: SecretSyncGenerationKey

  static func make(
    previous: U7PolicyFixture? = nil,
    scopeID: SecretScopeID = U7GoldenVectors.scopeID
  ) throws -> U7PolicyFixture {
    // This fixture intentionally keeps the content-addressed graph assembly in
    // one routine: splitting policy, envelopes, signatures, and commit across
    // mutable builders would permit impossible mixed-epoch test states.
    let digester = try SecretSyncSHA256DigestProvider(suite: U7GoldenVectors.suite())
    let signatures = try SecretSyncP256SignatureProvider(suite: U7GoldenVectors.suite())
    let epoch = (previous?.entry.commit.policyEpoch ?? 0) + 1
    let signerA = P256.Signing.PrivateKey()
    let agreementA = P256.KeyAgreement.PrivateKey()
    let signerB = P256.Signing.PrivateKey()
    let agreementB = P256.KeyAgreement.PrivateKey()
    let signerC = P256.Signing.PrivateKey()
    let agreementC = P256.KeyAgreement.PrivateKey()
    let recovery = P256.KeyAgreement.PrivateKey()
    let credentialA = try credential(
      signing: signerA, agreement: agreementA, marker: 0x73, label: "a", status: .active
    )
    let credentialB = try credential(
      signing: signerB, agreement: agreementB, marker: 0x83, label: "b", status: .active
    )
    let credentialC = try credential(
      signing: signerC, agreement: agreementC, marker: 0x93, label: "c", status: .revoked
    )
    let credentials = [credentialA, credentialB, credentialC]
    let trusts = try zip(credentials, [DeviceTrustState.trusted, .trusted, .revoked]).map {
      credential, state in
      let credentialDigest = try digester.digest(canonicalBytes: credential.canonicalBytes())
      return try addressed(digester) { digest in
        try DeviceTrustRecord(
          recordDigest: digest, credentialDigest: credentialDigest,
          deviceID: credential.deviceID, credentialID: credential.credentialID,
          trustState: state, effectivePolicyEpoch: epoch
        )
      }
    }.sorted { $0.recordDigest.bytes.lexicographicallyPrecedes($1.recordDigest.bytes) }
    let scope = try addressed(digester) { digest in
      try SecretScopeSnapshot(
        scopeID: scopeID,
        rootRecordID: U7UUID.byte(0x71),
        memberRecordIDs: [U7UUID.byte(0x71), U7UUID.byte(0x72)],
        snapshotDigest: digest
      )
    }
    let recoveryDescriptor = try recoveryDescriptor(recovery)
    let policy = try SecretPolicyEpoch(
      epoch: epoch,
      predecessorPolicyDigest: previous?.entry.commit.policyDigest,
      scopeSnapshot: scope,
      generationID: SecretGenerationID(UUID()),
      authorizedRecipientCredentialIDs: [credentialA.credentialID, credentialB.credentialID],
      trustedDeviceRecordDigests: trusts.map(\.recordDigest),
      recoveryRecipient: recoveryDescriptor,
      signerCredentialID: credentialA.credentialID
    )
    let policySignature = try signatures.sign(
      canonicalBytes: policy.canonicalBytes(), using: signerA
    )
    let signedPolicy = try addressed(digester) { digest in
      try SignedSecretPolicyEpoch(
        recordDigest: digest,
        policy: policy,
        signature: policySignature
      )
    }
    let graph = try encryptedGraph(
      policy: signedPolicy,
      recipients: [credentialA, credentialB],
      recovery: recovery,
      digester: digester
    )
    return try finish(
      previous: previous,
      credentials: credentials,
      trusts: trusts,
      signedPolicy: signedPolicy,
      graph: graph,
      digester: digester,
      signer: signerA,
      signatures: signatures
    )
  }

  /// Builds a production-valid graph whose audience records are the physical
  /// credentials gathered on A/B/C. A separate ephemeral orchestration
  /// authority signs graph bytes because Secure Enclave custody deliberately
  /// exposes possession and unwrap operations, not arbitrary signing.
  static func makeLive(
    scopeID: SecretScopeID,
    physicalCredentials: [TrustedDeviceCredential]
  ) throws -> U7PolicyFixture {
    // The live variant is likewise atomic so every externally supplied
    // credential is closed over by the exact policy digest it is tested with.
    guard physicalCredentials.count == 3 else {
      throw SecretSyncInterfaceError.invalidPolicyStoreEntry
    }
    let digester = try SecretSyncSHA256DigestProvider(suite: U7GoldenVectors.suite())
    let signatures = try SecretSyncP256SignatureProvider(suite: U7GoldenVectors.suite())
    let authoritySigning = P256.Signing.PrivateKey()
    let authorityAgreement = P256.KeyAgreement.PrivateKey()
    let authority = try credential(
      signing: authoritySigning, agreement: authorityAgreement,
      marker: 0x63, label: "live-authority", status: .active
    )
    let credentials = physicalCredentials + [authority]
    let trusts = try credentials.map { credential in
      let credentialDigest = try digester.digest(canonicalBytes: credential.canonicalBytes())
      let state: DeviceTrustState = credential.status == .active ? .trusted : .revoked
      return try addressed(digester) { digest in
        try DeviceTrustRecord(
          recordDigest: digest, credentialDigest: credentialDigest,
          deviceID: credential.deviceID, credentialID: credential.credentialID,
          trustState: state, effectivePolicyEpoch: 1
        )
      }
    }.sorted { $0.recordDigest.bytes.lexicographicallyPrecedes($1.recordDigest.bytes) }
    let rootRecordID = UUID()
    let scope = try addressed(digester) { digest in
      try SecretScopeSnapshot(
        scopeID: scopeID, rootRecordID: rootRecordID,
        memberRecordIDs: [rootRecordID],
        snapshotDigest: digest
      )
    }
    let recovery = P256.KeyAgreement.PrivateKey()
    let policy = try SecretPolicyEpoch(
      epoch: 1, predecessorPolicyDigest: nil, scopeSnapshot: scope,
      generationID: SecretGenerationID(UUID()),
      authorizedRecipientCredentialIDs: physicalCredentials
        .filter { $0.status == .active }.map(\.credentialID),
      trustedDeviceRecordDigests: trusts.map(\.recordDigest),
      recoveryRecipient: recoveryDescriptor(recovery),
      signerCredentialID: authority.credentialID
    )
    let policySignature = try signatures.sign(
      canonicalBytes: policy.canonicalBytes(), using: authoritySigning
    )
    let signedPolicy = try addressed(digester) { digest in
      try SignedSecretPolicyEpoch(
        recordDigest: digest, policy: policy, signature: policySignature
      )
    }
    let graph = try encryptedGraph(
      policy: signedPolicy,
      recipients: physicalCredentials.filter { $0.status == .active },
      recovery: recovery, digester: digester
    )
    return try finish(
      previous: nil, credentials: credentials, trusts: trusts,
      signedPolicy: signedPolicy, graph: graph, digester: digester,
      signer: authoritySigning, signerCredentialID: authority.credentialID,
      signatures: signatures
    )
  }

  static func precondition(
    _ fixture: U7PolicyFixture,
    expected: U7PolicyFixture? = nil
  ) throws -> SecretPolicyAdvancePrecondition {
    try SecretPolicyAdvancePrecondition(
      expectedHead: try expected.map { item in
        try SecretPolicyStoreHead(
          scopeID: item.entry.commit.scopeID,
          policyEpoch: item.entry.commit.policyEpoch,
          commitDigest: item.entry.commit.recordDigest,
          policyDigest: item.entry.commit.policyDigest
        )
      },
      candidateEntry: fixture.entry,
      validatedSnapshot: fixture.snapshot
    )
  }

  private struct EncryptedGraph {
    let payload: SealedPayload
    let recipientEnvelopes: [RecipientKeyEnvelope]
    let recoveryEnvelope: RecoveryEnvelope
    let generationKey: SecretSyncGenerationKey
  }

  private static func encryptedGraph(
    policy: SignedSecretPolicyEpoch,
    recipients: [TrustedDeviceCredential],
    recovery: P256.KeyAgreement.PrivateKey,
    digester: any SecretSyncDigesting
  ) throws -> EncryptedGraph {
    // Payload plus all routine/recovery envelopes share one generated key and
    // bound context; keeping them together makes accidental key drift visible.
    let crypto = try SecretSyncV1CryptoProvider(suite: U7GoldenVectors.suite())
    let key = SecretSyncGenerationKey.generate()
    let bound = try SecretSyncV1BoundContext(
      scopeID: policy.policy.scopeSnapshot.scopeID,
      scopeSnapshotDigest: policy.policy.scopeSnapshot.snapshotDigest,
      policyEpoch: policy.policy.epoch,
      policyDigest: policy.recordDigest,
      generationID: policy.policy.generationID,
      formatVersion: 1
    )
    let payloadBytes = try crypto.aesGCMProvider.seal(
      plaintext: Data("u7-production-encrypted-payload".utf8), using: key, context: bound
    )
    let recoveryWrapped = try crypto.hpkeEnvelopeProvider.sealRecoveryGenerationKey(
      key,
      for: agreementDescriptor(recovery, label: "u7-recovery-agreement"),
      context: SecretSyncRecoveryEnvelopeContext(
        boundContext: bound,
        recoveryRecipientID: try #require(policy.policy.recoveryRecipient).recoveryRecipientID
      )
    )
    let payload = try addressed(digester) { digest in
      try SealedPayload(
        recordDigest: digest, scopeID: bound.scopeID,
        scopeSnapshotDigest: bound.scopeSnapshotDigest, policyEpoch: bound.policyEpoch,
        policyDigest: bound.policyDigest, generationID: bound.generationID,
        formatVersion: bound.formatVersion, ciphertextBytes: payloadBytes
      )
    }
    let recipientEnvelopes = try recipients.map { credential in
      let wrapped = try crypto.hpkeEnvelopeProvider.sealGenerationKey(
        key,
        for: credential.keyAgreementPublicKey,
        context: SecretSyncRecipientEnvelopeContext(
          boundContext: bound, recipientCredentialID: credential.credentialID
        )
      )
      return try addressed(digester) { digest in
        try RecipientKeyEnvelope(
          recordDigest: digest, scopeID: bound.scopeID,
          scopeSnapshotDigest: bound.scopeSnapshotDigest, policyEpoch: bound.policyEpoch,
          policyDigest: bound.policyDigest, generationID: bound.generationID,
          recipientCredentialID: credential.credentialID,
          formatVersion: bound.formatVersion, wrappedKeyBytes: wrapped
        )
      }
    }
    let recoveryEnvelope = try addressed(digester) { digest in
      try RecoveryEnvelope(
        recordDigest: digest, scopeID: bound.scopeID,
        scopeSnapshotDigest: bound.scopeSnapshotDigest, policyEpoch: bound.policyEpoch,
        policyDigest: bound.policyDigest, generationID: bound.generationID,
        recoveryRecipientID: try #require(policy.policy.recoveryRecipient).recoveryRecipientID,
        formatVersion: bound.formatVersion, wrappedKeyBytes: recoveryWrapped
      )
    }
    return EncryptedGraph(
      payload: payload,
      recipientEnvelopes: recipientEnvelopes,
      recoveryEnvelope: recoveryEnvelope,
      generationKey: key
    )
  }

  private static func finish(
    previous: U7PolicyFixture?, credentials: [TrustedDeviceCredential],
    trusts: [DeviceTrustRecord], signedPolicy: SignedSecretPolicyEpoch,
    graph: EncryptedGraph,
    digester: any SecretSyncDigesting,
    signer: P256.Signing.PrivateKey,
    signerCredentialID: DeviceCredentialID? = nil,
    signatures: SecretSyncP256SignatureProvider
  ) throws -> U7PolicyFixture {
    let records = try SecretControlRecords(
      state: .staged, signedPolicy: signedPolicy, sealedPayload: graph.payload,
      recipientEnvelopes: graph.recipientEnvelopes, recoveryEnvelope: graph.recoveryEnvelope,
      purgeRequirements: [], purgeReceipts: [], recoveryAuthorization: nil
    )
    let provisionalCommit = try commit(
      digest: U7GoldenVectors.digest(0), signature: Data([0]),
      previous: previous, credentials: credentials,
      signedPolicy: signedPolicy, graph: graph,
      signerCredentialID: signerCredentialID
    )
    let commitSignature = try signatures.sign(
      canonicalBytes: provisionalCommit.signingBytes(), using: signer
    )
    let commit = try addressed(digester) { digest in
      try commit(
        digest: digest, signature: commitSignature,
        previous: previous, credentials: credentials,
        signedPolicy: signedPolicy, graph: graph,
        signerCredentialID: signerCredentialID
      )
    }
    let freshness = try SecretBootstrapFreshnessCommitment(
      scopeID: commit.scopeID, latestPolicyEpoch: commit.policyEpoch,
      headCommitDigest: commit.recordDigest, policyDigest: commit.policyDigest
    )
    let snapshot = try SecretPolicyValidator.validateTransition(
      currentSnapshot: previous?.snapshot, stagedRecords: records, commit: commit,
      trustedCredentials: credentials, trustedDeviceRecords: trusts,
      knownCompetingChildDigests: [], externalFreshness: freshness,
      digester: digester, signatureVerifier: signatures
    )
    return try U7PolicyFixture(
      entry: SecretPolicyStoreEntry(
        commit: commit, records: records, credentials: credentials,
        trustRecords: trusts, digester: digester
      ),
      snapshot: snapshot, generationKey: graph.generationKey
    )
  }

  private static func commit(
    digest: SecretRecordDigest,
    signature: Data,
    previous: U7PolicyFixture?,
    credentials: [TrustedDeviceCredential],
    signedPolicy: SignedSecretPolicyEpoch,
    graph: EncryptedGraph,
    signerCredentialID: DeviceCredentialID? = nil
  ) throws -> SecretTransitionCommit {
    try SecretTransitionCommit(
      recordDigest: digest,
      scopeID: signedPolicy.policy.scopeSnapshot.scopeID,
      policyEpoch: signedPolicy.policy.epoch,
      predecessorCommitDigest: previous?.entry.commit.recordDigest,
      policyDigest: signedPolicy.recordDigest,
      scopeSnapshotDigest: signedPolicy.policy.scopeSnapshot.snapshotDigest,
      generationID: signedPolicy.policy.generationID,
      sealedPayloadDigest: graph.payload.recordDigest,
      recipientEnvelopeDigests: graph.recipientEnvelopes.map(\.recordDigest),
      recoveryEnvelopeDigest: graph.recoveryEnvelope.recordDigest,
      purgeRequirementDigests: [], purgeReceiptDigests: [],
      recoveryAuthorizationDigest: nil,
      signerCredentialID: try signerCredentialID ?? #require(credentials.first).credentialID,
      signature: signature
    )
  }

  private static func credential(
    signing: P256.Signing.PrivateKey,
    agreement: P256.KeyAgreement.PrivateKey,
    marker: UInt8,
    label: String,
    status: TrustedDeviceCredentialStatus
  ) throws -> TrustedDeviceCredential {
    let credentialID = DeviceCredentialID(U7UUID.byte(marker))
    return try TrustedDeviceCredential(
      deviceID: TrustedDeviceID(U7UUID.byte(marker &+ 1)), credentialID: credentialID,
      credentialVersion: 1, status: status,
      signingPublicKey: SigningPublicKeyDescriptor(
        algorithmIdentifier: SecretSyncAlgorithmRegistry.publicKeyEncoding,
        keyIdentifier: Data("u7-\(label)-signing".utf8),
        publicKeyBytes: signing.publicKey.x963Representation
      ),
      keyAgreementPublicKey: agreementDescriptor(agreement, label: "u7-\(label)-agreement"),
      enrollmentProof: DeviceCredentialEnrollmentProof(
        challengeID: U7UUID.byte(marker &+ 2), challengeBytes: Data([marker &+ 2]),
        signingProofBytes: Data([marker &+ 3]), keyAgreementProofBytes: Data([marker &+ 4]),
        provenance: .trustedDevice(
          TrustedDeviceEnrollmentAuthority(
            credentialID: DeviceCredentialID(U7UUID.byte(0x78)), signature: Data([0xA1])
          )
        )
      )
    )
  }

  private static func recoveryDescriptor(
    _ key: P256.KeyAgreement.PrivateKey
  ) throws -> RecoveryRecipientDescriptor {
    let signing = P256.Signing.PrivateKey()
    return try RecoveryRecipientDescriptor(
      recoveryRecipientID: U7UUID.byte(0x79),
      keyAgreementPublicKey: KeyAgreementPublicKeyDescriptor(
        algorithmIdentifier: RecoveryRecipientDescriptor.agreementAlgorithmIdentifier,
        keyIdentifier: Data("u7-recovery-agreement".utf8),
        publicKeyBytes: key.publicKey.x963Representation
      ),
      authorizationSigningPublicKey: SigningPublicKeyDescriptor(
        algorithmIdentifier: RecoveryRecipientDescriptor.authorizationSigningAlgorithmIdentifier,
        keyIdentifier: Data("u7-recovery-signing".utf8),
        publicKeyBytes: signing.publicKey.x963Representation
      )
    )
  }

  private static func agreementDescriptor(
    _ key: P256.KeyAgreement.PrivateKey, label: String
  ) throws -> KeyAgreementPublicKeyDescriptor {
    try KeyAgreementPublicKeyDescriptor(
      algorithmIdentifier: SecretSyncAlgorithmRegistry.publicKeyEncoding,
      keyIdentifier: Data(label.utf8), publicKeyBytes: key.publicKey.x963Representation
    )
  }

  private static func addressed<T: SecretSyncCanonicalEncodable>(
    _ digester: any SecretSyncDigesting,
    build: (SecretRecordDigest) throws -> T
  ) throws -> T {
    let provisional = try build(U7GoldenVectors.digest(0))
    return try build(digester.digest(canonicalBytes: provisional.canonicalBytes()))
  }
}
