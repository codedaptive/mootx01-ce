// JsonImportDeterminism — the Part 6 verification harness (Swift half).
//
// Driven by `Tests/determinism/json_import_determinism.sh`, which runs this
// suite (`swift test --filter JsonImportDeterminism`), the Rust twin
// (`cargo test json_import_determinism`), and then byte-compares the two
// ports' canonical inventory files. The suite itself proves:
//   (a) a malformed seed performs ZERO writes and errors (nonzero script
//       exit comes from the failing test if this ever regresses),
//   (b) a lineage collision is a hard error,
//   (c) the same seed imported twice into fresh estates produces
//       byte-identical drawer/fact/tunnel inventories.
// Cross-port identity (d) is the script's diff over the files this suite
// and the Rust twin write to $JI_INVENTORY_OUT.
//
// The canonical inventory format is pinned across ports: sorted lines,
//   drawer|<lineage>|<wing>|<room>|<kind>|<sensitivity>|<exportability>|<event_ms>|<content-sha256>
//   fact|<subject>|<predicate>|<object>|<anchor-lineage>
//   tunnel|<kind>|<srcWing>/<srcRoom>|<tgtWing>/<tgtRoom>|<label>|<src-lineage>|<tgt-lineage>
// Volatile row UUIDs are excluded (they are minted per run); lineage ids,
// locations, bitmaps-as-raw-ints, event times, and content digests are the
// deterministic surface the lane guarantees.

import Testing
import Foundation
import CryptoKit
import LocusKit
import GeniusLocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import VaultKit

@Suite("JsonImportDeterminism")
struct JsonImportDeterminismTests {

    /// The canonical determinism seed — every record carries an EXPLICIT
    /// wing so the inventory never depends on the ports' default-wing
    /// naming. Shared verbatim with the Rust twin.
    static let determinismSeed = """
        {"format_version": 1, "name": "determinism-harness", "records": [
          {"id": "d1", "content": "determinism record one", "event_time": "2026-03-01T08:00:00Z", "wing": "HarnessA", "room": "alpha/one", "kind": "prose", "sensitivity": "normal", "exportability": "private"},
          {"id": "d2", "content": "determinism record two", "event_time": "2026-03-01T09:30:00.250Z", "wing": "HarnessA", "room": "alpha/two", "kind": "transcript", "sensitivity": "elevated", "exportability": "public"},
          {"id": "d3", "content": "determinism record three", "event_time": "2026-03-02T10:00:00Z", "wing": "HarnessB", "room": "beta/one", "kind": "code", "sensitivity": "restricted", "exportability": "private"},
          {"id": "d4", "content": "determinism record four", "event_time": "2026-03-03T11:15:00Z", "wing": "HarnessB", "room": "beta/one", "kind": "list", "sensitivity": "normal", "exportability": "private"}],
         "facts": [
          {"subject": "harness", "predicate": "counts", "object": "four", "record_id": "d1"},
          {"subject": "harness", "predicate": "spans", "object": "two wings", "record_id": "d3"}],
         "tunnels": [
          {"from": "d2", "to": "d1", "kind": "supersedes", "label": "chain"},
          {"from": "d4", "to": "d3", "kind": "references"}]}
        """

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "jsonimport-determinism")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    private func tempSeedFile(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsonimport-determinism-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    /// Canonical, sorted, port-neutral inventory of the estate's imported
    /// drawers, facts, and tunnels.
    private func canonicalInventory(kit: GeniusLocusKit, handle: EstateHandle) async throws -> String {
        let drawers = try await kit.recall(
            handle,
            RecallFrame(
                filterChain: [
                    .currentlyBelieve,
                    .any([.userConfirmed, .unconfirmed, .automatedConfirmedOnly]),
                    .any([.trustworthy, .requiresConfirmation]),
                    .sensitivityAtMost(.secret),
                ],
                hydrationLevel: .full,
                limit: 1_000_000))
        let estate = try await kit.estate(for: handle)
        let nodeNames = try await estate.resolveNodeNames(
            parentNodeIds: drawers.map(\.parentNodeId))
        var lineageByRowID: [String: UUID] = [:]
        var lines: [String] = []

        for drawer in drawers {
            lineageByRowID[drawer.id] = drawer.lineageID
            let names = nodeNames[drawer.parentNodeId]
            let contentHash = SHA256.hash(data: Data(drawer.content.utf8))
                .map { String(format: "%02x", $0) }.joined()
            let eventMs = Int64((drawer.eventTime.timeIntervalSince1970 * 1000).rounded())
            lines.append(
                "drawer|\(drawer.lineageID.uuidString.lowercased())|\(names?.wing ?? "")|\(names?.room ?? "")|\(drawer.contentKind.rawValue)|\(drawer.adjectiveSensitivity.rawValue)|\(drawer.exportability.rawValue)|\(eventMs)|\(contentHash)"
            )
        }

        for fact in try await kit.recallKGFacts(handle) {
            let anchor = lineageByRowID[fact.sourceDrawerID]?.uuidString.lowercased() ?? ""
            lines.append("fact|\(fact.subject)|\(fact.predicate)|\(fact.object)|\(anchor)")
        }

        // Tunnels: union over the wings the drawers landed in; synthetic
        // containment tunnels (node-topology echoes) are excluded.
        // `includingRestricted: true` — the sanctioned widening (same as
        // vault export's private scope): the default Normal-tier ceiling
        // would hide tunnels touching restricted drawers, and the harness
        // must inventory EVERYTHING the seed built.
        let wings = Set(drawers.compactMap { nodeNames[$0.parentNodeId]?.wing })
        for wing in wings.sorted() {
            for tunnel in try await kit.recallTunnels(handle, wing: wing, includingRestricted: true)
            where tunnel.addedBy != "nodeTopologyProvider" {
                let src = tunnel.sourceDrawerId.flatMap { lineageByRowID[$0] }?
                    .uuidString.lowercased() ?? ""
                let tgt = tunnel.targetDrawerId.flatMap { lineageByRowID[$0] }?
                    .uuidString.lowercased() ?? ""
                lines.append(
                    "tunnel|\(tunnel.kind.rawValue)|\(tunnel.sourceWing)/\(tunnel.sourceRoom)|\(tunnel.targetWing)/\(tunnel.targetRoom)|\(tunnel.label)|\(src)|\(tgt)"
                )
            }
        }

        return lines.sorted().joined(separator: "\n") + "\n"
    }

    // (a) Malformed seed → zero writes; the import errors.
    @Test("harness (a): malformed seed is an error with zero writes")
    func malformedSeedZeroWrites() async throws {
        let (kit, handle) = try await openEstate()
        let bridge = JsonImportBridge(kit: kit)
        let url = try tempSeedFile("{malformed")
        defer { try? FileManager.default.removeItem(at: url) }

        var errored = false
        do {
            _ = try await bridge.importSeed(at: url, into: handle, now: Date())
        } catch VaultKitError.adapterError {
            errored = true
        }
        #expect(errored, "a malformed seed MUST error — a stub that succeeds is a mission failure")

        let drawers = try await kit.recall(
            handle,
            RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured, limit: 10))
        #expect(drawers.isEmpty, "zero writes on a malformed seed")
    }

    // (b) Collision → hard error.
    @Test("harness (b): lineage collision is a hard error")
    func collisionHardError() async throws {
        let (kit, handle) = try await openEstate()
        let bridge = JsonImportBridge(kit: kit)
        _ = try await kit.capture(handle, CaptureFrame(
            content: "occupies d1",
            channel: .importedFile,
            room: "rm",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "harness",
            embeddingModelID: "no-embedding",
            lineageID: DrawerMapping.lineageID(forStableSourceKey: "d1")))
        let url = try tempSeedFile(Self.determinismSeed)
        defer { try? FileManager.default.removeItem(at: url) }

        var errored = false
        do {
            _ = try await bridge.importSeed(at: url, into: handle, now: Date())
        } catch let VaultKitError.adapterError(message) {
            errored = message.contains("\"d1\"") && message.contains("lineage collision")
        }
        #expect(errored, "a collision MUST be a hard error naming the colliding id")
    }

    // (c) Double-run determinism + the cross-port inventory artifact (d).
    @Test("harness (c/d): double-run inventories are byte-identical; inventory exported")
    func doubleRunInventoryIdentical() async throws {
        let url = try tempSeedFile(Self.determinismSeed)
        defer { try? FileManager.default.removeItem(at: url) }

        var inventories: [String] = []
        for _ in 0..<2 {
            let (kit, handle) = try await openEstate()
            let bridge = JsonImportBridge(kit: kit)
            let report = try await bridge.importSeed(at: url, into: handle, now: Date())
            #expect(report.drawersWritten == 4)
            #expect(report.factsWritten == 2)
            #expect(report.tunnelsCreated == 2)
            inventories.append(try await canonicalInventory(kit: kit, handle: handle))
        }
        #expect(inventories[0] == inventories[1],
                "same seed, fresh estates → byte-identical inventories")
        // The inventory is meaningfully populated — a stub writing an empty
        // file must fail here, not pass silently.
        #expect(inventories[0].split(separator: "\n").count == 8,
                "inventory must carry 4 drawers + 2 facts + 2 tunnels")

        // (d) Export for the script's cross-port byte comparison.
        if let outPath = ProcessInfo.processInfo.environment["JI_INVENTORY_OUT"] {
            try Data(inventories[0].utf8).write(to: URL(fileURLWithPath: outPath))
        }
    }
}
