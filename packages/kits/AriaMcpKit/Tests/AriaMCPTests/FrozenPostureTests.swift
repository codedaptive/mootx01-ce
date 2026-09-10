// FrozenPostureTests.swift — the frozen serve posture at the dispatcher.
//
// Mirrors packages/kits/AriaMcpKit/rust/tests/frozen_posture_tests.rs.
//
// Coverage:
//   1. EstatePosture resolution: flag wins, MOOTX01_FROZEN=1 enables, else live.
//   2. ToolMutationInventory names only reachable tools, covers the writers,
//      and classifies every reachable tool (under every opt-in flag
//      combination) into exactly one of the read set, the refused set, or
//      the command-classified set.
//   3. A frozen dispatcher refuses moot_file_memory / moot_update_memory with
//      the exact isError text and no side effect, allows moot_memory_search and
//      moot_estate_status, and reports `frozen: true`.
//   4. A frozen search then dereference writes no recall-trace rows and leaves
//      the reward mark untouched (probed through kit.markRecallUsed).
//   5. `memory` is view-only when frozen: every other command is refused
//      before the adapter runs and before session state records the call,
//      with the estate byte-identical on disk; the same delete lands live.
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

    /// Every tool name a serve launched with `environment` can dispatch: the
    /// advertised projection.
    private func reachable(_ environment: [String: String]) -> Set<String> {
        Set(ToolProjection.tools(environment: environment).map(\.name))
    }

    /// Every flag combination a serve can be launched with.
    private static let flagCombinations: [[String: String]] = {
        var combinations: [[String: String]] = []
        for vault in ["1", "0"] {
            for memory in ["0", "1"] {
                combinations.append(["MOOTX01_VAULT": vault, "MOOTX01_MEMORY_TOOL": memory])
            }
        }
        return combinations
    }()

    /// Every opt-in on: the widest surface a serve can dispatch.
    private static let widest = ["MOOTX01_VAULT": "1", "MOOTX01_MEMORY_TOOL": "1"]

    /// Every name in the inventory must be a tool a serve can really
    /// dispatch; a renamed or retired tool must fail here, not silently stop
    /// being refused (or stop being allowed).
    @Test func inventoryNamesOnlyReachableTools() {
        let real = reachable(Self.widest)
        let classified = ToolMutationInventory.frozenReadTools
            .union(ToolMutationInventory.frozenRefusedTools)
            .union(ToolMutationInventory.commandClassifiedTools)
        let stale = classified.subtracting(real)
        #expect(stale.isEmpty, "inventory names tool(s) no serve can dispatch: \(stale.sorted())")
    }

    /// The structural guarantee: a tool a frozen serve can dispatch is in
    /// exactly one of the read set, the refused set, or the command-classified
    /// set, under every opt-in flag combination. A new tool in none of them
    /// fails here with its name.
    @Test func everyReachableToolIsInExactlyOneFrozenSet() {
        for environment in Self.flagCombinations {
            for name in reachable(environment).sorted() {
                let buckets = [
                    ToolMutationInventory.frozenReadTools.contains(name),
                    ToolMutationInventory.frozenRefusedTools.contains(name),
                    ToolMutationInventory.commandClassifiedTools.contains(name),
                ].filter { $0 }.count
                #expect(buckets == 1,
                        "\(name) is in \(buckets) frozen sets under \(environment); every reachable tool must be in exactly one of frozenReadTools / frozenRefusedTools / commandClassifiedTools")
            }
        }
    }

    @Test func writersAreRefusedAndReadersAreNot() {
        let refused = ToolMutationInventory.frozenRefusedTools
        for tool in ["moot_file_memory", "moot_update_memory", "moot_erase_memory",
                     "moot_dream", "moot_json_import", "moot_file_packet"] {
            #expect(refused.contains(tool), "\(tool) must be refused when frozen")
        }
        for tool in ["moot_memory_search", "moot_estate_status", "moot_memory_get", "moot_recall_precise",
                     "moot_lens_concepts", "moot_estate_ping", "moot_drain_status", "moot_packet_get"] {
            #expect(!refused.contains(tool), "\(tool) is a read and must stay callable when frozen")
            #expect(ToolMutationInventory.frozenReadTools.contains(tool),
                    "\(tool) is a read and must be in the explicit read set")
        }
        // The three sets are disjoint: a tool has exactly one tier.
        #expect(ToolMutationInventory.additiveWriteTools.isDisjoint(with: ToolMutationInventory.mutationTools))
        #expect(ToolMutationInventory.mutationTools.isDisjoint(with: ToolMutationInventory.destructiveTools))
        #expect(ToolMutationInventory.additiveWriteTools.isDisjoint(with: ToolMutationInventory.destructiveTools))
    }

    @Test func memoryIsCommandClassifiedWithViewAsItsOnlyRead() {
        #expect(ToolMutationInventory.frozenReadCommands["memory"] == ["view"])
        #expect(ToolMutationInventory.commandClassifiedTools == ["memory"])
        #expect(!ToolMutationInventory.frozenRefusedTools.contains("memory"),
                "memory is classified by command, never by name")
        #expect(!ToolMutationInventory.frozenReadTools.contains("memory"))
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

    /// The on-disk estate: the main database file plus its WAL sibling (the
    /// kit runs SQLite in WAL mode, so a write that has not been checkpointed
    /// lives in `-wal`). Two snapshots that compare equal prove no byte of
    /// committed or pending state changed between them.
    private func estateBytes(_ url: URL) throws -> [Data] {
        let wal = URL(fileURLWithPath: url.path + "-wal")
        let walBytes = FileManager.default.fileExists(atPath: wal.path) ? try Data(contentsOf: wal) : Data()
        return [try Data(contentsOf: url), walBytes]
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


    // MARK: - Command-classified tool: memory is view-only when frozen

    /// `memory` is classified per call: `view` proceeds and reads; every
    /// other command, and a missing or unknown one, is refused before the
    /// adapter runs and before session state records the call, with the
    /// estate byte-identical on disk. The adapter itself is posture-blind:
    /// the same `delete` lands through a live dispatcher.
    @Test func frozenMemoryToolIsViewOnly() async throws {
        let url = try tempDBURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (kit, handle) = try await openSQLiteEstate(url: url)
        let memoryOn = ["MOOTX01_MEMORY_TOOL": "1"]
        let live = ToolDispatcher(kit: kit, handle: handle, environment: memoryOn)
        let frozen = ToolDispatcher(kit: kit, handle: handle, environment: memoryOn, posture: .frozen)
        let path = "/memories/frozen-notes.txt"

        // One file created live, so view has something to read and delete a target.
        let created = try await live.dispatch(name: "memory", arguments: .object([
            "command": .string("create"), "path": .string(path),
            "file_text": .string("frozen posture view-only test"),
        ]))
        #expect(firstText(created).contains("File created successfully"), "precondition; got: \(firstText(created))")

        let before = try estateBytes(url)
        let callsBefore = await frozen.modeSessionState.totalCallCount
        let mutating: [(command: String?, arguments: [String: JSONValue])] = [
            ("create", ["path": .string("/memories/other.txt"), "file_text": .string("must not land")]),
            ("str_replace", ["path": .string(path), "old_str": .string("view-only"), "new_str": .string("must not land")]),
            ("insert", ["path": .string(path), "insert_line": .integer(0), "insert_text": .string("must not land")]),
            ("delete", ["path": .string(path)]),
            ("rename", ["old_path": .string(path), "new_path": .string("/memories/renamed.txt")]),
            ("frobnicate", ["path": .string(path)]),
            (nil, ["path": .string(path)]),
        ]
        for (command, arguments) in mutating {
            var args = arguments
            if let command { args["command"] = .string(command) }
            let result = try await frozen.dispatch(name: "memory", arguments: .object(args))
            #expect(isError(result), "memory \(command ?? "(missing)") must be refused when frozen; got: \(firstText(result))")
            #expect(firstText(result) == EstatePosture.refusalMessage(tool: "memory", command: command))
        }
        #expect(try estateBytes(url) == before, "refused memory commands must leave the estate byte-identical on disk")
        let callsAfterRefusals = await frozen.modeSessionState.totalCallCount
        #expect(callsAfterRefusals == callsBefore, "a refused memory command must not be recorded in session state")

        // view proceeds and reads the live-created file; the dispatcher records it.
        let view = try await frozen.dispatch(name: "memory",
                                             arguments: .object(["command": .string("view"), "path": .string(path)]))
        #expect(!isError(view) && firstText(view).contains("frozen posture view-only test"),
                "memory view is a read and must work when frozen; got: \(firstText(view))")
        let callsAfterView = await frozen.modeSessionState.totalCallCount
        #expect(callsAfterView == callsBefore + 1, "a view the dispatcher lets through is recorded")

        // The adapter is posture-blind: the same delete lands live.
        let deleted = try await live.dispatch(name: "memory",
                                              arguments: .object(["command": .string("delete"), "path": .string(path)]))
        #expect(firstText(deleted).hasPrefix("Successfully deleted"), "live delete must still work; got: \(firstText(deleted))")
        let gone = try await frozen.dispatch(name: "memory",
                                             arguments: .object(["command": .string("view"), "path": .string(path)]))
        #expect(firstText(gone).contains("does not exist"), "the deleted file must be gone; got: \(firstText(gone))")
    }

    // MARK: - moot_synthesize is a read under frozen

    /// `moot_synthesize` reads candidates and generates text; it writes no
    /// drawer, packet, journal, meta, trace, or reward. A frozen dispatcher
    /// must let it through, and the estate must be byte-identical before and
    /// after the call. FRZ-3: moved from mutationTools to frozenReadTools.
    @Test func frozenSynthesizeProceedsAndEstateIsUnchanged() async throws {
        let url = try tempDBURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (kit, handle) = try await openSQLiteEstate(url: url)
        let live = ToolDispatcher(kit: kit, handle: handle, environment: [:])
        let frozen = ToolDispatcher(kit: kit, handle: handle, environment: [:], posture: .frozen)

        _ = try await fileMemory(live, content: "carbon compounds synthesis test", location: "synth-room")
        let before = try estateBytes(url)

        let result = try await frozen.dispatch(
            name: "moot_synthesize",
            arguments: .object(["query": .string("carbon compounds"), "limit": .integer(5)]))
        #expect(!isError(result),
                "moot_synthesize is a read and must work when frozen; got: \(firstText(result))")
        #expect(try estateBytes(url) == before,
                "moot_synthesize must leave the estate byte-identical on disk")
        // The frozen refused-set must no longer name moot_synthesize.
        #expect(!ToolMutationInventory.frozenRefusedTools.contains("moot_synthesize"),
                "moot_synthesize must not be in the refused set after FRZ-3")
        #expect(ToolMutationInventory.frozenReadTools.contains("moot_synthesize"),
                "moot_synthesize must be in the explicit read set after FRZ-3")
    }

}
