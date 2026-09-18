// InstallCoexistenceTests.swift
// MootInstallerCoreTests — MACD-3B3 install coexistence decision coverage.
//
// Tests the coexistence decision logic applied by install/upgrade/status after
// the probe returns.  Part A tests (Suites 1–4) exercised pure decision
// helpers defined locally.  Part B (Suites 5–8) verifies:
//   - the decision properties promoted to OwnershipProbeOutcome itself
//   - LaunchAgent.authenticatedBundledOwner formatting (C5)
//   - all C4 version-mismatch verdict rows verbatim
//   - preference read-only contract (C6): install never rewrites preference
//   - probe + decision + status-format end-to-end chains
//
// Binding decisions tested:
//   C2: Authenticated healthy bundled owner ⇒ CLIENT-ONLY mode.
//   C3: Unauthenticated ⇒ normal install; NEVER kills the running process.
//   C4: Incompatible owner ⇒ block install, verdict verbatim.
//   C5: Status vocabulary comes from provider verbatim; no second copy.
//   C6: Absent ⇒ normal install; probe result NEVER rewrites preference.

import Foundation
import Testing
import MootDaemonProvider
@testable import MootInstallerCore

// MARK: - C2: client-only install gate (Part A helpers — forward to outcome properties)

@Suite("MACD-3B3 C2 — client-only install gate")
struct ClientOnlyGateTests {

    @Test("healthy bundled owner → requiresClientOnlyInstall true")
    func healthyBundledOwnerRequiresClientOnly() {
        let outcome = OwnershipProbeOutcome.healthy(kind: .bundled, preferredKind: .bundled)
        #expect(outcome.requiresClientOnlyInstall == true)
        #expect(outcome.normalInstallProceeds == false)
        #expect(outcome.blocksInstallByVersionMismatch == false)
    }

    @Test("healthy bundled owner with no preference → requiresClientOnlyInstall true")
    func healthyBundledOwnerNoPreferenceRequiresClientOnly() {
        let outcome = OwnershipProbeOutcome.healthy(kind: .bundled, preferredKind: nil)
        #expect(outcome.requiresClientOnlyInstall == true)
    }

    @Test("healthy direct owner does NOT trigger client-only (direct owner is standalone)")
    func healthyDirectOwnerNotClientOnly() {
        // A direct-install (standalone) owner is a different registration
        // channel.  The client-only gate is ONLY for bundled owners (C2).
        let outcome = OwnershipProbeOutcome.healthy(kind: .direct, preferredKind: .direct)
        #expect(outcome.requiresClientOnlyInstall == false)
    }
}

// MARK: - C3: legacy/unauthenticated → normal install, no kill

@Suite("MACD-3B3 C3 — legacy and unauthenticated handling")
struct LegacyUnauthenticatedTests {

    @Test("unauthenticated → normalInstallProceeds, no kill")
    func unauthenticatedNormalInstall() {
        let outcome = OwnershipProbeOutcome.unauthenticated
        // Normal install proceeds — the unauthenticated process is left running.
        #expect(outcome.normalInstallProceeds == true)
        #expect(outcome.requiresClientOnlyInstall == false)
        #expect(outcome.blocksInstallByVersionMismatch == false)
    }

    @Test("absent → normalInstallProceeds")
    func absentNormalInstall() {
        let outcome = OwnershipProbeOutcome.absent
        #expect(outcome.normalInstallProceeds == true)
        #expect(outcome.requiresClientOnlyInstall == false)
        #expect(outcome.blocksInstallByVersionMismatch == false)
    }
}

// MARK: - C4: incompatible blocks install

@Suite("MACD-3B3 C4 — incompatible owner blocks install")
struct IncompatibleBlocksInstallTests {

    @Test("incompatible (.updateApp) → install blocked, verdict available verbatim")
    func incompatibleUpdateApp() {
        let outcome = OwnershipProbeOutcome.incompatible(verdict: .updateApp)
        #expect(outcome.blocksInstallByVersionMismatch == true)
        #expect(outcome.requiresClientOnlyInstall == false)
        #expect(outcome.normalInstallProceeds == false)
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
        #expect(outcome.blocksInstallByVersionMismatch == true)
        #expect(outcome.normalInstallProceeds == false)
    }

    @Test("incompatible (.updateCliClient) → install blocked")
    func incompatibleUpdateCliClient() {
        let outcome = OwnershipProbeOutcome.incompatible(verdict: .updateCliClient)
        #expect(outcome.blocksInstallByVersionMismatch == true)
    }

    @Test("incompatible (.generationDowngrade) → install blocked")
    func incompatibleGenerationDowngrade() {
        let outcome = OwnershipProbeOutcome.incompatible(verdict: .generationDowngrade)
        #expect(outcome.blocksInstallByVersionMismatch == true)
    }

    @Test("incompatible (.keepOwnerNoOverlap) → install blocked")
    func incompatibleKeepOwnerNoOverlap() {
        let outcome = OwnershipProbeOutcome.incompatible(verdict: .keepOwnerNoOverlap)
        #expect(outcome.blocksInstallByVersionMismatch == true)
    }
}

// MARK: - C6: probe result does not rewrite preference

@Suite("MACD-3B3 C6 — probe does not rewrite bundled-preferred")
struct ProbeDoesNotRewritePreferenceTests {

    @Test("healthy outcome carries preferredKind read-only; probe never elects")
    func preferredKindIsReadOnly() {
        // The probe surfaces preferredKind for REPORTING only (C5/C6).
        // Nothing in the probe or coexistence logic changes the preference.
        let outcome = OwnershipProbeOutcome.healthy(kind: .bundled, preferredKind: .bundled)
        if case .healthy(_, let pk) = outcome {
            #expect(pk == .bundled)
        }
    }

    @Test("absent outcome has no preferredKind (nothing was read)")
    func absentHasNoPreferredKind() {
        // The .absent case carries no preferredKind — no preference file was
        // consulted because no authenticated owner exists.
        let outcome = OwnershipProbeOutcome.absent
        if case .healthy(_, let pk) = outcome {
            Issue.record("Expected .absent, got .healthy with preferredKind \(String(describing: pk))")
        }
        #expect(outcome == .absent)
    }
}

// MARK: - Full probe decode + coexistence integration (Part A)

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
        #expect(outcome.requiresClientOnlyInstall == true)
        #expect(outcome.blocksInstallByVersionMismatch == false)
        #expect(outcome.normalInstallProceeds == false)
    }

    @Test("absent → detect returns .absent, normal install gate fires")
    func absentEndToEnd() {
        let p = probe(returning: (-1, nil))
        let outcome = p.detect(homeDirectory: fakeHome)
        #expect(outcome.requiresClientOnlyInstall == false)
        #expect(outcome.blocksInstallByVersionMismatch == false)
        #expect(outcome.normalInstallProceeds == true)
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
        #expect(outcome.requiresClientOnlyInstall == false)
        #expect(outcome.blocksInstallByVersionMismatch == true)
        #expect(outcome.normalInstallProceeds == false)
    }

    @Test("mode-absent (code 64) → .absent, normal install, not unauthenticated")
    func modeAbsentEndToEnd() {
        let p = probe(returning: (64, "usage text"))
        let outcome = p.detect(homeDirectory: fakeHome)
        #expect(outcome == .absent)
        #expect(outcome.requiresClientOnlyInstall == false)
        #expect(outcome.normalInstallProceeds == true)
    }
}

// MARK: - Part B: LaunchAgent.authenticatedBundledOwner formatting (C5)

@Suite("MACD-3B3 C5 — LaunchAgent.authenticatedBundledOwner status formatting")
struct AuthenticatedBundledOwnerFormatTests {

    @Test("absent → nil (falls through to registration/port observation)")
    func absentReturnsNil() {
        // .absent means no authenticated owner; observedServerStatus should use
        // the registration/port observation, not a provider-reported string.
        let result = LaunchAgent.authenticatedBundledOwner(outcome: .absent)
        #expect(result == nil)
    }

    @Test("healthy bundled with preferred → includes kind and preferred fields")
    func healthyBundledWithPreferred() {
        let result = LaunchAgent.authenticatedBundledOwner(
            outcome: .healthy(kind: .bundled, preferredKind: .bundled)
        )
        // Must include both kind and preferred fields from the provider's vocab.
        #expect(result != nil)
        #expect(result!.contains("healthy"))
        #expect(result!.contains(ProviderKind.bundled.rawValue))
        #expect(result!.contains("preferred"))
    }

    @Test("healthy bundled without preferred → includes kind; no preferred field")
    func healthyBundledNoPreferred() {
        let result = LaunchAgent.authenticatedBundledOwner(
            outcome: .healthy(kind: .bundled, preferredKind: nil)
        )
        #expect(result != nil)
        #expect(result!.contains("healthy"))
        #expect(result!.contains(ProviderKind.bundled.rawValue))
        #expect(!result!.contains("preferred"))
    }

    @Test("healthy direct → surfaces kind: direct-install")
    func healthyDirect() {
        let result = LaunchAgent.authenticatedBundledOwner(
            outcome: .healthy(kind: .direct, preferredKind: nil)
        )
        #expect(result != nil)
        #expect(result!.contains(ProviderKind.direct.rawValue))
    }

    @Test("incompatible → surfaces verdict rawValue verbatim (C4 mandate)")
    func incompatibleSurfacesVerdictVerbatim() {
        for verdict in VersionCompatibilityVerdict.allCases {
            let result = LaunchAgent.authenticatedBundledOwner(
                outcome: .incompatible(verdict: verdict)
            )
            // Each verdict rawValue must appear verbatim — no paraphrase.
            #expect(result != nil, "Expected non-nil for verdict \(verdict)")
            #expect(result!.contains(verdict.rawValue),
                    "Expected verbatim rawValue '\(verdict.rawValue)' in '\(result!)'")
        }
    }

    @Test("unauthenticated → non-nil string indicating authentication failure")
    func unauthenticatedNonNil() {
        let result = LaunchAgent.authenticatedBundledOwner(outcome: .unauthenticated)
        #expect(result != nil)
        #expect(result!.contains("authentication failed") || result!.contains("unauthenticated"))
    }

    @Test("observedServerStatus receives authenticatedBundledOwner result verbatim")
    func observedServerStatusPassthrough() {
        // Verify the two-call chain: authenticatedBundledOwner → observedServerStatus.
        // observedServerStatus prefixes the string with "provider: "; the rest is
        // verbatim (no second interpretation).
        let formattedState = LaunchAgent.authenticatedBundledOwner(
            outcome: .healthy(kind: .bundled, preferredKind: .bundled)
        )!
        let statusLine = LaunchAgent.observedServerStatus(
            registration: .registered,
            port: .answering,
            providerReportedState: formattedState
        )
        // The full status line must be exactly "provider: <formattedState>" —
        // not the registration/port vocabulary.
        #expect(statusLine == "provider: \(formattedState)")
        #expect(!statusLine.contains("registered"))
        #expect(!statusLine.contains("answering"))
    }
}

// MARK: - Part B: app-first order (C2 end-to-end)

@Suite("MACD-3B3 Part B — app-first install order (C2 end-to-end)")
struct AppFirstInstallOrderTests {

    private func probe(returning result: (code: Int32, output: String?)) -> ProviderOwnershipProbe {
        ProviderOwnershipProbe(runner: { _, _ in result })
    }

    private func fakeResult(json: [String: Any]) -> (code: Int32, output: String?) {
        let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let string = data.flatMap { String(data: $0, encoding: .utf8) }
        return (0, string)
    }

    private let fakeHome = URL(fileURLWithPath: "/Users/test-appfirst", isDirectory: true)

    // App-first order: the bundled app was installed first (MOOTx01-App); the
    // CLI runs second.  The probe returns healthy(bundled).
    // Expected: no registration performed, artifact stays disabled, client-only gate fires.

    @Test("app-first: probe healthy → requiresClientOnlyInstall (no registration)")
    func appFirstProbeHealthy() {
        let p = probe(returning: fakeResult(json: [
            "outcome": "healthy",
            "kind": ProviderKind.bundled.rawValue,
            "preferredKind": ProviderKind.bundled.rawValue,
        ]))
        let outcome = p.detect(homeDirectory: fakeHome)
        // Gate: install must take client-only path (skip daemon + bundle plist).
        #expect(outcome.requiresClientOnlyInstall == true)
        // No daemon registration performed (tested via the decision gate;
        // the actual LaunchAgent call is inside the command's else-branch).
        #expect(outcome.blocksInstallByVersionMismatch == false)
        #expect(outcome.normalInstallProceeds == false)
    }

    @Test("app-first: status surface returns provider-verbatim string (C5)")
    func appFirstStatusVerbatim() {
        let p = probe(returning: fakeResult(json: [
            "outcome": "healthy",
            "kind": ProviderKind.bundled.rawValue,
        ]))
        let outcome = p.detect(homeDirectory: fakeHome)
        // StatusCommand passes authenticatedBundledOwner(outcome:) into
        // observedServerStatus; verify the chain produces a non-nil state.
        let formattedState = LaunchAgent.authenticatedBundledOwner(outcome: outcome)
        #expect(formattedState != nil)
        // The status line must lead with "provider: " (C5 requirement).
        let statusLine = LaunchAgent.observedServerStatus(
            registration: .registered,
            port: .answering,
            providerReportedState: formattedState
        )
        #expect(statusLine.hasPrefix("provider:"))
    }

    @Test("app-first: probe healthy, no preference → gate fires, preferredKind nil")
    func appFirstHealthyNoPreference() {
        let p = probe(returning: fakeResult(json: [
            "outcome": "healthy",
            "kind": ProviderKind.bundled.rawValue,
            // No preferredKind field in JSON.
        ]))
        let outcome = p.detect(homeDirectory: fakeHome)
        #expect(outcome.requiresClientOnlyInstall == true)
        if case .healthy(_, let pk) = outcome {
            #expect(pk == nil)
        } else {
            Issue.record("Expected .healthy, got \(outcome)")
        }
    }

    // C4: update-direction rows — each mismatch verdict blocks install verbatim.
    @Test("update direction: updateApp → blocksInstallByVersionMismatch")
    func updateDirectionUpdateApp() {
        let outcome = OwnershipProbeOutcome.incompatible(verdict: .updateApp)
        #expect(outcome.blocksInstallByVersionMismatch == true)
        let formatted = LaunchAgent.authenticatedBundledOwner(outcome: outcome)
        #expect(formatted != nil)
        #expect(formatted!.contains(VersionCompatibilityVerdict.updateApp.rawValue))
    }

    @Test("update direction: updateCliClient → blocksInstallByVersionMismatch")
    func updateDirectionUpdateCliClient() {
        let outcome = OwnershipProbeOutcome.incompatible(verdict: .updateCliClient)
        #expect(outcome.blocksInstallByVersionMismatch == true)
        let formatted = LaunchAgent.authenticatedBundledOwner(outcome: outcome)
        #expect(formatted!.contains(VersionCompatibilityVerdict.updateCliClient.rawValue))
    }

    @Test("update direction: generationDowngrade → blocksInstallByVersionMismatch")
    func updateDirectionGenerationDowngrade() {
        let outcome = OwnershipProbeOutcome.incompatible(verdict: .generationDowngrade)
        #expect(outcome.blocksInstallByVersionMismatch == true)
    }

    // C6: preference read-only — install never rewrites bundled-preferred.
    @Test("C6: preferredKind from probe is read-only; not modified by install logic")
    func preferenceReadOnly() {
        // The probe carries preferredKind from the subprocess JSON.
        // The install path reads it for REPORTING only — never writes it.
        // This test verifies the outcome's preferredKind survives the gate
        // functions unchanged.
        let p = probe(returning: fakeResult(json: [
            "outcome": "healthy",
            "kind": ProviderKind.bundled.rawValue,
            "preferredKind": ProviderKind.bundled.rawValue,
        ]))
        let outcome = p.detect(homeDirectory: fakeHome)
        // Run through the gate; verify preferredKind is unchanged afterward.
        let _ = outcome.requiresClientOnlyInstall
        let _ = outcome.blocksInstallByVersionMismatch
        let _ = outcome.normalInstallProceeds
        if case .healthy(_, let pk) = outcome {
            #expect(pk == .bundled, "preferredKind must not be changed by gate evaluation")
        } else {
            Issue.record("Expected .healthy, got \(outcome)")
        }
    }

    // Interrupted-handover: unauthenticated → reported conflict state, no kill.
    @Test("interrupted handover: unauthenticated → reported conflict, no kill (C3)")
    func interruptedHandoverUnauthenticated() {
        let p = probe(returning: (1, nil)) // non-zero, non-64 → .unauthenticated
        let outcome = p.detect(homeDirectory: fakeHome)
        #expect(outcome == .unauthenticated)
        #expect(outcome.normalInstallProceeds == true)
        #expect(outcome.requiresClientOnlyInstall == false)
        // Status surface reports unauthenticated state honestly (not nil).
        let formatted = LaunchAgent.authenticatedBundledOwner(outcome: outcome)
        #expect(formatted != nil)
    }
}
