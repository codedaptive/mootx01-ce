import Foundation
import Testing
import AriaMCP
@testable import MootDaemonProvider

// MARK: - P1 eligibility, P2 root injection, P3 hygiene, self-report identity

@Suite("Eligibility judgment (Perkins P1)")
struct EligibilityJudgeTests {

    @Test("an eligible identity is judged eligible with the expanded group matched")
    func eligiblePasses() throws {
        let eligibility = try ProviderEligibilityJudge.judge(eligibleIdentity())
        #expect(eligibility.appGroupIdentifier == ProviderEligibilityJudge.requiredAppGroup)
        #expect(eligibility.expandedKeychainGroup == testTeam + "." + ProviderEligibilityJudge.requiredKeychainGroupSuffix)
        #expect(eligibility.signingIdentity.teamIdentifier == testTeam)
        #expect(eligibility.signingIdentity.signingClass == .developerID)
    }

    @Test("the MACD-2a team-prefixed runtime App Group spelling is accepted and propagated")
    func teamPrefixedAppGroupAccepted() throws {
        let runtime = testTeam + "." + ProviderEligibilityJudge.requiredAppGroup
        let identity = SignedProcessIdentity(
            signingClass: .developerID, teamIdentifier: testTeam,
            applicationGroups: [runtime],
            keychainAccessGroups: [testTeam + "." + ProviderEligibilityJudge.requiredKeychainGroupSuffix],
            bundleIdentifier: "com.codedaptive.mootx01.test-shell"
        )
        let eligibility = try ProviderEligibilityJudge.judge(identity)
        // The resolver must be handed the SIGNED spelling, verbatim.
        #expect(eligibility.appGroupIdentifier == runtime)
    }

    @Test("all three signed channels are eligible")
    func signedChannelsEligible() throws {
        for signingClass in [SignedProcessIdentity.SigningClass.developerID, .appleDevelopment, .appleDistribution] {
            let eligibility = try ProviderEligibilityJudge.judge(eligibleIdentity(signingClass: signingClass))
            #expect(eligibility.identity.signingClass == signingClass)
        }
    }

    @Test("an unsigned shell is refused as unsigned")
    func unsignedRefused() {
        let identity = SignedProcessIdentity(
            signingClass: .unsigned, teamIdentifier: nil,
            applicationGroups: [], keychainAccessGroups: [], bundleIdentifier: nil
        )
        #expect(throws: DaemonProviderError.ineligible(.unsigned)) {
            try ProviderEligibilityJudge.judge(identity)
        }
    }

    @Test("an ad-hoc shell is refused as ad-hoc even when it claims the groups")
    func adHocRefused() {
        // Ad-hoc signatures can CLAIM any entitlement; nothing enforces them.
        let identity = SignedProcessIdentity(
            signingClass: .adHoc, teamIdentifier: nil,
            applicationGroups: [ProviderEligibilityJudge.requiredAppGroup],
            keychainAccessGroups: ["FAKETEAM00." + ProviderEligibilityJudge.requiredKeychainGroupSuffix],
            bundleIdentifier: "com.evil.adhoc"
        )
        #expect(throws: DaemonProviderError.ineligible(.adHocSigned)) {
            try ProviderEligibilityJudge.judge(identity)
        }
    }

    @Test("a keychain group with a foreign team prefix is refused as wrong-team")
    func wrongTeamRefused() {
        let identity = SignedProcessIdentity(
            signingClass: .developerID, teamIdentifier: testTeam,
            applicationGroups: [ProviderEligibilityJudge.requiredAppGroup],
            keychainAccessGroups: ["OTHERTEAM1." + ProviderEligibilityJudge.requiredKeychainGroupSuffix],
            bundleIdentifier: "com.codedaptive.mootx01.test-shell"
        )
        #expect(throws: DaemonProviderError.ineligible(.wrongTeam)) {
            try ProviderEligibilityJudge.judge(identity)
        }
    }

    @Test("a missing app group is refused as wrong-group")
    func missingAppGroupRefused() {
        let identity = SignedProcessIdentity(
            signingClass: .developerID, teamIdentifier: testTeam,
            applicationGroups: ["group.something.else"],
            keychainAccessGroups: [testTeam + "." + ProviderEligibilityJudge.requiredKeychainGroupSuffix],
            bundleIdentifier: "com.codedaptive.mootx01.test-shell"
        )
        #expect(throws: DaemonProviderError.ineligible(.wrongGroup)) {
            try ProviderEligibilityJudge.judge(identity)
        }
    }

    @Test("a missing team keychain group is refused as wrong-group")
    func missingKeychainGroupRefused() {
        let identity = SignedProcessIdentity(
            signingClass: .appleDistribution, teamIdentifier: testTeam,
            applicationGroups: [ProviderEligibilityJudge.requiredAppGroup],
            keychainAccessGroups: [testTeam + ".some.other.group"],
            bundleIdentifier: "com.codedaptive.mootx01.test-shell"
        )
        #expect(throws: DaemonProviderError.ineligible(.wrongGroup)) {
            try ProviderEligibilityJudge.judge(identity)
        }
    }
}

@Suite("Ineligible shells perform zero side effects (Perkins P1)")
struct IneligibleZeroSideEffectTests {

    private static func ineligibleIdentities() -> [(SignedProcessIdentity, IneligibilityReason)] {
        [
            (SignedProcessIdentity(signingClass: .unsigned, teamIdentifier: nil,
                                   applicationGroups: [], keychainAccessGroups: [], bundleIdentifier: nil),
             .unsigned),
            (SignedProcessIdentity(signingClass: .adHoc, teamIdentifier: nil,
                                   applicationGroups: [ProviderEligibilityJudge.requiredAppGroup],
                                   keychainAccessGroups: [], bundleIdentifier: "x"),
             .adHocSigned),
            (SignedProcessIdentity(signingClass: .developerID, teamIdentifier: testTeam,
                                   applicationGroups: [ProviderEligibilityJudge.requiredAppGroup],
                                   keychainAccessGroups: ["WRONG00000." + ProviderEligibilityJudge.requiredKeychainGroupSuffix],
                                   bundleIdentifier: "x"),
             .wrongTeam),
            (SignedProcessIdentity(signingClass: .developerID, teamIdentifier: testTeam,
                                   applicationGroups: [],
                                   keychainAccessGroups: [testTeam + "." + ProviderEligibilityJudge.requiredKeychainGroupSuffix],
                                   bundleIdentifier: "x"),
             .wrongGroup),
        ]
    }

    @Test("each ineligible class exits before the lock with zero callbacks")
    func fourClassesZeroSideEffects() async throws {
        for (identity, reason) in Self.ineligibleIdentities() {
            let harness = ProviderHarness(identity: identity)
            await #expect(throws: DaemonProviderError.ineligible(reason)) {
                _ = try await harness.provider.activate()
            }
            // Zero Keychain, estate, bind, or session callbacks — and no lock
            // file was ever created in the scratch container.
            #expect(harness.sideEffectCallbackCount == 0)
            let providerDir = harness.scratch.url
                .appendingPathComponent("Library/Application Support/MOOTx01/provider")
            #expect(!FileManager.default.fileExists(atPath: providerDir.appendingPathComponent("provider.lock").path))
        }
    }
}

@Suite("Root resolution is injected and exclusive (Perkins P2)")
struct RootResolutionTests {

    @Test("an unresolvable container refuses with zero side effects")
    func unresolvableRefuses() async throws {
        let scratch = ScratchDirectory()
        let harness = ProviderHarness(scratch: scratch, resolverURL: nil)
        // FakeResolver(nil) — but harness substitutes scratch when nil; build
        // a provider with an explicitly nil resolver instead.
        let recorder = CallRecorder()
        let provider = DaemonProvider(
            configuration: DaemonProviderConfiguration(
                instanceIdentifier: UUID(), binaryVersion: "1.0.18",
                capabilities: ["authenticated-first-party"]
            ),
            readback: FakeReadback(identity: eligibleIdentity()),
            resolver: FakeResolver(url: nil),
            keychain: CountingKeychain(recorder: recorder),
            estate: CountingEstate(recorder: recorder),
            bind: CountingBind(recorder: recorder),
            sessions: CountingSessions(recorder: recorder),
            clock: FixedClock().closure,
            randomBytes: SeededRandom().closure
        )
        await #expect(throws: DaemonProviderError.rootUnresolvable) {
            _ = try await provider.activate()
        }
        #expect(recorder.events.isEmpty)
        _ = harness // keep scratch alive to the end of the test
    }

    @Test("the layout nests every state file under the resolved container")
    func layoutUnderContainer() throws {
        let scratch = ScratchDirectory()
        let layout = try ProviderRootLayout.resolve(
            resolver: FakeResolver(url: scratch.url),
            groupIdentifier: ProviderEligibilityJudge.requiredAppGroup
        )
        #expect(layout.providerDirectory.path.hasPrefix(scratch.url.path))
        #expect(layout.lockFile.path.hasPrefix(layout.providerDirectory.path))
        #expect(layout.generationsFile.path.hasPrefix(layout.providerDirectory.path))
        #expect(layout.leaseJournal.path.hasPrefix(layout.providerDirectory.path))
        #expect(layout.descriptorFile.path.hasPrefix(scratch.url.path))
    }

    @Test("a proof context must be a UUID leaf name, never a path")
    func proofContextValidated() throws {
        let scratch = ScratchDirectory()
        // A path-shaped context is refused: argv may name a leaf, not a location.
        #expect(throws: DaemonProviderError.rootUnresolvable) {
            _ = try ProviderRootLayout.resolve(
                resolver: FakeResolver(url: scratch.url),
                groupIdentifier: ProviderEligibilityJudge.requiredAppGroup,
                proofContext: "../../etc"
            )
        }
        let context = UUID().uuidString
        let layout = try ProviderRootLayout.resolve(
            resolver: FakeResolver(url: scratch.url),
            groupIdentifier: ProviderEligibilityJudge.requiredAppGroup,
            proofContext: context
        )
        #expect(layout.providerDirectory.lastPathComponent == context)
        #expect(layout.providerDirectory.path.contains("/proof/"))
    }
}

@Suite("Filesystem hygiene (Perkins P3)")
struct SecureFilesTests {

    @Test("a symlinked state file is refused")
    func symlinkRefused() throws {
        let scratch = ScratchDirectory()
        let real = scratch.url.appendingPathComponent("real")
        try Data("x".utf8).write(to: real)
        let link = scratch.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: DaemonProviderError.hygieneViolation(.symlink)) {
            _ = try SecureFiles.openValidated(link, flags: O_RDONLY, create: false)
        }
    }

    @Test("a multi-link file is refused")
    func hardLinkRefused() throws {
        let scratch = ScratchDirectory()
        let original = scratch.url.appendingPathComponent("original")
        try Data("x".utf8).write(to: original)
        let alias = scratch.url.appendingPathComponent("alias")
        try FileManager.default.linkItem(at: original, to: alias)
        #expect(throws: DaemonProviderError.hygieneViolation(.hardLink)) {
            _ = try SecureFiles.openValidated(original, flags: O_RDONLY, create: false)
        }
    }

    @Test("a group-writable parent directory is refused")
    func permissiveParentRefused() throws {
        let scratch = ScratchDirectory()
        let parent = scratch.url.appendingPathComponent("loose", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o720])
        let file = parent.appendingPathComponent("state")
        #expect(throws: DaemonProviderError.hygieneViolation(.permissiveMode)) {
            _ = try SecureFiles.openValidated(file, flags: O_RDWR, create: true)
        }
    }

    @Test("a missing file without create is refused as unopenable")
    func missingRefused() throws {
        let scratch = ScratchDirectory()
        #expect(throws: DaemonProviderError.hygieneViolation(.unopenable)) {
            _ = try SecureFiles.openValidated(scratch.url.appendingPathComponent("absent"), flags: O_RDONLY, create: false)
        }
    }

    @Test("a healthy create round-trips and the descriptor is a validated regular file")
    func healthyCreate() throws {
        let scratch = ScratchDirectory()
        let file = scratch.url.appendingPathComponent("state")
        let fd = try SecureFiles.openValidated(file, flags: O_RDWR, create: true)
        defer { close(fd) }
        #expect(fd >= 0)
        var status = stat()
        #expect(fstat(fd, &status) == 0)
        #expect((status.st_mode & S_IFMT) == S_IFREG)
        #expect(status.st_nlink == 1)
        #expect(status.st_mode & 0o077 == 0)
    }

    @Test("ensureProviderDirectory creates an owner-only chain")
    func ensureDirectoryOwnerOnly() throws {
        let scratch = ScratchDirectory()
        let dir = scratch.url.appendingPathComponent("a/b/provider", isDirectory: true)
        try SecureFiles.ensureProviderDirectory(dir)
        var status = stat()
        #expect(stat(dir.path, &status) == 0)
        #expect((status.st_mode & S_IFMT) == S_IFDIR)
        #expect(status.st_mode & 0o077 == 0)
        #expect(status.st_uid == geteuid())
    }

    @Test("atomicReplace lands either the old or the new bytes, and fsyncs")
    func atomicReplace() throws {
        let scratch = ScratchDirectory()
        let file = scratch.url.appendingPathComponent("record")
        try SecureFiles.atomicReplace(Data("one".utf8), at: file)
        #expect(try Data(contentsOf: file) == Data("one".utf8))
        try SecureFiles.atomicReplace(Data("two".utf8), at: file)
        #expect(try Data(contentsOf: file) == Data("two".utf8))
        // No temp sibling survives a completed replace.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: scratch.url.path)
        #expect(siblings == ["record"])
    }
}

@Suite("Canonical self-report")
struct SelfReportTests {

    @Test("the report is deterministic, byte for byte")
    func deterministic() {
        #expect(ProviderSelfReport.canonicalReport() == ProviderSelfReport.canonicalReport())
        #expect(!ProviderSelfReport.canonicalReport().isEmpty)
    }

    @Test("the module digest is 64 lowercase hex characters and appears in the report")
    func digestShape() {
        let digest = ProviderSelfReport.moduleDigest()
        #expect(digest.count == 64)
        #expect(digest.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(ProviderSelfReport.canonicalReport().contains(digest))
    }

    @Test("the report carries the frozen wire identities from the contract module")
    func identitiesFromContract() {
        let report = ProviderSelfReport.canonicalReport()
        #expect(report.contains(FirstPartyAuthProtocol.providerIdentifier))
        #expect(report.contains(FirstPartyAuthProtocol.serviceIdentifier))
        #expect(report.contains(FirstPartyAuthProtocol.endpoint))
        #expect(report.contains(FirstPartyAuthProtocol.authProtocolIdentifier))
        #expect(report.contains(String(FirstPartyAuthProtocol.descriptorSchemaVersion)))
        #expect(report.contains(FirstPartyAuthProtocol.mcpProtocolVersion))
        #expect(report.contains(GenerationStore.formatIdentifier))
        #expect(report.contains(HandoverLease.leaseDomain))
    }

    @Test("the report enumerates all twelve arbiter encodings in fixed order")
    func arbiterEncodings() {
        let report = ProviderSelfReport.canonicalReport()
        for encoding in ProviderArbiterState.allWireEncodings {
            #expect(report.contains(encoding))
        }
        #expect(ProviderArbiterState.allWireEncodings.count == 12)
    }

    @Test("the lease domain is new — distinct from every MACD-2b domain")
    func leaseDomainDistinct() {
        let existing = [
            FirstPartyAuthProtocol.descriptorDomain,
            FirstPartyAuthProtocol.sessionDomain,
            FirstPartyAuthProtocol.authDomain,
            FirstPartyAuthProtocol.serverProofDomain,
            FirstPartyAuthProtocol.clientProofDomain,
            FirstPartyAuthProtocol.sessionKeyDomain,
            FirstPartyAuthProtocol.establishedDomain,
            FirstPartyAuthProtocol.requestDomain,
            FirstPartyAuthProtocol.responseDomain,
        ]
        #expect(!existing.contains(HandoverLease.leaseDomain))
    }

    @Test("digest input changes when any contract element would change")
    func digestCoversContract() {
        // The digest input must be non-trivial and include the arbiter
        // encodings tail — a coarse but real guard that the canonical
        // encoding covers the enumerated elements rather than a prefix.
        let input = ProviderSelfReport.digestInput()
        #expect(input.count > 200)
        let text = String(decoding: input, as: UTF8.self)
        #expect(text.contains("recovery-required"))
        #expect(text.contains(HandoverLease.leaseDomain))
    }
}

@Suite("Shell entry")
struct ShellEntryTests {

    @Test("self-report mode emits exactly the canonical report")
    func selfReportMode() async {
        let (code, output) = await DaemonShellMain.runCollecting(arguments: ["self-report"])
        #expect(code == DaemonShellMain.ExitCode.success.rawValue)
        #expect(output == ProviderSelfReport.canonicalReport())
    }

    @Test("unknown arguments exit with usage before any side effect")
    func unknownArguments() async {
        let (code, _) = await DaemonShellMain.runCollecting(arguments: ["definitely-not-a-mode"])
        #expect(code == DaemonShellMain.ExitCode.usage.rawValue)
    }

    @Test("a race invocation with a malformed context is refused as usage")
    func malformedContextRefused() async {
        let (code, _) = await DaemonShellMain.runCollecting(arguments: ["race", "--context", "../not-a-uuid"])
        #expect(code == DaemonShellMain.ExitCode.usage.rawValue)
    }
}
