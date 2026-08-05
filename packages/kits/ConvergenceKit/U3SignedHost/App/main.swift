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
  case checkpointRecordsAbsent
  // Carries the first checkpoint field that disagreed with the stored record,
  // so a refused resume names what was wrong instead of only that it refused.
  case checkpointFieldMismatch(String)
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
      } catch let error as U3SignedHostFailure {
        // The refusal detail is written where the checkpoint path is known,
        // inside resumeInterruptedCustody. Here only the fixed token is due.
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

  /// Finishes the cleanup a previous run was interrupted before completing.
  ///
  /// The checkpoint is never authority on its own. It is same-user file data
  /// with no MAC, no signature, and no Keychain binding, so its credential ID
  /// alone is not evidence that the records it names are the records this run
  /// wrote — a stale checkpoint from an earlier run, or a partially written
  /// one, would otherwise be enough to delete an unrelated credential's
  /// handles. The stored signing and agreement records are the ground truth
  /// the checkpoint must agree with, field for field, before anything is
  /// removed. Codex finding 98abbd7925148191ac433b614b7ba5c8.
  ///
  /// A refusal deliberately leaves the checkpoint on disk. Clearing it would
  /// destroy the evidence a developer needs to see what disagreed.
  private func resumeInterruptedCustody(
    with custody: SecretSyncSecureEnclaveCustody,
    checkpointStore: U3CustodyCheckpointStore
  ) async throws {
    guard let checkpoint = try checkpointStore.read() else { return }
    do {
      try await requireCheckpointMatchesStoredRecords(
        checkpoint,
        custody: custody
      )
    } catch let refusal as U3SignedHostFailure {
      // Reported here rather than at the top-level catch because this is the
      // only scope that knows where the retained checkpoint lives, and a
      // refusal is useless to a developer who cannot find the file to clear.
      writeCheckpointRefusalDetail(
        refusal,
        checkpointPath: checkpointStore.checkpointPath
      )
      throw refusal
    }
    try await custody.removeCredentialForPhysicalProof(checkpoint.credentialID)
    try await verifyProductionAbsence(
      with: custody,
      credentialID: checkpoint.credentialID
    )
    try verifyKeychainAbsence(for: checkpoint.credentialID)
    try checkpointStore.clear()
  }

  /// Proves the checkpoint describes the records it is about to authorize the
  /// deletion of, and throws without deleting anything when it does not.
  ///
  /// Every field the checkpoint carries about the two role records is compared,
  /// not just the credential ID that selects them. The reads are the ordinary
  /// production retrieval methods: non-destructive, no Secure Enclave key is
  /// reconstructed, and each one takes a fresh authority authorization — so a
  /// resume can no longer delete custody records without the device owner
  /// present.
  ///
  /// `deviceID` is the one checkpoint field left uncompared: a stored record
  /// carries no device identity, so there is no ground truth to match it
  /// against.
  private func requireCheckpointMatchesStoredRecords(
    _ checkpoint: U3CustodyCheckpoint,
    custody: SecretSyncSecureEnclaveCustody
  ) async throws {
    let credentialID = checkpoint.credentialID
    let signingHandle: SigningPrivateKeyHandle
    let agreementHandle: KeyAgreementPrivateKeyHandle
    let signingDescriptor: SigningPublicKeyDescriptor
    let agreementDescriptor: KeyAgreementPublicKeyDescriptor
    do {
      signingHandle = try await custody.signingPrivateKeyHandle(
        for: credentialID
      )
      agreementHandle = try await custody.keyAgreementPrivateKeyHandle(
        for: credentialID
      )
      signingDescriptor = try await custody.signingPublicCredential(
        for: credentialID
      )
      agreementDescriptor = try await custody.keyAgreementPublicCredential(
        for: credentialID
      )
    } catch SecretSyncCustodyError.missingHandle {
      // Absent records mean the checkpoint does not describe this machine's
      // current state. Every other custody error — missing entitlement, failed
      // authorization — propagates unchanged so it keeps its own diagnosis.
      throw U3SignedHostFailure.checkpointRecordsAbsent
    }

    // Ordered so the strongest identity evidence for each role is stated first
    // and the reported field is the most specific disagreement available.
    let comparisons: [(field: String, agrees: Bool)] = [
      (
        "signingHandleID",
        signingHandle.rawValue == checkpoint.signingHandleID
      ),
      (
        "signingAlgorithm",
        signingDescriptor.algorithmIdentifier == checkpoint.signingAlgorithm
      ),
      (
        "signingKeyIdentifier",
        signingDescriptor.keyIdentifier == checkpoint.signingKeyIdentifier
      ),
      (
        "signingPublicKey",
        signingDescriptor.publicKeyBytes == checkpoint.signingPublicKey
      ),
      (
        "agreementHandleID",
        agreementHandle.rawValue == checkpoint.agreementHandleID
      ),
      (
        "agreementAlgorithm",
        agreementDescriptor.algorithmIdentifier == checkpoint.agreementAlgorithm
      ),
      (
        "agreementKeyIdentifier",
        agreementDescriptor.keyIdentifier == checkpoint.agreementKeyIdentifier
      ),
      (
        "agreementPublicKey",
        agreementDescriptor.publicKeyBytes == checkpoint.agreementPublicKey
      ),
    ]
    guard let disagreement = comparisons.first(where: { !$0.agrees }) else {
      return
    }
    throw U3SignedHostFailure.checkpointFieldMismatch(disagreement.field)
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

  /// The checkpoint's on-disk location, so a refusal can name the file a
  /// developer has to delete rather than leaving them to find it.
  var checkpointPath: String {
    directoryURL.appendingPathComponent(Self.fileName).path
  }

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

private func classification(for failure: U3SignedHostFailure) -> String {
  switch failure {
  case .checkpointRecordsAbsent, .checkpointFieldMismatch:
    // A refused resume is not a failed proof: nothing was deleted and the
    // checkpoint is still on disk. It gets its own token so a developer can
    // tell the two outcomes apart at a glance.
    "checkpoint-unmatched"
  case .inactiveApplication, .invalidEntitlementShape,
    .invalidKeychainAttributes, .invalidProof, .incompleteCleanup,
    .invalidCheckpoint:
    "proof-failed"
  }
}

/// Reports on standard error why a resume declined to delete, and how to clear
/// the block it leaves behind.
///
/// Standard output carries exactly one fixed line because
/// `run-physical-proof.sh` compares it byte for byte, so the detail goes to
/// standard error instead of loosening that comparison. The message names the
/// checkpoint's full path and says what to do with it: a refusal deliberately
/// keeps the checkpoint, which means every later run refuses too until the file
/// is removed. A developer who is told only which field disagreed still has no
/// idea how to get the harness running again, so the remedy travels with the
/// diagnosis rather than living in a document they will not be reading.
private func writeCheckpointRefusalDetail(
  _ failure: U3SignedHostFailure,
  checkpointPath: String
) {
  let disagreement: String
  switch failure {
  case .checkpointFieldMismatch(let field):
    disagreement = field
  case .checkpointRecordsAbsent:
    disagreement = "records-absent"
  case .inactiveApplication, .invalidEntitlementShape,
    .invalidKeychainAttributes, .invalidProof, .incompleteCleanup,
    .invalidCheckpoint:
    return
  }
  let message = """
    U3_SIGNED_HOST_CHECKPOINT_DISAGREEMENT=\(disagreement)
    U3_SIGNED_HOST_CHECKPOINT_PATH=\(checkpointPath)
    U3_SIGNED_HOST_CHECKPOINT_REMEDY: The checkpoint on disk does not describe \
    the custody records it names, so nothing was deleted and both Keychain \
    records are intact. The checkpoint was kept on purpose, as evidence. Every \
    later run will refuse the same way until it is removed. Inspect it, then \
    delete it to let the harness start a fresh run:
        rm '\(checkpointPath)'

    """
  FileHandle.standardError.write(Data(message.utf8))
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
