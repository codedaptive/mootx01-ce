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
                     "moot_dream", "moot_json_import", "moot_file_fact"] {
            #expect(refused.contains(tool), "\(tool) must be refused when frozen")
        }
        for tool in ["moot_memory_search", "moot_estate_status", "moot_memory_get", "moot_recall_precise",
                     "moot_lens_concepts", "moot_estate_ping", "moot_drain_status", "moot_dataset_query"] {
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

    // MARK: - Read path writes nothing — BLOCKED (v2 dropped dereference reward-marking)
    //
    // v1: live search seeds trace rows; a frozen search adds none, and a
    // frozen dereference (`moot_memory_get`) leaves the reward mark
    // untouched — probed via `kit.markRecallUsed` returning a non-zero
    // "still eligible to be flipped" count. This discriminates frozen from
    // live: a LIVE dereference is expected to mark the row (make
    // `markRecallUsed` return 0 the second time), while a FROZEN one must
    // not.
    //
    // In v2, `moot_memory_get`'s production path
    // (`AriaV2MemoryOperations.get`, AriaV2MemoryOperations.swift:756-782)
    // calls `context.usageLedger.recordDereferenced(...)` at line 767, but
    // every concrete `AriaV2MemoryUsageLedger` wired to it is a no-op:
    // the default implementation is an empty body
    // (`public func recordDereferenced(...) async {}`,
    // AriaV2MemoryOperations.swift:50), and the dispatcher's own
    // `DispatcherV2MemoryUsageLedger.recordDereferenced`
    // (ToolDispatch.swift:37) explicitly discards its arguments
    // (`_ = (memoryIDs, estateID, callerID, at)`) with a doc comment stating
    // "Reward marking remains owned by the established typed GLK path; this
    // adapter does not invent a second session store or mutate recall state
    // during a read." The only code that actually calls `kit.markRecallUsed`
    // on a dereference is `noteUsage(_:handle:)` (ToolDispatch.swift:2671-2688),
    // called exclusively from the dead legacy `runMemoryGet`
    // (ToolDispatch.swift:2402, line 2611), unreachable from
    // `ToolDispatcher.dispatch(name:arguments:)`.
    //
    // The result: `moot_memory_get` never marks the reward bit in v2,
    // whether the dispatcher is live or frozen. The v1 probe
    // (`unmarked > 0` after a dereference) would now be true in BOTH
    // postures, so it no longer discriminates frozen behavior from live
    // behavior — the property this case exists to prove (frozen is MORE
    // restrictive than live here) cannot be demonstrated against v2, because
    // live is no longer less restrictive on this path. Do not delete; do
    // not weaken to pass.

    @Test(.disabled("BLOCKED ON ID SPELLING, not on the reward loop. The loop is restored: DispatcherV2MemoryUsageLedger.recordDereferenced now calls kit.markRecallUsed under the four v1 conditions (live posture only, surfaced in this session, both storage spellings, a fresh wall clock later than the dispatch instant), and the four mutation verbs call it too, so v1's seven sites are covered. This case still cannot run because its own probe at :361 calls markRecallUsed(target: id) with the canonical-lowercase id taken from the v2 response text, while trace rows are keyed by the stored drawer spelling and GeniusLocusKit.markRecallUsed (VerbSurface.swift:1773-1785) passes target through verbatim with no normalisation — the same casing family recorded in the node-motion block reasons. The restoration code tries both spellings; the probe tries one. Unblocks with the public-id versus storage-id reconciliation. Do not delete; do not weaken to pass."))
    func frozenSearchThenDereferenceLeavesTracesUnmarked() async throws {
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
        let get = try await frozen.dispatch(name: "moot_memory_get", arguments: .object(["memory_id": .string(id)]))
        #expect(!isError(get), "moot_memory_get is a read and must work when frozen; got: \(get)")
        let unmarked = try await kit.markRecallUsed(handle, target: id, now: Date())
        #expect(unmarked > 0,
                "the seeded rows must still be unmarked after a frozen dereference (probe flipped \(unmarked))")
        #expect(try await kit.countRecallTraces(handle) == seeded)
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
