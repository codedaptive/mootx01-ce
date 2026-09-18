import Foundation
import Testing
import AriaMCP
@testable import MootDaemonProvider

// MARK: - P4 lock ordering and race, P5 K_install custody

@Suite("Exclusive provider lock (Perkins P4)")
struct ProviderLockTests {

    @Test("the lock is exclusive: a second acquisition refuses")
    func exclusive() throws {
        let scratch = ScratchDirectory()
        let lockURL = scratch.url.appendingPathComponent("provider.lock")
        let held = try ProviderLock.acquire(at: lockURL)
        #expect(throws: DaemonProviderError.lockUnavailable) {
            _ = try ProviderLock.acquire(at: lockURL)
        }
        held.release()
    }

    @Test("release makes the lock acquirable again")
    func releaseReacquire() throws {
        let scratch = ScratchDirectory()
        let lockURL = scratch.url.appendingPathComponent("provider.lock")
        let first = try ProviderLock.acquire(at: lockURL)
        first.release()
        let second = try ProviderLock.acquire(at: lockURL)
        second.release()
    }

    @Test("a proof from a released handle is stale and refuses everywhere it is consumed")
    func staleProofRefused() throws {
        let scratch = ScratchDirectory()
        let handle = try ProviderLock.acquire(at: scratch.url.appendingPathComponent("provider.lock"))
        let proof = handle.proof
        #expect(proof.isLive)
        handle.release()
        #expect(!proof.isLive)

        // K_install mint refuses under a stale proof.
        let keychain = CountingKeychain(recorder: CallRecorder())
        let authority = InstallationRootAuthority(
            keychain: keychain, eligibility: try makeEligibility(),
            randomBytes: SeededRandom().closure
        )
        #expect(throws: DaemonProviderError.lockUnavailable) {
            _ = try authority.ensureRoot(lockProof: proof)
        }
        #expect(keychain.recorder.count(prefix: "keychain.add") == 0)

        // Generation writes refuse under a stale proof.
        let store = GenerationStore(fileURL: scratch.url.appendingPathComponent("generations.v1"))
        #expect(throws: DaemonProviderError.lockUnavailable) {
            _ = try store.initialize(lockProof: proof)
        }

        // A fresh handle over the same lock file vends live proofs again.
        let fresh = try ProviderLock.acquire(at: scratch.url.appendingPathComponent("provider.lock"))
        _ = try store.initialize(lockProof: fresh.proof)
        fresh.release()
    }

    @Test("a symlinked lock path is refused before flocking anything")
    func symlinkedLockRefused() throws {
        let scratch = ScratchDirectory()
        let real = scratch.url.appendingPathComponent("elsewhere")
        try Data().write(to: real)
        let lockURL = scratch.url.appendingPathComponent("provider.lock")
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: real)
        #expect(throws: DaemonProviderError.hygieneViolation(.symlink)) {
            _ = try ProviderLock.acquire(at: lockURL)
        }
    }
}

@Suite("Activation ordering and the two-provider race (Perkins P4)")
struct ActivationRaceTests {

    @Test("activation holds the lock before any keychain, estate, or bind callback")
    func lockPrecedesSideEffects() async throws {
        let harness = ProviderHarness()
        _ = try await harness.provider.activate()
        let events = harness.recorder.events
        // The first side-effect callback of any kind must come AFTER lock
        // acquisition — proven by the harness recording nothing at all until
        // the provider had the lock (the lock itself is not an injected
        // callback, so the first recorded event is necessarily post-lock).
        // The load-bearing assertion is the ORDER of the seams themselves:
        let keychainIndex = harness.recorder.firstIndex(prefix: "keychain.")
        let estateIndex = harness.recorder.firstIndex(prefix: "estate.open")
        let bindIndex = harness.recorder.firstIndex(prefix: "bind.")
        #expect(keychainIndex != nil && estateIndex != nil && bindIndex != nil)
        if let k = keychainIndex, let e = estateIndex, let b = bindIndex {
            #expect(k < e && e < b)
        }
        #expect(!events.isEmpty)
    }

    @Test("the sequential race loser refuses with zero side-effect callbacks")
    func sequentialLoserZeroCallbacks() async throws {
        let scratch = ScratchDirectory()
        let winner = ProviderHarness(scratch: scratch)
        _ = try await winner.provider.activate()

        let loserRecorder = CallRecorder()
        let loser = ProviderHarness(scratch: scratch, recorder: loserRecorder)
        await #expect(throws: DaemonProviderError.lockUnavailable) {
            _ = try await loser.provider.activate()
        }
        #expect(loser.sideEffectCallbackCount == 0)
    }

    @Test("the concurrent race elects exactly one owner; the loser makes zero callbacks")
    func concurrentRace() async throws {
        let scratch = ScratchDirectory()
        let a = ProviderHarness(scratch: scratch, recorder: CallRecorder())
        let b = ProviderHarness(scratch: scratch, recorder: CallRecorder())

        let results = await withTaskGroup(of: Bool.self) { group -> [Bool] in
            group.addTask {
                do { _ = try await a.provider.activate(); return true } catch { return false }
            }
            group.addTask {
                do { _ = try await b.provider.activate(); return true } catch { return false }
            }
            var collected: [Bool] = []
            for await result in group { collected.append(result) }
            return collected
        }

        #expect(results.filter { $0 }.count == 1)
        #expect(results.filter { !$0 }.count == 1)
        // Whichever lost must have recorded nothing.
        let aWon = results.count == 2 && a.recorder.events.isEmpty == false && b.recorder.events.isEmpty
        let bWon = results.count == 2 && b.recorder.events.isEmpty == false && a.recorder.events.isEmpty
        #expect(aWon || bWon)
    }
}

@Suite("K_install custody (Perkins P5)")
struct InstallationRootTests {

    private func authority(
        _ keychain: CountingKeychain,
        random: SeededRandom = SeededRandom()
    ) throws -> InstallationRootAuthority {
        InstallationRootAuthority(
            keychain: keychain,
            eligibility: try makeEligibility(),
            randomBytes: random.closure
        )
    }

    @Test("an existing valid root is reused, never re-minted")
    func existingReused() throws {
        let recorder = CallRecorder()
        let keychain = CountingKeychain(recorder: recorder, scriptedReads: [.found([UInt8](repeating: 9, count: 32))])
        let lockScratch = ScratchDirectory()
        let handle = try ProviderLock.acquire(at: lockScratch.url.appendingPathComponent("l"))
        let root = try authority(keychain).ensureRoot(lockProof: handle.proof)
        #expect(root.provenance == .existing)
        #expect(root.bytes == [UInt8](repeating: 9, count: 32))
        #expect(recorder.count(prefix: "keychain.add") == 0)
        handle.release()
    }

    @Test("genuine absence plus eligibility plus lock licenses a 32-byte mint from injected randomness")
    func genuineAbsenceMints() throws {
        let recorder = CallRecorder()
        let keychain = CountingKeychain(recorder: recorder)
        let random = SeededRandom(seed: 41)
        let lockScratch = ScratchDirectory()
        let handle = try ProviderLock.acquire(at: lockScratch.url.appendingPathComponent("l"))
        let root = try authority(keychain, random: random).ensureRoot(lockProof: handle.proof)
        #expect(root.provenance == .minted)
        #expect(root.bytes.count == FirstPartyAuthProtocol.rootKeyByteCount)
        // Deterministic randomness: the minted bytes are the seeded pattern.
        #expect(root.bytes == [UInt8](repeating: 42, count: 32))
        #expect(keychain.stored == root.bytes)
        #expect(recorder.count(prefix: "keychain.add") == 1)
        handle.release()
    }

    @Test("the mint uses the exact MACD-2b service, account, and expanded group")
    func mintUsesContractConstants() throws {
        let recorder = CallRecorder()
        let keychain = CountingKeychain(recorder: recorder)
        let lockScratch = ScratchDirectory()
        let handle = try ProviderLock.acquire(at: lockScratch.url.appendingPathComponent("l"))
        _ = try authority(keychain).ensureRoot(lockProof: handle.proof)
        let adds = recorder.events.filter { $0.hasPrefix("keychain.add") }
        #expect(adds.count == 1)
        #expect(adds[0].contains("service=\(FirstPartyAuthProtocol.keychainService)"))
        #expect(adds[0].contains("account=\(FirstPartyAuthProtocol.keychainAccount)"))
        #expect(adds[0].contains("group=\(testTeam).\(ProviderEligibilityJudge.requiredKeychainGroupSuffix)"))
        handle.release()
    }

    @Test("errSecMissingEntitlement is fatal and never licenses a mint")
    func missingEntitlementFatal() throws {
        let recorder = CallRecorder()
        let keychain = CountingKeychain(recorder: recorder, scriptedReads: [.missingEntitlement])
        let lockScratch = ScratchDirectory()
        let handle = try ProviderLock.acquire(at: lockScratch.url.appendingPathComponent("l"))
        #expect(throws: DaemonProviderError.keychainFatal(.missingEntitlement)) {
            _ = try authority(keychain).ensureRoot(lockProof: handle.proof)
        }
        #expect(recorder.count(prefix: "keychain.add") == 0)
        handle.release()
    }

    @Test("a locked keychain is fatal, not absence")
    func interactionRequiredFatal() throws {
        let recorder = CallRecorder()
        let keychain = CountingKeychain(recorder: recorder, scriptedReads: [.interactionRequired])
        let lockScratch = ScratchDirectory()
        let handle = try ProviderLock.acquire(at: lockScratch.url.appendingPathComponent("l"))
        #expect(throws: DaemonProviderError.keychainFatal(.interactionRequired)) {
            _ = try authority(keychain).ensureRoot(lockProof: handle.proof)
        }
        #expect(recorder.count(prefix: "keychain.add") == 0)
        handle.release()
    }

    @Test("any other keychain error is fatal, not absence")
    func unavailableFatal() throws {
        let recorder = CallRecorder()
        let keychain = CountingKeychain(recorder: recorder, scriptedReads: [.unavailable])
        let lockScratch = ScratchDirectory()
        let handle = try ProviderLock.acquire(at: lockScratch.url.appendingPathComponent("l"))
        #expect(throws: DaemonProviderError.keychainFatal(.unavailable)) {
            _ = try authority(keychain).ensureRoot(lockProof: handle.proof)
        }
        #expect(recorder.count(prefix: "keychain.add") == 0)
        handle.release()
    }

    @Test("a wrong-length item is corruption, fatal, never re-minted")
    func wrongLengthCorrupt() throws {
        let recorder = CallRecorder()
        let keychain = CountingKeychain(recorder: recorder, scriptedReads: [.found([1, 2, 3])])
        let lockScratch = ScratchDirectory()
        let handle = try ProviderLock.acquire(at: lockScratch.url.appendingPathComponent("l"))
        #expect(throws: DaemonProviderError.keychainFatal(.corrupted)) {
            _ = try authority(keychain).ensureRoot(lockProof: handle.proof)
        }
        #expect(recorder.count(prefix: "keychain.add") == 0)
        handle.release()
    }

    @Test("a post-mint read-back disagreement is fatal")
    func disagreementFatal() throws {
        let recorder = CallRecorder()
        let keychain = CountingKeychain(recorder: recorder)
        keychain.corruptOnAdd = [UInt8](repeating: 0xEE, count: 32)
        let lockScratch = ScratchDirectory()
        let handle = try ProviderLock.acquire(at: lockScratch.url.appendingPathComponent("l"))
        #expect(throws: DaemonProviderError.keychainFatal(.disagreement)) {
            _ = try authority(keychain).ensureRoot(lockProof: handle.proof)
        }
        handle.release()
    }

    @Test("losing the add race to an identical item is benign; to a different item, fatal")
    func duplicateAdd() throws {
        // Identical: the duplicate re-read returns the same bytes the mint
        // attempted — treated as an existing root.
        let recorderSame = CallRecorder()
        let same = CountingKeychain(
            recorder: recorderSame,
            scriptedReads: [.notFound, .found([UInt8](repeating: 42, count: 32))],
            scriptedAdd: .duplicate
        )
        let lockScratch = ScratchDirectory()
        let handle = try ProviderLock.acquire(at: lockScratch.url.appendingPathComponent("l"))
        let root = try authority(same, random: SeededRandom(seed: 41)).ensureRoot(lockProof: handle.proof)
        #expect(root.provenance == .existing)
        #expect(root.bytes == [UInt8](repeating: 42, count: 32))

        // Different: disagreement.
        let recorderDiff = CallRecorder()
        let different = CountingKeychain(
            recorder: recorderDiff,
            scriptedReads: [.notFound, .found([UInt8](repeating: 0xAB, count: 32))],
            scriptedAdd: .duplicate
        )
        #expect(throws: DaemonProviderError.keychainFatal(.disagreement)) {
            _ = try authority(different, random: SeededRandom(seed: 41)).ensureRoot(lockProof: handle.proof)
        }
        handle.release()
    }

    @Test("readRoot reports genuine absence as nil and every fault as fatal")
    func readOnlyMatrix() throws {
        let notFound = CountingKeychain(recorder: CallRecorder(), scriptedReads: [.notFound])
        #expect(try authority(notFound).readRoot() == nil)

        let entitlement = CountingKeychain(recorder: CallRecorder(), scriptedReads: [.missingEntitlement])
        #expect(throws: DaemonProviderError.keychainFatal(.missingEntitlement)) {
            _ = try authority(entitlement).readRoot()
        }
        let malformed = CountingKeychain(recorder: CallRecorder(), scriptedReads: [.found([0])])
        #expect(throws: DaemonProviderError.keychainFatal(.corrupted)) {
            _ = try authority(malformed).readRoot()
        }
    }
}
