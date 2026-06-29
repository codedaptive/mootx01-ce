import Foundation
import Testing
@testable import LocusKit

/// Conformance runner for the LocusKit-surface vectors authored under
/// docs/validation/substrate_math_performance/test-harness/vectors/locuskit/.
///
/// The vectors carry an operation-sequence schema (see schema_note in
/// each JSON). Each case fires `inputs.ops` in order against a fresh
/// in-memory Estate and asserts `expected_output.observations` in
/// order. This Swift runner is the ground truth: a future Rust port
/// runs the same JSON through its own runner and must reproduce every
/// observation byte-for-byte (within the canonical encoding the
/// observations use — content strings, room ids, UDC codes, ordered
/// id lists, state-active booleans, recall counts).
///
/// The JSON locations are resolved by walking up from `#filePath`
/// until a directory containing
/// `docs/validation/substrate_math_performance/test-harness/vectors/locuskit/`
/// is found. This keeps the runner reusable from any worktree
/// without an environment variable.
@Suite("LocusKit vectors — parity runner over locuskit_* vectors")
struct LocusKitVectorsTests {

    /// Resolve the directory holding the LocusKit vector JSONs by
    /// walking upward from `#filePath` until a directory is found that
    /// contains `docs/validation/substrate_math_performance/test-harness/vectors/locuskit/`.
    /// This works regardless of whether the test runner is invoked
    /// from the repo root, the LocusKit package root, or another
    /// nested working directory.
    private static func vectorsDir() -> URL {
        let needle = ["docs", "validation", "substrate_math_performance",
                      "test-harness", "vectors", "locuskit"]
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<10 {
            var candidate = url
            for c in needle { candidate.appendPathComponent(c) }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        // Fall back to an obviously-bogus path so the error message is
        // useful when the vectors directory genuinely cannot be found.
        return URL(fileURLWithPath: "/vectors-directory-not-found")
    }

    @Test("drawer_lifecycle vector — capture, withdraw, peek, recall observations match")
    func drawerLifecycle() async throws {
        try await runVectorFile(named: "drawer_lifecycle.json")
    }

    @Test("tunnel_traverse vector — addTunnel + tunnelsFrom/tunnelsTo observations match")
    func tunnelTraverse() async throws {
        try await runVectorFile(named: "tunnel_traverse.json")
    }

    @Test("kgfact_temporal vector — addKGFact + kgFactsForDrawer observations match")
    func kgFactTemporal() async throws {
        try await runVectorFile(named: "kgfact_temporal.json")
    }

    @Test("recall_stream vector — capture + recallPaged observations match")
    func recallStream() async throws {
        try await runVectorFile(named: "recall_stream.json")
    }

    // MARK: - Vector runner

    private func runVectorFile(named name: String) async throws {
        let url = Self.vectorsDir().appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(VectorFile.self, from: data)

        #expect(file.format_version == "1")
        #expect(file.case_count == file.cases.count)

        for c in file.cases {
            let runner = VectorRunner()
            try await runner.run(case: c, primitive: file.primitive)
        }
    }

}

// MARK: - Vector schema (Decodable mirror of the JSON)
//
// File-scope so the VectorRunner actor can name `VectorCase` in its
// `run(case:primitive:)` signature without crossing private scope.

/// Mirrors the test-vector-format format_version 1 envelope, plus
/// per-primitive `inputs` and `expected_output` whose internal
/// shape is operation-list / observation-list.
struct VectorFile: Decodable {
    let format_version: String
    let primitive: String
    let case_count: Int
    let cases: [VectorCase]
}

struct VectorCase: Decodable {
    let id: String
    let description: String
    let inputs: VectorInputs
    let expected_output: VectorExpectedOutput
}

struct VectorInputs: Decodable {
    let ops: [Op]
}

struct VectorExpectedOutput: Decodable {
    let observations: [Observation]
}

// MARK: - Operation and observation enums (Decodable)
//
// Hand-rolled coding so the JSON stays human-readable and so a new
// op or observation kind is a single `case` addition rather than a
// refactor. The discriminator key is `op` for inputs and `kind` for
// outputs, matching the JSON.

enum Op: Decodable {
    case capture(content: String, room: String, udc: String, addedBy: String, embeddingModelID: String)
    case peek(drawerIndex: Int)
    case withdraw(drawerIndex: Int, reason: String?)
    case recallAll(room: String)
    case recallPaged(room: String, pageSize: Int)
    case addTunnel(id: String,
                   sourceWing: String, sourceRoom: String,
                   targetWing: String, targetRoom: String,
                   label: String, addedBy: String, filedAtEpoch: TimeInterval)
    case tunnelsFromRoom(sourceWing: String, sourceRoom: String)
    case tunnelsFromWing(sourceWing: String)
    case tunnelsToWing(targetWing: String)
    case addKGFact(id: String, subject: String, predicate: String, object: String,
                   sourceDrawerIndex: Int, filedAtEpoch: TimeInterval)
    case kgFactsForDrawer(sourceDrawerIndex: Int)

    private enum Keys: String, CodingKey {
        case op, content, room, udc, addedBy, embeddingModelID
        case drawerIndex, reason, pageSize
        case id, sourceWing, sourceRoom, targetWing, targetRoom, label, filedAtEpoch
        case subject, predicate, object, sourceDrawerIndex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "capture":
            self = .capture(
                content: try c.decode(String.self, forKey: .content),
                room: try c.decode(String.self, forKey: .room),
                udc: try c.decode(String.self, forKey: .udc),
                addedBy: try c.decode(String.self, forKey: .addedBy),
                embeddingModelID: try c.decode(String.self, forKey: .embeddingModelID))
        case "peek":
            self = .peek(drawerIndex: try c.decode(Int.self, forKey: .drawerIndex))
        case "withdraw":
            self = .withdraw(
                drawerIndex: try c.decode(Int.self, forKey: .drawerIndex),
                reason: try c.decodeIfPresent(String.self, forKey: .reason))
        case "recallAll":
            self = .recallAll(room: try c.decode(String.self, forKey: .room))
        case "recallPaged":
            self = .recallPaged(
                room: try c.decode(String.self, forKey: .room),
                pageSize: try c.decode(Int.self, forKey: .pageSize))
        case "addTunnel":
            self = .addTunnel(
                id: try c.decode(String.self, forKey: .id),
                sourceWing: try c.decode(String.self, forKey: .sourceWing),
                sourceRoom: try c.decode(String.self, forKey: .sourceRoom),
                targetWing: try c.decode(String.self, forKey: .targetWing),
                targetRoom: try c.decode(String.self, forKey: .targetRoom),
                label: try c.decode(String.self, forKey: .label),
                addedBy: try c.decode(String.self, forKey: .addedBy),
                filedAtEpoch: try c.decode(TimeInterval.self, forKey: .filedAtEpoch))
        case "tunnelsFromRoom":
            self = .tunnelsFromRoom(
                sourceWing: try c.decode(String.self, forKey: .sourceWing),
                sourceRoom: try c.decode(String.self, forKey: .sourceRoom))
        case "tunnelsFromWing":
            self = .tunnelsFromWing(sourceWing: try c.decode(String.self, forKey: .sourceWing))
        case "tunnelsToWing":
            self = .tunnelsToWing(targetWing: try c.decode(String.self, forKey: .targetWing))
        case "addKGFact":
            self = .addKGFact(
                id: try c.decode(String.self, forKey: .id),
                subject: try c.decode(String.self, forKey: .subject),
                predicate: try c.decode(String.self, forKey: .predicate),
                object: try c.decode(String.self, forKey: .object),
                sourceDrawerIndex: try c.decode(Int.self, forKey: .sourceDrawerIndex),
                filedAtEpoch: try c.decode(TimeInterval.self, forKey: .filedAtEpoch))
        case "kgFactsForDrawer":
            self = .kgFactsForDrawer(
                sourceDrawerIndex: try c.decode(Int.self, forKey: .sourceDrawerIndex))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .op, in: c,
                debugDescription: "unknown op: \(op)")
        }
    }
}

enum Observation: Decodable {
    case captured(captureIndex: Int, expectContent: String, expectRoom: String, expectUDC: String, expectStateActive: Bool)
    case peeked(peekIndex: Int, found: Bool, expectContent: String?, expectStateActive: Bool?)
    case withdrew(withdrawIndex: Int)
    case recalled(expectCount: Int, expectFirstContent: String?)
    case recallPaged(expectTotal: Int, expectContents: [String])
    case tunnelAdded(id: String)
    case traversed(expectIds: [String])
    case kgFactAdded(id: String)
    case kgFactList(expectIds: [String])

    private enum Keys: String, CodingKey {
        case kind
        case captureIndex, peekIndex, withdrawIndex
        case expectContent, expectRoom, expectUDC, expectStateActive
        case found
        case expectCount, expectFirstContent
        case expectTotal, expectContents
        case id, expectIds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "captured":
            self = .captured(
                captureIndex: try c.decode(Int.self, forKey: .captureIndex),
                expectContent: try c.decode(String.self, forKey: .expectContent),
                expectRoom: try c.decode(String.self, forKey: .expectRoom),
                expectUDC: try c.decode(String.self, forKey: .expectUDC),
                expectStateActive: try c.decode(Bool.self, forKey: .expectStateActive))
        case "peeked":
            self = .peeked(
                peekIndex: try c.decode(Int.self, forKey: .peekIndex),
                found: try c.decode(Bool.self, forKey: .found),
                expectContent: try c.decodeIfPresent(String.self, forKey: .expectContent),
                expectStateActive: try c.decodeIfPresent(Bool.self, forKey: .expectStateActive))
        case "withdrew":
            self = .withdrew(withdrawIndex: try c.decode(Int.self, forKey: .withdrawIndex))
        case "recalled":
            self = .recalled(
                expectCount: try c.decode(Int.self, forKey: .expectCount),
                expectFirstContent: try c.decodeIfPresent(String.self, forKey: .expectFirstContent))
        case "recallPaged":
            self = .recallPaged(
                expectTotal: try c.decode(Int.self, forKey: .expectTotal),
                expectContents: try c.decode([String].self, forKey: .expectContents))
        case "tunnelAdded":
            self = .tunnelAdded(id: try c.decode(String.self, forKey: .id))
        case "traversed":
            self = .traversed(expectIds: try c.decode([String].self, forKey: .expectIds))
        case "kgFactAdded":
            self = .kgFactAdded(id: try c.decode(String.self, forKey: .id))
        case "kgFactList":
            self = .kgFactList(expectIds: try c.decode([String].self, forKey: .expectIds))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "unknown observation kind: \(kind)")
        }
    }
}

// MARK: - Vector replay actor
//
// Each case runs in a fresh actor instance so state is bounded to the
// case. The actor owns a temporary SQLite-backed DrawerStore (the
// in-memory backend is sibling-pathed via TestStorage helpers used
// elsewhere in the suite; rather than reach into TestStorage from a
// separate file the runner reproduces the minimal store init here).

actor VectorRunner {
    private var estate: Estate?
    private var store: DrawerStore?
    private var capturedDrawers: [Drawer] = []
    private var tempURL: URL?

    deinit {
        // Best-effort cleanup. Tests run in parallel; the unique UUID
        // in the file name keeps collisions out of the picture.
        if let u = tempURL {
            try? FileManager.default.removeItem(at: u)
            try? FileManager.default.removeItem(at: u.appendingPathExtension("sqlite-wal"))
            try? FileManager.default.removeItem(at: u.appendingPathExtension("sqlite-shm"))
        }
    }

    /// Run one case: open a fresh Estate, fire each op in order,
    /// pop a matching observation from the head of the expected
    /// list and assert.
    func run(case c: VectorCase, primitive: String) async throws {
        try await openFreshEstate()
        var pendingObs = c.expected_output.observations
        for op in c.inputs.ops {
            try await execute(op: op, pendingObs: &pendingObs, caseID: c.id)
        }
        let leftover = pendingObs.count
        let summary = "case \(c.id): \(leftover) observations not consumed (primitive=\(primitive))"
        #expect(pendingObs.isEmpty, Comment(rawValue: summary))
    }

    private func openFreshEstate() async throws {
        let url = LocusKitVectorsTests_tempURL()
        self.tempURL = url
        let storage = try LocusKitVectorsTests_sqlite(url: url)
        let owner = OwnerCredentials(ownerIdentifier: "owner")
        self.estate = try await Estate.create(storage: storage, owner: owner)
        self.store = try await DrawerStore(storage: storage)
    }

    private func execute(op: Op,
                         pendingObs: inout [Observation],
                         caseID: String) async throws {
        guard let estate = estate, let store = store else {
            Issue.record("case \(caseID): estate/store nil")
            return
        }
        switch op {
        case .capture(let content, let room, let udc, let addedBy, let embed):
            let frame = CaptureFrame(
                content: content, channel: .typed, room: room,
                latticeAnchor: .udc(udc), addedBy: addedBy,
                embeddingModelID: embed)
            let drawer = try await estate.capture(frame)
            capturedDrawers.append(drawer)
            consumeCaptured(&pendingObs, drawer: drawer, caseID: caseID)
        case .peek(let idx):
            let rowID = capturedDrawers[idx].id
            let found = try await estate._peekDrawer(id: rowID)
            consumePeeked(&pendingObs, found: found, caseID: caseID)
        case .withdraw(let idx, let reason):
            let rowID = capturedDrawers[idx].id
            try await estate.withdraw(rowID: rowID, reason: reason)
            consumeWithdrew(&pendingObs, caseID: caseID)
        case .recallAll(let room):
            // `.unconfirmed` keeps the vector fixture focused on rows
            // produced by bare `capture`, whose provenance remains 0.
            // `.full` hydration is required because the vector observations
            // check `expectFirstContent` — per spec § 7.3, `.structured`
            // returns content = "" (no blob reads), so only `.full` loads
            // the blob for content-checking conformance ops.
            let frame = RecallFrame(
                filterChain: [.inRoom(room), .currentlyBelieve, .unconfirmed],
                hydrationLevel: .full)
            let stream = await estate.recall(frame)
            var rows: [Drawer] = []
            for await page in stream { rows.append(contentsOf: page.rows) }
            consumeRecalled(&pendingObs, rows: rows, caseID: caseID)
        case .recallPaged(let room, let pageSize):
            // `.full` hydration: same reason as recallAll above — vector
            // observations check `expectContents` so content must be loaded.
            let frame = RecallFrame(
                filterChain: [.inRoom(room), .currentlyBelieve, .unconfirmed],
                hydrationLevel: .full,
                limit: pageSize)
            let stream = await estate.recall(frame)
            var rows: [Drawer] = []
            for await page in stream { rows.append(contentsOf: page.rows) }
            consumeRecallPaged(&pendingObs, rows: rows, caseID: caseID)
        case .addTunnel(let id, let sw, let sr, let tw, let tr, let label, let addedBy, let epoch):
            let t = Tunnel(
                id: id,
                sourceWing: sw, sourceRoom: sr,
                targetWing: tw, targetRoom: tr,
                label: label,
                addedBy: addedBy, filedAt: Date(timeIntervalSince1970: epoch))
            try await store.addTunnel(t)
            consumeTunnelAdded(&pendingObs, id: id, caseID: caseID)
        case .tunnelsFromRoom(let sw, let sr):
            let result = try await store.tunnelsFrom(wing: sw, room: sr)
            consumeTraversed(&pendingObs, ids: result.map { $0.id }, caseID: caseID)
        case .tunnelsFromWing(let sw):
            let result = try await store.tunnelsFrom(wing: sw)
            consumeTraversed(&pendingObs, ids: result.map { $0.id }, caseID: caseID)
        case .tunnelsToWing(let tw):
            let result = try await store.tunnelsTo(wing: tw)
            consumeTraversed(&pendingObs, ids: result.map { $0.id }, caseID: caseID)
        case .addKGFact(let id, let subject, let predicate, let object, let drawerIdx, let epoch):
            let drawerID = capturedDrawers[drawerIdx].id
            let fact = KGFact(
                id: id,
                subject: subject, predicate: predicate, object: object,
                sourceDrawerID: drawerID,
                filedAt: Date(timeIntervalSince1970: epoch))
            try await store.addKGFact(fact)
            consumeKGFactAdded(&pendingObs, id: id, caseID: caseID)
        case .kgFactsForDrawer(let drawerIdx):
            let drawerID = capturedDrawers[drawerIdx].id
            let result = try await store.kgFacts(forDrawerID: drawerID)
            consumeKGFactList(&pendingObs, ids: result.map { $0.id }, caseID: caseID)
        }
    }

    // MARK: - Observation consumers

    private func consumeCaptured(_ obs: inout [Observation], drawer: Drawer, caseID: String) {
        guard !obs.isEmpty, case .captured(_, let ec, let er, let eu, let esa) = obs.removeFirst() else {
            Issue.record("case \(caseID): expected captured observation")
            return
        }
        #expect(drawer.content == ec, "case \(caseID): content")
        #expect(drawer.udcCode == eu, "case \(caseID): udc")
        #expect((drawer.state == .active) == esa, "case \(caseID): state.active")
    }

    private func consumePeeked(_ obs: inout [Observation], found: Drawer?, caseID: String) {
        guard !obs.isEmpty, case .peeked(_, let expectFound, let ec, let esa) = obs.removeFirst() else {
            Issue.record("case \(caseID): expected peeked observation")
            return
        }
        #expect((found != nil) == expectFound, "case \(caseID): peek found")
        if let f = found {
            if let ec = ec { #expect(f.content == ec, "case \(caseID): peek content") }
            if let esa = esa { #expect((f.state == .active) == esa, "case \(caseID): peek state.active") }
        }
    }

    private func consumeWithdrew(_ obs: inout [Observation], caseID: String) {
        guard !obs.isEmpty, case .withdrew = obs.removeFirst() else {
            Issue.record("case \(caseID): expected withdrew observation")
            return
        }
    }

    private func consumeRecalled(_ obs: inout [Observation], rows: [Drawer], caseID: String) {
        guard !obs.isEmpty, case .recalled(let ec, let efc) = obs.removeFirst() else {
            Issue.record("case \(caseID): expected recalled observation")
            return
        }
        #expect(rows.count == ec, "case \(caseID): recall count")
        if let efc = efc, let first = rows.first {
            #expect(first.content == efc, "case \(caseID): recall first content")
        }
    }

    private func consumeRecallPaged(_ obs: inout [Observation], rows: [Drawer], caseID: String) {
        guard !obs.isEmpty, case .recallPaged(let et, let contents) = obs.removeFirst() else {
            Issue.record("case \(caseID): expected recallPaged observation")
            return
        }
        #expect(rows.count == et, "case \(caseID): recallPaged total")
        #expect(rows.map { $0.content } == contents, "case \(caseID): recallPaged contents")
    }

    private func consumeTunnelAdded(_ obs: inout [Observation], id: String, caseID: String) {
        guard !obs.isEmpty, case .tunnelAdded(let eid) = obs.removeFirst() else {
            Issue.record("case \(caseID): expected tunnelAdded observation")
            return
        }
        #expect(id == eid, "case \(caseID): tunnel id")
    }

    private func consumeTraversed(_ obs: inout [Observation], ids: [String], caseID: String) {
        guard !obs.isEmpty, case .traversed(let eids) = obs.removeFirst() else {
            Issue.record("case \(caseID): expected traversed observation")
            return
        }
        #expect(ids == eids, "case \(caseID): traversal ids")
    }

    private func consumeKGFactAdded(_ obs: inout [Observation], id: String, caseID: String) {
        guard !obs.isEmpty, case .kgFactAdded(let eid) = obs.removeFirst() else {
            Issue.record("case \(caseID): expected kgFactAdded observation")
            return
        }
        #expect(id == eid, "case \(caseID): kg fact id")
    }

    private func consumeKGFactList(_ obs: inout [Observation], ids: [String], caseID: String) {
        guard !obs.isEmpty, case .kgFactList(let eids) = obs.removeFirst() else {
            Issue.record("case \(caseID): expected kgFactList observation")
            return
        }
        #expect(ids == eids, "case \(caseID): kg fact list ids")
    }
}

// MARK: - Local storage builders
//
// The TestStorage helpers in the suite are typed against
// SQLiteStorage; importing them here would not change behavior and
// would couple the runner to the rest of the test suite. The two
// small builders below are the same pattern, scoped to this file.

import PersistenceKit
import PersistenceKitSQLite

/// A fresh temp URL under NSTemporaryDirectory(). UUID in the name
/// keeps parallel test runs isolated.
func LocusKitVectorsTests_tempURL() -> URL {
    let name = "locuskit-vectors-\(UUID().uuidString).sqlite"
    return URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(name)
}

/// SQLiteStorage over the given URL. Reuses the
/// `EstateConfiguration` shape the rest of the suite uses.
func LocusKitVectorsTests_sqlite(url: URL) throws -> SQLiteStorage {
    let config = EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: url)
    )
    return try SQLiteStorage(configuration: config)
}
