// ClientDetectionTests.swift
//
// Swift Testing suite for MCPClient.detectPath and isPresent.
// Covers: non-nil detectPath for all supported entries, isPresent
// false in an empty sandbox, true when the mock probe path exists.
// Uses a temporary directory as a sandboxed home to keep tests
// hermetic — no real ~/.continue or /Applications access.

import Testing
@testable import MootInstallerCore
import Foundation

@Suite("MCPClient detection")
struct ClientDetectionTests {

    // MARK: - detectPath population

    @Test("all supported entries have a non-nil detectPath")
    func allEntriesHaveDetectPath() {
        for client in MCPClients.supported {
            #expect(client.detectPath != nil, "expected \(client.id) to have a detectPath")
        }
    }

    @Test("claude-desktop detectPath is /Applications/Claude.app")
    func claudeDesktopDetectPath() throws {
        let client = try requiredClient("claude-desktop")
        #expect(client.detectPath == "/Applications/Claude.app")
    }

    @Test("claude-code detectPath is .claude.json")
    func claudeCodeDetectPath() throws {
        let client = try requiredClient("claude-code")
        #expect(client.detectPath == ".claude.json")
    }

    @Test("cursor detectPath is /Applications/Cursor.app")
    func cursorDetectPath() throws {
        let client = try requiredClient("cursor")
        #expect(client.detectPath == "/Applications/Cursor.app")
    }

    @Test("cline detectPath is .vscode/extensions")
    func clineDetectPath() throws {
        let client = try requiredClient("cline")
        #expect(client.detectPath == ".vscode/extensions")
    }

    @Test("continue detectPath is .continue")
    func continueDetectPath() throws {
        let client = try requiredClient("continue")
        #expect(client.detectPath == ".continue")
    }

    // MARK: - isPresent: nil detectPath

    @Test("nil detectPath always returns true regardless of home")
    func nilDetectPathAlwaysPresent() {
        let alwaysWire = MCPClient(
            id: "test", displayName: "Test",
            configPath: "some/path.json", serverName: "test",
            detectPath: nil
        )
        // homeDirectory deliberately points at a non-existent path
        let noSuchDir = URL(fileURLWithPath: "/no/such/path/\(ProcessInfo.processInfo.globallyUniqueString)")
        #expect(alwaysWire.isPresent(homeDirectory: noSuchDir))
    }

    // MARK: - isPresent: Continue (.continue directory)

    @Test("continue isPresent returns false in empty sandbox")
    func continueAbsentInEmptySandbox() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = try requiredClient("continue")
        #expect(!client.isPresent(homeDirectory: home))
    }

    @Test("continue isPresent returns true when .continue directory exists")
    func continuePresentWhenDirectoryExists() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".continue"),
            withIntermediateDirectories: true
        )

        let client = try requiredClient("continue")
        #expect(client.isPresent(homeDirectory: home))
    }

    // MARK: - isPresent: Claude Code (.claude.json file)

    @Test("claude-code isPresent returns false without .claude.json in empty sandbox")
    func claudeCodeAbsentInEmptySandbox() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = try requiredClient("claude-code")
        #expect(!client.isPresent(homeDirectory: home))
    }

    @Test("claude-code isPresent returns true when .claude.json exists")
    func claudeCodePresentWhenConfigExists() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        try "{}".write(
            to: home.appendingPathComponent(".claude.json"),
            atomically: true,
            encoding: .utf8
        )

        let client = try requiredClient("claude-code")
        #expect(client.isPresent(homeDirectory: home))
    }

    // MARK: - isPresent: Cline (VS Code extension glob)

    @Test("cline isPresent returns false without extensions directory in empty sandbox")
    func clineAbsentInEmptySandbox() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = try requiredClient("cline")
        #expect(!client.isPresent(homeDirectory: home))
    }

    @Test("cline isPresent returns false when extensions directory has no matching entry")
    func clineAbsentWhenExtensionsDirExistsButNoMatch() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        // Create the extensions directory with an unrelated extension
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".vscode/extensions/other.extension-1.0.0"),
            withIntermediateDirectories: true
        )

        let client = try requiredClient("cline")
        #expect(!client.isPresent(homeDirectory: home))
    }

    @Test("cline isPresent returns true when saoudrizwan.claude-dev-* extension is present")
    func clinePresentWhenExtensionMatches() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        // Version suffix varies across installs; use a representative version
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".vscode/extensions/saoudrizwan.claude-dev-4.1.0"),
            withIntermediateDirectories: true
        )

        let client = try requiredClient("cline")
        #expect(client.isPresent(homeDirectory: home))
    }

    // MARK: - Helpers

    private func requiredClient(_ id: String) throws -> MCPClient {
        guard let client = MCPClients.supported.first(where: { $0.id == id }) else {
            Issue.record("client '\(id)' not found in MCPClients.supported")
            throw TestFailure()
        }
        return client
    }

    private func makeSandboxHome() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mootx01-test-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func cleanupSandbox(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

// Minimal error used to break out of a test helper that discovers a
// missing fixture. Separate from MOOTx01Error because MootInstallerCore
// does not define that enum — this is test-only scaffolding.
private struct TestFailure: Error {}
