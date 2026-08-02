import AppKit
import ConvergenceKit
import Darwin
import Foundation
import Security

@_spi(SecretSyncPhysicalProof) import ConvergenceKitAppleSecurity

private enum U3SignedHostFailure: Error {
  case inactiveApplication
  case invalidEntitlementShape
  case invalidKeychainAttributes
  case invalidProof
  case incompleteCleanup
  case invalidCheckpoint
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
    try verifyRuntimeEntitlements()

    let creator = SecretSyncSecureEnclaveCustody()
    let checkpointStore = try U3CustodyCheckpointStore()
    try await resumeInterruptedCustody(
      with: creator,
      checkpointStore: checkpointStore
    )
    guard SecretSyncSecureEnclaveCustody.hardwareAvailable else {
      throw SecretSyncCustodyError.hardwareUnavailable
    }
    let generation = try await creator.createCredential(
      for: TrustedDeviceID(UUID()),
      checkpointBeforePersistence: { generation in
        try checkpointStore.write(generation)
      }
    )
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
      try await verifyProductionAbsence(
        with: reloaded,
        credentialID: generation.credentialID
      )
      try verifyKeychainAbsence(for: generation.credentialID)
      try checkpointStore.clear()
    } catch {
      let proofFailure = error
      do {
        try await creator.removeCredentialForPhysicalProof(
          generation.credentialID
        )
        try await verifyProductionAbsence(
          with: creator,
          credentialID: generation.credentialID
        )
        try verifyKeychainAbsence(for: generation.credentialID)
        try checkpointStore.clear()
      } catch {
        // Cleanup failure takes precedence and the durable checkpoint remains.
        throw error
      }
      throw proofFailure
    }
  }

  private func resumeInterruptedCustody(
    with custody: SecretSyncSecureEnclaveCustody,
    checkpointStore: U3CustodyCheckpointStore
  ) async throws {
    guard let checkpoint = try checkpointStore.read() else { return }
    try await custody.removeCredentialForPhysicalProof(checkpoint.credentialID)
    try await verifyProductionAbsence(
      with: custody,
      credentialID: checkpoint.credentialID
    )
    try verifyKeychainAbsence(for: checkpoint.credentialID)
    try checkpointStore.clear()
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

private struct U3CustodyCheckpoint: Codable {
  let deviceID: UUID
  let credentialIDValue: UUID
  let signingHandleID: UUID
  let agreementHandleID: UUID
  let signingAlgorithm: String
  let signingKeyIdentifier: Data
  let signingPublicKey: Data
  let agreementAlgorithm: String
  let agreementKeyIdentifier: Data
  let agreementPublicKey: Data

  init(_ generation: SecretSyncCustodyCredentialGeneration) {
    deviceID = generation.deviceID.rawValue
    credentialIDValue = generation.credentialID.rawValue
    signingHandleID = generation.signingHandle.rawValue
    agreementHandleID = generation.agreementHandle.rawValue
    signingAlgorithm = generation.signingPublicKey.algorithmIdentifier
    signingKeyIdentifier = generation.signingPublicKey.keyIdentifier
    signingPublicKey = generation.signingPublicKey.publicKeyBytes
    agreementAlgorithm = generation.agreementPublicKey.algorithmIdentifier
    agreementKeyIdentifier = generation.agreementPublicKey.keyIdentifier
    agreementPublicKey = generation.agreementPublicKey.publicKeyBytes
  }

  var credentialID: DeviceCredentialID {
    DeviceCredentialID(credentialIDValue)
  }
}

private struct U3CustodyCheckpointStore: Sendable {
  private static let directoryMode: mode_t = 0o700
  private static let fileMode: mode_t = 0o600
  private static let fileName = "provisional-custody.json"
  private let directoryURL: URL

  init() throws {
    directoryURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support", isDirectory: true)
      .appendingPathComponent("com.codedaptive.mootx01", isDirectory: true)
      .appendingPathComponent("U3SignedHost", isDirectory: true)
    try Self.requirePrivateDirectory(directoryURL)
  }

  func read() throws -> U3CustodyCheckpoint? {
    let directory = try openDirectory()
    defer { close(directory) }
    let descriptor = openat(
      directory, Self.fileName, O_RDONLY | O_NOFOLLOW
    )
    if descriptor < 0, errno == ENOENT { return nil }
    guard descriptor >= 0, Self.isPrivateRegularFile(descriptor) else {
      if descriptor >= 0 { close(descriptor) }
      throw U3SignedHostFailure.invalidCheckpoint
    }
    defer { close(descriptor) }
    return try JSONDecoder().decode(
      U3CustodyCheckpoint.self,
      from: Self.readAll(descriptor)
    )
  }

  func write(_ generation: SecretSyncCustodyCredentialGeneration) throws {
    let directory = try openDirectory()
    defer { close(directory) }
    let bytes = try JSONEncoder().encode(U3CustodyCheckpoint(generation))
    let temporaryName = ".\(Self.fileName).\(UUID().uuidString.lowercased()).tmp"
    let descriptor = openat(
      directory,
      temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
      Self.fileMode
    )
    guard descriptor >= 0 else { throw U3SignedHostFailure.invalidCheckpoint }
    var installed = false
    defer {
      close(descriptor)
      if !installed { _ = unlinkat(directory, temporaryName, 0) }
    }
    try Self.writeAll(bytes, descriptor: descriptor)
    guard fsync(descriptor) == 0,
      renameat(directory, temporaryName, directory, Self.fileName) == 0,
      fsync(directory) == 0
    else {
      throw U3SignedHostFailure.invalidCheckpoint
    }
    installed = true
  }

  func clear() throws {
    let directory = try openDirectory()
    defer { close(directory) }
    if unlinkat(directory, Self.fileName, 0) != 0, errno != ENOENT {
      throw U3SignedHostFailure.invalidCheckpoint
    }
    guard fsync(directory) == 0 else {
      throw U3SignedHostFailure.invalidCheckpoint
    }
  }

  private func openDirectory() throws -> Int32 {
    try Self.requirePrivateDirectory(directoryURL)
    let descriptor = open(
      directoryURL.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW
    )
    guard descriptor >= 0 else { throw U3SignedHostFailure.invalidCheckpoint }
    return descriptor
  }

  private static func requirePrivateDirectory(_ url: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: directoryMode)]
      )
    } catch {
      throw U3SignedHostFailure.invalidCheckpoint
    }
    var status = stat()
    guard lstat(url.path, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFDIR,
      status.st_uid == geteuid(),
      (status.st_mode & 0o777) == directoryMode
    else {
      throw U3SignedHostFailure.invalidCheckpoint
    }
  }

  private static func isPrivateRegularFile(_ descriptor: Int32) -> Bool {
    var status = stat()
    return fstat(descriptor, &status) == 0
      && (status.st_mode & S_IFMT) == S_IFREG
      && status.st_uid == geteuid()
      && (status.st_mode & 0o777) == fileMode
  }

  private static func readAll(_ descriptor: Int32) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count == 0 { return result }
      guard count > 0 else { throw U3SignedHostFailure.invalidCheckpoint }
      result.append(contentsOf: buffer.prefix(Int(count)))
    }
  }

  private static func writeAll(
    _ data: Data,
    descriptor: Int32
  ) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard var pointer = rawBuffer.baseAddress else { return }
      var remaining = rawBuffer.count
      while remaining > 0 {
        let count = Darwin.write(descriptor, pointer, remaining)
        guard count > 0 else { throw U3SignedHostFailure.invalidCheckpoint }
        remaining -= count
        pointer = pointer.advanced(by: count)
      }
    }
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
