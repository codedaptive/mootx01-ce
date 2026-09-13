import AriaMCPWire
import CognitionKit
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import AriaMCP

@Suite("ARIA v2 recall and lens contracts")
struct AriaV2RecallLensTests {
    @Test("frozen roster rejects unknown keys and canonicalizes opaque IDs")
    func strictRoster() throws {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let request = try AriaV2RecallLensRequest(tool: "moot_lens_node_motion", arguments: .object(["memory_id": .string(id.uuidString.uppercased())]))
        #expect(request.arguments["memory_id"] == .string(id.uuidString.lowercased()))
        #expect(throws: JSONRPCError.self) { _ = try AriaV2RecallLensRequest(tool: "moot_recall_precise", arguments: .object(["query": .string("x"), "legacy": .bool(true)])) }
        #expect(throws: JSONRPCError.self) { _ = try AriaV2RecallLensRequest(tool: "moot_lens_successors", arguments: .object(["wing": .string("A"), "anchor_memory_id": .string("not-a-uuid")])) }
    }

    @Test("typed authority result is enveloped without legacy response parsing")
    func typedResult() async throws {
        let result = try await AriaV2RecallLensService(authority: RecallLensAuthority()).execute(tool: "moot_recall_precise", arguments: .object(["query": .string("needle")]))
        #expect(result.objectValue?["isError"] == .bool(false))
        #expect(result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["results"] == .array([]))
    }

    @Test("precise recall grammar accepts the source-backed numeric pool")
    func preciseRecallGrammar() throws {
        let request = try AriaV2RecallLensRequest(
            tool: AriaV2RecallLensOperation.recallPrecise.rawValue,
            arguments: .object(["query": .string("needle"), "pool": .integer(30)]))
        #expect(request.operation == .recallPrecise)
        #expect(request.arguments["pool"] == .integer(30))
        #expect(AriaV2SelectedCatalog.descriptors.contains { $0.publicName == request.operation.rawValue })
    }

    @Test("public selected v2 keeps its documented string keystone arguments")
    func publicKeystoneStringCompatibility() throws {
        let request = try AriaV2RecallLensRequest(
            tool: AriaV2RecallLensOperation.lensKeystones.rawValue,
            arguments: .object([
                "wing": .string("work"), "topK": .string("3"), "keystoneOnly": .string("true"),
            ]))
        #expect(request.arguments["topK"] == .string("3"))
        #expect(request.arguments["keystoneOnly"] == .string("true"))
    }

    @Test("extracted recall names call the typed authority directly")
    func selectedRecallDirectCalls() async throws {
        let service = AriaV2RecallLensService(authority: RecallLensAuthority())
        for operation in [
            AriaV2RecallLensOperation.recallPrecise, .recallTemporal, .recallConnected,
            .recallShaped, .recallDistilled, .recallVague, .recallWalk,
        ] {
            let result = try await service.execute(
                tool: operation.rawValue, arguments: .object(["query": .string("needle")]))
            #expect(result.objectValue?["structuredContent"]?.objectValue?["tool"] == .string(operation.rawValue))
            #expect(result.objectValue?["structuredContent"]?.objectValue?["meta"]?.objectValue?["effect"] == .string("read"))
        }
    }

    @Test("v2 recall projection fails closed on raw provenance sensitivity")
    func rawProvenanceProjection() {
        func drawer(_ raw: Int64) -> Drawer {
            Drawer(content: "private body", parentNodeId: "room", addedBy: "test",
                   filedAt: Date(timeIntervalSince1970: 0), embeddingModelID: "test",
                   provenance: raw << 30, sscFacts: "private facts", subject: "private subject")
        }
        for raw in [Int64(0), 16] {
            let projection = AriaV2RecallLensPrivacy.project(drawer: drawer(raw), subject: "private subject", bestSpan: "private body", sscFacts: "private facts", distilled: "private distillate", representation: "distilled")
            #expect(projection.subject == "private subject")
            #expect(projection.bestSpan == "private body")
            #expect(projection.sscFacts == "private facts")
            #expect(projection.distilled == "private distillate")
        }
        for (raw, marker) in [(Int64(32), ResultComposer.restrictedMarker), (Int64(48), ResultComposer.secretMarker)] {
            let projection = AriaV2RecallLensPrivacy.project(drawer: drawer(raw), subject: "private subject", bestSpan: "private body", sscFacts: "private facts", distilled: "private distillate", representation: "distilled")
            #expect(projection.subject == marker)
            #expect(projection.bestSpan == nil && projection.sscFacts == nil && projection.distilled == nil && projection.representation == nil)
        }
        let unknown = AriaV2RecallLensPrivacy.project(drawer: drawer(63), subject: "private subject", bestSpan: "private body", sscFacts: "private facts", distilled: "private distillate", representation: "distilled")
        #expect(unknown.subject == nil)
        #expect(unknown.bestSpan == nil && unknown.sscFacts == nil && unknown.distilled == nil && unknown.representation == nil)
    }

    @Test("filtered drawers cannot leak a pre-hydration distillate")
    func unavailableDrawerOmitsDistilledRepresentation() {
        let row = AriaV2RecallLensPrivacy.unavailableRow(
            id: "filtered-id", eventTime: "-", score: 0.9,
            retrievalSource: "distilled", tier: "summary",
            discardedDistilled: "private pre-hydration distillate",
            discardedRepresentation: "distilled")
        #expect(row.id == "filtered-id")
        #expect(row.score == 0.9)
        #expect(row.distilled == nil)
        #expect(row.representation == nil)
    }

    // MARK: - Distilled recall savings gate

    /// Open a scratch in-memory estate holding five distinct bodies. The
    /// fourth carries secret provenance, so the v2 privacy projection withholds
    /// its body and it must count on neither side of the savings figure.
    private func distilledEstate() async throws -> (GeniusLocusKit, EstateHandle, [String: String], String) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-v2-recall-lens-tests")
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let bodies = [
            "savings-probe alpha: the reactor schedule moved to March and Sarah approved the reactor plan.",
            "savings-probe beta: vendor contracts were renewed in Geneva and every term held.",
            "savings-probe gamma: travel policy updates landed and flights now require approval.",
            "savings-probe delta: this secret body must never reach either token sum.",
            "savings-probe epsilon: the quarterly forecast covers revenue targets and team velocity.",
        ]
        var bodyByID: [String: String] = [:]
        var secretID = ""
        for (index, body) in bodies.enumerated() {
            let drawer = try await kit.capture(handle, CaptureFrame(
                content: body, channel: .typed, room: "notes", latticeAnchor: .udc("0"),
                addedBy: "aria-v2-recall-lens-tests", embeddingModelID: "test-v1",
                provenanceSensitivity: index == 3 ? .secret : .normal))
            bodyByID[drawer.id] = body
            if index == 3 { secretID = drawer.id }
        }
        return (kit, handle, bodyByID, secretID)
    }

    // MARK: - Projected recall bestSpan gate

    /// Operation: `moot_recall_precise`. Entry point: `AriaV2GeniusLocusRecallLensAuthority.execute`
    /// → `precise` → `projectedResult` (the shipped server path — no row construction by hand).
    ///
    /// The fixture has subject and content deliberately different so `structuredRowObject` cannot
    /// fire the omit-when-identical branch. This test goes red when `projectedResult` fetches
    /// drawers at `.structured` hydration, because `drawer.content` is then `""` and `bestSpan`
    /// evaluates to `nil`. It goes green only when `.full` hydration is used, which is the fix.
    @Test("projected precise recall row carries bestSpan equal to drawer content")
    func projectedRecallRowCarriesBestSpan() async throws {
        // Subject and content are DIFFERENT so the omit-when-identical branch in
        // structuredRowObject cannot fire and suppress the field.
        let subject = "projected-bestspan-gate: a short subject"
        let content = "projected-bestspan-gate: the body is longer than the subject and must appear as bestSpan"

        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-v2-projected-bestspan-tests")
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        _ = try await kit.capture(handle, CaptureFrame(
            content: content, channel: .typed, room: "notes", latticeAnchor: .udc("0"),
            addedBy: "aria-v2-projected-bestspan-tests", embeddingModelID: "test-v1",
            subject: subject))

        let authority = AriaV2GeniusLocusRecallLensAuthority(kit: kit, handle: handle)
        let outcome = try await authority.execute(try AriaV2RecallLensRequest(
            tool: "moot_recall_precise",
            arguments: .object(["query": .string("projected-bestspan-gate")])))
        let data = try #require(outcome.data.objectValue)
        let results = try #require(data["results"]?.arrayValue)
        let row = try #require(
            results.first(where: { $0.objectValue?["subject"] == .string(subject) })?.objectValue,
            "the captured row must appear in precise recall results")
        #expect(
            row["bestSpan"] == .string(content),
            "projected recall row must carry bestSpan equal to the drawer content; got \(row)")
    }

    @Test("distilled recall savings cover only the emitted rows that carry a distilled body")
    func distilledSavingsCoverEmittedRowsOnly() async throws {
        let (kit, handle, bodyByID, secretID) = try await distilledEstate()
        let authority = AriaV2GeniusLocusRecallLensAuthority(kit: kit, handle: handle)
        let outcome = try await authority.execute(try AriaV2RecallLensRequest(
            tool: "moot_recall_distilled",
            arguments: .object(["query": .string("savings-probe"), "limit": .integer(100)])))
        let data = try #require(outcome.data.objectValue)
        let results = try #require(data["results"]?.arrayValue)
        let distillation = try #require(data["capabilities"]?.objectValue?["distillation"]?.objectValue)

        // Expected sums: the estimator over the emitted distilled strings and
        // over the captured bodies of those same rows, joined by id.
        var expectedReturned: Int64 = 0
        var expectedOriginal: Int64 = 0
        var secretRowSeen = false
        for row in results {
            let object = try #require(row.objectValue)
            let id = try #require(object["id"]?.stringValue)
            if id == secretID {
                secretRowSeen = true
                #expect(object["distilled"] == nil, "the secret row must carry no distilled body")
                continue
            }
            guard let distilled = object["distilled"]?.stringValue else { continue }
            let body = try #require(bodyByID[id], "every emitted distilled row is a captured record")
            expectedReturned += GeniusLocusKit.estimatedTokenCount(of: distilled)
            expectedOriginal += GeniusLocusKit.estimatedTokenCount(of: body)
        }
        #expect(secretRowSeen, "the secret row is present in results")
        #expect(expectedReturned > 0, "the probe query must return distilled bodies")
        #expect(distillation["returnedTokens"] == .integer(expectedReturned))
        #expect(distillation["originalTokens"] == .integer(expectedOriginal))
        #expect(distillation["estimated"] == .bool(true))
        #expect(distillation["estimator"] == .string(DistilledSavings.estimatorName))
        #expect(distillation["skim"] == nil)
        let display = try #require(distillation["display"]?.stringValue)
        #expect(display.hasPrefix("\u{1F331} Distilled: ~"))
        #expect(outcome.compactText.hasSuffix("\n" + display))
    }

    @Test("distilled recall with no rows still reports the zero distillation object")
    func distilledSavingsOnEmptyResultAreZero() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-v2-recall-lens-tests")
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let authority = AriaV2GeniusLocusRecallLensAuthority(kit: kit, handle: handle)
        let outcome = try await authority.execute(try AriaV2RecallLensRequest(
            tool: "moot_recall_distilled", arguments: .object(["query": .string("savings-probe")])))
        let data = try #require(outcome.data.objectValue)
        #expect(data["results"] == .array([]))
        let distillation = try #require(data["capabilities"]?.objectValue?["distillation"]?.objectValue)
        let zero = "\u{1F331} Distilled: ~0 tokens returned vs ~0 original \u{00B7} ~0 saved (0%)"
        #expect(distillation["returnedTokens"] == .integer(0))
        #expect(distillation["originalTokens"] == .integer(0))
        #expect(distillation["display"] == .string(zero))
        #expect(outcome.compactText == "Returned 0 distilled recall result(s).\n" + zero)
    }

    @Test("precise recall carries no distillation object")
    func preciseRecallCarriesNoDistillation() async throws {
        let (kit, handle, _, _) = try await distilledEstate()
        let authority = AriaV2GeniusLocusRecallLensAuthority(kit: kit, handle: handle)
        let outcome = try await authority.execute(try AriaV2RecallLensRequest(
            tool: "moot_recall_precise", arguments: .object(["query": .string("savings-probe")])))
        let data = try #require(outcome.data.objectValue)
        #expect(data["capabilities"]?.objectValue?["distillation"] == nil)
        #expect(!outcome.compactText.contains("\u{1F331}"))
    }
}

private struct RecallLensAuthority: AriaV2RecallLensAuthority {
    func execute(_ request: AriaV2RecallLensRequest) async throws -> AriaV2RecallLensOutcome {
        return .init(data: .object(["results": .array([])]), compactText: "No \(request.operation.rawValue) results.")
    }
}
