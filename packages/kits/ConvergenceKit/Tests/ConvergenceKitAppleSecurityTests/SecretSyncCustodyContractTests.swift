import ConvergenceKit
import Foundation
import Security
import Testing

@_spi(SecretSyncPhysicalProof) @testable import ConvergenceKitAppleSecurity

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
      try await reloaded.removeCredentialForPhysicalProof(
        generation.credentialID
      )
    } catch let error as SecretSyncCustodyError {
      try? await provider.removeCredentialForPhysicalProof(generation.credentialID)
      throw error
    } catch {
      try? await provider.removeCredentialForPhysicalProof(generation.credentialID)
      throw SecretSyncCustodyError.cryptographicFailure
    }
  }
}

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
