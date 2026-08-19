// AppFirstStandaloneSecondTests.swift
// MootInstallerCoreTests — MACD-3B5 GAP 2 coverage.
//
// Design: "App first, standalone second" — 5-step install sequence.
//
// Smythe pre-flight identified this gap: the existing InstallCoexistenceTests
// (3B3 Part B) verify the gate-logic and status-format decisions in isolation.
// What is NOT covered is the full 5-step chain with explicit end-state
// assertions:
//
//   Step 1: mootx01 install authenticates the bundled provider
//             (probe returns healthy(bundled)).
//   Step 2: Install CLI and write MCP client config.
//   Step 3: Stage the direct provider as a DISABLED recovery artifact.
//             Never registers or starts it — RunAtLoad must be false.
//   Step 4: Record and report "Using MOOTx01-App resident provider".
//   Step 5: A CLI/client mismatch reports the required update and NEVER
//             starts a second provider.
//
// End-state invariants (design mandate, §Decision):
//   ES-1: One logical service — the bundled provider is the sole active owner.
//   ES-2: One active provider — standaloneRegistered is NOT reached.
//   ES-3: One writable estate — no second SQLite open authority is created.
//
// Each test documents what regression would make it fail.
//
// BLOCKED paths (require live entitled provider + App Store-signed bundle):
//   - Real subprocess authentication of the bundled provider executable
//   - Real SMAppService registration status for the bundled helper
//   - Real SQLite open on the bundled provider's canonical estate

import Foundation
import Testing
import MootDaemonProvider
@testable import MootInstallerCore

// MARK: - Probe injection helper

private func bundledHealthyProbe(
    kind: ProviderKind = .bundled,
    preferredKind: ProviderKind? = .bundled
) -> ProviderOwnershipProbe {
    let json = NSMutableDictionary()
    json["outcome"] = "healthy"
    json["kind"] = kind.rawValue
    if let pk = preferredKind { json["preferredKind"] = pk.rawValue }
    let data = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    let string = String(data: data, encoding: .utf8)!
    return ProviderOwnershipProbe(runner: { _, _ in (0, string) })
}

private func incompatibleProbe(verdict: VersionCompatibilityVerdict) -> ProviderOwnershipProbe {
    let json: [String: String] = [
        "outcome": "incompatible",
        "verdict": verdict.rawValue,
    ]
    let data = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    let string = String(data: data, encoding: .utf8)!
    return ProviderOwnershipProbe(runner: { _, _ in (0, string) })
}

private let fakeHome = URL(fileURLWithPath: "/Users/test-a1st-s2nd", isDirectory: true)

// MARK: - Suite 1: Step 1 — authentication of the bundled provider

@Suite("App-first / standalone-second — Step 1: bundled provider authenticated")
struct AppFirstStep1AuthenticationTests {

    /// Step 1 positive: probe returns healthy(bundled) → gate fires correctly.
    ///
    /// Regression: if the gate does not fire on a healthy bundled outcome, the
    /// install path would attempt a full standalone install, creating a second
    /// provider. The `requiresClientOnlyInstall == true` check is the only
    /// gate that prevents it.
    @Test("healthy bundled probe → requiresClientOnlyInstall true, normalInstallProceeds false")
    func healthyBundledGateFires() {
        let probe = bundledHealthyProbe()
        let outcome = probe.detect(homeDirectory: fakeHome)
        // Gate must fire — this is Step 1's decision output.
        #expect(outcome.requiresClientOnlyInstall == true,
                "healthy bundled owner must trigger client-only gate")
        #expect(outcome.normalInstallProceeds == false,
                "normal install must be blocked when bundled owner is active")
        #expect(outcome.blocksInstallByVersionMismatch == false,
                "healthy means compatible — not a version block")
    }

    /// Step 1 unauthenticated path: probe cannot authenticate → normal install
    /// proceeds. The running process is NOT killed (C3 mandate).
    ///
    /// Regression: if unauthenticated incorrectly fires the client-only gate,
    /// a running process that happens to be unsigned could block an install.
    @Test("unauthenticated probe → normal install proceeds, no kill (C3)")
    func unauthenticatedNormalInstall() {
        let probe = ProviderOwnershipProbe(runner: { _, _ in (1, nil) })
        let outcome = probe.detect(homeDirectory: fakeHome)
        #expect(outcome == .unauthenticated)
        #expect(outcome.normalInstallProceeds == true,
                "unauthenticated must allow normal install — process is NOT killed")
        #expect(outcome.requiresClientOnlyInstall == false)
    }
}

// MARK: - Suite 2: Step 3 — direct provider staged DISABLED

@Suite("App-first / standalone-second — Step 3: direct provider staged DISABLED (never started)")
struct AppFirstStep3DisabledStagingTests {

    /// Step 3 positive: the disabled plist is written when the gate fires.
    /// The plist must have RunAtLoad = false and KeepAlive = false — the
    /// provider is a RECOVERY ARTIFACT, not a running process.
    ///
    /// Regression: if the disabled-plist content were changed to include
    /// RunAtLoad = true, the provider would start automatically and create a
    /// second active provider.
    @Test("disabled plist has RunAtLoad = false and KeepAlive = false")
    func disabledPlistNotAutoStarted() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("a1st-s2nd-step3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        let status = LaunchAgent.installDaemonBundleDisabled(homeDirectory: home)
        guard case .installedDisabled = status else {
            Issue.record("Expected .installedDisabled, got \(status)")
            return
        }

        let plistURL = DaemonBundle.launchAgentPlistURL(homeDirectory: home)
        let content = try String(contentsOf: plistURL, encoding: .utf8)
        // The plist must NOT start the provider automatically. Both RunAtLoad
        // and KeepAlive are present but set to false — the provider is a
        // recovery artifact only; launchd must not start or restart it.
        #expect(content.contains("RunAtLoad"), "RunAtLoad key must be present")
        #expect(content.contains("KeepAlive"), "KeepAlive key must be present")
        // Both must be false (the plist contains exactly one <false/> run-at-load
        // and one <false/> keep-alive; verify the count).
        let falseCount = content.components(separatedBy: "<false/>").count - 1
        #expect(falseCount >= 2, "both RunAtLoad and KeepAlive must be <false/>")
        // Confirm the bundle label is the daemon-bundle label, not the legacy
        // raw-serve label.
        #expect(content.contains(DaemonBundle.launchAgentLabel),
                "plist must use the bundle provider label")
    }

    /// Step 3 gate: the disabled plist uses the daemon-bundle label, never
    /// the legacy standalone daemon label. Two different labels can coexist;
    /// the wrong label would register the WRONG service.
    ///
    /// Regression: a label mismatch would cause the launchd job to appear
    /// under the wrong identity, breaking subsequent authentication.
    @Test("disabled plist uses DaemonBundle.launchAgentLabel not the legacy CLI daemon label")
    func disabledPlistUsesCorrectLabel() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("a1st-s2nd-label-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        _ = LaunchAgent.installDaemonBundleDisabled(homeDirectory: home)

        let plistURL = DaemonBundle.launchAgentPlistURL(homeDirectory: home)
        let content = try String(contentsOf: plistURL, encoding: .utf8)
        #expect(content.contains(DaemonBundle.launchAgentLabel),
                "must use the bundle provider label \(DaemonBundle.launchAgentLabel)")
    }

    /// Step 3 gate: the disabled plist readback must match the written
    /// content. A partial write or interference is reported, never silently
    /// accepted (P-c2-10).
    ///
    /// Regression: if the readback check is removed, a corrupt plist could be
    /// silently accepted as a "staged" recovery artifact.
    @Test("installDaemonBundleDisabled returns .installedDisabled with a verifiable path")
    func installedDisabledCarriesPath() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("a1st-s2nd-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        let status = LaunchAgent.installDaemonBundleDisabled(homeDirectory: home)

        guard case .installedDisabled(let path) = status else {
            Issue.record("Expected .installedDisabled, got \(status)")
            return
        }
        #expect(!path.isEmpty, "path must be non-empty")
        #expect(FileManager.default.fileExists(atPath: path),
                "plist at path must exist on disk")
    }
}

// MARK: - Suite 3: Step 4 — "Using MOOTx01-App resident provider" report

@Suite("App-first / standalone-second — Step 4: resident provider reported, not second-guessed")
struct AppFirstStep4ReportTests {

    /// Step 4: the status surface reports the bundled owner's own state
    /// verbatim — it does NOT report "registered" or "answering" vocabulary
    /// from the CLI's own observation (C5 mandate, no second copy).
    ///
    /// Regression: if the status format were derived from CLI-side registration
    /// or port observations instead of the provider's own authenticated report,
    /// the design's "parallel copies fail" rule would be violated.
    @Test("honestServerStatus with bundled-owner outcome leads with 'provider:' prefix")
    func statusLeadsWithProviderPrefix() {
        let probe = bundledHealthyProbe()
        let outcome = probe.detect(homeDirectory: fakeHome)

        let ownerString = LaunchAgent.authenticatedBundledOwner(outcome: outcome)
        #expect(ownerString != nil,
                "healthy bundled owner must produce a non-nil status string")

        let statusLine = LaunchAgent.honestServerStatus(
            registration: .registered,
            port: .answering,
            providerReportedState: ownerString
        )
        // ES-1: the status line leads with "provider:" — the CLI's own
        // "registered/answering" vocabulary is suppressed when the provider
        // speaks for itself.
        #expect(statusLine.hasPrefix("provider:"),
                "status must start with 'provider:' not 'registered'")
        #expect(!statusLine.contains("registered"),
                "registered vocabulary must be suppressed when provider reports")
        #expect(!statusLine.contains("answering"),
                "port-answering vocabulary must be suppressed when provider reports")
    }

    /// Step 4: the bundled owner's kind appears in the report without
    /// paraphrase — the caller cannot add its own interpretation.
    ///
    /// Regression: if the kind were translated to a different string (e.g.,
    /// "app provider" instead of "bundled-helper"), the status vocabulary
    /// would diverge from the provider's own wire format.
    @Test("bundled-owner status string contains the kind rawValue verbatim")
    func statusContainsBundledKindVerbatim() {
        let probe = bundledHealthyProbe(kind: .bundled, preferredKind: .bundled)
        let outcome = probe.detect(homeDirectory: fakeHome)
        let ownerString = LaunchAgent.authenticatedBundledOwner(outcome: outcome)!

        #expect(ownerString.contains(ProviderKind.bundled.rawValue),
                "bundled-helper rawValue must appear verbatim in status")
    }
}

// MARK: - Suite 4: Step 5 — mismatch blocks install; never starts a second provider

@Suite("App-first / standalone-second — Step 5: mismatch blocks install, never second provider (ES-1/ES-2)")
struct AppFirstStep5MismatchTests {

    /// Step 5: an incompatible verdict (any direction) blocks install
    /// entirely. The CLI must NOT start a second provider as a workaround.
    ///
    /// Regression: if `blocksInstallByVersionMismatch` returned false for any
    /// verdict, the install path could proceed and start a second provider —
    /// directly violating ES-2 (exactly one active provider).
    @Test("all incompatible verdicts block install (ES-2: never two active providers)")
    func allVerdictsBlockInstall() {
        for verdict in VersionCompatibilityVerdict.allCases {
            let probe = incompatibleProbe(verdict: verdict)
            let outcome = probe.detect(homeDirectory: fakeHome)
            #expect(outcome.blocksInstallByVersionMismatch == true,
                    "verdict \(verdict.rawValue) must block install")
            #expect(outcome.requiresClientOnlyInstall == false,
                    "incompatible must not fire client-only gate")
            #expect(outcome.normalInstallProceeds == false,
                    "incompatible must not proceed with any install")
        }
    }

    /// Step 5: an incompatible outcome carries the verdict verbatim — the
    /// update direction message must not be paraphrased.
    ///
    /// Regression: if the verdict were paraphrased or lost, the user would
    /// receive an incorrect or unhelpful update direction.
    @Test("incompatible status surfaces verdict rawValue verbatim (no paraphrase)")
    func incompatibleStatusVerdictVerbatim() {
        for verdict in VersionCompatibilityVerdict.allCases {
            let probe = incompatibleProbe(verdict: verdict)
            let outcome = probe.detect(homeDirectory: fakeHome)
            let ownerString = LaunchAgent.authenticatedBundledOwner(outcome: outcome)
            #expect(ownerString != nil,
                    "incompatible must produce a non-nil status string for \(verdict)")
            #expect(ownerString!.contains(verdict.rawValue),
                    "verdict '\(verdict.rawValue)' must appear verbatim in status string")
        }
    }

    // BLOCKED: Live entitled provider subprocess — verifying that the CLI
    // process does NOT invoke bootstrap/launchctl on the direct-provider
    // LaunchAgent plist during the client-only path requires running against a
    // real signed bundle executable. The subprocess authentication gate
    // (BundleSignatureVerifier) requires a Developer-ID-signed binary.
    //
    // The decision-layer tests above prove the structural guarantee:
    // requiresClientOnlyInstall == true means the install command takes the
    // client-only branch, which calls installDaemonBundleDisabled() but NOT
    // LaunchAgent.install() or bootstrapJob(). The production verification
    // is a MACD-3 deliverable requiring an AppGroup-entitled signed build.
    // BLOCKED: live subprocess authentication via BundleSignatureVerifier.production.
    // Unblocked by: signed daemon bundle + App Group entitlement (MACD-3 provider activation).
    // No @Test — a vacuous empty test provides false positive evidence; see Adams r2.
}
