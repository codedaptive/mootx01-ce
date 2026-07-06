import Foundation
import OSLog
import GeniusLocusKit
import QueueKit
import SubstrateTypes

// PalacePump.swift — the outbound data pump: MOOTx01's entire data model →
// MemPalace, over MemPalace's live MCP server.
//
// This is the live-transport sibling of `ExchangeAdapter` (which writes the
// JSON exchange document to disk). Where the benchmarker's TransferEngine
// moved CONTENT-ONLY with fixed args and no resume/pacing/drift-detection,
// the pump fixes every one of those gaps:
//
//   GAP A (per-item args)  → PalacePumpMapping builds wing/room/content/
//                            source_file per NoteIR.
//   GAP B (write id)       → PalaceResponseParsing.parseAddDrawerID reads the
//                            assigned drawer_id from the add_drawer response.
//   GAP C (verify by id)   → round-trip verification fetches get_drawer by the
//                            assigned id (MemPalace search has no stable id).
//   GAP D (resume)         → QueueKit IS the checkpoint: each note is a Job;
//                            a crash mid-run resumes from the queue's `new/`.
//   GAP E (pacing)         → a paced drain (delayPerItem) between writes.
//   GAP F (drift)          → PalaceDriftDetector diffs the live tools/list
//                            against the expected manifest BEFORE any write.
//
// ## Determinism
//
// The pump takes `now: @Sendable () -> Date` (the QueueKit HLC needs a clock).
// No engine inside reads the wall clock directly — the clock is injected at
// the call boundary, matching the MOOTx01 "pass now as a parameter" rule.
//
// ## Security posture (per this mission's mandate)
//
// Tier/sensitivity is pass-through "on": the pump reads the estate at the
// `.believedIncludingPrivate` scope by default so the WHOLE data model flows.
// The bulk-channel tier exclusions that `DrawerMapping.export` still counts
// for `secret` are surfaced in the result for transparency but do not gate the
// run beyond what the substrate itself withholds.

/// The outcome of one note's pump: the source key, the assigned noun id it
/// landed in, and whether it verified by round-trip fetch.
public struct PalacePumpItemResult: Sendable, Equatable {
    /// The note's `stableSourceKey` (its origin identity).
    public let sourceKey: String
    /// The assigned noun id from MemPalace (drawer id, tunnel id, triple id,
    /// or entry id, depending on the noun written). nil only when the write
    /// itself failed.
    public let drawerID: String?
    /// True when a `get_drawer` fetch of `drawerID` returned the content the
    /// pump wrote.
    public let verified: Bool

    public init(sourceKey: String, drawerID: String?, verified: Bool) {
        self.sourceKey = sourceKey
        self.drawerID = drawerID
        self.verified = verified
    }
}

/// The result of a full pump run.
public struct PalacePumpResult: Sendable, Equatable {
    /// One result per note that was drained and written.
    public var items: [PalacePumpItemResult]
    /// Secret-tier drawers the substrate withheld from the export projection.
    /// Reported, never silent (symmetry with VaultKit's C-13 reporting).
    public var withheldSecretTier: Int

    public init(items: [PalacePumpItemResult] = [], withheldSecretTier: Int = 0) {
        self.items = items
        self.withheldSecretTier = withheldSecretTier
    }

    /// Notes that wrote AND verified by round-trip fetch.
    public var verifiedCount: Int { items.filter { $0.verified }.count }
    /// Notes whose write failed (no assigned id).
    public var failedCount: Int { items.filter { $0.drawerID == nil }.count }
}

/// Errors the pump raises that halt the run.
public enum PalacePumpError: Error, Sendable {
    /// `tools/list` showed the live MemPalace surface no longer matches the
    /// pump's expected manifest. Carries the precise findings so the operator
    /// sees exactly what moved. The pump writes NOTHING when this is raised
    /// (drift check runs before the first write — GAP F).
    case driftDetected([PalaceDriftFinding])
}

/// The stream id the pump files its QueueKit jobs under. One logical stream
/// per pump; the queue root is per-run so resume is scoped to that run.
private let pumpStreamID = StreamID(rawValue: "mootx01-mp-pump")

/// Drives the outbound pump. Reads an estate's whole data model as `[NoteIR]`,
/// enqueues each as a QueueKit job (the checkpoint), then paced-drains the
/// queue, writing each note to MemPalace and verifying it by round-trip fetch.
public struct PalacePump: Sendable {

    private let client: MCPStdioClient
    private let queue: QueueKit
    /// Seconds to pause between item writes — the pacing knob (GAP E).
    private let delayPerItem: TimeInterval
    /// Injected clock (determinism rule); drives the QueueKit HLC.
    private let now: @Sendable () -> Date

    private static let log = Logger(subsystem: "com.mootx01.kit", category: "VaultKit")

    /// - Parameters:
    ///   - client: a connected ``MCPStdioClient`` bound to the MemPalace
    ///     server. The caller owns its lifecycle (connect before, disconnect
    ///     after).
    ///   - queue: the QueueKit instance whose root is the pump's checkpoint.
    ///     A filesystem-backed queue makes the run crash-resumable.
    ///   - delayPerItem: pacing pause between writes (default 0 — the caller
    ///     sets a positive value for a gentle background drain).
    ///   - now: the clock, injected at the boundary (determinism).
    public init(
        client: MCPStdioClient,
        queue: QueueKit,
        delayPerItem: TimeInterval = 0,
        now: @escaping @Sendable () -> Date
    ) {
        self.client = client
        self.queue = queue
        self.delayPerItem = delayPerItem
        self.now = now
    }

    // MARK: - Drift gate (GAP F)

    /// Run the drift gate: call `tools/list`, parse the live tools, diff
    /// against the expected manifest. Throws ``PalacePumpError/driftDetected``
    /// with a precise finding list if the surface moved. Call this before any
    /// write — the pump's ``run(estate:kit:scope:)`` does so automatically.
    public func checkDrift() async throws {
        let toolsJSON = try await client.listTools()
        let live = try PalaceLiveTool.parse(toolsListJSON: toolsJSON)
        let findings = PalaceDriftDetector.diff(live: live)
        if !findings.isEmpty {
            Self.log.error("MemPalace tool drift detected: \(findings.map(\.description).joined(separator: "; "), privacy: .public)")
            throw PalacePumpError.driftDetected(findings)
        }
    }

    // MARK: - Enqueue (GAP D — the queue is the checkpoint)

    /// Enqueue every note as a QueueKit job whose payload is the canonical
    /// JSON of its `add_drawer` arguments. Returns the number enqueued. A
    /// crash after this point resumes from the queue, not from zero.
    ///
    /// The job payload is the FINAL write args (envelope already folded in),
    /// so a resumed drain needs neither the estate nor the IR — the queue
    /// holds everything required to complete the write.
    public func enqueue(notes: [NoteIR]) async throws -> Int {
        var generator = HLCGenerator(nodeID: 1)
        let nowMillis = Int64(now().timeIntervalSince1970 * 1000)
        var count = 0
        for note in notes {
            let args = try PalacePumpMapping.makeArgs(for: note)
            let payload = try JSONEncoder().encode(PumpJobPayload(args: args))
            let job = Job(
                id: JobID.generate(),
                streamID: pumpStreamID,
                submittedAt: generator.send(now: nowMillis),
                payload: payload
            )
            try await queue.send(job)
            count += 1
        }
        return count
    }

    // MARK: - Drain (GAP A/B/C/E)

    /// Drain the queue, writing each job's drawer to MemPalace and verifying
    /// it by `get_drawer` of the assigned id. Paces by `delayPerItem` between
    /// items. Each drained job is completed in the queue, so a re-drain after
    /// a crash only re-processes jobs still in `new/`.
    ///
    /// - Returns: one ``PalacePumpItemResult`` per drained job.
    public func drain() async throws -> [PalacePumpItemResult] {
        var results: [PalacePumpItemResult] = []
        // drainAvailable claims all currently-waiting jobs; loop until empty so
        // a large estate (many pages) fully drains.
        while true {
            let claimed = try await queue.drain()
            if claimed.isEmpty { break }
            for (job, _) in claimed {
                let result = try await processJob(job)
                results.append(result)
                // Mark the job terminal so it is not re-processed on a resume.
                // A successful write is `.done`; a write that returned no
                // drawer_id is `.blocked` (terminal, but flagged as failed).
                try await queue.reply(
                    to: job.id,
                    status: result.drawerID == nil ? .blocked : .done,
                    artifacts: result.drawerID.map { [ArtifactRef.filePath($0)] } ?? []
                )
                if delayPerItem > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delayPerItem * 1_000_000_000))
                }
            }
        }
        return results
    }

    /// Write one job's drawer and verify it. Pure transport + parse; the args
    /// were fully built at enqueue time.
    private func processJob(_ job: Job) async throws -> PalacePumpItemResult {
        let decoded = try JSONDecoder().decode(PumpJobPayload.self, from: job.payload)
        let args = decoded.args
        // Write (GAP A — per-item args).
        let writeResult = try await client.callTool("mempalace_add_drawer", arguments: [
            "wing": args.wing,
            "room": args.room,
            "content": args.content,
            "source_file": args.sourceFile,
            "added_by": args.addedBy,
        ])
        let drawerID: String
        do {
            drawerID = try PalaceResponseParsing.parseAddDrawerID(textBlocks: writeResult.textBlocks)
        } catch {
            Self.log.error("add_drawer for '\(args.sourceFile, privacy: .public)' returned no drawer_id")
            return PalacePumpItemResult(sourceKey: args.sourceFile, drawerID: nil, verified: false)
        }
        // Verify by round-trip fetch (GAP C — by id, not search).
        let verified = await verify(drawerID: drawerID, expectedContent: args.content)
        return PalacePumpItemResult(sourceKey: args.sourceFile, drawerID: drawerID, verified: verified)
    }

    /// Fetch the drawer by id and confirm the content the pump wrote came
    /// back verbatim. Any error or mismatch is a failed verification (never a
    /// thrown error — a non-verifying drawer is recorded, not fatal).
    private func verify(drawerID: String, expectedContent: String) async -> Bool {
        do {
            let fetchResult = try await client.callTool("mempalace_get_drawer", arguments: [
                "drawer_id": drawerID,
            ])
            let fetched = try PalaceResponseParsing.parseGetDrawer(textBlocks: fetchResult.textBlocks)
            return fetched.drawerID == drawerID && fetched.content == expectedContent
        } catch {
            return false
        }
    }

    // MARK: - Four-noun pump (drawer / tunnel / KG fact / diary)
    //
    // The canonical path: the caller (the operator driver's EstateReader)
    // injects the full `[PalaceItem]` noun stream, and the pump writes each
    // through the per-noun PalacePumpMapping, verifies it by the noun's read
    // tool, and checkpoints it in QueueKit. This is the generalization of the
    // drawers-only NoteIR path above to the WHOLE data model. The drift gate
    // (now covering all four write tools + read tools) still runs first.

    /// Enqueue every ``PalaceItem`` as a QueueKit job whose payload is the
    /// fully-built MemPalace call (tool + native args, envelope already folded
    /// in) plus the noun and source id needed to verify the write. A crash
    /// after this point resumes from the queue. Returns the number enqueued.
    public func enqueueItems(_ items: [PalaceItem]) async throws -> Int {
        var generator = HLCGenerator(nodeID: 1)
        let nowMillis = Int64(now().timeIntervalSince1970 * 1000)
        var count = 0
        for item in items {
            let call = try PalacePumpMapping.call(for: item)
            let payload = try JSONEncoder().encode(
                PalaceItemJobPayload(noun: item.noun, sourceID: item.sourceID, body: item.body, call: call))
            let job = Job(
                id: JobID.generate(),
                streamID: pumpStreamID,
                submittedAt: generator.send(now: nowMillis),
                payload: payload)
            try await queue.send(job)
            count += 1
        }
        return count
    }

    /// Drain the four-noun queue, writing each job's call to MemPalace and
    /// verifying it by the noun's read tool. Paces by `delayPerItem`. Each
    /// drained job is completed in the queue, so a re-drain after a crash only
    /// re-processes jobs still in `new/`. Returns one result per drained job.
    public func drainItems() async throws -> [PalacePumpItemResult] {
        var results: [PalacePumpItemResult] = []
        while true {
            let claimed = try await queue.drain()
            if claimed.isEmpty { break }
            for (job, _) in claimed {
                let result = try await processItemJob(job)
                results.append(result)
                try await queue.reply(
                    to: job.id,
                    status: result.drawerID == nil ? .blocked : .done,
                    artifacts: result.drawerID.map { [ArtifactRef.filePath($0)] } ?? [])
                if delayPerItem > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delayPerItem * 1_000_000_000))
                }
            }
        }
        return results
    }

    /// Write one four-noun job's call and verify it by the noun's read tool.
    ///
    /// Security: the tool name is re-validated against the write-tool allowlist
    /// before every invocation. A persisted payload whose `call.tool` names any
    /// tool outside the four write tools is rejected with a logged error and
    /// counted as a failure — it is never forwarded to the MCP server. This
    /// prevents a tampered queue job from invoking arbitrary MemPalace tools
    /// (e.g. erase or admin tools) during drain.
    private func processItemJob(_ job: Job) async throws -> PalacePumpItemResult {
        let decoded = try JSONDecoder().decode(PalaceItemJobPayload.self, from: job.payload)
        let call = decoded.call

        // Allowlist check: only the four canonical write tools are permitted.
        // The tool name was embedded in the payload when the job was enqueued;
        // it could have been tampered with on disk between enqueue and drain.
        let allowedWriteTools: Set<String> = [
            PalacePumpMapping.addDrawerTool,
            PalacePumpMapping.createTunnelTool,
            PalacePumpMapping.kgAddTool,
            PalacePumpMapping.diaryWriteTool,
        ]
        guard allowedWriteTools.contains(call.tool) else {
            Self.log.error(
                "refusing persisted tool '\(call.tool, privacy: .public)' for '\(decoded.sourceID, privacy: .public)' — not in write allowlist")
            return PalacePumpItemResult(sourceKey: decoded.sourceID, drawerID: nil, verified: false)
        }

        let args = call.arguments.mapValues(\.foundationValue)
        let writeResult: MCPCallResult
        do {
            writeResult = try await client.callTool(call.tool, arguments: args)
        } catch {
            Self.log.error("\(call.tool, privacy: .public) for '\(decoded.sourceID, privacy: .public)' threw: \(String(describing: error), privacy: .public)")
            return PalacePumpItemResult(sourceKey: decoded.sourceID, drawerID: nil, verified: false)
        }
        let idKey = PalaceResponseParsing.assignedIDKey(for: decoded.noun)
        guard let assignedID = PalaceResponseParsing.parseAssignedID(textBlocks: writeResult.textBlocks, idKey: idKey) else {
            Self.log.error("\(call.tool, privacy: .public) for '\(decoded.sourceID, privacy: .public)' returned no \(idKey, privacy: .public)")
            return PalacePumpItemResult(sourceKey: decoded.sourceID, drawerID: nil, verified: false)
        }
        let verified = await verifyItem(noun: decoded.noun, assignedID: assignedID, body: decoded.body, call: call)
        return PalacePumpItemResult(sourceKey: decoded.sourceID, drawerID: assignedID, verified: verified)
    }

    /// Verify one written item landed, by reading it back with the noun's own
    /// MemPalace read tool. Any error or mismatch is a failed verification
    /// (never thrown — a non-verifying item is recorded, not fatal):
    ///   - drawer → get_drawer(drawer_id): id matches and the stored content's
    ///     body (envelope stripped) equals the source body.
    ///   - tunnel → list_tunnels(wing): our tunnel id is present.
    ///   - kgFact → kg_query(entity: subject): the clean subject+predicate+
    ///     object triple came back (MemPalace lowercases predicates and maps
    ///     spaces to underscores, so the predicate is normalized for compare).
    ///   - diary → diary_read(agent_name): an entry whose body (envelope
    ///     stripped) equals the source body is present.
    private func verifyItem(noun: PalaceNoun, assignedID: String, body: String, call: PalaceCall) async -> Bool {
        do {
            switch noun {
            case .drawer:
                let fetch = try await client.callTool(PalacePumpMapping.getDrawerTool, arguments: ["drawer_id": assignedID])
                let fetched = try PalaceResponseParsing.parseGetDrawer(textBlocks: fetch.textBlocks)
                guard fetched.drawerID == assignedID else { return false }
                return (try? PalacePayloadEnvelope.decodeFields(content: fetched.content).body) == body
            case .tunnel:
                var args: [String: Any] = [:]
                if let wing = call.arguments["source_wing"]?.stringValue { args["wing"] = wing }
                let result = try await client.callTool("mempalace_list_tunnels", arguments: args)
                return Self.anyArrayContains(textBlocks: result.textBlocks, key: "id", equals: assignedID)
            case .kgFact:
                guard let subject = call.arguments["subject"]?.stringValue,
                      let predicate = call.arguments["predicate"]?.stringValue,
                      let object = call.arguments["object"]?.stringValue else { return false }
                let normalized = predicate.lowercased().replacingOccurrences(of: " ", with: "_")
                let result = try await client.callTool("mempalace_kg_query", arguments: ["entity": subject])
                return Self.factsContain(textBlocks: result.textBlocks, predicate: normalized, object: object)
            case .diaryEntry:
                guard let agent = call.arguments["agent_name"]?.stringValue else { return false }
                let result = try await client.callTool("mempalace_diary_read", arguments: ["agent_name": agent])
                return Self.diaryContains(textBlocks: result.textBlocks, body: body)
            }
        } catch {
            return false
        }
    }

    /// Run the canonical four-noun pump: drift gate → enqueue the injected
    /// `[PalaceItem]` stream → paced drain with per-noun round-trip verify.
    /// The caller (operator driver) supplies the items (the read seam); the
    /// pump owns the wire format and verification.
    ///
    /// - Parameter items: the full noun stream from the driver's EstateReader.
    /// - Returns: the run result (per-item outcomes; `withheldSecretTier` 0 —
    ///   the driver decides the read scope and reports any withholding).
    /// - Throws: ``PalacePumpError/driftDetected`` (nothing written) or a
    ///   transport error.
    public func runItems(_ items: [PalaceItem]) async throws -> PalacePumpResult {
        try await checkDrift()
        _ = try await enqueueItems(items)
        let results = try await drainItems()
        Self.log.info("four-noun pump complete: \(results.count, privacy: .public) items, \(results.filter { $0.verified }.count, privacy: .public) verified, \(results.filter { $0.drawerID == nil }.count, privacy: .public) failed")
        return PalacePumpResult(items: results, withheldSecretTier: 0)
    }

    // MARK: - verify response readers (pure)

    /// True when any JSON object in a text block's first array-valued member
    /// (or a bare array block) carries `key == value`. Used for list-style
    /// verification (tunnels).
    static func anyArrayContains(textBlocks: [String], key: String, equals value: String) -> Bool {
        for block in textBlocks {
            guard let data = block.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let array = parsed as? [[String: Any]] {
                if array.contains(where: { ($0[key] as? String) == value }) { return true }
            } else if let object = parsed as? [String: Any] {
                for member in object.values {
                    if let array = member as? [[String: Any]],
                       array.contains(where: { ($0[key] as? String) == value }) {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// True when the `facts` array in a kg_query response carries a fact with
    /// the given (normalized) predicate and clean object.
    static func factsContain(textBlocks: [String], predicate: String, object: String) -> Bool {
        for block in textBlocks {
            guard let data = block.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let facts = parsed["facts"] as? [[String: Any]] else { continue }
            if facts.contains(where: { ($0["predicate"] as? String) == predicate && ($0["object"] as? String) == object }) {
                return true
            }
        }
        return false
    }

    /// True when the `entries` array in a diary_read response carries an entry
    /// whose content (envelope stripped) equals `body`.
    static func diaryContains(textBlocks: [String], body: String) -> Bool {
        for block in textBlocks {
            guard let data = block.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = parsed["entries"] as? [[String: Any]] else { continue }
            for entry in entries {
                guard let content = entry["content"] as? String else { continue }
                if (try? PalacePayloadEnvelope.decodeFields(content: content).body) == body { return true }
            }
        }
        return false
    }

    // MARK: - Full run (drawers-only NoteIR path)

    /// Run the whole pump for one estate: drift gate → project the estate to
    /// `[NoteIR]` → enqueue → paced drain with round-trip verification.
    ///
    /// - Parameters:
    ///   - handle: the estate to pump.
    ///   - kit: the open `GeniusLocusKit` whose estate is read.
    ///   - scope: which drawers to project. Defaults to
    ///     `.believedIncludingPrivate` so the WHOLE data model flows (the
    ///     mission's pass-through posture); `secret` is still withheld by the
    ///     substrate and reported.
    /// - Returns: the run result (per-item outcomes + withheld-secret count).
    /// - Throws: ``PalacePumpError/driftDetected`` if the surface moved
    ///   (nothing is written), or a transport error.
    public func run(
        estate handle: EstateHandle,
        kit: GeniusLocusKit,
        scope: VaultExportScope = .exportable
    ) async throws -> PalacePumpResult {
        // GAP F: refuse to write against a drifted surface.
        try await checkDrift()

        // Project the whole data model to NoteIR via the existing mapping.
        let mapping = DrawerMapping()
        let projection = try await mapping.export(kit: kit, handle: handle, scope: scope)

        _ = try await enqueue(notes: projection.notes)
        let items = try await drain()

        Self.log.info("pump complete: \(items.count, privacy: .public) items, \(items.filter { $0.verified }.count, privacy: .public) verified, \(items.filter { $0.drawerID == nil }.count, privacy: .public) failed")
        return PalacePumpResult(items: items, withheldSecretTier: projection.excludedSecretTier)
    }
}

/// The QueueKit job payload for a four-noun ``PalaceItem``: the fully-built
/// MemPalace call (tool + native args, envelope already folded into the
/// text-bearing arg) plus the noun and source id the drain needs to parse the
/// assigned id and verify the write. A resumed drain needs nothing but this.
/// `Codable` so it serializes into the job's opaque `payload` bytes.
struct PalaceItemJobPayload: Codable, Sendable, Equatable {
    /// The noun, so the drain picks the right assigned-id key and verify tool.
    let noun: PalaceNoun
    /// The source row id (checkpoint/result key).
    let sourceID: String
    /// The source body (envelope stripped), so verify can compare round-trip.
    let body: String
    /// The fully-built MemPalace call.
    let call: PalaceCall
}

/// The QueueKit job payload: the fully-built `add_drawer` arguments for one
/// note. The envelope is already folded into `content`, so a resumed drain
/// needs nothing but this to complete the write. `Codable` so it serializes
/// into the job's opaque `payload` bytes.
struct PumpJobPayload: Codable, Sendable, Equatable {
    let wing: String
    let room: String
    let content: String
    let sourceFile: String
    let addedBy: String

    init(args: PalaceDrawerArgs) {
        self.wing = args.wing
        self.room = args.room
        self.content = args.content
        self.sourceFile = args.sourceFile
        self.addedBy = args.addedBy
    }

    /// The args reconstructed from the decoded payload, for the write call.
    var args: PalaceDrawerArgs {
        PalaceDrawerArgs(wing: wing, room: room, content: content, sourceFile: sourceFile, addedBy: addedBy)
    }
}
