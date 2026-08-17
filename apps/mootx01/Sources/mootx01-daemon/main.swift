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

import Foundation
import MootDaemonProvider

let exitCode = await DaemonShellMain.run(arguments: Array(CommandLine.arguments.dropFirst()))
exit(exitCode)
