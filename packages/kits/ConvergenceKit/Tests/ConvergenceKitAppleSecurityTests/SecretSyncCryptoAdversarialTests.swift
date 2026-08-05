import ConvergenceKit
import CryptoKit
import Foundation
import Testing

@testable import ConvergenceKitAppleSecurity

@Suite("SecretSync v1 adversarial crypto matrix")
struct SecretSyncCryptoAdversarialTests {
  @Test("bound contexts and generation-key fixtures fail closed")
  func invalidBoundInputsReject() throws {
    #expect(throws: SecretSyncV1CryptoError.invalidBinding) {
      _ = try SecretSyncV1GoldenVectors.boundContext(policyEpoch: 0)
    }
    #expect(throws: SecretSyncV1CryptoError.invalidBinding) {
      _ = try SecretSyncV1GoldenVectors.boundContext(formatVersion: 2)
    }
    #expect(throws: SecretSyncV1CryptoError.invalidGenerationKey) {
      _ = try SecretSyncGenerationKey(
        fixtureBytes: Data(repeating: 0, count: 31)
      )
    }
  }

  @Test("every recipient and recovery HPKE field binds both info and AAD")
  func everyHPKEFieldBindsInfoAndAAD() throws {
    try assertHPKEMutationsFail(
      privateKeyBytes: SecretSyncV1GoldenVectors.recipientPrivateKeyBytes,
      wrapped: SecretSyncV1GoldenVectors.recipientWrappedKey,
      original: SecretSyncV1GoldenVectors.recipientBinding,
      valueOffsets: [50, 92, 130, 144, 182, 224, 232, 274, 296, 304, 356]
    )
    try assertHPKEMutationsFail(
      privateKeyBytes: SecretSyncV1GoldenVectors.recoveryPrivateKeyBytes,
      wrapped: SecretSyncV1GoldenVectors.recoveryWrappedKey,
      original: SecretSyncV1GoldenVectors.recoveryBinding,
      valueOffsets: [45, 87, 125, 139, 177, 219, 227, 269, 297, 305, 357]
    )
  }

  @Test("HPKE rejects role swaps, wrong keys, corrupt wrappers, and bad public keys")
  func hpkeMalformedAndCrossRoleInputsReject() throws {
    // This matrix shares one provider setup so wrapper framing, key mismatch,
    // and public-key encoding failures retain stable lane-specific errors.
    let provider = try SecretSyncHPKEEnvelopeProvider(
      suite: SecretSyncV1GoldenVectors.suite()
    )
    let recipientPrivate = try P256.KeyAgreement.PrivateKey(
      rawRepresentation: SecretSyncV1GoldenVectors.recipientPrivateKeyBytes
    )
    let recoveryPrivate = try P256.KeyAgreement.PrivateKey(
      rawRepresentation: SecretSyncV1GoldenVectors.recoveryPrivateKeyBytes
    )

    #expect(throws: SecretSyncV1CryptoError.authenticationFailed) {
      _ = try provider.openRecipientGenerationKey(
        SecretSyncV1GoldenVectors.recoveryWrappedKey,
        using: recipientPrivate,
        context: SecretSyncV1GoldenVectors.recipientContext()
      )
    }
    #expect(throws: SecretSyncV1CryptoError.authenticationFailed) {
      _ = try provider.openRecoveryGenerationKey(
        SecretSyncV1GoldenVectors.recipientWrappedKey,
        using: recoveryPrivate,
        context: SecretSyncV1GoldenVectors.recoveryContext()
      )
    }
    #expect(throws: SecretSyncV1CryptoError.authenticationFailed) {
      _ = try provider.openRecipientGenerationKey(
        SecretSyncV1GoldenVectors.recipientWrappedKey,
        using: recoveryPrivate,
        context: SecretSyncV1GoldenVectors.recipientContext()
      )
    }
    #expect(throws: SecretSyncV1CryptoError.authenticationFailed) {
      _ = try provider.openRecoveryGenerationKey(
        SecretSyncV1GoldenVectors.recoveryWrappedKey,
        using: recipientPrivate,
        context: SecretSyncV1GoldenVectors.recoveryContext()
      )
    }

    for length in [0, 64, 65, 112, 114, 65_536] {
      #expect(throws: SecretSyncV1CryptoError.invalidEnvelope) {
        _ = try provider.openRecipientGenerationKey(
          Data(repeating: 0, count: length),
          using: recipientPrivate,
          context: SecretSyncV1GoldenVectors.recipientContext()
        )
      }
    }

    for offset in [0, 1, 64, 65, 96, 112] {
      var corrupt = SecretSyncV1GoldenVectors.recipientWrappedKey
      corrupt[offset] ^= 0x01
      let expected: SecretSyncV1CryptoError =
        offset < 65
        ? .invalidEnvelope
        : .authenticationFailed
      #expect(throws: expected) {
        _ = try provider.openRecipientGenerationKey(
          corrupt,
          using: recipientPrivate,
          context: SecretSyncV1GoldenVectors.recipientContext()
        )
      }
    }
    #expect(throws: SecretSyncV1CryptoError.invalidEnvelope) {
      _ = try provider.openRecipientGenerationKey(
        SecretSyncV1GoldenVectors.recipientWrappedKey + Data([0]),
        using: recipientPrivate,
        context: SecretSyncV1GoldenVectors.recipientContext()
      )
    }

    let key = SecretSyncGenerationKey.generate()
    let ephemeralPublicKey = P256.KeyAgreement.PrivateKey().publicKey
    for bytes in [
      Data(repeating: 0, count: 64),
      Data([0x02]) + ephemeralPublicKey.x963Representation[1...32],
      ephemeralPublicKey.derRepresentation,
      Data([0x02]) + SecretSyncV1GoldenVectors.recipientPublicKeyBytes.dropFirst(),
      Data([0x04]) + Data(repeating: 0, count: 64),
    ] {
      let descriptor = try SecretSyncV1GoldenVectors.recipientDescriptor(
        bytes: Data(bytes)
      )
      #expect(throws: SecretSyncV1CryptoError.invalidPublicKeyEncoding) {
        _ = try provider.sealGenerationKey(
          key,
          for: descriptor,
          context: SecretSyncV1GoldenVectors.recipientContext()
        )
      }
    }
    let wrongAlgorithm = try SecretSyncV1GoldenVectors.recipientDescriptor(
      algorithm: "p256-compressed"
    )
    #expect(throws: SecretSyncV1CryptoError.invalidPublicKeyEncoding) {
      _ = try provider.sealGenerationKey(
        key,
        for: wrongAlgorithm,
        context: SecretSyncV1GoldenVectors.recipientContext()
      )
    }
  }

  @Test("HPKE role and domain separate an identical key and identifier")
  func identicalKeyAndIdentifierCrossRoleReject() throws {
    // The same key and UUID intentionally remove every discriminator except
    // the typed recipient/recovery domain and fixed role embedded in SSCP.
    let provider = try SecretSyncHPKEEnvelopeProvider(
      suite: SecretSyncV1GoldenVectors.suite()
    )
    let sharedPrivateKey = P256.KeyAgreement.PrivateKey()
    let sharedUUID = UUID(
      uuidString: "12345678-1234-5678-9abc-def012345678"
    )!
    let descriptor = try KeyAgreementPublicKeyDescriptor(
      algorithmIdentifier: SecretSyncAlgorithmRegistry.publicKeyEncoding,
      keyIdentifier: Data("shared-cross-role-key".utf8),
      publicKeyBytes: sharedPrivateKey.publicKey.x963Representation
    )
    let boundContext = try SecretSyncV1GoldenVectors.boundContext()
    let recipientContext = SecretSyncRecipientEnvelopeContext(
      boundContext: boundContext,
      recipientCredentialID: DeviceCredentialID(sharedUUID)
    )
    let recoveryContext = SecretSyncRecoveryEnvelopeContext(
      boundContext: boundContext,
      recoveryRecipientID: sharedUUID
    )
    let generationKey = SecretSyncGenerationKey.generate()

    let recipientWrapped = try provider.sealGenerationKey(
      generationKey,
      for: descriptor,
      context: recipientContext
    )
    #expect(throws: SecretSyncV1CryptoError.authenticationFailed) {
      _ = try provider.openRecoveryGenerationKey(
        recipientWrapped,
        using: sharedPrivateKey,
        context: recoveryContext
      )
    }

    let recoveryWrapped = try provider.sealRecoveryGenerationKey(
      generationKey,
      for: descriptor,
      context: recoveryContext
    )
    #expect(throws: SecretSyncV1CryptoError.authenticationFailed) {
      _ = try provider.openRecipientGenerationKey(
        recoveryWrapped,
        using: sharedPrivateKey,
        context: recipientContext
      )
    }
  }

  @Test("AES binds every field and rejects all malformed payload shapes")
  func aesAdversarialMatrix() throws {
    // A single fixed ciphertext anchors all AAD-field and payload-shape
    // mutations, proving that no malformed case changes the plaintext oracle.
    let provider = try SecretSyncAESGCMProvider(
      suite: SecretSyncV1GoldenVectors.suite()
    )
    let key = try SecretSyncGenerationKey(
      fixtureBytes: SecretSyncV1GoldenVectors.aesKeyBytes
    )
    let original = SecretSyncV1GoldenVectors.payloadBinding
    let sealed = SecretSyncV1GoldenVectors.aesCombined

    for offset in [42, 84, 122, 136, 174, 216, 224, 243, 251, 303] {
      var wrongAAD = original
      wrongAAD[offset] ^= 0x01
      let box = try AES.GCM.SealedBox(combined: sealed)
      #expect(throws: (any Error).self) {
        _ = try AES.GCM.open(
          box,
          using: SymmetricKey(data: SecretSyncV1GoldenVectors.aesKeyBytes),
          authenticating: wrongAAD
        )
      }
    }

    let wrongKey = SecretSyncGenerationKey.generate()
    #expect(throws: SecretSyncV1CryptoError.authenticationFailed) {
      _ = try provider.open(
        sealedBytes: sealed,
        using: wrongKey,
        context: SecretSyncV1GoldenVectors.boundContext()
      )
    }
    let alternateDigest = try SecretRecordDigest(
      bytes: Data(repeating: 0xa5, count: 32)
    )
    let alternateScope = SecretScopeID(
      UUID(uuidString: "ffffffff-eeee-dddd-cccc-bbbbbbbbbbbb")!
    )
    let alternateGeneration = SecretGenerationID(
      UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    )
    let mutatedContexts = [
      try SecretSyncV1GoldenVectors.boundContext(scopeID: alternateScope),
      try SecretSyncV1GoldenVectors.boundContext(
        snapshotDigest: alternateDigest
      ),
      try SecretSyncV1GoldenVectors.boundContext(policyEpoch: 43),
      try SecretSyncV1GoldenVectors.boundContext(
        policyDigest: alternateDigest
      ),
      try SecretSyncV1GoldenVectors.boundContext(
        generationID: alternateGeneration
      ),
    ]
    for context in mutatedContexts {
      #expect(throws: SecretSyncV1CryptoError.authenticationFailed) {
        _ = try provider.open(
          sealedBytes: sealed,
          using: key,
          context: context
        )
      }
    }
    for length in 0...27 {
      #expect(throws: SecretSyncV1CryptoError.invalidPayload) {
        _ = try provider.open(
          sealedBytes: Data(repeating: 0, count: length),
          using: key,
          context: SecretSyncV1GoldenVectors.boundContext()
        )
      }
    }
    for offset in [0, 11, 12, sealed.count - 1] {
      var corrupt = sealed
      corrupt[offset] ^= 0x01
      #expect(throws: SecretSyncV1CryptoError.authenticationFailed) {
        _ = try provider.open(
          sealedBytes: corrupt,
          using: key,
          context: SecretSyncV1GoldenVectors.boundContext()
        )
      }
    }
    #expect(throws: SecretSyncV1CryptoError.authenticationFailed) {
      _ = try provider.open(
        sealedBytes: sealed + Data([0]),
        using: key,
        context: SecretSyncV1GoldenVectors.boundContext()
      )
    }
    #expect(throws: SecretSyncV1CryptoError.authenticationFailed) {
      _ = try provider.open(
        sealedBytes: Data(sealed.dropLast()),
        using: key,
        context: SecretSyncV1GoldenVectors.boundContext()
      )
    }
  }

  @Test("ECDSA rejects alternate encodings and noncanonical scalars")
  func signatureAdversarialMatrix() throws {
    // Keeping the raw64 scalar and public-key cases together makes alternate
    // parsing or verifier-side normalization visible as one fail-closed matrix.
    let provider = try SecretSyncP256SignatureProvider(
      suite: SecretSyncV1GoldenVectors.suite()
    )
    let descriptor = try SecretSyncV1GoldenVectors.signingDescriptor()
    let message = SecretSyncV1GoldenVectors.signatureMessage
    let signature = SecretSyncV1GoldenVectors.lowSRawSignature

    var wrongMessage = message
    wrongMessage[0] ^= 1
    #expect(
      try !provider.verify(
        signature: signature,
        canonicalBytes: wrongMessage,
        signingPublicKey: descriptor
      )
    )

    var invalidMath = signature
    invalidMath[31] ^= 1
    #expect(
      try !provider.verify(
        signature: invalidMath,
        canonicalBytes: message,
        signingPublicKey: descriptor
      )
    )
    var invalidS = signature
    invalidS[63] ^= 1
    #expect(
      try !provider.verify(
        signature: invalidS,
        canonicalBytes: message,
        signingPublicKey: descriptor
      )
    )
    let otherSigningKey = P256.Signing.PrivateKey()
    #expect(
      try !provider.verify(
        signature: signature,
        canonicalBytes: message,
        signingPublicKey: SecretSyncV1GoldenVectors.signingDescriptor(
          bytes: otherSigningKey.publicKey.x963Representation
        )
      )
    )

    let der = try P256.Signing.ECDSASignature(
      rawRepresentation: signature
    ).derRepresentation
    for malformed in [
      der,
      signature.dropLast(),
      signature + Data([0]),
      Data(repeating: 0, count: 64),
      Data(repeating: 0xff, count: 64),
    ].map(Data.init) {
      #expect(throws: SecretSyncV1CryptoError.invalidSignatureEncoding) {
        _ = try provider.verify(
          signature: malformed,
          canonicalBytes: message,
          signingPublicKey: descriptor
        )
      }
    }

    let order = SecretSyncV1GoldenVectors.data(
      "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"
    )
    let r = Data(signature.prefix(32))
    let s = Data(signature.suffix(32))
    for malformed in [
      Data(repeating: 0, count: 32) + s,
      r + Data(repeating: 0, count: 32),
      order + s,
      r + order,
    ] {
      #expect(throws: SecretSyncV1CryptoError.invalidSignatureEncoding) {
        _ = try provider.verify(
          signature: malformed,
          canonicalBytes: message,
          signingPublicKey: descriptor
        )
      }
    }

    let highS = SecretSyncP256SignatureProvider.highSTwin(signature)
    #expect(throws: SecretSyncV1CryptoError.highSSignature) {
      _ = try provider.verify(
        signature: highS,
        canonicalBytes: message,
        signingPublicKey: descriptor
      )
    }

    for bytes in [
      Data(repeating: 0, count: 64),
      Data([0x03]) + SecretSyncV1GoldenVectors.signingPublicKey.dropFirst(),
      Data([0x04]) + Data(repeating: 0, count: 64),
    ] {
      let badDescriptor = try SecretSyncV1GoldenVectors.signingDescriptor(
        bytes: Data(bytes)
      )
      #expect(throws: SecretSyncV1CryptoError.invalidPublicKeyEncoding) {
        _ = try provider.verify(
          signature: signature,
          canonicalBytes: message,
          signingPublicKey: badDescriptor
        )
      }
    }
    let wrongAlgorithm = try SecretSyncV1GoldenVectors.signingDescriptor(
      algorithm: "ecdsa-p256-der"
    )
    #expect(throws: SecretSyncV1CryptoError.invalidPublicKeyEncoding) {
      _ = try provider.verify(
        signature: signature,
        canonicalBytes: message,
        signingPublicKey: wrongAlgorithm
      )
    }
  }

  @Test("all providers reject manufactured or unavailable suites")
  func suiteMutationsReject() throws {
    // Every tuple component is varied against every provider in one atomic
    // matrix so leaf-local validation cannot diverge by provider type.
    let exact = SecretSyncV1GoldenVectors.exactIdentifiers()
    #expect(throws: SecretSyncAppleSecurityError.suiteUnavailable) {
      _ = try SecretSyncAlgorithmRegistry.resolve(
        exact,
        availability: .unavailable
      )
    }

    let mutations = [
      manufacturedSuite(suiteID: 2),
      manufacturedSuite(suiteName: "wrong-suite"),
      manufacturedSuite(version: 2),
      manufacturedSuite(digestAlgorithm: "sha512"),
      manufacturedSuite(signatureAlgorithm: "ecdsa-p256-der"),
      manufacturedSuite(publicKeyEncoding: "p256-compressed"),
      manufacturedSuite(keyEnvelopeAlgorithm: "hpke-alternate"),
      manufacturedSuite(payloadAlgorithm: "aes-gcm-alternate"),
    ]
    for mutated in mutations {
      #expect(throws: SecretSyncAppleSecurityError.unsupportedSuite) {
        _ = try SecretSyncSHA256DigestProvider(suite: mutated)
      }
      #expect(throws: SecretSyncAppleSecurityError.unsupportedSuite) {
        _ = try SecretSyncP256SignatureProvider(suite: mutated)
      }
      #expect(throws: SecretSyncAppleSecurityError.unsupportedSuite) {
        _ = try SecretSyncHPKEEnvelopeProvider(suite: mutated)
      }
      #expect(throws: SecretSyncAppleSecurityError.unsupportedSuite) {
        _ = try SecretSyncAESGCMProvider(suite: mutated)
      }
      #expect(throws: SecretSyncAppleSecurityError.unsupportedSuite) {
        _ = try SecretSyncV1CryptoProvider(suite: mutated)
      }
    }
  }

  private func manufacturedSuite(
    suiteID: UInt16 = SecretSyncAlgorithmRegistry.suiteID,
    suiteName: String = SecretSyncAlgorithmRegistry.suiteName,
    version: UInt16 = SecretSyncAlgorithmRegistry.version,
    digestAlgorithm: String = SecretSyncAlgorithmRegistry.digestAlgorithm,
    signatureAlgorithm: String = SecretSyncAlgorithmRegistry.signatureAlgorithm,
    publicKeyEncoding: String = SecretSyncAlgorithmRegistry.publicKeyEncoding,
    keyEnvelopeAlgorithm: String = SecretSyncAlgorithmRegistry.keyEnvelopeAlgorithm,
    payloadAlgorithm: String = SecretSyncAlgorithmRegistry.payloadAlgorithm
  ) -> SecretSyncAlgorithmSuite {
    SecretSyncAlgorithmSuite(
      suiteID: suiteID,
      suiteName: suiteName,
      version: version,
      digestAlgorithm: digestAlgorithm,
      signatureAlgorithm: signatureAlgorithm,
      publicKeyEncoding: publicKeyEncoding,
      keyEnvelopeAlgorithm: keyEnvelopeAlgorithm,
      payloadAlgorithm: payloadAlgorithm
    )
  }

  private func assertHPKEMutationsFail(
    privateKeyBytes: Data,
    wrapped: Data,
    original: Data,
    valueOffsets: [Int]
  ) throws {
    // Each bound value must fail independently in both HPKE lanes: mutated
    // info with original AAD, then original info with mutated AAD.
    let privateKey = try P256.KeyAgreement.PrivateKey(
      rawRepresentation: privateKeyBytes
    )
    let encapsulatedKey = wrapped.prefix(65)
    let ciphertext = wrapped.dropFirst(65)
    for offset in valueOffsets {
      var mutation = original
      mutation[offset] ^= 1

      #expect(throws: (any Error).self) {
        var recipient = try HPKE.Recipient(
          privateKey: privateKey,
          ciphersuite: .P256_SHA256_AES_GCM_256,
          info: mutation,
          encapsulatedKey: Data(encapsulatedKey)
        )
        _ = try recipient.open(
          Data(ciphertext),
          authenticating: original
        )
      }
      #expect(throws: (any Error).self) {
        var recipient = try HPKE.Recipient(
          privateKey: privateKey,
          ciphersuite: .P256_SHA256_AES_GCM_256,
          info: original,
          encapsulatedKey: Data(encapsulatedKey)
        )
        _ = try recipient.open(
          Data(ciphertext),
          authenticating: mutation
        )
      }
    }
  }
}
