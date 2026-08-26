import Foundation
import Testing
import AriaMCP
@testable import MootDaemonProvider

// MARK: - P6 durable monotonic generations, P7 rotation ordering

@Suite("Durable generations (Perkins P6)")
struct GenerationStoreTests {

    private func makeStore() throws -> (ScratchDirectory, GenerationStore, ProviderLockHandle) {
        let scratch = ScratchDirectory()
        let store = GenerationStore(fileURL: scratch.url.appendingPathComponent("generations.v1"))
        let handle = try ProviderLock.acquire(at: scratch.url.appendingPathComponent("provider.lock"))
        return (scratch, store, handle)
    }

    @Test("genuine absence loads as nil; initialize creates 1/1/0")
    func initialize() throws {
        let (scratch, store, handle) = try makeStore()
        #expect(try store.load() == nil)
        let initial = try store.initialize(lockProof: handle.proof)
        #expect(initial == ProviderGenerations(credential: 1, provider: 1, descriptor: 0))
        #expect(try store.load() == initial)
        _ = scratch
        handle.release()
    }

    @Test("the record survives restart: a fresh store instance reads the same counters")
    func restartSurvival() throws {
        let (scratch, store, handle) = try makeStore()
        _ = try store.initialize(lockProof: handle.proof)
        let advanced = try store.advance(
            to: ProviderGenerations(credential: 1, provider: 2, descriptor: 5),
            expecting: ProviderGenerations(credential: 1, provider: 1, descriptor: 0),
            lockProof: handle.proof
        )
        // A NEW store over the same file — a restarted provider.
        let reborn = GenerationStore(fileURL: scratch.url.appendingPathComponent("generations.v1"))
        #expect(try reborn.load() == advanced)
        handle.release()
    }

    @Test("monotonic advance persists; any backwards counter is rollback")
    func rollbackRefused() throws {
        let (scratch, store, handle) = try makeStore()
        defer { withExtendedLifetime(scratch) {} }
        let initial = try store.initialize(lockProof: handle.proof)
        _ = try store.advance(
            to: ProviderGenerations(credential: 2, provider: 1, descriptor: 1),
            expecting: initial, lockProof: handle.proof
        )
        #expect(throws: DaemonProviderError.generationFault(.rollback)) {
            _ = try store.advance(
                to: ProviderGenerations(credential: 1, provider: 1, descriptor: 1),
                expecting: ProviderGenerations(credential: 2, provider: 1, descriptor: 1),
                lockProof: handle.proof
            )
        }
        handle.release()
    }

    @Test("a stale expectation is mismatch, not overwrite")
    func mismatchRefused() throws {
        let (scratch, store, handle) = try makeStore()
        defer { withExtendedLifetime(scratch) {} }
        let initial = try store.initialize(lockProof: handle.proof)
        _ = try store.advance(
            to: ProviderGenerations(credential: 1, provider: 2, descriptor: 0),
            expecting: initial, lockProof: handle.proof
        )
        // A caller still holding the INITIAL view must not clobber.
        #expect(throws: DaemonProviderError.generationFault(.mismatch)) {
            _ = try store.advance(
                to: ProviderGenerations(credential: 1, provider: 3, descriptor: 0),
                expecting: initial, lockProof: handle.proof
            )
        }
        handle.release()
    }

    @Test("overflow refuses rather than wraps")
    func overflowRefused() throws {
        let atMax = ProviderGenerations(credential: UInt64.max, provider: 1, descriptor: 1)
        #expect(throws: DaemonProviderError.generationFault(.overflow)) {
            _ = try atMax.bumpedCredential()
        }
        #expect(throws: DaemonProviderError.generationFault(.overflow)) {
            _ = try ProviderGenerations(credential: 1, provider: UInt64.max, descriptor: 1).bumpedProvider()
        }
        #expect(throws: DaemonProviderError.generationFault(.overflow)) {
            _ = try ProviderGenerations(credential: 1, provider: 1, descriptor: UInt64.max).bumpedDescriptor()
        }
    }

    @Test("a torn record refuses: garbage, truncation, and checksum damage all fail closed")
    func tornRefused() throws {
        let (scratch, store, handle) = try makeStore()
        _ = try store.initialize(lockProof: handle.proof)
        let file = scratch.url.appendingPathComponent("generations.v1")

        // Bit-flip damage.
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count / 2] ^= 0x01
        try bytes.write(to: file)
        #expect(throws: DaemonProviderError.generationFault(.torn)) { _ = try store.load() }

        // Outright garbage.
        try Data("not a generation record".utf8).write(to: file)
        #expect(throws: DaemonProviderError.generationFault(.torn)) { _ = try store.load() }

        // Truncation of a healthy record.
        let (scratch2, store2, handle2) = try makeStore()
        _ = try store2.initialize(lockProof: handle2.proof)
        let file2 = scratch2.url.appendingPathComponent("generations.v1")
        let full = try Data(contentsOf: file2)
        try full.prefix(full.count / 2).write(to: file2)
        #expect(throws: DaemonProviderError.generationFault(.torn)) { _ = try store2.load() }
        handle2.release()
        handle.release()
    }

    @Test("an unreadable record refuses rather than resets")
    func unreadableRefused() throws {
        let (scratch, store, handle) = try makeStore()
        _ = try store.initialize(lockProof: handle.proof)
        let file = scratch.url.appendingPathComponent("generations.v1")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        #expect(throws: DaemonProviderError.generationFault(.unreadable)) { _ = try store.load() }
        handle.release()
    }

    @Test("wire encoding is the canonical decimal string")
    func wireEncoding() {
        #expect(ProviderGenerations.wireEncode(0) == "0")
        #expect(ProviderGenerations.wireEncode(UInt64.max) == "18446744073709551615")
        #expect(ProviderGenerations.wireDecode("18446744073709551615") == UInt64.max)
        #expect(ProviderGenerations.wireDecode("01") == nil)
        #expect(ProviderGenerations.wireDecode("-1") == nil)
        #expect(ProviderGenerations.wireDecode("1.0") == nil)
        #expect(ProviderGenerations.wireDecode("18446744073709551616") == nil)
        #expect(ProviderGenerations.wireDecode("") == nil)
    }
}

@Suite("Rotation (Perkins P7)")
struct RotationTests {

    @Test("rotation bumps the credential generation durably and republished descriptor carries it")
    func rotationBumpsAndRepublishes() async throws {
        let harness = ProviderHarness()
        let activation = try await harness.provider.activate()
        #expect(activation.generations.credential == 1)

        let rotated = try await harness.provider.rotateCredential()
        #expect(rotated.credentialGeneration == 2)
        #expect(rotated.descriptorGeneration > activation.descriptor.descriptorGeneration)

        // The durable record moved too — a fresh store over the same file
        // agrees, so the bump survives restart.
        let file = harness.scratch.url
            .appendingPathComponent("Library/Application Support/MOOTx01/provider/generations.v1")
        let store = GenerationStore(fileURL: file)
        let stored = try store.load()
        #expect(stored?.credential == 2)
    }

    @Test("rotation revokes every session and lease BEFORE republishing")
    func rotationRevokesBeforeRepublish() async throws {
        let harness = ProviderHarness()
        _ = try await harness.provider.activate()
        _ = try await harness.provider.rotateCredential()

        let events = harness.recorder.events
        guard let revokeIndex = events.lastIndex(where: { $0.hasPrefix("sessions.revokeAll") }) else {
            Issue.record("rotation never revoked sessions; events: \(events)")
            return
        }
        // Republication re-proves readiness, so the fresh bind readback is the
        // observable "republish is happening" marker; it must come after the
        // revocation.
        guard let rebindIndex = events.lastIndex(where: { $0.hasPrefix("bind.") }) else {
            Issue.record("rotation never re-proved the bind; events: \(events)")
            return
        }
        #expect(revokeIndex < rebindIndex)
    }

    @Test("outstanding leases are stale after rotation by generation binding")
    func rotationStalesLeases() async throws {
        let scratch = ScratchDirectory()
        let clock = FixedClock()
        let random = SeededRandom()
        let journal = LeaseConsumptionJournal(fileURL: scratch.url.appendingPathComponent("journal"))
        let authority = LeaseAuthority(journal: journal, clock: clock.closure, randomBytes: random.closure)
        let root = [UInt8](repeating: 5, count: 32)
        let estate = EstateReadyProof(estateIdentifier: UUID(), schemaVersion: 3)
        let target = SigningIdentityDescriptor(teamIdentifier: testTeam, bundleIdentifier: "b", signingClass: .appleDistribution)
        let generationsAtIssue = ProviderGenerations(credential: 1, provider: 2, descriptor: 2)
        let lease = authority.issue(
            estate: estate,
            sourceInstance: UUID(), targetInstance: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!,
            sourceIdentity: SigningIdentityDescriptor(teamIdentifier: testTeam, bundleIdentifier: "a", signingClass: .developerID),
            targetIdentity: target,
            generations: generationsAtIssue,
            installationRoot: root
        )
        // Rotation happened: current credential generation is now 2.
        let current = ProviderGenerations(credential: 2, provider: 2, descriptor: 3)
        #expect(throws: DaemonProviderError.leaseInvalid(.staleGeneration)) {
            _ = try authority.consume(
                lease, installationRoot: root, asTarget: target,
                targetInstance: lease.targetInstance, currentGenerations: current
            )
        }
    }
}
