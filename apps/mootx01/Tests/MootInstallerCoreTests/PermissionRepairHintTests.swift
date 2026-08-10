import Foundation
import Testing
@testable import MootInstallerCore

/// The 2026-08-05 install failure surfaced as a bare NSError and took a person
/// reading directory ownership by hand to diagnose. These pin the message so the
/// binary explains it instead, and pin the negative case so an unrelated failure
/// never gets a misleading repair suggestion.
@Suite struct PermissionRepairHintTests {
    private let home = URL(fileURLWithPath: "/Users/testuser")

    /// The exact error class the reporter hit: EPERM on removing the PATH symlink,
    /// surfaced by Foundation as NSCocoaErrorDomain 513.
    private func permissionError() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: 513,
                userInfo: [NSFilePathErrorKey: "/Users/testuser/.local/bin/mootx01"])
    }

    @Test("a permission failure yields a hint naming both directories to repair")
    func hintNamesBothDirectories() throws {
        let hint = try #require(Installer.permissionRepairHint(for: permissionError(),
                                                              homeDirectory: home))
        // Assert on the chown LINE, with both paths as distinct QUOTED arguments.
        // Checking hint.contains("~/.local") and hint.contains("~/.local/bin")
        // separately proves nothing — the second string contains the first, so the
        // pair passes even when only the longer path is present. A mutation that
        // dropped the parent directory from the chown slipped through exactly that
        // way before this was tightened.
        let chownLine = try #require(
            hint.split(separator: "\n").first { $0.contains("sudo chown") }.map(String.init))
        #expect(chownLine.contains("\"/Users/testuser/.local\""))
        #expect(chownLine.contains("\"/Users/testuser/.local/bin\""))
        // It must name the re-run command, not just the repair.
        #expect(hint.contains("mootx01"))
        #expect(hint.contains("install"))
    }

    @Test("the hint promises only the two directories are touched")
    func hintScopesTheChown() throws {
        let hint = try #require(Installer.permissionRepairHint(for: permissionError(),
                                                              homeDirectory: home))
        // ~/.local is shared with pipx, cargo and others; a recursive chown would
        // be a worse bug than the one being repaired, so the text must not imply one.
        #expect(!hint.contains("chown -R"))
        #expect(hint.contains("nothing else"))
    }

    @Test("an unrelated error yields no hint")
    func unrelatedErrorGivesNoHint() {
        let notFound = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        #expect(Installer.permissionRepairHint(for: notFound, homeDirectory: home) == nil)
        let network = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(Installer.permissionRepairHint(for: network, homeDirectory: home) == nil)
    }

    @Test("the hint uses the supplied home, not the running user's")
    func hintUsesSuppliedHome() throws {
        let other = URL(fileURLWithPath: "/Users/michaelmennenga")
        let hint = try #require(Installer.permissionRepairHint(for: permissionError(),
                                                              homeDirectory: other))
        #expect(hint.contains("/Users/michaelmennenga/.local"))
        #expect(!hint.contains("/Users/testuser"))
    }
}
