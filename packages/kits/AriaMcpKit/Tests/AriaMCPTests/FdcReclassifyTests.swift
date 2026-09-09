import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("FDC reclassification tool", .serialized)
struct FdcReclassifyTests {
    private static let fdcFloorKey = "aria.fdc.recalced_data_version"

    private func makeDispatcher() async throws -> (GeniusLocusKit, EstateHandle, ToolDispatcher) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "fdc-reclassify-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (kit, handle, ToolDispatcher(kit: kit, handle: handle, serverIdentity: "fdc-test"))
    }

    @discardableResult
    private func capture(
        _ kit: GeniusLocusKit,
        _ handle: EstateHandle,
        content: String,
        code: String,
        qid: String? = nil,
        facets: String? = nil,
        secondaryQIDs: String? = nil,
        kind: ContentKind = .prose
    ) async throws -> String {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "fdc-reclassify",
            latticeAnchor: LatticeAnchor(
                udcCode: code,
                udcFacets: facets,
                wikidataQID: qid,
                wikidataQidsSecondary: secondaryQIDs),
            addedBy: "fdc-reclassify-tests",
            embeddingModelID: "test-model-v1",
            kind: kind)
        return try await kit.capture(handle, frame).id
    }

    private func text(_ result: JSONValue) throws -> String {
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        return try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    }

    private func storedCode(_ kit: GeniusLocusKit, _ handle: EstateHandle, id: String) async throws -> String {
        let estate = try await kit.estate(for: handle)
        let drawer = try #require((try await estate.allDrawers()).first { $0.id == id })
        return drawer.udcCode
    }

    private func storedDrawer(_ kit: GeniusLocusKit, _ handle: EstateHandle, id: String) async throws -> Drawer {
        let estate = try await kit.estate(for: handle)
        return try #require((try await estate.allDrawers()).first { $0.id == id })
    }

    private func fdcFloor(_ kit: GeniusLocusKit, _ handle: EstateHandle) async throws -> String? {
        let estate = try await kit.estate(for: handle)
        return try await estate.meta(key: Self.fdcFloorKey)
    }

    // Advisory 1 (FDC-RECLASSIFY-ADVISORIES): apply must repair only the
    // primary udcCode/wikidataQID and carry udcFacets +
    // wikidataQidsSecondary forward unchanged. Before the fix, the apply
    // path constructed the replacement `LatticeAnchor` with only the two
    // primary fields, silently defaulting facets/secondary QIDs to nil and
    // wiping any enrichment a human or the enrichment daemon had attached.

    // RECLASSIFY-PARALLEL: the classify pass now runs across all cores while
    // the audited write stays serial and in scan order. Byte-identical proof
    // for "parallelize a deterministic pure classify + apply in a fixed order":
    //
    //  (1) Invariance — repeated dry-runs over the same estate must produce
    //      byte-identical output. The batch is heterogeneous (two distinct
    //      classify outcomes) and large enough to OVERFLOW the 25-entry
    //      `changes:` cap, so the ORDER of the emitted change list is
    //      observable in the output; a racing write or an order-dependent
    //      classify would perturb the change-list order or the counters across
    //      runs. Dry-run does not mutate, so identical inputs must give
    //      identical output every time.
    //
    //  (2) Golden values — a fresh estate applied through the parallel path
    //      must store the SAME anchor each content classifies to serially:
    //      the git-command drawers resolve to the `000` sentinel and the
    //      biology-prose drawers resolve to a real subject code (neither the
    //      sentinel nor the stale `362.4`). This ties the parallel classify to
    //      the known-correct per-content classifications the other tests pin.
}
