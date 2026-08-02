import CryptoKit
import Darwin
import Foundation

private enum HostError: Error {
  case invalidArguments, unsafePath, malformedEvidence, bindingMismatch
  case replay, wrongOrder, expired, deterministicLive
}

private enum Role: String, Codable, CaseIterable {
  case a = "A"
  case b = "B"
  case c = "C"
}
private enum Platform: String, Codable { case mac, iPhone, iPad }
private enum Phase: String, Codable {
  case credential, backgroundDenied, stage, conditionalHead, verify, offline
  case revoke, recovery, rotation, restart, audit, cleanup
}

private struct RecordReference: Codable, Hashable {
  let recordName: String
  let zoneName: String
}

private struct RunManifest: Codable {
  let version: Int
  let runNamespace: String
  let ledgerIdentifier: String
  let artifactRecordNames: [String]
}

private struct SignedRunManifest: Codable {
  let manifest: RunManifest
  let signature: Data
}

private struct GrantManifest: Codable {
  let version: Int
  let runNamespace: String
  let role: Role
  let phase: Phase
  let platform: Platform
  let nonce: UUID
  let issuedAtUnixSeconds: Int64
  let expiresAtUnixSeconds: Int64
  let runManifestDigest: Data
  let destinationBindingDigest: Data
  let expectedLedgerContentDigest: Data
  let prerequisiteArtifactDigests: [Data]
  let trustedCredentialGrantDigestsByRole: [String: Data]
  let credentialBindingDigest: Data?
  let cleanupAuthorizationDigest: Data?
}

private struct SignedGrant: Codable {
  let manifest: GrantManifest
  let signature: Data
}

private struct CleanupManifest: Codable {
  let version: Int
  let namespace: String
  let runManifestDigest: Data
  let records: [RecordReference]
  let allowedZones: [String]
  let inventoryDigest: Data
  let issuedAtUnixSeconds: Int64
  let expiresAtUnixSeconds: Int64
  let nonce: UUID
}

private struct SignedCleanupAuthorization: Codable {
  let manifest: CleanupManifest
  let signature: Data
}

private struct ProbeAttachment: Codable {
  let version: Int
  let namespace: String
  let ledgerIdentifier: String
  let role: Role
  let contentDigest: Data
}

private struct PhaseReceipt: Codable {
  let version: Int
  let namespace: String
  let role: Role
  let phase: Phase
  let runManifestDigest: Data
  let launchGrantDigest: Data
  let destinationBindingDigest: Data
  let artifactDigest: Data
  let inventoryDigest: Data?
  let credentialBindingDigest: Data?

  private enum CodingKeys: String, CodingKey {
    case version, namespace, role, phase, runManifestDigest
    case launchGrantDigest, destinationBindingDigest, artifactDigest
    case inventoryDigest, credentialBindingDigest
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(namespace, forKey: .namespace)
    try container.encode(role, forKey: .role)
    try container.encode(phase, forKey: .phase)
    try container.encode(runManifestDigest, forKey: .runManifestDigest)
    try container.encode(launchGrantDigest, forKey: .launchGrantDigest)
    try container.encode(destinationBindingDigest, forKey: .destinationBindingDigest)
    try container.encode(artifactDigest, forKey: .artifactDigest)
    try container.encode(inventoryDigest, forKey: .inventoryDigest)
    try container.encode(credentialBindingDigest, forKey: .credentialBindingDigest)
  }
}

private struct StageInventory: Codable {
  let version: Int
  let namespace: String
  let role: Role
  let runManifestDigest: Data
  let launchGrantDigest: Data
  let destinationBindingDigest: Data
  let records: [RecordReference]
}

private struct HostState: Codable {
  let version: Int
  let namespace: String
  let ledgerIdentifier: String
  let runManifestDigest: Data
  let authorityPublicKey: Data
  let artifactRecordNames: [String]
  var nextStep: Int
  var ledgerDigestsByRole: [String: Data]
  var credentialGrantDigestsByRole: [String: Data]
  var credentialBindingDigestsByRole: [String: Data]?
  var acceptedArtifactDigests: [Data]
  var issuedNonces: [String]
  var consumedResultIDs: [String]
  var pendingGrantDigest: Data?
  var pendingRole: Role?
  var pendingPhase: Phase?
  var pendingDestinationDigest: Data?
  var pendingGrantName: String?
  var stageInventoryDigest: Data?
  var cleanupAuthorizationDigest: Data?
  var terminal: Bool
}

private struct SignedHostState: Codable {
  let state: HostState
  let signature: Data
}

private struct Step {
  let role: Role
  let phase: Phase
  let platform: Platform
}

private enum Host {
  static let zones = ["moot-secret-control-v1", "moot-secret-payload-v1"]
  static let steps: [Step] = [
    .init(role: .a, phase: .credential, platform: .mac),
    .init(role: .b, phase: .credential, platform: .iPhone),
    .init(role: .c, phase: .credential, platform: .iPad),
    .init(role: .a, phase: .backgroundDenied, platform: .mac),
    .init(role: .a, phase: .stage, platform: .mac),
    .init(role: .a, phase: .conditionalHead, platform: .mac),
    .init(role: .b, phase: .conditionalHead, platform: .iPhone),
    .init(role: .a, phase: .verify, platform: .mac),
    .init(role: .b, phase: .verify, platform: .iPhone),
    .init(role: .c, phase: .verify, platform: .iPad),
    .init(role: .a, phase: .offline, platform: .mac),
    .init(role: .c, phase: .revoke, platform: .iPad),
    .init(role: .a, phase: .recovery, platform: .mac),
    .init(role: .a, phase: .rotation, platform: .mac),
    .init(role: .a, phase: .restart, platform: .mac),
    .init(role: .a, phase: .audit, platform: .mac),
    .init(role: .b, phase: .cleanup, platform: .iPhone),
    .init(role: .c, phase: .cleanup, platform: .iPad),
    .init(role: .a, phase: .cleanup, platform: .mac),
  ]

  static func canonical<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  static func exactDecode<T: Decodable>(
    _ type: T.Type, data: Data, keys: Set<String>
  ) throws -> T {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == keys
    else { throw HostError.malformedEvidence }
    return try JSONDecoder().decode(type, from: data)
  }

  static func digest(domain: String, fields: [Data]) -> Data {
    var framed = Data(domain.utf8)
    for field in fields {
      var length = UInt64(field.count).bigEndian
      withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
      framed.append(field)
    }
    return Data(SHA256.hash(data: framed))
  }

  static func exactArtifacts(namespace: String) -> [String] {
    let pairs: [(String, Role)] = [
      ("agreement-verifier", .a), ("agreement-verifier", .b),
      ("agreement-verifier", .c), ("credential", .a), ("credential", .b),
      ("credential", .c), ("phase-credential", .a), ("phase-credential", .b),
      ("phase-credential", .c), ("phase-backgroundDenied", .a),
      ("candidate", .a), ("candidate", .b), ("manifest", .a),
      ("phase-stage", .a), ("cas", .a), ("cas", .b),
      ("phase-conditionalHead", .a), ("phase-conditionalHead", .b),
      ("phase-verify", .a), ("phase-verify", .b), ("phase-verify", .c),
      ("phase-revoke", .c), ("phase-offline", .a), ("phase-recovery", .a),
      ("phase-rotation", .a), ("phase-restart", .a), ("phase-audit", .a),
      ("phase-cleanup", .b), ("phase-cleanup", .c),
    ]
    return pairs.map { "\(namespace)-\($0.0)-\($0.1.rawValue)" }
  }

  static func ledgerIdentifier(namespace: String) -> String {
    "u7-ledger-"
      + SHA256.hash(data: Data(namespace.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  /// The dependency table mirrors the device's explicit `requirePhase`
  /// calls. In particular terminal cleanup A binds audit A plus both remote
  /// cleanup markers; a generic suffix cannot express that three-way gate.
  static func prerequisiteDigests(
    for step: Int, accepted: [Data]
  ) throws -> [Data] {
    let dependencyIndices: [Int]
    switch step {
    case 3: dependencyIndices = [0]
    case 4: dependencyIndices = [3]
    case 5, 6: dependencyIndices = [4]
    case 12: dependencyIndices = [10]
    case 14: dependencyIndices = [13]
    case 15: dependencyIndices = [14]
    case 18: dependencyIndices = [15, 16, 17]
    default: dependencyIndices = []
    }
    guard dependencyIndices.allSatisfy({ $0 < accepted.count }) else {
      throw HostError.wrongOrder
    }
    return dependencyIndices.map { accepted[$0] }
  }

  static func privateDirectory(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    var value = stat()
    guard lstat(url.path, &value) == 0, (value.st_mode & S_IFMT) == S_IFDIR,
      value.st_uid == geteuid(), (value.st_mode & 0o777) == 0o700
    else { throw HostError.unsafePath }
    return url
  }

  static func withDirectory<T>(_ directory: URL, _ body: (Int32) throws -> T) throws -> T {
    let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard directoryFD >= 0 else { throw HostError.unsafePath }
    defer { close(directoryFD) }
    let lockFD = openat(
      directoryFD, ".host.lock", O_CREAT | O_RDWR | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard lockFD >= 0, privateRegularFile(lockFD), flock(lockFD, LOCK_EX) == 0
    else { throw HostError.unsafePath }
    defer {
      _ = flock(lockFD, LOCK_UN)
      close(lockFD)
    }
    return try body(directoryFD)
  }

  static func privateRegularFile(_ descriptor: Int32) -> Bool {
    var value = stat()
    return fstat(descriptor, &value) == 0 && (value.st_mode & S_IFMT) == S_IFREG
      && value.st_uid == geteuid() && (value.st_mode & 0o777) == 0o600
  }

  static func readPrivate(name: String, directoryFD: Int32) throws -> Data {
    let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0, privateRegularFile(fd) else {
      if fd >= 0 { close(fd) }
      throw HostError.unsafePath
    }
    defer { close(fd) }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = read(fd, &buffer, buffer.count)
      if count == 0 { return result }
      guard count > 0 else { throw HostError.unsafePath }
      result.append(contentsOf: buffer.prefix(Int(count)))
    }
  }

  static func writePrivate(
    _ data: Data, name: String, directoryFD: Int32
  ) throws {
    let temporary = ".\(name).\(UUID().uuidString.lowercased()).tmp"
    let fd = openat(
      directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard fd >= 0 else { throw HostError.unsafePath }
    var complete = false
    defer {
      close(fd)
      if !complete { _ = unlinkat(directoryFD, temporary, 0) }
    }
    try data.withUnsafeBytes { bytes in
      guard var pointer = bytes.baseAddress else { return }
      var remaining = bytes.count
      while remaining > 0 {
        let count = write(fd, pointer, remaining)
        guard count > 0 else { throw HostError.unsafePath }
        pointer = pointer.advanced(by: count)
        remaining -= count
      }
    }
    guard fsync(fd) == 0,
      renameat(directoryFD, temporary, directoryFD, name) == 0,
      fsync(directoryFD) == 0
    else { throw HostError.unsafePath }
    complete = true
  }

  static func argument(_ name: String, in arguments: [String]) throws -> String {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count
    else { throw HostError.invalidArguments }
    return arguments[index + 1]
  }

  static func deterministicMode(_ arguments: inout [String]) -> Bool {
    guard arguments.first == "self-test" else { return false }
    arguments.removeFirst()
    return true
  }

  static func now(arguments: [String], deterministic: Bool) throws -> Int64 {
    if deterministic {
      return Int64(try argument("--now", in: arguments)) ?? 1_100
    }
    guard !arguments.contains("--now"), !arguments.contains("--deterministic-key")
    else { throw HostError.deterministicLive }
    return Int64(Date().timeIntervalSince1970)
  }

  /// Initialization is one lock-held custody transaction so authority resume,
  /// manifest identity, and durable state can never be observed from different runs.
  static func initialize(arguments: [String], deterministic: Bool) throws -> String {
    let directory = try privateDirectory(try argument("--run-dir", in: arguments))
    let namespace = try argument("--namespace", in: arguments)
    guard namespace.hasPrefix("u7-"), UUID(uuidString: String(namespace.dropFirst(3))) != nil
    else { throw HostError.invalidArguments }
    _ = try now(arguments: arguments, deterministic: deterministic)
    return try withDirectory(directory) { directoryFD in
      let stateName = "host-state.json"
      let existingStateFD = openat(directoryFD, stateName, O_RDONLY | O_NOFOLLOW)
      if existingStateFD >= 0 {
        close(existingStateFD)
        let state = try loadState(directoryFD)
        guard state.namespace == namespace else { throw HostError.bindingMismatch }
        return state.terminal ? "U7_HOST_TERMINAL_OK" : "U7_HOST_RESUME_OK"
      }
      guard errno == ENOENT else { throw HostError.unsafePath }
      let key: P256.Signing.PrivateKey
      if deterministic {
        var bytes = Data(repeating: 0, count: 32)
        bytes[31] = 7
        key = try P256.Signing.PrivateKey(rawRepresentation: bytes)
      } else {
        key = P256.Signing.PrivateKey()
      }
      let ledgerIdentifier = ledgerIdentifier(namespace: namespace)
      let manifest = RunManifest(
        version: 2, runNamespace: namespace, ledgerIdentifier: ledgerIdentifier,
        artifactRecordNames: exactArtifacts(namespace: namespace)
      )
      let body = try canonical(manifest)
      let signed = SignedRunManifest(
        manifest: manifest, signature: try key.signature(for: body).derRepresentation
      )
      let manifestDigest = digest(
        domain: "mootx01.u7.signed-run-manifest.v2", fields: [body]
      )
      let state = HostState(
        version: 2, namespace: namespace, ledgerIdentifier: ledgerIdentifier,
        runManifestDigest: manifestDigest,
        authorityPublicKey: key.publicKey.x963Representation,
        artifactRecordNames: manifest.artifactRecordNames, nextStep: 0,
        ledgerDigestsByRole: [:], credentialGrantDigestsByRole: [:],
        credentialBindingDigestsByRole: [:],
        acceptedArtifactDigests: [], issuedNonces: [], consumedResultIDs: [],
        pendingGrantDigest: nil, pendingRole: nil, pendingPhase: nil,
        pendingDestinationDigest: nil, pendingGrantName: nil,
        stageInventoryDigest: nil, cleanupAuthorizationDigest: nil,
        terminal: false
      )
      try writePrivate(
        key.rawRepresentation, name: "authority-private.bin", directoryFD: directoryFD)
      try writePrivate(
        Data(key.publicKey.x963Representation.base64EncodedString().utf8),
        name: "authority-public.b64", directoryFD: directoryFD)
      try writePrivate(try canonical(signed), name: "run-manifest.json", directoryFD: directoryFD)
      try saveState(state, directoryFD)
      return "U7_HOST_INIT_OK"
    }
  }

  static func loadState(_ directoryFD: Int32) throws -> HostState {
    let signed = try exactDecode(
      SignedHostState.self,
      data: readPrivate(name: "host-state.json", directoryFD: directoryFD),
      keys: ["state", "signature"]
    )
    let state = signed.state
    let publicText = String(
      decoding: try readPrivate(name: "authority-public.b64", directoryFD: directoryFD),
      as: UTF8.self
    )
    guard let publicData = Data(base64Encoded: publicText),
      let publicKey = try? P256.Signing.PublicKey(x963Representation: publicData),
      let stateSignature = try? P256.Signing.ECDSASignature(
        derRepresentation: signed.signature
      ),
      publicKey.isValidSignature(stateSignature, for: try canonical(state)),
      state.version == 2, state.authorityPublicKey == publicData,
      state.ledgerIdentifier == ledgerIdentifier(namespace: state.namespace),
      state.artifactRecordNames == exactArtifacts(namespace: state.namespace),
      state.nextStep >= 0, state.nextStep <= steps.count,
      state.acceptedArtifactDigests.count == state.nextStep
    else { throw HostError.bindingMismatch }

    let signedManifest = try exactDecode(
      SignedRunManifest.self,
      data: readPrivate(name: "run-manifest.json", directoryFD: directoryFD),
      keys: ["manifest", "signature"]
    )
    let manifestBody = try canonical(signedManifest.manifest)
    guard
      let manifestSignature = try? P256.Signing.ECDSASignature(
        derRepresentation: signedManifest.signature
      ),
      publicKey.isValidSignature(manifestSignature, for: manifestBody),
      signedManifest.manifest.version == 2,
      signedManifest.manifest.runNamespace == state.namespace,
      signedManifest.manifest.ledgerIdentifier == state.ledgerIdentifier,
      signedManifest.manifest.artifactRecordNames == state.artifactRecordNames,
      digest(domain: "mootx01.u7.signed-run-manifest.v2", fields: [manifestBody])
        == state.runManifestDigest
    else { throw HostError.bindingMismatch }

    let pendingValues: [Any?] = [
      state.pendingGrantDigest, state.pendingRole, state.pendingPhase,
      state.pendingDestinationDigest, state.pendingGrantName,
    ]
    let pendingCount = pendingValues.compactMap { $0 }.count
    guard pendingCount == 0 || pendingCount == pendingValues.count,
      !state.terminal || state.nextStep == steps.count,
      !state.terminal || pendingCount == 0
    else { throw HostError.bindingMismatch }
    if pendingCount == pendingValues.count {
      guard state.nextStep < steps.count,
        state.pendingRole == steps[state.nextStep].role,
        state.pendingPhase == steps[state.nextStep].phase,
        state.pendingGrantDigest?.count == SHA256.byteCount,
        state.pendingDestinationDigest?.count == SHA256.byteCount,
        state.pendingGrantName == "grant-\(String(format: "%02d", state.nextStep)).json"
      else { throw HostError.bindingMismatch }
    }
    if !state.terminal {
      let privateKey = try signingKey(directoryFD)
      guard privateKey.publicKey.x963Representation == publicData else {
        throw HostError.bindingMismatch
      }
    }
    return state
  }

  static func saveState(_ state: HostState, _ directoryFD: Int32) throws {
    let key = try signingKey(directoryFD)
    let body = try canonical(state)
    let signed = SignedHostState(
      state: state, signature: try key.signature(for: body).derRepresentation
    )
    try writePrivate(
      try canonical(signed), name: "host-state.json", directoryFD: directoryFD
    )
  }

  static func signingKey(_ directoryFD: Int32) throws -> P256.Signing.PrivateKey {
    try P256.Signing.PrivateKey(
      rawRepresentation: readPrivate(name: "authority-private.bin", directoryFD: directoryFD)
    )
  }

  static func issueGrant(arguments: [String], deterministic: Bool) throws -> String {
    let directory = try privateDirectory(try argument("--run-dir", in: arguments))
    let role = try Role(rawValue: argument("--role", in: arguments)).unwrapped()
    let phase = try Phase(rawValue: argument("--phase", in: arguments)).unwrapped()
    let platform = try Platform(rawValue: argument("--platform", in: arguments)).unwrapped()
    let destination = try Data(base64Encoded: argument("--destination-digest", in: arguments))
      .unwrapped()
    let probeURL = URL(fileURLWithPath: try argument("--probe", in: arguments))
    let outputArgument = try argument("--output", in: arguments)
    let outputName = URL(fileURLWithPath: outputArgument).lastPathComponent
    guard outputArgument == outputName, outputName.hasPrefix("grant-"),
      outputName.hasSuffix(".json"),
      outputName.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0)
          || (97...122).contains($0) || $0 == 45 || $0 == 46
      })
    else { throw HostError.invalidArguments }
    let issuedAt = try now(arguments: arguments, deterministic: deterministic)
    // Probe validation, nonce issuance, grant signing, and pending-state
    // persistence are deliberately one lock-held transaction. Splitting them
    // would create a replay window between authority decisions.
    return try withDirectory(directory) { directoryFD in
      var state = try loadState(directoryFD)
      guard state.pendingGrantDigest == nil, state.nextStep < steps.count else {
        throw HostError.wrongOrder
      }
      let step = steps[state.nextStep]
      guard step.role == role, step.phase == phase, step.platform == platform,
        destination.count == SHA256.byteCount
      else { throw HostError.wrongOrder }
      let probe = try exactDecode(
        ProbeAttachment.self, data: Data(contentsOf: probeURL),
        keys: ["version", "namespace", "ledgerIdentifier", "role", "contentDigest"]
      )
      guard probe.version == 1, probe.namespace == state.namespace,
        probe.ledgerIdentifier == state.ledgerIdentifier, probe.role == role,
        probe.contentDigest.count == SHA256.byteCount
      else { throw HostError.bindingMismatch }
      state.ledgerDigestsByRole[role.rawValue] = probe.contentDigest
      let nonce = UUID()
      let nonceText = nonce.uuidString.lowercased()
      guard !state.issuedNonces.contains(nonceText) else {
        throw HostError.replay
      }
      state.issuedNonces.append(nonceText)
      state.issuedNonces.sort()
      let manifest = GrantManifest(
        version: 2, runNamespace: state.namespace, role: role, phase: phase,
        platform: platform, nonce: nonce, issuedAtUnixSeconds: issuedAt,
        expiresAtUnixSeconds: issuedAt + 300,
        runManifestDigest: state.runManifestDigest,
        destinationBindingDigest: destination,
        expectedLedgerContentDigest: probe.contentDigest,
        prerequisiteArtifactDigests: try prerequisiteDigests(
          for: state.nextStep, accepted: state.acceptedArtifactDigests
        ),
        trustedCredentialGrantDigestsByRole: state.credentialGrantDigestsByRole,
        credentialBindingDigest: phase == .credential
          ? nil
          : state.credentialBindingDigestsByRole?[role.rawValue],
        cleanupAuthorizationDigest: phase == .cleanup
          ? state.cleanupAuthorizationDigest : nil
      )
      guard phase == .credential || manifest.credentialBindingDigest != nil,
        phase != .cleanup || manifest.cleanupAuthorizationDigest != nil
      else {
        throw HostError.wrongOrder
      }
      let key = try signingKey(directoryFD)
      let body = try canonical(manifest)
      let grant = SignedGrant(
        manifest: manifest, signature: try key.signature(for: body).derRepresentation
      )
      let grantDigest = digest(
        domain: "mootx01.u7.host-launch-grant.v2",
        fields: [state.authorityPublicKey, body, grant.signature]
      )
      state.pendingGrantDigest = grantDigest
      state.pendingRole = role
      state.pendingPhase = phase
      state.pendingDestinationDigest = destination
      state.pendingGrantName = outputName
      try writePrivate(try canonical(grant), name: outputName, directoryFD: directoryFD)
      try saveState(state, directoryFD)
      return "U7_HOST_GRANT_OK"
    }
  }

  static func acceptReceipt(arguments: [String]) throws -> String {
    let directory = try privateDirectory(try argument("--run-dir", in: arguments))
    let receiptURL = URL(fileURLWithPath: try argument("--receipt", in: arguments))
    let resultID = try argument("--result-id", in: arguments)
    // Result replay consumption and protocol advancement stay atomic with the
    // exact receipt check; there is no accepted-but-not-advanced state.
    return try withDirectory(directory) { directoryFD in
      var state = try loadState(directoryFD)
      guard !state.consumedResultIDs.contains(resultID),
        let grantDigest = state.pendingGrantDigest,
        let role = state.pendingRole, let phase = state.pendingPhase,
        let destination = state.pendingDestinationDigest
      else { throw HostError.replay }
      state.consumedResultIDs.append(resultID)
      state.consumedResultIDs.sort()
      let receipt = try exactDecode(
        PhaseReceipt.self, data: Data(contentsOf: receiptURL),
        keys: [
          "version", "namespace", "role", "phase", "runManifestDigest", "launchGrantDigest",
          "destinationBindingDigest", "artifactDigest", "inventoryDigest",
          "credentialBindingDigest",
        ]
      )
      guard receipt.version == 1, receipt.namespace == state.namespace,
        receipt.role == role, receipt.phase == phase,
        receipt.runManifestDigest == state.runManifestDigest,
        receipt.launchGrantDigest == grantDigest,
        receipt.destinationBindingDigest == destination,
        receipt.artifactDigest.count == SHA256.byteCount,
        (phase == .stage) == (receipt.inventoryDigest != nil),
        (phase == .credential) == (receipt.credentialBindingDigest != nil),
        receipt.credentialBindingDigest?.count == nil
          || receipt.credentialBindingDigest?.count == SHA256.byteCount,
        receipt.inventoryDigest?.count == nil || receipt.inventoryDigest?.count == SHA256.byteCount
      else { throw HostError.bindingMismatch }
      state.acceptedArtifactDigests.append(receipt.artifactDigest)
      if phase == .credential {
        state.credentialGrantDigestsByRole[role.rawValue] = grantDigest
        var bindings = state.credentialBindingDigestsByRole ?? [:]
        bindings[role.rawValue] = receipt.credentialBindingDigest
        state.credentialBindingDigestsByRole = bindings
      }
      if phase == .stage { state.stageInventoryDigest = receipt.inventoryDigest }
      state.pendingGrantDigest = nil
      state.pendingRole = nil
      state.pendingPhase = nil
      state.pendingDestinationDigest = nil
      state.pendingGrantName = nil
      state.nextStep += 1
      try saveState(state, directoryFD)
      return "U7_HOST_RECEIPT_OK"
    }
  }

  /// Cleanup authorization remains a single cohesive transaction because the
  /// successful stage receipt, private inventory, exact capability set, nonce,
  /// and signed durable state must advance together or not at all.
  static func authorizeCleanup(arguments: [String], deterministic: Bool) throws -> String {
    let directory = try privateDirectory(try argument("--run-dir", in: arguments))
    let inventoryURL = URL(fileURLWithPath: try argument("--inventory", in: arguments))
    let outputArgument = try argument("--output", in: arguments)
    let outputName = URL(fileURLWithPath: outputArgument).lastPathComponent
    guard outputArgument == outputName, outputName == "cleanup-authorization.json"
    else { throw HostError.invalidArguments }
    let issuedAt = try now(arguments: arguments, deterministic: deterministic)
    return try withDirectory(directory) { directoryFD in
      var state = try loadState(directoryFD)
      guard state.nextStep == 5, state.pendingGrantDigest == nil,
        let expectedInventoryDigest = state.stageInventoryDigest,
        state.cleanupAuthorizationDigest == nil
      else { throw HostError.wrongOrder }
      let inventory = try exactDecode(
        StageInventory.self, data: Data(contentsOf: inventoryURL),
        keys: [
          "version", "namespace", "role", "runManifestDigest", "launchGrantDigest",
          "destinationBindingDigest", "records",
        ]
      )
      let inventoryDigest = digest(
        domain: "mootx01.u7.stage-inventory.v1",
        fields: [try canonical(inventory)]
      )
      guard inventory.version == 1, inventory.namespace == state.namespace,
        inventory.role == .a, inventory.runManifestDigest == state.runManifestDigest,
        inventoryDigest == expectedInventoryDigest,
        !inventory.records.isEmpty, Set(inventory.records).count == inventory.records.count,
        inventory.records.allSatisfy({ validRecord($0, namespace: state.namespace) })
      else { throw HostError.bindingMismatch }
      // SecretSyncHeadCAS uses the UUID's 16 raw bytes as lowercase hex. The
      // namespace is exactly `u7-<UUID>`, so the host derives the record name
      // without receiving or retaining a separate private selector.
      let head = String(state.namespace.dropFirst(3))
        .replacingOccurrences(of: "-", with: "").lowercased()
      guard validHex(head) else { throw HostError.bindingMismatch }
      let deterministic =
        state.artifactRecordNames.map {
          RecordReference(recordName: $0, zoneName: zones[0])
        } + [RecordReference(recordName: head, zoneName: zones[0])]
      guard Set(inventory.records).isDisjoint(with: deterministic) else {
        throw HostError.bindingMismatch
      }
      let records = (inventory.records + deterministic).sorted(by: recordOrder)
      let manifest = CleanupManifest(
        version: 1, namespace: state.namespace,
        runManifestDigest: state.runManifestDigest, records: records,
        allowedZones: zones, inventoryDigest: inventoryDigest,
        issuedAtUnixSeconds: issuedAt, expiresAtUnixSeconds: issuedAt + 300,
        nonce: UUID()
      )
      let key = try signingKey(directoryFD)
      let body = try canonical(manifest)
      let signed = SignedCleanupAuthorization(
        manifest: manifest, signature: try key.signature(for: body).derRepresentation
      )
      state.cleanupAuthorizationDigest = digest(
        domain: "mootx01.u7.cleanup-authorization.v1",
        fields: [body, signed.signature]
      )
      try writePrivate(try canonical(signed), name: outputName, directoryFD: directoryFD)
      try saveState(state, directoryFD)
      return "U7_HOST_CLEANUP_AUTH_OK"
    }
  }

  static func validHex(_ value: String) -> Bool {
    (value.count == 32 || value.count == 64)
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  static func validRecord(_ value: RecordReference, namespace: String) -> Bool {
    // The stage inventory contains only runtime graph records. Every
    // namespace-prefixed artifact is supplied separately by the signed run
    // manifest, so accepting one here would broaden the cleanup capability.
    zones.contains(value.zoneName) && !value.recordName.hasPrefix("\(namespace)-")
      && validHex(value.recordName)
  }

  static func recordOrder(_ lhs: RecordReference, _ rhs: RecordReference) -> Bool {
    lhs.zoneName == rhs.zoneName
      ? lhs.recordName < rhs.recordName : lhs.zoneName < rhs.zoneName
  }

  static func inspect(arguments: [String]) throws -> String {
    let directory = try privateDirectory(try argument("--run-dir", in: arguments))
    return try withDirectory(directory) { directoryFD in
      let state = try loadState(directoryFD)
      return [
        "U7_HOST_INSPECT", String(state.nextStep),
        state.pendingGrantDigest == nil ? "none" : "pending",
        state.pendingRole?.rawValue ?? "-", state.pendingPhase?.rawValue ?? "-",
        state.pendingGrantName ?? "-", state.terminal ? "terminal" : "active",
      ].joined(separator: ":")
    }
  }

  /// Terminal finalization signs one sanitized digest-only state before the
  /// authority secret is erased. The retained public key, manifest, and signed
  /// state remain independently verifiable; grants and cleanup capabilities do
  /// not survive successful completion.
  static func finalize(arguments: [String]) throws -> String {
    let directory = try privateDirectory(try argument("--run-dir", in: arguments))
    return try withDirectory(directory) { directoryFD in
      var state = try loadState(directoryFD)
      guard state.nextStep == steps.count, state.pendingGrantDigest == nil
      else { throw HostError.wrongOrder }
      if !state.terminal {
        state.ledgerDigestsByRole.removeAll()
        state.issuedNonces.removeAll()
        state.consumedResultIDs.removeAll()
        state.terminal = true
        try saveState(state, directoryFD)
      }
      let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      for name in names
      where
        name == "authority-private.bin"
        || name == "stage-inventory.json"
        || name == "stage-receipt.json"
        || name == "cleanup-authorization.json"
        || (name.hasPrefix("grant-") && name.hasSuffix(".json"))
        || (name.hasPrefix("pending-receipt-") && name.hasSuffix(".json"))
      {
        guard unlinkat(directoryFD, name, 0) == 0 || errno == ENOENT else {
          throw HostError.unsafePath
        }
      }
      guard fsync(directoryFD) == 0 else { throw HostError.unsafePath }
      return "U7_HOST_FINALIZED_OK"
    }
  }

  static func publicKey(arguments: [String]) throws -> String {
    let directory = try privateDirectory(try argument("--run-dir", in: arguments))
    return try withDirectory(directory) { directoryFD in
      _ = try loadState(directoryFD)
      return String(
        decoding: try readPrivate(name: "authority-public.b64", directoryFD: directoryFD),
        as: UTF8.self)
    }
  }

  static func run() throws -> String {
    var arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["self-test"] { return "U7_HOST_SELF_TEST_OK" }
    let deterministic = deterministicMode(&arguments)
    guard let command = arguments.first else { throw HostError.invalidArguments }
    switch command {
    case "init": return try initialize(arguments: arguments, deterministic: deterministic)
    case "public-key":
      guard !deterministic else { throw HostError.invalidArguments }
      return try publicKey(arguments: arguments)
    case "inspect":
      guard !deterministic else { throw HostError.invalidArguments }
      return try inspect(arguments: arguments)
    case "issue-grant": return try issueGrant(arguments: arguments, deterministic: deterministic)
    case "accept-receipt":
      guard !deterministic else { throw HostError.invalidArguments }
      return try acceptReceipt(arguments: arguments)
    case "authorize-cleanup":
      return try authorizeCleanup(arguments: arguments, deterministic: deterministic)
    case "finalize":
      guard !deterministic else { throw HostError.invalidArguments }
      return try finalize(arguments: arguments)
    default: throw HostError.invalidArguments
    }
  }
}

extension Optional {
  fileprivate func unwrapped() throws -> Wrapped {
    guard let self else { throw HostError.invalidArguments }
    return self
  }
}

do {
  print(try Host.run())
} catch {
  fputs("U7_HOST_ERROR\n", stderr)
  exit(64)
}
