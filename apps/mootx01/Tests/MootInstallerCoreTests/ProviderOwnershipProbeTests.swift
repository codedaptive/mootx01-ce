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

// MARK: - Missing decode-path tests (Adams MINOR 3)

@Suite("ProviderOwnershipProbe — incompatible decode paths (repairOwnership / keepOwnerNoOverlap / candidateCannotReadEstate)")
struct ProbeMissingVerdictDecodeTests {

    // These three VersionCompatibilityVerdict rawValues were not previously exercised
    // in the JSON-decode path.  A typo in any rawValue would silently produce
    // .unauthenticated without any test catching the decode failure.

    @Test("repairOwnership verdict → .incompatible(.repairOwnership)")
    func incompatibleRepairOwnership() {
        let p = probe(returning: fakeResult(json: [
            "mode": "owner-status",
            "outcome": "incompatible",
            "kind": ProviderKind.bundled.rawValue,
            "verdict": VersionCompatibilityVerdict.repairOwnership.rawValue,
        ]))
        #expect(p.detect(homeDirectory: fakeHome) == .incompatible(verdict: .repairOwnership))
    }

    @Test("keepOwnerNoOverlap verdict → .incompatible(.keepOwnerNoOverlap)")
    func incompatibleKeepOwnerNoOverlap() {
        let p = probe(returning: fakeResult(json: [
            "mode": "owner-status",
            "outcome": "incompatible",
            "kind": ProviderKind.bundled.rawValue,
            "verdict": VersionCompatibilityVerdict.keepOwnerNoOverlap.rawValue,
        ]))
        #expect(p.detect(homeDirectory: fakeHome) == .incompatible(verdict: .keepOwnerNoOverlap))
    }

    @Test("candidateCannotReadEstate verdict → .incompatible(.candidateCannotReadEstate)")
    func incompatibleCandidateCannotReadEstate() {
        let p = probe(returning: fakeResult(json: [
            "mode": "owner-status",
            "outcome": "incompatible",
            "kind": ProviderKind.bundled.rawValue,
            "verdict": VersionCompatibilityVerdict.candidateCannotReadEstate.rawValue,
        ]))
        #expect(p.detect(homeDirectory: fakeHome) == .incompatible(verdict: .candidateCannotReadEstate))
    }
}

// MARK: - Signature verifier seam tests (Perkins F1)

@Suite("ProviderOwnershipProbe — signature verification seam (Perkins F1)")
struct ProbeSignatureVerifierTests {

    // These tests exercise the BundleSignatureVerifier seam introduced to close
    // the Perkins F1 trust-boundary gap: before the CLI runs the bundle subprocess,
    // it must verify the binary is the legitimate signed artifact.

    @Test("verifier refusal → .unauthenticated even when runner returns healthy (F1 gate)")
    func verifierRefusalGate() {
        // Simulates a planted unsigned binary: the runner WOULD return healthy JSON
        // (as in the exploit), but the verifier refuses the file first.
        let p = ProviderOwnershipProbe(
            runner: { _, _ in
                (0, "{\"mode\":\"owner-status\",\"outcome\":\"healthy\",\"kind\":\"bundled\"}")
            },
            verifier: .init(verify: { _ in false })  // simulate unsigned/wrong-team binary
        )
        // Verifier refuses → .unauthenticated, not .absent (see trust-boundary comment)
        #expect(p.detect(homeDirectory: fakeHome) == .unauthenticated)
    }

    @Test("verifier pass + runner healthy → .healthy (normal path)")
    func verifierPassThenHealthy() {
        // Verifier accepts the binary; the runner returns a healthy verdict.
        // Confirms the verifier seam does not interfere with the success path.
        let p = ProviderOwnershipProbe(
            runner: { _, _ in
                fakeResult(json: [
                    "mode": "owner-status",
                    "outcome": "healthy",
                    "kind": ProviderKind.bundled.rawValue,
                ])
            },
            verifier: .alwaysValid
        )
        #expect(p.detect(homeDirectory: fakeHome) == .healthy(kind: .bundled, preferredKind: nil))
    }

    @Test("verifier not called when executable absent → .absent from runner (not .unauthenticated)")
    func verifierSkippedForAbsentBinary() {
        // When the bundle executable does not exist at the expected path, the
        // verifier must NOT be called (verifying a non-existent path would
        // spuriously return .unauthenticated, shadowing .absent).
        //
        // Proof: inject a verifier that returns false for every path.  If the
        // verifier were called for a non-existent binary, the outcome would be
        // .unauthenticated; .absent proves the verifier was skipped.
        let p = ProviderOwnershipProbe(
            runner: { _, _ in (-1, nil) },
            verifier: .init(verify: { _ in false })  // always-reject; called iff file exists
        )
        // fakeHome (/Users/test-probe) has no real bundle binary; fileExists returns false.
        // The runner's -1 exit maps to .absent, proving the verifier was not called.
        let outcome = p.detect(homeDirectory: fakeHome)
        #expect(outcome == .absent,
                "absent binary must yield .absent, not .unauthenticated — verifier must not run for non-existent paths")
    }

    // RED TEST — Perkins F1 exploit: planted unsigned shell script at the bundle
    // executable path, real Security-framework verifier.
    //
    // This test reproduces the exact exploit scenario: a process running as the
    // current user places an unsigned shell script at the daemon bundle executable
    // path that emits a healthy JSON response.  With the real SecStaticBundleVerifier,
    // the probe must refuse with .unauthenticated — the impostor is never launched.
    #if canImport(Security)
    @Test("planted unsigned shell script at bundle path → .unauthenticated (F1 exploit closed)")
    func plantedShellScriptRefused() throws {
        // Build a fake home directory and create the full bundle executable path.
        let fakeHomeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-f1-test-\(UUID().uuidString)", isDirectory: true)
        let execURL = DaemonBundle.bundleExecutableURL(homeDirectory: fakeHomeDir)
        try FileManager.default.createDirectory(
            at: execURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        defer { try? FileManager.default.removeItem(at: fakeHomeDir) }

        // Plant an unsigned shell script at the exact path the probe will check.
        // This is the Perkins F1 exploit payload: the script emits a "healthy"
        // JSON response that, without signature verification, would route
        // InstallCommand / UpgradeCommand to the client-only path — skipping all
        // daemon registration.
        let exploitScript = "#!/bin/sh\necho '{\"mode\":\"owner-status\",\"outcome\":\"healthy\",\"kind\":\"bundled\"}'"
        try exploitScript.write(to: execURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: execURL.path
        )

        // Probe with the REAL Security-framework verifier and a runner that would
        // return healthy if ever reached (it must NOT be reached).
        let probe = ProviderOwnershipProbe(
            runner: { _, _ in
                (0, "{\"mode\":\"owner-status\",\"outcome\":\"healthy\",\"kind\":\"bundled\"}")
            },
            verifier: .init(verify: SecStaticBundleVerifier.verify(executableURL:))
        )
        // The real verifier must reject the unsigned shell script — exploit blocked.
        #expect(
            probe.detect(homeDirectory: fakeHomeDir) == .unauthenticated,
            "planted unsigned binary must be refused; Perkins F1 exploit must be blocked"
        )
    }
    #endif
}
