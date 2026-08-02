import CryptoKit
import Darwin
import Foundation

private enum HostError: Error { case invalid, unsafePath, deterministicLive }

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

private enum Host {
  static let zones = ["moot-secret-control-v1", "moot-secret-payload-v1"]

  static func canonical<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
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

  static func privateDirectory(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    var value = stat()
    guard lstat(url.path, &value) == 0,
      (value.st_mode & S_IFMT) == S_IFDIR,
      value.st_uid == geteuid(), (value.st_mode & 0o777) == 0o700
    else { throw HostError.unsafePath }
    return url
  }

  static func writePrivate(_ data: Data, name: String, directory: URL) throws {
    let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard directoryFD >= 0 else { throw HostError.unsafePath }
    defer { close(directoryFD) }
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

  static func authority(directory: URL, deterministic: Bool) throws -> P256.Signing.PrivateKey {
    let keyURL = directory.appendingPathComponent("authority-private.bin")
    if let bytes = try? Data(contentsOf: keyURL, options: .mappedIfSafe) {
      return try P256.Signing.PrivateKey(rawRepresentation: bytes)
    }
    let key: P256.Signing.PrivateKey
    if deterministic {
      var bytes = Data(repeating: 0, count: 32); bytes[31] = 7
      key = try P256.Signing.PrivateKey(rawRepresentation: bytes)
    } else {
      key = P256.Signing.PrivateKey()
    }
    try writePrivate(key.rawRepresentation, name: keyURL.lastPathComponent, directory: directory)
    return key
  }

  static func validRecord(_ value: RecordReference, namespace: String) -> Bool {
    guard zones.contains(value.zoneName) else { return false }
    if value.recordName.hasPrefix("\(namespace)-") {
      return ["-A", "-B", "-C"].contains { value.recordName.hasSuffix($0) }
    }
    return (value.recordName.count == 32 || value.recordName.count == 64)
      && value.recordName.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  static func selfTest() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-host-self-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try privateDirectory(root.path)
    let key = try authority(directory: directory, deterministic: true)
    let namespace = "u7-00112233-4455-6677-8899-aabbccddeeff"
    let manifest = RunManifest(
      version: 2, runNamespace: namespace,
      ledgerIdentifier: "u7-ledger-" + SHA256.hash(data: Data(namespace.utf8))
        .map { String(format: "%02x", $0) }.joined(),
      artifactRecordNames: ["\(namespace)-credential-A"]
    )
    let body = try canonical(manifest)
    let signed = SignedRunManifest(
      manifest: manifest,
      signature: try key.signature(for: body).derRepresentation
    )
    try writePrivate(try canonical(signed), name: "run-manifest.json", directory: directory)
    guard key.publicKey.isValidSignature(
      try P256.Signing.ECDSASignature(derRepresentation: signed.signature), for: body
    ) else { throw HostError.invalid }
    print("U7_HOST_SELF_TEST_OK")
  }
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard arguments == ["self-test"] else {
    if arguments.contains("--deterministic-key") || arguments.contains("--deterministic-time") {
      throw HostError.deterministicLive
    }
    throw HostError.invalid
  }
  try Host.selfTest()
} catch {
  fputs("U7_HOST_ERROR\n", stderr)
  exit(64)
}
