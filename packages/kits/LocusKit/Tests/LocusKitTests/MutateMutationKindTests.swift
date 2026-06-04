import Testing
import SubstrateTypes
import Foundation
@testable import LocusKit

/// Round-trip tests for every `MutationKind` case in `Estate.mutate`.
/// Each test verifies the state-cluster transition (or guard condition)
/// documented in `EstateVerbs.swift` and cookbook §7.8.3.
@Suite("Estate.mutate — full MutationKind coverage per cookbook §7.8.3")
struct MutateMutationKindTests {

    // MARK: - Fixture helpers

    /// Fresh estate on a unique temp path.
    private func makeEstate() async throws -> Estate {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutate-kind-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("estate.sqlite3")
        return try await Estate.create(
            storage: TestStorage.sqlite(path),
            owner: OwnerCredentials(ownerIdentifier: "test-owner")
        )
    }

    /// Capture a drawer in `.active` state (the default for all captured rows).
    private func captureActive(in estate: Estate, content: String = "test") async throws -> Drawer {
        try await estate.capture(CaptureFrame(
            content: content,
            channel: .typed,
            room: "test-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6"
        ))
    }

    /// Read back a drawer via the internal peek helper.
    private func peek(_ estate: Estate, id: String) async throws -> Drawer {
        try await #require(try await estate._peekDrawer(id: id))
    }

    // MARK: - §9.2 contest: active → contested

    @Test(".contest moves an active drawer to .contested")
    func contest_fromActive_becomesContested() async throws {
        let estate = try await makeEstate()
        let drawer = try await captureActive(in: estate)
        #expect(drawer.state == .active)

        try await estate.mutate(rowID: drawer.id, kind: .contest)

        let after = try await peek(estate, id: drawer.id)
        #expect(after.state == .contested, "state should be .contested after .contest")
    }

    // MARK: - §9.2 resolve: contested → active (guard: only from contested)

    @Test(".resolve on a contested drawer returns it to .active")
    func resolve_fromContested_becomesActive() async throws {
        let estate = try await makeEstate()
        let drawer = try await captureActive(in: estate)
        // Contest first so resolve has a valid source state.
        try await estate.mutate(rowID: drawer.id, kind: .contest)
        let contested = try await peek(estate, id: drawer.id)
        #expect(contested.state == .contested)

        try await estate.mutate(rowID: drawer.id, kind: .resolve)

        let after = try await peek(estate, id: drawer.id)
        #expect(after.state == .active, "resolve should return a contested row to .active")
    }

    @Test(".resolve on a non-contested drawer throws the guard error")
    func resolve_fromActive_throwsGuard() async throws {
        let estate = try await makeEstate()
        let drawer = try await captureActive(in: estate)
        // Row is active — resolve is not valid from active state.
        let thrown = await #expect(throws: LocusKitError.self) {
            try await estate.mutate(rowID: drawer.id, kind: .resolve)
        }
        if case .invalidContent(let msg)? = thrown {
            #expect(msg.contains("resolve"), "error should mention 'resolve'")
            #expect(msg.contains("contested"), "error should mention 'contested'")
        } else {
            Issue.record("expected LocusKitError.invalidContent, got \(String(describing: thrown))")
        }
    }

    // MARK: - §9.2 supersede: active → superseded

    @Test(".supersede moves an active drawer to .superseded")
    func supersede_fromActive_becomesSuperseded() async throws {
        let estate = try await makeEstate()
        let drawer = try await captureActive(in: estate)

        try await estate.mutate(rowID: drawer.id, kind: .supersede)

        let after = try await peek(estate, id: drawer.id)
        #expect(after.state == .superseded, "state should be .superseded after .supersede")
    }

    // MARK: - §9.2 accept: active → accepted (requires trust ≥ canonical, S-1)

    @Test(".accept on an active drawer with trust ≥ canonical produces .accepted")
    func accept_withCanonicalTrust_becomesAccepted() async throws {
        let estate = try await makeEstate()
        let drawer = try await captureActive(in: estate)

        // Lift trust to .canonical so the S-1 guard and gate both pass.
        try await estate.mutate(rowID: drawer.id, kind: .correctTrust(.canonical))
        let withTrust = try await peek(estate, id: drawer.id)
        #expect(withTrust.trust == .canonical)

        try await estate.mutate(rowID: drawer.id, kind: .accept)

        let after = try await peek(estate, id: drawer.id)
        #expect(after.state == .accepted, "state should be .accepted after .accept with canonical trust")
    }

    @Test(".accept throws S-1 guard when trust is below canonical")
    func accept_withLowTrust_throwsS1Guard() async throws {
        let estate = try await makeEstate()
        let drawer = try await captureActive(in: estate)
        // trust defaults to .verbatim (raw 0) — below canonical (raw 3).
        #expect(drawer.trust == .verbatim)

        let thrown = await #expect(throws: LocusKitError.self) {
            try await estate.mutate(rowID: drawer.id, kind: .accept)
        }
        if case .invalidContent(let msg)? = thrown {
            #expect(msg.contains("S-1") || msg.contains("canonical"), "error should mention S-1 or canonical trust")
        } else {
            Issue.record("expected LocusKitError.invalidContent, got \(String(describing: thrown))")
        }
    }

    // MARK: - §9.2 reject: gate-enforced (only from pending; active throws)

    @Test(".reject from an active drawer throws — automaton gate enforces pending-only")
    func reject_fromActive_throwsGateViolation() async throws {
        let estate = try await makeEstate()
        let drawer = try await captureActive(in: estate)
        // reject is only legal from pending per cookbook §9.2.
        // An active row raises a gate discipline violation, not the old
        // "not yet implemented" sentinel.
        await #expect(throws: LocusKitError.self) {
            try await estate.mutate(rowID: drawer.id, kind: .reject)
        }
    }

    // MARK: - revive: guard — only from Cluster B

    @Test(".revive on a Cluster A row (active) throws the Cluster B guard")
    func revive_fromActive_throwsClusterBGuard() async throws {
        let estate = try await makeEstate()
        let drawer = try await captureActive(in: estate)

        let thrown = await #expect(throws: LocusKitError.self) {
            try await estate.mutate(rowID: drawer.id, kind: .revive)
        }
        if case .invalidContent(let msg)? = thrown {
            #expect(
                msg.contains("revive") || msg.contains("Cluster B") || msg.contains("cluster"),
                "error should identify the revive guard"
            )
        } else {
            Issue.record("expected LocusKitError.invalidContent, got \(String(describing: thrown))")
        }
    }

    @Test(".revive on a Cluster C row (tombstoned) throws the Cluster B guard")
    func revive_fromTerminal_throwsClusterBGuard() async throws {
        let estate = try await makeEstate()
        let drawer = try await captureActive(in: estate)
        try await estate.expunge(rowID: drawer.id, reason: "test", confirmation: true)

        // Tombstoned rows are Cluster C — cannot be revived.
        await #expect(throws: LocusKitError.self) {
            try await estate.mutate(rowID: drawer.id, kind: .revive)
        }
    }

    // MARK: - correctSensitivity: adjective bits 6–11

    @Test(".correctSensitivity(.elevated) writes elevated to adjective bits 6–11")
    func correctSensitivity_elevated_updatesAdjectiveBits() async throws {
        let estate = try await makeEstate()
        let drawer = try await captureActive(in: estate, content: "sensitivity target")
        #expect(drawer.adjectiveSensitivity == .normal)

        try await estate.mutate(rowID: drawer.id, kind: .correctSensitivity(.elevated))

        let after = try await peek(estate, id: drawer.id)
        #expect(after.adjectiveSensitivity == .elevated,
                "sensitivity should be .elevated after correctSensitivity(.elevated)")
        #expect(after.state == .active, "state must be unchanged after correctSensitivity")
    }

    @Test(".correctSensitivity and .correctTrust are independently settable")
    func correctSensitivity_andTrust_areIndependent() async throws {
        let estate = try await makeEstate()
        let drawer = try await captureActive(in: estate)

        try await estate.mutate(rowID: drawer.id, kind: .correctSensitivity(.restricted))
        try await estate.mutate(rowID: drawer.id, kind: .correctTrust(.imported))

        let after = try await peek(estate, id: drawer.id)
        // Each axis settable independently — other axes must be unchanged.
        #expect(after.adjectiveSensitivity == .restricted, "sensitivity must be .restricted")
        #expect(after.trust == .imported, "trust must be .imported")
        #expect(after.state == .active, "state must be unchanged")
    }

    // MARK: - correctTrust: adjective bits 18–23

    @Test(".correctTrust(.derived) writes derived to adjective bits 18–23")
    func correctTrust_derived_updatesAdjectiveBits() async throws {
        let estate = try await makeEstate()
        let drawer = try await captureActive(in: estate, content: "trust target")
        #expect(drawer.trust == .verbatim)

        try await estate.mutate(rowID: drawer.id, kind: .correctTrust(.derived))

        let after = try await peek(estate, id: drawer.id)
        #expect(after.trust == .derived,
                "trust should be .derived after correctTrust(.derived)")
        #expect(after.state == .active, "state must be unchanged after correctTrust")
    }

    // MARK: - Missing row

    @Test(".contest on a missing row throws drawerNotFound")
    func contest_missingRow_throwsNotFound() async throws {
        let estate = try await makeEstate()
        let thrown = await #expect(throws: LocusKitError.self) {
            try await estate.mutate(rowID: "no-such-id", kind: .contest)
        }
        if case .drawerNotFound? = thrown {
            // Correct error type.
        } else {
            Issue.record("expected .drawerNotFound, got \(String(describing: thrown))")
        }
    }
}
