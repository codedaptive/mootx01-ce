import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import AriaMCP

/// Verifies that every v2 refusal site that refuses a closed-set enum value
/// emits BOTH data.allowed and data.correction in the JSONRPCError payload.
///
/// Covers Groups A and C from mission V2_REFUSAL_PARITY unit 2:
/// - Group A: four sites that had allowed but no correction before this fix.
/// - Group C: six sites that had neither field before this fix (two generic
///   enumValue helpers in AriaV2MemoryOperations and AriaV2MemoryMutations).
///
/// Every case routes through ToolDispatcher.dispatch(name:arguments:) — the
/// production tool surface — and expects a thrown JSONRPCError whose data
/// object carries non-empty allowed and non-empty correction.
@Suite("v2 enum refusal parity — data.allowed and data.correction", .serialized)
struct AriaV2RefusalParityTests {

    // MARK: - Harness

    private func makeDispatcher() async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "refusal-parity-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage,
            owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (ToolDispatcher(kit: kit, handle: handle, serverIdentity: "refusal-parity-test"), kit, handle)
    }

    // MARK: - Parameterised cases

    struct RefusalCase: Sendable, CustomStringConvertible {
        let tool: String
        let arguments: [String: JSONValue]
        let description: String
    }

    /// All closed-set enum refusals in this unit's scope. Every entry must
    /// reach a JSONRPCError whose data carries non-empty allowed and correction.
    static let refusalCases: [RefusalCase] = {
        let uuid1 = UUID().uuidString
        let uuid2 = UUID().uuidString
        return [
            // Group A — had allowed, missing correction before this fix.
            RefusalCase(
                tool: "moot_memory_list",
                arguments: ["wing": .string("test-wing"), "filter": .string("bogus_filter")],
                description: "moot_memory_list/filter"),
            RefusalCase(
                tool: "moot_update_memory",
                arguments: ["memory_id": .string(uuid1), "mutation": .string("bogus_mutation")],
                description: "moot_update_memory/mutation"),
            RefusalCase(
                tool: "moot_link_memories",
                arguments: [
                    "from_id": .string(uuid1), "to_id": .string(uuid2),
                    "relationship": .string("bogus_relationship"),
                ],
                description: "moot_link_memories/relationship"),
            RefusalCase(
                tool: "moot_review_tunnel",
                arguments: [
                    "tunnel_id": .string(uuid1),
                    "decision": .string("accept"),
                    "reviewed_by": .string("model"),
                ],
                description: "moot_review_tunnel/reviewed_by"),
            // Group C — had neither field before this fix (generic enumValue helpers).
            RefusalCase(
                tool: "moot_file_memory",
                arguments: [
                    "content": .string("c"), "subject": .string("s"), "location": .string("l/r"),
                    "sensitivity": .string("bogus_sensitivity"),
                ],
                description: "moot_file_memory/sensitivity"),
            RefusalCase(
                tool: "moot_file_memory",
                arguments: [
                    "content": .string("c"), "subject": .string("s"), "location": .string("l/r"),
                    "exportability": .string("bogus_exportability"),
                ],
                description: "moot_file_memory/exportability"),
            RefusalCase(
                tool: "moot_file_memory",
                arguments: [
                    "content": .string("c"), "subject": .string("s"), "location": .string("l/r"),
                    "kind": .string("bogus_kind"),
                ],
                description: "moot_file_memory/kind"),
            RefusalCase(
                tool: "moot_memory_get",
                arguments: ["memory_id": .string(uuid1), "depth": .string("bogus_depth")],
                description: "moot_memory_get/depth"),
            RefusalCase(
                tool: "moot_update_memory",
                arguments: [
                    "memory_id": .string(uuid1), "mutation": .string("confirm"),
                    "sensitivity": .string("bogus_sensitivity"),
                ],
                description: "moot_update_memory/sensitivity"),
            RefusalCase(
                tool: "moot_update_memory",
                arguments: [
                    "memory_id": .string(uuid1), "mutation": .string("confirm"),
                    "exportability": .string("bogus_exportability"),
                ],
                description: "moot_update_memory/exportability"),
        ]
    }()

    // MARK: - Parameterised test

    @Test("enum refusal carries both data.allowed and data.correction", arguments: refusalCases)
    func enumRefusalCarriesBothFields(_ entry: RefusalCase) async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }
        do {
            _ = try await dispatcher.dispatch(name: entry.tool, arguments: .object(entry.arguments))
            Issue.record("expected JSONRPCError for \(entry.description)")
        } catch let error as JSONRPCError {
            guard let data = error.data?.objectValue else {
                Issue.record("data field must be an object for \(entry.description); got: \(String(describing: error.data))")
                return
            }
            guard let allowed = data["allowed"]?.arrayValue, !allowed.isEmpty else {
                Issue.record("data.allowed must be present and non-empty for \(entry.description); data: \(data)")
                return
            }
            guard let correction = data["correction"]?.stringValue, !correction.isEmpty else {
                Issue.record("data.correction must be present and non-empty for \(entry.description); data: \(data)")
                return
            }
            // Reaching here means both fields are present and non-empty.
            _ = allowed
            _ = correction
        }
    }
}
