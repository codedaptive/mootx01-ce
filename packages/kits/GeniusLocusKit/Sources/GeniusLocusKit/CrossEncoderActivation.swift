// CrossEncoderActivation.swift — GeniusLocusKit
//
// The lifecycle of the cross-encoder stage: the packaged profiles this build
// knows, the per-estate manifest limits (`cross_encoder_pool`,
// `cross_encoder_head`, `cross_encoder_spans`, `cross_encoder_profile`), and
// the lazily loaded `PairScorer` per estate. Nothing loads at open: the first
// `apply` on an estate resolves the model directory through the same
// resolver the span encoder uses and builds the scorer once under the actor;
// a failure is remembered so later applies degrade without re-resolving.
// `close` drops the slot. Twin of Rust `EstateCoordinator`'s cross-encoder
// section in coordinator.rs.

import Foundation
import CorpusKit
import CorpusKitProviders
import MootProductIdentity
import OSLog

/// The outcome of `pairScorer(profile:for:)`.
enum PairScorerLoad {
    /// The scorer, and whether this call loaded it.
    case loaded(scorer: any PairScorer, coldLoad: Bool)
    /// A `CrossEncoderStage.Reason` value.
    case unavailable(String)
}

/// What an estate holds for the cross encoder once an apply has been tried.
enum PairScorerSlot: Sendable {
    /// The scorer loaded (or was registered by a host or test).
    case loaded(any PairScorer)
    /// The load failed; the reason is a `CrossEncoderStage.Reason` value.
    case unavailable(String)
}

public extension GeniusLocusKit {

    /// Manifest key: maximum candidates handed to the stage (Int).
    static var crossEncoderPoolMetaKey: String { "cross_encoder_pool" }
    /// Manifest key: maximum scored candidates (Int).
    static var crossEncoderHeadMetaKey: String { "cross_encoder_head" }
    /// Manifest key: maximum spans per scored candidate (Int).
    static var crossEncoderSpansMetaKey: String { "cross_encoder_spans" }
    /// Manifest key: the packaged profile id a directive without one should
    /// mean; informational until the verb surface carries directives.
    static var crossEncoderProfileMetaKey: String { "cross_encoder_profile" }

    /// The profiles this build packages, by `modelID`. One today.
    static var packagedCrossEncoderProfiles: [String: CrossEncoderProfile] {
        [CrossEncoderProfile.minilmL6.modelID: CrossEncoderProfile.minilmL6]
    }

    static var crossEncoderLog: Logger {
        Logger(subsystem: MootProductIdentity.Logging.subsystem, category: "GeniusLocusKit")
    }

    // MARK: - Registry

    /// Register a `PairScorer` for `handle` so the stage uses it instead of
    /// loading the packaged model. Re-registering replaces the entry;
    /// `close(_:)` drops it. Hosts and tests use this; the product path
    /// loads lazily through `pairScorer(profile:for:)`.
    func registerPairScorer(_ scorer: any PairScorer, for handle: EstateHandle) {
        pairScorers[handle] = .loaded(scorer)
    }

    /// Whether a loaded scorer is held for `handle` (registered or lazily
    /// loaded). False for a stale handle and after `close`.
    func isPairScorerRegistered(for handle: EstateHandle) -> Bool {
        if case .loaded = pairScorers[handle] { return true }
        return false
    }

    // MARK: - Manifest limits

    /// Store the three limits on the estate manifest. Values above the
    /// packaged profile's maxima are stored as given and clamped on read.
    func provisionCrossEncoderLimits(pool: Int, head: Int, spans: Int, for handle: EstateHandle) async throws {
        let estate = try estate(for: handle)
        do {
            try await estate.setMeta(key: Self.crossEncoderPoolMetaKey, value: String(pool))
            try await estate.setMeta(key: Self.crossEncoderHeadMetaKey, value: String(head))
            try await estate.setMeta(key: Self.crossEncoderSpansMetaKey, value: String(spans))
        } catch {
            throw remap(verb: "provisionCrossEncoderLimits", estateID: handle.estateUUID.uuidString, error: error)
        }
    }

    /// The limits for `profile` on `handle`: each manifest key when present
    /// and a positive integer, else the profile's value; every one clamped
    /// to the profile's maximum (ruling: the manifest adjusts the maxima
    /// downward, never above the packaged profile).
    func provisionedCrossEncoderLimits(profile: CrossEncoderProfile, for handle: EstateHandle) async -> CrossEncoderLimits {
        let pool = min(profile.pool, await positiveIntMeta(key: Self.crossEncoderPoolMetaKey, for: handle) ?? profile.pool)
        let head = min(profile.head, await positiveIntMeta(key: Self.crossEncoderHeadMetaKey, for: handle) ?? profile.head)
        let spans = min(profile.spans, await positiveIntMeta(key: Self.crossEncoderSpansMetaKey, for: handle) ?? profile.spans)
        return CrossEncoderLimits(pool: pool, head: head, spans: spans)
    }

    /// Fail-quiet positive-Int manifest read shared with the encoder keys.
    private func positiveIntMeta(key: String, for handle: EstateHandle) async -> Int? {
        guard let estate = try? estate(for: handle),
              let raw = try? await estate.meta(key: key),
              let value = Int(raw.trimmingCharacters(in: .whitespaces)),
              value > 0 else {
            return nil
        }
        return value
    }

    // MARK: - Lazy load

    /// The scorer for `profile` on `handle`, loading it on the first call.
    ///
    /// Returns the scorer and whether THIS call loaded it (`coldLoad`), or
    /// the `CrossEncoderStage.Reason` the stage reports. The load runs under
    /// the actor with no suspension between the slot check and the insert,
    /// so two concurrent first applies load once. A failed load is cached as
    /// `.unavailable` until `close`.
    internal func pairScorer(profile: CrossEncoderProfile, for handle: EstateHandle) -> PairScorerLoad {
        switch pairScorers[handle] {
        case .loaded(let scorer):
            return .loaded(scorer: scorer, coldLoad: false)
        case .unavailable(let reason):
            return .unavailable(reason)
        case nil:
            break
        }
#if MOOTX01_CROSS_ENCODER
        guard let directory = modelDirectoryResolver.encoderModelDirectory(for: profile.modelID) else {
            Self.crossEncoderLog.warning(
                "cross encoder: no model directory for \(profile.modelID, privacy: .public); apply degrades (estate: \(handle.estateUUID, privacy: .public))"
            )
            pairScorers[handle] = .unavailable(CrossEncoderStage.Reason.modelUnavailable)
            return .unavailable(CrossEncoderStage.Reason.modelUnavailable)
        }
        do {
            let scorer = try PairScorerFactory.make(profile: profile, modelDirectory: directory)
            pairScorers[handle] = .loaded(scorer)
            Self.crossEncoderLog.info(
                "cross encoder: loaded \(profile.modelID, privacy: .public) (\(scorer.backend, privacy: .public)) from \(directory.path, privacy: .public) (estate: \(handle.estateUUID, privacy: .public))"
            )
            return .loaded(scorer: scorer, coldLoad: true)
        } catch {
            Self.crossEncoderLog.warning(
                "cross encoder: \(profile.modelID, privacy: .public) unavailable (\(String(describing: error), privacy: .public)); apply degrades (estate: \(handle.estateUUID, privacy: .public))"
            )
            pairScorers[handle] = .unavailable(CrossEncoderStage.Reason.modelUnavailable)
            return .unavailable(CrossEncoderStage.Reason.modelUnavailable)
        }
#else
        pairScorers[handle] = .unavailable(CrossEncoderStage.Reason.capabilityOff)
        return .unavailable(CrossEncoderStage.Reason.capabilityOff)
#endif
    }
}

// MARK: - The stage as the director runs it

extension GeniusLocusKit {

    /// Run the cross-encoder stage over `hits` (the authorized final list,
    /// possibly widened to the pool) for `directive`.
    ///
    /// Returns the hits to hand on (reordered within the pool on apply,
    /// unchanged otherwise), the report, and whether the apply degraded.
    /// Never throws: every failure is a degrade with the incoming order.
    func runCrossEncoderStage(
        handle: EstateHandle,
        request: GLKRecallRequest,
        directive: RerankDirective,
        profile: CrossEncoderProfile?,
        limits: CrossEncoderLimits?,
        hits: [RecallHit]
    ) async -> (hits: [RecallHit], report: CrossEncoderReport, degraded: Bool) {
        guard directive.action == .apply else {
            return (hits, .bypassed(directive), false)
        }
        guard let profile, let limits else {
            return (hits, .degraded(directive, reason: CrossEncoderStage.Reason.profileUnknown, limits: nil), true)
        }
        let query = (request.queryText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return (hits, .degraded(directive, reason: CrossEncoderStage.Reason.noQueryText, limits: limits), true)
        }
        let scorer: any PairScorer
        let coldLoad: Bool
        switch pairScorer(profile: profile, for: handle) {
        case .loaded(let value, let cold):
            scorer = value
            coldLoad = cold
        case .unavailable(let reason):
            return (hits, .degraded(directive, reason: reason, limits: limits), true)
        }

        let clock = ContinuousClock()
        let started = clock.now
        let pool = min(limits.pool, hits.count)
        let head = min(limits.head, pool)
        let headHits = Array(hits.prefix(head))

        // Span rows and the query vector come from the registered span rerank
        // source when there is one; a read failure only means the windowed
        // fallback in `selectSpans` is used, never a degrade.
        var rows: [String: [SpanRerankVector]] = [:]
        var queryVector: [Float]? = nil
        if let source = spanRerankSources[handle], !headHits.isEmpty,
           let vector = try? await source.encoder.encodeQuery(query), !vector.isEmpty {
            queryVector = vector
            rows = (try? await source.store.spanVectors(
                itemIDs: headHits.map(\.id), modelID: source.encoder.modelID)) ?? [:]
        }
        let spec = spanEncoders[handle]?.spec ?? EncoderModelSpec.floor

        var logits: [String: [Float]] = [:]
        var scored = 0
        for hit in headHits {
            guard let content = hit.drawer?.content else { continue }
            let spans = CrossEncoderStage.selectSpans(
                content: content, rows: rows[hit.id], queryVector: queryVector,
                limit: limits.spans, windowWords: spec.windowWords, overlapDivisor: spec.overlapDivisor)
            guard !spans.isEmpty else { continue }
            do {
                let values = try await scorer.score(query: query, spans: spans)
                logits[hit.id] = values
                if !values.isEmpty { scored += 1 }
            } catch {
                Self.crossEncoderLog.error(
                    "cross encoder: scoring failed (\(String(describing: error), privacy: .public)); incoming order stands (estate: \(handle.estateUUID, privacy: .public))"
                )
                return (hits, .degraded(directive, reason: CrossEncoderStage.Reason.scorerFailed, limits: limits), true)
            }
        }
        let order = CrossEncoderStage.fuse(
            incoming: hits.prefix(pool).map(\.id), head: head, logits: logits, rrfK: profile.rrfK)
        let reordered = CrossEncoderStage.reorder(hits: hits, pool: pool, order: order)
        let elapsed = clock.now - started
        let report = CrossEncoderReport(
            status: .applied, requested: true, reason: directive.reason,
            profileID: directive.profileID, modelVersion: profile.modelVersion,
            backend: scorer.backend, pool: pool, head: head, spans: limits.spans,
            scored: scored, coldLoad: coldLoad,
            stageMillis: Int(elapsed / .milliseconds(1)))
        return (reordered, report, false)
    }
}
