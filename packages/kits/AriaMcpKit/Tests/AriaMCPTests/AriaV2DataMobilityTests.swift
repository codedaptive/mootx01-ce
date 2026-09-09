import AriaMCPWire
import Foundation
import Testing
@testable import AriaMCP

@Suite("ARIA v2 typed data mobility")
struct AriaV2DataMobilityTests {
    @Test("strictly decodes frozen mobility keys and keeps vault job identities typed")
    func strictRequests() throws {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let request = try AriaV2DataMobilityRequest.decode(tool: "moot_vault_job", arguments: .object(["job_id": .string(id.uuidString.uppercased())]))
        if case .vaultJob(let parsed) = request {
            #expect(parsed == id)
        } else {
            #expect(Bool(false))
        }
        #expect(throws: JSONRPCError.self) { _ = try AriaV2DataMobilityRequest.decode(tool: "moot_reindex", arguments: .object(["unknown": .bool(true)])) }
        #expect(throws: JSONRPCError.self) { _ = try AriaV2DataMobilityRequest.decode(tool: "moot_file_dataset", arguments: .object(["name": .string("x"), "location": .string("Inbox")])) }
        #expect(throws: JSONRPCError.self) { _ = try AriaV2DataMobilityRequest.decode(tool: "moot_dataset_query", arguments: .object(["dataset_id": .string(id.uuidString), "where": .string("legacy predicate")])) }
        #expect(throws: JSONRPCError.self) { _ = try AriaV2DataMobilityRequest.decode(tool: "moot_file_dataset", arguments: .object(["name": .string("x"), "location": .string("Inbox"), "rows": .array([]), "sensitivity": .string("top_secret")])) }
    }

    @Test("dataset predicates and ordering enforce the bounded v2 grammar")
    func boundedDatasetGrammar() throws {
        let id = "11111111-1111-4111-8111-111111111111"
        func decode(where predicate: JSONValue, order: [JSONValue]? = nil) throws {
            var arguments: [String: JSONValue] = [
                "dataset_id": .string(id),
                "where": predicate,
            ]
            if let order { arguments["order_by"] = .array(order) }
            _ = try AriaV2DataMobilityRequest.decode(
                tool: "moot_dataset_query", arguments: .object(arguments))
        }
        func nested(_ depth: Int) -> JSONValue {
            if depth == 1 {
                return .object(["col": .string("count"), "op": .string("gte"), "val": .integer(1)])
            }
            return .object(["and": .array([nested(depth - 1)])])
        }

        try decode(
            where: nested(8),
            order: [.object(["col": .string("count"), "dir": .string("desc")])])
        try decode(where: .object([
            "col": .string("active"), "op": .string("eq"), "val": .bool(true),
        ]))

        let invalid: [JSONValue] = [
            .object(["col": .string("count"), "op": .string("eq"), "val": .null]),
            .object(["col": .string("active"), "op": .string("gt"), "val": .bool(true)]),
            .object(["col": .string("count"), "op": .string("is_null"), "val": .integer(1)]),
            .object(["and": .array([])]),
            .object(["and": .array([nested(1)]), "or": .array([nested(1)])]),
            nested(9),
            .object(["and": .array(Array(repeating: nested(1), count: 128))]),
        ]
        for predicate in invalid {
            #expect(throws: JSONRPCError.self) { try decode(where: predicate) }
        }
        #expect(throws: JSONRPCError.self) {
            try decode(
                where: nested(1),
                order: [.object(["col": .string("count"), "dir": .string("ascending")])])
        }
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2DataMobilityRequest.decode(
                tool: "moot_dataset_query",
                arguments: .object([
                    "dataset_id": .string(id),
                    "limit": .integer(1_001),
                    "columns": .array([.integer(1)]),
                ]))
        }
    }

    @Test("forwards typed outcomes without a legacy response parse")
    func forwardsTypedOutcome() async throws {
        let authority = MobilityAuthority()
        let result = try await AriaV2DataMobility(authority: authority).execute(tool: "moot_reindex", arguments: .object([:]))
        #expect(result.objectValue?["isError"] == .bool(false))
        #expect(result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["state"] == .string("running"))
        #expect(await authority.observedTool() == "moot_reindex")
    }

    @Test("vault job v2 projection reads the typed registry snapshot")
    func vaultJobSnapshotDoesNotParseV1Text() async throws {
        let registry = VaultJobRegistry()
        let rawID = try await registry.checkAndRegister(kind: .import, vaultPath: "/tmp/fixture-vault", maxJobs: 1)
        let id = try #require(UUID(uuidString: rawID))
        await registry.updateProgress(jobID: rawID, processed: 2, total: 5)

        let result = try await AriaV2DataMobility(
            authority: AriaV2VaultLifecycleAuthority(jobRegistry: registry)
        ).execute(tool: "moot_vault_job", arguments: .object(["job_id": .string(id.uuidString)]))
        let data = result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
        #expect(data?["job_id"] == .string(id.uuidString.lowercased()))
        #expect(data?["status"] == .string("running"))
        #expect(data?["progress"]?.objectValue?["processed"] == .integer(2))
        #expect(data?["progress"]?.objectValue?["total"] == .integer(5))
    }
}

private actor MobilityAuthority: AriaV2DataMobilityAuthority {
    private(set) var executedTool: String?
    func observedTool() -> String? { executedTool }
    func execute(_ request: AriaV2DataMobilityRequest) async throws -> AriaV2DataMobilityOutcome {
        executedTool = request.tool
        return .init(data: .object(["state": .string("running")]), compactText: "Reindex scheduled.")
    }
}
