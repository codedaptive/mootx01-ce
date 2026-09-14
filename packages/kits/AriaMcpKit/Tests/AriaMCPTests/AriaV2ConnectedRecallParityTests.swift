import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import AriaMCP

/// Swift half of the shared v2 connected-recall vector.  Its Rust twin reads
/// the same fixture and drives the selected public dispatcher, so the vector
/// catches a port drift in either anchor scoping or graph-hit hydration.
@Suite("ARIA v2 connected-recall cross-port parity", .serialized)
struct AriaV2ConnectedRecallParityTests {
    private func vector() throws -> [String: JSONValue] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Conformance/aria_v2_connected_recall_parity_vector.json")
            .standardizedFileURL
        guard let value = try JSONValue.parse(Data(contentsOf: url)).objectValue?["vector"]?.objectValue else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    private func string(_ object: [String: JSONValue], _ key: String) throws -> String {
        guard let value = object[key]?.stringValue else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }

    private func makeDispatcher() async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-v2-connected-recall-parity")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage,
            owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (ToolDispatcher(kit: kit, handle: handle), kit, handle)
    }

    private func fileMemory(
        _ dispatcher: ToolDispatcher,
        content: String,
        location: String,
        exportability: String?
    ) async throws -> String {
        var arguments: [String: JSONValue] = [
            "content": .string(content),
            "subject": .string(content),
            "location": .string(location),
        ]
        if let exportability { arguments["exportability"] = .string(exportability) }
        let result = try await dispatcher.dispatch(name: "moot_file_memory", arguments: .object(arguments))
        return try #require(
            result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["memory_id"]?.stringValue,
            "moot_file_memory must return a selected-v2 memory_id")
    }

    private func rows(_ result: JSONValue) throws -> [[String: JSONValue]] {
        guard let values = result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["results"]?.arrayValue else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return values.compactMap(\.objectValue)
    }

    @Test func sharedVectorKeepsAnchorWingIndependentAndWalkHydrationFiltered() async throws {
        let vector = try vector()
        let anchorSpec = try #require(vector["anchor"]?.objectValue)
        let targetSpec = try #require(vector["target"]?.objectValue)
        let expected = try #require(vector["expected"]?.objectValue)
        let tunnelWing = try string(vector, "tunnel_wing")
        let query = try string(vector, "query")
        let limit = try #require(vector["limit"]?.integerValue)
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        let anchor = try await fileMemory(
            dispatcher,
            content: try string(anchorSpec, "content"),
            location: try string(anchorSpec, "location"),
            exportability: anchorSpec["exportability"]?.stringValue)
        let target = try await fileMemory(
            dispatcher,
            content: try string(targetSpec, "content"),
            location: try string(targetSpec, "location"),
            exportability: targetSpec["exportability"]?.stringValue)
        let canonicalAnchor = anchor.lowercased()
        let canonicalTarget = target.lowercased()
        func expectedIDs(_ key: String) throws -> Set<String> {
            guard let values = expected[key]?.arrayValue else { throw CocoaError(.fileReadCorruptFile) }
            let keys = values.compactMap(\.stringValue)
            guard keys.count == values.count else { throw CocoaError(.fileReadCorruptFile) }
            return Set(try keys.map {
                switch $0 {
                case "anchor": return canonicalAnchor
                case "target": return canonicalTarget
                default: throw CocoaError(.fileReadCorruptFile)
                }
            })
        }

        let estate = try await kit.estate(for: handle)
        let tunnel = TunnelCaptureFrame(
            sourceWing: tunnelWing, sourceRoom: tunnelWing,
            targetWing: tunnelWing, targetRoom: tunnelWing,
            label: "shared v2 connected-recall parity tunnel", addedBy: "aria-mcp-tests",
            sourceDrawerId: target, targetDrawerId: anchor, kind: .references)
        _ = try await estate.capture(tunnel)

        func recall(_ filter: String) async throws -> JSONValue {
            try await dispatcher.dispatch(
                name: "moot_recall_connected",
                arguments: .object([
                    "query": .string(query),
                    "wing": .string(tunnelWing),
                    "filter": .string(filter),
                    "limit": .integer(limit),
                ]))
        }

        let control = try await recall(try string(vector, "control_filter"))
        let controlRows = try rows(control)
        let controlIDs = controlRows.compactMap { $0["id"]?.stringValue?.lowercased() }
        #expect(Set(controlIDs) == (try expectedIDs("control_result_keys")),
                "wing must not scope anchor recall and control must prove tunnel reachability; got IDs: \(controlIDs)")

        let filtered = try await recall(try string(vector, "filtered_filter"))
        let filteredRows = try rows(filtered)
        let filteredIDs = filteredRows.compactMap { $0["id"]?.stringValue?.lowercased() }
        #expect(Set(filteredIDs) == (try expectedIDs("filtered_result_keys")),
                "caller-filtered full hydration must omit the graph endpoint from selected-v2 results; got IDs: \(filteredIDs)")
    }
}
