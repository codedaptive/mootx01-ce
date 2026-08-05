// MeetingDecisionCaptureTests.swift
//
// DCP M6 — filing seam, Swift leg. The deterministic fact-id literal is
// the CROSS-PORT FIXTURE shared with the Rust coordinator test. The
// end-to-end case is the F21 precursor: two conflicting controlled
// transcripts → filed facts → typed sweep proves the contradiction
// (the proposed contradicts tunnel on top of this is M5).

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateML
@testable import GeniusLocusKit

@Suite("Meeting decision capture — filing seam", .serialized)
struct MeetingDecisionCaptureTests {

    private func openEstate(
        owner: String
    ) async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let creds = OwnerCredentials(ownerIdentifier: owner)
        _ = try await LocusKit.Estate.create(storage: storage, owner: creds)
        let handle = try await kit.open(
            storage: storage, owner: creds,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (kit, handle)
    }

    private func captureTranscriptDrawer(
        _ kit: GeniusLocusKit, _ handle: EstateHandle, content: String
    ) async throws -> Drawer {
        try await kit.capture(handle, CaptureFrame(
            content: content,
            channel: .typed,
            room: "meeting-tests",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "meeting-decision-tests",
            embeddingModelID: "test-model-v1",
            eventTime: Date(timeIntervalSince1970: 1_690_000_000)))
    }

    /// A decision extracted from a Secret transcript is itself Secret.
    ///
    /// The seam routes through `captureKGFact`, so the decision inherits the
    /// transcript drawer's adjective and provenance bitmaps rather than filing
    /// at the Normal default. Against pre-MXE-KH code the filed fact carried a
    /// zero bitmap and was disclosed by the fact-search ceiling.
    @Test func decisionsFromASecretTranscriptInheritSecrecy() async throws {
        let (kit, handle) = try await openEstate(owner: "meeting-secrecy")
        let estate = try await kit.estate(for: handle)
        let secretTranscript = try await estate.capture(CaptureFrame(
            content: "Meeting transcript, closed session.",
            channel: .typed,
            room: "meeting-tests",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "meeting-decision-tests",
            embeddingModelID: "test-model-v1",
            sensitivity: .secret,
            eventTime: Date(timeIntervalSince1970: 1_690_000_000)))

        let report = try await kit.captureMeetingDecisions(
            in: handle,
            transcript: """
            Attendees: the platform group.
            Decision: project-phoenix.launch_date = 2026-09-15
            """,
            sourceDrawerID: secretTranscript.id,
            now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(report.filedFactIDs.count == 1)

        let facts = try await kit.recallKGFacts(handle)
        let filed = try #require(facts.first { $0.id == report.filedFactIDs[0] })
        #expect(filed.adjectiveSensitivity == .secret,
                "a decision from a Secret transcript must itself be Secret")
        #expect(filed.adjectiveBitmap == secretTranscript.adjectiveBitmap,
                "the transcript's adjective bitmap must be carried verbatim")
        #expect(!filed.adjectiveSensitivity.isBulkExportable,
                "a Secret decision must fall outside the disclosure ceiling")
    }

    /// A decision whose source drawer does not exist fails the write rather
    /// than filing at the Normal default.
    @Test func decisionWithMissingSourceDrawerFails() async throws {
        let (kit, handle) = try await openEstate(owner: "meeting-missing-source")
        await #expect(throws: GeniusLocusKitError.sourceDrawerNotFound(
            drawerID: "no-such-drawer")) {
            _ = try await kit.captureMeetingDecisions(
                in: handle,
                transcript: """
                Attendees: the platform group.
                Decision: project-phoenix.launch_date = 2026-09-15
                """,
                sourceDrawerID: "no-such-drawer",
                now: Date(timeIntervalSince1970: 1_700_000_000))
        }
    }

    /// Golden deterministic fact id (generated once, pinned in both ports).
    @Test func goldenFactID() {
        #expect(GeniusLocusKit.meetingDecisionFactID(
            sourceDrawerID: "drawer-t1", subject: "project-phoenix",
            predicate: "decision:launch_date", object: "2026-09-15")
            == "a4adaa374550adaeb5fdd72c6648f983567217fc1f6ad2b1b39dc30a8b6d89ac")
    }

    /// Accepted lines file as ACTIVE facts; a replay of the same
    /// transcript skips every id instead of erroring or duplicating.
    @Test func filesActiveAndReplaysSafely() async throws {
        let (kit, handle) = try await openEstate(owner: "meeting-filing")
        let drawer = try await captureTranscriptDrawer(
            kit, handle, content: "Meeting transcript one.")
        let transcript = """
        Attendees: the platform group.
        Decision: project-phoenix.launch_date = 2026-09-15
        Decision: they.launch_date = 2026-10-01
        """
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try await kit.captureMeetingDecisions(
            in: handle, transcript: transcript,
            sourceDrawerID: drawer.id, now: now)
        #expect(first.filedFactIDs.count == 1)
        #expect(first.skippedExistingIDs.isEmpty)
        #expect(first.extraction.rejected.map(\.reason) == [.pronounEntity])

        let estate = try await kit.estate(for: handle)
        let facts = try await estate.allKGFacts()
        let filedFact = try #require(facts.first { $0.id == first.filedFactIDs[0] })
        #expect(filedFact.state == .active)
        #expect(filedFact.predicate == "decision:launch_date")
        #expect(filedFact.sourceDrawerID == drawer.id)

        let replay = try await kit.captureMeetingDecisions(
            in: handle, transcript: transcript,
            sourceDrawerID: drawer.id, now: now)
        #expect(replay.filedFactIDs.isEmpty)
        #expect(replay.skippedExistingIDs == first.filedFactIDs)
    }

    /// The `Replaces decision <id>` reference lands in the report keyed
    /// by the filed fact id (the M5 supersession wiring input).
    @Test func replacesReferenceIsCarried() async throws {
        let (kit, handle) = try await openEstate(owner: "meeting-replaces")
        let drawer = try await captureTranscriptDrawer(
            kit, handle, content: "Meeting transcript two.")
        let report = try await kit.captureMeetingDecisions(
            in: handle,
            transcript: "Replaces decision abc-123: project-phoenix.launch_date = 2026-10-01",
            sourceDrawerID: drawer.id,
            now: Date(timeIntervalSince1970: 1_700_000_000))
        let factID = try #require(report.filedFactIDs.first)
        #expect(report.replacesByFactID[factID] == "abc-123")
    }

    /// F21 precursor — two conflicting controlled transcripts, filed
    /// from two drawers, prove a contradiction through the typed sweep.
    @Test func conflictingTranscriptsProveThroughSweep() async throws {
        let (kit, handle) = try await openEstate(owner: "meeting-conflict")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let drawerA = try await captureTranscriptDrawer(
            kit, handle, content: "Monday planning meeting.")
        let drawerB = try await captureTranscriptDrawer(
            kit, handle, content: "Thursday follow-up meeting.")
        _ = try await kit.captureMeetingDecisions(
            in: handle,
            transcript: "Decision: project-phoenix.launch_date = 2026-09-15",
            sourceDrawerID: drawerA.id, now: now)
        _ = try await kit.captureMeetingDecisions(
            in: handle,
            transcript: "Decision: project-phoenix.launch_date = 2026-10-01",
            sourceDrawerID: drawerB.id, now: now)

        let report = try await kit.conflictProjectionSweep(in: handle)
        #expect(report.diagnostics.projected == 2)
        #expect(report.counts.provenContradiction == 1)
        let finding = try #require(report.proven.first)
        #expect(finding.outcome.key == "decision:project-phoenix")
        #expect(finding.outcome.dimension == "decision:launch_date")
    }
}
