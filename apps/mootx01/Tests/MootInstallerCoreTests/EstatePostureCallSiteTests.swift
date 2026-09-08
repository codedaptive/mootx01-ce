// EstatePostureCallSiteTests.swift
//
// Source-level drift guards over the mootx01 command files, which live in the
// executable target this test target cannot import. The at-rest posture is ONE
// decision in GeniusLocusKit (`EstateOpenPosture`); if a future edit re-inlines
// an estate open in one command, or the two estate-creating commands disagree
// about the `--no-encrypt` flag, these fail.

import Foundation
import Testing

@Suite("Estate posture call sites")
struct EstatePostureCallSiteTests {

    private var commands: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MootInstallerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // apps/mootx01
            .appendingPathComponent("Sources/mootx01/Commands")
    }

    @Test("serve, drain and dream resolve their posture through EstateOpenPosture")
    func openersUseTheSharedDecision() throws {
        for name in ["ServeCommand", "DrainCommand", "DreamCommand"] {
            let source = try String(contentsOf: commands.appendingPathComponent("\(name).swift"), encoding: .utf8)
            #expect(source.contains("EstateOpenPosture.resolve(for: estate)"),
                "\(name) must resolve its at-rest posture through the shared decision")
            #expect(source.contains("encryptionConfig:"),
                "\(name) must pass an encryptionConfig — omitting it silently takes the .plaintext default")
        }
    }

    @Test("install and db create expose the same --no-encrypt flag and write no marker")
    func installAndDbCreateShareTheFlag() throws {
        let install = try String(contentsOf: commands.appendingPathComponent("InstallCommand.swift"), encoding: .utf8)
        let db = try String(contentsOf: commands.appendingPathComponent("DbCommand.swift"), encoding: .utf8)
        #expect(install.contains("var noEncrypt: Bool = false"))
        #expect(db.contains("var noEncrypt: Bool = false"))
        #expect(!install.contains("writeEncryptionOptOut"))
        #expect(!db.contains("writeEncryptionOptOut"))
    }
}
