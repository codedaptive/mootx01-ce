import ConvergenceKit
import Foundation
import Testing

@testable import ConvergenceKitAppleSecurity

@Suite("SecretSync Keychain and authorization")
struct SecretSyncKeychainAndAuthorizationTests {
  @Test("handle writes are ThisDeviceOnly, local, and default-group scoped")
  func handleAttributesAreFailClosed() async throws {
    let keychain = RecordingKeychain()
    let store = SecretSyncKeychainHandleStore(keychain: keychain)
    let record = fixtureStoredHandle(role: .signing)

    try await store.insert(record)
    let requests = await keychain.requests
    let request = try #require(requests.first)
    #expect(request.accessibility == .whenUnlockedThisDeviceOnly)
    #expect(request.synchronizable == false)
    #expect(request.usesDataProtectionKeychain)
    #expect(request.accessGroup == nil)
  }

  @Test("missing and corrupt reads never write or create")
  func readsNeverCreate() async throws {
    let keychain = RecordingKeychain(readResults: [
      .notFound,
      .success(Data([0x00])),
    ])
    let store = SecretSyncKeychainHandleStore(keychain: keychain)
    let credentialID = DeviceCredentialID(fixtureUUID(3))

    await #expect(throws: SecretSyncCustodyError.missingHandle) {
      try await store.record(for: credentialID, role: .signing)
    }
    await #expect(throws: SecretSyncCustodyError.corruptHandle) {
      try await store.record(for: credentialID, role: .signing)
    }
    #expect(await keychain.writeCount == 0)
  }

  @Test("authority contexts are fresh while one foreground session is reusable")
  func authorizationScopesStaySeparate() async throws {
    let operations = RecordingAuthorizationOperations()
    let authorization = SecretSyncLocalAuthorization(operations: operations)

    let first = try await authorization.authorityContext()
    await authorization.invalidate(first)
    let second = try await authorization.authorityContext()
    await authorization.invalidate(second)
    let session = try await authorization.beginForegroundSession()
    let reusedOne = try await session.authorizedContext()
    let reusedTwo = try await session.authorizedContext()
    await session.invalidate()

    #expect(first.identifier != second.identifier)
    #expect(reusedOne.identifier == reusedTwo.identifier)
    #expect(await operations.authorityRequestCount == 2)
    #expect(await operations.foregroundRequestCount == 1)
  }

  @Test("background scope denies before authorization or Keychain access")
  func backgroundDeniesPrivateOperations() async throws {
    let operations = RecordingAuthorizationOperations()
    let authorization = SecretSyncLocalAuthorization(operations: operations)

    await #expect(throws: SecretSyncCustodyError.backgroundOperationDenied) {
      try await authorization.context(for: .background)
    }
    #expect(await operations.requestCount == 0)
  }

  @Test("protected heads reject rollback, same-epoch forks, and wrong predecessor")
  func protectedHeadIsMonotonic() async throws {
    let keychain = RecordingKeychain()
    let store = SecretSyncProtectedHeadStore(keychain: keychain)
    let first = try fixtureHead(epoch: 4, byte: 0x14)
    let next = try fixtureHead(epoch: 5, byte: 0x15)

    try await store.initialize(first)
    #expect(try await store.protectedHead(for: first.scopeID) == first)
    await #expect(throws: SecretSyncCustodyError.rollbackDetected) {
      try await store.advance(
        SecretSyncProtectedHeadAdvance(
          expectedHead: first,
          predecessorHeadDigest: try fixtureDigest(0xFF),
          candidate: next
        )
      )
    }
    try await store.advance(
      SecretSyncProtectedHeadAdvance(
        expectedHead: first,
        predecessorHeadDigest: first.headCommitDigest,
        candidate: next
      )
    )
    let fork = try fixtureHead(epoch: 5, byte: 0x25)
    await #expect(throws: SecretSyncCustodyError.rollbackDetected) {
      try await store.advance(
        SecretSyncProtectedHeadAdvance(
          expectedHead: next,
          predecessorHeadDigest: next.headCommitDigest,
          candidate: fork
        )
      )
    }
  }
}

private actor RecordingKeychain: SecretSyncKeychainOperating {
  private(set) var requests: [SecretSyncKeychainRequest] = []
  private(set) var writeCount = 0
  private var storage: [String: Data] = [:]
  private var readResults: [SecretSyncKeychainResult]

  init(readResults: [SecretSyncKeychainResult] = []) {
    self.readResults = readResults
  }

  func add(_ request: SecretSyncKeychainRequest) -> SecretSyncKeychainResult {
    requests.append(request)
    writeCount += 1
    guard storage[request.storageKey] == nil, let data = request.data else {
      return .duplicate
    }
    storage[request.storageKey] = data
    return .success(nil)
  }

  func read(_ request: SecretSyncKeychainRequest) -> SecretSyncKeychainResult {
    requests.append(request)
    if !readResults.isEmpty {
      return readResults.removeFirst()
    }
    guard let data = storage[request.storageKey] else { return .notFound }
    return .success(data)
  }

  func update(_ request: SecretSyncKeychainRequest) -> SecretSyncKeychainResult {
    requests.append(request)
    writeCount += 1
    guard storage[request.storageKey] != nil, let data = request.data else {
      return .notFound
    }
    storage[request.storageKey] = data
    return .success(nil)
  }

  func delete(_ request: SecretSyncKeychainRequest) -> SecretSyncKeychainResult {
    requests.append(request)
    writeCount += 1
    guard storage.removeValue(forKey: request.storageKey) != nil else {
      return .notFound
    }
    return .success(nil)
  }
}

private actor RecordingAuthorizationOperations:
  SecretSyncAuthorizationOperating
{
  private(set) var authorityRequestCount = 0
  private(set) var foregroundRequestCount = 0
  var requestCount: Int { authorityRequestCount + foregroundRequestCount }

  func authorize(
    scope: SecretSyncAuthorizationScope
  ) throws -> SecretSyncAuthorizedContext {
    switch scope {
    case .authority:
      authorityRequestCount += 1
    case .foregroundHydration:
      foregroundRequestCount += 1
    case .background:
      throw SecretSyncCustodyError.backgroundOperationDenied
    }
    return SecretSyncAuthorizedContext.fixture(
      scope: scope,
      identifier: UUID()
    )
  }

  func invalidate(_ context: SecretSyncAuthorizedContext) {}
}

private func fixtureStoredHandle(
  role: SecretSyncStoredKeyRole
) -> SecretSyncStoredKeyRecord {
  SecretSyncStoredKeyRecord(
    credentialID: DeviceCredentialID(fixtureUUID(4)),
    handleID: fixtureUUID(role == .signing ? 5 : 6),
    role: role,
    opaqueKeyRepresentation: Data(repeating: 0xA5, count: 48),
    publicKeyBytes: Data([0x04]) + Data(repeating: 0x11, count: 64)
  )
}

private func fixtureHead(
  epoch: UInt64,
  byte: UInt8
) throws -> SecretBootstrapFreshnessCommitment {
  try SecretBootstrapFreshnessCommitment(
    scopeID: SecretScopeID(fixtureUUID(7)),
    latestPolicyEpoch: epoch,
    headCommitDigest: fixtureDigest(byte),
    policyDigest: fixtureDigest(byte &+ 1)
  )
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
