import AppKit
import ConvergenceKit
import Foundation
import Security

@_spi(SecretSyncPhysicalProof) import ConvergenceKitAppleSecurity

private enum U3SignedHostFailure: Error {
  case inactiveApplication
  case invalidEntitlementShape
  case invalidKeychainAttributes
  case invalidProof
  case incompleteCleanup
}

private final class U3SignedHostDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.activate()
    Task { @MainActor in
      do {
        try await waitUntilActive()
        try await U3SignedPhysicalProof().run()
        writeFixedResult("pass")
        exit(EXIT_SUCCESS)
      } catch let error as SecretSyncCustodyError {
        writeFixedResult(classification(for: error))
        exit(EXIT_FAILURE)
      } catch {
        writeFixedResult("proof-failed")
        exit(EXIT_FAILURE)
      }
    }
  }

  @MainActor
  private func waitUntilActive() async throws {
    // Production custody reads NSApplication.isActive. Bound the activation
    // wait so the proof cannot silently substitute a forced foreground seam.
    for _ in 0..<100 {
      if NSApplication.shared.isActive {
        return
      }
      try await Task<Never, Never>.sleep(for: .milliseconds(50))
    }
    throw U3SignedHostFailure.inactiveApplication
  }
}

private struct U3SignedPhysicalProof {
  private static let signingService =
    "com.codedaptive.mootx01.secret-sync.signing-handle"
  private static let agreementService =
    "com.codedaptive.mootx01.secret-sync.agreement-handle"

  func run() async throws {
    guard SecretSyncSecureEnclaveCustody.hardwareAvailable else {
      throw SecretSyncCustodyError.hardwareUnavailable
    }
    try verifyRuntimeEntitlements()

    let creator = SecretSyncSecureEnclaveCustody()
    let generation = try await creator.createCredential(
      for: TrustedDeviceID(UUID())
    )
    var cleanupRequired = true
    do {
      try verifyStoredAttributes(for: generation.credentialID)

      // A new production actor owns fresh LocalAuthentication contexts and
      // reconstructs both Secure Enclave keys only from stored opaque handles.
      let reloaded = SecretSyncSecureEnclaveCustody()
      let signingHandle = try await reloaded.signingPrivateKeyHandle(
        for: generation.credentialID
      )
      let agreementHandle = try await reloaded.keyAgreementPrivateKeyHandle(
        for: generation.credentialID
      )
      guard
        signingHandle == generation.signingHandle,
        agreementHandle == generation.agreementHandle,
        try await reloaded.signingPublicCredential(
          for: generation.credentialID
        ) == generation.signingPublicKey,
        try await reloaded.keyAgreementPublicCredential(
          for: generation.credentialID
        ) == generation.agreementPublicKey
      else {
        throw U3SignedHostFailure.invalidProof
      }

      try await proveBothRoles(
        with: reloaded,
        generation: generation,
        signingHandle: signingHandle,
        agreementHandle: agreementHandle
      )

      try await reloaded.removeCredentialForPhysicalProof(
        generation.credentialID
      )
      cleanupRequired = false
      try await verifyProductionAbsence(
        with: reloaded,
        credentialID: generation.credentialID
      )
      try verifyKeychainAbsence(for: generation.credentialID)
    } catch {
      if cleanupRequired {
        try? await creator.removeCredentialForPhysicalProof(
          generation.credentialID
        )
      }
      throw error
    }
  }

  private func proveBothRoles(
    with custody: SecretSyncSecureEnclaveCustody,
    generation: SecretSyncCustodyCredentialGeneration,
    signingHandle: SigningPrivateKeyHandle,
    agreementHandle: KeyAgreementPrivateKeyHandle
  ) async throws {
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
        headCommitDigest: try digest(0x31),
        policyDigest: try digest(0x32)
      )
    )
    let signingChallenge = try SecretSyncSigningProofChallenge(
      transcript: transcript
    )
    let agreement = try SecretSyncAgreementProofChallenge.create(
      transcript: transcript
    )
    let signingProof = try await custody.proveSigningKeyPossession(
      SigningProofOfPossessionRequest(
        credentialID: generation.credentialID,
        privateKeyHandle: signingHandle,
        challengeID: transcript.challengeID,
        challengeBytes: signingChallenge.canonicalBytes
      )
    )
    let agreementProof = try await custody.proveKeyAgreementKeyPossession(
      KeyAgreementProofOfPossessionRequest(
        credentialID: generation.credentialID,
        privateKeyHandle: agreementHandle,
        challengeID: transcript.challengeID,
        challengeBytes: agreement.challenge.canonicalBytes
      )
    )
    guard
      try signingChallenge.verify(
        signingProof.proofBytes,
        publicKey: generation.signingPublicKey
      ),
      try agreement.verifier.verify(
        agreementProof.proofBytes,
        challenge: agreement.challenge,
        candidatePublicKey: generation.agreementPublicKey
      )
    else {
      throw U3SignedHostFailure.invalidProof
    }
  }

  private func verifyRuntimeEntitlements() throws {
    guard let task = SecTaskCreateFromSelf(nil),
      let applicationIdentifier = SecTaskCopyValueForEntitlement(
        task,
        "com.apple.application-identifier" as CFString,
        nil
      ) as? String,
      let teamIdentifier = SecTaskCopyValueForEntitlement(
        task,
        "com.apple.developer.team-identifier" as CFString,
        nil
      ) as? String,
      let accessGroups = SecTaskCopyValueForEntitlement(
        task,
        "keychain-access-groups" as CFString,
        nil
      ) as? [String],
      !applicationIdentifier.isEmpty,
      !teamIdentifier.isEmpty,
      applicationIdentifier.hasPrefix(teamIdentifier + "."),
      accessGroups.contains(applicationIdentifier)
    else {
      throw U3SignedHostFailure.invalidEntitlementShape
    }
  }

  private func verifyStoredAttributes(
    for credentialID: DeviceCredentialID
  ) throws {
    for service in [Self.signingService, Self.agreementService] {
      var query = baseQuery(service: service, credentialID: credentialID)
      query[kSecReturnAttributes as String] = kCFBooleanTrue
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      var returned: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &returned)
      if status == errSecMissingEntitlement {
        throw SecretSyncCustodyError.missingEntitlement
      }
      guard status == errSecSuccess,
        let attributes = returned as? [String: Any],
        attributes[kSecAttrAccessible as String] as? String
          == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
        (attributes[kSecAttrSynchronizable as String] as? Bool) != true
      else {
        throw U3SignedHostFailure.invalidKeychainAttributes
      }
    }
  }

  private func verifyProductionAbsence(
    with custody: SecretSyncSecureEnclaveCustody,
    credentialID: DeviceCredentialID
  ) async throws {
    do {
      _ = try await custody.signingPrivateKeyHandle(for: credentialID)
      throw U3SignedHostFailure.incompleteCleanup
    } catch SecretSyncCustodyError.missingHandle {
      // Exact production retrieval must classify the deleted role as absent.
    }
    do {
      _ = try await custody.keyAgreementPrivateKeyHandle(for: credentialID)
      throw U3SignedHostFailure.incompleteCleanup
    } catch SecretSyncCustodyError.missingHandle {
      // Exact production retrieval must classify the deleted role as absent.
    }
  }

  private func verifyKeychainAbsence(
    for credentialID: DeviceCredentialID
  ) throws {
    for service in [Self.signingService, Self.agreementService] {
      let status = SecItemCopyMatching(
        baseQuery(service: service, credentialID: credentialID) as CFDictionary,
        nil
      )
      if status == errSecMissingEntitlement {
        throw SecretSyncCustodyError.missingEntitlement
      }
      guard status == errSecItemNotFound else {
        throw U3SignedHostFailure.incompleteCleanup
      }
    }
  }

  private func baseQuery(
    service: String,
    credentialID: DeviceCredentialID
  ) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String:
        credentialID.rawValue.uuidString.lowercased(),
      kSecAttrSynchronizable as String: kCFBooleanFalse!,
      kSecUseDataProtectionKeychain as String: kCFBooleanTrue!,
    ]
  }

  private func digest(_ byte: UInt8) throws -> SecretRecordDigest {
    try SecretRecordDigest(bytes: Data(repeating: byte, count: 32))
  }
}

private func classification(for error: SecretSyncCustodyError) -> String {
  switch error {
  case .missingEntitlement:
    "configuration-missing-entitlement"
  case .hardwareUnavailable:
    "hardware-unavailable"
  case .authorizationFailed:
    "authorization-failed"
  case .backgroundOperationDenied:
    "application-inactive"
  case .missingHandle, .corruptHandle, .duplicateHandle,
    .cryptographicFailure, .invalidProof, .missingProtectedHead,
    .corruptProtectedHead, .rollbackDetected:
    "proof-failed"
  }
}

private func writeFixedResult(_ result: String) {
  let line = "U3_SIGNED_HOST_RESULT=" + result + "\n"
  FileHandle.standardOutput.write(Data(line.utf8))
}

let application = NSApplication.shared
private let delegate = U3SignedHostDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
