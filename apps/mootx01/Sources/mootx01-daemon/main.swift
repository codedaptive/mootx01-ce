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
// c1 modes (self-report, proof race) run to completion and start no run
// loop; the resident service mode is MACD-2c2's deliverable.
//
// MACD-3D EE composition root: MootDaemonFederation is linked only in the EE
// edition (see Package.swift — the EE mootx01-daemon target depends on both
// MootDaemonProvider AND MootDaemonFederation; the CE Package.community.swift
// variant omits MootDaemonFederation). The #if canImport guard ensures the CE
// build (which compiles this same source file via Package.community.swift) does
// not reference the EE-only token. Kong invariant 4: SHARED module never
// hard-codes "federation-sync"; the composition root injects it here.

import Foundation
import MootDaemonProvider

// MACD-3D: Collect EE-only capability tokens from MootDaemonFederation when
// it is linked (EE build). The CE build omits MootDaemonFederation from the
// mootx01-daemon target, so this block compiles away — #if canImport resolves
// at compile time based on the SPM target dependency graph.
#if canImport(MootDaemonFederation)
import MootDaemonFederation
private let eeExtraCapabilities: [String] = [FederationSyncCapabilities.token]
#else
private let eeExtraCapabilities: [String] = []
#endif

let exitCode = await DaemonShellMain.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    extraCapabilities: eeExtraCapabilities
)
exit(exitCode)
