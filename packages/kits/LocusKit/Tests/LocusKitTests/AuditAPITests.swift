import Testing
import SubstrateTypes
import Foundation
@testable import LocusKit
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib

/// Tests for `Estate.auditTrail(rowID:)` and `Estate.bitmapState(rowID:asOf:)`.
/// The cross-row wall-clock window form was dropped: state evolves in
/// ingest-HLC order (DECISION_CLOCK_TRIANGLE_TIME_MODEL §11; wall-clock
/// is not a fold/ordering axis). Capture now emits a sealed genesis
/// event, so a freshly-captured drawer's trail holds the capture event.
///
/// These exercise the typed audit surface that sits on top of the
/// `bitmap_audit` table. `auditTrail` is a straight projection of that
/// table; `bitmapState` runs the spec § 6.8 XOR-fold reconstruction
/// against historical mutations so a row's bitmap state at any past
/// timestamp can be recovered.
@Suite("Estate audit and history API — spec § 7.8.7")
struct AuditAPITests {

    /// Build a fresh estate on a unique temp path. Mirrors the helper
    /// in `EstateVerbTests` — keeping a local copy avoids cross-file
    /// test fixture coupling.
    private func makeEstate() async throws -> (Estate, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locuskit-audit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("estate.sqlite3")
        let estate = try await Estate.create(storage: TestStorage.sqlite(path),
            owner: OwnerCredentials(ownerIdentifier: "test-owner")
        )
        return (estate, path)
    }

    private func sampleFrame(content: String = "audit row") -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "test-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6"
        )
    }

    // MARK: - auditTrail(rowID:)

    @Test("auditTrail(rowID:) after capture returns the genesis capture event")
    func auditTrail_afterCapture_hasGenesisEvent() async throws {
        let (estate, _) = try await makeEstate()
        let drawer = try await estate.capture(sampleFrame())
        let events = try await estate.auditTrail(rowID: drawer.id)
        #expect(events.count == 1)
        #expect(events.first?.verb == "capture")
    }

    @Test("auditTrail(rowID:) after capture + withdraw returns two events: capture then retract")
    func auditTrail_afterWithdraw_genesisPlusRetract() async throws {
        let (estate, _) = try await makeEstate()
        let drawer = try await estate.capture(sampleFrame())
        try await estate.withdraw(rowID: drawer.id, reason: "test withdraw")
        let events = try await estate.auditTrail(rowID: drawer.id)
        #expect(events.count == 2)
        guard events.count == 2 else { return }
        // events[0] = capture (genesis). events[1] = withdraw (verb retract).
        #expect(events[0].verb == "capture")
        #expect(events[1].verb == "retract")
        #expect(events[1].afterBitmaps.adjective & 0x3F == Int64(State.withdrawn.rawValue))
    }

    @Test("auditTrail(rowID:) for capture + withdraw is HLC-ordered ascending")
    func auditTrail_capturePlusWithdraw_orderedAscending() async throws {
        let (estate, _) = try await makeEstate()
        let drawer = try await estate.capture(sampleFrame())
        try await estate.withdraw(rowID: drawer.id, reason: "first")
        let events = try await estate.auditTrail(rowID: drawer.id)
        // Capture (genesis) then withdraw, in HLC order. _setAdjective is
        // a test-only helper that does not pass through the gate and
        // appends no event, so it is not exercised here.
        #expect(events.count == 2)
        if events.count == 2 {
            #expect(events[0].hlc < events[1].hlc)
        }
    }

    // MARK: - bitmapState(rowID:asOf:)

    @Test("bitmapState(rowID:asOf:) at the capture HLC matches the live drawer bitmap")
    func bitmapState_atGenesis_matchesLive() async throws {
        let (estate, _) = try await makeEstate()
        let drawer = try await estate.capture(sampleFrame())
        // The genesis event makes this reconstruction possible. Fold as
        // of the capture HLC; with no mutations on top, it equals the
        // live drawer bitmap.
        let events = try await estate.auditTrail(rowID: drawer.id)
        guard let capHLC = events.first?.hlc else { return }
        let state = try await estate.bitmapState(rowID: drawer.id, asOf: capHLC)
        #expect(state.adjectiveBitmap == drawer.adjectiveBitmap)
        #expect(state.operationalBitmap == drawer.operationalBitmap)
        #expect(state.provenanceBitmap == drawer.provenance)
    }

    @Test("bitmapState(rowID:asOf:) reconstructs the pre-withdraw active state from the audit log fold")
    func bitmapState_atGenesisHLC_isActiveBeforeWithdraw() async throws {
        let (estate, _) = try await makeEstate()
        let drawer = try await estate.capture(sampleFrame())
        // Capture the genesis event's HLC (the moment of remembering),
        // then withdraw. Folding as of the genesis HLC yields the
        // pre-withdraw active state — the genesis event is what makes
        // this reconstruction possible at all.
        let before = try await estate.auditTrail(rowID: drawer.id)
        guard let capHLC = before.first?.hlc else { return }
        try await estate.withdraw(rowID: drawer.id, reason: "after genesis")
        let state = try await estate.bitmapState(rowID: drawer.id, asOf: capHLC)
        // State bits are the low nibble. Active = 0.
        #expect(state.adjectiveBitmap & 0x3F == 0)
    }

    @Test("bitmapState(rowID:asOf:) before the genesis HLC throws drawerNotFound")
    func bitmapState_beforeGenesis_throws() async throws {
        let (estate, _) = try await makeEstate()
        let drawer = try await estate.capture(sampleFrame())
        // An HLC strictly before any event (physical=0). The fold finds
        // no events at or before this asOf → DrawerNotFound (the row
        // had no state yet at that point).
        let beforeAny = HLC(physicalTime: 0, logicalCount: 0, nodeID: 0)
        await #expect(throws: LocusKitError.drawerNotFound(id: drawer.id)) {
            _ = try await estate.bitmapState(rowID: drawer.id, asOf: beforeAny)
        }
    }
}
