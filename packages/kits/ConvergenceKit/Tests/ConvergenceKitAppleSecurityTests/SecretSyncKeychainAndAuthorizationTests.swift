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
    let foregroundState = MutableForegroundState(isActive: true)
    let authorization = SecretSyncLocalAuthorization(
      operations: operations,
      foregroundState: foregroundState
    )

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
    let foregroundState = MutableForegroundState(isActive: true)
    let authorization = SecretSyncLocalAuthorization(
      operations: operations,
      foregroundState: foregroundState
    )

    await #expect(throws: SecretSyncCustodyError.backgroundOperationDenied) {
      try await authorization.context(for: .background)
    }
    #expect(await operations.requestCount == 0)
  }

  @Test("foreground session creation denies before authorization when inactive")
  func inactiveSessionCreationDeniesBeforeAuthorization() async throws {
    let operations = RecordingAuthorizationOperations()
    let foregroundState = MutableForegroundState(isActive: false)
    let authorization = SecretSyncLocalAuthorization(
      operations: operations,
      foregroundState: foregroundState
    )

    await #expect(throws: SecretSyncCustodyError.backgroundOperationDenied) {
      try await authorization.beginForegroundSession()
    }
    #expect(await operations.requestCount == 0)
  }

  @Test("foreground transition revokes the session before Keychain access")
  func foregroundTransitionRevokesBeforeKeychain() async throws {
    let keychain = RecordingKeychain()
    let operations = RecordingAuthorizationOperations()
    let foregroundState = MutableForegroundState(isActive: true)
    let authorization = SecretSyncLocalAuthorization(
      operations: operations,
      foregroundState: foregroundState
    )
    let custody = SecretSyncSecureEnclaveCustody(
      handleStore: SecretSyncKeychainHandleStore(keychain: keychain),
      authorization: authorization
    )
    let credentialID = DeviceCredentialID(fixtureUUID(31))
    let session = try await authorization.beginForegroundSession()

    await foregroundState.setActive(false)
    await #expect(throws: SecretSyncCustodyError.backgroundOperationDenied) {
      try await custody.openRecipientGenerationKey(
        Data(repeating: 0, count: 113),
        privateKeyHandle: KeyAgreementPrivateKeyHandle(fixtureUUID(32)),
        credentialID: credentialID,
        context: try fixtureEnvelopeContext(
          recipientCredentialID: credentialID
        ),
        session: session
      )
    }

    #expect(await keychain.requests.isEmpty)
    #expect(await operations.invalidationCount == 1)
  }

  @Test("mislabeled recipient context is rejected before Keychain access")
  func mismatchedRecipientIsRejectedBeforeKeychain() async throws {
    let keychain = RecordingKeychain()
    let handleStore = SecretSyncKeychainHandleStore(keychain: keychain)
    let operations = RecordingAuthorizationOperations()
    let foregroundState = MutableForegroundState(isActive: true)
    let authorization = SecretSyncLocalAuthorization(
      operations: operations,
      foregroundState: foregroundState
    )
    let custody = SecretSyncSecureEnclaveCustody(
      handleStore: handleStore,
      authorization: authorization
    )
    let credentialID = DeviceCredentialID(fixtureUUID(33))
    let handleID = fixtureUUID(34)
    try await handleStore.insert(
      fixtureStoredHandle(
        role: .agreement,
        credentialID: credentialID,
        handleID: handleID
      )
    )
    await keychain.resetRequests()
    let session = try await authorization.beginForegroundSession()

    await #expect(throws: SecretSyncCustodyError.invalidProof) {
      try await custody.openRecipientGenerationKey(
        Data(repeating: 0, count: 113),
        privateKeyHandle: KeyAgreementPrivateKeyHandle(handleID),
        credentialID: credentialID,
        context: try fixtureEnvelopeContext(
          recipientCredentialID: DeviceCredentialID(fixtureUUID(35))
        ),
        session: session
      )
    }

    #expect(await keychain.requests.isEmpty)
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

  @Test("append-only floor survives an interleaved stale writer")
  func protectedHeadSurvivesStaleConcurrentWriter() async throws {
    let keychain = StaleWriteCoordinatingKeychain(lowerEpoch: 11)
    let firstStore = SecretSyncProtectedHeadStore(keychain: keychain)
    let secondStore = SecretSyncProtectedHeadStore(keychain: keychain)
    let epochTen = try fixtureHead(epoch: 10, byte: 0x40)
    let epochEleven = try fixtureHead(epoch: 11, byte: 0x41)
    let epochTwelve = try fixtureHead(epoch: 12, byte: 0x42)
    try await firstStore.initialize(epochTen)

    async let staleAdvance: Void = firstStore.advance(
      SecretSyncProtectedHeadAdvance(
        expectedHead: epochTen,
        predecessorHeadDigest: epochTen.headCommitDigest,
        candidate: epochEleven
      )
    )
    await keychain.waitUntilLowerAddIsHeld()
    try await secondStore.advance(
      SecretSyncProtectedHeadAdvance(
        expectedHead: epochTen,
        predecessorHeadDigest: epochTen.headCommitDigest,
        candidate: epochTwelve
      )
    )
    _ = try? await staleAdvance

    #expect(try await firstStore.protectedHead(for: epochTen.scopeID) == epochTwelve)
  }

  @Test("protected-head history fails closed on corrupt and duplicate entries")
  func protectedHeadRejectsCorruptAndDuplicateHistory() async throws {
    let corruptKeychain = RecordingKeychain()
    let corruptStore = SecretSyncProtectedHeadStore(keychain: corruptKeychain)
    let head = try fixtureHead(epoch: 20, byte: 0x50)
    try await corruptStore.initialize(head)
    let initialRequest = try #require(await corruptKeychain.requests.first)
    await corruptKeychain.seed(
      service: initialRequest.service,
      account: "corrupt",
      data: Data([0x00])
    )
    await #expect(throws: SecretSyncCustodyError.corruptProtectedHead) {
      try await corruptStore.protectedHead(for: head.scopeID)
    }

    let duplicateKeychain = RecordingKeychain()
    let duplicateStore = SecretSyncProtectedHeadStore(keychain: duplicateKeychain)
    try await duplicateStore.initialize(head)
    let duplicateRequest = try #require(await duplicateKeychain.requests.first)
    await duplicateKeychain.seed(
      service: duplicateRequest.service,
      account: "duplicate",
      data: try encodeHead(head)
    )
    await #expect(throws: SecretSyncCustodyError.corruptProtectedHead) {
      try await duplicateStore.protectedHead(for: head.scopeID)
    }
  }

  @Test("protected-head history rejects conflicting highest-epoch ties")
  func protectedHeadRejectsHighestEpochTie() async throws {
    let keychain = RecordingKeychain()
    let store = SecretSyncProtectedHeadStore(keychain: keychain)
    let head = try fixtureHead(epoch: 30, byte: 0x60)
    let fork = try fixtureHead(epoch: 30, byte: 0x70)
    try await store.initialize(head)
    let initialRequest = try #require(await keychain.requests.first)
    await keychain.seed(
      service: initialRequest.service,
      account: "same-epoch-fork",
      data: try encodeHead(fork)
    )

    await #expect(throws: SecretSyncCustodyError.rollbackDetected) {
      try await store.protectedHead(for: head.scopeID)
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

  func readAll(
    _ request: SecretSyncKeychainRequest
  ) -> SecretSyncKeychainItemsResult {
    requests.append(request)
    let prefix = request.service + "\u{0}"
    let matches =
      storage
      .filter { $0.key.hasPrefix(prefix) }
      .map(\.value)
    return matches.isEmpty ? .notFound : .success(matches)
  }

  func delete(_ request: SecretSyncKeychainRequest) -> SecretSyncKeychainResult {
    requests.append(request)
    writeCount += 1
    guard storage.removeValue(forKey: request.storageKey) != nil else {
      return .notFound
    }
    return .success(nil)
  }

  func seed(service: String, account: String, data: Data) {
    storage[service + "\u{0}" + account] = data
  }

  func resetRequests() {
    requests.removeAll()
  }
}

private actor StaleWriteCoordinatingKeychain: SecretSyncKeychainOperating {
  private let lowerEpoch: UInt64
  private var storage: [String: Data] = [:]
  private var lowerAddIsHeld = false
  private var heldLowerAdd: CheckedContinuation<Void, Never>?
  private var lowerHeldWaiters: [CheckedContinuation<Void, Never>] = []

  init(lowerEpoch: UInt64) {
    self.lowerEpoch = lowerEpoch
  }

  func add(_ request: SecretSyncKeychainRequest) async -> SecretSyncKeychainResult {
    guard request.account != nil, let data = request.data else {
      return .failure
    }
    let commitment = try? PropertyListDecoder().decode(
      SecretBootstrapFreshnessCommitment.self,
      from: data
    )
    if commitment?.latestPolicyEpoch == lowerEpoch {
      lowerAddIsHeld = true
      let waiters = lowerHeldWaiters
      lowerHeldWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      await withCheckedContinuation { continuation in
        heldLowerAdd = continuation
      }
    }
    guard storage[request.storageKey] == nil else { return .duplicate }
    storage[request.storageKey] = data
    if commitment?.latestPolicyEpoch != lowerEpoch {
      heldLowerAdd?.resume()
      heldLowerAdd = nil
    }
    return .success(nil)
  }

  func read(_ request: SecretSyncKeychainRequest) -> SecretSyncKeychainResult {
    guard let data = storage[request.storageKey] else { return .notFound }
    return .success(data)
  }

  func readAll(
    _ request: SecretSyncKeychainRequest
  ) -> SecretSyncKeychainItemsResult {
    let prefix = request.service + "\u{0}"
    let matches =
      storage
      .filter { $0.key.hasPrefix(prefix) }
      .map(\.value)
    return matches.isEmpty ? .notFound : .success(matches)
  }

  func delete(_ request: SecretSyncKeychainRequest) -> SecretSyncKeychainResult {
    guard storage.removeValue(forKey: request.storageKey) != nil else {
      return .notFound
    }
    return .success(nil)
  }

  func waitUntilLowerAddIsHeld() async {
    guard !lowerAddIsHeld else { return }
    await withCheckedContinuation { continuation in
      lowerHeldWaiters.append(continuation)
    }
  }
}

private actor RecordingAuthorizationOperations:
  SecretSyncAuthorizationOperating
{
  private(set) var authorityRequestCount = 0
  private(set) var foregroundRequestCount = 0
  private(set) var invalidationCount = 0
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

  func invalidate(_ context: SecretSyncAuthorizedContext) {
    invalidationCount += 1
  }
}

private actor MutableForegroundState: SecretSyncForegroundStateProviding {
  private var isActive: Bool

  init(isActive: Bool) {
    self.isActive = isActive
  }

  func isForegroundActive() -> Bool { isActive }

  func setActive(_ isActive: Bool) {
    self.isActive = isActive
  }
}

private func fixtureStoredHandle(
  role: SecretSyncStoredKeyRole,
  credentialID: DeviceCredentialID = DeviceCredentialID(fixtureUUID(4)),
  handleID: UUID? = nil
) -> SecretSyncStoredKeyRecord {
  SecretSyncStoredKeyRecord(
    credentialID: credentialID,
    handleID: handleID ?? fixtureUUID(role == .signing ? 5 : 6),
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

private func encodeHead(
  _ head: SecretBootstrapFreshnessCommitment
) throws -> Data {
  let encoder = PropertyListEncoder()
  encoder.outputFormat = .binary
  return try encoder.encode(head)
}

private func fixtureEnvelopeContext(
  recipientCredentialID: DeviceCredentialID
) throws -> SecretSyncRecipientEnvelopeContext {
  SecretSyncRecipientEnvelopeContext(
    boundContext: try SecretSyncV1BoundContext(
      scopeID: SecretScopeID(fixtureUUID(36)),
      scopeSnapshotDigest: fixtureDigest(0x81),
      policyEpoch: 1,
      policyDigest: fixtureDigest(0x82),
      generationID: SecretGenerationID(fixtureUUID(37)),
      formatVersion: 1
    ),
    recipientCredentialID: recipientCredentialID
  )
}

private func fixtureDigest(_ byte: UInt8) throws -> SecretRecordDigest {
  try SecretRecordDigest(bytes: Data(repeating: byte, count: 32))
}

private func fixtureUUID(_ byte: UInt8) -> UUID {
  UUID(
    uuid: (
      byte, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, byte
    ))
}
