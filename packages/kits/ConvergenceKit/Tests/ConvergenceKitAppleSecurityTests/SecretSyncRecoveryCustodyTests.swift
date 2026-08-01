import ConvergenceKit
import CryptoKit
import Foundation
import Testing

@testable import ConvergenceKitAppleSecurity

@Suite("SecretSync recovery custody")
struct SecretSyncRecoveryCustodyTests {
  @Test("enrollment reveals once, confirms completely, stages once, and activates")
  func enrollmentLifecycle() async throws {
    let fixture = U6BFixture()
    let custody = fixture.custody()
    let handle = try await custody.beginEnrollment(requestID: fixture.requestID)
    let phrase = try await custody.revealPhrase(for: handle)
    let transcript = try SecretSyncRecoveryKeyCustody.transcript(
      handle: handle,
      branch: .enrollment,
      descriptor: handle.recoveryRecipient
    )
    #expect(transcript.count == 607)
    #expect(
      Data(SHA256.hash(data: transcript))
        == u6Hex("0be535ffd84a0d8cec8412736bdd817bcd90cf0d432318dd060001a98d7697af")
    )
    #expect(phrase.split(separator: " ").count == 24)
    await #expect(throws: SecretSyncRecoveryError.alreadyConsumed) {
      _ = try await custody.revealPhrase(for: handle)
    }
    let confirmation = try await custody.confirm(handle, phrase: phrase)
    let request = try RecoveryEnrollmentRequest(
      requestID: handle.requestID,
      recoveryRecipient: handle.recoveryRecipient,
      blindConfirmation: confirmation
    )
    let output = try await custody.stageEnrollment(request)
    #expect(output.requestID == fixture.requestID)
    #expect(
      try await custody.globalRecoveryRecipient()
        == handle.recoveryRecipient
    )
    #expect(await custody.cancel(handle) == .tooLate)
    await #expect(throws: SecretSyncRecoveryError.alreadyConsumed) {
      _ = try await custody.stageEnrollment(request)
    }
  }

  @Test("cancellation after confirmation prevents staging")
  func cancelAfterConfirmation() async throws {
    let fixture = U6BFixture()
    let custody = fixture.custody()
    let handle = try await custody.beginEnrollment(requestID: fixture.requestID)
    let phrase = try await custody.revealPhrase(for: handle)
    let evidence = try await custody.confirm(handle, phrase: phrase)
    #expect(await custody.cancel(handle) == .cancelled)
    let request = try RecoveryEnrollmentRequest(
      requestID: handle.requestID,
      recoveryRecipient: handle.recoveryRecipient,
      blindConfirmation: evidence
    )
    await #expect(throws: SecretSyncRecoveryError.cancelled) {
      _ = try await custody.stageEnrollment(request)
    }
  }

  @Test("wrong, partial, cancelled, and restarted confirmation fail closed")
  func confirmationFailures() async throws {
    let fixture = U6BFixture()
    let custody = fixture.custody()
    let handle = try await custody.beginEnrollment(requestID: fixture.requestID)
    let phrase = try await custody.revealPhrase(for: handle)
    await #expect(throws: SecretSyncRecoveryError.invalidConfirmation) {
      _ = try await custody.confirm(handle, phrase: phrase + " abandon")
    }
    #expect(await custody.cancel(handle) == .cancelled)
    await #expect(throws: SecretSyncRecoveryError.cancelled) {
      _ = try await custody.confirm(handle, phrase: phrase)
    }

    let live = fixture.custody(offset: 10)
    let liveHandle = try await live.beginEnrollment(requestID: fixture.requestID)
    let livePhrase = try await live.revealPhrase(for: liveHandle)
    let evidence = try await live.confirm(liveHandle, phrase: livePhrase)
    let restarted = fixture.custody(offset: 20)
    let request = try RecoveryEnrollmentRequest(
      requestID: liveHandle.requestID,
      recoveryRecipient: liveHandle.recoveryRecipient,
      blindConfirmation: evidence
    )
    await #expect(throws: SecretSyncRecoveryError.missingCeremony) {
      _ = try await restarted.stageEnrollment(request)
    }
  }

  @Test("confirmation evidence is the exact four-field public frame")
  func publicEvidenceFrame() async throws {
    let fixture = U6BFixture()
    let custody = fixture.custody()
    let handle = try await custody.beginEnrollment(requestID: fixture.requestID)
    let phrase = try await custody.revealPhrase(for: handle)
    let evidence = try await custody.confirm(handle, phrase: phrase)
    let fields = try SecretSyncRecoveryFrame.decode(evidence.evidenceBytes)
    #expect(fields.map(\.tag) == [1, 2, 3, 4])
    #expect(
      String(data: fields[0].value, encoding: .utf8)
        == "mootx01.secret-recovery.confirmation-evidence.v1"
    )
    #expect(fields[1].value == SecretSyncRecoveryFrame.uuid(handle.sessionID))
    #expect(fields[2].value == SecretSyncRecoveryFrame.uuid(handle.tokenID))
    #expect(fields[3].value.count == 32)
    #expect(evidence.evidenceBytes.range(of: phrase.data(using: .utf8)!) == nil)
  }
}

struct U6BFixture: Sendable {
  let requestID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
  let scopeID = SecretScopeID(
    UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
  )
  let currentGenerationID = SecretGenerationID(
    UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
  )
  let replacementGenerationID = SecretGenerationID(
    UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
  )
  let freshness: SecretBootstrapFreshnessCommitment

  init() {
    freshness = try! SecretBootstrapFreshnessCommitment(
      scopeID: scopeID,
      latestPolicyEpoch: 9,
      headCommitDigest: SecretRecordDigest(bytes: Data(repeating: 0x11, count: 32)),
      policyDigest: SecretRecordDigest(bytes: Data(repeating: 0x22, count: 32))
    )
  }

  func custody(
    offset: Int = 0,
    failOutput: Bool = false
  ) -> SecretSyncRecoveryKeyCustody {
    let inputs = U6BDeterministicInputs(offset: offset)
    let builder: SecretSyncRecoveryKeyCustody.EvidenceBuilder
    if failOutput {
      builder = { _, _, _, _, _ in
        throw SecretSyncRecoveryError.outputFailure
      }
    } else {
      builder = { operation, requestID, descriptor, commitment, signature in
        try SecretSyncRecoveryKeyCustody.defaultOperationEvidence(
          operation: operation,
          requestID: requestID,
          descriptor: descriptor,
          commitment: commitment,
          signature: signature
        )
      }
    }
    return SecretSyncRecoveryKeyCustody(
      entropySource: inputs.entropy,
      uuidSource: inputs.uuid,
      operationEvidenceBuilder: builder
    )
  }
}

final class U6BDeterministicInputs: @unchecked Sendable {
  private let lock = NSLock()
  private var entropyCounter: UInt8
  private var uuidCounter: UInt64

  init(offset: Int) {
    entropyCounter = UInt8(offset & 0xff)
    uuidCounter = UInt64(offset + 1)
  }

  func entropy() throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    let start = entropyCounter
    entropyCounter &+= 1
    return Data((0..<32).map { start &+ UInt8($0) })
  }

  func uuid() -> UUID {
    lock.lock()
    defer { lock.unlock() }
    var bytes = [UInt8](repeating: 0, count: 16)
    var counter = uuidCounter.bigEndian
    withUnsafeBytes(of: &counter) {
      bytes.replaceSubrange(8..<16, with: $0)
    }
    uuidCounter += 1
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3],
      bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11],
      bytes[12], bytes[13], bytes[14], bytes[15]
    ))
  }
}

struct U6BFreshnessAnchor: ExternalBootstrapFreshnessAnchor {
  let commitment: SecretBootstrapFreshnessCommitment

  func latestCommitment(
    for scopeID: SecretScopeID
  ) async throws -> SecretBootstrapFreshnessCommitment {
    commitment
  }
}

func u6Hex(_ value: String) -> Data {
  Data(stride(from: 0, to: value.count, by: 2).map { offset in
    let start = value.index(value.startIndex, offsetBy: offset)
    let end = value.index(start, offsetBy: 2)
    return UInt8(value[start..<end], radix: 16)!
  })
}
