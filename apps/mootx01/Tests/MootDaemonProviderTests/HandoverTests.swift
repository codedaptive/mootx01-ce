import Foundation
import Testing
import AriaMCP
@testable import MootDaemonProvider

// MARK: - P9 lease custody and the eight-step handover

private let leaseRoot = [UInt8](repeating: 5, count: 32)

private func makeLeaseAuthority(
    scratch: ScratchDirectory, clock: FixedClock = FixedClock(), random: SeededRandom = SeededRandom()
) -> LeaseAuthority {
    LeaseAuthority(
        journal: LeaseConsumptionJournal(fileURL: scratch.url.appendingPathComponent("lease.journal")),
        clock: clock.closure,
        randomBytes: random.closure
    )
}

private let sourceIdentity = SigningIdentityDescriptor(
    teamIdentifier: testTeam, bundleIdentifier: "com.codedaptive.mootx01.source", signingClass: .developerID
)
private let targetIdentity = SigningIdentityDescriptor(
    teamIdentifier: testTeam, bundleIdentifier: "com.codedaptive.mootx01.target", signingClass: .appleDistribution
)
private let leaseEstate = EstateReadyProof(
    estateIdentifier: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!, schemaVersion: 12
)
private let leaseGenerations = ProviderGenerations(credential: 1, provider: 2, descriptor: 3)
private let targetInstance = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

private func issuedLease(
    authority: LeaseAuthority, sourceInstance: UUID = UUID()
) -> HandoverLease {
    authority.issue(
        estate: leaseEstate,
        sourceInstance: sourceInstance, targetInstance: targetInstance,
        sourceIdentity: sourceIdentity, targetIdentity: targetIdentity,
        generations: leaseGenerations,
        installationRoot: leaseRoot
    )
}

@Suite("Handover lease custody (Perkins P9)")
struct HandoverLeaseTests {

    @Test("an issued lease is sealed, expiring, and bound")
    func issueShape() {
        let scratch = ScratchDirectory()
        let clock = FixedClock(2_000_000_000)
        let authority = makeLeaseAuthority(scratch: scratch, clock: clock)
        let lease = issuedLease(authority: authority)
        #expect(lease.issuedAt == 2_000_000_000)
        #expect(lease.expiresAt == 2_000_000_000 + HandoverLease.leaseLifetime)
        #expect(lease.nonce.count == 32)
        #expect(lease.leaseMAC.count == FirstPartyAuthProtocol.macByteCount)
        #expect(lease.verifyMAC(installationRoot: leaseRoot))
        #expect(lease.credentialGeneration == 1)
        #expect(lease.providerGeneration == 2)
        #expect(lease.descriptorGeneration == 3)
    }

    @Test("the lease key is domain-separated from every descriptor-ladder key")
    func leaseKeyDistinct() {
        let leaseKey = HandoverLease.leaseKey(installationRoot: leaseRoot)
        #expect(leaseKey != FirstPartyAuthProtocol.descriptorKey(installationRoot: leaseRoot))
        #expect(leaseKey.count == 32)
    }

    @Test("tampering with any bound field breaks the MAC")
    func tamperBreaksMAC() {
        let scratch = ScratchDirectory()
        let authority = makeLeaseAuthority(scratch: scratch)
        let lease = issuedLease(authority: authority)

        var wrongEstate = lease
        wrongEstate = HandoverLease(
            leaseIdentifier: lease.leaseIdentifier, estateIdentifier: UUID(),
            estateSchemaVersion: lease.estateSchemaVersion,
            sourceInstance: lease.sourceInstance, targetInstance: lease.targetInstance,
            sourceIdentity: lease.sourceIdentity, targetIdentity: lease.targetIdentity,
            credentialGeneration: lease.credentialGeneration,
            providerGeneration: lease.providerGeneration,
            descriptorGeneration: lease.descriptorGeneration,
            issuedAt: lease.issuedAt, expiresAt: lease.expiresAt,
            nonce: lease.nonce, leaseMAC: lease.leaseMAC
        )
        #expect(!wrongEstate.verifyMAC(installationRoot: leaseRoot))

        var laterExpiry = lease
        laterExpiry = HandoverLease(
            leaseIdentifier: lease.leaseIdentifier, estateIdentifier: lease.estateIdentifier,
            estateSchemaVersion: lease.estateSchemaVersion,
            sourceInstance: lease.sourceInstance, targetInstance: lease.targetInstance,
            sourceIdentity: lease.sourceIdentity, targetIdentity: lease.targetIdentity,
            credentialGeneration: lease.credentialGeneration,
            providerGeneration: lease.providerGeneration,
            descriptorGeneration: lease.descriptorGeneration,
            issuedAt: lease.issuedAt, expiresAt: lease.expiresAt + 3600,
            nonce: lease.nonce, leaseMAC: lease.leaseMAC
        )
        #expect(!laterExpiry.verifyMAC(installationRoot: leaseRoot))

        var wrongMAC = lease
        wrongMAC.leaseMAC[0] ^= 0x01
        #expect(!wrongMAC.verifyMAC(installationRoot: leaseRoot))
    }

    @Test("the durable record round-trips and refuses malformed input")
    func encodeDecode() {
        let scratch = ScratchDirectory()
        let authority = makeLeaseAuthority(scratch: scratch)
        let lease = issuedLease(authority: authority)
        #expect(HandoverLease.decode(lease.encoded()) == lease)
        #expect(HandoverLease.decode(Data("nope".utf8)) == nil)
        #expect(HandoverLease.decode(Data()) == nil)
    }

    @Test("a valid lease consumes exactly once; the journal survives a crash")
    func singleUse() throws {
        let scratch = ScratchDirectory()
        let authority = makeLeaseAuthority(scratch: scratch)
        let lease = issuedLease(authority: authority)
        let proof = try authority.consume(
            lease, installationRoot: leaseRoot, asTarget: targetIdentity,
            targetInstance: targetInstance, currentGenerations: leaseGenerations
        )
        #expect(proof == leaseEstate)

        // Second consumption refuses.
        #expect(throws: DaemonProviderError.leaseInvalid(.consumed)) {
            _ = try authority.consume(
                lease, installationRoot: leaseRoot, asTarget: targetIdentity,
                targetInstance: targetInstance, currentGenerations: leaseGenerations
            )
        }

        // "Crash": a brand-new authority over the same journal file — the
        // durable record, not process memory, is what enforces single use.
        let reborn = makeLeaseAuthority(scratch: scratch)
        #expect(throws: DaemonProviderError.leaseInvalid(.consumed)) {
            _ = try reborn.consume(
                lease, installationRoot: leaseRoot, asTarget: targetIdentity,
                targetInstance: targetInstance, currentGenerations: leaseGenerations
            )
        }
    }

    @Test("an expired lease refuses on the injected clock")
    func expiry() {
        let scratch = ScratchDirectory()
        let clock = FixedClock(3_000_000_000)
        let authority = makeLeaseAuthority(scratch: scratch, clock: clock)
        let lease = issuedLease(authority: authority)
        clock.advance(by: HandoverLease.leaseLifetime + 1)
        #expect(throws: DaemonProviderError.leaseInvalid(.expired)) {
            _ = try authority.consume(
                lease, installationRoot: leaseRoot, asTarget: targetIdentity,
                targetInstance: targetInstance, currentGenerations: leaseGenerations
            )
        }
    }

    @Test("a forged MAC refuses before anything else")
    func forgedMAC() {
        let scratch = ScratchDirectory()
        let authority = makeLeaseAuthority(scratch: scratch)
        var lease = issuedLease(authority: authority)
        lease.leaseMAC = [UInt8](repeating: 0xAA, count: 32)
        #expect(throws: DaemonProviderError.leaseInvalid(.badMAC)) {
            _ = try authority.consume(
                lease, installationRoot: leaseRoot, asTarget: targetIdentity,
                targetInstance: targetInstance, currentGenerations: leaseGenerations
            )
        }
    }

    @Test("binding refuses a wrong consumer identity or instance")
    func bindingMismatch() {
        let scratch = ScratchDirectory()
        let authority = makeLeaseAuthority(scratch: scratch)
        let lease = issuedLease(authority: authority)
        #expect(throws: DaemonProviderError.leaseInvalid(.bindingMismatch)) {
            _ = try authority.consume(
                lease, installationRoot: leaseRoot,
                asTarget: sourceIdentity, // wrong identity: the source itself
                targetInstance: targetInstance, currentGenerations: leaseGenerations
            )
        }
        #expect(throws: DaemonProviderError.leaseInvalid(.bindingMismatch)) {
            _ = try authority.consume(
                lease, installationRoot: leaseRoot, asTarget: targetIdentity,
                targetInstance: UUID(), // wrong instance
                currentGenerations: leaseGenerations
            )
        }
    }

    @Test("a stale generation refuses — rotation and republication burn leases")
    func staleGenerations() {
        let scratch = ScratchDirectory()
        let authority = makeLeaseAuthority(scratch: scratch)
        let lease = issuedLease(authority: authority)
        let rotated = ProviderGenerations(credential: 2, provider: 2, descriptor: 3)
        #expect(throws: DaemonProviderError.leaseInvalid(.staleGeneration)) {
            _ = try authority.consume(
                lease, installationRoot: leaseRoot, asTarget: targetIdentity,
                targetInstance: targetInstance, currentGenerations: rotated
            )
        }
    }

    @Test("an unreadable journal fails closed — never resolves the lease")
    func journalUnreadable() throws {
        let scratch = ScratchDirectory()
        let journalURL = scratch.url.appendingPathComponent("lease.journal")
        try Data("x\n".utf8).write(to: journalURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: journalURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path) }
        let authority = makeLeaseAuthority(scratch: scratch)
        let lease = issuedLease(authority: authority)
        #expect(throws: DaemonProviderError.leaseInvalid(.journalUnavailable)) {
            _ = try authority.consume(
                lease, installationRoot: leaseRoot, asTarget: targetIdentity,
                targetInstance: targetInstance, currentGenerations: leaseGenerations
            )
        }
    }

    @Test("a hard-linked journal fails closed — an aliased one-use record answers nothing")
    func journalHardLinkRefused() throws {
        let scratch = ScratchDirectory()
        let journalURL = scratch.url.appendingPathComponent("lease.journal")
        try Data("x\n".utf8).write(to: journalURL)
        try FileManager.default.linkItem(at: journalURL, to: scratch.url.appendingPathComponent("alias"))
        let journal = LeaseConsumptionJournal(fileURL: journalURL)
        #expect(throws: DaemonProviderError.leaseInvalid(.journalUnavailable)) {
            _ = try journal.contains(UUID())
        }
        #expect(throws: DaemonProviderError.leaseInvalid(.journalUnavailable)) {
            try journal.recordConsumption(UUID())
        }
    }

    @Test("a FIFO where the journal should be fails closed")
    func journalFIFORefused() throws {
        let scratch = ScratchDirectory()
        let journalURL = scratch.url.appendingPathComponent("lease.journal")
        guard mkfifo(journalURL.path, 0o600) == 0 else {
            Issue.record("mkfifo failed with errno \(errno)")
            return
        }
        // Hold the FIFO open O_RDWR so the journal's O_RDONLY open cannot
        // park waiting for a writer; the fstat S_ISREG gate is then what
        // refuses it.
        let keepAlive = open(journalURL.path, O_RDWR | O_NONBLOCK)
        #expect(keepAlive >= 0)
        defer { close(keepAlive) }
        let journal = LeaseConsumptionJournal(fileURL: journalURL)
        #expect(throws: DaemonProviderError.leaseInvalid(.journalUnavailable)) {
            _ = try journal.contains(UUID())
        }
    }

    @Test("the consumption record is durable BEFORE the lease resolves")
    func journalFirst() throws {
        let scratch = ScratchDirectory()
        let journal = LeaseConsumptionJournal(fileURL: scratch.url.appendingPathComponent("lease.journal"))
        let authority = LeaseAuthority(
            journal: journal, clock: FixedClock().closure, randomBytes: SeededRandom().closure
        )
        let lease = issuedLease(authority: authority)
        _ = try authority.consume(
            lease, installationRoot: leaseRoot, asTarget: targetIdentity,
            targetInstance: targetInstance, currentGenerations: leaseGenerations
        )
        // The journal contains the record — and would have even if the caller
        // had crashed immediately after consume returned, because the append
        // and fsync happen inside consume, before its return value exists.
        #expect(try journal.contains(lease.leaseIdentifier))
    }
}

@Suite("Two-phase handover sequencing (Kong decision 3)")
struct HandoverCoordinatorTests {

    private struct Rig {
        let recorder = CallRecorder()
        let scratch = ScratchDirectory()
        let clock = FixedClock()
        let random = SeededRandom()
        let estate: CountingEstate
        let installer: CountingInstaller
        let process: CountingProcess
        let sourceAuth: FakeSourceAuthentication
        let coordinator: HandoverCoordinator
        let leaseAuthority: LeaseAuthority

        init(sourceStillRunning: Bool = false) {
            estate = CountingEstate(recorder: recorder, proof: leaseEstate)
            installer = CountingInstaller(recorder: recorder)
            process = CountingProcess(recorder: recorder, sourceStillRunning: sourceStillRunning)
            sourceAuth = FakeSourceAuthentication(recorder: recorder, identity: sourceIdentity)
            coordinator = HandoverCoordinator(
                estate: estate, installer: installer, process: process, sourceAuthentication: sourceAuth
            )
            leaseAuthority = LeaseAuthority(
                journal: LeaseConsumptionJournal(fileURL: scratch.url.appendingPathComponent("lease.journal")),
                clock: clock.closure, randomBytes: random.closure
            )
        }

        /// Drive steps 1 through `upTo` on the happy path.
        func drive(upTo step: HandoverStep) async throws -> HandoverLease? {
            var lease: HandoverLease?
            if step.rawValue >= HandoverStep.targetPrepared.rawValue {
                try await coordinator.prepareTarget()
            }
            if step.rawValue >= HandoverStep.sourceAuthenticated.rawValue {
                _ = try await coordinator.authenticateSource()
            }
            if step.rawValue >= HandoverStep.estateClosed.rawValue {
                _ = try await coordinator.quiesceSource {
                    ProviderGenerations(credential: 1, provider: 2, descriptor: 3)
                }
            }
            if step.rawValue >= HandoverStep.leaseIssued.rawValue {
                lease = try await coordinator.issueLease(
                    authority: leaseAuthority, estate: leaseEstate,
                    sourceInstance: UUID(), targetInstance: targetInstance,
                    targetIdentity: targetIdentity,
                    generations: leaseGenerations, installationRoot: leaseRoot
                )
            }
            if step.rawValue >= HandoverStep.sourceExited.rawValue {
                try await coordinator.verifySourceExit()
            }
            if step.rawValue >= HandoverStep.targetReady.rawValue {
                try await coordinator.consumeAndStartTarget {
                    self.recorder.record("target.activate")
                }
            }
            if step.rawValue >= HandoverStep.sourceRemoved.rawValue {
                try await coordinator.removeSource()
            }
            return lease
        }
    }

    @Test("the happy path runs all eight steps in the mandated order")
    func happyPath() async throws {
        let rig = Rig()
        _ = try await rig.drive(upTo: .sourceRemoved)
        let events = rig.recorder.events
        // The estate quiescence order INSIDE step 3 is itself mandated.
        let quiescence = events.filter { $0.hasPrefix("estate.") && $0 != "estate.open" }
        #expect(quiescence == ["estate.stopWrites", "estate.drain", "estate.checkpoint", "estate.close"])
        // Cross-step order: prepare < authenticate < quiesce < exit-verify <
        // target activation < source removal.
        let order = [
            "installer.prepareTargetDisabled", "sourceAuth.authenticate",
            "estate.stopWrites", "process.verifySourceExited",
            "target.activate", "installer.removeSource",
        ]
        let indices = order.compactMap { event in events.firstIndex(of: event) }
        #expect(indices.count == order.count)
        #expect(indices == indices.sorted())
        let step = await rig.coordinator.step
        #expect(step == .sourceRemoved)
    }

    @Test("every out-of-order callback refuses WITHOUT invoking its authority")
    func outOfOrderRefused() async throws {
        // From idle, every later step must refuse and record nothing.
        do {
            let rig = Rig()
            await #expect(throws: DaemonProviderError.self) {
                _ = try await rig.coordinator.authenticateSource()
            }
            await #expect(throws: DaemonProviderError.self) {
                _ = try await rig.coordinator.quiesceSource { leaseGenerations }
            }
            await #expect(throws: DaemonProviderError.self) {
                try await rig.coordinator.verifySourceExit()
            }
            await #expect(throws: DaemonProviderError.self) {
                try await rig.coordinator.consumeAndStartTarget { rig.recorder.record("target.activate") }
            }
            await #expect(throws: DaemonProviderError.self) {
                try await rig.coordinator.removeSource()
            }
            #expect(rig.recorder.events.isEmpty)
        }

        // Source removal before target readiness — the canonical "step 7
        // needs step 6" refusal, from a machine parked at leaseIssued.
        do {
            let rig = Rig()
            _ = try await rig.drive(upTo: .leaseIssued)
            let before = rig.recorder.count(prefix: "installer.removeSource")
            // The machine sits at leaseIssued, so the next legal step is
            // sourceExited — that is what the violation names as expected.
            await #expect(throws: DaemonProviderError.handoverSequenceViolation(
                expected: .sourceExited, requested: .sourceRemoved
            )) {
                try await rig.coordinator.removeSource()
            }
            #expect(rig.recorder.count(prefix: "installer.removeSource") == before)
        }

        // Lease issue before quiescence.
        do {
            let rig = Rig()
            _ = try await rig.drive(upTo: .sourceAuthenticated)
            await #expect(throws: DaemonProviderError.handoverSequenceViolation(
                expected: .estateClosed, requested: .leaseIssued
            )) {
                _ = try await rig.coordinator.issueLease(
                    authority: rig.leaseAuthority, estate: leaseEstate,
                    sourceInstance: UUID(), targetInstance: targetInstance,
                    targetIdentity: targetIdentity,
                    generations: leaseGenerations, installationRoot: leaseRoot
                )
            }
        }

        // Target start before source-exit verification.
        do {
            let rig = Rig()
            _ = try await rig.drive(upTo: .leaseIssued)
            await #expect(throws: DaemonProviderError.handoverSequenceViolation(
                expected: .sourceExited, requested: .targetReady
            )) {
                try await rig.coordinator.consumeAndStartTarget { rig.recorder.record("target.activate") }
            }
            #expect(!rig.recorder.events.contains("target.activate"))
        }

        // Repeating a completed step.
        do {
            let rig = Rig()
            _ = try await rig.drive(upTo: .targetPrepared)
            let before = rig.recorder.count(prefix: "installer.prepareTargetDisabled")
            await #expect(throws: DaemonProviderError.handoverSequenceViolation(
                expected: .sourceAuthenticated, requested: .targetPrepared
            )) {
                try await rig.coordinator.prepareTarget()
            }
            #expect(rig.recorder.count(prefix: "installer.prepareTargetDisabled") == before)
        }
    }

    @Test("a compatible failure rolls back through the injected installer")
    func rollback() async throws {
        let rig = Rig()
        _ = try await rig.drive(upTo: .leaseIssued)
        let disposition = try await rig.coordinator.fail(compatibleRollbackAvailable: true)
        #expect(disposition == .rolledBack)
        #expect(rig.recorder.count(prefix: "installer.rollbackToSource") == 1)
        let step = await rig.coordinator.step
        #expect(step == .rolledBack)
    }

    @Test("an incompatible failure lands in recoveryRequired and stops")
    func recoveryRequired() async throws {
        let rig = Rig()
        _ = try await rig.drive(upTo: .sourceExited)
        let disposition = try await rig.coordinator.fail(compatibleRollbackAvailable: false)
        #expect(disposition == .recoveryRequired)
        #expect(rig.recorder.count(prefix: "installer.rollbackToSource") == 0)
        let step = await rig.coordinator.step
        #expect(step == .recoveryRequired)
        // A machine in recoveryRequired refuses to continue.
        await #expect(throws: DaemonProviderError.self) {
            try await rig.coordinator.removeSource()
        }
    }

    @Test("a still-running source refuses step 5 and the machine does not advance")
    func sourceStillRunning() async throws {
        let rig = Rig(sourceStillRunning: true)
        _ = try await rig.drive(upTo: .leaseIssued)
        await #expect(throws: DaemonProviderError.self) {
            try await rig.coordinator.verifySourceExit()
        }
        let step = await rig.coordinator.step
        #expect(step == .leaseIssued)
    }

    @Test("crash-at-every-step: a fresh coordinator refuses to resume mid-sequence")
    func crashAtEveryStep() async throws {
        for step in [HandoverStep.targetPrepared, .sourceAuthenticated, .estateClosed, .leaseIssued, .sourceExited] {
            let rig = Rig()
            _ = try await rig.drive(upTo: step)
            // The process "crashes": all coordinator state is lost. A new
            // coordinator (same authorities) must refuse to continue from the
            // middle — only step 1 is legal from idle, so the resumed flow
            // re-prepares rather than double-running a later side effect.
            let resumed = HandoverCoordinator(
                estate: rig.estate, installer: rig.installer,
                process: rig.process, sourceAuthentication: rig.sourceAuth
            )
            await #expect(throws: DaemonProviderError.self) {
                try await resumed.removeSource()
            }
            await #expect(throws: DaemonProviderError.self) {
                try await resumed.consumeAndStartTarget { rig.recorder.record("target.activate") }
            }
        }
    }
}
