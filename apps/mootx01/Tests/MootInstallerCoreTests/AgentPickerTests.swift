// AgentPickerTests.swift
//
// Tests for AgentPicker: explicit --target list validation and the
// --yes / non-interactive auto-detect path. Interactive prompts
// are not tested here (they require a TTY).

import Testing
import Foundation
@testable import MootInstallerCore

@Suite("AgentPicker")
struct AgentPickerTests {

    // MARK: - Explicit target list

    @Test("pick with target 'claude-desktop' returns that client")
    func pickExplicitSingle() throws {
        let home = makeSandboxHome()
        defer { cleanupSandbox(home) }

        let result = try AgentPicker.pick(yes: false, target: "claude-desktop", homeDirectory: home)
        #expect(result.count == 1)
        #expect(result.first?.id == "claude-desktop")
    }

    @Test("pick with target 'claude-desktop,cursor' returns both clients")
    func pickExplicitMultiple() throws {
        let home = makeSandboxHome()
        defer { cleanupSandbox(home) }

        let result = try AgentPicker.pick(yes: false, target: "claude-desktop,cursor", homeDirectory: home)
        let ids = result.map { $0.id }
        #expect(ids.contains("claude-desktop"))
        #expect(ids.contains("cursor"))
        #expect(result.count == 2)
    }

    @Test("pick with unknown target id throws unknownClient error")
    func pickUnknownClientThrows() {
        let home = makeSandboxHome()
        defer { cleanupSandbox(home) }

        #expect(throws: AgentPickerError.self) {
            _ = try AgentPicker.pick(yes: false, target: "nonexistent", homeDirectory: home)
        }
    }

    @Test("pick with target handles whitespace around commas")
    func pickExplicitWithWhitespace() throws {
        let home = makeSandboxHome()
        defer { cleanupSandbox(home) }

        let result = try AgentPicker.pick(yes: false, target: "claude-desktop , cursor", homeDirectory: home)
        #expect(result.count == 2)
    }

    // MARK: - --yes mode (non-interactive, auto-detect)

    @Test("pick with yes=true returns all detected clients")
    func pickYesReturnsDetected() throws {
        let home = makeSandboxHome()
        defer { cleanupSandbox(home) }

        // Plant a .claude.json so claude-code is detected.
        try "{}".write(
            to: home.appendingPathComponent(".claude.json"),
            atomically: true, encoding: .utf8
        )

        // Plant a .continue directory so continue is detected.
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".continue"),
            withIntermediateDirectories: true
        )

        let result = try AgentPicker.pick(yes: true, target: nil, homeDirectory: home)
        let ids = result.map { $0.id }
        #expect(ids.contains("claude-code"))
        #expect(ids.contains("continue"))
    }

    @Test("pick with yes=true and empty sandbox returns no relative-detectPath clients")
    func pickYesEmptySandboxRelativeOnly() throws {
        let home = makeSandboxHome()
        defer { cleanupSandbox(home) }

        // Clients with absolute detectPaths (e.g. /Applications/Claude.app) may be
        // detected regardless of sandbox home — they check real filesystem paths.
        // Clients with relative detectPaths (claude-code: .claude.json, continue:
        // .continue, cline: .vscode/extensions) must NOT appear in an empty sandbox.
        let result = try AgentPicker.pick(yes: true, target: nil, homeDirectory: home)
        let relativeDetectedIDs = result
            .filter { ($0.detectPath.map { !$0.hasPrefix("/") }) ?? false }
            .map { $0.id }
        #expect(!relativeDetectedIDs.contains("claude-code"))
        #expect(!relativeDetectedIDs.contains("continue"))
        #expect(!relativeDetectedIDs.contains("cline"))
    }

    // MARK: - Helpers

    private func makeSandboxHome() -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpicker-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func cleanupSandbox(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
