import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("FDC reclassification tool", .serialized)
struct FdcReclassifyTests {

    private func makeDispatcher() async throws -> (GeniusLocusKit, EstateHandle, ToolDispatcher) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "fdc-reclassify-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle, ToolDispatcher(kit: kit, handle: handle, serverIdentity: "fdc-test"))
    }

    @discardableResult
    private func capture(
        _ kit: GeniusLocusKit,
        _ handle: EstateHandle,
        content: String,
        code: String,
        qid: String? = nil
    ) async throws -> String {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "fdc-reclassify",
            latticeAnchor: LatticeAnchor(udcCode: code, wikidataQID: qid),
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
            arguments: .object(["apply": .bool(true)])
        )
        let body = try text(result)
        #expect(body.contains("fdc_reclassify: applied"))
        #expect(body.contains("updated: 1"))
        #expect(try await storedCode(kit, handle, id: id) == "000")
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
    }
}
