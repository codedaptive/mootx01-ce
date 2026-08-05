import ConvergenceKit
import Foundation
import Testing

@_spi(SecretSyncPhysicalProof) @testable import ConvergenceKitAppleSecurity

@Suite("SecretSync proof of possession")
struct SecretSyncProofOfPossessionTests {
  @Test("both role proofs verify only for the exact complete transcript")
  func exactTranscriptAndRoles() async throws {
    let provider = SecretSyncTestOnlyCustodyProvider()
    let generation = try await provider.createGeneration(
      for: TrustedDeviceID(fixtureUUID(10))
    )
    let transcript = try fixtureTranscript(generation: generation)
    let signingChallenge = try SecretSyncSigningProofChallenge(
      transcript: transcript
    )
    let agreement = try SecretSyncAgreementProofChallenge.create(
      transcript: transcript
    )

    let signing = try await provider.proveSigningKeyPossession(
      SigningProofOfPossessionRequest(
        credentialID: generation.credentialID,
        privateKeyHandle: generation.signingHandle,
        challengeID: transcript.challengeID,
        challengeBytes: signingChallenge.canonicalBytes
      )
    )
    let agreementProof = try await provider.proveKeyAgreementKeyPossession(
      KeyAgreementProofOfPossessionRequest(
        credentialID: generation.credentialID,
        privateKeyHandle: generation.agreementHandle,
        challengeID: transcript.challengeID,
        challengeBytes: agreement.challenge.canonicalBytes
      )
    )

    #expect(
      try SecretSyncProofOfPossession.verifySigning(
        signing.proofBytes,
        challengeBytes: signingChallenge.canonicalBytes,
        publicKey: generation.signingPublicKey
      )
    )
    #expect(
      try signingChallenge.verify(
        signing.proofBytes,
        publicKey: generation.signingPublicKey
      )
    )
    #expect(
      try agreement.verifier.verify(
        agreementProof.proofBytes,
        challenge: agreement.challenge,
        candidatePublicKey: generation.agreementPublicKey
      )
    )
    #expect(
      !((try? agreement.verifier.verify(
        signing.proofBytes,
        challenge: agreement.challenge,
        candidatePublicKey: generation.agreementPublicKey
      )) ?? false)
    )
  }

  @Test("head, expiry, credential, and challenge substitution are rejected")
  func transcriptSubstitutionFails() async throws {
    let provider = SecretSyncTestOnlyCustodyProvider()
    let generation = try await provider.createGeneration(
      for: TrustedDeviceID(fixtureUUID(11))
    )
    let transcript = try fixtureTranscript(generation: generation)
    let original = try SecretSyncSigningProofChallenge(transcript: transcript)
    let proof = try await provider.proveSigningKeyPossession(
      SigningProofOfPossessionRequest(
        credentialID: generation.credentialID,
        privateKeyHandle: generation.signingHandle,
        challengeID: transcript.challengeID,
        challengeBytes: original.canonicalBytes
      )
    )

    for mutation in try mutatedTranscripts(
      transcript,
      generation: generation
    ) {
      let challenge = try SecretSyncSigningProofChallenge(transcript: mutation)
      #expect(
        !(try SecretSyncProofOfPossession.verifySigning(
          proof.proofBytes,
          challengeBytes: challenge.canonicalBytes,
          publicKey: generation.signingPublicKey
        ))
      )
    }
  }

  @Test("expired challenges fail validation before private-key use")
  func expiryFailsClosed() async throws {
    let provider = SecretSyncTestOnlyCustodyProvider()
    let generation = try await provider.createGeneration(
      for: TrustedDeviceID(fixtureUUID(12))
    )
    let transcript = try fixtureTranscript(
      generation: generation,
      expiresAt: Date(timeIntervalSince1970: 150)
    )
    let challenge = try SecretSyncSigningProofChallenge(transcript: transcript)

    #expect(
      !SecretSyncProofOfPossession.isUnexpired(
        challenge.canonicalBytes,
        now: Date(timeIntervalSince1970: 151)
      )
    )
  }
}

private func fixtureTranscript(
  generation: SecretSyncTestOnlyCustodyProvider.Generation,
  expiresAt: Date = Date(timeIntervalSince1970: 200)
) throws -> SecretSyncProofOfPossessionTranscript {
  try SecretSyncProofOfPossessionTranscript(
    challengeID: fixtureUUID(20),
    sessionID: fixtureUUID(21),
    issuedAt: Date(timeIntervalSince1970: 100),
    expiresAt: expiresAt,
    deviceID: generation.deviceID,
    credentialID: generation.credentialID,
    signingPublicKey: generation.signingPublicKey,
    agreementPublicKey: generation.agreementPublicKey,
    authorityCredentialID: DeviceCredentialID(fixtureUUID(22)),
    freshnessCommitment: try SecretBootstrapFreshnessCommitment(
      scopeID: SecretScopeID(fixtureUUID(23)),
      latestPolicyEpoch: 7,
      headCommitDigest: fixtureDigest(0x71),
      policyDigest: fixtureDigest(0x72)
    )
  )
}

private func mutatedTranscripts(
  _ original: SecretSyncProofOfPossessionTranscript,
  generation: SecretSyncTestOnlyCustodyProvider.Generation
) throws -> [SecretSyncProofOfPossessionTranscript] {
  let changedHead = try SecretBootstrapFreshnessCommitment(
    scopeID: original.freshnessCommitment.scopeID,
    latestPolicyEpoch: original.freshnessCommitment.latestPolicyEpoch,
    headCommitDigest: fixtureDigest(0x7F),
    policyDigest: original.freshnessCommitment.policyDigest
  )
  return [
    try original.replacing(freshnessCommitment: changedHead),
    try original.replacing(expiresAt: original.expiresAt.addingTimeInterval(1)),
    try original.replacing(credentialID: DeviceCredentialID(fixtureUUID(24))),
    try original.replacing(challengeID: fixtureUUID(25)),
  ]
}

private func fixtureDigest(_ byte: UInt8) throws -> SecretRecordDigest {
  try SecretRecordDigest(bytes: Data(repeating: byte, count: 32))
}

private func fixtureUUID(_ byte: UInt8) -> UUID {
  UUID(uuid: (
    byte, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, byte
  ))
}
