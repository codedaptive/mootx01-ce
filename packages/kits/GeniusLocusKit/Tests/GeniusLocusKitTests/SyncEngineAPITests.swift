// SyncEngineAPITests.swift
//
// Parity gate for syncStateDescription (Swift) vs format_sync_state_token (Rust).
//
// These tests lock the canonical vocabulary defined in SyncEngineAPI.swift §Vocabulary.
// Any change to the token format must update BOTH this test and the Rust
// estate_status_sync_tests::syncing_direction_tokens_are_camelcase_matching_swift_rawvalue.
//
// Part 3 of secfix/c-glk-remaining: the Rust port was using {direction:?} (Debug) which
// emits PascalCase ("Bidirectional") while Swift uses \(direction) which emits the
// SyncDirection rawValue ("bidirectional"). This divergence produced different sync
// status tokens per port. Both ports now emit canonical camelCase rawValue tokens.

import Testing
import Foundation
import ConvergenceKit
@testable import GeniusLocusKit

@Suite("SyncEngineAPI canonical token vocabulary (parity gate)")
struct SyncEngineAPITests {

    // MARK: - idle

    @Test("disabled state produces idle token")
    func disabledProducesIdleToken() {
        let token = syncStateDescription(state: .disabled, backendName: "cloudkit")
        #expect(token == "cloudkit (idle)")
    }

    // MARK: - enabled

    @Test("enabled state produces enabled token with zone")
    func enabledProducesEnabledToken() {
        let token = syncStateDescription(state: .enabled(zone: "moot.default", lastPushAt: nil, lastPullAt: nil), backendName: "cloudkit")
        #expect(token == "cloudkit (enabled, zone: moot.default)")
    }

    @Test("federation enabled produces in-process token")
    func federationEnabledProducesInProcessToken() {
        let token = syncStateDescription(state: .enabled(zone: "fed.zone", lastPushAt: nil, lastPullAt: nil), backendName: "federation")
        #expect(token == "federation (in-process, zone: fed.zone)")
    }

    // MARK: - syncing direction (Part 3 regression gate)
    //
    // SyncDirection is a String raw-value enum. Swift's string interpolation
    // calls CustomStringConvertible → rawValue, giving camelCase: "bidirectional",
    // "pushOnly", "pullOnly". The Rust port was emitting PascalCase Debug variants.
    // These tests lock the canonical camelCase form.

    @Test("syncing bidirectional produces camelCase direction token")
    func syncingBidirectionalIsCamelCase() {
        let token = syncStateDescription(state: .syncing(direction: .bidirectional), backendName: "cloudkit")
        // Must be "bidirectional" (rawValue), NOT "Bidirectional" (PascalCase Debug)
        #expect(token == "cloudkit (syncing, direction: bidirectional)")
        #expect(!token.contains("Bidirectional"), "Direction must be camelCase rawValue, not PascalCase Debug")
    }

    @Test("syncing pushOnly produces camelCase direction token")
    func syncingPushOnlyIsCamelCase() {
        let token = syncStateDescription(state: .syncing(direction: .pushOnly), backendName: "cloudkit")
        // Must be "pushOnly" (rawValue), NOT "PushOnly" (PascalCase)
        #expect(token == "cloudkit (syncing, direction: pushOnly)")
        #expect(!token.contains("PushOnly"), "Direction must be camelCase rawValue, not PascalCase")
    }

    @Test("syncing pullOnly produces camelCase direction token")
    func syncingPullOnlyIsCamelCase() {
        let token = syncStateDescription(state: .syncing(direction: .pullOnly), backendName: "cloudkit")
        // Must be "pullOnly" (rawValue), NOT "PullOnly" (PascalCase)
        #expect(token == "cloudkit (syncing, direction: pullOnly)")
        #expect(!token.contains("PullOnly"), "Direction must be camelCase rawValue, not PascalCase")
    }

    // MARK: - error

    @Test("error state produces error token")
    func errorStateProducesErrorToken() {
        let err = SyncError.notEnabled
        let token = syncStateDescription(state: .error(err, retryAt: nil), backendName: "cloudkit")
        #expect(token.hasPrefix("cloudkit (error:"), "Error token must begin with 'cloudkit (error:'")
    }

    // MARK: - no fabricated tokens

    @Test("connected literal must never appear in any sync token")
    func connectedLiteralNeverAppears() {
        let states: [SyncState] = [
            .disabled,
            .enabled(zone: "z", lastPushAt: nil, lastPullAt: nil),
            .syncing(direction: .bidirectional),
            .syncing(direction: .pushOnly),
            .syncing(direction: .pullOnly),
            .error(.notEnabled, retryAt: nil),
        ]
        for state in states {
            let token = syncStateDescription(state: state, backendName: "cloudkit")
            #expect(!token.contains("connected"),
                    "Token 'connected' must never appear in canonical vocabulary; got: \(token)")
        }
    }
}
