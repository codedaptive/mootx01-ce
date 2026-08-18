// ProviderOwnershipProbeTests.swift
// MootInstallerCoreTests — MACD-3B3 probe decode logic
//
// Tests the JSON-decoding logic of ProviderOwnershipProbe.detect via the
// internal test initialiser that injects a deterministic fake subprocess
// runner.  No real bundle binary is required; the decode path is exercised
// in isolation.
//
// Coverage (TDD RED/GREEN per policy):
//   1. Authenticated healthy bundled owner
//   2. Absent — binary not found (code -1)
//   3. Absent — shell mode not recognised (code 64) — distinguished from unauthenticated
//   4. Unauthenticated impostor — wrong MAC / crafted descriptor
//   5. Legacy schema-2 descriptor — classified unauthenticated, no kill
//   6. Incompatible newer — updateApp verdict
//   7. Incompatible older — updateCliService verdict
//   8. Incompatible CLI too old — updateCliClient verdict
//   9. Absent — descriptor file absent (outcome="absent" from subprocess)
//  10. Malformed JSON — fail-closed → unauthenticated
//  11. Unknown outcome string — fail-closed → unauthenticated
//  12. Healthy with no preference written (preferredKind absent from JSON)
//  13. Healthy with preference for bundled kind

import Foundation
import Testing
import MootDaemonProvider
@testable import MootInstallerCore

// MARK: - Fake subprocess helpers

/// Build a fake subprocess result that returns the given JSON dictionary.
private func fakeResult(code: Int32 = 0, json: [String: Any]) -> (code: Int32, output: String?) {
    let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    let string = data.flatMap { String(data: $0, encoding: .utf8) }
    return (code, string)
}

/// A probe with an injected runner that returns a fixed result.
private func probe(returning result: (code: Int32, output: String?)) -> ProviderOwnershipProbe {
    ProviderOwnershipProbe(runner: { _, _ in result })
}

private let fakeHome = URL(fileURLWithPath: "/Users/test-probe", isDirectory: true)

// MARK: - Absent cases

@Suite("ProviderOwnershipProbe — absent")
struct ProbeAbsentTests {

    @Test("binary absent (code -1) → .absent")
    func binaryAbsent() {
        let p = probe(returning: (-1, nil))
        #expect(p.detect(homeDirectory: fakeHome) == .absent)
    }

    @Test("shell mode unrecognised (code 64) → .absent, not .unauthenticated")
    func shellModeAbsent() {
        // Code 64 is the DaemonShellMain.usageText default case — the installed
        // bundle predates the owner-status mode.  This must map to .absent, not
        // .unauthenticated, because the absence of the mode is a missing
        // capability, not an authentication failure.
        let p = probe(returning: (64, "usage: mootx01-daemon self-report"))
        let outcome = p.detect(homeDirectory: fakeHome)
        #expect(outcome == .absent)
        // Explicitly assert it is NOT unauthenticated — the key TDD claim.
        if case .unauthenticated = outcome {
            Issue.record("mode-absent should map to .absent, got .unauthenticated")
        }
    }

    @Test("descriptor file absent (subprocess outcome=absent) → .absent")
    func descriptorAbsent() {
        let p = probe(returning: fakeResult(json: [
            "mode": "owner-status",
            "outcome": "absent",
        ]))
        #expect(p.detect(homeDirectory: fakeHome) == .absent)
    }

    @Test("K_install never minted (subprocess outcome=absent) → .absent")
    func keyNeverMinted() {
        // The bundle reports absent when K_install is not in the Keychain.
        let p = probe(returning: fakeResult(json: [
            "mode": "owner-status",
            "outcome": "absent",
        ]))
        #expect(p.detect(homeDirectory: fakeHome) == .absent)
    }
}

// MARK: - Healthy cases

@Suite("ProviderOwnershipProbe — healthy")
struct ProbeHealthyTests {

    @Test("authenticated healthy bundled owner → .healthy(.bundled, preferredKind)")
    func healthyBundledOwnerWithPreference() {
        let p = probe(returning: fakeResult(json: [
            "mode": "owner-status",
            "outcome": "healthy",
            "kind": ProviderKind.bundled.rawValue,
            "preferredKind": ProviderKind.bundled.rawValue,
        ]))
        #expect(p.detect(homeDirectory: fakeHome) == .healthy(kind: .bundled, preferredKind: .bundled))
    }

    @Test("healthy bundled owner with no preference written → .healthy(.bundled, nil)")
    func healthyBundledOwnerNoPreference() {
        // preferredKind omitted from JSON when no preference file has been written yet.
        let p = probe(returning: fakeResult(json: [
            "mode": "owner-status",
            "outcome": "healthy",
            "kind": ProviderKind.bundled.rawValue,
        ]))
        #expect(p.detect(homeDirectory: fakeHome) == .healthy(kind: .bundled, preferredKind: nil))
    }

    @Test("healthy direct owner with bundled preference → .healthy(.direct, .bundled)")
    func healthyDirectOwnerWithBundledPreference() {
        let p = probe(returning: fakeResult(json: [
            "mode": "owner-status",
            "outcome": "healthy",
            "kind": ProviderKind.direct.rawValue,
            "preferredKind": ProviderKind.bundled.rawValue,
        ]))
        #expect(p.detect(homeDirectory: fakeHome) == .healthy(kind: .direct, preferredKind: .bundled))
    }

    @Test("healthy report with unknown kind → .unauthenticated (fail-closed)")
    func healthyUnknownKind() {
        // An unrecognised kind string cannot be decoded into ProviderKind — fail-closed.
        let p = probe(returning: fakeResult(json: [
            "mode": "owner-status",
            "outcome": "healthy",
            "kind": "not-a-valid-kind",
        ]))
        #expect(p.detect(homeDirectory: fakeHome) == .unauthenticated)
    }

    @Test("healthy report missing kind field → .unauthenticated (fail-closed)")
    func healthyMissingKind() {
        // A healthy report without kind is malformed — fail-closed.
        let p = probe(returning: fakeResult(json: [
            "mode": "owner-status",
            "outcome": "healthy",
        ]))
        #expect(p.detect(homeDirectory: fakeHome) == .unauthenticated)
    }
}

// MARK: - Unauthenticated cases

@Suite("ProviderOwnershipProbe — unauthenticated")
struct ProbeUnauthenticatedTests {

    @Test("crafted descriptor with wrong MAC → .unauthenticated")
    func wrongMacImpostor() {
        // An impostor process writes a descriptor with a squatted port but cannot
        // produce a valid MAC without K_install.  The bundle subprocess detects this
        // and reports unauthenticated.
        let p = probe(returning: fakeResult(json: [
            "mode": "owner-status",
            "outcome": "unauthenticated",
        ]))
        #expect(p.detect(homeDirectory: fakeHome) == .unauthenticated)
    }

    @Test("legacy schema-2 descriptor → .unauthenticated (no kill, no replace)")
    func legacySchema2Descriptor() {
        // A schema-2 descriptor is classified unauthenticated per C3 carry-forward
        // (Perkins A1).  The probe must NOT kill or replace the process running
        // behind it.  Callers use this classification to skip client-only install
        // (the legacy provider runs on; the CLI does not register a second daemon).
        let p = probe(returning: fakeResult(json: [
            "mode": "owner-status",
            "outcome": "unauthenticated",
            "verdict": VersionCompatibilityVerdict.legacyNotEligibleForAutomatedTakeover.rawValue,
        ]))
        #expect(p.detect(homeDirectory: fakeHome) == .unauthenticated)
    }

    @Test("Keychain fatal error → .unauthenticated (fail-closed)")
    func keychainFatal() {
        // The bundle reported unauthenticated when a Keychain fatal fault occurred
        // (entitlement missing in this context, or interaction required, etc.).
        let p = probe(returning: fakeResult(json: [
            "mode": "owner-status",
            "outcome": "unauthenticated",
        ]))
        #expect(p.detect(homeDirectory: fakeHome) == .unauthenticated)
    }
}

// MARK: - Incompatible cases

@Suite("ProviderOwnershipProbe — incompatible")
struct ProbeIncompatibleTests {

    @Test("owner newer than CLI can understand → .incompatible(.updateApp)")
    func incompatibleNewer() {
        // The running owner's data-plane revision is newer than what this CLI
        // supports.  C4: surface the verdict verbatim.
        let p = probe(returning: fakeResult(json: [
            "mode": "owner-status",
            "outcome": "incompatible",
            "kind": ProviderKind.bundled.rawValue,
            "verdict": VersionCompatibilityVerdict.updateApp.rawValue,
        ]))
        #expect(p.detect(homeDirectory: fakeHome) == .incompatible(verdict: .updateApp))
    }

    @Test("owner's CLI service is too old for this client → .incompatible(.updateCliService)")
    func incompatibleCliService() {
        // The running provider (the CLI service) is older than the revision this
        // CLI binary requires.  C4: surface verbatim.
        let p = probe(returning: fakeResult(json: [
            "mode": "owner-status",
            "outcome": "incompatible",
            "kind": ProviderKind.bundled.rawValue,
            "verdict": VersionCompatibilityVerdict.updateCliService.rawValue,
        ]))
        #expect(p.detect(homeDirectory: fakeHome) == .incompatible(verdict: .updateCliService))
    }

    @Test("CLI client too old for the running owner → .incompatible(.updateCliClient)")
    func incompatibleCliClient() {
        // This CLI binary is older than the revision the running owner requires
        // for its clients.  C4: surface verbatim.
        let p = probe(returning: fakeResult(json: [
            "mode": "owner-status",
            "outcome": "incompatible",
            "kind": ProviderKind.bundled.rawValue,
            "verdict": VersionCompatibilityVerdict.updateCliClient.rawValue,
        ]))
        #expect(p.detect(homeDirectory: fakeHome) == .incompatible(verdict: .updateCliClient))
    }

    @Test("generation downgrade → .incompatible(.generationDowngrade)")
    func incompatibleGenerationDowngrade() {
        let p = probe(returning: fakeResult(json: [
            "mode": "owner-status",
            "outcome": "incompatible",
            "kind": ProviderKind.bundled.rawValue,
            "verdict": VersionCompatibilityVerdict.generationDowngrade.rawValue,
        ]))
        #expect(p.detect(homeDirectory: fakeHome) == .incompatible(verdict: .generationDowngrade))
    }

    @Test("incompatible with unknown verdict → .unauthenticated (fail-closed)")
    func incompatibleUnknownVerdict() {
        // An unrecognised verdict string cannot be decoded — fail-closed so the
        // caller does not proceed with install when the owner's status is unclear.
        let p = probe(returning: fakeResult(json: [
            "mode": "owner-status",
            "outcome": "incompatible",
            "kind": ProviderKind.bundled.rawValue,
            "verdict": "future-unknown-verdict",
        ]))
        #expect(p.detect(homeDirectory: fakeHome) == .unauthenticated)
    }

    @Test("incompatible with missing verdict field → .unauthenticated (fail-closed)")
    func incompatibleMissingVerdict() {
        let p = probe(returning: fakeResult(json: [
            "mode": "owner-status",
            "outcome": "incompatible",
        ]))
        #expect(p.detect(homeDirectory: fakeHome) == .unauthenticated)
    }
}

// MARK: - Fail-closed cases

@Suite("ProviderOwnershipProbe — fail-closed")
struct ProbeFailClosedTests {

    @Test("non-zero non-64 exit code → .unauthenticated (fail-closed)")
    func nonZeroExitCode() {
        // Any other non-zero exit (e.g., 1, 2) should fail-closed.
        let p = probe(returning: (1, nil))
        #expect(p.detect(homeDirectory: fakeHome) == .unauthenticated)
    }

    @Test("malformed JSON output → .unauthenticated (fail-closed)")
    func malformedJSON() {
        let p = probe(returning: (0, "not valid json at all"))
        #expect(p.detect(homeDirectory: fakeHome) == .unauthenticated)
    }

    @Test("nil output with code 0 → .unauthenticated (fail-closed)")
    func nilOutputCode0() {
        let p = probe(returning: (0, nil))
        #expect(p.detect(homeDirectory: fakeHome) == .unauthenticated)
    }

    @Test("JSON missing outcome field → .unauthenticated (fail-closed)")
    func missingOutcomeField() {
        let p = probe(returning: fakeResult(json: ["mode": "owner-status"]))
        #expect(p.detect(homeDirectory: fakeHome) == .unauthenticated)
    }

    @Test("unknown outcome string → .unauthenticated (fail-closed)")
    func unknownOutcomeString() {
        let p = probe(returning: fakeResult(json: [
            "mode": "owner-status",
            "outcome": "some-future-outcome-string",
        ]))
        #expect(p.detect(homeDirectory: fakeHome) == .unauthenticated)
    }
}
