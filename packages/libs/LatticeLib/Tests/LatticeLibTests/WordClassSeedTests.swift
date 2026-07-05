// WordClassSeedTests.swift
//
// Tests for the curated WordClassTable pristine seed shipped in
// Resources/WordClassTable.json (table_version 1.1.0, snapshot_date
// 2026-07-04). Prior to this seed the bundled table carried only 21
// nouns / 18 verbs — a hand-written v0.8 test fixture, not a production
// seed — so nearly every token on a fresh estate fell through to the
// HMM fallback (cookbook §2.1's "fast path covers the vast majority of
// tokens" was not actually true on a fresh install). This mission grows
// the pristine seed to real fast-path coverage while preserving every
// existing entry (including the deliberately dual-classed "run" fixture
// that the shared-vector precedence test depends on) untouched.
//
// Four things are asserted here:
//   1. The artifact loads and its counts match what was shipped.
//   2. A newly-seeded noun/verb resolves via the table fast path WITHOUT
//      invoking the HMM fallback — proved via the same sharedNovelCache
//      delta seam WordClassRecordNovelTests.swift uses (a table hit never
//      calls sharedNovelCache.record; a genuine novel token always does).
//   3. A curated list of common English noun/verb homographs ("run",
//      "watch", "book", "water", "light", ...) is ABSENT from the new
//      additions, so a future edit accidentally reintroducing an
//      ambiguous word is caught here rather than silently degrading the
//      fast path to a permanent, context-blind misclassification.
//   4. PoolReducer merge precedence still treats every seeded token as
//      table-resident (skipped, not re-added) over the larger seed.

import Foundation
import Testing
@testable import LatticeLib

@Suite("WordClassTable pristine seed (curated, table_version 1.1.0)", .serialized)
struct WordClassSeedTests {

    // MARK: - 1. Artifact counts

    @Test("bundled seed loads with the shipped table_version and counts")
    func bundledSeedLoadsWithShippedCounts() throws {
        let table = try #require(WordClassTable.loadBundled())
        #expect(table.tableVersion == "1.1.0")
        #expect(table.snapshotDate == "2026-07-04")

        // 466 nouns / 426 verbs: the 21/18 v0.8 fixture entries preserved
        // verbatim, plus the curated additions ("nebula" was dropped from
        // the initial 467-noun draft — it collided with the synthetic
        // novel-token fixture word used by
        // NovelTokenEffectivenessTests.endToEndNovelTokenLearned, see the
        // synthetic-fixture-word guard test below; "solder" and "weld" were
        // dropped from the initial 428-verb draft — Wave 6 Adams finding:
        // both are noun/verb homographs and belong in the ambiguous-word
        // guard's exclusion list below, not the seed). These counts are
        // pinned so an accidental partial edit (e.g. a merge conflict
        // resolution that drops entries) fails loudly rather than
        // silently shrinking the fast path again.
        #expect(table.nouns.count == 466, "noun count drifted from the shipped seed")
        #expect(table.verbs.count == 426, "verb count drifted from the shipped seed")

        // No duplicates within each class.
        #expect(Set(table.nouns).count == table.nouns.count, "duplicate noun entries")
        #expect(Set(table.verbs).count == table.verbs.count, "duplicate verb entries")
    }

    /// The original v0.8 fixture entries must all still be present — this
    /// mission ADDS coverage, it does not touch or reorder the existing
    /// pinned entries (several are direct dependencies of other shared
    /// conformance vectors: "dinner"/"run" in word_class_vectors.json,
    /// "dinner" in the Rust live_table_swap_test.rs, etc.)
    @Test("all pre-existing v0.8 fixture entries are preserved")
    func preExistingEntriesPreserved() throws {
        let table = try #require(WordClassTable.loadBundled())
        let originalNouns = ["dinner", "wife", "husband", "carburetor", "computer",
            "science", "programming", "chemistry", "dog", "house", "car", "water",
            "music", "teacher", "garden", "book", "phone", "city", "river",
            "mountain", "run"]
        let originalVerbs = ["run", "compile", "encode", "eat", "write", "read",
            "drive", "walk", "think", "build", "classify", "resolve", "tag",
            "sing", "cook", "drink", "teach", "plant"]
        for noun in originalNouns {
            #expect(table.nouns.contains(noun), "pre-existing noun '\(noun)' must be preserved")
        }
        for verb in originalVerbs {
            #expect(table.verbs.contains(verb), "pre-existing verb '\(verb)' must be preserved")
        }
    }

    // MARK: - 2. Routing proof — seeded tokens never reach the HMM

    /// A newly-seeded noun resolves via the fast path. Proof: the
    /// sharedNovelCache delta is zero across the call (a table hit never
    /// invokes `tagNovelToken`, which is the only call site that touches
    /// `sharedNovelCache.record`). A genuine novel token, by contrast,
    /// always moves the counter (or drains it to zero at the 50-entry
    /// threshold). `.serialized` because sharedNovelCache is a
    /// process-wide singleton other suites may also write to; the delta
    /// (not the absolute count) is the assertion, matching the pattern in
    /// WordClassRecordNovelTests.swift.
    @Test("newly-seeded noun classifies via fast path (no HMM invocation)")
    func newlySeededNounUsesFastPath() {
        // WordClassTableCache is a process-wide LIVE cache seeded once via
        // writable-artifact precedence (cookbook §1.3/§2.2): on a dev machine
        // that has ever run the real pool-reduce pipeline, a writable artifact
        // predating this mission's bundled-table update may still be on disk
        // and would otherwise shadow the freshly-shipped seed for the whole
        // test process. Publish the freshly-loaded bundled table via the
        // production live-swap API first — the same pattern LiveTableSwapTests
        // uses to restore a clean table for other suites — so this assertion
        // exercises the shipped 1.1.0 seed regardless of local machine state.
        WordClassTableCache.swap(WordClassTable.loadBundled())

        // "astronaut" is one of the curated additions (professions category),
        // not present in the original 21-noun fixture.
        #expect(WordClassTableCache.nounSet.contains("astronaut"))

        let before = LatticeLib.sharedNovelCache.count
        let result = LatticeLib.wordClass("astronaut")
        let after = LatticeLib.sharedNovelCache.count

        #expect(result == .noun)
        #expect(after == before, "table-resident token must not touch sharedNovelCache; before=\(before) after=\(after)")
    }

    @Test("newly-seeded verb classifies via fast path (no HMM invocation)")
    func newlySeededVerbUsesFastPath() {
        // See newlySeededNounUsesFastPath: publish the shipped bundled table
        // via the live-swap API so this test is independent of any writable
        // artifact left on disk by prior local runs.
        WordClassTableCache.swap(WordClassTable.loadBundled())

        // "clarify" is one of the curated additions (the example word named
        // directly in the mission spec).
        #expect(WordClassTableCache.verbSet.contains("clarify"))

        let before = LatticeLib.sharedNovelCache.count
        let result = LatticeLib.wordClass("clarify")
        let after = LatticeLib.sharedNovelCache.count

        #expect(result == .verb)
        #expect(after == before, "table-resident token must not touch sharedNovelCache; before=\(before) after=\(after)")
    }

    /// Control case: a genuine novel token (guaranteed absent from both the
    /// table and any prior test run via a UUID suffix) DOES move the
    /// sharedNovelCache counter, proving the fast-path tests above are
    /// actually exercising the table and not a no-op counter.
    @Test("genuine novel token (not in table) DOES invoke the HMM and record")
    func genuineNovelTokenInvokesHMM() {
        let uid = UUID().uuidString.prefix(8)
        let token = "seedcheck_\(uid)"
        #expect(!WordClassTableCache.nounSet.contains(token))
        #expect(!WordClassTableCache.verbSet.contains(token))

        let before = LatticeLib.sharedNovelCache.count
        _ = LatticeLib.wordClass(token)
        let after = LatticeLib.sharedNovelCache.count

        let increased = after == before + 1
        let drainedToZero = after == 0 && before >= 1
        #expect(increased || drainedToZero,
                "genuine novel token must record into sharedNovelCache; before=\(before) after=\(after)")
    }

    // MARK: - 3. Ambiguous-word absence guard

    /// Common English noun/verb homographs — words whose class flips with
    /// context ("I need a run" vs "I run every day") — must never be added
    /// to the seed. The table is a hard override checked before the HMM
    /// (WordClassTagger.swift: verb set, then noun set, with NO sentence
    /// context available to either path), so seeding an ambiguous word
    /// would permanently force one class regardless of use. "run" is the
    /// sole, deliberate, pre-existing exception (kept for the verb-before-
    /// noun precedence fixture that other shared vectors depend on); this
    /// guard locks the curated ADDITIONS to the unambiguous-only standard
    /// so a future edit cannot silently reintroduce ambiguity.
    @Test("known noun/verb-ambiguous English words are absent from the seed")
    func ambiguousWordsAbsentFromSeed() throws {
        let table = try #require(WordClassTable.loadBundled())
        let nounSet = Set(table.nouns)
        let verbSet = Set(table.verbs)

        // Common homographs NOT already grandfathered in the v0.8 fixture.
        // A word here appearing in EITHER set (other than the pre-existing
        // "run" and "drive" -- "drive" is one of the original 18 verbs and
        // out of this mission's scope to remove) is a regression.
        let ambiguousWords = [
            "watch", "work", "place", "name", "light", "spring",
            "land", "park", "hand", "face", "head", "back", "cover", "order",
            "act", "play", "fish", "hunt", "guard", "host", "brief", "lift",
            "form", "shape", "style", "color", "paint", "stain", "spot",
            "mark", "brand", "label", "stamp", "seal", "sign", "note",
            "record", "report", "plan", "project", "process", "program",
            "format", "model", "pattern", "structure", "function", "target",
            "focus", "base", "source", "force", "charge", "balance", "profit",
            "value", "use", "need", "chair", "table", "desert", "harbor",
            "microwave", "sandwich", "swamp", "warehouse", "plateau",
            "referee", "quarterback", "snowboard", "skateboard", "buffalo",
            "monitor", "coach", "train", "author", "produce", "design",
            "estimate", "delegate", "coordinate", "moderate", "initiate",
            "affiliate", "subordinate", "aggregate",
            // Adams finding (Wave 6): "point" (a point / to point), "solder"
            // (a solder joint / to solder), and "weld" (a weld / to weld)
            // were missing from this guard. "solder" and "weld" were
            // ALREADY present in the shipped verbs table (a latent
            // ambiguity this guard should have caught) — removed from
            // Resources/WordClassTable.json as part of this fix.
            "point", "solder", "weld",
        ]
        var offenders: [String] = []
        for word in ambiguousWords {
            if nounSet.contains(word) { offenders.append("\(word) (noun)") }
            if verbSet.contains(word) { offenders.append("\(word) (verb)") }
        }
        #expect(offenders.isEmpty,
                "ambiguous word(s) present in the seed: \(offenders.joined(separator: ", "))")
    }

    /// The curated additions (i.e. everything beyond the original 21/18
    /// fixture) must never intersect noun and verb — that would itself be
    /// an ambiguous word smuggled into both sets.
    @Test("curated noun and verb additions do not overlap each other")
    func curatedAdditionsDoNotOverlap() throws {
        let table = try #require(WordClassTable.loadBundled())
        let originalNouns: Set<String> = ["dinner", "wife", "husband", "carburetor",
            "computer", "science", "programming", "chemistry", "dog", "house",
            "car", "water", "music", "teacher", "garden", "book", "phone",
            "city", "river", "mountain", "run"]
        let originalVerbs: Set<String> = ["run", "compile", "encode", "eat",
            "write", "read", "drive", "walk", "think", "build", "classify",
            "resolve", "tag", "sing", "cook", "drink", "teach", "plant"]

        let addedNouns = Set(table.nouns).subtracting(originalNouns)
        let addedVerbs = Set(table.verbs).subtracting(originalVerbs)
        let overlap = addedNouns.intersection(addedVerbs)
        #expect(overlap.isEmpty, "curated additions overlap noun/verb: \(overlap.sorted())")
    }

    /// Synthetic "obviously novel" words used as fixtures by other test
    /// files (NovelTokenEffectivenessTests, LiveTableSwapTests, the Rust
    /// mirrors) MUST stay absent from the seed — those tests rely on the
    /// word being a genuine table miss so the novel-token learning loop
    /// has something to prove. This guard exists because the initial
    /// curation draft for this mission included "nebula" (astronomy
    /// category) and it silently collided with
    /// NovelTokenEffectivenessTests.endToEndNovelTokenLearned's fixture,
    /// dropping `PoolReduceResult.nounsAdded` from 3 to 2 for that test
    /// (a table-resident token is skipped, not re-merged, by design —
    /// PoolReducer.swift choice 3). "nebula" was removed from this
    /// mission's additions as a result; this test locks that decision in.
    @Test("synthetic novel-token fixture words used by other test files stay out of the seed")
    func syntheticFixtureWordsAbsentFromSeed() throws {
        let table = try #require(WordClassTable.loadBundled())
        let nounSet = Set(table.nouns)
        let verbSet = Set(table.verbs)
        let fixtureWords = ["quasar", "nebula", "photon", "magnetar", "xenolith",
                             "pulsar", "brachiosaurus"]
        var offenders: [String] = []
        for word in fixtureWords {
            if nounSet.contains(word) { offenders.append("\(word) (noun)") }
            if verbSet.contains(word) { offenders.append("\(word) (verb)") }
        }
        #expect(offenders.isEmpty,
                "synthetic fixture word(s) leaked into the seed: \(offenders.joined(separator: ", "))")
    }

    // MARK: - 4. PoolReducer merge precedence over the larger seed

    /// A pool submission naming an ALREADY-table-resident token (from the
    /// curated additions, not just the original 21/18) must be skipped by
    /// the reducer exactly as it was for the original fixture entries —
    /// merge precedence is unaffected by seed size.
    @Test("PoolReducer skips a table-resident token from the curated additions")
    func poolReducerSkipsCuratedAdditionEntry() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice_seed_precedence_\(UUID().uuidString)")
        let poolDir = base.appendingPathComponent("pool", isDirectory: true)
        let artifactURL = base.appendingPathComponent("WordClassTable.json")
        defer { try? FileManager.default.removeItem(at: base) }

        let bundled = try #require(WordClassTable.loadBundled())

        // "astronaut" is a curated addition, already table-resident as a noun.
        #expect(bundled.nouns.contains("astronaut"))

        let submission = PoolSubmission(
            tableVersion: bundled.tableVersion,
            platform: "other",
            taggerVersion: "hmm-viterbi-3",
            entries: [PoolEntry(token: "astronaut", tag: "VERB")]
        )
        let data = try JSONEncoder().encode(submission)
        try FileManager.default.createDirectory(at: poolDir, withIntermediateDirectories: true)
        try data.write(to: poolDir.appendingPathComponent("pool_seed_precedence.json"))

        let result = try PoolReducer.reduce(
            poolDirectory: poolDir,
            tableArtifactURL: artifactURL,
            now: Date(),
            maxFiles: .max
        )

        // Table-resident tokens are skipped, not re-added (PoolReducer.swift
        // design choice 3): "astronaut" is already a noun, so the conflicting
        // VERB submission must not be merged in either direction.
        #expect(result.nounsAdded == 0)
        #expect(result.verbsAdded == 0)
    }
}
