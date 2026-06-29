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

    // MARK: - revive: complete state semantics (cookbook §9.3 / §6.2)
    //
    // revive restores a historical row to .active. The four Cluster-B
    // states are legal sources (superseded conditionally); live and
    // terminal states refuse with a named disciplineViolation.

    /// Capture into `.withdrawn` then revive → `.active`.
    @Test("revive: withdrawn → active (unwithdraw), with an audit row")
    func revive_fromWithdrawn_becomesActive() async throws {
        let estate = try await makeEstate()
        let drawer = try await captureActive(in: estate)
        try await estate.withdraw(rowID: drawer.id, reason: "test")
        #expect(try await peek(estate, id: drawer.id).state == .withdrawn)
        let before = try await estate._auditEventCount(rowID: drawer.id)

        try await estate.mutate(rowID: drawer.id, kind: .revive)

        #expect(try await peek(estate, id: drawer.id).state == .active)
        let after = try await estate._auditEventCount(rowID: drawer.id)
        #expect(after == before + 1, "revive must append exactly one audit row")
    }

    /// Stage `.expired` via the test seam, then revive → `.active`.
    @Test("revive: expired → active (TTL revive), with an audit row")
    func revive_fromExpired_becomesActive() async throws {
        let estate = try await makeEstate()
        let drawer = try await captureActive(in: estate)
        // expire is a dreaming-daemon transition, not a MutationKind;
        // stage it directly through the validated mutateState seam.
        try await estate._mutateState(
            rowID: drawer.id, to: .expired, via: .expire, now: Date(timeIntervalSince1970: 1))
        #expect(try await peek(estate, id: drawer.id).state == .expired)

        try await estate.mutate(rowID: drawer.id, kind: .revive)
        #expect(try await peek(estate, id: drawer.id).state == .active)
    }

    /// Stage `.decayed` via the test seam, then revive → `.active`.
    @Test("revive: decayed → active (re-observation), with an audit row")
    func revive_fromDecayed_becomesActive() async throws {
        let estate = try await makeEstate()
        let drawer = try await captureActive(in: estate)
        try await estate._mutateState(
            rowID: drawer.id, to: .decayed, via: .decay, now: Date(timeIntervalSince1970: 1))
        #expect(try await peek(estate, id: drawer.id).state == .decayed)

        try await estate.mutate(rowID: drawer.id, kind: .revive)
        #expect(try await peek(estate, id: drawer.id).state == .active)
    }

    /// A superseded row whose successor was itself withdrawn has a vacant
    /// lineage head — revive is LEGAL and reclaims it.
    @Test("revive: superseded → active LEGAL when the successor is dead (vacant head)")
    func revive_fromSuperseded_deadSuccessor_becomesActive() async throws {
        let estate = try await makeEstate()
        let lineage = UUID()
        // v1 captured into a shared lineage.
        let v1 = try await estate.capture(CaptureFrame(
            content: "v1", channel: .typed, room: "r",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "t", embeddingModelID: "minilm-v6", lineageID: lineage))
        // v2 shares the lineage → supersession cascade flips v1 to superseded.
        let v2 = try await estate.capture(CaptureFrame(
            content: "v2", channel: .typed, room: "r",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "t", embeddingModelID: "minilm-v6", lineageID: lineage))
        #expect(try await peek(estate, id: v1.id).state == .superseded)
        // Kill the successor so the lineage head goes vacant.
        try await estate.withdraw(rowID: v2.id, reason: "test")

        try await estate.mutate(rowID: v1.id, kind: .revive)
        #expect(try await peek(estate, id: v1.id).state == .active,
                "with no living successor, the superseded predecessor reclaims the head")
    }

    /// A superseded row whose successor is still live refuses revive with
    /// the named lineage-conflict domain error.
    @Test("revive: superseded → active REFUSED while a living successor holds the head")
    func revive_fromSuperseded_livingSuccessor_throwsLineageConflict() async throws {
        let estate = try await makeEstate()
        let lineage = UUID()
        let v1 = try await estate.capture(CaptureFrame(
            content: "v1", channel: .typed, room: "r",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "t", embeddingModelID: "minilm-v6", lineageID: lineage))
        let v2 = try await estate.capture(CaptureFrame(
            content: "v2", channel: .typed, room: "r",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "t", embeddingModelID: "minilm-v6", lineageID: lineage))
        #expect(try await peek(estate, id: v1.id).state == .superseded)
        #expect(try await peek(estate, id: v2.id).state == .active) // living successor

        let thrown = await #expect(throws: LocusKitError.self) {
            try await estate.mutate(rowID: v1.id, kind: .revive)
        }
        guard case .disciplineViolation(let from, let to, let reason)? = thrown else {
            Issue.record("expected disciplineViolation, got \(String(describing: thrown))")
            return
        }
        #expect(from == State.superseded.rawValue)
        #expect(to == State.active.rawValue)
        #expect(reason.contains("living successor"), "error must name the lineage conflict")
        #expect(reason.contains(v2.id), "error must name the conflicting successor id")
        // v1 stays superseded; the refused revive changed nothing.
        #expect(try await peek(estate, id: v1.id).state == .superseded)
    }

    @Test("revive: active (Cluster A) REFUSED — row is already live")
    func revive_fromActive_throwsAlreadyLive() async throws {
        let estate = try await makeEstate()
        let drawer = try await captureActive(in: estate)
        let thrown = await #expect(throws: LocusKitError.self) {
            try await estate.mutate(rowID: drawer.id, kind: .revive)
        }
        guard case .disciplineViolation(let from, _, let reason)? = thrown else {
            Issue.record("expected disciplineViolation, got \(String(describing: thrown))")
            return
        }
        #expect(from == State.active.rawValue)
        #expect(reason.contains("already live"))
    }

    // Note: the `.rejected` and `.pending` refusal branches of the revive
    // guard are not exercised E2E here because a Drawer cannot legally reach
    // those states through Estate verbs — drawers are born `.active` and the
    // only reachable terminal is `.tombstoned` (via expunge). Those guard
    // branches are correct domain rules (cookbook §9.3) and the
    // rejected→active refusal is covered at the automaton level by
    // `StateTransitionTests.illegalRejectedToActive`. The `.contested`
    // refusal branch is also unexercised here (the revive-from-contested
    // guard fires, but no test drives that path end-to-end).

    @Test("revive: tombstoned (Cluster C terminal) REFUSED — content erased")
    func revive_fromTombstoned_throwsUnrecoverable() async throws {
        let estate = try await makeEstate()
        let drawer = try await captureActive(in: estate)
        try await estate.expunge(rowID: drawer.id, reason: "test", confirmation: true)
        #expect(try await peek(estate, id: drawer.id).state == .tombstoned)

        let thrown = await #expect(throws: LocusKitError.self) {
            try await estate.mutate(rowID: drawer.id, kind: .revive)
        }
        guard case .disciplineViolation(let from, _, let reason)? = thrown else {
            Issue.record("expected disciplineViolation, got \(String(describing: thrown))")
            return
        }
        #expect(from == State.tombstoned.rawValue)
        #expect(reason.contains("tombstoned") || reason.contains("unrecoverable"))
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

    // MARK: - correctExportability: adjective bits 12–17 (DEBT-1 write path)

    /// Drain a RecallStream to a flat `[Drawer]` array for assertion.
    private func drainStream(_ stream: RecallStream) async -> [Drawer] {
        var rows: [Drawer] = []
        for await page in stream { rows.append(contentsOf: page.rows) }
        return rows
    }

    @Test(".correctExportability(.public_) writes public_ to adjective bits 12–17")
    func correctExportability_public_updatesAdjectiveBits() async throws {
        let estate = try await makeEstate()
        let drawer = try await captureActive(in: estate, content: "exportability target")
        // Default exportability is .private_ (raw 0).
        #expect(drawer.exportability == .private_, "captured drawers default to .private_")

        try await estate.mutate(rowID: drawer.id, kind: .correctExportability(.public_))

        let after = try await peek(estate, id: drawer.id)
        #expect(after.exportability == .public_,
                "exportability should be .public_ after correctExportability(.public_)")
        #expect(after.state == .active, "state must be unchanged after correctExportability")
    }

    @Test(".correctExportability(.private_) lowers a public drawer back to private")
    func correctExportability_private_lowersFromPublic() async throws {
        let estate = try await makeEstate()
        let drawer = try await captureActive(in: estate, content: "re-lower test")

        // Raise to public first.
        try await estate.mutate(rowID: drawer.id, kind: .correctExportability(.public_))
        #expect(try await peek(estate, id: drawer.id).exportability == .public_)

        // Lower back to private.
        try await estate.mutate(rowID: drawer.id, kind: .correctExportability(.private_))

        let after = try await peek(estate, id: drawer.id)
        #expect(after.exportability == .private_,
                "exportability should be .private_ after lowering from public")
    }

    @Test(".correctExportability does not disturb sensitivity or trust axes")
    func correctExportability_doesNotDisturbOtherAdjectiveAxes() async throws {
        let estate = try await makeEstate()
        let drawer = try await captureActive(in: estate)

        // Stage non-default values on the other two adjective axes.
        try await estate.mutate(rowID: drawer.id, kind: .correctSensitivity(.restricted))
        try await estate.mutate(rowID: drawer.id, kind: .correctTrust(.canonical))
        let staged = try await peek(estate, id: drawer.id)
        #expect(staged.adjectiveSensitivity == .restricted)
        #expect(staged.trust == .canonical)

        // Now mutate exportability — the other axes must survive unchanged.
        try await estate.mutate(rowID: drawer.id, kind: .correctExportability(.public_))

        let after = try await peek(estate, id: drawer.id)
        #expect(after.exportability == .public_, "exportability must be .public_")
        #expect(after.adjectiveSensitivity == .restricted, "sensitivity must be unchanged")
        #expect(after.trust == .canonical, "trust must be unchanged")
        #expect(after.state == .active, "state must be unchanged")
    }

    @Test(".correctExportability writes an audit row")
    func correctExportability_writesAuditRow() async throws {
        let estate = try await makeEstate()
        let drawer = try await captureActive(in: estate)
        let before = try await estate._auditEventCount(rowID: drawer.id)

        try await estate.mutate(rowID: drawer.id, kind: .correctExportability(.public_))

        let after = try await estate._auditEventCount(rowID: drawer.id)
        #expect(after == before + 1, "correctExportability must append exactly one audit row")
    }

    @Test("capture born-public: CaptureFrame exportability=.public_ produces .public_ drawer")
    func capture_bornPublic_exportabilityPublic() async throws {
        let estate = try await makeEstate()
        let drawer = try await estate.capture(CaptureFrame(
            content: "born public",
            channel: .typed,
            room: "test-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6",
            exportability: .public_
        ))
        #expect(drawer.exportability == .public_,
                "a drawer captured with exportability: .public_ should be born public")
    }

    @Test("filter:exportable returns public drawers, not private ones")
    func filterExportable_returnsPublicDrawersOnly() async throws {
        let estate = try await makeEstate()

        // Capture a private drawer and confirm it so it passes the default
        // confirmation filter — the test uses an explicit filter chain that
        // includes the confirmation axis.
        let privateDrawer = try await captureActive(in: estate, content: "private content")
        #expect(privateDrawer.exportability == .private_)
        try await estate.mutate(rowID: privateDrawer.id, kind: .confirm)

        // Capture a born-public drawer and confirm it.
        let publicDrawer = try await estate.capture(CaptureFrame(
            content: "public content",
            channel: .typed,
            room: "test-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6",
            exportability: .public_
        ))
        #expect(publicDrawer.exportability == .public_)
        try await estate.mutate(rowID: publicDrawer.id, kind: .confirm)

        // Use an explicit filter chain that includes the required confirmation
        // and state axes so the BitmapEvaluator default-insertion does not
        // suppress results with an incompatible trust or provenance default.
        let chain: [Filter] = [
            .currentlyBelieve, .userConfirmed, .trustworthy,
            .sensitivityAtMost(.elevated), .exportable
        ]
        let rows = await drainStream(estate.recall(RecallFrame(filterChain: chain)))
        let ids = rows.map(\.id)
        #expect(ids.contains(publicDrawer.id),
                "filter:exportable must include the public drawer")
        #expect(!ids.contains(privateDrawer.id),
                "filter:exportable must exclude the private drawer")
    }

    @Test("mutate to public → filter:exportable returns it; mutate back → no longer returned")
    func mutateToPublic_thenFilterExportable_roundtrip() async throws {
        let estate = try await makeEstate()

        // Capture a drawer (private by default) and confirm it so
        // the confirmation axis doesn't suppress it from recall.
        let drawer = try await captureActive(in: estate, content: "mutation roundtrip")
        #expect(drawer.exportability == .private_)
        try await estate.mutate(rowID: drawer.id, kind: .confirm)

        // Explicit filter chain to avoid default provenance filter suppressing results.
        let exportableChain: [Filter] = [
            .currentlyBelieve, .userConfirmed, .trustworthy,
            .sensitivityAtMost(.elevated), .exportable
        ]

        // Before mutation: filter:exportable must return empty (drawer is private).
        let emptyRows = await drainStream(estate.recall(RecallFrame(filterChain: exportableChain)))
        #expect(emptyRows.isEmpty, "before mutation, filter:exportable must return empty")

        // Mutate to public.
        try await estate.mutate(rowID: drawer.id, kind: .correctExportability(.public_))

        // After mutation: filter:exportable must return the drawer.
        let publicRows = await drainStream(estate.recall(RecallFrame(filterChain: exportableChain)))
        #expect(publicRows.map(\.id).contains(drawer.id),
                "after correctExportability(.public_), filter:exportable must return the drawer")

        // Mutate back to private.
        try await estate.mutate(rowID: drawer.id, kind: .correctExportability(.private_))

        // After lowering: filter:exportable must return empty again.
        let privateRows = await drainStream(estate.recall(RecallFrame(filterChain: exportableChain)))
        #expect(privateRows.isEmpty,
                "after re-lowering to private, filter:exportable must return empty")
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
