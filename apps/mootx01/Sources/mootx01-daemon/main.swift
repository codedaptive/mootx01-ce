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

import Foundation
import MootDaemonProvider
import MootCommunityDaemon

let exitCode = await DaemonShellMain.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    residentActivate: CommunityResidentMain.run
)
exit(exitCode)
