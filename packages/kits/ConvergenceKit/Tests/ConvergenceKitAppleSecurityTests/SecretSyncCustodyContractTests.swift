import ConvergenceKit
import CryptoKit
import Darwin
import Foundation
import Security
import Testing

@_spi(SecretSyncPhysicalProof) @testable import ConvergenceKitAppleSecurity

@Suite("SecretSync custody contracts")
struct SecretSyncCustodyContractTests {
  @Test("durable checkpoint precedes both handle inserts")
  func durableCheckpointPrecedesHandlePersistence() async throws {
    let fixture = try custodyPersistenceFixture()
    let probe = SecretSyncCustodyPersistenceProbe()

    let returned = try await SecretSyncSecureEnclaveCustody
      .persistCredentialGeneration(
        fixture.generation,
        signingRecord: fixture.signingRecord,
        agreementRecord: fixture.agreementRecord,
        checkpointBeforePersistence: { generation in
          #expect(generation == fixture.generation)
          await probe.record(.checkpoint)
        },
        insert: { record in
          await probe.record(record.role == .signing ? .insertSigning : .insertAgreement)
        },
        remove: { _, role in
          await probe.record(role == .signing ? .removeSigning : .removeAgreement)
        }
      )

    #expect(returned == fixture.generation)
    #expect(
      await probe.events == [.checkpoint, .insertSigning, .insertAgreement]
    )
  }

  @Test("checkpoint failure performs zero inserts and zero cleanup writes")
  func checkpointFailurePerformsNoPersistence() async throws {
    let fixture = try custodyPersistenceFixture()
    let probe = SecretSyncCustodyPersistenceProbe()

    await #expect(throws: SecretSyncCustodyError.authorizationFailed) {
      _ = try await SecretSyncSecureEnclaveCustody.persistCredentialGeneration(
        fixture.generation,
        signingRecord: fixture.signingRecord,
        agreementRecord: fixture.agreementRecord,
        checkpointBeforePersistence: { _ in
          await probe.record(.checkpoint)
          throw SecretSyncCustodyError.authorizationFailed
        },
        insert: { _ in await probe.record(.insertSigning) },
        remove: { _, _ in await probe.record(.removeSigning) }
      )
    }
    #expect(await probe.events == [.checkpoint])
  }

  @Test("insert failure attempts both removals and gives cleanup error precedence")
  func insertFailureUsesStrictRollback() async throws {
    let fixture = try custodyPersistenceFixture()
    let probe = SecretSyncCustodyPersistenceProbe()

    await #expect(throws: SecretSyncCustodyError.missingEntitlement) {
      _ = try await SecretSyncSecureEnclaveCustody.persistCredentialGeneration(
        fixture.generation,
        signingRecord: fixture.signingRecord,
        agreementRecord: fixture.agreementRecord,
        checkpointBeforePersistence: { _ in await probe.record(.checkpoint) },
        insert: { record in
          if record.role == .agreement {
            await probe.record(.insertAgreement)
            throw SecretSyncCustodyError.duplicateHandle
          }
          await probe.record(.insertSigning)
        },
        remove: { _, role in
          await probe.record(role == .signing ? .removeSigning : .removeAgreement)
          if role == .signing {
            throw SecretSyncCustodyError.missingHandle
          }
          throw SecretSyncCustodyError.missingEntitlement
        }
      )
    }
    #expect(
      await probe.events == [
        .checkpoint, .insertSigning, .insertAgreement,
        .removeSigning, .removeAgreement,
      ]
    )
  }

  @Test("first insert failure still attempts both exact role removals")
  func firstInsertFailureUsesStrictRollback() async throws {
    let fixture = try custodyPersistenceFixture()
    let probe = SecretSyncCustodyPersistenceProbe()

    await #expect(throws: SecretSyncCustodyError.duplicateHandle) {
      _ = try await SecretSyncSecureEnclaveCustody.persistCredentialGeneration(
        fixture.generation,
        signingRecord: fixture.signingRecord,
        agreementRecord: fixture.agreementRecord,
        checkpointBeforePersistence: { _ in await probe.record(.checkpoint) },
        insert: { _ in
          await probe.record(.insertSigning)
          throw SecretSyncCustodyError.duplicateHandle
        },
        remove: { _, role in
          await probe.record(role == .signing ? .removeSigning : .removeAgreement)
          throw SecretSyncCustodyError.missingHandle
        }
      )
    }
    #expect(
      await probe.events == [
        .checkpoint, .insertSigning, .removeSigning, .removeAgreement,
      ]
    )
  }

  @Test("strict removal treats missing as absent and still attempts both roles")
  func strictRemovalIsIdempotentAndComplete() async throws {
    let credentialID = DeviceCredentialID(fixtureUUID(0x91))
    let probe = SecretSyncCustodyPersistenceProbe()

    try await SecretSyncSecureEnclaveCustody.removeCredentialRecords(
      credentialID
    ) { _, role in
      await probe.record(role == .signing ? .removeSigning : .removeAgreement)
      throw SecretSyncCustodyError.missingHandle
    }

    #expect(await probe.events == [.removeSigning, .removeAgreement])
  }

  @Test("public custody creation has no checkpoint-free compatibility overload")
  func custodyCreationRequiresCheckpointContract() throws {
    let source = try custodySource()
    #expect(source.components(separatedBy: "public func createCredential(").count == 2)
    #expect(source.components(separatedBy: "public func replaceCredential(").count == 2)
    #expect(source.contains("checkpointBeforePersistence:"))
    #expect(!source.contains("checkpointBeforePersistence: @Sendable") ||
      !source.contains("= { _ in }"))
  }

  @Test("signed host uses a fixed strict fsync-backed custody checkpoint")
  func signedHostDurableCheckpointContract() throws {
    let source = try signedHostSource()
    #expect(source.contains("O_NOFOLLOW"))
    #expect(source.contains("fsync("))
    #expect(source.contains("0o700"))
    #expect(source.contains("0o600"))
    #expect(source.contains("resumeInterruptedCustody"))
    #expect(source.contains("checkpointBeforePersistence:"))
    #expect(!source.contains("try?"))
    let resume = try #require(source.range(of: "resumeInterruptedCustody"))
    let create = try #require(source.range(of: "createCredential"))
    #expect(resume.lowerBound < create.lowerBound)
  }

  // U3SignedHost is an app target with no SwiftPM coverage, and its checkpoint
  // types are private inside main.swift, so the match gate cannot be exercised
  // behaviourally without restructuring U3SignedHost.xcodeproj. This asserts
  // the structural contract instead, in the same source-text idiom as the
  // durable-checkpoint test above: the gate consults every checkpoint field,
  // never deletes or clears anything itself, and always runs before removal.
  @Test("signed host proves the checkpoint against stored records before deleting")
  func signedHostCheckpointMatchGateContract() throws {
    let source = try signedHostSource()
    let resumeStart = try #require(
      source.range(of: "private func resumeInterruptedCustody(")
    )
    let gateStart = try #require(
      source.range(of: "private func requireCheckpointMatchesStoredRecords(")
    )
    let gateEnd = try #require(
      source.range(of: "private func proveBothRoles(")
    )
    #expect(resumeStart.lowerBound < gateStart.lowerBound)
    #expect(gateStart.lowerBound < gateEnd.lowerBound)

    let resume = String(source[resumeStart.lowerBound..<gateStart.lowerBound])
    let match = try #require(
      resume.range(of: "requireCheckpointMatchesStoredRecords(")
    )
    let removal = try #require(
      resume.range(of: "removeCredentialForPhysicalProof(")
    )
    #expect(match.lowerBound < removal.lowerBound)

    let gate = String(source[gateStart.lowerBound..<gateEnd.lowerBound])
    for field in [
      "signingHandleID", "signingAlgorithm", "signingKeyIdentifier",
      "signingPublicKey", "agreementHandleID", "agreementAlgorithm",
      "agreementKeyIdentifier", "agreementPublicKey",
    ] {
      #expect(gate.contains("checkpoint." + field))
    }
    // The gate reads and compares; it must never remove a record or clear the
    // checkpoint, so a refusal leaves both the handles and the evidence intact.
    #expect(!gate.contains("removeCredentialForPhysicalProof"))
    #expect(!gate.contains("checkpointStore"))
    #expect(gate.contains("U3SignedHostFailure.checkpointRecordsAbsent"))
    #expect(gate.contains("U3SignedHostFailure.checkpointFieldMismatch"))
  }

  @Test("opt-in hardware proof preserves its checkpoint until strict absence")
  func hardwareProofStrictCleanupContract() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8
    )
    let proofStart = try #require(
      source.range(of: "func supportedHardwareProof()", options: .backwards)
    )
    let fixtureStart = try #require(
      source.range(
        of: "private struct SecretSyncCustodyPersistenceFixture",
        options: .backwards
      )
    )
    let proof = String(source[proofStart.lowerBound..<fixtureStart.lowerBound])

    #expect(!proof.contains("try?"))
    #expect(!proof.contains("defer {"))
    let absence = try #require(
      proof.range(of: "hardwareCredentialIsAbsent")
    )
    let checkpointClear = try #require(
      proof.range(of: "FileManager.default.removeItem")
    )
    #expect(absence.lowerBound < checkpointClear.lowerBound)
  }

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

  #if os(macOS)
  @Test("signed host accepts the macOS development profile shape")
  func signedHostAcceptsMacOSDevelopmentProfileShape() throws {
    let packageRoot =
      URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let script = packageRoot.appendingPathComponent(
      "U3SignedHost/run-physical-proof.sh"
    )
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let profile = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
      "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>TeamIdentifier</key>
        <array><string>TESTTEAM123</string></array>
        <key>Platform</key>
        <array><string>OSX</string></array>
        <key>Entitlements</key>
        <dict>
          <key>com.apple.application-identifier</key>
          <string>TESTTEAM123.com.example.u3-host</string>
          <key>keychain-access-groups</key>
          <array><string>TESTTEAM123.*</string></array>
        </dict>
      </dict>
      </plist>
      """
    let validProfile = temporaryDirectory.appendingPathComponent("valid.plist")
    try profile.write(to: validProfile, atomically: true, encoding: .utf8)

    #expect(
      try signedHostProfileValidationStatus(
        script: script,
        profile: validProfile,
        teamID: "TESTTEAM123"
      ) == 0
    )
    #expect(
      try signedHostProfileValidationStatus(
        script: script,
        profile: validProfile,
        teamID: "WRONGTEAM456"
      ) != 0
    )

    let legacyProfile = temporaryDirectory.appendingPathComponent("legacy.plist")
    try profile.replacingOccurrences(
      of: "com.apple.application-identifier",
      with: "application-identifier"
    ).write(to: legacyProfile, atomically: true, encoding: .utf8)
    #expect(
      try signedHostProfileValidationStatus(
        script: script,
        profile: legacyProfile,
        teamID: "TESTTEAM123"
      ) != 0
    )

    let wrongGroupProfile = temporaryDirectory.appendingPathComponent(
      "wrong-group.plist"
    )
    try profile.replacingOccurrences(
      of: "TESTTEAM123.*",
      with: "WRONGTEAM456.*"
    ).write(to: wrongGroupProfile, atomically: true, encoding: .utf8)
    #expect(
      try signedHostProfileValidationStatus(
        script: script,
        profile: wrongGroupProfile,
        teamID: "TESTTEAM123"
      ) != 0
    )
  }

  @Test("signed host respects managed and manual profile signing modes")
  func signedHostSelectsProfileSigningMode() throws {
    let packageRoot =
      URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let script = packageRoot.appendingPathComponent(
      "U3SignedHost/run-physical-proof.sh"
    )
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let profilePrefix = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
      "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
      """
    let profileSuffix = "</dict></plist>"
    let managedProfile = temporaryDirectory.appendingPathComponent(
      "managed.plist"
    )
    try (profilePrefix + "<key>IsXcodeManaged</key><true/>" + profileSuffix)
      .write(to: managedProfile, atomically: true, encoding: .utf8)
    let manualProfile = temporaryDirectory.appendingPathComponent(
      "manual.plist"
    )
    try (profilePrefix + "<key>IsXcodeManaged</key><false/>" + profileSuffix)
      .write(to: manualProfile, atomically: true, encoding: .utf8)
    let unmarkedProfile = temporaryDirectory.appendingPathComponent(
      "unmarked.plist"
    )
    try (profilePrefix + profileSuffix)
      .write(to: unmarkedProfile, atomically: true, encoding: .utf8)
    let invalidProfile = temporaryDirectory.appendingPathComponent(
      "invalid.plist"
    )
    try (
      profilePrefix
        + "<key>IsXcodeManaged</key><string>unexpected</string>"
        + profileSuffix
    ).write(to: invalidProfile, atomically: true, encoding: .utf8)

    #expect(
      try signedHostProfileSigningMode(
        script: script,
        profile: managedProfile
      ) == (0, "managed")
    )
    #expect(
      try signedHostProfileSigningMode(
        script: script,
        profile: manualProfile
      ) == (0, "manual")
    )
    #expect(
      try signedHostProfileSigningMode(
        script: script,
        profile: unmarkedProfile
      ) == (0, "manual")
    )
    #expect(
      try signedHostProfileSigningMode(
        script: script,
        profile: invalidProfile
      ).status != 0
    )

    let managedArguments = try signedHostBuildArguments(
      script: script,
      signingMode: "managed",
      temporaryDirectory: temporaryDirectory
    )
    #expect(managedArguments.contains("CODE_SIGN_STYLE=Automatic"))
    #expect(managedArguments.contains("CODE_SIGN_IDENTITY=Apple Development"))
    #expect(!managedArguments.contains { argument in
      argument.hasPrefix("PROVISIONING_PROFILE_SPECIFIER=")
    })

    let manualArguments = try signedHostBuildArguments(
      script: script,
      signingMode: "manual",
      temporaryDirectory: temporaryDirectory
    )
    #expect(manualArguments.contains("CODE_SIGN_STYLE=Manual"))
    #expect(
      manualArguments.contains(
        "CODE_SIGN_IDENTITY=Apple Development: Exact Identity"
      )
    )
    #expect(
      manualArguments.contains("PROVISIONING_PROFILE_SPECIFIER=Manual Profile")
    )
  }

  @Test("signed host uses a regular LaunchServices proof contract")
  func signedHostUsesRegularLaunchServicesProofContract() throws {
    let packageRoot =
      URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let hostRoot = packageRoot.appendingPathComponent("U3SignedHost")
    let script = hostRoot.appendingPathComponent("run-physical-proof.sh")
    let infoPlist = hostRoot.appendingPathComponent("App/Info.plist")
    let mainSource = hostRoot.appendingPathComponent("App/main.swift")
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let plistData = try Data(contentsOf: infoPlist)
    let plist = try #require(
      PropertyListSerialization.propertyList(from: plistData, format: nil)
        as? [String: Any]
    )
    #expect(plist["LSUIElement"] == nil)

    let source = try String(contentsOf: mainSource, encoding: .utf8)
    #expect(source.contains("setActivationPolicy(.regular)"))
    #expect(!source.contains("setActivationPolicy(.accessory)"))

    let launchProbe = try signedHostLaunchProbe(
      script: script,
      temporaryDirectory: temporaryDirectory
    )
    #expect(launchProbe.status == 0)
    #expect(
      launchProbe.arguments == [
        "-n",
        "-F",
        "-W",
        "--stdout",
        launchProbe.standardOutput.path,
        "--stderr",
        launchProbe.standardError.path,
        launchProbe.application.path,
      ]
    )
    #expect(
      try signedHostResultValidationStatus(
        script: script,
        output: launchProbe.standardOutput
      ) == 0
    )

    let rejectedOutputs = [
      ("empty", ""),
      ("failure", "U3_SIGNED_HOST_RESULT=proof-failed\n"),
      ("extra", "U3_SIGNED_HOST_RESULT=pass\nunexpected\n"),
      ("unterminated", "U3_SIGNED_HOST_RESULT=pass"),
    ]
    for (name, contents) in rejectedOutputs {
      let output = temporaryDirectory.appendingPathComponent("\(name).txt")
      try contents.write(to: output, atomically: true, encoding: .utf8)
      #expect(
        try signedHostResultValidationStatus(
          script: script,
          output: output
        ) != 0
      )
    }
  }
  #endif

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
    let checkpointDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-custody-checkpoint-\(UUID().uuidString)")
    let generation = try await provider.createCredential(
      for: TrustedDeviceID(UUID()),
      checkpointBeforePersistence: { generation in
        try writeDurableHardwareCheckpoint(
          generation, directory: checkpointDirectory
        )
      }
    )
    var proofError: SecretSyncCustodyError?
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
      let crossRoleProofAccepted: Bool
      do {
        crossRoleProofAccepted = try agreement.verifier.verify(
          signingProof.proofBytes,
          challenge: agreement.challenge,
          candidatePublicKey: generation.agreementPublicKey
        )
      } catch {
        crossRoleProofAccepted = false
      }
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
        !crossRoleProofAccepted
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
    } catch let error as SecretSyncCustodyError {
      proofError = error
    } catch {
      proofError = .cryptographicFailure
    }

    // Cleanup failure takes precedence over a proof failure. The checkpoint is
    // cleared only after both exact Keychain roles are independently absent.
    do {
      try await provider.removeCredentialForPhysicalProof(
        generation.credentialID
      )
      guard try hardwareCredentialIsAbsent(generation) else {
        throw SecretSyncCustodyError.cryptographicFailure
      }
      try FileManager.default.removeItem(at: checkpointDirectory)
    } catch let cleanupError as SecretSyncCustodyError {
      throw cleanupError
    } catch {
      throw SecretSyncCustodyError.cryptographicFailure
    }
    if let proofError {
      throw proofError
    }
  }
}

private struct SecretSyncCustodyPersistenceFixture {
  let generation: SecretSyncCustodyCredentialGeneration
  let signingRecord: SecretSyncStoredKeyRecord
  let agreementRecord: SecretSyncStoredKeyRecord
}

private func custodyPersistenceFixture() throws
  -> SecretSyncCustodyPersistenceFixture
{
  let deviceID = TrustedDeviceID(fixtureUUID(0x81))
  let credentialID = DeviceCredentialID(fixtureUUID(0x82))
  let signingHandle = SigningPrivateKeyHandle(fixtureUUID(0x83))
  let agreementHandle = KeyAgreementPrivateKeyHandle(fixtureUUID(0x84))
  let signing = P256.Signing.PrivateKey()
  let agreement = P256.KeyAgreement.PrivateKey()
  let signingRecord = SecretSyncStoredKeyRecord(
    credentialID: credentialID,
    handleID: signingHandle.rawValue,
    role: .signing,
    opaqueKeyRepresentation: Data([0x01]),
    publicKeyBytes: signing.publicKey.x963Representation
  )
  let agreementRecord = SecretSyncStoredKeyRecord(
    credentialID: credentialID,
    handleID: agreementHandle.rawValue,
    role: .agreement,
    opaqueKeyRepresentation: Data([0x02]),
    publicKeyBytes: agreement.publicKey.x963Representation
  )
  return try SecretSyncCustodyPersistenceFixture(
    generation: SecretSyncCustodyCredentialGeneration(
      deviceID: deviceID,
      credentialID: credentialID,
      signingHandle: signingHandle,
      agreementHandle: agreementHandle,
      signingPublicKey: SigningPublicKeyDescriptor(
        algorithmIdentifier: SecretSyncAlgorithmRegistry.publicKeyEncoding,
        keyIdentifier: Data(signingHandle.rawValue.uuidString.utf8),
        publicKeyBytes: signingRecord.publicKeyBytes
      ),
      agreementPublicKey: KeyAgreementPublicKeyDescriptor(
        algorithmIdentifier: SecretSyncAlgorithmRegistry.publicKeyEncoding,
        keyIdentifier: Data(agreementHandle.rawValue.uuidString.utf8),
        publicKeyBytes: agreementRecord.publicKeyBytes
      )
    ),
    signingRecord: signingRecord,
    agreementRecord: agreementRecord
  )
}

private actor SecretSyncCustodyPersistenceProbe {
  enum Event: Sendable, Equatable {
    case checkpoint
    case insertSigning
    case insertAgreement
    case removeSigning
    case removeAgreement
  }

  private(set) var events: [Event] = []

  func record(_ event: Event) {
    events.append(event)
  }
}

private func custodySource() throws -> String {
  let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  return try String(
    contentsOf: packageRoot.appendingPathComponent(
      "Sources/ConvergenceKitAppleSecurity/SecretSyncSecureEnclaveCustody.swift"
    ),
    encoding: .utf8
  )
}

private func signedHostSource() throws -> String {
  let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  return try String(
    contentsOf: packageRoot.appendingPathComponent("U3SignedHost/App/main.swift"),
    encoding: .utf8
  )
}

#if os(macOS)
private func signedHostProfileValidationStatus(
  script: URL,
  profile: URL,
  teamID: String
) throws -> Int32 {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/bash")
  process.arguments = [
    "-c",
    """
    source "$1"
    team_id="$2"
    application_id="$3"
    profile_is_match "$4"
    """,
    "u3-profile-smoke",
    script.path,
    teamID,
    "com.example.u3-host",
    profile.path,
  ]
  try process.run()
  process.waitUntilExit()
  return process.terminationStatus
}

private func signedHostProfileSigningMode(
  script: URL,
  profile: URL
) throws -> (status: Int32, mode: String) {
  let output = Pipe()
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/bash")
  process.arguments = [
    "-c",
    """
    source "$1"
    profile_signing_mode_for "$2"
    """,
    "u3-signing-mode",
    script.path,
    profile.path,
  ]
  process.standardOutput = output
  try process.run()
  process.waitUntilExit()
  let mode = String(
    decoding: output.fileHandleForReading.readDataToEndOfFile(),
    as: UTF8.self
  ).trimmingCharacters(in: .whitespacesAndNewlines)
  return (process.terminationStatus, mode)
}

private func signedHostBuildArguments(
  script: URL,
  signingMode: String,
  temporaryDirectory: URL
) throws -> [String] {
  let capture = temporaryDirectory.appendingPathComponent(
    "\(signingMode)-arguments.txt"
  )
  let buildLog = temporaryDirectory.appendingPathComponent(
    "\(signingMode)-build.log"
  )
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/bash")
  process.arguments = [
    "-c",
    """
    source "$1"
    capture_path="$3"
    xcodebuild() { printf '%s\\n' "$@" > "$capture_path"; }
    project_path="/tmp/U3SignedHost.xcodeproj"
    scheme="U3SignedHost"
    signing_identity="Apple Development: Exact Identity"
    team_id="TESTTEAM123"
    application_id="com.example.u3-host"
    profile_name="Manual Profile"
    run_signed_build "$2" "/tmp/U3DerivedData" "$4"
    """,
    "u3-build-arguments",
    script.path,
    signingMode,
    capture.path,
    buildLog.path,
  ]
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    return []
  }
  return try String(contentsOf: capture, encoding: .utf8)
    .split(separator: "\n")
    .map(String.init)
}

private struct SignedHostLaunchProbe {
  let status: Int32
  let arguments: [String]
  let application: URL
  let standardOutput: URL
  let standardError: URL
}

private func signedHostLaunchProbe(
  script: URL,
  temporaryDirectory: URL
) throws -> SignedHostLaunchProbe {
  let launcher = temporaryDirectory.appendingPathComponent("open-probe.sh")
  let capturedArguments = temporaryDirectory.appendingPathComponent(
    "open-arguments.txt"
  )
  let application = temporaryDirectory.appendingPathComponent(
    "U3SignedHost.app"
  )
  let standardOutput = temporaryDirectory.appendingPathComponent(
    "signed-host.stdout"
  )
  let standardError = temporaryDirectory.appendingPathComponent(
    "signed-host.stderr"
  )
  let launcherSource = """
    #!/bin/bash
    set -euo pipefail
    printf '%s\\n' "$@" > "$U3_ARGUMENT_CAPTURE"
    while (($#)); do
      case "$1" in
        --stdout)
          printf '%s\\n' 'U3_SIGNED_HOST_RESULT=pass' > "$2"
          shift 2
          ;;
        --stderr)
          : > "$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    """
  try launcherSource.write(to: launcher, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o700],
    ofItemAtPath: launcher.path
  )

  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/bash")
  process.arguments = [
    "-c",
    """
    source "$1"
    export U3_ARGUMENT_CAPTURE="$6"
    run_signed_host "$2" "$3" "$4" "$5"
    """,
    "u3-launch-probe",
    script.path,
    application.path,
    standardOutput.path,
    standardError.path,
    launcher.path,
    capturedArguments.path,
  ]
  try process.run()
  process.waitUntilExit()
  let arguments = try String(contentsOf: capturedArguments, encoding: .utf8)
    .split(separator: "\n")
    .map(String.init)
  return SignedHostLaunchProbe(
    status: process.terminationStatus,
    arguments: arguments,
    application: application,
    standardOutput: standardOutput,
    standardError: standardError
  )
}

private func signedHostResultValidationStatus(
  script: URL,
  output: URL
) throws -> Int32 {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/bash")
  process.arguments = [
    "-c",
    """
    source "$1"
    signed_host_result_is_pass "$2"
    """,
    "u3-result-validation",
    script.path,
    output.path,
  ]
  try process.run()
  process.waitUntilExit()
  return process.terminationStatus
}
#endif

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

private func hardwareCredentialIsAbsent(
  _ generation: SecretSyncCustodyCredentialGeneration
) throws -> Bool {
  for role in [SecretSyncStoredKeyRole.signing, .agreement] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: role.service,
      kSecAttrAccount as String:
        generation.credentialID.rawValue.uuidString.lowercased(),
      kSecAttrSynchronizable as String: kCFBooleanFalse!,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    #if os(macOS)
      query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue
    #endif
    guard SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound
    else { throw SecretSyncCustodyError.cryptographicFailure }
  }
  return true
}

private func hardwareDigest(_ byte: UInt8) throws -> SecretRecordDigest {
  try SecretRecordDigest(bytes: Data(repeating: byte, count: 32))
}

private struct HardwareCheckpoint: Codable {
  let deviceID: UUID
  let credentialID: UUID
  let signingHandleID: UUID
  let agreementHandleID: UUID
}

private func writeDurableHardwareCheckpoint(
  _ generation: SecretSyncCustodyCredentialGeneration,
  directory: URL
) throws {
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: false,
    attributes: [.posixPermissions: NSNumber(value: 0o700)]
  )
  let checkpoint = HardwareCheckpoint(
    deviceID: generation.deviceID.rawValue,
    credentialID: generation.credentialID.rawValue,
    signingHandleID: generation.signingHandle.rawValue,
    agreementHandleID: generation.agreementHandle.rawValue
  )
  let bytes = try JSONEncoder().encode(checkpoint)
  let file = directory.appendingPathComponent("checkpoint.json")
  let descriptor = open(
    file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
    S_IRUSR | S_IWUSR
  )
  guard descriptor >= 0 else { throw SecretSyncCustodyError.cryptographicFailure }
  defer { close(descriptor) }
  try bytes.withUnsafeBytes { rawBuffer in
    guard var pointer = rawBuffer.baseAddress else { return }
    var remaining = rawBuffer.count
    while remaining > 0 {
      let count = write(descriptor, pointer, remaining)
      guard count > 0 else { throw SecretSyncCustodyError.cryptographicFailure }
      remaining -= count
      pointer = pointer.advanced(by: count)
    }
  }
  guard fsync(descriptor) == 0 else {
    throw SecretSyncCustodyError.cryptographicFailure
  }
  let directoryDescriptor = open(
    directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW
  )
  guard directoryDescriptor >= 0 else {
    throw SecretSyncCustodyError.cryptographicFailure
  }
  defer { close(directoryDescriptor) }
  guard fsync(directoryDescriptor) == 0 else {
    throw SecretSyncCustodyError.cryptographicFailure
  }
}

private func fixtureUUID(_ byte: UInt8) -> UUID {
  UUID(
    uuid: (
      byte, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, byte
    ))
}
