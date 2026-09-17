import FactExtractionKit
import Foundation
import LocusKit
import QueueKit
import SubstrateTypes

// The payload belongs to GLK. QueueKit only persists opaque bytes with CAS;
// LocusKit alone owns facts and the guarded source/recipe publication transaction.
struct FactExtractionProgress: Codable, Sendable {
    var version = 1
    var sourceID: String
    var sourceDigest: String
    var recipeID: String
    var contentKind: Int
    var outcome: FactExtractionOutcome = .pending
    var nextStart = 0
    var nextStartUTF8Byte = 0
    var maximumCharacters: Int
    var readyToPublish = false
    var candidates: [GroundedFactCandidate] = []
    var rejectedCandidates = 0
    var attempts = 0
    var malformedAttempts = 0
    var nextAttemptAt: Double = 0
    var leaseUntil: Double = 0
    var leaseToken = ""
    var reason = ""
}

private struct FactExtractionSweep: Codable { var afterSourceID: String? }

public struct FactExtractionWorkStatus: Sendable {
    public var runnable = 0
    public var inFlight = 0
    public var partial = 0
    public var retrying = 0
    public var blocked = 0
    public var rejected = 0
    public var notApplicable = 0
    public var completedEmpty = 0
    /// Earliest `nextAttemptAt` among sources scheduled for retry (not
    /// blocked-provider), so a settle loop can wait out the backoff instead
    /// of stopping on it. Nil when nothing is scheduled.
    public var nextRetryAt: Date? = nil
    // False when no extractor is registered for the estate; the detail
    // prepends the explanation so an operator reading moot_drain_status with
    // 54,000 pending rows sees "no extractor registered" ahead of the counts.
    public var extractorRegistered = true
    public var detail: String {
        let counts = "ready: \(runnable), running: \(inFlight), partial: \(partial), retrying: \(retrying), blocked: \(blocked), rejected: \(rejected), not applicable: \(notApplicable), empty: \(completedEmpty)"
        if !extractorRegistered {
            return "no extractor registered; \(counts)"
        }
        return counts
    }
}

extension GeniusLocusKit {
    static var factWorkStream: StreamID { StreamID(rawValue: "fact-extraction-checkpoints") }
    static func factWorkID(_ sourceID: String) -> JobID {
        JobID(rawValue: String(factSourceDigest("fact-work-v1|" + sourceID).prefix(32)))
    }
    static func factWorkflowRecipe(_ base: String, spec: FactExtractorModelSpec) -> String {
        let marker = "|fact-workflow-v2|"
        let root = base.components(separatedBy: marker)[0]
        return root + marker + factSourceDigest([
            spec.providerID, spec.modelID, spec.modelVersion, spec.schemaVersion,
            String(spec.maximumInputCharacters), String(spec.maximumFactsPerSource),
            "original-overlap-v2", "array-prompt-v2", "grounding-v1", "eligibility-v1",
        ].joined(separator: "|"))
    }

    func factCheckpoints(_ handle: EstateHandle) async throws -> QueueCheckpointStore {
        let (queue, _) = try await ensureDreamingQueue(for: handle)
        let checkpoints = try QueueCheckpointStore(queue: queue)
        if let configuration = storages[handle]?.configuration {
            switch configuration.backend {
            case .inMemory: break
            default:
                guard checkpoints.isPersistent else {
                    throw GeniusLocusKitError.underlyingEstateFailure(reason: "fact extraction requires a durable queue for a persistent estate")
                }
            }
        }
        return checkpoints
    }

    func prepareFactExtractionBatch(_ handle: EstateHandle, limit: Int, now: Date) async throws -> FactExtractionBatchWork? {
        guard limit > 0, let extractor = factExtractors[handle],
              let recipeID = factExtractorRecipeIDs[handle] else { return nil }
        let estate = try estate(for: handle)
        let checkpoints = try await factCheckpoints(handle)
        guard let lease = try checkpoints.acquireDrainLease(stream: DutyKind.factExtraction.streamID) else { return nil }
        if checkpoints.isPersistent, let queue = dreamingQueues[handle] {
            _ = try await queue.reclaimInFlight(stream: DutyKind.factExtraction.streamID)
        }
        let sweepID = Self.factWorkID("sweep")
        let sweepStream = StreamID(rawValue: "fact-extraction-sweep")
        let previous = try await checkpoints.read(id: sweepID, stream: sweepStream)
        let sweep = try previous.map { try JSONDecoder().decode(FactExtractionSweep.self, from: $0) }
        var pending = try await estate.factExtractionDebtBatch(limit: limit, afterDrawerID: sweep?.afterSourceID)
        let wrapped = pending.isEmpty && sweep?.afterSourceID != nil
        if wrapped { pending = try await estate.factExtractionDebtBatch(limit: limit) }
        // The cursor advances even when every selected record is deferred or
        // rejected. Falling off the tail wraps to the head on the next pass.
        let cursor = FactExtractionSweep(afterSourceID: pending.last?.id)
        _ = try await checkpoints.compareAndSwap(id: sweepID, stream: sweepStream,
            expected: previous, payload: try JSONEncoder().encode(cursor),
            stamp: HLC(physicalTime: Int64(now.timeIntervalSince1970 * 1000), logicalCount: 0, nodeID: 0))
        return FactExtractionBatchWork(drawers: pending, extractor: extractor, recipeID: recipeID,
            checkpoints: checkpoints, store: try await ensureKGStore(for: handle), now: now,
            traversedForward: !wrapped && !pending.isEmpty, lease: lease,
            sourceLeaseSeconds: dutyLimits(for: handle).factSourceLeaseSeconds)
    }

    public func factExtractionWorkStatus(_ handle: EstateHandle, now: Date) async throws -> FactExtractionWorkStatus {
        let estate = try estate(for: handle)
        var status = FactExtractionWorkStatus()
        status.runnable = try await estate.countFactExtractionDebt()
        guard let recipeID = factExtractorRecipeIDs[handle] else {
            status.blocked = status.runnable; status.runnable = 0
            status.extractorRegistered = false
            return status
        }
        guard let queue = dreamingQueues[handle] else { return status }
        let checkpoints = try QueueCheckpointStore(queue: queue)
        for payload in try await checkpoints.payloads(stream: Self.factWorkStream) {
            let state = try JSONDecoder().decode(FactExtractionProgress.self, from: payload)
            // Completed sources are already absent from raw bit-28 debt. Do not
            // hydrate their bodies merely to produce an operational count.
            if state.outcome == .completed { continue }
            guard state.recipeID == recipeID,
                  let source = try await estate.getDrawers(ids: [state.sourceID]).first,
                  source.tombstonedAt == nil,
                  source.adjectiveBitmap & 63 < Int64(RowState.activeClusterUpperBoundRaw),
                  Self.factSourceDigest(source.content) == state.sourceDigest,
                  source.contentKind.rawValue == state.contentKind else { continue }
            if state.outcome == .completedEmpty || (state.readyToPublish && state.candidates.isEmpty && source.areFactsExtracted) {
                status.completedEmpty += 1
            }
            // Bit 28 sits above the 12-bit feature-flag region, so
            // `hasFeatureFlag` cannot see it; the computed accessor can.
            guard !source.areFactsExtracted else { continue }
            if state.leaseUntil > now.timeIntervalSince1970 {
                status.inFlight += 1; status.runnable -= 1
            } else if state.outcome == .notApplicable {
                status.notApplicable += 1; status.runnable -= 1
            } else if state.outcome == .rejected {
                status.rejected += 1; status.runnable -= 1
            } else if state.nextAttemptAt > now.timeIntervalSince1970 {
                if state.outcome == .blockedProvider { status.blocked += 1 }
                else {
                    status.retrying += 1
                    let at = Date(timeIntervalSince1970: state.nextAttemptAt)
                    if status.nextRetryAt.map({ at < $0 }) ?? true { status.nextRetryAt = at }
                }
                status.runnable -= 1
            }
            if state.nextStart > 0 && !state.outcome.isTerminal { status.partial += 1 }
        }
        status.runnable = max(0, status.runnable)
        // Rejected sources carry bits 28 and 29 and are settled for this
        // recipe; they are reported, never owed (ruling 2026-09-16).
        status.rejected = try await estate.countFactExtractionRejected()
        return status
    }
}

/// A prepared batch owns immutable inputs and kit handles, not the GLK actor.
/// Rust's mirror is run after releasing the resident coordinator mutex.
public struct FactExtractionBatchWork: Sendable {
    let drawers: [Drawer]
    let extractor: any FactExtractor
    let recipeID: String
    let checkpoints: QueueCheckpointStore
    let store: DrawerStore
    let now: Date
    let traversedForward: Bool
    let lease: QueueCheckpointLease
    /// Per-source in-flight fence (DutyLimits.factSourceLeaseSeconds).
    let sourceLeaseSeconds: Int

    public func run() async throws -> FactExtractionBatchResult {
        defer { lease.release() }
        var completed = 0, filed = 0, rejected = 0, skipped = 0, failed = 0
        var chunks = 0, deferred = 0, inapplicable = 0, rejectedSources = 0
        var advanced = traversedForward
        let started = ProcessInfo.processInfo.systemUptime
        for drawer in drawers {
            try Task.checkCancellation()
            let instant = now.addingTimeInterval(ProcessInfo.processInfo.systemUptime - started)
            let epoch = instant.timeIntervalSince1970
            let id = GeniusLocusKit.factWorkID(drawer.id)
            let stream = GeniusLocusKit.factWorkStream
            let previous = try await checkpoints.read(id: id, stream: stream)
            let digest = GeniusLocusKit.factSourceDigest(drawer.content)
            var state = try previous.map { try JSONDecoder().decode(FactExtractionProgress.self, from: $0) }
                ?? FactExtractionProgress(sourceID: drawer.id, sourceDigest: digest,
                    recipeID: recipeID, contentKind: drawer.contentKind.rawValue,
                    maximumCharacters: extractor.spec.maximumInputCharacters)
            if state.version != 1 { throw FactExtractionError.invalidRequest("unsupported fact checkpoint version") }
            if state.sourceDigest != digest || state.recipeID != recipeID
                || state.contentKind != drawer.contentKind.rawValue
                || state.outcome == .completed || state.outcome == .completedEmpty {
                state = FactExtractionProgress(sourceID: drawer.id, sourceDigest: digest,
                    recipeID: recipeID, contentKind: drawer.contentKind.rawValue,
                    maximumCharacters: extractor.spec.maximumInputCharacters)
            }
            if state.outcome.isTerminal || state.nextAttemptAt > epoch || state.leaseUntil > epoch {
                // A checkpoint already rejected before bit 29 existed (or by a
                // process that died between the checkpoint and the mark) is
                // settled now, so it leaves the debt instead of being re-read
                // by every batch. Idempotent: 0 when the bit is already set.
                if state.outcome == .rejected && !drawer.areFactsExtracted {
                    if try await store.markFactExtractionRejected(
                        sourceID: drawer.id, expectedContent: drawer.content, recipeID: recipeID) == 1 {
                        advanced = true
                    }
                }
                deferred += 1; continue
            }
            state.leaseToken = UUID().uuidString.lowercased()
            state.leaseUntil = epoch + Double(sourceLeaseSeconds)
            let stamp = HLC(physicalTime: Int64(epoch * 1000), logicalCount: 0, nodeID: 0)
            let claim = try JSONEncoder().encode(state)
            guard try await checkpoints.compareAndSwap(id: id, stream: stream,
                expected: previous, payload: claim, stamp: stamp) else { skipped += 1; continue }
            var filedThisSource = 0
            do {
                // These are structural records, not prose. Code/JSON and mixed
                // content remain eligible; no model failure implies ineligibility.
                if drawer.contentKind == .fingerprintOnly || drawer.contentKind == .dataset
                    || drawer.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    state.outcome = .notApplicable
                    state.reason = "eligibility-v1: structural handle or no textual content"
                    inapplicable += 1
                } else if !state.readyToPublish {
                    guard let chunk = FactSourceChunker.next(originalSource: drawer.content,
                        start: state.nextStart, startUTF8Byte: state.nextStartUTF8Byte,
                        maximumCharacters: state.maximumCharacters) else {
                        throw FactExtractionError.invalidRequest("invalid source continuation")
                    }
                    let request = FactExtractionRequest(sourceID: drawer.id, sourceDigest: digest,
                        sourceText: chunk.text, eligibleSourceSpans: [chunk.span],
                        maximumFacts: extractor.spec.maximumFactsPerSource)
                    let response = try await extractor.extract(request)
                    if response.candidates.count >= request.maximumFacts {
                        throw FactExtractionError.needsSubdivision("response reached its fact budget")
                    }
                    let grounding = FactGroundingValidator.validateChunk(response: response, request: request,
                        chunk: chunk, expectedSpec: extractor.spec)
                    rejected += grounding.rejected.count
                    state.rejectedCandidates += grounding.rejected.count
                    if !grounding.rejected.isEmpty && grounding.accepted.isEmpty {
                        throw FactExtractionError.malformedResponse("all candidates rejected by source grounding")
                    }
                    for candidate in grounding.accepted {
                        let key = GeniusLocusKit.factSemanticKey(candidate, digest: digest, spec: extractor.spec)
                        if !state.candidates.contains(where: { GeniusLocusKit.factSemanticKey($0, digest: digest, spec: extractor.spec) == key }) {
                            state.candidates.append(candidate)
                        }
                    }
                    state.readyToPublish = chunk.span.endUTF8Byte == drawer.content.utf8.count
                    let overlap = state.readyToPublish ? "" : String(chunk.text.unicodeScalars.suffix(
                        min(FactGroundingValidator.maximumEvidenceCharacters, max(0, state.maximumCharacters / 4))))
                    state.nextStart = chunk.span.end - overlap.unicodeScalars.count
                    state.nextStartUTF8Byte = chunk.span.endUTF8Byte - overlap.utf8.count
                    state.attempts = 0; state.malformedAttempts = 0; state.nextAttemptAt = 0
                    state.outcome = .partial; state.reason = ""
                    chunks += 1
                }
            } catch {
                failed += 1
                state.attempts += 1
                state.reason = String(String(describing: error).prefix(512))
                switch error {
                case FactExtractionError.needsSubdivision where state.maximumCharacters > 128:
                    state.maximumCharacters = max(128, state.maximumCharacters / 2)
                    state.outcome = .needsSubdivision; state.nextAttemptAt = 0
                case FactExtractionError.needsSubdivision, FactExtractionError.invalidRequest:
                    state.outcome = .rejected; rejectedSources += 1
                case FactExtractionError.malformedResponse:
                    state.malformedAttempts += 1
                    if state.malformedAttempts < 2 {
                        state.maximumCharacters = min(state.maximumCharacters, max(128, state.maximumCharacters / 2))
                        state.outcome = .retryScheduled; state.nextAttemptAt = epoch + 30
                    } else { state.outcome = .rejected; rejectedSources += 1 }
                case FactExtractionError.unavailable:
                    state.outcome = .blockedProvider; state.nextAttemptAt = epoch + 300
                default:
                    state.outcome = .retryScheduled
                    state.nextAttemptAt = epoch + min(3600, 30 * pow(2, Double(min(state.attempts - 1, 7))))
                }
            }
            state.leaseUntil = 0; state.leaseToken = ""
            let staged = try JSONEncoder().encode(state)
            guard try await checkpoints.compareAndSwap(id: id, stream: stream,
                expected: claim, payload: staged, stamp: stamp) else { skipped += 1; continue }
            advanced = true
            if state.outcome == .rejected {
                // Rejected is settled for this recipe: bits 28 and 29 go on
                // together and the row leaves the debt. The reason stays in
                // the checkpoint row as the analysis corpus.
                _ = try await store.markFactExtractionRejected(
                    sourceID: drawer.id, expectedContent: drawer.content, recipeID: recipeID)
            }
            if state.readyToPublish && state.outcome == .partial {
                // Progress is durable BEFORE publication. If the process dies
                // after the transaction, bit 28 prevents publishing twice.
                let facts = state.candidates.map { candidate in
                    let key = GeniusLocusKit.factSemanticKey(candidate, digest: digest, spec: extractor.spec)
                    return KGFact(id: GeniusLocusKit.distilledFactID(sourceID: drawer.id, recipeID: recipeID, semanticKey: key),
                        subject: candidate.subject, predicate: candidate.predicate, object: candidate.object,
                        sourceDrawerID: drawer.id, addedBy: "distilled-fact-duty",
                        evidenceQuote: candidate.evidenceQuote, evidenceStart: candidate.evidenceSpan.start,
                        evidenceEnd: candidate.evidenceSpan.end, evidenceStartUTF8Byte: candidate.evidenceSpan.startUTF8Byte,
                        evidenceEndUTF8Byte: candidate.evidenceSpan.endUTF8Byte, sourceDigest: digest,
                        extractorProviderID: extractor.spec.providerID, extractorModelID: extractor.spec.modelID,
                        extractorModelVersion: extractor.spec.modelVersion, extractionSchemaVersion: extractor.spec.schemaVersion,
                        searchProjection: candidate.searchProjection, searchProjectionVersion: FactSearchProjection.version,
                        operationalBitmap: GeniusLocusKit.factOperationalBitmap(kind: extractor.spec.extractorKind,
                            assertion: candidate.assertionKind, confidence: candidate.confidence), filedAt: instant)
                }
                if let count = try await store.publishExtractedFacts(sourceID: drawer.id,
                    expectedContent: drawer.content, recipeID: recipeID, facts: facts, now: instant) {
                    filedThisSource = count; completed += 1
                    state.outcome = facts.isEmpty ? .completedEmpty : .completed
                    state.candidates.removeAll()
                    _ = try await checkpoints.compareAndSwap(id: id, stream: stream,
                        expected: staged, payload: try JSONEncoder().encode(state), stamp: stamp)
                } else { skipped += 1 }
            }
            filed += filedThisSource
        }
        var report = FactExtractionBatchResult(completedSources: completed, factsFiled: filed,
            candidatesRejected: rejected, skippedSources: skipped, failedSources: failed)
        report.chunksProcessed = chunks; report.scannedSources = drawers.count
        report.deferredSources = deferred; report.inapplicableSources = inapplicable
        report.rejectedSources = rejectedSources
        report.madeProgress = advanced
        return report
    }
}
