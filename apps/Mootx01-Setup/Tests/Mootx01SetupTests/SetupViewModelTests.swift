// SetupViewModelTests.swift
//
// Wave 6, Defect B: the .pkg install path bypassed convergence entirely
// whenever nothing new needed selecting — the setup assistant only ever
// invoked `mootx01 install` from the interactive "Connect" flow, which is
// gated on the user selecting at least one client, and `detect()`
// deliberately pre-deselects already-wired clients. A machine upgraded via
// the .pkg with an already-wired Claude Code (Bob's exact case) therefore
// got zero convergence unless the user happened to select something anyway.
//
// This file tests `SetupViewModel.convergenceTargetIDs(for:)`, the pure
// function behind the fix: it decides which clients get silently
// re-converged the moment detection completes, independent of the
// interactive selection UI. It does NOT spawn the `mootx01` subprocess —
// `convergeAlreadyWired()`/`runInstall` remain untested at that level,
// matching the rest of this codebase's convention of not process-spawning
// in unit tests.

import Testing
import MootInstallerCore
@testable import Mootx01Setup

@Suite("SetupViewModel convergence targeting (Wave 6, Defect B)")
struct SetupViewModelTests {

    private func client(_ id: String) -> MCPClient {
        guard let found = MCPClients.supported.first(where: { $0.id == id }) else {
            fatalError("test fixture references an unknown client id: \(id)")
        }
        return found
    }

    private func item(_ id: String, selected: Bool, detected: Bool, wired: Bool) -> ClientItem {
        ClientItem(client: client(id), isSelected: selected, isDetected: detected, isAlreadyWired: wired)
    }

    @Test("already-wired clients are included regardless of selection state")
    func alreadyWiredIncludedRegardlessOfSelection() {
        let items = [
            // Bob's exact case: detected, already wired (via the plugin),
            // and — per detect()'s own pre-selection rule — NOT selected.
            item("claude-code", selected: false, detected: true, wired: true),
        ]
        #expect(SetupViewModel.convergenceTargetIDs(for: items) == ["claude-code"])
    }

    @Test("a newly-detected, unwired, unselected client is NOT included")
    func newUnselectedClientNotIncluded() {
        let items = [
            item("cursor", selected: false, detected: true, wired: false),
        ]
        #expect(SetupViewModel.convergenceTargetIDs(for: items).isEmpty,
                "a genuinely new connection must go through the interactive flow, not silent convergence")
    }

    @Test("a newly-detected client the user selected is NOT double-converged here")
    func selectedButNotYetWiredClientNotIncluded() {
        let items = [
            item("cursor", selected: true, detected: true, wired: false),
        ]
        #expect(SetupViewModel.convergenceTargetIDs(for: items).isEmpty,
                "install() already handles the user's selection; convergence is only for already-wired clients")
    }

    @Test("a clean machine with nothing detected converges nothing")
    func nothingDetectedConvergesNothing() {
        let items = [
            item("cursor", selected: false, detected: false, wired: false),
            item("codex", selected: false, detected: false, wired: false),
        ]
        #expect(SetupViewModel.convergenceTargetIDs(for: items).isEmpty)
    }

    @Test("mixed fixture: only the already-wired clients are targeted")
    func mixedFixtureTargetsOnlyAlreadyWired() {
        let items = [
            item("claude-code", selected: false, detected: true, wired: true),
            item("cursor", selected: true, detected: true, wired: false),
            item("codex", selected: false, detected: false, wired: false),
        ]
        #expect(SetupViewModel.convergenceTargetIDs(for: items) == ["claude-code"])
    }

    @Test("multiple already-wired clients are all targeted")
    func multipleAlreadyWiredClientsAllTargeted() {
        let items = [
            item("claude-code", selected: false, detected: true, wired: true),
            item("codex", selected: false, detected: true, wired: true),
        ]
        #expect(SetupViewModel.convergenceTargetIDs(for: items) == ["claude-code", "codex"])
    }

    @Test("empty client list converges nothing")
    func emptyClientListConvergesNothing() {
        #expect(SetupViewModel.convergenceTargetIDs(for: []).isEmpty)
    }
}
