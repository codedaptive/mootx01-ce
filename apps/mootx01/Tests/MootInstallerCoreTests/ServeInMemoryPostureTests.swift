// ServeInMemoryPostureTests.swift — source-shape guard for the `--in-memory`
// posture rule (R8, 2026-09-08) and the at-rest posture ordering fix (V2-F).
//
// One rule across `aria-mcp` (both ports) and `mootx01 serve` (both ports):
// `--in-memory` opens the catalog, resolves its record, and then serves that
// estate as a TRANSIENT one — federation off, charters off. The Rust twin of
// this gate is `transient_charter_gate_tests.rs` in AriaMcpKit, which counts
// drawers on a freshly opened estate per backend. Swift's decision lives in
// one binding inside `ServeCommand.run`, which the executable target keeps
// out of reach of a test target, so it is checked on the source text — the
// same technique `ServeFrozenGateTests` uses for the frozen gate.
//
// Before V2-F the at-rest posture block ran unconditionally, so
// `mootx01 serve --in-memory` against an encrypted registered estate blocked
// on a Keychain prompt even though no on-disk key is needed.
//
// The V2-F follow-up (2026-09-09) guards the manifest refresh so an in-memory
// serve writes nothing into the estate directory. `encryption` is now declared
// as an optional; the in-memory arm sets it to nil and the manifest refresh is
// wrapped in `if let encryption` so it only runs for an on-disk serve.

import Testing
import Foundation

@Suite("ServeCommand in-memory posture (source shape)")
struct ServeInMemoryPostureTests {

    private func serveCommandSource() throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let source = here
            .deletingLastPathComponent()   // strip the file name
            .deletingLastPathComponent()   // MootInstallerCoreTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Sources/mootx01/Commands/ServeCommand.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }

    @Test func inMemoryIsServedAsATransientEstate() throws {
        let source = try serveCommandSource()
        #expect(
            source.contains("let registered = estate.kind == .registered && !inMemory"),
            "--in-memory must force the transient posture: without the !inMemory term an in-memory serve of a registered record federates and seeds charters")
    }

    @Test func chartersSeedOnlyForARegisteredOpen() throws {
        let source = try serveCommandSource()
        #expect(source.contains("if registered && posture != .frozen {"),
                "seedDefaultWings must stay under the registered gate")
        #expect(source.contains("try await kit.seedDefaultWings(for: handle, now: Date())"))
    }

    @Test func federationAndTheIdentityStoreFollowTheSameBinding() throws {
        let source = try serveCommandSource()
        #expect(source.contains("registered ? nil : InMemoryEstateIdentityKeyStore()"),
                "a non-registered open keeps its Ed25519 identity in memory")
        #expect(source.contains("identityKeyStore: identityKeyStore, federate: registered, frozen: posture == .frozen)"),
                "federation is the same binding as the identity store and the charters")
    }

    @Test func theRecordIsResolvedBeforeTheBackendIsChosen() throws {
        let source = try serveCommandSource()
        guard let recordIndex = source.range(of: "let registered = estate.kind == .registered"),
              let backendIndex = source.range(of: "let storage: any Storage") else {
            Issue.record("ServeCommand no longer carries the record binding or the storage branch")
            return
        }
        #expect(recordIndex.lowerBound < backendIndex.lowerBound,
                "the catalog record must resolve before the backend is chosen, so a bad --db is refused even under --in-memory")
    }

    // V2-F: the in-memory branch is entered before EstateOpenPosture.resolve
    // is reached. No posture resolution, no Keychain contact for --in-memory.
    @Test func atRestPostureSkippedForInMemoryServe() throws {
        let source = try serveCommandSource()
        // The storage declaration marks the start of the branching block.
        // The else clause carries the on-disk path with the posture call.
        guard let storageBranch = source.range(of: "let storage: any Storage"),
              let inMemoryArm = source.range(of: "if inMemory {"),
              let elseArm = source.range(of: "} else {\n            // At-rest posture"),
              let postureCall = source.range(of: "EstateOpenPosture.resolve(for: estate)") else {
            Issue.record("ServeCommand no longer carries the storage branch, the in-memory arm, the on-disk else arm, or the posture call")
            return
        }
        #expect(storageBranch.lowerBound < inMemoryArm.lowerBound,
                "the storage branch must open before the in-memory arm")
        #expect(inMemoryArm.lowerBound < elseArm.lowerBound,
                "the in-memory arm must come before the on-disk else arm")
        #expect(postureCall.lowerBound > elseArm.lowerBound,
                "EstateOpenPosture.resolve must appear only inside the on-disk (else) arm, never before it")
    }

    // V2-F follow-up: encryption is now an optional; the in-memory arm sets it
    // to nil; the manifest refresh is guarded by `if let encryption` so an
    // in-memory serve writes nothing into the estate directory.
    @Test func inMemoryServeWritesNoManifest() throws {
        let source = try serveCommandSource()
        #expect(
            source.contains("let encryption: EstateEncryptionConfig?"),
            "encryption must be declared as an optional: an unguarded refresh rewrites the on-disk estate.json to plaintext during an in-memory serve")
        guard let inMemoryArm = source.range(of: "if inMemory {"),
              let elseArm = source.range(of: "} else {\n            // At-rest posture") else {
            Issue.record("ServeCommand no longer carries the in-memory arm or the on-disk else arm")
            return
        }
        let nilAssignPos = source.range(of: "encryption = nil")?.lowerBound
        #expect(
            nilAssignPos != nil
                && nilAssignPos! > inMemoryArm.lowerBound
                && nilAssignPos! < elseArm.lowerBound,
            "encryption = nil must be assigned strictly inside the if inMemory { arm, before the else: an unguarded refresh rewrites the on-disk estate.json to plaintext during an in-memory serve")
        let guardedCount = source.components(separatedBy: "if let encryption, try EstateManifestRefresh.afterPrepare(").count - 1
        let totalCount = source.components(separatedBy: "EstateManifestRefresh.afterPrepare(").count - 1
        #expect(
            guardedCount == totalCount && guardedCount >= 1,
            "every EstateManifestRefresh.afterPrepare( call must be guarded by `if let encryption`: an unguarded refresh rewrites the on-disk estate.json to plaintext during an in-memory serve")
    }

    // V2-F follow-up: the in-memory log line names the transient facts inline,
    // matching the shape of the Rust port which lists them in the same line.
    @Test func inMemoryLineCarriesTheTransientFacts() throws {
        let source = try serveCommandSource()
        #expect(
            source.contains("(transient: identity in memory, no federation, no charters, no Keychain writes)"),
            "the in-memory arm must report the transient facts inline as the Rust port does")
    }
}
