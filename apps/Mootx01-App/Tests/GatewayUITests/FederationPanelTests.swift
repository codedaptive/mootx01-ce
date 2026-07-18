// FederationPanelTests.swift
//
// FED-OD-6: Tests for the Federation panel's state machine and F1 invariants.
//
// Tests exercise FederationController and FederationPosture directly — no
// UI rendering required. Covers:
//   - Discovery visibility defaults to off
//   - Balanced is the only functional posture in F1
//   - Sealed absent by construction (no-secret invariant)
//   - startSession throws for locked postures (never silent stubs)
//   - startSession succeeds with Balanced
//   - Localized-string fields are non-empty
//
// FederationController is @MainActor @Observable. Tests run on MainActor via
// @Suite attribute to avoid async actor-hop noise on property access.

import Testing
import Foundation
@testable import GatewayUI
import ConvergenceKitFederation

// .serialized: FederationController reads/writes UserDefaults; parallel runs
// would interleave suite isolation and defaults state.
@Suite("FederationPanel — state transitions and F1 invariants (FED-OD-6)", .serialized)
@MainActor
struct FederationPanelTests {

    // MARK: - Visibility defaults

    @Test("discovery visibility defaults to off on first launch")
    func visibilityDefaultsToOff() throws {
        let d = try #require(UserDefaults(suiteName: "fed-od6-visibility-test"))
        d.removePersistentDomain(forName: "fed-od6-visibility-test")
        // The key is absent → DiscoveryVisibilityPolicy returns .off.
        // AirDrop-style default-closed design (decision §1).
        let visibility = DiscoveryVisibilityPolicy.visibility(defaults: d)
        #expect(visibility == .off)
        d.removePersistentDomain(forName: "fed-od6-visibility-test")
    }

    @Test("visibility round-trips through UserDefaults")
    func visibilityRoundTrips() throws {
        let d = try #require(UserDefaults(suiteName: "fed-od6-visibility-rt"))
        d.removePersistentDomain(forName: "fed-od6-visibility-rt")

        DiscoveryVisibilityPolicy.setVisibility(.whileOpen, defaults: d)
        #expect(DiscoveryVisibilityPolicy.visibility(defaults: d) == .whileOpen)

        DiscoveryVisibilityPolicy.setVisibility(.always, defaults: d)
        #expect(DiscoveryVisibilityPolicy.visibility(defaults: d) == .always)

        DiscoveryVisibilityPolicy.setVisibility(.off, defaults: d)
        #expect(DiscoveryVisibilityPolicy.visibility(defaults: d) == .off)

        d.removePersistentDomain(forName: "fed-od6-visibility-rt")
    }

    // MARK: - Posture: Balanced is functional in F1

    @Test("balanced posture is functional in F1")
    func balancedIsFunctionalInF1() {
        // Only Balanced should start an actual session in F1.
        #expect(FederationPosture.balanced.isFunctionalInF1 == true)
    }

    @Test("non-balanced postures are all locked in F1")
    func nonBalancedPosturesAreLockedInF1() {
        let locked = FederationPosture.allCases.filter { !$0.isFunctionalInF1 }
        // Exactly 4 locked postures at F1: Open, Convenient, Locked, In-person.
        #expect(locked.count == 4)
        for posture in locked {
            #expect(posture != .balanced)
        }
    }

    // MARK: - No secret in any enumeration

    @Test("Sealed is absent from FederationPosture.allCases (secret has no UI)")
    func sealedAbsentFromPostureEnumeration() {
        // Sealed's data class = secret; sharing model mandates no key is minted.
        // No UI control ever offers a secret row — Sealed is absent by construction.
        let rawValues = FederationPosture.allCases.map(\.rawValue)
        #expect(!rawValues.contains("Sealed"))
        // 5 postures: Open, Convenient, Balanced, Locked, In-person.
        #expect(FederationPosture.allCases.count == 5)
    }

    @Test("no posture card description mentions 'secret'")
    func noPostureDescriptionMentionsSecret() {
        for posture in FederationPosture.allCases {
            #expect(!posture.cardWhatCrosses.lowercased().contains("secret"),
                    "cardWhatCrosses for \(posture.rawValue) must not mention secret")
            #expect(!posture.cardLifetime.lowercased().contains("secret"),
                    "cardLifetime for \(posture.rawValue) must not mention secret")
        }
    }

    // MARK: - StartSession gate

    @Test("startSession throws for all locked postures — never silently no-ops")
    func startSessionThrowsForLockedPostures() async throws {
        let controller = FederationController()
        let peer = KnownPeer(id: "aabbccddeeff0011", displayName: "Test Peer")

        for posture in FederationPosture.allCases where !posture.isFunctionalInF1 {
            do {
                try await controller.startSession(peer: peer, posture: posture)
                Issue.record("startSession with \(posture.rawValue) should have thrown")
            } catch FederationSessionError.postureNotFunctionalInF1(let p) {
                #expect(p == posture)
            } catch {
                Issue.record("Unexpected error for \(posture.rawValue): \(error)")
            }
        }
        // No session left active after all locked attempts.
        #expect(controller.activeSession == nil)
    }

    @Test("startSession succeeds with Balanced posture")
    func startSessionSucceedsWithBalanced() async throws {
        let controller = FederationController()
        let peer = KnownPeer(id: "11223344aabbccdd", displayName: "Alice")

        try await controller.startSession(peer: peer, posture: .balanced)

        #expect(controller.activeSession != nil)
        #expect(controller.activeSession?.posture == .balanced)
        #expect(controller.activeSession?.peer.id == peer.id)

        await controller.endSession()
        #expect(controller.activeSession == nil)
    }

    @Test("startSession throws sessionAlreadyActive when a session is in progress")
    func startSessionThrowsWhenAlreadyActive() async throws {
        let controller = FederationController()
        let peer = KnownPeer(id: "deadbeefdeadbeef", displayName: "Bob")

        try await controller.startSession(peer: peer, posture: .balanced)

        do {
            try await controller.startSession(peer: peer, posture: .balanced)
            Issue.record("Second startSession should have thrown sessionAlreadyActive")
        } catch FederationSessionError.sessionAlreadyActive {
            // Expected — the session is still active.
        }

        await controller.endSession()
    }

    // MARK: - Localized-string presence

    @Test("all posture card text fields are non-empty")
    func postureCardTextFieldsNonEmpty() {
        for posture in FederationPosture.allCases {
            #expect(!posture.cardTitle.isEmpty,
                    "cardTitle empty for \(posture.rawValue)")
            #expect(!posture.cardWhatCrosses.isEmpty,
                    "cardWhatCrosses empty for \(posture.rawValue)")
            #expect(!posture.cardLifetime.isEmpty,
                    "cardLifetime empty for \(posture.rawValue)")
            #expect(!posture.cardAtEnd.isEmpty,
                    "cardAtEnd empty for \(posture.rawValue)")
        }
    }

    @Test("posture raw values are stable (no key drift)")
    func postureRawValuesStable() {
        #expect(FederationPosture.balanced.rawValue == "Balanced")
        #expect(FederationPosture.open.rawValue == "Open")
        #expect(FederationPosture.convenient.rawValue == "Convenient")
        #expect(FederationPosture.locked.rawValue == "Locked")
        #expect(FederationPosture.inPerson.rawValue == "In-person")
    }

    // MARK: - Session lifecycle

    @Test("endSession updates lastSession timestamp on the known peer")
    func endSessionUpdatesLastSessionTimestamp() async throws {
        let controller = FederationController()
        let peer = KnownPeer(id: "cafebabe12345678", displayName: "Eve")
        controller.addKnownPeerForTesting(peer)

        try await controller.startSession(peer: peer, posture: .balanced)
        await controller.endSession()

        let updated = controller.knownPeers.first { $0.id == peer.id }
        #expect(updated?.lastSession != nil,
                "lastSession must be set after a completed session")

        controller.removeKnownPeerForTesting(peer)
    }
}
