// ExternalCorpus.swift
//
// The external reference corpus the migration benchmark scores a branch
// against (NEURONKIT_SPEC § 4.7). A corpus is any enumerable reference
// set flattened to a list of id/content/tags entries.
//
// Corpus construction paths (VK-ADAPT-01, data-movement privacy tiers):
//   - VaultKit's CorpusProjection converts [NoteIR] → ExternalCorpus for
//     the adapter → bridge import pipeline.
//   - ARIA_MCP can construct a corpus inline from wire args.
//   - NeuronKit's benchmark algorithm constructs corpora programmatically
//     from captured drawer content.
//
// Decode knowledge for the external memory-tool JSON export format lives
// in VaultKit's ExchangeAdapter per data-movement privacy tiers; it is not
// reproduced here.
//
// Ownership rationale: "external" means external to a GeniusLocus
// estate — the reference frame belongs to the consumer, not the
// substrate. This type lives in GeniusLocusKit because the migration
// API (GLK-MIG-02) is where the corpus is *used as an estate input*.
// NeuronKit's benchmark algorithm (`BenchmarkAlgorithm.swift`) imports
// GeniusLocusKit and therefore receives this type for free through the
// existing GLK → NK dependency, without a circular dependency.
//
// Previously owned by NeuronKit. Relocated here in GLK-MIG-02 to
// resolve a circular dependency: NeuronKit already imports GLK, so
// defining ExternalCorpus here lets GLK's migration API accept it
// without creating a GLK → NK import cycle.

import Foundation
import LocusKit
import CorpusKit

/// A single entry in an external reference corpus used for migration
/// benchmarking. `id` is the stable identifier from the source system
/// (an external tool node ID, a reference key); it is compared against
/// `Drawer.id` values recalled from a branch. In a lossless migration
/// each entry's `id` equals the `id` of the drawer the migration
/// produced from it, so the benchmark's expected-vs-found set
/// comparison is an identity comparison.
public struct ExternalEntry: Sendable, Codable, Equatable {
    /// Stable identifier from the source system. The benchmark treats
    /// this as the expected rank-1 recall target for the entry's query.
    public let id: String
    /// Verbatim text — the basis for the derived `RecallFrame` query.
    public let content: String
    /// Classification tags carried from the source system. Advisory;
    /// the benchmark does not weight on them in v1. Tags are populated
    /// by VaultKit's CorpusProjection from NoteIR.tags when the corpus
    /// originates from the adapter → bridge import pipeline.
    public let tags: [String]

    public init(id: String, content: String, tags: [String]) {
        self.id = id
        self.content = content
        self.tags = tags
    }
}

/// An external corpus for benchmark comparison — an exchange-format export or
/// any enumerable reference set. Owned by GeniusLocusKit; consumed by
/// the migration API and by NeuronKit's benchmark algorithm. Value
/// type, fully `Sendable`.
public struct ExternalCorpus: Sendable, Codable, Equatable {
    /// Human-readable corpus name, carried through from the export.
    public let name: String
    /// The reference entries, in export order. `asRecallFrames()`
    /// preserves this order so a caller-supplied `queries` override can
    /// stay index-aligned with the expected concept IDs.
    public let entries: [ExternalEntry]

    public init(name: String, entries: [ExternalEntry]) {
        self.name = name
        self.entries = entries
    }

    /// One `RecallFrame` per entry, in entry order.
    ///
    /// Each frame is a content-driven query whose expected rank-1 result
    /// is the entry's `id` in a lossless migration. The filter chain is
    /// `[.unconfirmed, .contentMatches(entry.content)]`:
    ///
    /// - `.contentMatches` is content-driven (not ID-driven) on purpose:
    ///   the benchmark measures whether the migrated branch can *recall*
    ///   the concept from its text, which is what a real consumer query
    ///   does. An ID lookup would test storage round-trip, not recall
    ///   fidelity. This is the LocusKit content-match path used for
    ///   estate-level existence checking in `verifyMigration`. For
    ///   hybrid BM25+vector recall through the CorpusKit tier (with
    ///   both `vectorScore` and `keywordScore` on each result), call
    ///   `hybridRecall(via:limit:now:)` instead.
    /// - `.unconfirmed` is required, not incidental. The recall evaluator
    ///   inserts four implicit filters for any axis the chain leaves
    ///   unconstrained (spec § 7.9.5), and one of them is `.userConfirmed`.
    ///   Imported drawers enter the branch through the `capture` verb and
    ///   are unconfirmed by default, so without an explicit confirmation
    ///   constraint every freshly imported row would be hidden behind the
    ///   default `.userConfirmed` filter and the benchmark would report a
    ///   total loss. Constraining the axis to `.unconfirmed` matches the
    ///   imported-content state and mirrors the substrate's own branch
    ///   enumeration in `glkPromoteBranch` / `glkMergeDrawers`.
    /// - `hydrationLevel: .structured` because the benchmark only reads
    ///   `Drawer.id`; full blob hydration would be wasted work.
    /// - `ordering: .byCaptureTimeDesc` is the deterministic default that
    ///   matches the GLK branch recall used elsewhere; the benchmark's
    ///   MRR uses the position of the expected ID within this ordering.
    public func asRecallFrames() -> [LocusKit.RecallFrame] {
        entries.map { entry in
            LocusKit.RecallFrame(
                filterChain: [.unconfirmed, .contentMatches(entry.content)],
                hydrationLevel: .structured,
                ordering: .byCaptureTimeDesc
            )
        }
    }

    /// Execute hybrid BM25+vector recall for each corpus entry via the
    /// canonical-content engine. Returns one `[CorpusContentHit]` list per
    /// entry, in entry order. Entries with empty content return an empty
    /// list without querying the store.
    ///
    /// This is the shared-content 1.1 recall path.
    /// Recall fuses vector kNN and BM25 keyword scores via Reciprocal Rank
    /// Fusion, surfacing both `vectorScore` and `keywordScore` on each
    /// result. For the LocusKit-only content-match path used in
    /// `verifyMigration`, use `asRecallFrames()`.
    ///
    /// - Parameters:
    ///   - corpus: The estate's canonical-content engine.
    ///   - limit: Maximum canonical content hits per entry. Default 10.
    ///   - now: Deterministic clock — forwarded to `CorpusContentEngine.recall` per the
    ///     fleet determinism rule (CLAUDE.md).
    ///
    /// - Returns: One `[CorpusContentHit]` list per entry, index-aligned with
    ///   `entries`. Entries with empty content produce an empty list.
    ///
    /// - Throws: `CorpusKitError` if any recall call fails.
    public func hybridRecall(
        via corpus: CorpusKit.CorpusContentEngine,
        limit: Int = 10,
        now: Date
    ) async throws -> [[CorpusKit.CorpusContentHit]] {
        var results: [[CorpusKit.CorpusContentHit]] = []
        results.reserveCapacity(entries.count)
        for entry in entries {
            guard !entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                results.append([])
                continue
            }
            let hits = try await corpus.recall(entry.content, limit: limit, now: now)
            results.append(hits)
        }
        return results
    }
}
