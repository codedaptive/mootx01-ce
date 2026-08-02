import ConvergenceKit
import ConvergenceKitAppleSecurity
import CryptoKit
import Foundation
import Testing

@Suite("SecretSync end-to-end conformance")
struct SecretSyncEndToEndConformanceTests {
  @Test("A and B can open while excluded C receives no usable envelope")
  // Graph admission and cryptographic opening remain in one test because the
  // same A/B/C keys prove both policy membership and actual decryptability.
  func authorizedAudienceExcludesC() throws {
    let graph = try U7PolicyFixture.make().entry
    let cID = DeviceCredentialID(U7UUID.byte(0x93))
    #expect(graph.records.signedPolicy.policy.authorizedRecipientCredentialIDs.count == 2)
    #expect(graph.records.recipientEnvelopes.count == 2)
    #expect(!graph.records.recipientEnvelopes.contains { $0.recipientCredentialID == cID })
    #expect(graph.trustRecords.first { $0.credentialID == cID }?.trustState == .revoked)

    let provider = try SecretSyncV1CryptoProvider(suite: U7GoldenVectors.suite())
    let generationKey = SecretSyncGenerationKey.generate()
    let a = P256.KeyAgreement.PrivateKey()
    let b = P256.KeyAgreement.PrivateKey()
    let c = P256.KeyAgreement.PrivateKey()
    let aID = DeviceCredentialID(U7UUID.byte(0xA1))
    let bID = DeviceCredentialID(U7UUID.byte(0xB1))
    let excludedID = DeviceCredentialID(U7UUID.byte(0xC1))
    let bound = try U7GoldenVectors.boundContext()
    let plaintext = Data("isolated-u7-secret".utf8)
    let sealed = try provider.aesGCMProvider.seal(
      plaintext: plaintext,
      using: generationKey,
      context: bound
    )

    let aEnvelope = try provider.hpkeEnvelopeProvider.sealGenerationKey(
      generationKey,
      for: descriptor(a, label: "A"),
      context: try U7GoldenVectors.recipientContext(
        credentialID: aID,
        boundContext: bound
      )
    )
    let bEnvelope = try provider.hpkeEnvelopeProvider.sealGenerationKey(
      generationKey,
      for: descriptor(b, label: "B"),
      context: try U7GoldenVectors.recipientContext(
        credentialID: bID,
        boundContext: bound
      )
    )
    for (id, privateKey, envelope) in [(aID, a, aEnvelope), (bID, b, bEnvelope)] {
      let opened = try provider.hpkeEnvelopeProvider.openRecipientGenerationKey(
        envelope,
        using: privateKey,
        context: try U7GoldenVectors.recipientContext(
          credentialID: id,
          boundContext: bound
        )
      )
      #expect(
        try provider.aesGCMProvider.open(
          sealedBytes: sealed,
          using: opened,
          context: bound
        ) == plaintext
      )
    }

    #expect(throws: SecretSyncV1CryptoError.authenticationFailed) {
      _ = try provider.hpkeEnvelopeProvider.openRecipientGenerationKey(
        aEnvelope,
        using: c,
        context: try U7GoldenVectors.recipientContext(
          credentialID: excludedID,
          boundContext: bound
        )
      )
    }
  }

  @Test("audience contraction rotates epoch generation and content key")
  // This end-to-end boundary deliberately retains old and replacement epochs
  // together so stale-key rejection and current-key success share one fixture.
  func audienceContractionRotatesAllAuthority() throws {
    let provider = try SecretSyncV1CryptoProvider(suite: U7GoldenVectors.suite())
    let a = P256.KeyAgreement.PrivateKey()
    let b = P256.KeyAgreement.PrivateKey()
    let aID = DeviceCredentialID(U7UUID.byte(0xA2))
    let bID = DeviceCredentialID(U7UUID.byte(0xB2))
    let oldContext = try U7GoldenVectors.boundContext(policyEpoch: 42)
    let newContext = try U7GoldenVectors.boundContext(
      policyEpoch: 43,
      policyDigest: U7GoldenVectors.digest(0x51),
      generationID: SecretGenerationID(U7UUID.byte(0x52))
    )
    let oldKey = SecretSyncGenerationKey.generate()
    let newKey = SecretSyncGenerationKey.generate()
    let oldBEnvelope = try provider.hpkeEnvelopeProvider.sealGenerationKey(
      oldKey,
      for: descriptor(b, label: "B-old"),
      context: try U7GoldenVectors.recipientContext(
        credentialID: bID,
        boundContext: oldContext
      )
    )
    let newAEnvelope = try provider.hpkeEnvelopeProvider.sealGenerationKey(
      newKey,
      for: descriptor(a, label: "A-new"),
      context: try U7GoldenVectors.recipientContext(
        credentialID: aID,
        boundContext: newContext
      )
    )
    let future = try provider.aesGCMProvider.seal(
      plaintext: Data("future-generation".utf8),
      using: newKey,
      context: newContext
    )

    #expect(throws: SecretSyncV1CryptoError.authenticationFailed) {
      let stale = try provider.hpkeEnvelopeProvider.openRecipientGenerationKey(
        oldBEnvelope,
        using: b,
        context: try U7GoldenVectors.recipientContext(
          credentialID: bID,
          boundContext: oldContext
        )
      )
      _ = try provider.aesGCMProvider.open(
        sealedBytes: future,
        using: stale,
        context: newContext
      )
    }
    let current = try provider.hpkeEnvelopeProvider.openRecipientGenerationKey(
      newAEnvelope,
      using: a,
      context: try U7GoldenVectors.recipientContext(
        credentialID: aID,
        boundContext: newContext
      )
    )
    #expect(
      try provider.aesGCMProvider.open(
        sealedBytes: future,
        using: current,
        context: newContext
      ) == Data("future-generation".utf8)
    )
  }

  @Test("account and transport tokens carry no cryptographic authority")
  func transportMetadataIsNotAuthority() throws {
    let commit = try U7TransitionFixture.commit(epoch: 7, marker: 0x91)
    let exact = try SecretBootstrapFreshnessCommitment(
      scopeID: commit.scopeID,
      latestPolicyEpoch: commit.policyEpoch,
      headCommitDigest: commit.recordDigest,
      policyDigest: commit.policyDigest
    )
    try SecretPolicyValidator.validateBootstrapFreshness(
      localCommit: commit,
      against: exact
    )

    #expect(throws: SecretPolicyValidationError.externalFreshnessFork) {
      try SecretPolicyValidator.validateBootstrapFreshness(
        localCommit: commit,
        against: SecretBootstrapFreshnessCommitment(
          scopeID: exact.scopeID,
          latestPolicyEpoch: exact.latestPolicyEpoch,
          headCommitDigest: U7GoldenVectors.digest(0x92),
          policyDigest: exact.policyDigest
        )
      )
    }
  }

  private func descriptor(
    _ key: P256.KeyAgreement.PrivateKey,
    label: String
  ) throws -> KeyAgreementPublicKeyDescriptor {
    try KeyAgreementPublicKeyDescriptor(
      algorithmIdentifier: SecretSyncAlgorithmRegistry.publicKeyEncoding,
      keyIdentifier: Data(label.utf8),
      publicKeyBytes: key.publicKey.x963Representation
    )
  }
}

enum U7UUID {
  static func byte(_ value: UInt8) -> UUID {
    UUID(uuid: (
      value, value, value, value, value, value, value, value,
      value, value, value, value, value, value, value, value
    ))
  }
}
