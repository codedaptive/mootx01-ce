import Testing
import SubstrateTypes
import SubstrateKernel
import Foundation
@testable import LocusKit

/// A-3: the `propose` verb wires the three provenance operational axes
/// (confirmation source 12–17, generated-by class 18–23, confidence bucket
/// 24–29) from `ProposeFrame` into the proposal's `operationalBitmap`, at the
/// exact positions the read accessors in `ProposalOperational.swift` decode.
///
/// Two guarantees are pinned here:
///   1. Round-trip — proposing with non-default provenance reads back the
///      written values after a SQLite store round-trip (`getProposal`), so the
///      bits survive persistence, not just in-memory construction.
///   2. Default byte-identity — a frame that omits the three provenance slots
///      produces the exact same `operationalBitmap` the verb wrote before the
///      slots were wired (kind | target only), proving the additive change is
///      behavior-preserving for existing callers.
@Suite("Propose provenance axes (A-3) — wire confirmation/generatedBy/confidence")
struct ProposeProvenanceTests {

    /// Build a fresh estate on a unique temp path.
    private func makeEstate() async throws -> (Estate, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locuskit-propose-prov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("estate.sqlite3")
        let estate = try await Estate.create(
            storage: TestStorage.sqlite(path),
            owner: OwnerCredentials(ownerIdentifier: "test-owner")
        )
        return (estate, path)
    }

    /// Capture a drawer to serve as a propose target, returning its id.
    private func captureTarget(_ estate: Estate) async throws -> String {
        let frame = CaptureFrame(
            content: "target",
            channel: .typed,
            room: "test-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6"
        )
        return try await estate.capture(frame).id
    }

    @Test("non-default provenance round-trips through the store")
    func nonDefaultProvenance_roundTrips() async throws {
        let (estate, _) = try await makeEstate()
        let target = try await captureTarget(estate)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // Pick a distinct non-zero value on each provenance axis so a cross-wired
        // shift would surface as a mismatched read.
        let frame = ProposeFrame(
            target: target,
            kind: .mutateDrawer,
            justification: "wire check",
            confirmation: .agent,            // raw 1, bits 12–17
            generatedBy: .manual,            // raw 3, bits 18–23
            confidence: .high                // raw 32, bits 24–29
        )
        let returned = try await estate.propose(frame, now: now)

        // 1) the value the verb returned carries the axes.
        #expect(returned.proposalKind == .mutateDrawer)
        #expect(returned.targetObjectType == .drawer)
        #expect(returned.confirmationSource == .agent)
        #expect(returned.generatedByClass == .manual)
        #expect(returned.confidenceBucket == .high)

        // 2) the same values survive a SQLite store round-trip.
        guard let reloaded = try await estate.store.getProposal(id: returned.id) else {
            Issue.record("proposal not found after store round-trip")
            return
        }
        #expect(reloaded.operationalBitmap == returned.operationalBitmap)
        #expect(reloaded.confirmationSource == .agent)
        #expect(reloaded.generatedByClass == .manual)
        #expect(reloaded.confidenceBucket == .high)
    }

    @Test("each provenance enum value writes to its own window")
    func eachProvenanceValue_writesToOwnWindow() async throws {
        let (estate, _) = try await makeEstate()
        let target = try await captureTarget(estate)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // Exhaustively walk every confirmation × generated-by × confidence value
        // so any width/shift error on one axis surfaces as a wrong read on it
        // without disturbing the other two.
        let confirmations: [ProposalConfirmationSource] = [.human, .agent, .automatedThreshold, .actuator]
        let generators: [ProposalGeneratedByClass] = [.dreamingDaemon, .mcpAgent, .federationSync, .manual, .tierAggregator]
        let confidences: [ProposalConfidenceBucket] = [.null, .low, .medium, .high, .verified]

        for c in confirmations {
            for g in generators {
                for conf in confidences {
                    let frame = ProposeFrame(
                        target: target,
                        kind: .newKGFact,
                        confirmation: c,
                        generatedBy: g,
                        confidence: conf
                    )
                    let p = try await estate.propose(frame, now: now)
                    #expect(p.proposalKind == .newKGFact)
                    #expect(p.targetObjectType == .drawer)
                    #expect(p.confirmationSource == c)
                    #expect(p.generatedByClass == g)
                    #expect(p.confidenceBucket == conf)
                }
            }
        }
    }

    @Test("default frame is byte-identical to the pre-wire bitmap")
    func defaultFrame_byteIdentical() async throws {
        let (estate, _) = try await makeEstate()
        let target = try await captureTarget(estate)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // The pre-A-3 propose verb wrote ONLY kind (bits 0–5) and target object
        // type .drawer=0 (bits 6–11); the three provenance windows were zeroed.
        // Reconstruct that exact value independently.
        var expected = BitField.writeField(Int64(ProposalKind.mutateDrawer.rawValue), into: 0, shift: 0, width: 6)
        expected = BitField.writeField(Int64(ProposalTargetObjectType.drawer.rawValue), into: expected, shift: 6, width: 6)

        // A frame that omits the three provenance args takes their defaults
        // (.human / .dreamingDaemon / .null), all raw 0.
        let frame = ProposeFrame(target: target, kind: .mutateDrawer)
        let p = try await estate.propose(frame, now: now)

        #expect(p.operationalBitmap == expected)
        // And the upper provenance windows are all zero.
        #expect(p.confirmationSource == .human)
        #expect(p.generatedByClass == .dreamingDaemon)
        #expect(p.confidenceBucket == .null)
    }
}
