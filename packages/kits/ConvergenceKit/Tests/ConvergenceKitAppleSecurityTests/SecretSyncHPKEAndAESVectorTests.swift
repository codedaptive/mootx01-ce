import ConvergenceKit
import CryptoKit
import Foundation
import Testing

@testable import ConvergenceKitAppleSecurity

@Suite("SecretSync v1 HPKE and AES vectors")
struct SecretSyncHPKEAndAESVectorTests {
  @Test("SSCP bindings match the exact fixed byte contracts")
  func exactBindings() throws {
    let recipient = try SecretSyncV1Binding.recipientBytes(
      context: SecretSyncV1GoldenVectors.recipientContext()
    )
    let recovery = try SecretSyncV1Binding.recoveryBytes(
      context: SecretSyncV1GoldenVectors.recoveryContext()
    )
    let payload = try SecretSyncV1Binding.payloadBytes(
      context: SecretSyncV1GoldenVectors.boundContext()
    )

    #expect(recipient.count == 358)
    #expect(recipient == SecretSyncV1GoldenVectors.recipientBinding)
    #expect(recovery.count == 359)
    #expect(recovery == SecretSyncV1GoldenVectors.recoveryBinding)
    #expect(payload.count == 305)
    #expect(payload == SecretSyncV1GoldenVectors.payloadBinding)
  }

  @Test("fixed recipient and recovery HPKE OPEN vectors recover the key")
  func fixedHPKEOpenVectors() throws {
    // Both independent OPEN fixtures stay together so they prove identical
    // opaque-key usability while preserving their distinct typed contexts.
    let suite = try SecretSyncV1GoldenVectors.suite()
    let hpke = try SecretSyncHPKEEnvelopeProvider(suite: suite)
    let aes = try SecretSyncAESGCMProvider(suite: suite)
    let expectedKey = try SecretSyncGenerationKey(
      fixtureBytes: SecretSyncV1GoldenVectors.generationKeyBytes
    )
    let payloadContext = try SecretSyncV1GoldenVectors.boundContext()
    let proof = try aes.seal(
      plaintext: Data("known-generation-key".utf8),
      using: expectedKey,
      context: payloadContext
    )

    let recipientKey = try hpke.openRecipientGenerationKey(
      SecretSyncV1GoldenVectors.recipientWrappedKey,
      using: P256.KeyAgreement.PrivateKey(
        rawRepresentation: SecretSyncV1GoldenVectors.recipientPrivateKeyBytes
      ),
      context: SecretSyncV1GoldenVectors.recipientContext()
    )
    #expect(
      try aes.open(
        sealedBytes: proof,
        using: recipientKey,
        context: payloadContext
      ) == Data("known-generation-key".utf8)
    )

    let recoveryKey = try hpke.openRecoveryGenerationKey(
      SecretSyncV1GoldenVectors.recoveryWrappedKey,
      using: P256.KeyAgreement.PrivateKey(
        rawRepresentation: SecretSyncV1GoldenVectors.recoveryPrivateKeyBytes
      ),
      context: SecretSyncV1GoldenVectors.recoveryContext()
    )
    #expect(
      try aes.open(
        sealedBytes: proof,
        using: recoveryKey,
        context: payloadContext
      ) == Data("known-generation-key".utf8)
    )
  }

  @Test("random HPKE creation is one-shot and non-repeating")
  func randomizedHPKESealOpen() throws {
    // The routine and recovery lanes deliberately mirror each other in one
    // matrix so nonce-free HPKE randomness and typed round trips cannot drift.
    let suite = try SecretSyncV1GoldenVectors.suite()
    let hpke = try SecretSyncHPKEEnvelopeProvider(suite: suite)
    let aes = try SecretSyncAESGCMProvider(suite: suite)
    let generationKey = SecretSyncGenerationKey.generate()
    let payloadContext = try SecretSyncV1GoldenVectors.boundContext()
    let proof = try aes.seal(
      plaintext: Data("hpke-round-trip".utf8),
      using: generationKey,
      context: payloadContext
    )

    let recipientPrivate = P256.KeyAgreement.PrivateKey()
    let recipientDescriptor = try SecretSyncV1GoldenVectors.recipientDescriptor(
      bytes: recipientPrivate.publicKey.x963Representation
    )
    let recipientOne = try hpke.sealGenerationKey(
      generationKey,
      for: recipientDescriptor,
      context: SecretSyncV1GoldenVectors.recipientContext()
    )
    let recipientTwo = try hpke.sealGenerationKey(
      generationKey,
      for: recipientDescriptor,
      context: SecretSyncV1GoldenVectors.recipientContext()
    )
    #expect(recipientOne.count == 113)
    #expect(recipientTwo.count == 113)
    #expect(recipientOne.prefix(65) != recipientTwo.prefix(65))
    #expect(recipientOne != recipientTwo)
    for wrapped in [recipientOne, recipientTwo] {
      let opened = try hpke.openRecipientGenerationKey(
        wrapped,
        using: recipientPrivate,
        context: SecretSyncV1GoldenVectors.recipientContext()
      )
      #expect(
        try aes.open(
          sealedBytes: proof,
          using: opened,
          context: payloadContext
        ) == Data("hpke-round-trip".utf8)
      )
    }

    let recoveryPrivate = P256.KeyAgreement.PrivateKey()
    let recoveryDescriptor = try SecretSyncV1GoldenVectors.recoveryDescriptor(
      bytes: recoveryPrivate.publicKey.x963Representation
    )
    let recoveryOne = try hpke.sealRecoveryGenerationKey(
      generationKey,
      for: recoveryDescriptor,
      context: SecretSyncV1GoldenVectors.recoveryContext()
    )
    let recoveryTwo = try hpke.sealRecoveryGenerationKey(
      generationKey,
      for: recoveryDescriptor,
      context: SecretSyncV1GoldenVectors.recoveryContext()
    )
    #expect(recoveryOne.count == 113)
    #expect(recoveryTwo.count == 113)
    #expect(recoveryOne.prefix(65) != recoveryTwo.prefix(65))
    #expect(recoveryOne != recoveryTwo)
    for wrapped in [recoveryOne, recoveryTwo] {
      let opened = try hpke.openRecoveryGenerationKey(
        wrapped,
        using: recoveryPrivate,
        context: SecretSyncV1GoldenVectors.recoveryContext()
      )
      #expect(
        try aes.open(
          sealedBytes: proof,
          using: opened,
          context: payloadContext
        ) == Data("hpke-round-trip".utf8)
      )
    }
  }

  @Test("fixed AES OPEN and randomized creation satisfy framing")
  func aesVectorsAndRandomizedCreation() throws {
    let aes = try SecretSyncAESGCMProvider(
      suite: SecretSyncV1GoldenVectors.suite()
    )
    let fixedKey = try SecretSyncGenerationKey(
      fixtureBytes: SecretSyncV1GoldenVectors.aesKeyBytes
    )
    let context = try SecretSyncV1GoldenVectors.boundContext()
    #expect(
      try aes.open(
        sealedBytes: SecretSyncV1GoldenVectors.aesCombined,
        using: fixedKey,
        context: context
      ) == SecretSyncV1GoldenVectors.aesPlaintext
    )

    let key = SecretSyncGenerationKey.generate()
    #expect(key.bitCount == 256)
    let plaintext = Data("randomized-aes-round-trip".utf8)
    let one = try aes.seal(plaintext: plaintext, using: key, context: context)
    let two = try aes.seal(plaintext: plaintext, using: key, context: context)
    #expect(one.count == plaintext.count + 28)
    #expect(two.count == plaintext.count + 28)
    #expect(one.prefix(12) != two.prefix(12))
    #expect(try aes.open(sealedBytes: one, using: key, context: context) == plaintext)
    #expect(try aes.open(sealedBytes: two, using: key, context: context) == plaintext)
  }
}
