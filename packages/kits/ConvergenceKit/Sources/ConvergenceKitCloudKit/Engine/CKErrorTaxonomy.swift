// CKErrorTaxonomy.swift
//
// Classifies CKError codes into four transport-response postures for the
// per-record push result handler (PushResults.swift, CVK-ICLOUD P1-M6 R6).
//
// WHY ONE CLASSIFICATION TABLE:
// Per-record errors from modifyRecords(atomically: false) need to be mapped
// to actions (confirm, retry, park, reclaim) in a single, auditable place.
// Spreading the logic across PushCycle or PushResults would make it hard to
// verify completeness and to update when CloudKit adds new error codes.
//
// CLASSIFICATION POSTURES:
//   retryableBackoff — transient error; honour retryAfterSeconds if present
//   reclaim          — zone or token invalid; re-establish before retrying
//   conflict         — serverRecordChanged; pull resolves via LWW before retry
//   permanent        — quota or size exceeded; park entry, stop retrying

import CloudKit
import Foundation

// MARK: - CKErrorClass

/// The four transport-response postures for a per-record CKError.
///
/// Used by PushResults.process to decide what to do with each failed entry:
///   .retryableBackoff → increment retry_count, leave in outbox
///   .reclaim          → increment retry_count, surface reclaim kind to caller
///   .conflict         → increment retry_count, pull cycle resolves via LWW
///   .permanent        → set is_parked = 1, exclude from future push batches
public enum CKErrorClass: Equatable {
    /// Rate-limit or transient network error. Back off before retrying.
    /// `retryAfter` is the server-suggested minimum delay from
    /// `CKError.retryAfterSeconds`; nil means use the exponential backoff schedule.
    case retryableBackoff(retryAfter: TimeInterval?)

    /// Zone or change token invalid. The reclaim action must be completed
    /// before any records can be re-pushed.
    case reclaim(ReclaimKind)

    /// The server holds a newer version of this record (CKError.serverRecordChanged).
    /// The entry stays in the outbox with an incremented retry_count. The next
    /// pull cycle applies the winning server version under LWW; the outbox entry
    /// either becomes stale (server won) or remains live for the next push
    /// (local won). No action required beyond the retry count increment.
    case conflict

    /// Unrecoverable per-record failure. No amount of retrying will push this
    /// entry in its current form. Park it (is_parked = 1) and exclude from
    /// future push batches; surface via OutboxStore.parkedEntries for diagnostics.
    case permanent(PermanentReason)
}

/// Variant within the `reclaim` posture.
public enum ReclaimKind: Equatable, Sendable {
    /// The CloudKit zone was deleted (zoneNotFound) or the user deleted it
    /// (userDeletedZone). The engine must re-create the zone before re-pushing.
    case zoneNotFound

    /// The server change token has been invalidated (zone history truncated or
    /// token too old). The engine must clear the persisted token and perform a
    /// full re-pull before re-pushing. Coordinate with PullCycle.swift's
    /// changeTokenExpired handler — do not duplicate the reset logic; raise this
    /// reclaim kind and let the caller (PushCycle) drive the recovery path.
    case changeTokenExpired
}

/// Variant within the `permanent` posture.
public enum PermanentReason: Equatable {
    /// iCloud storage quota exceeded. The user must free storage before any new
    /// records can be pushed. The host app should surface a user-visible warning.
    case quotaExceeded

    /// The record exceeds CloudKit's per-record size limit (~1 MB). The payload
    /// must be reduced (via column projection or splitting) before it can be pushed.
    case recordSizeLimitExceeded

    /// Another per-record error code that is known to be permanent for this entry.
    /// Parking prevents infinite retry loops on programming errors or configuration
    /// problems that no number of retries will fix.
    case other(CKError.Code)
}

// MARK: - Classification

public extension CKErrorClass {

    /// Classify any `Error` into a transport-response posture.
    ///
    /// Non-CKError types (e.g. URLError) are treated as transient network failures
    /// and classified `.retryableBackoff(retryAfter: nil)`.
    static func classify(_ error: Error) -> CKErrorClass {
        guard let ckError = error as? CKError else {
            // Non-CKError: treat as transient network failure, apply backoff.
            return .retryableBackoff(retryAfter: nil)
        }
        return classify(ckError)
    }

    /// Classify a `CKError` into a transport-response posture.
    ///
    /// Exhaustive over all known `CKError.Code` values. Each case carries a
    /// WHY comment explaining the classification choice. `@unknown default` catches
    /// codes added in future OS SDK versions without breaking existing installations.
    static func classify(_ ckError: CKError) -> CKErrorClass {
        // Extract the server-suggested minimum wait, if any. CloudKit sets this on
        // .requestRateLimited; honour it precisely to avoid thundering-herd storms.
        let suggestedDelay: TimeInterval? = ckError.retryAfterSeconds

        switch ckError.code {

        // ── retryableBackoff ──────────────────────────────────────────────────
        // WHY: These codes represent transient states the server expects to resolve
        // on its own. Retrying without delay (except where a suggested delay is
        // provided) will produce the same outcome.

        case .requestRateLimited:
            // WHY: Server is rate-limiting this client. retryAfterSeconds is set and
            // must be honoured to avoid being blocked further.
            return .retryableBackoff(retryAfter: suggestedDelay)

        case .serviceUnavailable:
            // WHY: CloudKit temporarily unavailable (maintenance or outage).
            return .retryableBackoff(retryAfter: suggestedDelay)

        case .networkUnavailable, .networkFailure:
            // WHY: Device is offline or the network call failed. Retry when
            // connectivity is restored; no server-suggested delay.
            return .retryableBackoff(retryAfter: nil)

        case .serverResponseLost:
            // WHY: The network request was sent but the response was lost. The
            // record may or may not have been saved; retrying with savePolicy
            // .changedKeys is idempotent so this is safe.
            return .retryableBackoff(retryAfter: nil)

        case .zoneBusy:
            // WHY: The target zone is temporarily busy. Back off.
            return .retryableBackoff(retryAfter: suggestedDelay)

        case .permissionFailure, .notAuthenticated:
            // WHY: User is not signed in or has revoked permission. Retryable
            // when the user signs back in; no server-suggested delay.
            return .retryableBackoff(retryAfter: nil)

        case .unknownItem:
            // WHY: The record does not exist on the server. savePolicy .changedKeys
            // should create it on the next attempt; treat as transient.
            return .retryableBackoff(retryAfter: nil)

        case .internalError:
            // WHY: CloudKit internal error. Treat as transient; back off and retry.
            return .retryableBackoff(retryAfter: nil)

        case .partialFailure:
            // WHY: Should not appear on a per-record result (it wraps the per-record
            // dict on the outer call). If it leaks here, treat as transient.
            return .retryableBackoff(retryAfter: nil)

        case .serverRejectedRequest:
            // WHY: Generic server rejection not covered by a more specific code.
            // Treat as transient; the server may accept on a subsequent attempt.
            return .retryableBackoff(retryAfter: nil)

        case .operationCancelled:
            // WHY: The operation was cancelled by the caller (e.g. app backgrounded).
            // The entry is still valid; retry on the next push cycle.
            return .retryableBackoff(retryAfter: nil)

        case .assetFileNotFound, .assetFileModified:
            // WHY: Asset upload problems. The asset may have been modified locally;
            // a subsequent observe-and-push cycle should resolve it.
            return .retryableBackoff(retryAfter: nil)

        case .participantMayNeedVerification:
            // WHY: Sharing workflow issue. Not applicable to private-zone push but
            // treat as transient to avoid permanently parking the entry.
            return .retryableBackoff(retryAfter: nil)

        case .managedAccountRestricted, .accountTemporarilyUnavailable:
            // WHY: Account-level access issue. Transient; resolved by account state change.
            return .retryableBackoff(retryAfter: nil)

        case .resultsTruncated:
            // WHY: Not a push error. Treat as transient.
            return .retryableBackoff(retryAfter: nil)

        // ── reclaim ───────────────────────────────────────────────────────────
        // WHY: These errors indicate a required precondition (zone existence or
        // token validity) has been lost. Retrying without re-establishing the
        // precondition loops forever at the same error.

        case .zoneNotFound, .userDeletedZone:
            // WHY: The target private zone was deleted. Re-create it via
            // modifyRecordZones before the next push attempt.
            return .reclaim(.zoneNotFound)

        case .changeTokenExpired:
            // WHY: The server has invalidated our change token (zone history truncated
            // or token too old). Clear the persisted token and re-pull from scratch.
            // Coordinated with PullCycle.swift's changeTokenExpired handler.
            return .reclaim(.changeTokenExpired)

        // ── conflict ──────────────────────────────────────────────────────────
        // WHY: The server holds a newer version of this record. We cannot push
        // our version without first reconciling. The pull cycle's LWW gate handles
        // the reconciliation; the outbox entry either becomes stale or stays live.

        case .serverRecordChanged:
            // WHY: Server version is newer than our CKRecord's base anchor. Increment
            // retry_count; pull cycle resolves via LWW on the next pull attempt.
            return .conflict

        // ── permanent ─────────────────────────────────────────────────────────
        // WHY: These errors indicate the record cannot be pushed in its current
        // form regardless of the number of retries. Parking the entry prevents
        // wasting push cycles and delaying other entries.

        case .quotaExceeded:
            // WHY: User's iCloud storage is full. No amount of retrying helps
            // until the user frees space. Surface via diagnostics.
            return .permanent(.quotaExceeded)

        case .limitExceeded:
            // WHY: Record exceeds CloudKit's per-record size limit (~1 MB).
            // Must reduce the payload (column projection, splitting) before pushing.
            return .permanent(.recordSizeLimitExceeded)

        case .badContainer, .badDatabase, .invalidArguments:
            // WHY: Programming / configuration error in the caller. Park so the
            // developer sees these in diagnostics without infinite retry loops.
            return .permanent(.other(ckError.code))

        case .constraintViolation:
            // WHY: Unique constraint violation. Permanent without a schema change.
            return .permanent(.other(ckError.code))

        case .incompatibleVersion:
            // WHY: App schema version mismatch with server. Park until migrated.
            return .permanent(.other(ckError.code))

        case .missingEntitlement:
            // WHY: CloudKit entitlement missing from the app bundle. Configuration
            // error; no retry will fix it.
            return .permanent(.other(ckError.code))

        case .alreadyShared, .tooManyParticipants, .referenceViolation:
            // WHY: Sharing / collaboration constraints. Not applicable to the private
            // database push path but classified for completeness. Park to avoid loops.
            return .permanent(.other(ckError.code))

        @unknown default:
            // WHY: A CKError code added in a future OS SDK. Treat as retryable to
            // avoid permanently parking entries for errors we do not yet understand.
            // This case exists specifically to remain open to future CloudKit additions
            // without breaking existing installations.
            return .retryableBackoff(retryAfter: nil)
        }
    }
}
