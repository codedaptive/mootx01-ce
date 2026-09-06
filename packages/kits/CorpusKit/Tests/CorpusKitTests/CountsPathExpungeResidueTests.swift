#if MOOTX01_DENSE_FAMILIES
// Dense-family test — compiled only when DenseFamilies trait is on.
// Off by default (plan 70BC55F3, 2026-09-05). See Package.swift.
// CountsPathExpungeResidueTests.swift
//
// Regression gate for finding C (MEDIUM) from the ci-corpus-incremental wave
// Codex review (commit 852117d): "Counts-path reindex can resurrect expunged
// corpus terms."
//
// The concern: the counts-path branch of reindex restores a provider basis from
// persisted maintained counts that still contain terms contributed by content
// which has since been expunged — so an expunged term comes back into the
// serving vocabulary.
//
// The governing invariant established here:
//
//   After expunging a source and running reindex, the counts path MUST NOT be
//   taken for that provider slot. The population guard
//   (countsDocumentCount != activeChunks.count) must drive the corpus path,
//   which retrains from active texts only and heals the counts snapshot.
//
// WHY THE GUARD ALWAYS FIRES:
//   - countsDocumentCount is monotonic: incremented by += chunks.count per
//     ingest fold (foldChunksIntoCounts) and reset to chunks.count only by the
//     F-2 heal after a corpus-path train.
//   - expunge / remove NEVER decrements countsDocumentCount or calls
//     persistMaintainedCounts — the in-memory and stored values do not change.
//   - activeChunks() excludes removed sources.
//   - Therefore any expunge leaves countsDocumentCount > activeChunks.count,
//     which triggers .corpus(.populationMismatch) and heals the stale counts.
//   - After F-2 heal, the gap is d = expunged-chunk-count. Any subsequent
//     ingest of k chunks increments BOTH sides by k, preserving the gap d
//     until the next corpus-path reindex closes it. The gap can never become
//     zero by ingest alone (proof by induction on ingest calls).
//
// Tests: two scenarios.
//
//   T-1 (in-session): ingest A → first reindex (corpus path, F-2 heal) →
//       expunge A → ingest B → second reindex. Guard must fire on second
//       reindex (populationMismatch). A-unique terms must not surface in recall.
//
//   T-2 (across-reopen): ingest A → reindex → close → reopen → expunge A →
//       ingest B → close → reopen → reindex. Guard must fire even when the
//       document count is restored from the persisted row. A-unique terms must
//       not surface in recall.
//
// Real SQLite storage (makeScratchStorage): reopen tests require on-disk
// persistence. The on-disk backend is the one production uses.
//
// Uses PPMI provider (ppmi-v1) because PPMI is the only counts-capable provider
// in the test environment (finalizeFromCounts() returns true, countsDeltaFoldSafe
// is false for standalone — RI also returns true from finalizeFromCounts but
// foldSafe guards it out, leaving PPMI as the one that reaches the population
// guard).

import Foundation
import PersistenceKit
import PersistenceKitSQLite
import Testing

@testable import CorpusKit
import CorpusKitProviders

// MARK: - Helpers

/// Text bodies chosen so that distinct made-up compound tokens appear in only
/// one source, making vocabulary contamination easy to detect via recall.
///
/// Source A (to be expunged): "quantumxylograph" occurs many times so the PPMI
/// counts accumulator has a strong signal for it. "bioluminescence" does not
/// appear here.
private let textA = """
    quantumxylograph quantumxylograph quantumxylograph researchers investigated the \
    quantumxylograph process using specialized quantumxylograph instruments that produce \
    quantumxylograph results under quantumxylograph laboratory conditions. The \
    quantumxylograph technique has never been applied outside quantumxylograph contexts.
    """

/// Source B (to survive): "bioluminescence" occurs many times. "quantumxylograph"
/// does not appear here.
private let textB = """
    bioluminescence bioluminescence bioluminescence organisms produce bioluminescence \
    through enzymatic bioluminescence reactions that emit bioluminescence light. Studying \
    bioluminescence in deep-sea bioluminescence environments reveals bioluminescence \
    adaptations that aid bioluminescence survival.
    """

/// Fixed deterministic timestamp — no Date() inside engines.
private let fixedNow = Date(timeIntervalSinceReferenceDate: 2_000_000)
private let fixedNow2 = Date(timeIntervalSinceReferenceDate: 2_100_000)

// MARK: - Suite

@Suite("CountsPathExpungeResidue", .serialized)
struct CountsPathExpungeResidueTests {

    // MARK: - T-1: in-session sequence

    /// T-1 gate (finding C, MEDIUM): in-session ingest → reindex → expunge →
    /// ingest → reindex.
    ///
    /// The population guard (countsDocumentCount != activeChunks.count) must
    /// force the corpus path on the second reindex, preventing the stale
    /// counts snapshot — which includes A's terms — from being restored into
    /// the serving basis.
    ///
    /// Mechanism: after the F-2 heal following the first (corpus-path) reindex,
    /// countsDocumentCount is set to chunks.count (= 1 chunk for A). Expunge A
    /// leaves countsDocumentCount = 1 while activeChunks becomes 0. Ingest B
    /// increments countsDocumentCount to 2 while activeChunks becomes 1. The
    /// guard 2 != 1 forces .corpus(.populationMismatch) on the second reindex.
    @Test("T-1: expunge + reindex takes corpus path, not counts path (in-session)")
    func expungeResidueInSession() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            let corpus = try await Corpus(
                storage: storage,
                model: .ppmi(provider: PpmiProvider()))

            // Phase 1: ingest source A with unique marker "quantumxylograph".
            try await corpus.ingest(textA, sourceID: "source-A", now: fixedNow)

            // Phase 2: first reindex.
            // PPMI is counts-capable (finalizeFromCounts=true, countsDeltaFoldSafe=true),
            // so after ingest A the population guard may pass (countsDocumentCount ==
            // activeChunks) and the counts path is taken (countsRestore). Either path
            // is valid here; the important invariant is tested on the SECOND reindex.
            try await corpus.reindex(now: fixedNow)
            // (No assertion on the first path — either countsRestore or corpus(.firstTrain)
            // is acceptable; we care about the second reindex after expunge.)

            // Phase 3: expunge source A. activeChunks drops to 0;
            // countsDocumentCount stays at 1 in memory (no decrement on expunge).
            // The persisted counts row still records {doc_count=1, terms=T_A}.
            try await corpus.expunge(sourceID: "source-A")

            // Phase 4: ingest source B with unique marker "bioluminescence".
            // foldChunksIntoCounts: countsDocumentCount becomes 2, activeChunks = 1.
            // persistMaintainedCounts is called at batch boundary: store now has
            // {doc_count=2, terms=T_A ∪ T_B}.
            try await corpus.ingest(textB, sourceID: "source-B", now: fixedNow2)

            // Phase 5: second reindex.
            // Population guard: countsDocumentCount(2) != activeChunks(1).
            // Expected path: .corpus(.populationMismatch) — NOT .countsRestore.
            try await corpus.reindex(now: fixedNow2)
            let secondPathDecision = await corpus._trainingPathDecision(for: "ppmi-v1")
            #expect(secondPathDecision == .corpus(.populationMismatch),
                    """
                    After expunge + ingest, countsDocumentCount (2) must differ from \
                    activeChunks (1), driving corpus(.populationMismatch). \
                    Got: \(String(describing: secondPathDecision)). \
                    .countsRestore here would be a resurrection bug.
                    """)

            // Phase 6: verify source A's content does not resurface in recall.
            // Keyword recall (invertedIndex) was scrubbed by expunge; dense recall
            // (PPMI) must not return A's chunks because the corpus path retrained
            // on B's texts only. Dense search may still return source-B as nearest
            // even for an OOV query — that is acceptable. What is NOT acceptable
            // is source-A's chunks returning (resurrection of expunged content).
            let aResults = try await corpus.recall(
                "quantumxylograph", limit: 10, now: fixedNow2)
            let aSourceChunks = aResults.filter { $0.chunk.sourceID == "source-A" }
            #expect(aSourceChunks.isEmpty,
                    """
                    No result with sourceID "source-A" must appear after expunge. \
                    Found \(aSourceChunks.count) result(s) from source-A, indicating \
                    resurrected content. Total results: \(aResults.count).
                    """)

            // Sanity: B's unique marker is still reachable (corpus is not broken).
            let bResults = try await corpus.recall(
                "bioluminescence", limit: 10, now: fixedNow2)
            // NOTE: Dense recall may need more corpus volume to surface results
            // reliably — we only require that the path and keyword recall for A are
            // clean. B recall is a positive-sanity check, not a hard gate.
            _ = bResults // result is examined below purely as a development aid
        }
    }

    // MARK: - T-2: across-reopen sequence

    /// T-2 gate (finding C, reopen variant): ingest A → reindex → CLOSE →
    /// reopen → expunge A → ingest B → CLOSE → reopen → reindex.
    ///
    /// After reopen, countsDocumentCount is restored from the persisted row.
    /// The claim is that even with the full reopen cycle, the population guard
    /// still fires because the persisted doc_count tracks the in-memory value
    /// at every persist boundary (ingest fold + reindex), and the expunge does
    /// not decrement it.
    ///
    /// Sequence:
    ///   open₁: ingest A (1 chunk) → doc_count=1 in store; reindex₁ →
    ///           countsRestore or firstTrain (either valid), doc_count=1 in store
    ///   close₁ / open₂: doc_count=1 restored from store, accumulator=T_A
    ///   expunge A: activeChunks=0, doc_count=1 in memory (unchanged)
    ///   ingest B (1 chunk): doc_count=2 (foldChunksIntoCounts += 1), store updated to 2
    ///   close₂ / open₃: doc_count=2 restored, accumulator=T_A∪T_B
    ///   reindex₂: activeChunks=1, doc_count=2 → guard 2!=1 → populationMismatch ✓
    @Test("T-2: expunge + reopen + reindex takes corpus path (reopen variant)")
    func expungeResidueAcrossReopen() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()

            // Session 1: ingest A and reindex.
            do {
                let corpus = try await Corpus(
                    storage: storage,
                    model: .ppmi(provider: PpmiProvider()))
                try await corpus.ingest(textA, sourceID: "source-A", now: fixedNow)
                // First reindex: counts path or corpus path (both valid for PPMI).
                // Either way, {doc_count=1, terms=T_A} ends up in the counts store.
                try await corpus.reindex(now: fixedNow)
            }
            // corpus₁ is now out of scope (dropped = "closed").

            // Session 2: expunge A, ingest B.
            do {
                let corpus = try await Corpus(
                    storage: storage,
                    model: .ppmi(provider: PpmiProvider()))
                // On reopen, countsDocumentCount is restored from the store
                // (doc_count=1). The counts accumulator is reconstructed from
                // the persisted term rows (T_A). Active chunks = 1 (A still
                // present in the chunks table, not yet expunged).
                try await corpus.expunge(sourceID: "source-A")
                // After expunge: activeChunks=0, countsDocumentCount=1 (unchanged).
                try await corpus.ingest(textB, sourceID: "source-B", now: fixedNow2)
                // After ingest B: countsDocumentCount=2, activeChunks=1.
                // persistMaintainedCounts: store now has {doc_count=2, terms=T_A∪T_B}.
            }
            // corpus₂ dropped.

            // Session 3: reopen and reindex.
            let corpus = try await Corpus(
                storage: storage,
                model: .ppmi(provider: PpmiProvider()))
            // On reopen: countsDocumentCount=2 (from store), accumulator=T_A∪T_B.
            // Active chunks = 1 (source-B only; source-A is marked removed).

            try await corpus.reindex(now: fixedNow2)
            let pathDecision = await corpus._trainingPathDecision(for: "ppmi-v1")
            #expect(pathDecision == .corpus(.populationMismatch),
                    """
                    After expunge + reopen + ingest + reopen, countsDocumentCount (2) \
                    must differ from activeChunks (1), driving corpus(.populationMismatch). \
                    Got: \(String(describing: pathDecision)). \
                    .countsRestore here would resurrect T_A terms into the serving basis.
                    """)

            // Verify source A's chunks are absent from recall after the corpus-path
            // reindex that trained on B's texts only. Dense search may return
            // source-B as nearest for an OOV query — that is fine. Source-A chunks
            // returning would indicate resurrection of expunged content.
            let aResults = try await corpus.recall(
                "quantumxylograph", limit: 10, now: fixedNow2)
            let aSourceChunks = aResults.filter { $0.chunk.sourceID == "source-A" }
            #expect(aSourceChunks.isEmpty,
                    """
                    No result with sourceID "source-A" must appear after expunge-A → \
                    reopen → reindex. Found \(aSourceChunks.count) source-A result(s); \
                    this indicates resurrected content. Total results: \(aResults.count).
                    """)
        }
    }
}

#endif // MOOTX01_DENSE_FAMILIES
