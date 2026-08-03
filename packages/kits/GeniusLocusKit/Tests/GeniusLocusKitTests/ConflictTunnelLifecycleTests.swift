// ConflictTunnelLifecycleTests.swift
//
// DCP M5 — tunnel lifecycle, Swift leg. Mirrors the Rust coordinator
// tests one-for-one. Ledger cases: F14 (rejected tunnel; exact repeat
// suppressed), F15 (rejected tunnel; rule-version change → new
// instance), F21 (two conflicting controlled transcripts → one
// proposed contradicts tunnel end-to-end), F22 (later explicit
// replacement → HistoricalSuccession end-to-end).

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateML
@testable import GeniusLocusKit

@Suite("Conflict tunnel lifecycle — typed proposals", .serialized)
struct ConflictTunnelLifecycleTests {

    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func openEstate(
        owner: String
    ) async throws -> (GeniusLocusKit, EstateHandle, LocusKit.Estate) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let creds = OwnerCredentials(ownerIdentifier: owner)
        _ = try await LocusKit.Estate.create(storage: storage, owner: creds)
        let handle = try await kit.open(
            storage: storage, owner: creds,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        let estate = try await kit.estate(for: handle)
        return (kit, handle, estate)
    }

    /// Capture a transcript drawer and file its decisions.
    @discardableResult
    private func fileTranscript(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        content: String, transcript: String
    ) async throws -> (Drawer, MeetingDecisionCaptureReport) {
        let drawer = try await kit.capture(handle, CaptureFrame(
            content: content,
            channel: .typed,
            room: "tunnel-lifecycle-tests",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "tunnel-lifecycle-tests",
            embeddingModelID: "test-model-v1",
            eventTime: Date(timeIntervalSince1970: 1_690_000_000)))
        let report = try await kit.captureMeetingDecisions(
            in: handle, transcript: transcript,
            sourceDrawerID: drawer.id, now: Self.now)
        return (drawer, report)
    }

    /// F21 — two conflicting controlled transcripts produce EXACTLY ONE
    /// proposed contradicts tunnel; a second pass proposes nothing (the
    /// live tunnel suppresses).
    @Test func f21ConflictingTranscriptsProposeOneTunnel() async throws {
        let (kit, handle, estate) = try await openEstate(owner: "tunnel-f21")
        try await fileTranscript(kit, handle, content: "Monday meeting.",
            transcript: "Decision: project-phoenix.launch_date = 2026-09-15")
        try await fileTranscript(kit, handle, content: "Thursday meeting.",
            transcript: "Decision: project-phoenix.launch_date = 2026-10-01")

        let first = try await kit.proposeConflictTunnels(in: handle, now: Self.now)
        #expect(first.sweep.counts.provenContradiction == 1)
        #expect(first.proposedTunnelIDs.count == 1)
        #expect(first.suppressed == 0)
        let tunnels = try await estate.allTunnels().filter { $0.kind == .contradicts }
        #expect(tunnels.count == 1)
        #expect(tunnels.first?.lifecycle == .proposed)
        #expect(tunnels.first?.label.hasPrefix("dcp: dim.decision.launch_date@1") == true)

        let second = try await kit.proposeConflictTunnels(in: handle, now: Self.now)
        #expect(second.proposedTunnelIDs.isEmpty)
        #expect(second.suppressed == 1)
    }

    /// F14/F15 — a WITHDRAWN typed proposal suppresses the exact
    /// rule@version repeat; an older-version rejection does not.
    @Test func f14f15RejectionDurabilityAndVersionRenewal() async throws {
        let (kit, handle, estate) = try await openEstate(owner: "tunnel-f14")
        let (drawerA, _) = try await fileTranscript(kit, handle,
            content: "Meeting A.",
            transcript: "Decision: project-phoenix.launch_date = 2026-09-15")
        let (drawerB, _) = try await fileTranscript(kit, handle,
            content: "Meeting B.",
            transcript: "Decision: project-phoenix.launch_date = 2026-10-01")

        // Plant a WITHDRAWN typed rejection at the CURRENT rule version.
        let names = try await estate.resolveNodeNames(
            parentNodeIds: [drawerA.parentNodeId, drawerB.parentNodeId])
        let aNames = try #require(names[drawerA.parentNodeId])
        let bNames = try #require(names[drawerB.parentNodeId])
        func plantWithdrawn(label: String) async throws {
            _ = try await estate.capture(TunnelCaptureFrame(
                sourceWing: aNames.wing, sourceRoom: aNames.room,
                targetWing: bNames.wing, targetRoom: bNames.room,
                label: label,
                addedBy: "tunnel-lifecycle-tests",
                sourceDrawerId: drawerA.id,
                targetDrawerId: drawerB.id,
                kind: .contradicts,
                originClass: .derived,
                lifecycle: .withdrawn))
        }
        try await plantWithdrawn(label: "dcp: dim.decision.launch_date@1 result=old")

        // F14: exact rule@version repeat stays rejected.
        let suppressedPass = try await kit.proposeConflictTunnels(in: handle, now: Self.now)
        #expect(suppressedPass.proposedTunnelIDs.isEmpty)
        #expect(suppressedPass.suppressed == 1)

        // F15: rewrite history so the rejection is an OLDER version —
        // fresh estate, older-version withdrawn tunnel, then propose.
        let (kit2, handle2, estate2) = try await openEstate(owner: "tunnel-f15")
        let (a2, _) = try await fileTranscript(kit2, handle2,
            content: "Meeting A.",
            transcript: "Decision: project-phoenix.launch_date = 2026-09-15")
        let (b2, _) = try await fileTranscript(kit2, handle2,
            content: "Meeting B.",
            transcript: "Decision: project-phoenix.launch_date = 2026-10-01")
        let names2 = try await estate2.resolveNodeNames(
            parentNodeIds: [a2.parentNodeId, b2.parentNodeId])
        let an2 = try #require(names2[a2.parentNodeId])
        let bn2 = try #require(names2[b2.parentNodeId])
        _ = try await estate2.capture(TunnelCaptureFrame(
            sourceWing: an2.wing, sourceRoom: an2.room,
            targetWing: bn2.wing, targetRoom: bn2.room,
            label: "dcp: dim.decision.launch_date@0 result=ancient",
            addedBy: "tunnel-lifecycle-tests",
            sourceDrawerId: a2.id,
            targetDrawerId: b2.id,
            kind: .contradicts,
            originClass: .derived,
            lifecycle: .withdrawn))
        let renewal = try await kit2.proposeConflictTunnels(in: handle2, now: Self.now)
        #expect(renewal.proposedTunnelIDs.count == 1)
        #expect(renewal.suppressed == 0)
    }

    /// A withdrawn LEXICAL (hunter) tunnel does not suppress a typed
    /// proof — a rejected textual guess is not a rejected proof.
    @Test func withdrawnLexicalTunnelDoesNotSuppressTypedProof() async throws {
        let (kit, handle, estate) = try await openEstate(owner: "tunnel-lexical")
        let (a, _) = try await fileTranscript(kit, handle,
            content: "Meeting A.",
            transcript: "Decision: project-phoenix.launch_date = 2026-09-15")
        let (b, _) = try await fileTranscript(kit, handle,
            content: "Meeting B.",
            transcript: "Decision: project-phoenix.launch_date = 2026-10-01")
        let names = try await estate.resolveNodeNames(
            parentNodeIds: [a.parentNodeId, b.parentNodeId])
        let an = try #require(names[a.parentNodeId])
        let bn = try #require(names[b.parentNodeId])
        _ = try await estate.capture(TunnelCaptureFrame(
            sourceWing: an.wing, sourceRoom: an.room,
            targetWing: bn.wing, targetRoom: bn.room,
            label: "hunter: numeric_divergence score=0.9",
            addedBy: "contradiction-hunter",
            sourceDrawerId: a.id,
            targetDrawerId: b.id,
            kind: .contradicts,
            originClass: .derived,
            lifecycle: .withdrawn))
        let pass = try await kit.proposeConflictTunnels(in: handle, now: Self.now)
        #expect(pass.proposedTunnelIDs.count == 1)
    }

    /// F22 — a later `Replaces decision` transcript files an ACTIVE
    /// supersedes tunnel; the next sweep reads the pair as
    /// HistoricalSuccession, and proposals stop.
    @Test func f22ExplicitReplacementBecomesHistorical() async throws {
        let (kit, handle, _) = try await openEstate(owner: "tunnel-f22")
        let (_, first) = try await fileTranscript(kit, handle,
            content: "Monday meeting.",
            transcript: "Decision: project-phoenix.launch_date = 2026-09-15")
        let originalFactID = try #require(first.filedFactIDs.first)
        let (_, second) = try await fileTranscript(kit, handle,
            content: "Thursday meeting.",
            transcript: "Replaces decision \(originalFactID): "
                + "project-phoenix.launch_date = 2026-10-01")
        let (filed, unresolved) = try await kit.fileSupersessions(
            in: handle, report: second, now: Self.now)
        #expect(filed.count == 1)
        #expect(unresolved.isEmpty)

        let sweep = try await kit.conflictProjectionSweep(in: handle)
        #expect(sweep.counts.provenContradiction == 0)
        #expect(sweep.counts.historicalSuccession == 1)
        let proposals = try await kit.proposeConflictTunnels(in: handle, now: Self.now)
        #expect(proposals.proposedTunnelIDs.isEmpty)

        // An unknown replaced-fact id is reported unresolved, not filed.
        let (_, ghost) = try await fileTranscript(kit, handle,
            content: "Friday meeting.",
            transcript: "Replaces decision no-such-fact: "
                + "project-altair.launch_date = 2026-12-01")
        let (ghostFiled, ghostUnresolved) = try await kit.fileSupersessions(
            in: handle, report: ghost, now: Self.now)
        #expect(ghostFiled.isEmpty)
        #expect(ghostUnresolved == ["no-such-fact"])
    }
}
