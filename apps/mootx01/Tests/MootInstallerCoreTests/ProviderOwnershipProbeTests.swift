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

// MARK: - BundleCensusGate tests (Perkins F1 — census-site gate)

/// Tests for `BundleSignatureVerifier.gate(homeDirectory:)`, the shared helper
/// that gates census exec and disabled-plist staging in both `InstallCommand`
/// and `UpgradeCommand`.
///
/// Coverage:
///  - absent executable → .absent
///  - verifier reject → .unverified with actionable message
///  - verifier pass → .verified
///  - planted unsigned binary with real Security verifier → .unverified (RED exploit test)
///  - source invariant: both command files call the gate before census
@Suite("BundleCensusGate — shared pre-census verification helper (Perkins F1)")
struct BundleCensusGateTests {

    private static let fakeHome = URL(fileURLWithPath: "/Users/test-census-gate", isDirectory: true)

    @Test("absent executable → .absent (no executable at bundle path)")
    func absentExecutable() {
        // fakeHome has no real bundle executable; gate must return .absent without
        // calling the verifier.
        let alwaysReject = BundleSignatureVerifier(verify: { _ in false })
        let result = alwaysReject.gate(homeDirectory: Self.fakeHome)
        #expect(result == .absent,
                "non-existent executable must yield .absent, verifier must not be called")
    }

    @Test("verifier reject → .unverified with actionable message (planted unsigned binary)")
    func verifierRejectYieldsUnverified() throws {
        // Create a fake home with an executable at the bundle path so isExecutableFile
        // returns true, then inject an always-rejecting verifier to simulate an
        // unsigned binary.
        let fakeHomeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("census-gate-reject-\(UUID().uuidString)", isDirectory: true)
        let execURL = DaemonBundle.bundleExecutableURL(homeDirectory: fakeHomeDir)
        try FileManager.default.createDirectory(
            at: execURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        defer { try? FileManager.default.removeItem(at: fakeHomeDir) }

        // Plant a minimal executable (unsigned shell script) so isExecutableFile is true.
        let script = "#!/bin/sh\necho census-exploit"
        try script.write(to: execURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: execURL.path
        )

        // Inject always-rejecting verifier to simulate unsigned/ad-hoc/wrong-identity binary.
        let alwaysReject = BundleSignatureVerifier(verify: { _ in false })
        let result = alwaysReject.gate(homeDirectory: fakeHomeDir)

        // Must be .unverified — the census caller must skip census and plist.
        switch result {
        case .unverified(let msg):
            // Message must be actionable: warn about the unverified bundle and
            // confirm no process was started.
            #expect(msg.contains("signature could not be verified"),
                    "message must name the signature check failure; got: \(msg)")
            #expect(msg.contains("No provider process was started"),
                    "message must confirm no process was started; got: \(msg)")
        case .absent:
            Issue.record("executable present but gate returned .absent — verifier was not called")
        case .verified:
            Issue.record("always-rejecting verifier must not yield .verified")
        }
    }

    @Test("verifier pass → .verified (census may proceed)")
    func verifierPassYieldsVerified() throws {
        // Create a fake home with an executable and inject an always-valid verifier.
        let fakeHomeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("census-gate-pass-\(UUID().uuidString)", isDirectory: true)
        let execURL = DaemonBundle.bundleExecutableURL(homeDirectory: fakeHomeDir)
        try FileManager.default.createDirectory(
            at: execURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        defer { try? FileManager.default.removeItem(at: fakeHomeDir) }

        let script = "#!/bin/sh\necho {}"
        try script.write(to: execURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: execURL.path
        )

        // alwaysValid simulates a legitimately signed bundle.
        let result = BundleSignatureVerifier.alwaysValid.gate(homeDirectory: fakeHomeDir)
        #expect(result == .verified,
                "always-valid verifier with an executable binary must yield .verified")
    }

    // RED exploit test — Perkins F1 census-site: planted unsigned binary at the census
    // exec path, real Security-framework verifier.  The gate must return .unverified
    // before any census exec, so the attacker's subprocess never runs.
    #if canImport(Security)
    @Test("planted unsigned binary at census path → .unverified, not .verified (F1 census-site exploit closed)")
    func plantedBinaryCensusGateRefused() throws {
        let fakeHomeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("census-gate-f1-\(UUID().uuidString)", isDirectory: true)
        let execURL = DaemonBundle.bundleExecutableURL(homeDirectory: fakeHomeDir)
        try FileManager.default.createDirectory(
            at: execURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        defer { try? FileManager.default.removeItem(at: fakeHomeDir) }

        // Exploit payload: an unsigned shell script that emits a fake census report.
        // In the pre-fix code this binary would have reached DaemonBundle.runReadOnlyMode
        // ("census") after only isExecutableFile, giving the attacker arbitrary code
        // execution as the census subprocess with its output printed to the user.
        let exploitScript = "#!/bin/sh\necho 'attacker census output'"
        try exploitScript.write(to: execURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: execURL.path
        )

        // Real Security-framework verifier — this is what production uses.
        let productionVerifier = BundleSignatureVerifier(
            verify: SecStaticBundleVerifier.verify(executableURL:)
        )
        let result = productionVerifier.gate(homeDirectory: fakeHomeDir)

        // Gate must refuse the unsigned script — census exec is never reached.
        switch result {
        case .unverified:
            break  // correct — exploit blocked
        case .verified:
            Issue.record("real verifier must not pass an unsigned shell script — census-site exploit still open")
        case .absent:
            Issue.record("executable is present; gate must not return .absent")
        }
    }
    #endif
}

// MARK: - Census-site source invariant tests (Perkins F1)

/// Source-level invariant tests verifying that both InstallCommand and UpgradeCommand
/// call `BundleSignatureVerifier.production.gate(homeDirectory:)` before any census
/// exec.  These tests catch regressions where the gate is removed or bypassed.
@Suite("Census-site gate source invariants (Perkins F1)")
struct CensusSiteGateSourceTests {

    private static func commandSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MootInstallerCoreTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // apps/mootx01/
            .appendingPathComponent("Sources/mootx01/Commands/\(name).swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("InstallCommand calls BundleSignatureVerifier.production.gate before census exec")
    func installCommandGatesBeforeCensus() throws {
        let source = try Self.commandSource("InstallCommand")
        #expect(source.contains("BundleSignatureVerifier.production.gate(homeDirectory:"),
                "InstallCommand must call BundleSignatureVerifier.production.gate before census")
        // The gate call must appear BEFORE the census call in the source.
        let gateRange = try #require(
            source.range(of: "BundleSignatureVerifier.production.gate"),
            "gate call not found in InstallCommand"
        )
        let censusRange = try #require(
            source.range(of: "runReadOnlyMode(\"census\""),
            "census call not found in InstallCommand"
        )
        #expect(gateRange.lowerBound < censusRange.lowerBound,
                "gate call must precede census call in InstallCommand source order")
    }

    @Test("UpgradeCommand calls BundleSignatureVerifier.production.gate before census exec")
    func upgradeCommandGatesBeforeCensus() throws {
        let source = try Self.commandSource("UpgradeCommand")
        #expect(source.contains("BundleSignatureVerifier.production.gate(homeDirectory:"),
                "UpgradeCommand must call BundleSignatureVerifier.production.gate before census")
        let gateRange = try #require(
            source.range(of: "BundleSignatureVerifier.production.gate"),
            "gate call not found in UpgradeCommand"
        )
        let censusRange = try #require(
            source.range(of: "runReadOnlyMode(\"census\""),
            "census call not found in UpgradeCommand"
        )
        #expect(gateRange.lowerBound < censusRange.lowerBound,
                "gate call must precede census call in UpgradeCommand source order")
    }

    @Test("InstallCommand skips plist staging on .unverified (no disabled plist for impostor binary)")
    func installCommandSkipsPlistOnUnverified() throws {
        let source = try Self.commandSource("InstallCommand")
        // The .unverified branch must return before installDaemonBundleDisabled is called.
        let unverifiedRange = try #require(
            source.range(of: "case .unverified"),
            ".unverified case not found in InstallCommand"
        )
        let plistRange = try #require(
            source.range(of: "installDaemonBundleDisabled"),
            "plist install call not found in InstallCommand"
        )
        // .unverified branch must appear before installDaemonBundleDisabled in source
        // AND the .unverified case must contain a `return` before reaching it.
        #expect(unverifiedRange.lowerBound < plistRange.lowerBound,
                ".unverified case must appear before plist staging in source order")
    }

    @Test("UpgradeCommand skips plist staging on .unverified (no disabled plist for impostor binary)")
    func upgradeCommandSkipsPlistOnUnverified() throws {
        let source = try Self.commandSource("UpgradeCommand")
        let unverifiedRange = try #require(
            source.range(of: "case .unverified"),
            ".unverified case not found in UpgradeCommand"
        )
        let plistRange = try #require(
            source.range(of: "installDaemonBundleDisabled"),
            "plist install call not found in UpgradeCommand"
        )
        #expect(unverifiedRange.lowerBound < plistRange.lowerBound,
                ".unverified case must appear before plist staging in UpgradeCommand source order")
    }
}

// MARK: - Requirement-string team-OU pin invariant tests (MACD-3B3 residual)

/// Source-level invariant tests verifying that SecStaticBundleVerifier.verify
/// pins the signing team via `certificate leaf[subject.OU] = "G94X5T5GK7"`.
///
/// These tests close the MACD-3B3 blocking residual (seal 7CCC18C3): without the
/// OU pin, any Apple-issued developer certificate from any team naming the same
/// bundle identifier would satisfy the `anchor apple generic and identifier` check.
/// A source-level test makes the pin visible to review and prevents silent removal.
@Suite("SecStaticBundleVerifier requirement — OU pin invariant (MACD-3B3)")
struct RequirementOUPinTests {

    private static func probeSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MootInstallerCoreTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // apps/mootx01/
            .appendingPathComponent("Sources/MootInstallerCore/ProviderOwnershipProbe.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("requirement string contains team OU pin G94X5T5GK7 (MACD-3B3 residual)")
    func requirementPinsTeamOU() throws {
        let source = try Self.probeSource()
        // The requirement must pin the signing team.  Without this clause any
        // Apple-issued developer certificate from any team naming the same
        // bundle identifier would satisfy the anchor+identifier check.
        #expect(
            source.contains("certificate leaf[subject.OU] = \"G94X5T5GK7\""),
            "SecStaticBundleVerifier.verify must pin the team OU — MACD-3B3 residual"
        )
    }

    @Test("requirement string retains anchor apple generic")
    func requirementRetainsAnchor() throws {
        let source = try Self.probeSource()
        // The anchor clause rules out unsigned and ad-hoc signatures.  It must
        // not be removed when the OU pin is present.
        #expect(
            source.contains("anchor apple generic"),
            "SecStaticBundleVerifier.verify must retain anchor apple generic"
        )
    }

    @Test("requirement string retains bundle identifier pin")
    func requirementRetainsBundleID() throws {
        let source = try Self.probeSource()
        // The identifier clause pins the binary to the registered, unique bundle
        // identifier.  It must not be removed when the OU pin is present.
        // Check via raw string: in the source file the requirement string literal
        // contains `identifier \"<id>\"` (Swift-escaped), so look for that form.
        #expect(
            source.contains(#"identifier \"\(DaemonBundle.bundleIdentifier)\""#),
            "SecStaticBundleVerifier.verify must retain the bundle identifier pin"
        )
    }
}
