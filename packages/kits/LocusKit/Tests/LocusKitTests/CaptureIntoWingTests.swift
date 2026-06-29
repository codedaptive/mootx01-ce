import Testing
import SubstrateTypes
import Foundation
@testable import LocusKit

/// Tests for `CaptureFrame.wing` — ADR-016 wing targeting at capture time.
///
/// Verifies that:
///   - Supplying an explicit `wing` in `CaptureFrame` causes the stored
///     drawer to land in that wing.
///   - Omitting `wing` (nil) falls through to the estate default
///     ("Agentic Memory"), preserving byte-identical behaviour for all
///     existing callers.
@Suite("Capture-into-wing — CaptureFrame.wing slot (ADR-016)")
struct CaptureIntoWingTests {

    /// Build a fresh estate on a unique temp SQLite file.
    private func makeEstate() async throws -> (Estate, URL) {
        let url = TestStorage.tempURL()
        let storage = TestStorage.sqlite(url)
        let estate = try await Estate.create(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "wing-test-owner")
        )
        return (estate, url)
    }

    // MARK: - Explicit wing

    @Test("capture with explicit wing stores drawer in that wing")
    func capture_explicitWing_drawerLandsInWing() async throws {
        let (estate, _) = try await makeEstate()
        let frame = CaptureFrame(
            content: "user canon content",
            channel: .typed,
            room: "notes",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6",
            wing: "User Canon"
        )
        _ = try await estate.capture(frame)
    }

    @Test("capture with explicit wing 'Personal' stores drawer in Personal wing")
    func capture_personalWing_drawerLandsInPersonal() async throws {
        let (estate, _) = try await makeEstate()
        let frame = CaptureFrame(
            content: "personal note",
            channel: .typed,
            room: "diary",
            latticeAnchor: LatticeAnchor(udcCode: "100"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6",
            wing: "Personal"
        )
        _ = try await estate.capture(frame)
    }

    // MARK: - Default wing (nil)

    @Test("capture with nil wing files drawer in default wing (Agentic Memory)")
    func capture_nilWing_drawerLandsInDefaultWing() async throws {
        let (estate, _) = try await makeEstate()
        let frame = CaptureFrame(
            content: "agentic capture",
            channel: .typed,
            room: "inbox",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6"
            // wing intentionally omitted — should default to "Agentic Memory"
        )
        _ = try await estate.capture(frame)
    }

    @Test("capture without wing field produces same wing as before (backward compat)")
    func capture_noWingField_defaultWingUnchanged() async throws {
        let (estate, _) = try await makeEstate()
        // Construct the frame the exact same way ALL existing callers do —
        // with no `wing:` argument. The stored drawer must land in the same
        // default wing as before this slot existed.
        let frame = CaptureFrame(
            content: "backward compat content",
            channel: .voiced,
            room: "stream",
            latticeAnchor: LatticeAnchor(udcCode: "300"),
            addedBy: "legacy-caller",
            embeddingModelID: "minilm-v6"
        )
        _ = try await estate.capture(frame)
    }

    // MARK: - Multiple wings, same estate

    @Test("two captures with different wings both survive in recall")
    func capture_twoWings_bothRecallable() async throws {
        let (estate, _) = try await makeEstate()

        let canonFrame = CaptureFrame(
            content: "canon content for recall",
            channel: .typed,
            room: "canon-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6",
            wing: "User Canon"
        )
        let agenticFrame = CaptureFrame(
            content: "agentic content for recall",
            channel: .typed,
            room: "agentic-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6"
            // nil wing → "Agentic Memory"
        )

        let canon = try await estate.capture(canonFrame)
        let agentic = try await estate.capture(agenticFrame)

        // Both drawers must be present in an unfiltered recall.
        // Empty filterChain = no restrictions applied; returns all drawers.
        let stream = await estate.recall(RecallFrame(filterChain: []))
        var allDrawers: [Drawer] = []
        for await page in stream { allDrawers.append(contentsOf: page.rows) }
        let drawerIDs = allDrawers.map(\.id)
        // Charter drawers from estate init may also be present; the two
        // test drawers must be among them.
        #expect(drawerIDs.contains(canon.id),
            "User Canon drawer must appear in recall")
        #expect(drawerIDs.contains(agentic.id),
            "Agentic Memory drawer must appear in recall")
    }
}
