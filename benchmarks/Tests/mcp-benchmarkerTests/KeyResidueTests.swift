import Testing
import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif
@testable import mcp_benchmarker

// KeyResidueTests — the key lifecycle around scratch estate retirement
// (P1.1b): probe collection, teardown, and the zero-residual assertion.
// Pure by default: file-system probes run against real temp dirs; the one
// test that touches the real macOS Keychain is OPT-IN via
// MOOT_BENCH_LIVE_KEYCHAIN=1, following the live-E2E guard convention, so
// the suite stays green on any machine without side effects.

@Suite("Key residue — account contract")
struct KeyResidueAccountTests {

    @Test("account derivation matches the product contract shape")
    func accountShape() {
        // Contract: "estate-db-key." + SHA-256 hex of the STANDARDIZED path
        // (KeychainKeyStore.estateAccount(for:)). 64 hex chars, stable.
        let account = estateDbKeyAccount(forEstatePath: "/tmp/kr-test/estate.sqlite")
        #expect(account.hasPrefix("estate-db-key."))
        #expect(account.count == "estate-db-key.".count + 64)
        let hexPart = account.dropFirst("estate-db-key.".count)
        #expect(hexPart.allSatisfy { $0.isHexDigit && (!$0.isLetter || $0.isLowercase) })
    }

    @Test("path standardization: dot segments and trailing slashes collapse to one account")
    func standardization() {
        let canonical = estateDbKeyAccount(forEstatePath: "/tmp/kr-test/estate.sqlite")
        #expect(estateDbKeyAccount(forEstatePath: "/tmp/kr-test/./estate.sqlite") == canonical)
        #expect(estateDbKeyAccount(forEstatePath: "/tmp/kr-test/sub/../estate.sqlite") == canonical)
        // Distinct estates get distinct accounts.
        #expect(estateDbKeyAccount(forEstatePath: "/tmp/kr-other/estate.sqlite") != canonical)
    }
}

@Suite("Key residue — probe collection and retirement")
struct KeyResidueLifecycleTests {

    private func makeScratch(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kr-\(name)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("estates/default"),
            withIntermediateDirectories: true)
        return dir
    }

    @Test("probes find nested estate files and db.key, plus the default estate account")
    func probeCollection() throws {
        let dir = try makeScratch("probe")
        defer { try? FileManager.default.removeItem(at: dir) }
        let estateFile = dir.appendingPathComponent("estates/default/estate.sqlite")
        try Data("data".utf8).write(to: estateFile)
        try Data(repeating: 0x6b, count: 32)
            .write(to: dir.appendingPathComponent("estates/default/db.key"))

        let probes = collectKeyResidueProbes(scratchDir: dir)
        #expect(probes.keyFilePaths.count == 1)
        #expect(probes.keyFilePaths[0].hasSuffix("estates/default/db.key"))
        // One account for the found estate file, one for the default estate path.
        #expect(probes.keychainAccounts.contains(
            estateDbKeyAccount(forEstatePath: estateFile.path)))
        #expect(probes.keychainAccounts.contains(
            estateDbKeyAccount(forEstatePath: dir.appendingPathComponent("estate.sqlite").path)))
        #expect(probes.keychainAccounts.count == 2)
    }

    @Test("retirement removes the key with the estate — zero residue")
    func cleanRetirement() throws {
        let dir = try makeScratch("clean")
        try Data(repeating: 0x6b, count: 32)
            .write(to: dir.appendingPathComponent("estates/default/db.key"))
        let probes = collectKeyResidueProbes(scratchDir: dir)
        // Teardown = whole-dir removal, exactly what the runners do.
        try FileManager.default.removeItem(at: dir)
        let report = verifyZeroKeyResidue(after: probes)
        #expect(report.isClean, "expected zero residue, got \(report)")
    }

    @Test("residual key file after a failed teardown is detected")
    func dirtyRetirementDetected() throws {
        let dir = try makeScratch("dirty")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 0x6b, count: 32)
            .write(to: dir.appendingPathComponent("estates/default/db.key"))
        let probes = collectKeyResidueProbes(scratchDir: dir)
        // No teardown performed — everything must be reported.
        let report = verifyZeroKeyResidue(after: probes)
        #expect(!report.isClean)
        #expect(report.keyFilesRemaining.count == 1)
        #expect(report.scratchDirRemaining)
    }

    @Test("missing dir probes empty and verifies clean")
    func missingDir() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kr-never-created-\(UUID().uuidString.prefix(8))")
        let probes = collectKeyResidueProbes(scratchDir: dir)
        #expect(probes.keyFilePaths.isEmpty)
        // The default-estate account is still probed (a keychain item can
        // outlive a dir that was never fully created).
        #expect(probes.keychainAccounts.count == 1)
        #expect(verifyZeroKeyResidue(after: probes).isClean)
    }

    @Test("retireScratchEstate runs the supplied teardown")
    func retireRunsTeardown() throws {
        let dir = try makeScratch("retire")
        retireScratchEstate(dir) { url in
            try? FileManager.default.removeItem(at: url)
        }
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}

#if canImport(Security)
@Suite("Key residue — live Keychain purge (opt-in)")
struct KeyResidueLiveKeychainTests {

    /// Opt-in guard, following the live-E2E convention: the test self-skips
    /// (never fails) unless MOOT_BENCH_LIVE_KEYCHAIN=1, because it writes and
    /// removes a real generic-password item in the moot service.
    private static var liveEnabled: Bool {
        ProcessInfo.processInfo.environment["MOOT_BENCH_LIVE_KEYCHAIN"] == "1"
    }

    @Test("planted keychain item is found, purged, and reported",
          .enabled(if: liveEnabled, "opt-in: set MOOT_BENCH_LIVE_KEYCHAIN=1 to run"))
    func plantAndPurge() throws {
        // A synthetic estate path no product run would ever use.
        let fakeEstate = "/tmp/kr-live-\(UUID().uuidString)/estate.sqlite"
        let account = estateDbKeyAccount(forEstatePath: fakeEstate)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: mootKeychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(repeating: 0x6b, count: 32),
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        #expect(addStatus == errSecSuccess, "SecItemAdd failed: \(addStatus)")
        #expect(keychainItemExists(account: account))

        let probes = KeyResidueProbes(
            keychainAccounts: [account], keyFilePaths: [],
            scratchDirPath: "/tmp/kr-live-nonexistent",
            identityItemCountBefore: mootIdentityItemCount())
        let report = verifyZeroKeyResidue(after: probes)
        // The verifier PURGES what it finds and reports the account.
        #expect(report.keychainItemsFoundAndPurged == [account])
        #expect(report.keychainItemsUnremovable.isEmpty)
        #expect(!keychainItemExists(account: account),
                "item must be gone after purge — zero residual key material")
    }
}
#endif
