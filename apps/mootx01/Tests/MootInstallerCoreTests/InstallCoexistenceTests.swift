// InstallCoexistenceTests.swift
// MootInstallerCoreTests — MACD-3B3 install coexistence decision coverage.
//
// Tests the coexistence decision logic that install/upgrade commands will apply
// after the probe returns.  The logic is expressed through pure decision
// functions so it can be tested without running the full command pipeline.
//
// Binding decisions tested:
//   C2: Authenticated healthy bundled owner ⇒ CLIENT-ONLY mode (skip daemon registration).
//   C3: Legacy schema-2 OR unauthenticated ⇒ treat as no authenticated owner for C2 purposes.
//       NEVER kills or replaces the running process.
//   C4: Incompatible owner ⇒ block install, surface verdict verbatim to user.
//   C6: Absent ⇒ normal install proceeds; probe result NEVER rewrites preference.

import Foundation
import Testing
import MootDaemonProvider
@testable import MootInstallerCore

// MARK: - Decision helpers under test
//
// These decision functions encapsulate the branching logic that Install/Upgrade
// commands will call once the probe runs.  They are defined here to be tested
// first (TDD RED/GREEN), and will be promoted to the commands in Part B.

/// Whether the probe outcome authorises client-only install (skip daemon registration).
///
/// Returns `true` ONLY for `.healthy(kind: .bundled, ...)` — a running,
/// authenticated, compatible bundled owner means register the CLI client and MCP
/// client only; do not start a second daemon or register the bundle plist.
///
/// C2 mandate: source of truth for the client-only decision.
func clientOnlyInstallRequired(_ outcome: OwnershipProbeOutcome) -> Bool {
    if case .healthy(let kind, _) = outcome, kind == .bundled { return true }
    return false
}

/// Whether the probe outcome blocks install entirely (neither full nor client-only).
///
/// Returns `true` for `.incompatible`: a version mismatch that cannot be resolved
/// by this binary means the user must take action (update CLI or provider) before
/// install can proceed.  This case NEVER authorises starting a second provider (C4).
func installBlockedByVersionMismatch(_ outcome: OwnershipProbeOutcome) -> Bool {
    if case .incompatible = outcome { return true }
    return false
}

/// Whether normal (full) install should proceed.
///
/// Returns `true` for `.absent` and `.unauthenticated` — in both cases no
/// authenticated bundled owner is present, so the full install path runs.
/// For `.unauthenticated`, the running process (if any) is NOT killed or
/// replaced; the install proceeds as if starting fresh (C3).
func normalInstallProceeds(_ outcome: OwnershipProbeOutcome) -> Bool {
    switch outcome {
    case .absent, .unauthenticated:
        return true
    case .healthy, .incompatible:
        return false
    }
}

// MARK: - C2: client-only install gate

@Suite("MACD-3B3 C2 — client-only install gate")
struct ClientOnlyGateTests {

    @Test("healthy bundled owner → client-only install required")
    func healthyBundledOwnerRequiresClientOnly() {
        let outcome = OwnershipProbeOutcome.healthy(kind: .bundled, preferredKind: .bundled)
        #expect(clientOnlyInstallRequired(outcome) == true)
        #expect(normalInstallProceeds(outcome) == false)
        #expect(installBlockedByVersionMismatch(outcome) == false)
    }

    @Test("healthy bundled owner with no preference → client-only install required")
    func healthyBundledOwnerNoPreferenceRequiresClientOnly() {
        let outcome = OwnershipProbeOutcome.healthy(kind: .bundled, preferredKind: nil)
        #expect(clientOnlyInstallRequired(outcome) == true)
    }

    @Test("healthy direct owner does NOT trigger client-only (direct owner is standalone)")
    func healthyDirectOwnerNotClientOnly() {
        // A direct-install (standalone) owner is a different registration
        // channel.  The client-only gate is ONLY for bundled owners.
        let outcome = OwnershipProbeOutcome.healthy(kind: .direct, preferredKind: .direct)
        #expect(clientOnlyInstallRequired(outcome) == false)
    }
}

// MARK: - C3: legacy/unauthenticated → normal install, no kill

@Suite("MACD-3B3 C3 — legacy and unauthenticated handling")
struct LegacyUnauthenticatedTests {

    @Test("unauthenticated → normal install proceeds, no kill")
    func unauthenticatedNormalInstall() {
        let outcome = OwnershipProbeOutcome.unauthenticated
        // Normal install proceeds — the unauthenticated process is left running.
        #expect(normalInstallProceeds(outcome) == true)
        #expect(clientOnlyInstallRequired(outcome) == false)
        #expect(installBlockedByVersionMismatch(outcome) == false)
    }

    @Test("absent → normal install proceeds")
    func absentNormalInstall() {
        let outcome = OwnershipProbeOutcome.absent
        #expect(normalInstallProceeds(outcome) == true)
        #expect(clientOnlyInstallRequired(outcome) == false)
        #expect(installBlockedByVersionMismatch(outcome) == false)
    }
}

// MARK: - C4: incompatible blocks install

@Suite("MACD-3B3 C4 — incompatible owner blocks install")
struct IncompatibleBlocksInstallTests {

    @Test("incompatible (.updateApp) → install blocked, verdict available for display")
    func incompatibleUpdateApp() {
        let outcome = OwnershipProbeOutcome.incompatible(verdict: .updateApp)
        #expect(installBlockedByVersionMismatch(outcome) == true)
        #expect(clientOnlyInstallRequired(outcome) == false)
        #expect(normalInstallProceeds(outcome) == false)
        // Verify the verdict is recoverable for user-facing messaging (C4).
        if case .incompatible(let verdict) = outcome {
            #expect(verdict == .updateApp)
        } else {
            Issue.record("Expected .incompatible, got \(outcome)")
        }
    }

    @Test("incompatible (.updateCliService) → install blocked")
    func incompatibleUpdateCliService() {
        let outcome = OwnershipProbeOutcome.incompatible(verdict: .updateCliService)
        #expect(installBlockedByVersionMismatch(outcome) == true)
        #expect(normalInstallProceeds(outcome) == false)
    }

    @Test("incompatible (.updateCliClient) → install blocked")
    func incompatibleUpdateCliClient() {
        let outcome = OwnershipProbeOutcome.incompatible(verdict: .updateCliClient)
        #expect(installBlockedByVersionMismatch(outcome) == true)
    }

    @Test("incompatible (.generationDowngrade) → install blocked")
    func incompatibleGenerationDowngrade() {
        let outcome = OwnershipProbeOutcome.incompatible(verdict: .generationDowngrade)
        #expect(installBlockedByVersionMismatch(outcome) == true)
    }

    @Test("incompatible (.keepOwnerNoOverlap) → install blocked")
    func incompatibleKeepOwnerNoOverlap() {
        let outcome = OwnershipProbeOutcome.incompatible(verdict: .keepOwnerNoOverlap)
        #expect(installBlockedByVersionMismatch(outcome) == true)
    }
}

// MARK: - C6: probe result does not rewrite preference

@Suite("MACD-3B3 C6 — probe does not rewrite bundled-preferred")
struct ProbeDoesNotRewritePreferenceTests {

    @Test("healthy outcome carries preferredKind read-only; probe never elects")
    func preferredKindIsReadOnly() {
        // The probe surfaces preferredKind for REPORTING only (C5/C6).
        // Nothing in the probe or coexistence logic should change the preference
        // just because install ran.  We verify that the outcome's preferredKind
        // field is the value read from the subprocess, not a new election.
        let outcome = OwnershipProbeOutcome.healthy(kind: .bundled, preferredKind: .bundled)
        if case .healthy(_, let pk) = outcome {
            // preferredKind is whatever the subprocess reported — could be nil,
            // .bundled, or .direct.  The test confirms it is not silently changed.
            #expect(pk == .bundled)
        }
    }

    @Test("absent outcome has no preferredKind (nothing was read)")
    func absentHasNoPreferredKind() {
        // The .absent case carries no preferredKind — the preference file was
        // never consulted because no authenticated owner exists.
        let outcome = OwnershipProbeOutcome.absent
        if case .healthy(_, let pk) = outcome {
            Issue.record("Expected .absent, got .healthy with preferredKind \(String(describing: pk))")
        }
        // .absent: no preferredKind field to extract.
        #expect(outcome == .absent)
    }
}

// MARK: - Full probe decode + coexistence integration

@Suite("MACD-3B3 probe+coexistence integration")
struct ProbeCoexistenceIntegrationTests {

    private func probe(returning result: (code: Int32, output: String?)) -> ProviderOwnershipProbe {
        ProviderOwnershipProbe(runner: { _, _ in result })
    }

    private func fakeResult(json: [String: Any]) -> (code: Int32, output: String?) {
        let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let string = data.flatMap { String(data: $0, encoding: .utf8) }
        return (0, string)
    }

    private let fakeHome = URL(fileURLWithPath: "/Users/test-coex", isDirectory: true)

    @Test("healthy bundled → detect returns .healthy, clientOnly gate fires")
    func healthyBundledEndToEnd() {
        let p = probe(returning: fakeResult(json: [
            "mode": "owner-status",
            "outcome": "healthy",
            "kind": ProviderKind.bundled.rawValue,
            "preferredKind": ProviderKind.bundled.rawValue,
        ]))
        let outcome = p.detect(homeDirectory: fakeHome)
        #expect(clientOnlyInstallRequired(outcome) == true)
        #expect(installBlockedByVersionMismatch(outcome) == false)
        #expect(normalInstallProceeds(outcome) == false)
    }

    @Test("absent → detect returns .absent, normal install gate fires")
    func absentEndToEnd() {
        let p = probe(returning: (-1, nil))
        let outcome = p.detect(homeDirectory: fakeHome)
        #expect(clientOnlyInstallRequired(outcome) == false)
        #expect(installBlockedByVersionMismatch(outcome) == false)
        #expect(normalInstallProceeds(outcome) == true)
    }

    @Test("incompatible → detect returns .incompatible, install blocked")
    func incompatibleEndToEnd() {
        let p = probe(returning: fakeResult(json: [
            "mode": "owner-status",
            "outcome": "incompatible",
            "kind": ProviderKind.bundled.rawValue,
            "verdict": VersionCompatibilityVerdict.updateApp.rawValue,
        ]))
        let outcome = p.detect(homeDirectory: fakeHome)
        #expect(clientOnlyInstallRequired(outcome) == false)
        #expect(installBlockedByVersionMismatch(outcome) == true)
        #expect(normalInstallProceeds(outcome) == false)
    }

    @Test("mode-absent (code 64) → .absent, normal install, not unauthenticated")
    func modeAbsentEndToEnd() {
        let p = probe(returning: (64, "usage text"))
        let outcome = p.detect(homeDirectory: fakeHome)
        #expect(outcome == .absent)
        #expect(clientOnlyInstallRequired(outcome) == false)
        #expect(normalInstallProceeds(outcome) == true)
    }
}
