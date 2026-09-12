// MACD-2c1 — the thin daemon shell.
//
// This file is deliberately as small as a shell can be: every behavior,
// constant, and encoding lives in MootDaemonProvider, so the Developer-ID
// direct artifact (this SPM executable, wrapped app-like at signing time)
// and the sandboxed nested helper (Mootx01-DaemonProviderHelper-macOS in
// apps/Mootx01-App/project.yml, which compiles THIS SAME FILE) differ only
// in packaging and signature — never in substance. That is Kong K2's
// structural digest identity: the mission's cross-shell self-report assertion
// holds because there is exactly one module for the two shells to report.
//
// Wave A1b: `residentActivate` is now wired to `CommunityResidentMain.run`
// so the `resident` mode runs the real production loop instead of exit 4.
// Shell substance stays here; the loop lives in MootCommunityDaemon.
//
// MACD-3D EE composition root: MootDaemonFederation is linked only in the EE
// edition (see Package.swift — the EE mootx01-daemon target depends on both
// MootDaemonProvider AND MootDaemonFederation; the CE Package.community.swift
// variant omits MootDaemonFederation). The #if canImport guard ensures the CE
// build (which compiles this same source file via Package.community.swift) does
// not reference the EE-only token. Kong invariant 4: SHARED module never
// hard-codes "federation-sync"; the composition root injects it here.

import Foundation
import AriaMCP
import MootDaemonProvider
import MootCommunityDaemon

// MACD-3D: Collect EE-only capability tokens from MootDaemonFederation when
// it is linked (EE build). The CE build omits MootDaemonFederation from the
// mootx01-daemon target, so this block compiles away — #if canImport resolves
// at compile time based on the SPM target dependency graph.
#if canImport(MootDaemonFederation)
import MootDaemonFederation
private let federationCapabilities: [String] = [FederationSyncCapabilities.token]
#else
private let federationCapabilities: [String] = []
#endif

#if canImport(MootProductDock)
import MootProductDock
private let productDockCapabilities: [String] = [ProductDock.capabilityToken]
private let stableFirstPartyProvider = FirstPartyProviderExecutor()
private func runResident() async -> (code: Int32, output: String) {
    await CommunityResidentMain.run(
        additionalCapabilities: eeExtraCapabilities,
        firstPartyToolHost: ProductDock.shared,
        firstPartyProvider: stableFirstPartyProvider
    )
}
#else
private let productDockCapabilities: [String] = []
private let stableFirstPartyProvider = FirstPartyProviderExecutor()
private func runResident() async -> (code: Int32, output: String) {
    await CommunityResidentMain.run(
        additionalCapabilities: eeExtraCapabilities,
        firstPartyProvider: stableFirstPartyProvider)
}
#endif

// Every descriptor-producing shell path must make the same edition claim.
// ProductDock is process infrastructure, not a resident-mode-only feature, so
// race/census probes and the real resident descriptor receive one exact list.
private let eeExtraCapabilities = federationCapabilities + productDockCapabilities

let exitCode = await DaemonShellMain.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    extraCapabilities: eeExtraCapabilities,
    residentActivate: runResident
)
exit(exitCode)
