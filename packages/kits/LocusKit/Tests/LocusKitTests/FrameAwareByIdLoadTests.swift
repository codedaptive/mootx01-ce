import Testing
import SubstrateTypes
import Foundation
@testable import LocusKit

/// Tests for the public frame-aware by-id load,
/// `Estate.getDrawers(ids:matchingFrame:hydrationLevel:)`.
///
/// This is the capability GLK's RecallDirector uses to build a drawerIndex that
/// honors the actual recall frame, so corpus-lane candidates drop exactly the
/// frame-excluded set (e.g. `.withdrawn` under the default `.currentlyBelieve`)
/// and still surface under a `.usedToBelieve` override. The `loadedIDs` set lets
/// callers gate a drop on load success (a not-loaded id is degraded, not dropped).
/// Parity peer: rust frame_aware_by_id_load tests (estate_verbs.rs).
@Suite("Frame-aware by-id load — getDrawers(matchingFrame:)")
struct FrameAwareByIdLoadTests {

    private func makeEstate() async throws -> Estate {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locuskit-frameload-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("estate.sqlite3")
        return try await Estate.create(storage: TestStorage.sqlite(path),
            owner: OwnerCredentials(ownerIdentifier: "test-owner"))
    }

    private func frame(_ chain: [Filter]) -> RecallFrame {
        RecallFrame(filterChain: chain, hydrationLevel: .structured,
                    ordering: .byCaptureTimeDesc)
    }

    private func capture(_ estate: Estate, _ content: String) async throws -> Drawer {
        try await estate.capture(CaptureFrame(
            content: content, channel: .typed, room: "r",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "t", embeddingModelID: "m"))
    }

    @Test("default frame admits active, drops withdrawn; both load")
    func defaultFrameDropsWithdrawn() async throws {
        let estate = try await makeEstate()
        let active = try await capture(estate, "active one")
        let gone = try await capture(estate, "withdrawn one")
        try await estate.withdraw(rowID: gone.id, reason: "test")

        let res = try await estate.getDrawers(
            ids: [active.id, gone.id], matchingFrame: frame([.unconfirmed]),
            hydrationLevel: .structured)

        // Both rows physically loaded.
        #expect(res.loadedIDs == Set([active.id, gone.id]),
            "both rows must load regardless of frame filter; got \(res.loadedIDs)")
        // Only the active drawer is frame-admissible under the default
        // (`.currentlyBelieve` implied — withdrawn is Cluster B, excluded).
        #expect(res.admissible.map(\.id) == [active.id],
            "default frame must admit only the active drawer; got \(res.admissible.map(\.id))")
    }

    @Test("`.usedToBelieve` frame admits the withdrawn drawer (not a hardcode)")
    func usedToBelieveAdmitsWithdrawn() async throws {
        let estate = try await makeEstate()
        let active = try await capture(estate, "active one")
        let gone = try await capture(estate, "withdrawn one")
        try await estate.withdraw(rowID: gone.id, reason: "test")

        let res = try await estate.getDrawers(
            ids: [active.id, gone.id],
            matchingFrame: frame([.unconfirmed, .usedToBelieve]),
            hydrationLevel: .structured)

        // The override surfaces the withdrawn (Cluster B) drawer and excludes the
        // active (Cluster A) one — proving the filter is the FRAME's, not a constant.
        #expect(res.admissible.map(\.id) == [gone.id],
            "a .usedToBelieve frame must admit the withdrawn drawer and exclude the active one; got \(res.admissible.map(\.id))")
        #expect(res.admissible.first?.state == .withdrawn,
            "the admitted drawer must be in .withdrawn state")
    }

    @Test("a non-existent id is absent from loadedIDs (degrade, not drop)")
    func missingIdNotLoaded() async throws {
        let estate = try await makeEstate()
        let active = try await capture(estate, "active one")
        let ghost = UUID().uuidString

        let res = try await estate.getDrawers(
            ids: [active.id, ghost], matchingFrame: frame([.unconfirmed]),
            hydrationLevel: .structured)

        // The ghost id did not load — it is absent from BOTH sets, so a caller
        // gating a drop on load success will DEGRADE it (keep), never drop it.
        #expect(!res.loadedIDs.contains(ghost),
            "a non-existent id must be absent from loadedIDs; got \(res.loadedIDs)")
        #expect(res.loadedIDs == Set([active.id]))
        #expect(res.admissible.map(\.id) == [active.id])
    }
}
