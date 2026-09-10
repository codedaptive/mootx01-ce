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

    // Extract the structured data object from a v2 envelope response.
    // Assertions on moot_reclassify_fdc must use this rather than the
    // text block: content[0].text is capped at 512 Unicode scalars by
    // AriaV2Envelope.compactText(), and the reclassify report exceeds
    // that cap as soon as the change list has any entries.
    private func data(_ result: JSONValue) throws -> [String: JSONValue] {
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        return try #require(obj["structuredContent"]?.objectValue?["data"]?.objectValue)
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
            content: "```bash\nread_signal && git status --short\n```",
            code: "362.4",
            qid: "Q12131")

        let result = try await dispatcher.dispatch(
            name: "moot_reclassify_fdc",
            arguments: .object([:])
        )
        let d = try data(result)
        #expect(d["applied"] == .bool(false))
        #expect(d["candidates"] == .integer(1))
        #expect(d["would_update"] == .integer(1))
        let changes = try #require(d["changes"]?.arrayValue)
        #expect(changes.first?.objectValue?["id"] == .string(id))
        #expect(changes.first?.objectValue?["old_code"] == .string("362.4"))
        #expect(changes.first?.objectValue?["new_code"] == .string("000"))
        #expect(try await storedCode(kit, handle, id: id) == "362.4")
        #expect(try await fdcFloor(kit, handle) == nil)
    }

    @Test func allModeReclassifiesStoredCodeKindsAndAddsLanguageQID() async throws {
        let (kit, handle, dispatcher) = try await makeDispatcher()
        let shortID = try await capture(
            kit, handle, content: "x += 1", code: "362.4", kind: .code)
        let swiftID = try await capture(
            kit, handle,
            content: "import Foundation\npublic struct User { public let name: String }",
            code: "005", kind: .code)

        let result = try await dispatcher.dispatch(
            name: "moot_reclassify_fdc",
            arguments: .object(["apply": .bool(true), "mode": .string("all")]))
        let d = try data(result)
        #expect(d["updated"] == .integer(2))

        let short = try await storedDrawer(kit, handle, id: shortID)
        #expect(short.udcCode == "005")
        #expect(short.wikidataQID == nil)
        let swift = try await storedDrawer(kit, handle, id: swiftID)
        #expect(swift.udcCode == "005")
        #expect(swift.wikidataQID == "Q17118377")
    }

    @Test func suspectOnlyAddsMissingLanguageQIDWhenCodeIsUnchanged() async throws {
        let (kit, handle, dispatcher) = try await makeDispatcher()
        let id = try await capture(
            kit, handle,
            content: "import Foundation\npublic struct User { public let name: String }",
            code: "005", kind: .code)

        let result = try await dispatcher.dispatch(
            name: "moot_reclassify_fdc",
            arguments: .object(["apply": .bool(true)]))
        let d = try data(result)
        #expect(d["mode"] == .string("suspectOnly"))
        #expect(d["updated"] == .integer(1))
        #expect(try await storedDrawer(kit, handle, id: id).wikidataQID == "Q17118377")
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
        let d = try data(result)
        #expect(d["applied"] == .bool(true))
        #expect(d["fdc_data_version"]?.stringValue?.isEmpty == false)
        #expect(d["floor_stamp"] == .string("stamped"))
        #expect(d["updated"] == .integer(1))
        #expect(try await storedCode(kit, handle, id: id) == "000")
        #expect(try await fdcFloor(kit, handle)?.contains("classifier:4.2.0") == true)

        let status = try await dispatcher.dispatch(
            name: "moot_estate_status", arguments: .object([:]))
        let statusData = try data(status)
        #expect(statusData["fdc_recalculation"] == .string("current"))
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
        let conservativeData = try data(conservative)
        // A biology drawer reclassifies to a real subject code (not the 000 sentinel),
        // so suspectOnly mode produces 0 candidates and skips the change as non-suspect.
        #expect(conservativeData["candidates"] == .integer(0))
        #expect(conservativeData["skipped_non_candidate_changes"] == .integer(1))

        let reset = try await dispatcher.dispatch(
            name: "moot_reclassify_fdc",
            arguments: .object(["mode": .string("all")])
        )
        let resetData = try data(reset)
        #expect(resetData["mode"] == .string("all"))
        #expect(resetData["candidates"] == .integer(1))
        #expect(resetData["would_update"] == .integer(1))
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
        let d = try data(result)
        #expect(d["applied"] == .bool(true))
        #expect(d["floor_stamp"] == .string("skipped: limited run cannot update estate-wide floor"))
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
        let d = try data(result)
        #expect(d["applied"] == .bool(true))
        #expect(d["skipped_non_candidate_changes"] == .integer(1))
        #expect(d["floor_stamp"] == .string("skipped: mode=all is required for an estate-wide floor"))
        #expect(try await fdcFloor(kit, handle) == nil)
    }

    @Test func estateStatusDistinguishesMissingAndStaleFDCFloors() async throws {
        let (kit, handle, dispatcher) = try await makeDispatcher()
        let missing = try await dispatcher.dispatch(
            name: "moot_estate_status", arguments: .object([:]))
        let missingData = try data(missing)
        #expect(missingData["fdc_recalculation"] == .string("missing"))

        let estate = try await kit.estate(for: handle)
        try await estate.setMeta(key: Self.fdcFloorKey, value: "classifier:old")
        let stale = try await dispatcher.dispatch(
            name: "moot_estate_status", arguments: .object([:]))
        let staleData = try data(stale)
        #expect(staleData["fdc_recalculation"] == .string("stale"))
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
        let d = try data(result)
        #expect(d["applied"] == .bool(true))
        #expect(d["updated"] == .integer(1))

        let drawer = try await storedDrawer(kit, handle, id: id)
        #expect(drawer.udcCode == "000")
        #expect(drawer.udcFacets == "004, 621")
        #expect(drawer.wikidataQidsSecondary == "Q999, Q1000")
    }

    // RECLASSIFY-PARALLEL: the classify pass now runs across all cores while
    // the audited write stays serial and in scan order. Byte-identical proof
    // for "parallelize a deterministic pure classify + apply in a fixed order":
    //
    //  (1) Invariance — repeated dry-runs over the same estate must produce
    //      identical structured data. The batch is heterogeneous (two distinct
    //      classify outcomes) and large enough to OVERFLOW the 25-entry
    //      `changes:` cap, so the ORDER of the emitted change list is
    //      observable in the data; a racing write or an order-dependent
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
    @Test func parallelClassifyIsDeterministicAndMatchesSerialAnchors() async throws {
        let (kit, handle, dispatcher) = try await makeDispatcher()

        // 20 drawers whose content classifies to the `000` sentinel and 10
        // whose content classifies to a real subject code — a heterogeneous
        // classify workload that saturates the worker pool. All carry a stale
        // `362.4` anchor, so mode=all makes every one a candidate change (30
        // candidates > the 25-example cap ⇒ the change-list order is exercised).
        var sentinelIDs: [String] = []
        var subjectIDs: [String] = []
        for _ in 0..<20 {
            sentinelIDs.append(try await capture(
                kit, handle,
                content: "git update-index --refresh && rm .git/index.lock",
                code: "362.4", qid: "Q12131"))
        }
        for _ in 0..<10 {
            subjectIDs.append(try await capture(
                kit, handle,
                content: "Biology is the scientific study of life and living organisms " +
                    "including their physical structure chemical processes molecular " +
                    "interactions physiological mechanisms and evolution",
                code: "362.4"))
        }

        func dryRunAll() async throws -> [String: JSONValue] {
            try data(try await dispatcher.dispatch(
                name: "moot_reclassify_fdc",
                arguments: .object(["mode": .string("all")])))
        }

        // (1) Invariance across repeated parallel runs: structured data must be
        //     identical every time, including the capped 25-entry change list order.
        let first = try await dryRunAll()
        #expect(first["scanned"] == .integer(30))
        #expect(first["candidates"] == .integer(30))
        #expect(first["would_update"] == .integer(30))
        #expect(first["changes"]?.arrayValue?.count == 25) // capped at 25
        #expect(first["changes_omitted"] == .integer(5))   // 30 candidates − 25 examples
        for _ in 0..<4 {
            #expect(try await dryRunAll() == first)
        }

        // (2) Golden values — apply through the parallel path, then read back.
        let applied = try data(try await dispatcher.dispatch(
            name: "moot_reclassify_fdc",
            arguments: .object(["apply": .bool(true), "mode": .string("all")])))
        #expect(applied["updated"] == .integer(30))
        for id in sentinelIDs {
            #expect(try await storedCode(kit, handle, id: id) == "000")
        }
        for id in subjectIDs {
            let code = try await storedCode(kit, handle, id: id)
            #expect(code != "000")
            #expect(code != "362.4")
        }
    }
}
