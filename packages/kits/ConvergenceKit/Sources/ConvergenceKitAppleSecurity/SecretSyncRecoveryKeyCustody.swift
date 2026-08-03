import ConvergenceKit
import CryptoKit
import Foundation

/// One branch-specific blind-confirmation ceremony.
public enum SecretSyncRecoveryConfirmationOperation: String, Sendable, Hashable {
  case enrollment = "mootx01.secret-recovery.confirmation.enrollment.v1"
  case rotation = "mootx01.secret-recovery.confirmation.rotation.v1"
  case breakGlass = "mootx01.secret-recovery.confirmation.break-glass.v1"
}

/// Public locator and descriptor for one process-local confirmation ceremony.
///
/// The handle contains no phrase, seed, scalar, or private key. It is not
/// authority without matching live state in `SecretSyncRecoveryKeyCustody`.
public struct SecretSyncRecoveryConfirmationHandle: Sendable, Hashable {
  public let operation: SecretSyncRecoveryConfirmationOperation
  public let sessionID: UUID
  public let challengeID: UUID
  public let tokenID: UUID
  public let requestID: UUID
  public let recoveryRecipient: RecoveryRecipientDescriptor

  init(
    operation: SecretSyncRecoveryConfirmationOperation,
    sessionID: UUID,
    challengeID: UUID,
    tokenID: UUID,
    requestID: UUID,
    recoveryRecipient: RecoveryRecipientDescriptor
  ) {
    self.operation = operation
    self.sessionID = sessionID
    self.challengeID = challengeID
    self.tokenID = tokenID
    self.requestID = requestID
    self.recoveryRecipient = recoveryRecipient
  }
}

/// Truthful cancellation result for a process-local ceremony.
public enum SecretSyncRecoveryCancellationResult: Sendable, Hashable {
  case cancelled
  case tooLate
  case missing
}

struct SecretSyncRecoveryFrameField: Sendable, Hashable {
  let tag: UInt16
  let value: Data
}

/// Strict local framing used by confirmation transcripts and evidence.
enum SecretSyncRecoveryFrame {
  static func encode(_ fields: [SecretSyncRecoveryFrameField]) throws -> Data {
    guard fields.count <= Int(UInt16.max) else {
      throw SecretSyncRecoveryError.invalidConfirmation
    }
    var previous: UInt16?
    var result = uint16(UInt16(fields.count))
    for field in fields {
      if let previous, field.tag <= previous {
        throw SecretSyncRecoveryError.invalidConfirmation
      }
      guard field.value.count <= Int(UInt32.max) else {
        throw SecretSyncRecoveryError.invalidConfirmation
      }
      result.append(uint16(field.tag))
      result.append(uint32(UInt32(field.value.count)))
      result.append(field.value)
      previous = field.tag
    }
    return result
  }

  static func decode(_ data: Data) throws -> [SecretSyncRecoveryFrameField] {
    var cursor = 0
    guard let count = readUInt16(data, cursor: &cursor) else {
      throw SecretSyncRecoveryError.invalidConfirmation
    }
    var fields = [SecretSyncRecoveryFrameField]()
    fields.reserveCapacity(Int(count))
    var previous: UInt16?
    for _ in 0..<count {
      guard
        let tag = readUInt16(data, cursor: &cursor),
        let length = readUInt32(data, cursor: &cursor),
        Int(length) <= data.count - cursor,
        previous == nil || tag > previous!
      else {
        throw SecretSyncRecoveryError.invalidConfirmation
      }
      let end = cursor + Int(length)
      fields.append(
        SecretSyncRecoveryFrameField(
          tag: tag,
          value: Data(data[cursor..<end])
        )
      )
      cursor = end
      previous = tag
    }
    guard cursor == data.count else {
      throw SecretSyncRecoveryError.invalidConfirmation
    }
    return fields
  }

  static func constantTimeEqual32(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == 32, rhs.count == 32 else { return false }
    var difference: UInt8 = 0
    for index in 0..<32 {
      difference |= lhs[index] ^ rhs[index]
    }
    return difference == 0
  }

  static func uuid(_ value: UUID) -> Data {
    var bytes = value.uuid
    return withUnsafeBytes(of: &bytes) { Data($0) }
  }

  static func uuid(from data: Data) throws -> UUID {
    guard data.count == 16 else {
      throw SecretSyncRecoveryError.invalidConfirmation
    }
    let bytes = [UInt8](data)
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3],
      bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11],
      bytes[12], bytes[13], bytes[14], bytes[15]
    ))
  }

  static func uint16(_ value: UInt16) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
  }

  static func uint32(_ value: UInt32) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
  }

  static func uint64(_ value: UInt64) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
  }

  private static func readUInt16(
    _ data: Data,
    cursor: inout Int
  ) -> UInt16? {
    guard data.count - cursor >= 2 else { return nil }
    let value = (UInt16(data[cursor]) << 8) | UInt16(data[cursor + 1])
    cursor += 2
    return value
  }

  private static func readUInt32(
    _ data: Data,
    cursor: inout Int
  ) -> UInt32? {
    guard data.count - cursor >= 4 else { return nil }
    var value: UInt32 = 0
    for byte in data[cursor..<(cursor + 4)] {
      value = (value << 8) | UInt32(byte)
    }
    cursor += 4
    return value
  }
}

enum SecretSyncRecoveryBranch: Sendable, Hashable {
  case enrollment
  case rotation(
    scopeID: SecretScopeID,
    currentRecoveryRecipientID: UUID,
    currentGenerationID: SecretGenerationID,
    replacementGenerationID: SecretGenerationID,
    freshness: SecretBootstrapFreshnessCommitment
  )
  /// Full-loss break-glass, bound to the intent the recovery key will sign.
  ///
  /// `intentDigest` is the SHA-256 of the canonical
  /// `GlobalRecoveryTransitionIntent` this ceremony authorizes. It is `nil`
  /// only in the window between `beginBreakGlass` and `confirmBreakGlass`:
  /// the intent embeds the challenge and session identifiers that `begin`
  /// itself mints, so no caller can construct it any earlier. From
  /// confirmation onward the digest is fixed, and every transcript that
  /// `consume` recomputes carries it — which is what makes the signature
  /// cover the intent the user actually confirmed.
  case breakGlass(
    scopeID: SecretScopeID,
    currentRecoveryRecipientID: UUID,
    sealedGenerationID: SecretGenerationID,
    freshness: SecretBootstrapFreshnessCommitment,
    intentDigest: Data?
  )

  var operation: SecretSyncRecoveryConfirmationOperation {
    switch self {
    case .enrollment: .enrollment
    case .rotation: .rotation
    case .breakGlass: .breakGlass
    }
  }

  /// The canonical intent digest this break-glass ceremony is bound to.
  ///
  /// `nil` for enrollment and rotation, which authorize no intent, and for a
  /// break-glass ceremony that has not yet been confirmed.
  var breakGlassIntentDigest: Data? {
    guard case let .breakGlass(_, _, _, _, intentDigest) = self else {
      return nil
    }
    return intentDigest
  }

  /// Returns the same break-glass branch bound to `intentDigest`.
  ///
  /// Returns `nil` for any other branch: enrollment and rotation authorize no
  /// intent and must never acquire one.
  func boundToBreakGlassIntent(
    _ intentDigest: Data
  ) -> SecretSyncRecoveryBranch? {
    guard case let .breakGlass(
      scopeID,
      currentRecoveryRecipientID,
      sealedGenerationID,
      freshness,
      _
    ) = self else {
      return nil
    }
    return .breakGlass(
      scopeID: scopeID,
      currentRecoveryRecipientID: currentRecoveryRecipientID,
      sealedGenerationID: sealedGenerationID,
      freshness: freshness,
      intentDigest: intentDigest
    )
  }
}

enum SecretSyncRecoveryPendingState: Sendable {
  case pending
  case confirmed
  case consumed
  case cancelled
}

struct SecretSyncRecoveryPending: Sendable {
  let handle: SecretSyncRecoveryConfirmationHandle
  /// Mutable for exactly one transition: `confirmBreakGlass` rebinds the
  /// break-glass branch to the confirmed intent digest. Enrollment and
  /// rotation branches are written once at `begin` and never change.
  var branch: SecretSyncRecoveryBranch
  /// The commitment `consume` admits against. `begin` writes the transcript
  /// hash for the branch as recorded there; `confirmBreakGlass` replaces it
  /// with the hash of the intent-bearing transcript, so from confirmation
  /// onward the only admissible transcript is the bound one.
  var transcriptCommitment: Data
  var phraseForReveal: String?
  var material: SecretSyncRecoveryDerivedMaterial?
  var state: SecretSyncRecoveryPendingState
}

struct SecretSyncRecoveryDecodedEvidence: Sendable {
  let sessionID: UUID
  let tokenID: UUID
  let commitment: Data
}

/// Process-local deterministic recovery custody and one-shot confirmation gate.
///
/// This actor deliberately performs no Keychain, Secure Enclave,
/// LocalAuthentication, Passwords, CloudKit, or persistence operation.
public actor SecretSyncRecoveryKeyCustody:
  SecretSyncRecoveryRecipientCustody
{
  typealias EvidenceBuilder = @Sendable (
    SecretSyncRecoveryConfirmationOperation,
    UUID,
    RecoveryRecipientDescriptor,
    Data,
    Data?
  ) throws -> RecoveryOperationEvidence

  let entropySource: @Sendable () throws -> Data
  let uuidSource: @Sendable () -> UUID
  let operationEvidenceBuilder: EvidenceBuilder
  let derivation: SecretSyncRecoverySeedDerivation
  var pendingByToken: [UUID: SecretSyncRecoveryPending] = [:]
  var activeMaterial: SecretSyncRecoveryDerivedMaterial?

  /// Creates prompt-free process-local custody using system cryptographic
  /// randomness. Durable platform custody arrives only after G-RUNTIME.
  public init() {
    entropySource = Self.randomEntropy
    uuidSource = UUID.init
    operationEvidenceBuilder = Self.defaultOperationEvidence
    derivation = SecretSyncRecoverySeedDerivation()
  }

  init(
    entropySource: @escaping @Sendable () throws -> Data,
    uuidSource: @escaping @Sendable () -> UUID,
    operationEvidenceBuilder: @escaping EvidenceBuilder,
    derivation: SecretSyncRecoverySeedDerivation = .init()
  ) {
    self.entropySource = entropySource
    self.uuidSource = uuidSource
    self.operationEvidenceBuilder = operationEvidenceBuilder
    self.derivation = derivation
  }

  /// Returns the currently activated public recovery descriptor, if any.
  public func globalRecoveryRecipient() async throws
    -> RecoveryRecipientDescriptor?
  {
    activeMaterial?.descriptor
  }

  /// Begins one enrollment ceremony bound to a fresh descriptor and phrase.
  public func beginEnrollment(
    requestID: UUID
  ) throws -> SecretSyncRecoveryConfirmationHandle {
    let created = try makeFreshMaterial()
    return try begin(
      requestID: requestID,
      descriptor: created.material.descriptor,
      branch: .enrollment,
      phrase: created.mnemonic.canonicalPhrase,
      material: created.material
    )
  }

  /// Reveals a generated phrase exactly once for enrollment or rotation.
  public func revealPhrase(
    for handle: SecretSyncRecoveryConfirmationHandle
  ) throws -> String {
    guard var pending = pendingByToken[handle.tokenID] else {
      throw SecretSyncRecoveryError.missingCeremony
    }
    try requireExact(handle, pending: pending)
    switch pending.state {
    case .cancelled:
      throw SecretSyncRecoveryError.cancelled
    case .consumed, .confirmed:
      throw SecretSyncRecoveryError.alreadyConsumed
    case .pending:
      break
    }
    guard let phrase = pending.phraseForReveal else {
      throw SecretSyncRecoveryError.alreadyConsumed
    }
    pending.phraseForReveal = nil
    pendingByToken[handle.tokenID] = pending
    return phrase
  }

  /// Confirms one complete 24-word phrase against the exact pending operation.
  ///
  /// Break-glass ceremonies are refused here. They authorize a signature over
  /// a specific `GlobalRecoveryTransitionIntent`, so they must commit to that
  /// intent as part of being confirmed; use
  /// `confirmBreakGlass(_:phrase:intent:)`. Admitting one through this method
  /// would produce a confirmation bound to no intent, which is exactly the
  /// substitution the ceremony exists to prevent.
  public func confirm(
    _ handle: SecretSyncRecoveryConfirmationHandle,
    phrase: String
  ) throws -> BlindRecoveryConfirmationEvidence {
    guard handle.operation != .breakGlass else {
      throw SecretSyncRecoveryError.invalidConfirmation
    }
    return try admit(handle, phrase: phrase, intentDigest: nil)
  }

  /// Confirms a break-glass phrase against the exact intent it authorizes.
  ///
  /// The canonical digest of `intent` is committed into the confirmation
  /// transcript before any evidence is returned, and `consume` admits only a
  /// transcript carrying that same digest. The signature the recovery key
  /// later produces therefore covers the intent the user confirmed and no
  /// other: substituting any field of `intent` between here and
  /// `stageBreakGlassAuthorization(_:intent:freshnessAnchor:)` changes the
  /// digest, and the confirmation is refused without being spent.
  ///
  /// `intent` has no default. An unbound break-glass confirmation is not
  /// representable, so no caller can omit the binding by accident.
  public func confirmBreakGlass(
    _ handle: SecretSyncRecoveryConfirmationHandle,
    phrase: String,
    intent: GlobalRecoveryTransitionIntent
  ) throws -> BlindRecoveryConfirmationEvidence {
    guard handle.operation == .breakGlass else {
      throw SecretSyncRecoveryError.invalidConfirmation
    }
    let canonicalIntent: Data
    do {
      canonicalIntent = try intent.canonicalBytes()
    } catch {
      throw SecretSyncRecoveryError.invalidConfirmation
    }
    return try admit(
      handle,
      phrase: phrase,
      intentDigest: Data(SHA256.hash(data: canonicalIntent))
    )
  }

  /// Shared confirmation path. `intentDigest` is non-nil exactly for
  /// break-glass, whose callers are the only ones that reach it.
  private func admit(
    _ handle: SecretSyncRecoveryConfirmationHandle,
    phrase: String,
    intentDigest: Data?
  ) throws -> BlindRecoveryConfirmationEvidence {
    guard var pending = pendingByToken[handle.tokenID] else {
      throw SecretSyncRecoveryError.missingCeremony
    }
    try requireExact(handle, pending: pending)
    switch pending.state {
    case .cancelled:
      throw SecretSyncRecoveryError.cancelled
    case .confirmed, .consumed:
      throw SecretSyncRecoveryError.alreadyConsumed
    case .pending:
      break
    }
    let mnemonic: SecretSyncRecoveryMnemonic
    let material: SecretSyncRecoveryDerivedMaterial
    do {
      mnemonic = try SecretSyncRecoveryMnemonic(phrase: phrase)
      material = try derivation.derive(
        masterSeed: mnemonic.masterSeed,
        recoveryRecipientID: pending.handle.recoveryRecipient
          .recoveryRecipientID
      )
    } catch {
      throw SecretSyncRecoveryError.invalidConfirmation
    }
    guard material.descriptor == pending.handle.recoveryRecipient else {
      throw SecretSyncRecoveryError.invalidConfirmation
    }
    // The phrase is admitted against the branch exactly as `begin` recorded
    // it, proving the ceremony was not altered between begin and confirmation.
    let transcript = try Self.transcript(
      handle: pending.handle,
      branch: pending.branch,
      descriptor: material.descriptor
    )
    guard Self.constantTimeCommitment(
      Data(SHA256.hash(data: transcript)),
      pending.transcriptCommitment
    ) else {
      throw SecretSyncRecoveryError.invalidConfirmation
    }
    if let intentDigest {
      // Break-glass binds here. The branch acquires the intent digest and the
      // stored commitment is replaced by the transcript that carries it, so
      // the intent-free transcript is no longer admissible for this token.
      // Both the evidence returned below and the commitment `consume` checks
      // are therefore the bound ones — the digest gates, it is not merely
      // recorded.
      guard let bound = pending.branch.boundToBreakGlassIntent(intentDigest)
      else {
        throw SecretSyncRecoveryError.invalidConfirmation
      }
      let boundTranscript = try Self.transcript(
        handle: pending.handle,
        branch: bound,
        descriptor: material.descriptor
      )
      pending.branch = bound
      pending.transcriptCommitment = Data(SHA256.hash(data: boundTranscript))
    }
    pending.state = .confirmed
    pending.material = material
    pending.phraseForReveal = nil
    pendingByToken[handle.tokenID] = pending
    return try Self.confirmationEvidence(for: pending)
  }

  /// Cancels a pending or confirmed ceremony without creating authority.
  public func cancel(
    _ handle: SecretSyncRecoveryConfirmationHandle
  ) -> SecretSyncRecoveryCancellationResult {
    guard var pending = pendingByToken[handle.tokenID],
          pending.handle == handle
    else {
      return .missing
    }
    switch pending.state {
    case .pending, .confirmed:
      pending.state = .cancelled
      pending.material = nil
      pending.phraseForReveal = nil
      pendingByToken[handle.tokenID] = pending
      return .cancelled
    case .consumed:
      return .tooLate
    case .cancelled:
      return .cancelled
    }
  }

  /// Stages enrollment only after exact live confirmation, consuming first.
  public func stageEnrollment(
    _ request: RecoveryEnrollmentRequest
  ) async throws -> RecoveryOperationEvidence {
    let admitted = try consume(
      evidence: request.blindConfirmation,
      requestID: request.requestID,
      descriptor: request.recoveryRecipient,
      expectedBranch: .enrollment
    )
    let output = try operationEvidenceBuilder(
      .enrollment,
      request.requestID,
      request.recoveryRecipient,
      admitted.commitment,
      nil
    )
    activeMaterial = admitted.material
    return output
  }

  func begin(
    requestID: UUID,
    descriptor: RecoveryRecipientDescriptor,
    branch: SecretSyncRecoveryBranch,
    phrase: String?,
    material: SecretSyncRecoveryDerivedMaterial?
  ) throws -> SecretSyncRecoveryConfirmationHandle {
    let handle = SecretSyncRecoveryConfirmationHandle(
      operation: branch.operation,
      sessionID: uuidSource(),
      challengeID: uuidSource(),
      tokenID: uuidSource(),
      requestID: requestID,
      recoveryRecipient: descriptor
    )
    let bytes = try Self.transcript(
      handle: handle,
      branch: branch,
      descriptor: descriptor
    )
    let pending = SecretSyncRecoveryPending(
      handle: handle,
      branch: branch,
      transcriptCommitment: Data(SHA256.hash(data: bytes)),
      phraseForReveal: phrase,
      material: material,
      state: .pending
    )
    pendingByToken[handle.tokenID] = pending
    return handle
  }

  struct Admitted: Sendable {
    let material: SecretSyncRecoveryDerivedMaterial
    let commitment: Data
  }

  func consume(
    evidence: BlindRecoveryConfirmationEvidence,
    requestID: UUID,
    descriptor: RecoveryRecipientDescriptor,
    expectedBranch: SecretSyncRecoveryBranch
  ) throws -> Admitted {
    let decoded = try Self.decodeEvidence(evidence.evidenceBytes)
    guard var pending = pendingByToken[decoded.tokenID] else {
      throw SecretSyncRecoveryError.missingCeremony
    }
    switch pending.state {
    case .cancelled:
      throw SecretSyncRecoveryError.cancelled
    case .consumed:
      throw SecretSyncRecoveryError.alreadyConsumed
    case .pending:
      throw SecretSyncRecoveryError.invalidConfirmation
    case .confirmed:
      break
    }
    // A break-glass token is admissible only for the exact intent its
    // confirmation committed to. The structural equality below would already
    // catch a mismatch; this compares the digests in constant time first, and
    // states the invariant where it is enforced. An expected branch carrying
    // no digest — an unbound break-glass, or a rotation or enrollment record
    // replayed as one — is refused here.
    if expectedBranch.operation == .breakGlass {
      guard
        let expected = expectedBranch.breakGlassIntentDigest,
        let confirmed = pending.branch.breakGlassIntentDigest,
        SecretSyncRecoveryFrame.constantTimeEqual32(expected, confirmed)
      else {
        throw SecretSyncRecoveryError.invalidConfirmation
      }
    }
    guard
      pending.branch == expectedBranch,
      pending.handle.operation == expectedBranch.operation,
      pending.handle.sessionID == decoded.sessionID,
      pending.handle.tokenID == decoded.tokenID,
      pending.handle.requestID == requestID,
      pending.handle.challengeID == evidence.challengeID,
      pending.handle.recoveryRecipient.recoveryRecipientID
        == evidence.recoveryRecipientID,
      pending.handle.recoveryRecipient == descriptor,
      let material = pending.material,
      material.descriptor == descriptor
    else {
      throw SecretSyncRecoveryError.invalidConfirmation
    }
    let transcript = try Self.transcript(
      handle: pending.handle,
      branch: expectedBranch,
      descriptor: descriptor
    )
    let commitment = Data(SHA256.hash(data: transcript))
    guard
      Self.constantTimeCommitment(commitment, decoded.commitment),
      Self.constantTimeCommitment(commitment, pending.transcriptCommitment)
    else {
      throw SecretSyncRecoveryError.invalidConfirmation
    }
    // Consumption is the linearization point. No output is built before this
    // irreversible state change, and output failure never restores the token.
    pending.state = .consumed
    pending.material = nil
    pending.phraseForReveal = nil
    pendingByToken[decoded.tokenID] = pending
    return Admitted(
      material: material,
      commitment: commitment
    )
  }

  static func transcript(
    handle: SecretSyncRecoveryConfirmationHandle,
    branch: SecretSyncRecoveryBranch,
    descriptor: RecoveryRecipientDescriptor
  ) throws -> Data {
    guard handle.operation == branch.operation,
          handle.recoveryRecipient == descriptor
    else {
      throw SecretSyncRecoveryError.invalidConfirmation
    }
    var fields = [
      SecretSyncRecoveryFrameField(
        tag: 1,
        value: Data(
          "mootx01.secret-recovery.confirmation-transcript.v1".utf8
        )
      ),
      SecretSyncRecoveryFrameField(tag: 2, value: Data(branch.operation.rawValue.utf8)),
      SecretSyncRecoveryFrameField(tag: 3, value: SecretSyncRecoveryFrame.uuid(handle.sessionID)),
      SecretSyncRecoveryFrameField(tag: 4, value: SecretSyncRecoveryFrame.uuid(handle.tokenID)),
      SecretSyncRecoveryFrameField(tag: 5, value: SecretSyncRecoveryFrame.uuid(handle.requestID)),
      SecretSyncRecoveryFrameField(tag: 6, value: SecretSyncRecoveryFrame.uuid(handle.challengeID)),
      SecretSyncRecoveryFrameField(tag: 7, value: SecretSyncRecoveryFrame.uuid(descriptor.recoveryRecipientID)),
      SecretSyncRecoveryFrameField(tag: 8, value: try descriptorFrame(descriptor)),
    ]
    switch branch {
    case .enrollment:
      break
    case let .rotation(
      scopeID,
      currentRecoveryRecipientID,
      currentGenerationID,
      replacementGenerationID,
      freshness
    ):
      fields += [
        .init(tag: 9, value: SecretSyncRecoveryFrame.uuid(scopeID.rawValue)),
        .init(tag: 10, value: SecretSyncRecoveryFrame.uuid(currentRecoveryRecipientID)),
        .init(tag: 11, value: SecretSyncRecoveryFrame.uuid(currentGenerationID.rawValue)),
        .init(tag: 12, value: SecretSyncRecoveryFrame.uuid(replacementGenerationID.rawValue)),
        .init(tag: 13, value: try freshnessFrame(freshness)),
      ]
    case let .breakGlass(
      scopeID,
      currentRecoveryRecipientID,
      sealedGenerationID,
      freshness,
      intentDigest
    ):
      fields += [
        .init(tag: 9, value: SecretSyncRecoveryFrame.uuid(scopeID.rawValue)),
        .init(tag: 10, value: SecretSyncRecoveryFrame.uuid(currentRecoveryRecipientID)),
        .init(tag: 11, value: SecretSyncRecoveryFrame.uuid(sealedGenerationID.rawValue)),
        .init(tag: 12, value: try freshnessFrame(freshness)),
      ]
      // Tag 13 is the SHA-256 of the canonical intent the recovery key will
      // sign. It is absent from the pre-confirmation transcript `begin`
      // commits to and present from `confirmBreakGlass` onward, so a bound
      // confirmation and an unbound one are different transcripts by
      // construction and neither can stand in for the other.
      if let intentDigest {
        fields.append(.init(tag: 13, value: intentDigest))
      }
    }
    return try SecretSyncRecoveryFrame.encode(fields)
  }

  static func descriptorFrame(
    _ descriptor: RecoveryRecipientDescriptor
  ) throws -> Data {
    try SecretSyncRecoveryFrame.encode([
      .init(tag: 1, value: SecretSyncRecoveryFrame.uuid(descriptor.recoveryRecipientID)),
      .init(tag: 2, value: Data(descriptor.keyAgreementPublicKey.algorithmIdentifier.utf8)),
      .init(tag: 3, value: descriptor.keyAgreementPublicKey.keyIdentifier),
      .init(tag: 4, value: descriptor.keyAgreementPublicKey.publicKeyBytes),
      .init(tag: 5, value: Data(descriptor.authorizationSigningPublicKey.algorithmIdentifier.utf8)),
      .init(tag: 6, value: descriptor.authorizationSigningPublicKey.keyIdentifier),
      .init(tag: 7, value: descriptor.authorizationSigningPublicKey.publicKeyBytes),
    ])
  }

  static func freshnessFrame(
    _ freshness: SecretBootstrapFreshnessCommitment
  ) throws -> Data {
    try SecretSyncRecoveryFrame.encode([
      .init(tag: 1, value: SecretSyncRecoveryFrame.uuid(freshness.scopeID.rawValue)),
      .init(tag: 2, value: SecretSyncRecoveryFrame.uint64(freshness.latestPolicyEpoch)),
      .init(tag: 3, value: freshness.headCommitDigest.bytes),
      .init(tag: 4, value: freshness.policyDigest.bytes),
    ])
  }

  static func confirmationEvidence(
    for pending: SecretSyncRecoveryPending
  ) throws -> BlindRecoveryConfirmationEvidence {
    let bytes = try SecretSyncRecoveryFrame.encode([
      .init(
        tag: 1,
        value: Data(
          "mootx01.secret-recovery.confirmation-evidence.v1".utf8
        )
      ),
      .init(tag: 2, value: SecretSyncRecoveryFrame.uuid(pending.handle.sessionID)),
      .init(tag: 3, value: SecretSyncRecoveryFrame.uuid(pending.handle.tokenID)),
      .init(tag: 4, value: pending.transcriptCommitment),
    ])
    return try BlindRecoveryConfirmationEvidence(
      recoveryRecipientID: pending.handle.recoveryRecipient
        .recoveryRecipientID,
      challengeID: pending.handle.challengeID,
      evidenceBytes: bytes
    )
  }

  static func decodeEvidence(_ bytes: Data) throws
    -> SecretSyncRecoveryDecodedEvidence
  {
    let fields = try SecretSyncRecoveryFrame.decode(bytes)
    guard
      fields.map(\.tag) == [1, 2, 3, 4],
      fields[0].value == Data(
        "mootx01.secret-recovery.confirmation-evidence.v1".utf8
      ),
      fields[3].value.count == 32
    else {
      throw SecretSyncRecoveryError.invalidConfirmation
    }
    return try SecretSyncRecoveryDecodedEvidence(
      sessionID: SecretSyncRecoveryFrame.uuid(from: fields[1].value),
      tokenID: SecretSyncRecoveryFrame.uuid(from: fields[2].value),
      commitment: fields[3].value
    )
  }

  static func defaultOperationEvidence(
    operation: SecretSyncRecoveryConfirmationOperation,
    requestID: UUID,
    descriptor: RecoveryRecipientDescriptor,
    commitment: Data,
    signature: Data?
  ) throws -> RecoveryOperationEvidence {
    var fields = [
      SecretSyncRecoveryFrameField(
        tag: 1,
        value: Data("mootx01.secret-recovery.operation-evidence.v1".utf8)
      ),
      .init(tag: 2, value: Data(operation.rawValue.utf8)),
      .init(tag: 3, value: SecretSyncRecoveryFrame.uuid(requestID)),
      .init(tag: 4, value: try descriptorFrame(descriptor)),
      .init(tag: 5, value: commitment),
    ]
    if let signature {
      fields.append(.init(tag: 6, value: signature))
    }
    return try RecoveryOperationEvidence(
      requestID: requestID,
      evidenceBytes: SecretSyncRecoveryFrame.encode(fields)
    )
  }

  static func constantTimeCommitment(_ lhs: Data, _ rhs: Data) -> Bool {
    SecretSyncRecoveryFrame.constantTimeEqual32(lhs, rhs)
  }

  private func requireExact(
    _ handle: SecretSyncRecoveryConfirmationHandle,
    pending: SecretSyncRecoveryPending
  ) throws {
    guard pending.handle == handle else {
      throw SecretSyncRecoveryError.invalidConfirmation
    }
  }

  private func makeFreshMaterial() throws -> (
    mnemonic: SecretSyncRecoveryMnemonic,
    material: SecretSyncRecoveryDerivedMaterial
  ) {
    for _ in 0..<32 {
      let mnemonic = try SecretSyncRecoveryMnemonic(
        masterSeed: entropySource()
      )
      do {
        let material = try derivation.derive(
          masterSeed: mnemonic.masterSeed,
          recoveryRecipientID: uuidSource()
        )
        return (mnemonic, material)
      } catch SecretSyncRecoveryError.roleCollision {
        continue
      }
    }
    throw SecretSyncRecoveryError.derivationExhausted
  }

  private static func randomEntropy() throws -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
  }
}
