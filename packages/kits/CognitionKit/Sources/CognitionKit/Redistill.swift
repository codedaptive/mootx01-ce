// Redistill.swift
//
// Recipe that force-redistills ALL active items in the estate, then triggers
// a full derived-lane reindex (laneScope .all) — CDL-02.
// Registered name: `redistill`; the MCP surface lists it as `moot_redistill`.
//
// Contrast with `moot_distill` (Distill recipe): that verb is idempotent by
// the NULL predicate — it skips items that already carry a current-pipeline
// representation. moot_redistill ignores the hasCurrentRepresentation bit
// and force-overwrites every active non-empty drawer unconditionally.
//
// Why the full reindex (laneScope .all)?  The BM25 posting list is built from
// `record.text + TrailerGrammar.lexicalSupplement(fromDenseText: record.denseCompositionText)`.
// For items that were indexed before distillation ran, the BM25 tier never
// saw the EnrichmentStage trailer tokens (which are appended to drawer.distilled
// by distillItem).  After redistillation the `denseCompositionText` field (which
// maps to drawer.distilled) carries the trailer; a full reindex rebuilds the
// BM25 posting lists to admit those tokens.  Dense-only retrains omit BM25 and
// are not sufficient for this use case (addendum CDL-02-BINDING).
//
// Layer discipline B-1/B-2: pure sequencing.  Delegates redistillation work
// to GeniusLocusKit.redistillItemsSweep and the corpus reindex to
// GeniusLocusKit.reindexCorpus(handle:now:) — both are GLK verb surface
// calls, never direct CorpusKit or LocusKit calls.
//
// RecipeCatalog registration: present.

import Foundation
import GeniusLocusKit
import NeuronKit

/// Force-redistill all active items and rebuild both recall indexes
/// (BM25 + dense) from the fresh distillates (`moot_redistill` verb, CDL-02).
public struct Redistill: Recipe {

    // MARK: - Input

    /// Parameters for the redistillation sweep.
    public struct Input: Sendable {
        /// Optional cap on items redistilled (nil = all active items).
        ///
        /// Normally nil — redistill is an estate-wide operation.  Accepted as
        /// a parameter for testability and for the rare case where a partial
        /// sweep is sufficient (e.g. emergency repair of a bounded window).
        public let limit: Int?

        public init(limit: Int? = nil) {
            self.limit = limit
        }
    }

    // MARK: - Output

    /// Result of the redistillation + reindex pass.
    public struct Output: Sendable {
        /// Count of drawer rows whose representation columns were (re)populated.
        public let itemsRedistilled: Int

        public init(itemsRedistilled: Int) {
            self.itemsRedistilled = itemsRedistilled
        }
    }

    // MARK: - Recipe metadata

    public let name = "redistill"
    public let version = "1.0.0"
    public let description =
        "Force-redistill all active items in the estate and rebuild both recall "
        + "indexes (BM25 + dense) from the updated distillates. Unlike moot_distill, "
        + "this verb ignores the hasCurrentRepresentation flag and overwrites every "
        + "active non-empty item unconditionally, then triggers a full laneScope .all "
        + "reindex so BM25 can admit trailer tokens from the distilled text."

    // No external capability gates: redistillation runs the p1 GLK distillation
    // pipeline (on-device, no LLM call) and the on-device BM25+HNSW reindex.
    public let requiredCapabilities: [NeuronKitCapability] = []

    public init() {}

    // MARK: - run

    public func run(
        input: Input,
        estate: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Output {
        try await run(input: input, estate: estate, kit: kit, now: Date())
    }

    /// Internal overload with an explicit clock so tests stamp `distilled_at`
    /// and the reindex `trained_at` deterministically.
    func run(
        input: Input,
        estate: EstateHandle,
        kit: GeniusLocusKit,
        now: Date
    ) async throws -> Output {
        // Step 1: force-redistill every active non-empty drawer.
        // redistillItemsSweep does NOT call recomposeDenseVector per item —
        // the full reindex in step 2 covers all dense vectors.
        let itemsRedistilled = try await kit.redistillItemsSweep(
            handle: estate,
            distillFn: GeniusLocusKit.defaultDistillFn,
            now: now,
            limit: input.limit
        )

        // Step 2: full derived-lane reindex (laneScope .all — BM25 + dense).
        // Rebuilds BM25 posting lists so trailer tokens from the updated
        // distillates are admitted, and re-embeds all dense float vectors.
        // This is a no-op when no Corpus is registered for the estate.
        try await kit.reindexCorpus(handle: estate, now: now)

        return Output(itemsRedistilled: itemsRedistilled)
    }
}
