import ConvergenceKit
import CryptoKit
import Foundation

/// One consumed break-glass admission plus the exact U6A intent signature.
///
/// The custody evidence proves that the process-local blind confirmation was
/// admitted once. The signature is authority only for `intent`'s canonical
/// `GlobalRecoveryTransitionIntent` bytes; callers supply the content address
/// later when constructing `FullLossRecoveryAuthorization`.
public struct SecretSyncFullLossAuthorizationEvidence: Sendable, Hashable {
  public let custodyEvidence: RecoveryOperationEvidence
  public let intent: GlobalRecoveryTransitionIntent
  public let signature: Data

  init(
    custodyEvidence: RecoveryOperationEvidence,
    intent: GlobalRecoveryTransitionIntent,
    signature: Data
  ) {
    self.custodyEvidence = custodyEvidence
    self.intent = intent
    self.signature = signature
  }

  /// Builds the U6A authorization record after orchestration assigns its
  /// content-addressed digest. No policy, commit, or store graph is created.
  public func authorization(
    recordDigest: SecretRecordDigest
  ) throws -> FullLossRecoveryAuthorization {
    try FullLossRecoveryAuthorization(
      recordDigest: recordDigest,
      intent: intent,
      signature: signature
    )
  }
}

extension SecretSyncRecoveryKeyCustody {
  /// Begins an ordinary trusted-device rotation with fresh custody material.
  public func beginRotation(
    requestID: UUID,
    scopeID: SecretScopeID,
    currentRecoveryRecipientID: UUID,
    currentGenerationID: SecretGenerationID,
    replacementGenerationID: SecretGenerationID,
    expectedFreshnessCommitment: SecretBootstrapFreshnessCommitment
  ) throws -> SecretSyncRecoveryConfirmationHandle {
    guard
      let activeMaterial,
      activeMaterial.descriptor.recoveryRecipientID
        == currentRecoveryRecipientID,
      currentGenerationID != replacementGenerationID,
      scopeID == expectedFreshnessCommitment.scopeID
    else {
      throw SecretSyncRecoveryError.invalidConfirmation
    }
    let created = try makeRotationMaterial()
    return try begin(
      requestID: requestID,
      descriptor: created.material.descriptor,
      branch: .rotation(
        scopeID: scopeID,
        currentRecoveryRecipientID: currentRecoveryRecipientID,
        currentGenerationID: currentGenerationID,
        replacementGenerationID: replacementGenerationID,
        freshness: expectedFreshnessCommitment
      ),
      phrase: created.mnemonic.canonicalPhrase,
      material: created.material
    )
  }

  /// Begins explicit full-loss staging against the current public descriptor.
  ///
  /// The current phrase is not retained or revealed by this operation. The
  /// complete phrase and the exact intent this recovery authorizes must both
  /// be supplied later to `confirmBreakGlass(_:phrase:intent:)`.
  ///
  /// The intent cannot be supplied here: it embeds the challenge and session
  /// identifiers minted inside this call, so the caller first learns them from
  /// the returned handle. Confirmation is therefore the earliest point at
  /// which the ceremony can commit to the intent, and it is where it does.
  public func beginBreakGlass(
    requestID: UUID,
    scopeID: SecretScopeID,
    currentRecoveryRecipient: RecoveryRecipientDescriptor,
    sealedGenerationID: SecretGenerationID,
    expectedFreshnessCommitment: SecretBootstrapFreshnessCommitment
  ) throws -> SecretSyncRecoveryConfirmationHandle {
    guard
      scopeID == expectedFreshnessCommitment.scopeID
    else {
      throw SecretSyncRecoveryError.invalidConfirmation
    }
    return try begin(
      requestID: requestID,
      descriptor: currentRecoveryRecipient,
      branch: .breakGlass(
        scopeID: scopeID,
        currentRecoveryRecipientID:
          currentRecoveryRecipient.recoveryRecipientID,
        sealedGenerationID: sealedGenerationID,
        freshness: expectedFreshnessCommitment,
        intentDigest: nil
      ),
      phrase: nil,
      material: nil
    )
  }

  /// Stages ordinary rotation under normal authority and emits no recovery
  /// authorization signature or full-loss graph object.
  public func stageRotation(
    _ request: RecoveryRotationRequest,
    freshnessAnchor: any ExternalBootstrapFreshnessAnchor
  ) async throws -> RecoveryOperationEvidence {
    let latest = try await freshnessAnchor.latestCommitment(
      for: request.scopeID
    )
    guard latest == request.expectedFreshnessCommitment else {
      throw SecretSyncRecoveryError.freshnessMismatch
    }
    let branch = SecretSyncRecoveryBranch.rotation(
      scopeID: request.scopeID,
      currentRecoveryRecipientID: request.currentRecoveryRecipientID,
      currentGenerationID: request.currentGenerationID,
      replacementGenerationID: request.replacementGenerationID,
      freshness: request.expectedFreshnessCommitment
    )
    guard
      activeMaterial?.descriptor.recoveryRecipientID
        == request.currentRecoveryRecipientID
    else {
      throw SecretSyncRecoveryError.invalidConfirmation
    }
    let admitted = try consume(
      evidence: request.blindConfirmation,
      requestID: request.requestID,
      descriptor: request.replacementRecoveryRecipient,
      expectedBranch: branch
    )
    let output = try operationEvidenceBuilder(
      .rotation,
      request.requestID,
      request.replacementRecoveryRecipient,
      admitted.commitment,
      nil
    )
    activeMaterial = admitted.material
    return output
  }

  /// Stages unsigned break-glass custody evidence through the existing core
  /// protocol. Recovery authority requires the intent-bearing overload below.
  public func stageBreakGlass(
    _ request: BreakGlassRecoveryRequest,
    freshnessAnchor: any ExternalBootstrapFreshnessAnchor
  ) async throws -> RecoveryOperationEvidence {
    let latest = try await freshnessAnchor.latestCommitment(
      for: request.scopeID
    )
    guard latest == request.expectedFreshnessCommitment else {
      throw SecretSyncRecoveryError.freshnessMismatch
    }
    guard let pending = pendingFor(request.blindConfirmation) else {
      throw SecretSyncRecoveryError.missingCeremony
    }
    let descriptor = pending.handle.recoveryRecipient
    // This path signs nothing, so it carries no intent of its own to bind. It
    // reproduces the digest the confirmation already committed to, taken from
    // live custody state and never from caller input, which is the only value
    // `consume` will admit. The token therefore stays single-use across both
    // stage paths. Nothing can be laundered in here either: a break-glass
    // ceremony reaches `.confirmed` only through
    // `confirmBreakGlass(_:phrase:intent:)`, which always binds, so an
    // unbound confirmation does not exist to be spent.
    let branch = SecretSyncRecoveryBranch.breakGlass(
      scopeID: request.scopeID,
      currentRecoveryRecipientID: request.recoveryRecipientID,
      sealedGenerationID: request.sealedGenerationID,
      freshness: request.expectedFreshnessCommitment,
      intentDigest: pending.branch.breakGlassIntentDigest
    )
    let admitted = try consume(
      evidence: request.blindConfirmation,
      requestID: request.requestID,
      descriptor: descriptor,
      expectedBranch: branch
    )
    return try operationEvidenceBuilder(
      .breakGlass,
      request.requestID,
      descriptor,
      admitted.commitment,
      nil
    )
  }

  /// Consumes one exact break-glass confirmation and signs only the canonical
  /// U6A full-loss intent with the current recovery authorization key.
  ///
  /// The result is a leaf artifact. It creates no policy, commit, CloudKit or
  /// store graph, trusted device, purge record, or prepared transition.
  public func stageBreakGlassAuthorization(
    _ request: BreakGlassRecoveryRequest,
    intent: GlobalRecoveryTransitionIntent,
    freshnessAnchor: any ExternalBootstrapFreshnessAnchor
  ) async throws -> SecretSyncFullLossAuthorizationEvidence {
    let latest = try await freshnessAnchor.latestCommitment(
      for: request.scopeID
    )
    guard latest == request.expectedFreshnessCommitment else {
      throw SecretSyncRecoveryError.freshnessMismatch
    }
    guard let pending = pendingFor(request.blindConfirmation) else {
      throw SecretSyncRecoveryError.missingCeremony
    }
    let descriptor = pending.handle.recoveryRecipient
    let freshness = request.expectedFreshnessCommitment
    guard
      intent.challenge.requestID == request.requestID,
      intent.challenge.challengeID == pending.handle.challengeID,
      intent.challenge.sessionID == pending.handle.sessionID,
      intent.scopeID == request.scopeID,
      intent.currentGenerationID == request.sealedGenerationID,
      intent.currentRecoveryRecipient == descriptor,
      intent.currentRecoveryRecipient.recoveryRecipientID
        == request.recoveryRecipientID,
      intent.currentPolicyEpoch == freshness.latestPolicyEpoch,
      intent.currentCommitDigest == freshness.headCommitDigest,
      intent.currentPolicyDigest == freshness.policyDigest
    else {
      throw SecretSyncRecoveryError.invalidConfirmation
    }
    let canonicalIntent: Data
    do {
      canonicalIntent = try intent.canonicalBytes()
    } catch {
      throw SecretSyncRecoveryError.invalidConfirmation
    }
    // The digest of the exact bytes about to be signed. If it differs from the
    // one the confirmation committed to — that is, if any field of `intent`
    // was substituted after the user entered the phrase — `consume` refuses
    // before the token is spent, and nothing is signed.
    let branch = SecretSyncRecoveryBranch.breakGlass(
      scopeID: request.scopeID,
      currentRecoveryRecipientID: request.recoveryRecipientID,
      sealedGenerationID: request.sealedGenerationID,
      freshness: freshness,
      intentDigest: Data(SHA256.hash(data: canonicalIntent))
    )
    let admitted = try consume(
      evidence: request.blindConfirmation,
      requestID: request.requestID,
      descriptor: descriptor,
      expectedBranch: branch
    )
    // The process-local token is now irreversibly consumed. Any builder or
    // signing failure below cannot restore it or activate another operation.
    let custodyEvidence = try operationEvidenceBuilder(
      .breakGlass,
      request.requestID,
      descriptor,
      admitted.commitment,
      nil
    )
    let created: P256.Signing.ECDSASignature
    do {
      created = try admitted.material.authorizationSigningPrivateKey
        .signature(for: canonicalIntent)
    } catch {
      throw SecretSyncRecoveryError.outputFailure
    }
    let signature = Self.canonicalLowS(created.rawRepresentation)
    guard signature.count == 64 else {
      throw SecretSyncRecoveryError.outputFailure
    }
    return SecretSyncFullLossAuthorizationEvidence(
      custodyEvidence: custodyEvidence,
      intent: intent,
      signature: signature
    )
  }

  private func pendingFor(
    _ evidence: BlindRecoveryConfirmationEvidence
  ) -> SecretSyncRecoveryPending? {
    guard
      let decoded = try? Self.decodeEvidence(evidence.evidenceBytes)
    else {
      return nil
    }
    return pendingByToken[decoded.tokenID]
  }

  private func makeRotationMaterial() throws -> (
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

  // Recovery authorization signatures use the same raw64 low-S rule as the
  // existing v1 provider. CryptoKit performs ECDSA; this representation-only
  // transform replaces S with n-S when required.
  private static func canonicalLowS(_ raw: Data) -> Data {
    guard raw.count == 64 else { return Data() }
    let order = Data([
      0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
      0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
      0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84,
      0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51,
    ])
    let halfOrder = Data([
      0x7f, 0xff, 0xff, 0xff, 0x80, 0x00, 0x00, 0x00,
      0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
      0xde, 0x73, 0x7d, 0x56, 0xd3, 0x8b, 0xcf, 0x42,
      0x79, 0xdc, 0xe5, 0x61, 0x7e, 0x31, 0x92, 0xa8,
    ])
    let s = Data(raw.suffix(32))
    guard !halfOrder.lexicographicallyPrecedes(s) else {
      var output = raw
      output.replaceSubrange(32..<64, with: subtract(order, s))
      return output
    }
    return raw
  }

  private static func subtract(_ lhs: Data, _ rhs: Data) -> Data {
    let left = [UInt8](lhs)
    let right = [UInt8](rhs)
    var output = [UInt8](repeating: 0, count: left.count)
    var borrow = 0
    for index in stride(from: left.count - 1, through: 0, by: -1) {
      var value = Int(left[index]) - Int(right[index]) - borrow
      if value < 0 {
        value += 256
        borrow = 1
      } else {
        borrow = 0
      }
      output[index] = UInt8(value)
    }
    return Data(output)
  }
}
