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
        secondaryQIDs: String? = nil
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
            embeddingModelID: "test-model-v1")
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

    @Test func dryRunReportsSuspectButDoesNotMutate() async throws {
        let (kit, handle, dispatcher) = try await makeDispatcher()
        let id = try await capture(
            kit,
            handle,
            content: "```swift\nlet read_signal = try store.readSignal()\n```",
            code: "362.4",
            qid: "Q12131")

        let result = try await dispatcher.dispatch(
            name: "moot_reclassify_fdc",
            arguments: .object([:])
        )
        let body = try text(result)
        #expect(body.contains("fdc_reclassify: dry-run"))
        #expect(body.contains("candidates: 1"))
        #expect(body.contains("would_update: 1"))
        #expect(body.contains("\(id): 362.4 [Q12131] -> 000"))
        #expect(try await storedCode(kit, handle, id: id) == "362.4")
        #expect(try await fdcFloor(kit, handle) == nil)
    }

    @Test func applyRepairsSuspectFalsePositiveToUnclassifiedSentinel() async throws {
        let (kit, handle, dispatcher) = try await makeDispatcher()
        let id = try await capture(
            kit,
            handle,
            content: "git update-index --refresh && rm .git/index.lock",
            code: "362.4",
            qid: "Q12131")

        let result = try await dispatcher.dispatch(
            name: "moot_reclassify_fdc",
            arguments: .object(["apply": .bool(true), "mode": .string("all")])
        )
        let body = try text(result)
        #expect(body.contains("fdc_reclassify: applied"))
        #expect(body.contains("fdc_data_version: "))
        #expect(body.contains("floor_stamp: stamped"))
        #expect(body.contains("updated: 1"))
        #expect(try await storedCode(kit, handle, id: id) == "000")
        #expect(try await fdcFloor(kit, handle)?.contains("classifier:4.0.0") == true)

        let status = try await dispatcher.dispatch(
            name: "moot_estate_status", arguments: .object([:]))
        #expect(try text(status).contains("fdc_recalculation: current"))
    }

    @Test func suspectOnlyDoesNotOverwriteBroadCodeChangeWithoutAllMode() async throws {
        let (kit, handle, dispatcher) = try await makeDispatcher()
        _ = try await capture(
            kit,
            handle,
            content: "Biology is the scientific study of life and living organisms " +
                "including their physical structure chemical processes molecular " +
                "interactions physiological mechanisms and evolution",
            code: "362.4")

        let conservative = try await dispatcher.dispatch(
            name: "moot_reclassify_fdc",
            arguments: .object([:])
        )
        let conservativeBody = try text(conservative)
        #expect(conservativeBody.contains("candidates: 0"))
        #expect(conservativeBody.contains("skipped_non_candidate_changes: 1"))
        #expect(conservativeBody.contains("mode=all"))

        let reset = try await dispatcher.dispatch(
            name: "moot_reclassify_fdc",
            arguments: .object(["mode": .string("all")])
        )
        let resetBody = try text(reset)
        #expect(resetBody.contains("mode: all"))
        #expect(resetBody.contains("candidates: 1"))
        #expect(resetBody.contains("would_update: 1"))
        #expect(try await fdcFloor(kit, handle) == nil)
    }

    @Test func applyDoesNotStampFloorWhenLimited() async throws {
        let (kit, handle, dispatcher) = try await makeDispatcher()
        _ = try await capture(
            kit,
            handle,
            content: "git update-index --refresh && rm .git/index.lock",
            code: "362.4",
            qid: "Q12131")

        let result = try await dispatcher.dispatch(
            name: "moot_reclassify_fdc",
            arguments: .object([
                "apply": .bool(true), "mode": .string("all"), "limit": .integer(1)
            ])
        )
        let body = try text(result)
        #expect(body.contains("fdc_reclassify: applied"))
        #expect(body.contains("floor_stamp: skipped: limited run cannot update estate-wide floor"))
        #expect(try await fdcFloor(kit, handle) == nil)
    }

    @Test func conservativeApplyDoesNotStampEstateFloor() async throws {
        let (kit, handle, dispatcher) = try await makeDispatcher()
        _ = try await capture(
            kit,
            handle,
            content: "Biology is the scientific study of life and living organisms " +
                "including their physical structure chemical processes molecular " +
                "interactions physiological mechanisms and evolution",
            code: "362.4")

        let result = try await dispatcher.dispatch(
            name: "moot_reclassify_fdc",
            arguments: .object(["apply": .bool(true)])
        )
        let body = try text(result)
        #expect(body.contains("fdc_reclassify: applied"))
        #expect(body.contains("skipped_non_candidate_changes: 1"))
        #expect(body.contains("floor_stamp: skipped: mode=all is required for an estate-wide floor"))
        #expect(try await fdcFloor(kit, handle) == nil)
    }

    @Test func estateStatusDistinguishesMissingAndStaleFDCFloors() async throws {
        let (kit, handle, dispatcher) = try await makeDispatcher()
        let missing = try await dispatcher.dispatch(
            name: "moot_estate_status", arguments: .object([:]))
        #expect(try text(missing).contains("fdc_recalculation: missing"))

        let estate = try await kit.estate(for: handle)
        try await estate.setMeta(key: Self.fdcFloorKey, value: "classifier:old")
        let stale = try await dispatcher.dispatch(
            name: "moot_estate_status", arguments: .object([:]))
        #expect(try text(stale).contains("fdc_recalculation: stale"))
    }

    // Advisory 1 (FDC-RECLASSIFY-ADVISORIES): apply must repair only the
    // primary udcCode/wikidataQID and carry udcFacets +
    // wikidataQidsSecondary forward unchanged. Before the fix, the apply
    // path constructed the replacement `LatticeAnchor` with only the two
    // primary fields, silently defaulting facets/secondary QIDs to nil and
    // wiping any enrichment a human or the enrichment daemon had attached.
    @Test func applyRepairsPrimaryCodeButRetainsFacetsAndSecondaryQIDs() async throws {
        let (kit, handle, dispatcher) = try await makeDispatcher()
        let id = try await capture(
            kit,
            handle,
            content: "git update-index --refresh && rm .git/index.lock",
            code: "362.4",
            qid: "Q12131",
            facets: "004, 621",
            secondaryQIDs: "Q999, Q1000")

        let result = try await dispatcher.dispatch(
            name: "moot_reclassify_fdc",
            arguments: .object(["apply": .bool(true)])
        )
        let body = try text(result)
        #expect(body.contains("fdc_reclassify: applied"))
        #expect(body.contains("updated: 1"))

        let drawer = try await storedDrawer(kit, handle, id: id)
        #expect(drawer.udcCode == "000")
        #expect(drawer.udcFacets == "004, 621")
        #expect(drawer.wikidataQidsSecondary == "Q999, Q1000")
    }
}
