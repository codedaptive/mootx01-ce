import Foundation
import PersistenceKit
import SubstrateTypes

public enum MatrixRefreshPhase: String, Sendable, Codable {
    case idle, queued, running, deferred, failed
}

public struct MatrixRefreshStatus: Sendable, Equatable {
    public var phase: MatrixRefreshPhase = .idle
    public var generation: String?
    public var watermark: HLC = .zero
    public var reason: String?
    public var migrationPhase: String = "complete"
    public var reclaimedBytes: Int64 = 0
    public init() {}
}

public enum MatrixRefreshDisposition: String, Sendable { case queued, coalesced }

/// Explicit admission limits, not environment variables. A refused refresh
/// retains the last serving generation and surfaces a deferred reason.
public struct MatrixRefreshLimits: Sendable, Equatable {
    public var auditEvents: Int
    public var cells: Int
    public var sourceRows: Int
    public init(auditEvents: Int = 1_000_000, cells: Int = 1_000_000, sourceRows: Int = 1_000_000) {
        self.auditEvents = max(1, auditEvents); self.cells = max(1, cells); self.sourceRows = max(1, sourceRows)
    }
}

/// Separate from GLK's request actor. One task owns a refresh until completion;
/// merely wrapping the old actor-isolated rebuild in Task would not isolate it.
package actor MatrixRefreshWorker {
    let storage: any Storage
    let estateID: UUID
    let store: MatrixRecordStore
    private var task: Task<MatrixTier?, Error>?
    private var lastResult: Result<MatrixTier?, Error>?
    private var runningFrozen = false
    private var runningTraining = false
    private var statusValue = MatrixRefreshStatus()
    private var closed = false
    private var serial: UInt64 = 0

    package init(storage: any Storage, estateID: UUID) {
        self.storage = storage; self.estateID = estateID
        self.store = MatrixRecordStore(storage: storage)
    }

    func status() async throws -> MatrixRefreshStatus {
        var value = try await store.statusMetadata(estateID: estateID)
        value.phase = statusValue.phase; value.reason = statusValue.reason
        return value
    }

    package func request(now: Date, frozen: Bool, limits: MatrixRefreshLimits, trainingOnly: Bool = false,
                 publish: @escaping @Sendable (MatrixTier) async -> Void) throws -> MatrixRefreshDisposition {
        guard !closed else { throw CancellationError() }
        if task != nil {
            guard frozen == runningFrozen, trainingOnly || !runningTraining else { throw MatrixRecordError.publicationConflict }
            return .coalesced
        }
        runningFrozen = frozen
        runningTraining = trainingOnly
        lastResult = nil
        serial &+= 1
        let pass = serial
        let storage = self.storage, store = self.store, estateID = self.estateID
        statusValue.phase = .running; statusValue.reason = nil
        let work = Task.detached(priority: .utility) { () async throws -> MatrixTier? in
            if !frozen { try await store.prepare() }
            let recordsPresent = try await storage.currentSchemaVersion(for: MatrixRecordStore.schemaDeclaration.kitID) > 0
            let expected = recordsPresent ? try await store.activeGeneration(estateID: estateID) : nil
            var tier: MatrixTier?
            do { tier = recordsPresent ? try await store.load(estateID: estateID, cellLimit: limits.cells) : nil }
            catch MatrixRecordError.corrupt { tier = nil } // disposable counts; calibration is separate
            if let tier { await publish(tier) }
            let sourceCount = try await storage.auditLog.count()

            // Existing pure algorithms are unchanged. Admission bounds transient
            // replay state and refuses rather than exhausting the daemon's memory.
            var log = UnifiedAuditLog(), after: HLC?, auditCount = 0
            while true {
                try Task.checkCancellation()
                let page = try await storage.auditLog.iterate(after: after, rowID: nil, limit: 1024)
                if page.isEmpty { break }
                auditCount += page.count
                guard auditCount <= limits.auditEvents else { throw MatrixRecordError.workingSetLimit("audit replay exceeds configured event limit; refresh deferred") }
                log.add(contentsOf: page.flatMap { AuditBridge.bridge($0) })
                after = page.last?.hlc
                if page.count < 1024 { break }
                await Task.yield()
            }
            if trainingOnly, !TrainingThresholdGate().decide(transitionCount: TrainingThresholdGate.transitionCount(in: log)).isActive {
                return nil
            }
            var times: [UUID: Int64] = [:]
            var lastID: String?
            while true {
                try Task.checkCancellation()
                let predicate: StoragePredicate? = lastID.map { .gt(Column(table: "drawers", name: "id"), .text($0)) }
                let page = try await storage.rowStore.query(table: "drawers", where: predicate,
                    orderBy: [OrderClause(column: Column(table: "drawers", name: "id"))],
                    limit: 1024, offset: nil, columns: ["id", "eventTime", "filedAt"])
                if page.isEmpty { break }
                for row in page {
                    guard case let .text(id)? = row["id"], let uuid = UUID(uuidString: id) else { continue }
                    let date: Date?
                    if case let .timestamp(value)? = row["eventTime"] { date = value }
                    else if case let .timestamp(value)? = row["filedAt"] { date = value }
                    else { date = nil }
                    if let date { times[uuid] = Int64(date.timeIntervalSince1970 * 1000) }
                }
                guard times.count <= limits.sourceRows else { throw MatrixRecordError.workingSetLimit("matrix event-time budget exceeded") }
                guard case let .text(id)? = page.last?["id"] else { throw MatrixRecordError.corrupt("drawer metadata has no cursor") }
                lastID = id
                if page.count < 1024 { break }
            }
            guard auditCount == sourceCount, try await storage.auditLog.count() == sourceCount else {
                throw MatrixRecordError.sourceChanged
            }
            try Task.checkCancellation()
            if tier != nil { tier!.incrementalUpdate(from: log, eventTimes: times) }
            else { tier = MatrixTier.fullRebuild(from: log, eventTimes: times) }
            let nowMs = Int64(now.timeIntervalSince1970 * 1000)
            tier!.coOccurrenceDecayed = MatrixTier.decayedCoOccurrence(from: log, nowMs: nowMs)
            try Task.checkCancellation()
            tier!.temporalCausalityDecayed = MatrixTier.rebuildTemporal(from: log, eventTimes: times, decayNowMs: nowMs).temporalCausalityDecayed
            tier!.decayedAsOfMs = nowMs
            try Task.checkCancellation()
            if !frozen {
                // Remove abandoned staging from earlier attempts before adding
                // another generation. The serving generation is never pruned.
                try await store.prune(estateID: estateID, keeping: Set(expected.map { [$0] } ?? []))
                let generation = UUID().uuidString.lowercased()
                try await store.stage(estateID: estateID, tier: tier!, generation: generation, now: now, cellLimit: limits.cells)
                try Task.checkCancellation()
                try await store.publish(estateID: estateID, generation: generation, expected: expected, auditCount: sourceCount)
                // Serve the committed generation even if subsequent cleanup fails.
                await publish(tier!)
                try await store.prune(estateID: estateID, keeping: Set([generation] + (expected.map { [$0] } ?? [])))
            }
            try Task.checkCancellation()
            return tier!
        }
        task = work
        Task {
            let result = await work.result
            await finish(result, pass: pass, publish: publish)
        }
        return .queued
    }

    package func wait() async throws -> MatrixTier {
        guard let task else {
            if let lastResult, let tier = try lastResult.get() { return tier }
            throw MatrixRecordError.corrupt(statusValue.reason ?? "matrix refresh has no result")
        }
        let pass = serial
        let result = await task.result
        guard !closed, pass == serial else { throw CancellationError() }
        // An explicit waiter retires the completed slot before its next request.
        // Its GLK caller installs the returned tier; background completion uses
        // the original publication closure.
        await finish(result, pass: pass, publish: { _ in })
        guard let tier = try result.get() else { throw MatrixRecordError.corrupt("training gate dormant; no refresh performed") }
        return tier
    }

    private func finish(_ result: Result<MatrixTier?, Error>, pass: UInt64,
                        publish: @Sendable (MatrixTier) async -> Void) async {
        guard pass == serial, !closed, task != nil else { return }
        lastResult = result
        task = nil
        switch result {
        case .success(let tier):
            statusValue.phase = .idle
            if let tier { statusValue.watermark = tier.lastHLC; await publish(tier) }
            else { statusValue.reason = "training gate dormant; no refresh performed" }
        case .failure(let error):
            switch error {
            case MatrixRecordError.workingSetLimit, MatrixRecordError.sourceChanged, MatrixRecordError.publicationConflict:
                statusValue.phase = .deferred
            default: statusValue.phase = .failed
            }
            statusValue.reason = String(describing: error)
        }
    }

    package func close() async {
        closed = true; serial &+= 1
        let running = task; task = nil
        running?.cancel()
        _ = await running?.result
    }
}

public extension GeniusLocusKit {
    @discardableResult
    func requestMatrixRefresh(_ handle: EstateHandle, now: Date,
                              frozen: Bool = false, limits: MatrixRefreshLimits = .init()) async throws -> MatrixRefreshDisposition {
        let worker = try matrixWorker(for: handle)
        return try await worker.request(now: now, frozen: frozen || matrixFrozenHandles.contains(handle), limits: limits) { [weak self, weak worker] tier in
            guard let self, let worker else { return }
            await self.acceptMatrixRefresh(tier, worker: worker, handle: handle)
        }
    }

    func matrixRefreshStatus(_ handle: EstateHandle) async throws -> MatrixRefreshStatus {
        try await matrixWorker(for: handle).status()
    }
}

extension GeniusLocusKit {
    func matrixWorker(for handle: EstateHandle) throws -> MatrixRefreshWorker {
        guard registry[handle] != nil, mountStates[handle] != .draining, let storage = storages[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        if let worker = matrixRefreshWorkers[handle] { return worker }
        let worker = MatrixRefreshWorker(storage: storage, estateID: handle.estateUUID)
        matrixRefreshWorkers[handle] = worker
        return worker
    }

    func acceptMatrixRefresh(_ tier: MatrixTier, worker: MatrixRefreshWorker, handle: EstateHandle) {
        guard registry[handle] != nil, mountStates[handle] != .draining, matrixRefreshWorkers[handle] === worker else { return }
        matrixTiers[handle] = tier
    }

    func requestMatrixTraining(_ handle: EstateHandle, now: Date) async throws -> MatrixRefreshDisposition {
        let worker = try matrixWorker(for: handle)
        return try await worker.request(now: now, frozen: matrixFrozenHandles.contains(handle), limits: .init(), trainingOnly: true) { [weak self, weak worker] tier in
            guard let self, let worker else { return }
            await self.acceptMatrixRefresh(tier, worker: worker, handle: handle)
        }
    }
}
