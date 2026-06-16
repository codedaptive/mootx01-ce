// LiveTableSwapTests.swift
//
// Force-tests for the LIVE ATOMIC WordClassTable swap (cookbook §1.3/§2.2).
// These prove IN-SESSION learning: in ONE running process the same live tagger
// adopts a merged table WITHOUT a restart. This is distinct from the foundation
// lane's cross-RELOAD test (NovelTokenEffectivenessTests): there the new table
// is picked up on the NEXT process load; here it is picked up by the RUNNING
// process via WordClassTableCache.swap / reloadFromPrecedence.
//
// Determinism: tagging is deterministic given (input, table-version). A swap
// advances the version; within a version the classification is stable.

import Testing
import Foundation
@testable import LatticeLib

@Suite("Live table swap", .serialized)
struct LiveTableSwapTests {

    /// A token that is NOT in the bundled table and is NOT classified noun/verb
    /// by the deterministic HMM/Apple tagger — so `wordClass` returns `.other`
    /// for it until the table learns it. It carries a digit, so the HMM's
    /// observation is `NonAlpha` (→ `.other`) and Apple's NLTagger does not tag a
    /// digit-bearing token as a noun. After the swap inserts it into the table's
    /// noun set, the constant-time fast path resolves it to `.noun`.
    private static let novelToken = "qx7zglyph"

    /// Build a table snapshot that is the current live table PLUS `extraNoun`.
    private func tablePlusNoun(_ extraNoun: String) -> WordClassTable {
        let current = WordClassTableCache.table
        var nouns = current?.nouns ?? []
        nouns.append(extraNoun)
        return WordClassTable(
            tableVersion: current?.tableVersion ?? "1.0.0",
            minOSVersion: current?.minOSVersion ?? "0.0",
            snapshotDate: current?.snapshotDate ?? "2026-01-01",
            nouns: nouns,
            verbs: current?.verbs ?? [])
    }

    @Test func inSessionLearningViaSwap() async throws {
        // Baseline: the novel token is NOT classified as a noun by the running
        // tagger (it is not in the seed table). The HMM/Apple tagger returns a
        // non-noun for the bare form.
        let before = LatticeLib.wordClass(Self.novelToken)
        #expect(before != .noun, "precondition: novel token must not be a table noun before the swap")
        let versionBefore = WordClassTableCache.version

        // LIVE SWAP: publish a new snapshot that contains the novel token as a
        // noun. No process restart, no reload — the running holder is replaced.
        WordClassTableCache.swap(tablePlusNoun(Self.novelToken))

        // The SAME live tagger now classifies the token from the table — the
        // in-session learning proof.
        let after = LatticeLib.wordClass(Self.novelToken)
        #expect(after == .noun, "in-session: the running tagger must classify the merged token from the table")
        #expect(WordClassTableCache.version == versionBefore + 1, "swap must advance the version")

        // Restore the bundled seed so other suites see a clean table.
        WordClassTableCache.swap(WordClassTable.loadBundled())
    }

    @Test func swapAdvancesVersionDeterministically() async throws {
        let v0 = WordClassTableCache.version
        WordClassTableCache.swap(WordClassTableCache.table)
        let v1 = WordClassTableCache.version
        WordClassTableCache.swap(WordClassTableCache.table)
        let v2 = WordClassTableCache.version
        #expect(v1 == v0 + 1)
        #expect(v2 == v0 + 2)
        // Within a fixed version, classification is stable (deterministic given
        // (input, table-version)).
        let a = LatticeLib.wordClass("dinner")
        let b = LatticeLib.wordClass("dinner")
        #expect(a == b)
    }

    @Test func concurrentReadsDuringSwapNoTornRead() async throws {
        // Seed a known starting table.
        WordClassTableCache.swap(WordClassTable.loadBundled())
        let learned = tablePlusNoun(Self.novelToken)

        // Hammer the tagger from many concurrent tasks while a swapper flips the
        // table back and forth. A torn read would surface as a crash or a value
        // that is neither the pre-swap nor the post-swap classification. The
        // only legal results for the novel token are `.other` (pre) or `.noun`
        // (post) — never garbage.
        await withTaskGroup(of: Void.self) { group in
            // Readers.
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<2_000 {
                        let wc = LatticeLib.wordClass(Self.novelToken)
                        #expect(wc == .other || wc == .noun,
                                "torn read: classification must be the whole pre- or post-swap value")
                        // A always-present bundled token must never be lost
                        // mid-swap (both snapshots contain it).
                        #expect(LatticeLib.wordClass("dinner") == .noun)
                    }
                }
            }
            // Swappers.
            for _ in 0..<2 {
                group.addTask {
                    for i in 0..<500 {
                        if i.isMultiple(of: 2) {
                            WordClassTableCache.swap(learned)
                        } else {
                            WordClassTableCache.swap(WordClassTable.loadBundled())
                        }
                    }
                }
            }
        }

        // Restore the bundled seed.
        WordClassTableCache.swap(WordClassTable.loadBundled())
    }
}
