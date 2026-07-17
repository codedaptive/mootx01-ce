// CKErrorTaxonomyTests.swift
//
// Verifies that CKErrorClass.classify correctly assigns each CKError code
// to the expected transport-response posture (CVK-ICLOUD P1-M6 R6).
//
// Tests drive classify() with Foundation NSError bridging (CKError.Code has
// an Int raw value; NSError with the matching code bridges as CKError).
// This avoids constructing undocumented CKError internals while exercising
// the production classification path.

import Testing
import Foundation
import CloudKit
@testable import ConvergenceKitCloudKit

// MARK: - Helper

private func ckError(code: CKError.Code, userInfo: [String: Any] = [:]) -> Error {
    return CKError(code, userInfo: userInfo)
}

// MARK: - Taxonomy classification table tests

@Suite("CKErrorTaxonomy classification")
struct CKErrorTaxonomyTests {

    // MARK: retryableBackoff

    @Test("requestRateLimited → retryableBackoff with retryAfterSeconds honoured")
    func requestRateLimited_retryAfterHonoured() {
        let error = CKError(.requestRateLimited,
                            userInfo: [CKErrorRetryAfterKey: NSNumber(value: 42.0)])
        let cls = CKErrorClass.classify(error)
        #expect(cls == .retryableBackoff(retryAfter: 42.0))
    }

    @Test("requestRateLimited without retryAfterSeconds → retryableBackoff(retryAfter: nil)")
    func requestRateLimited_noRetryAfter() {
        let error = CKError(.requestRateLimited)
        let cls = CKErrorClass.classify(error)
        // suggestedDelay will be nil when the key is absent
        #expect(cls == .retryableBackoff(retryAfter: nil))
    }

    @Test("serviceUnavailable → retryableBackoff")
    func serviceUnavailable() {
        #expect(CKErrorClass.classify(ckError(code: .serviceUnavailable))
                == .retryableBackoff(retryAfter: nil))
    }

    @Test("networkUnavailable → retryableBackoff")
    func networkUnavailable() {
        #expect(CKErrorClass.classify(ckError(code: .networkUnavailable))
                == .retryableBackoff(retryAfter: nil))
    }

    @Test("networkFailure → retryableBackoff")
    func networkFailure() {
        #expect(CKErrorClass.classify(ckError(code: .networkFailure))
                == .retryableBackoff(retryAfter: nil))
    }

    @Test("serverResponseLost → retryableBackoff")
    func serverResponseLost() {
        #expect(CKErrorClass.classify(ckError(code: .serverResponseLost))
                == .retryableBackoff(retryAfter: nil))
    }

    @Test("zoneBusy → retryableBackoff")
    func zoneBusy() {
        #expect(CKErrorClass.classify(ckError(code: .zoneBusy))
                == .retryableBackoff(retryAfter: nil))
    }

    @Test("permissionFailure → retryableBackoff")
    func permissionFailure() {
        #expect(CKErrorClass.classify(ckError(code: .permissionFailure))
                == .retryableBackoff(retryAfter: nil))
    }

    @Test("notAuthenticated → retryableBackoff")
    func notAuthenticated() {
        #expect(CKErrorClass.classify(ckError(code: .notAuthenticated))
                == .retryableBackoff(retryAfter: nil))
    }

    @Test("internalError → retryableBackoff")
    func internalError() {
        #expect(CKErrorClass.classify(ckError(code: .internalError))
                == .retryableBackoff(retryAfter: nil))
    }

    @Test("operationCancelled → retryableBackoff")
    func operationCancelled() {
        #expect(CKErrorClass.classify(ckError(code: .operationCancelled))
                == .retryableBackoff(retryAfter: nil))
    }

    @Test("non-CKError (URLError) → retryableBackoff")
    func nonCKError() {
        let urlError = URLError(.notConnectedToInternet)
        #expect(CKErrorClass.classify(urlError)
                == .retryableBackoff(retryAfter: nil))
    }

    // MARK: reclaim

    @Test("zoneNotFound → reclaim(.zoneNotFound)")
    func zoneNotFound() {
        #expect(CKErrorClass.classify(ckError(code: .zoneNotFound))
                == .reclaim(.zoneNotFound))
    }

    @Test("userDeletedZone → reclaim(.zoneNotFound)")
    func userDeletedZone() {
        #expect(CKErrorClass.classify(ckError(code: .userDeletedZone))
                == .reclaim(.zoneNotFound))
    }

    @Test("changeTokenExpired → reclaim(.changeTokenExpired)")
    func changeTokenExpired() {
        #expect(CKErrorClass.classify(ckError(code: .changeTokenExpired))
                == .reclaim(.changeTokenExpired))
    }

    // MARK: conflict

    @Test("serverRecordChanged → conflict")
    func serverRecordChanged() {
        #expect(CKErrorClass.classify(ckError(code: .serverRecordChanged))
                == .conflict)
    }

    // MARK: permanent

    @Test("quotaExceeded → permanent(.quotaExceeded)")
    func quotaExceeded() {
        #expect(CKErrorClass.classify(ckError(code: .quotaExceeded))
                == .permanent(.quotaExceeded))
    }

    @Test("limitExceeded → permanent(.recordSizeLimitExceeded)")
    func limitExceeded() {
        #expect(CKErrorClass.classify(ckError(code: .limitExceeded))
                == .permanent(.recordSizeLimitExceeded))
    }

    @Test("badContainer → permanent(.other(.badContainer))")
    func badContainer() {
        #expect(CKErrorClass.classify(ckError(code: .badContainer))
                == .permanent(.other(.badContainer)))
    }

    @Test("invalidArguments → permanent(.other(.invalidArguments))")
    func invalidArguments() {
        #expect(CKErrorClass.classify(ckError(code: .invalidArguments))
                == .permanent(.other(.invalidArguments)))
    }

    @Test("missingEntitlement → permanent(.other(.missingEntitlement))")
    func missingEntitlement() {
        #expect(CKErrorClass.classify(ckError(code: .missingEntitlement))
                == .permanent(.other(.missingEntitlement)))
    }
}
