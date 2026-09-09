import AriaMCPWire
import Foundation
import LocusKit
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
}

private struct RecallLensAuthority: AriaV2RecallLensAuthority {
    func execute(_ request: AriaV2RecallLensRequest) async throws -> AriaV2RecallLensOutcome {
        return .init(data: .object(["results": .array([])]), compactText: "No \(request.operation.rawValue) results.")
    }
}
