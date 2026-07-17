// FaultInjector.swift
//
// Scripted fault-injection actor for convergence harness tests (CVK-ICLOUD P4-M1/P4-M2).
// Faults are queued per operation target and dequeued one-at-a-time. The queue
// is deterministic: tests enqueue a known sequence before running the operation
// under test, so there is no randomness. Each dequeued fault triggers exactly
// once; subsequent calls to the same target proceed normally once the queue is empty.
//
// FaultInjector is held by CloudZoneFake as an optional property. When non-nil,
// CloudZoneFake checks for queued faults at the start of each protocol method.
//
// Usage in tests:
//   let injector = FaultInjector()
//   await cloudZone.faults = injector   // (assign via actor method, not direct property)
//   await injector.enqueue(.networkError(detail: "timeout"), for: .modifyRecords)
//   // Next call to cloudZone.modifyRecords throws a network error; subsequent calls pass.
//
// Supported fault scripts:
//   .networkError(detail:)        — throws a generic network-unavailable CKError
//   .rateLimitError               — throws CKError.Code.requestRateLimited
//   .changeTokenExpired           — throws CKError.Code.changeTokenExpired (pull path recovery)
//   .serverRecordChanged          — throws CKError.Code.serverRecordChanged (CAS conflict)
//   .partialBatchFailure(count:)  — lets all records through but marks the first `count`
//                                   as per-record network failures in the saveResults dict.
//                                   The call itself does NOT throw; per-record errors are
//                                   surfaced in the result dictionary so PushResults.process
//                                   can classify them and increment retry_count on affected
//                                   outbox entries. Subsequent records in the same batch succeed.

import Foundation
import CloudKit

// MARK: - FaultScript

/// A scripted fault to inject into a CloudKitDatabaseProtocol operation.
enum FaultScript: Sendable {

    /// Generic network error (timeout, unavailable). Maps to CKError.networkUnavailable.
    /// Causes the entire modifyRecords / fetch / fetchZoneChanges call to throw.
    case networkError(detail: String)

    /// Server-side rate limit. Maps to CKError.requestRateLimited.
    case rateLimitError

    /// Persisted change token is stale. Maps to CKError.changeTokenExpired.
    /// Pull path recovers by clearing the token and re-pulling from scratch.
    case changeTokenExpired

    /// CAS conflict (slot registry or epoch fence). Maps to CKError.serverRecordChanged.
    case serverRecordChanged

    /// Partial batch failure: the modifyRecords call succeeds at the transport level
    /// (does NOT throw) but the first `count` records in the batch are returned as
    /// per-record networkUnavailable failures in the saveResults dictionary.
    ///
    /// WHY per-record rather than whole-batch:
    /// PushResults.process handles the saveResults dict from modifyRecords(atomically:false).
    /// Partial failures are the expected production shape when some records fail and others
    /// succeed in the same batch. This fault lets tests verify that:
    ///   - Failed entries stay in the outbox with incremented retry_count
    ///   - Succeeded entries are confirmed (removed from outbox)
    ///   - A second push drains the remaining failed entries → eventual convergence
    case partialBatchFailure(count: Int)
}

// MARK: - FaultTarget

/// The CloudKitDatabaseProtocol operation to inject a fault into.
enum FaultTarget: Hashable, Sendable {
    case modifyRecords
    case fetch
    case fetchZoneChanges
    case modifyRecordZones
}

// MARK: - FaultInjector

/// Deterministic, queue-based fault injector. Dequeues one fault per call.
actor FaultInjector {

    /// Per-target fault queues. Faults are dequeued FIFO.
    private var queues: [FaultTarget: [FaultScript]] = [:]

    // MARK: - Public API

    /// Enqueue a fault to be triggered on the next call to `target`.
    func enqueue(_ fault: FaultScript, for target: FaultTarget) {
        queues[target, default: []].append(fault)
    }

    /// Dequeue and return the next fault for `target`, or nil if the queue is empty.
    /// Called by CloudZoneFake at the start of each protocol method.
    func nextFault(for target: FaultTarget) -> FaultScript? {
        guard queues[target]?.isEmpty == false else { return nil }
        return queues[target]?.removeFirst()
    }

    /// True when all queues are empty (all scripted faults have been consumed).
    var isEmpty: Bool {
        queues.values.allSatisfy { $0.isEmpty }
    }

    // MARK: - Error factory

    /// Build a CKError from a FaultScript. Static so CloudZoneFake can call it
    /// without needing a FaultInjector reference after dequeuing the fault.
    /// Uses NSError with CKErrorDomain, matching the existing fake pattern in
    /// SlotRegistryTests.FakeCloudKitDatabase.
    ///
    /// .partialBatchFailure is NOT handled here — it does not produce a single
    /// error to throw; instead it produces per-record failures in the saveResults
    /// dictionary, handled directly in CloudZoneFake.modifyRecords.
    static func makeError(for fault: FaultScript) -> Error {
        let code: CKError.Code
        switch fault {
        case .networkError:
            code = .networkUnavailable
        case .rateLimitError:
            code = .requestRateLimited
        case .changeTokenExpired:
            code = .changeTokenExpired
        case .serverRecordChanged:
            code = .serverRecordChanged
        case .partialBatchFailure:
            // Handled separately in CloudZoneFake.modifyRecords; should not reach here.
            code = .networkUnavailable
        }
        return NSError(domain: CKErrorDomain, code: code.rawValue, userInfo: nil)
    }
}
