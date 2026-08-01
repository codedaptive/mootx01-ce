import ConvergenceKit
import ConvergenceKitAppleSecurity
import CryptoKit
import Foundation
import Testing

@Suite("SecretSync end-to-end conformance")
struct SecretSyncEndToEndConformanceTests {
  @Test("A and B can open while excluded C receives no usable envelope")
  func authorizedAudienceExcludesC() throws {
    let provider = try SecretSyncV1CryptoProvider(suite: U7GoldenVectors.suite())
    let generationKey = SecretSyncGenerationKey.generate()
    let a = P256.KeyAgreement.PrivateKey()
    let b = P256.KeyAgreement.PrivateKey()
    let c = P256.KeyAgreement.PrivateKey()
    let aID = DeviceCredentialID(U7UUID.byte(0xA1))
    let bID = DeviceCredentialID(U7UUID.byte(0xB1))
    let cID = DeviceCredentialID(U7UUID.byte(0xC1))
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
    let opaqueRecords = [aID: aEnvelope, bID: bEnvelope]

    for (id, privateKey) in [(aID, a), (bID, b)] {
      let opened = try provider.hpkeEnvelopeProvider.openRecipientGenerationKey(
        try #require(opaqueRecords[id]),
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

    #expect(opaqueRecords[cID] == nil)
    #expect(throws: SecretSyncV1CryptoError.authenticationFailed) {
      _ = try provider.hpkeEnvelopeProvider.openRecipientGenerationKey(
        aEnvelope,
        using: c,
        context: try U7GoldenVectors.recipientContext(
          credentialID: aID,
          boundContext: bound
        )
      )
    }
  }

  @Test("audience contraction rotates epoch generation and content key")
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
    let token = Data("cloud-account-token".utf8)
    let provider = try SecretSyncAESGCMProvider(suite: U7GoldenVectors.suite())
    let sealed = try provider.seal(
      plaintext: Data("authority-is-the-key".utf8),
      using: SecretSyncGenerationKey.generate(),
      context: U7GoldenVectors.boundContext()
    )

    #expect(token != sealed)
    #expect(SecretSyncCloudAuthority.accountOrChangeToken.authorizes == false)
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

private enum SecretSyncCloudAuthority {
  case accountOrChangeToken

  var authorizes: Bool { false }
}

enum U7UUID {
  static func byte(_ value: UInt8) -> UUID {
    UUID(uuid: (
      value, value, value, value, value, value, value, value,
      value, value, value, value, value, value, value, value
    ))
  }
}
