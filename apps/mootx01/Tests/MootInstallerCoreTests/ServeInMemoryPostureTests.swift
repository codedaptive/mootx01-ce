// ServeInMemoryPostureTests.swift — source-shape guard for the `--in-memory`
// posture rule (R8, 2026-09-08).
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
// Before this gate the binding read `estate.kind == .registered` alone, so
// `mootx01 serve --in-memory` against a registered record federated and seeded
// seven charter drawers into a benchmark RAM arm.

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
}
