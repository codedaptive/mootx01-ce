// FrozenPostureTests.swift — the frozen serve posture at the dispatcher.
//
// Mirrors packages/kits/AriaMcpKit/rust/tests/frozen_posture_tests.rs.
//
// Coverage:
//   1. EstatePosture resolution: flag wins, MOOTX01_FROZEN=1 enables, else live.
//   2. ToolMutationInventory names only real tools and covers the writers.
//   3. A frozen dispatcher refuses moot_file_memory / moot_update_memory with
//      the exact isError text and no side effect, allows moot_memory_search and
//      moot_estate_status, and reports `frozen: true`.
//   4. A frozen search then dereference writes no recall-trace rows and leaves
//      the reward mark untouched (probed through kit.markRecallUsed).
//
// SQLite-backed where trace rows are involved: the recall_trace table only
// exists on the SQLite backend.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
@testable import AriaMCP

@Suite("EstatePosture resolution")
struct EstatePostureResolutionTests {

    @Test func absentEnvironmentIsLive() {
        #expect(EstatePosture.resolve(frozenFlag: false, environment: [:]) == .live)
    }

    @Test func environmentOneFreezes() {
        #expect(EstatePosture.resolve(frozenFlag: false, environment: ["MOOTX01_FROZEN": "1"]) == .frozen)
    }

    @Test func environmentOtherValuesStayLive() {
        for value in ["0", "true", "yes", ""] {
            #expect(EstatePosture.resolve(frozenFlag: false, environment: ["MOOTX01_FROZEN": value]) == .live,
                    "MOOTX01_FROZEN=\(value) must not freeze; only \"1\" does")
        }
    }

    @Test func flagWinsOverEnvironment() {
        #expect(EstatePosture.resolve(frozenFlag: true, environment: ["MOOTX01_FROZEN": "0"]) == .frozen)
        #expect(EstatePosture.resolve(frozenFlag: true, environment: [:]) == .frozen)
    }

    @Test func logLineAndRefusalTextArePinned() {
        // Both strings are contract text shared byte-for-byte with the Rust port.
        #expect(EstatePosture.frozenLogLine
                == "FROZEN: no background workers, no recall traces, mutating tools refused")
        #expect(EstatePosture.refusalMessage(tool: "moot_file_memory")
                == "estate is frozen (serve --frozen): moot_file_memory is a mutating tool and was refused")
        #expect(EstatePosture.frozen.statusValue == "true")
        #expect(EstatePosture.live.statusValue == "false")
    }
}

@Suite("ToolMutationInventory")
struct ToolMutationInventoryTests {

    /// Every name in the inventory must be a tool the projection really
    /// serves; a renamed or retired tool must fail here, not silently stop
    /// being refused.
    @Test func inventoryNamesOnlyRealTools() {
        let real = Set(ToolProjection.tools().map(\.name))
        // `moot_redistill` is dispatchable in the Rust port and listed in the
        // installer tier tables of both ports, but neither port's tool list
        // advertises it today (the Swift recipe and tool never reached
        // develop; the Rust list was never extended). The inventory keeps
        // the name so a frozen Rust dispatcher refuses the callable tool and
        // the tier tables stay identical; this test tolerates exactly that
        // one absence, and nothing else.
        let knownUnadvertised: Set<String> = ["moot_redistill"]
        let stale = ToolMutationInventory.frozenRefusedTools.subtracting(real).subtracting(knownUnadvertised)
        #expect(stale.isEmpty, "inventory names tool(s) not in the projection: \(stale.sorted())")
    }

    @Test func writersAreRefusedAndReadersAreNot() {
        let refused = ToolMutationInventory.frozenRefusedTools
        for tool in ["moot_file_memory", "moot_update_memory", "moot_redistill", "moot_erase_memory",
                     "moot_dream", "moot_json_import"] {
            #expect(refused.contains(tool), "\(tool) must be refused when frozen")
        }
        for tool in ["moot_memory_search", "moot_estate_status", "moot_memory_get", "moot_recall_precise",
                     "moot_lens_concepts", "moot_estate_ping", "moot_drain_status"] {
            #expect(!refused.contains(tool), "\(tool) is a read and must stay callable when frozen")
        }
        // The three sets are disjoint: a tool has exactly one tier.
        #expect(ToolMutationInventory.additiveWriteTools.isDisjoint(with: ToolMutationInventory.mutationTools))
        #expect(ToolMutationInventory.mutationTools.isDisjoint(with: ToolMutationInventory.destructiveTools))
    }
}

/// `.serialized`: filesystem interaction; keep sequential to avoid temp-file
/// collisions.
@Suite("Frozen dispatcher", .serialized)
struct FrozenDispatcherTests {

    // MARK: - Helpers

    private func tempDBURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrozenPostureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("test.sqlite")
    }

    /// Open a SQLite-backed GLK estate and return (kit, handle). Dispatchers
    /// are built per test so live and frozen can share one estate.
    private func openSQLiteEstate(url: URL) async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "frozen-posture-tests")
        let configuration = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0)
        )
        let storage = try SQLiteStorage(configuration: configuration)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner,
                                        identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (kit, handle)
    }

    private func firstText(_ result: JSONValue) -> String {
        result.objectValue?["content"]?.arrayValue?.first?
            .objectValue?["text"]?.stringValue ?? ""
    }

    private func isError(_ result: JSONValue) -> Bool {
        result.objectValue?["isError"]?.boolValue ?? false
    }

    private func fileMemory(_ dispatcher: ToolDispatcher, content: String, location: String) async throws -> String {
        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string(content),
                "subject": .string(String(content.prefix(120))),
                "location": .string(location),
            ])
        )
        let idLine = firstText(result).split(separator: "\n").first.map(String.init) ?? ""
        let id = idLine.replacingOccurrences(of: "filed memory ", with: "")
        #expect(!id.isEmpty, "filed memory id must be non-empty; got: \(firstText(result))")
        return id
    }

    private func search(_ dispatcher: ToolDispatcher, query: String) async throws -> JSONValue {
        try await dispatcher.dispatch(name: "moot_memory_search",
                                      arguments: .object(["query": .string(query)]))
    }

    private func status(_ dispatcher: ToolDispatcher) async throws -> String {
        firstText(try await dispatcher.dispatch(name: "moot_estate_status", arguments: .object([:])))
    }

    // MARK: - Construction

    @Test func postureComesFromFlagThenEnvironment() async throws {
        let url = try tempDBURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (kit, handle) = try await openSQLiteEstate(url: url)

        #expect(ToolDispatcher(kit: kit, handle: handle, environment: [:]).posture == .live)
        #expect(ToolDispatcher(kit: kit, handle: handle,
                               environment: ["MOOTX01_FROZEN": "1"]).posture == .frozen)
        // Explicit posture (the --frozen flag) wins over the environment twin.
        let explicit = ToolDispatcher(kit: kit, handle: handle,
                                      environment: ["MOOTX01_FROZEN": "0"], posture: .frozen)
        #expect(explicit.posture == .frozen)
        // Derived dispatchers carry the posture unchanged.
        #expect(explicit.registering(handle).posture == .frozen)
        #expect(explicit.withMonitoringControl(nil).posture == .frozen)
    }

    // MARK: - Refusal and allow-list

    @Test func frozenRefusesWritersAndAllowsReads() async throws {
        let url = try tempDBURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (kit, handle) = try await openSQLiteEstate(url: url)
        let live = ToolDispatcher(kit: kit, handle: handle, environment: [:])
        let frozen = ToolDispatcher(kit: kit, handle: handle, environment: [:], posture: .frozen)

        // One memory filed live, so update has a real target and search has a hit.
        let id = try await fileMemory(live, content: "frozen posture refusal test", location: "frozen-room")
        let before = try await status(live)
        #expect(before.contains("memories: 1 active"), "precondition; got: \(before)")
        #expect(before.contains("frozen: false"), "a live dispatcher reports frozen: false; got: \(before)")

        // moot_file_memory refused, exact text, isError.
        let fileResult = try await frozen.dispatch(
            name: "moot_file_memory",
            arguments: .object(["content": .string("must not land"), "location": .string("frozen-room")]))
        #expect(isError(fileResult))
        #expect(firstText(fileResult)
                == "estate is frozen (serve --frozen): moot_file_memory is a mutating tool and was refused")

        // moot_update_memory refused the same way.
        let updateResult = try await frozen.dispatch(
            name: "moot_update_memory",
            arguments: .object(["id": .string(id), "mutation": .string("setSubject"),
                                "subject": .string("must not land")]))
        #expect(isError(updateResult))
        #expect(firstText(updateResult)
                == "estate is frozen (serve --frozen): moot_update_memory is a mutating tool and was refused")

        // No partial side effect: the estate is exactly as it was.
        let after = try await status(live)
        #expect(after.contains("memories: 1 active"), "refusal must not file anything; got: \(after)")

        // Reads keep working.
        let searchResult = try await search(frozen, query: "frozen posture refusal")
        #expect(!isError(searchResult))
        #expect(firstText(searchResult).contains(id), "frozen search must still surface the drawer")
        let frozenStatus = try await status(frozen)
        #expect(frozenStatus.contains("frozen: true"), "frozen status must report frozen: true; got: \(frozenStatus)")
        #expect(frozenStatus.contains("index_composition_policy: "),
                "frozen line sits beside index_composition_policy; got: \(frozenStatus)")

        // teachme touches nothing and is answered even for a refused tool.
        let guide = try await frozen.dispatch(
            name: "moot_file_memory", arguments: .object(["teachme": .bool(true)]))
        #expect(!isError(guide))
    }

    // MARK: - Read path writes nothing

    /// Live search seeds trace rows; a frozen search adds none, and a frozen
    /// dereference leaves the reward mark untouched. The probe is
    /// `kit.markRecallUsed`: it returns the number of rows it flips, so a
    /// non-zero count proves the frozen `moot_memory_get` did not mark them.
    @Test func frozenSearchThenDereferenceLeavesTracesUnmarked() async throws {
        let url = try tempDBURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (kit, handle) = try await openSQLiteEstate(url: url)
        let live = ToolDispatcher(kit: kit, handle: handle, environment: [:])
        let frozen = ToolDispatcher(kit: kit, handle: handle, environment: [:], posture: .frozen)

        let id = try await fileMemory(live, content: "frozen trace reward test", location: "trace-room")
        _ = try await search(live, query: "frozen trace reward")
        let seeded = try await kit.countRecallTraces(handle)
        #expect(seeded > 0, "live search must seed trace rows")

        // Frozen search: surfaces the drawer, writes no trace row.
        let frozenSearch = try await search(frozen, query: "frozen trace reward")
        #expect(firstText(frozenSearch).contains(id))
        #expect(try await kit.countRecallTraces(handle) == seeded,
                "a frozen search must not write recall-trace rows")

        // Frozen dereference: succeeds, marks nothing.
        let get = try await frozen.dispatch(name: "moot_memory_get", arguments: .object(["id": .string(id)]))
        #expect(!isError(get), "moot_memory_get is a read and must work when frozen; got: \(get)")
        let unmarked = try await kit.markRecallUsed(handle, target: id, now: Date())
        #expect(unmarked > 0,
                "the seeded rows must still be unmarked after a frozen dereference (probe flipped \(unmarked))")
        #expect(try await kit.countRecallTraces(handle) == seeded)
    }
}
