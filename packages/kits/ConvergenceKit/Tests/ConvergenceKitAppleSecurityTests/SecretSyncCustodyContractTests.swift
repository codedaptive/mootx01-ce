import ConvergenceKit
import Foundation
import Security
import Testing

@testable import ConvergenceKitAppleSecurity

@Suite("SecretSync custody contracts")
struct SecretSyncCustodyContractTests {
  @Test("signing and agreement generations stay role-distinct")
  func roleDistinctHandlesAndDescriptors() async throws {
    let provider = SecretSyncTestOnlyCustodyProvider()
    let generation = try await provider.createGeneration(
      for: TrustedDeviceID(fixtureUUID(1))
    )

    #expect(generation.signingHandle.rawValue != generation.agreementHandle.rawValue)
    #expect(
      generation.signingPublicKey.keyIdentifier
        != generation.agreementPublicKey.keyIdentifier
    )
    #expect(
      generation.signingPublicKey.publicKeyBytes
        != generation.agreementPublicKey.publicKeyBytes
    )
  }

  @Test("replacement preserves device identity and rotates credential identity")
  func replacementUsesFreshCredentialID() async throws {
    let provider = SecretSyncTestOnlyCustodyProvider()
    let deviceID = TrustedDeviceID(fixtureUUID(2))
    let first = try await provider.createGeneration(for: deviceID)
    let second = try await provider.createGeneration(for: deviceID)

    #expect(first.deviceID == second.deviceID)
    #expect(first.credentialID != second.credentialID)
    #expect(first.signingHandle != second.signingHandle)
    #expect(first.agreementHandle != second.agreementHandle)
  }

  @Test("software provider source is outside every production source path")
  func softwareProviderIsTestOnly() throws {
    let thisFile = URL(fileURLWithPath: #filePath)
    let packageRoot =
      thisFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let productionRoot =
      packageRoot
      .appendingPathComponent("Sources/ConvergenceKitAppleSecurity")
    let productionFiles = try FileManager.default.contentsOfDirectory(
      at: productionRoot,
      includingPropertiesForKeys: nil
    )
    let forbidden = "SecretSyncTestOnlyCustodyProvider"
    for file in productionFiles where file.pathExtension == "swift" {
      let source = try String(contentsOf: file, encoding: .utf8)
      #expect(!source.contains(forbidden))
    }
  }

  @Test("opt-in supported-hardware custody and user-presence proof")
  func supportedHardwareProof() async throws {
    guard
      ProcessInfo.processInfo.environment["SECRET_SYNC_HARDWARE_PROOF"]
        == "1"
    else {
      return
    }
    guard SecretSyncSecureEnclaveCustody.hardwareAvailable else {
      throw SecretSyncCustodyError.hardwareUnavailable
    }

    let provider = makeSecretSyncHardwareCustodyForCLITest()
    let generation = try await provider.createCredential(
      for: TrustedDeviceID(UUID())
    )
    do {
      // A new provider owns new LA contexts and reloads the opaque handles
      // from the Data Protection Keychain rather than retaining key objects.
      let reloaded = makeSecretSyncHardwareCustodyForCLITest()
      let signingHandle = try await reloaded.signingPrivateKeyHandle(
        for: generation.credentialID
      )
      let agreementHandle = try await reloaded.keyAgreementPrivateKeyHandle(
        for: generation.credentialID
      )
      guard
        signingHandle == generation.signingHandle,
        agreementHandle == generation.agreementHandle,
        try hardwareAttributesAreLocked(generation)
      else {
        throw SecretSyncCustodyError.cryptographicFailure
      }

      let now = Date()
      let transcript = try SecretSyncProofOfPossessionTranscript(
        challengeID: UUID(),
        sessionID: UUID(),
        issuedAt: now.addingTimeInterval(-1),
        expiresAt: now.addingTimeInterval(300),
        deviceID: generation.deviceID,
        credentialID: generation.credentialID,
        signingPublicKey: generation.signingPublicKey,
        agreementPublicKey: generation.agreementPublicKey,
        authorityCredentialID: DeviceCredentialID(UUID()),
        freshnessCommitment: try SecretBootstrapFreshnessCommitment(
          scopeID: SecretScopeID(UUID()),
          latestPolicyEpoch: 1,
          headCommitDigest: hardwareDigest(0x31),
          policyDigest: hardwareDigest(0x32)
        )
      )
      let signingChallenge = try SecretSyncSigningProofChallenge(
        transcript: transcript
      )
      let agreement = try SecretSyncAgreementProofChallenge.create(
        transcript: transcript
      )
      let signingProof = try await reloaded.proveSigningKeyPossession(
        SigningProofOfPossessionRequest(
          credentialID: generation.credentialID,
          privateKeyHandle: signingHandle,
          challengeID: transcript.challengeID,
          challengeBytes: signingChallenge.canonicalBytes
        )
      )
      let agreementProof = try await reloaded.proveKeyAgreementKeyPossession(
        KeyAgreementProofOfPossessionRequest(
          credentialID: generation.credentialID,
          privateKeyHandle: agreementHandle,
          challengeID: transcript.challengeID,
          challengeBytes: agreement.challenge.canonicalBytes
        )
      )
      guard
        try SecretSyncProofOfPossession.verifySigning(
          signingProof.proofBytes,
          challengeBytes: signingChallenge.canonicalBytes,
          publicKey: generation.signingPublicKey
        ),
        try agreement.verifier.verify(
          agreementProof.proofBytes,
          challenge: agreement.challenge,
          candidatePublicKey: generation.agreementPublicKey
        ),
        !((try? agreement.verifier.verify(
          signingProof.proofBytes,
          challenge: agreement.challenge,
          candidatePublicKey: generation.agreementPublicKey
        )) ?? false)
      else {
        throw SecretSyncCustodyError.invalidProof
      }

      let changedHead = try SecretBootstrapFreshnessCommitment(
        scopeID: transcript.freshnessCommitment.scopeID,
        latestPolicyEpoch: transcript.freshnessCommitment.latestPolicyEpoch,
        headCommitDigest: hardwareDigest(0x41),
        policyDigest: transcript.freshnessCommitment.policyDigest
      )
      let changedChallenge = try SecretSyncSigningProofChallenge(
        transcript: transcript.replacing(
          freshnessCommitment: changedHead
        )
      )
      guard
        !(try SecretSyncProofOfPossession.verifySigning(
          signingProof.proofBytes,
          challengeBytes: changedChallenge.canonicalBytes,
          publicKey: generation.signingPublicKey
        ))
      else {
        throw SecretSyncCustodyError.invalidProof
      }

      let background = SecretSyncLocalAuthorization()
      do {
        _ = try await background.context(for: .background)
        throw SecretSyncCustodyError.backgroundOperationDenied
      } catch SecretSyncCustodyError.backgroundOperationDenied {
        // Expected: the denial occurs before any Keychain/private operation.
      }
      await reloaded.removeCredentialForHardwareProof(
        generation.credentialID
      )
    } catch let error as SecretSyncCustodyError {
      await provider.removeCredentialForHardwareProof(
        generation.credentialID
      )
      throw error
    } catch {
      await provider.removeCredentialForHardwareProof(
        generation.credentialID
      )
      throw SecretSyncCustodyError.cryptographicFailure
    }
  }
}

private func hardwareAttributesAreLocked(
  _ generation: SecretSyncCustodyCredentialGeneration
) throws -> Bool {
  for role in [SecretSyncStoredKeyRole.signing, .agreement] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: role.service,
      kSecAttrAccount as String:
        generation.credentialID.rawValue.uuidString.lowercased(),
      kSecAttrSynchronizable as String: kCFBooleanFalse!,
      kSecReturnAttributes as String: kCFBooleanTrue!,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    #if os(macOS)
      query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue
    #endif
    var returned: CFTypeRef?
    guard
      SecItemCopyMatching(query as CFDictionary, &returned) == errSecSuccess,
      let attributes = returned as? [String: Any],
      attributes[kSecAttrAccessible as String] as? String
        == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
      (attributes[kSecAttrSynchronizable as String] as? Bool) != true
    else {
      return false
    }
  }
  return true
}

private func hardwareDigest(_ byte: UInt8) throws -> SecretRecordDigest {
  try SecretRecordDigest(bytes: Data(repeating: byte, count: 32))
}

private func fixtureUUID(_ byte: UInt8) -> UUID {
  UUID(
    uuid: (
      byte, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, byte
    ))
}
