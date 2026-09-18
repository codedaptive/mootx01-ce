// SSCFactsBackfill.swift
//
// The one-time SSC facts backfill `mootx01 upgrade` runs on an estate whose
// drawers predate the `ssc_facts` column (Encoder Rerank contract sheet §6).
//
// The capture path writes a drawer's facts before the drawer is encoded, so
// a live estate never accrues facts debt. An estate migrated from an earlier
// schema arrives with every row NULL; NULL is the "needs facts" predicate,
// and this pass pays it once. The caller rebuilds the BM25 documents
// afterwards (`reindexCorpus`) when the pass wrote anything, because the
// corpus adapter composes the supplement from the column at index time.
//
// Rust twin: `EstateCoordinator::backfill_ssc_facts` (intake.rs).

import Foundation
import LocusKit

public extension GeniusLocusKit {

    /// Write SSC facts for every active drawer whose `ssc_facts` column is
    /// NULL and whose content anchors at least one fact.
    ///
    /// Rows whose content yields no facts stay NULL and are not counted, so a
    /// second pass over the same estate writes nothing: the returned count
    /// is exactly the number of rows whose BM25 document changed, which is
    /// the caller's signal to rebuild the index. The facts are a pure
    /// function of content and are computed with a bounded fan-out per
    /// page; the writes are per-row updates.
    ///
    /// - Parameter handle: the estate. Must be open.
    /// - Returns: the number of rows whose facts were written.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` for a stale handle;
    ///   storage errors from the page reads or the facts writes.
    func backfillSSCFacts(handle: EstateHandle) async throws -> Int {
        let estate = try estate(for: handle)
        let cap = ProcessInfo.processInfo.activeProcessorCount
        var written = 0
        var cursor: String?
        let pageSize = 2_000
        while true {
            let page = try await estate.activeDrawersAfter(id: cursor, limit: pageSize)
            if page.isEmpty { break }
            cursor = page.last?.id
            let owing = page.filter { $0.sscFacts == nil && !$0.content.isEmpty }
            // Facts are pure over content: compute the page's facts across
            // `cap` workers, then write them in order.
            var results = [String??](repeating: nil, count: owing.count)
            var start = 0
            while start < owing.count {
                let end = min(start + cap, owing.count)
                await withTaskGroup(of: (Int, String?).self) { group in
                    for i in start..<end {
                        let content = owing[i].content
                        group.addTask { (i, EnrichmentStage.facts(forContent: content)) }
                    }
                    for await (i, value) in group {
                        results[i] = .some(value)
                    }
                }
                start = end
            }
            for (drawer, value) in zip(owing, results) {
                guard let facts = value ?? nil else { continue }
                _ = try await estate.setSSCFacts(facts, for: drawer.id)
                written += 1
            }
            if page.count < pageSize { break }
        }
        return written
    }
}
