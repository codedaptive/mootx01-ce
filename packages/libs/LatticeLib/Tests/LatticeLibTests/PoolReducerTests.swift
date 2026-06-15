// PoolReducerTests.swift
//
// Force-tests for PoolReducer — the pool-to-table merger (cookbook §10).
//
// Coverage contract (from mission specification):
//   1. N submissions → reduce → previously-novel token now classified by tagger
//   2. Idempotent re-run (drained pool → no-op, table unchanged)
//   3. Malformed submission quarantined, not crashed
//   4. Dedup across submissions (same token in two files merges once)
//   5. Version-mismatched submission quarantined
//   6. ONLY NOUN/VERB tags expand the table; OTHER does not
//   7. Table-resident tokens are not re-added (skipped)

import Foundation
import Testing
@testable import LatticeLib

// ─── Fixtures ─────────────────────────────────────────────────────────────────

/// A minimal WordClassTable JSON artifact for test use.
private let fixtureTableJSON = """
{
  "table_version": "1.0.0",
  "min_os_version": "17.0",
  "snapshot_date": "2026-01-01",
  "nouns": ["dog", "house"],
  "verbs": ["run", "eat"]
}
""".data(using: .utf8)!

/// A deterministic "now" date for snapshot_date assertions.
private let fixtureNow: Date = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    var comps = DateComponents()
    comps.year = 2026; comps.month = 6; comps.day = 12
    return cal.date(from: comps)!
}()

// ─── Helpers ──────────────────────────────────────────────────────────────────

/// Creates a temporary directory, passes it to the block, removes it after.
private func withTempDir(_ label: String, body: (URL, URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory
    let poolDir = base.appendingPathComponent("pool_reducer_test_\(label)_\(Int(Date().timeIntervalSince1970 * 1_000_000))")
    let tableFile = poolDir.appendingPathComponent("WordClassTable.json")
    try FileManager.default.createDirectory(at: poolDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: poolDir) }
    try fixtureTableJSON.write(to: tableFile, options: .atomic)
    try body(poolDir, tableFile)
}

/// Writes a PoolSubmission JSON file to `dir` with file name `name`.
private func writeSubmission(
    _ submission: PoolSubmission,
    to dir: URL,
    name: String
) throws {
    let data = try JSONEncoder().encode(submission)
    try data.write(to: dir.appendingPathComponent(name))
}

/// Reads the WordClassTable artifact at `url`.
private func readTable(at url: URL) throws -> WordClassTable {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(WordClassTable.self, from: data)
}

/// Counts files in a subdirectory; returns 0 if the subdir doesn't exist.
private func countFiles(in dir: URL, subdir: String) throws -> Int {
    let sub = dir.appendingPathComponent(subdir)
    guard FileManager.default.fileExists(atPath: sub.path) else { return 0 }
    return try FileManager.default.contentsOfDirectory(
        at: sub, includingPropertiesForKeys: nil
    ).count
}

// ─── Test suite ───────────────────────────────────────────────────────────────

@Suite("PoolReducer (cookbook §10)")
struct PoolReducerTests {

    // MARK: - 1. Novel token learning loop (force-test)

    @Test("force: N submissions → reduce → previously-novel token now classified")
    func novelTokenLearningLoop() throws {
        // This is the force-test proving the novel-token learning loop closes.
        // Before reduction, "quasar" is a novel token (not in fixture table).
        // After reduction, it should be in the noun set.

        try withTempDir("learning") { poolDir, tableFile in
            // Confirm "quasar" is NOT in the table pre-reduction.
            let preMerge = try readTable(at: tableFile)
            #expect(!preMerge.nouns.contains("quasar"), "precondition: quasar absent from noun set")

            // Land 1 submission containing "quasar" as NOUN.
            let submission = PoolSubmission(
                tableVersion: "1.0.0",
                platform: "apple",
                taggerVersion: "15.0.0",
                entries: [
                    PoolEntry(token: "quasar", tag: "NOUN"),
                    PoolEntry(token: "nebula", tag: "NOUN"),
                    PoolEntry(token: "orbit", tag: "VERB"),
                ]
            )
            try writeSubmission(submission, to: poolDir, name: "pool_2026-06-12_001.json")

            // Reduce.
            let result = try PoolReducer.reduce(
                poolDirectory: poolDir,
                tableArtifactURL: tableFile,
                now: fixtureNow
            )

            // Check result counts.
            #expect(result.consumed == 1, "1 file consumed")
            #expect(result.quarantined == 0, "0 quarantined")
            #expect(result.nounsAdded == 2, "2 nouns added: quasar, nebula")
            #expect(result.verbsAdded == 1, "1 verb added: orbit")

            // Read the updated table and verify the novel tokens are now classified.
            let postMerge = try readTable(at: tableFile)
            #expect(postMerge.nouns.contains("quasar"), "quasar must now be in noun set")
            #expect(postMerge.nouns.contains("nebula"), "nebula must now be in noun set")
            #expect(postMerge.verbs.contains("orbit"), "orbit must now be in verb set")

            // Pre-existing tokens are preserved.
            #expect(postMerge.nouns.contains("dog"), "existing noun dog preserved")
            #expect(postMerge.verbs.contains("run"), "existing verb run preserved")
        }
    }

    // MARK: - 2. Idempotent re-run (drained pool is a no-op)

    @Test("idempotent: re-run on drained pool is no-op")
    func idempotentRerun() throws {
        try withTempDir("idempotent") { poolDir, tableFile in
            // Run reduce on an empty pool directory.
            let result = try PoolReducer.reduce(
                poolDirectory: poolDir,
                tableArtifactURL: tableFile,
                now: fixtureNow
            )

            #expect(result.isNoop, "empty pool must be a no-op")
            #expect(result.consumed == 0)
            #expect(result.quarantined == 0)
            #expect(result.nounsAdded == 0)

            // Table is unchanged.
            let table = try readTable(at: tableFile)
            #expect(table.snapshotDate == "2026-01-01", "snapshot_date must not change on no-op")

            // Land one submission and reduce.
            let submission = PoolSubmission(
                tableVersion: "1.0.0",
                platform: "apple",
                taggerVersion: "15.0.0",
                entries: [PoolEntry(token: "pulsar", tag: "NOUN")]
            )
            try writeSubmission(submission, to: poolDir, name: "pool_2026-06-12_002.json")
            let result2 = try PoolReducer.reduce(
                poolDirectory: poolDir,
                tableArtifactURL: tableFile,
                now: fixtureNow
            )
            #expect(result2.consumed == 1)
            #expect(result2.nounsAdded == 1)

            // Re-run with same pool dir (now drained) — must be a no-op again.
            let result3 = try PoolReducer.reduce(
                poolDirectory: poolDir,
                tableArtifactURL: tableFile,
                now: fixtureNow
            )
            #expect(result3.isNoop, "second run on drained pool must be no-op")
            #expect(result3.nounsAdded == 0, "no tokens added on re-run")
        }
    }

    // MARK: - 3. Malformed submission quarantined, not crashed

    @Test("malformed submission is quarantined and run continues")
    func malformedSubmissionQuarantined() throws {
        try withTempDir("quarantine") { poolDir, tableFile in
            // Write a malformed file (not valid JSON).
            let badFile = poolDir.appendingPathComponent("pool_bad.json")
            try "not json at all {{{{".data(using: .utf8)!.write(to: badFile)

            // Write one valid file alongside it.
            let good = PoolSubmission(
                tableVersion: "1.0.0",
                platform: "apple",
                taggerVersion: "15.0.0",
                entries: [PoolEntry(token: "photon", tag: "NOUN")]
            )
            try writeSubmission(good, to: poolDir, name: "pool_good.json")

            let result = try PoolReducer.reduce(
                poolDirectory: poolDir,
                tableArtifactURL: tableFile,
                now: fixtureNow
            )

            // Bad file quarantined, good file consumed.
            #expect(result.consumed == 1, "valid file must be consumed")
            #expect(result.quarantined == 1, "malformed file must be quarantined")
            #expect(result.nounsAdded == 1, "photon must be added as noun")

            // Quarantine directory must contain the bad file.
            let quarantineCount = try countFiles(in: poolDir, subdir: "quarantine")
            #expect(quarantineCount == 1, "quarantine dir must contain 1 file")

            // Archive must contain the good file.
            let archiveCount = try countFiles(in: poolDir, subdir: "archive")
            #expect(archiveCount == 1, "archive dir must contain 1 file")

            // Pool root must be empty of pool_ files.
            let poolFiles = try FileManager.default.contentsOfDirectory(
                at: poolDir, includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("pool_") && $0.pathExtension == "json" }
            #expect(poolFiles.isEmpty, "pool root must be drained after reduce")
        }
    }

    // MARK: - 4. Dedup across submissions

    @Test("dedup: same token in multiple files merges exactly once")
    func dedupAcrossSubmissions() throws {
        try withTempDir("dedup") { poolDir, tableFile in
            // Two submissions both containing "comet" — should be added once.
            let s1 = PoolSubmission(
                tableVersion: "1.0.0",
                platform: "apple",
                taggerVersion: "15.0.0",
                entries: [PoolEntry(token: "comet", tag: "NOUN")]
            )
            let s2 = PoolSubmission(
                tableVersion: "1.0.0",
                platform: "apple",
                taggerVersion: "15.0.0",
                entries: [PoolEntry(token: "comet", tag: "NOUN")]
            )
            // Use alphabetically ordered names so s1 sorts before s2.
            try writeSubmission(s1, to: poolDir, name: "pool_a.json")
            try writeSubmission(s2, to: poolDir, name: "pool_b.json")

            let result = try PoolReducer.reduce(
                poolDirectory: poolDir,
                tableArtifactURL: tableFile,
                now: fixtureNow
            )

            #expect(result.consumed == 2, "both files consumed")
            // "comet" appears in both files but must be added only once.
            #expect(result.nounsAdded == 1, "comet added exactly once")
            #expect(result.skipped >= 1, "second occurrence of comet skipped")

            let table = try readTable(at: tableFile)
            let cometCount = table.nouns.filter { $0 == "comet" }.count
            #expect(cometCount == 1, "comet appears exactly once in noun set")
        }
    }

    // MARK: - 5. Version mismatch quarantined

    @Test("version mismatch: stale-table submission is quarantined")
    func versionMismatchQuarantined() throws {
        try withTempDir("version") { poolDir, tableFile in
            // Submission with wrong table_version.
            let stale = PoolSubmission(
                tableVersion: "0.9.0",  // does not match fixture table "1.0.0"
                platform: "apple",
                taggerVersion: "15.0.0",
                entries: [PoolEntry(token: "asteroid", tag: "NOUN")]
            )
            try writeSubmission(stale, to: poolDir, name: "pool_stale.json")

            let result = try PoolReducer.reduce(
                poolDirectory: poolDir,
                tableArtifactURL: tableFile,
                now: fixtureNow
            )

            #expect(result.consumed == 0, "stale submission must not be consumed")
            #expect(result.quarantined == 1, "stale submission must be quarantined")
            #expect(result.nounsAdded == 0, "no tokens from stale submission")

            // Table must be unchanged.
            let table = try readTable(at: tableFile)
            #expect(!table.nouns.contains("asteroid"), "asteroid must not be in table")
        }
    }

    // MARK: - 6. OTHER tag does not expand the table

    @Test("OTHER tag does not add tokens to noun or verb set")
    func otherTagSkipped() throws {
        try withTempDir("other_tag") { poolDir, tableFile in
            let submission = PoolSubmission(
                tableVersion: "1.0.0",
                platform: "other",
                taggerVersion: "hmm-viterbi-1",
                entries: [
                    PoolEntry(token: "the", tag: "OTHER"),
                    PoolEntry(token: "quickly", tag: "OTHER"),
                    PoolEntry(token: "galaxy", tag: "NOUN"),  // only this one merges
                ]
            )
            try writeSubmission(submission, to: poolDir, name: "pool_other.json")

            let result = try PoolReducer.reduce(
                poolDirectory: poolDir,
                tableArtifactURL: tableFile,
                now: fixtureNow
            )

            #expect(result.nounsAdded == 1, "only NOUN tag merges")
            #expect(result.verbsAdded == 0)
            // "the" and "quickly" are OTHER: they increment skipped.
            #expect(result.skipped >= 2)

            let table = try readTable(at: tableFile)
            #expect(table.nouns.contains("galaxy"))
            #expect(!table.nouns.contains("the"))
            #expect(!table.nouns.contains("quickly"))
        }
    }

    // MARK: - 7. Table-resident tokens skipped

    @Test("table-resident tokens are skipped without duplication")
    func tableResidentTokensSkipped() throws {
        try withTempDir("resident") { poolDir, tableFile in
            // "dog" and "run" are already in the fixture table.
            let submission = PoolSubmission(
                tableVersion: "1.0.0",
                platform: "apple",
                taggerVersion: "15.0.0",
                entries: [
                    PoolEntry(token: "dog", tag: "NOUN"),   // already noun
                    PoolEntry(token: "run", tag: "VERB"),   // already verb
                    PoolEntry(token: "meteor", tag: "NOUN"), // novel
                ]
            )
            try writeSubmission(submission, to: poolDir, name: "pool_resident.json")

            let result = try PoolReducer.reduce(
                poolDirectory: poolDir,
                tableArtifactURL: tableFile,
                now: fixtureNow
            )

            #expect(result.nounsAdded == 1, "only meteor added; dog already resident")
            #expect(result.verbsAdded == 0, "run already resident")
            #expect(result.skipped >= 2, "dog and run counted as skipped")

            // Verify "dog" still appears exactly once.
            let table = try readTable(at: tableFile)
            let dogCount = table.nouns.filter { $0 == "dog" }.count
            #expect(dogCount == 1, "dog appears exactly once")
        }
    }

    // MARK: - 8. snapshot_date updated on merge

    @Test("snapshot_date is updated to 'now' after merge")
    func snapshotDateUpdated() throws {
        try withTempDir("date") { poolDir, tableFile in
            let submission = PoolSubmission(
                tableVersion: "1.0.0",
                platform: "apple",
                taggerVersion: "15.0.0",
                entries: [PoolEntry(token: "supernova", tag: "NOUN")]
            )
            try writeSubmission(submission, to: poolDir, name: "pool_date.json")

            _ = try PoolReducer.reduce(
                poolDirectory: poolDir,
                tableArtifactURL: tableFile,
                now: fixtureNow
            )

            let table = try readTable(at: tableFile)
            #expect(table.snapshotDate == "2026-06-12", "snapshot_date must match injected now")
        }
    }

    // MARK: - 10. Same token tagged NOUN and VERB across two files (conflict)

    @Test("conflict: same token NOUN in earlier file, VERB in later file → earlier file's NOUN tag wins, single entry")
    func sameTokenNounAndVerbAcrossFiles() throws {
        // Run-global first-occurrence-wins, with files processed in
        // filename-chronological order. "spark" is tagged NOUN in the
        // earlier-named file (pool_a) and VERB in the later-named file
        // (pool_b). Because pool_a sorts before pool_b, the NOUN occurrence
        // is seen first and wins; the later VERB occurrence is a duplicate
        // token and is skipped. The token must NOT be double-counted (it is
        // added exactly once) and must NOT be double-tagged (it lands only
        // in the noun set, never the verb set).
        try withTempDir("noun_verb_conflict") { poolDir, tableFile in
            let fileA = PoolSubmission(
                tableVersion: "1.0.0",
                platform: "apple",
                taggerVersion: "15.0.0",
                entries: [PoolEntry(token: "spark", tag: "NOUN")]
            )
            let fileB = PoolSubmission(
                tableVersion: "1.0.0",
                platform: "apple",
                taggerVersion: "15.0.0",
                entries: [PoolEntry(token: "spark", tag: "VERB")]
            )
            // pool_a < pool_b lexicographically, so pool_a is processed first.
            try writeSubmission(fileA, to: poolDir, name: "pool_a.json")
            try writeSubmission(fileB, to: poolDir, name: "pool_b.json")

            let result = try PoolReducer.reduce(
                poolDirectory: poolDir,
                tableArtifactURL: tableFile,
                now: fixtureNow
            )

            // Both files consumed; "spark" added exactly once as a NOUN.
            #expect(result.consumed == 2, "both files consumed")
            #expect(result.nounsAdded == 1, "spark added exactly once, as a noun (earlier file wins)")
            #expect(result.verbsAdded == 0, "later-file VERB occurrence does not expand the verb set")
            #expect(result.skipped == 1, "later-file VERB occurrence of spark is a skipped duplicate")

            // Winning tag is pinned: spark is in the noun set, NOT the verb set.
            let table = try readTable(at: tableFile)
            #expect(table.nouns.contains("spark"), "spark must be in the noun set (NOUN tag from pool_a wins)")
            #expect(!table.verbs.contains("spark"), "spark must NOT be in the verb set (VERB tag from pool_b loses)")

            // Not double-counted: exactly one occurrence in the noun set.
            let sparkNounCount = table.nouns.filter { $0 == "spark" }.count
            #expect(sparkNounCount == 1, "spark appears exactly once in the noun set")
        }
    }

    // MARK: - 11. Same token twice within one file (intra-file conflict)

    @Test("conflict: same token twice in one file (NOUN then VERB) → first occurrence wins, single entry, no duplicate")
    func sameTokenTwiceInOneFile() throws {
        // First-occurrence-wins applies within a single file's entry order.
        // "quasar" appears twice in one submission: first as NOUN, then as
        // VERB. The first (NOUN) occurrence wins; the second (VERB) is a
        // duplicate token and is skipped. Exactly one table entry results,
        // in the noun set, with no duplicate.
        try withTempDir("intra_file_conflict") { poolDir, tableFile in
            let submission = PoolSubmission(
                tableVersion: "1.0.0",
                platform: "apple",
                taggerVersion: "15.0.0",
                entries: [
                    PoolEntry(token: "quasar", tag: "NOUN"),  // first occurrence wins
                    PoolEntry(token: "quasar", tag: "VERB"),  // duplicate token, skipped
                ]
            )
            try writeSubmission(submission, to: poolDir, name: "pool_intra.json")

            let result = try PoolReducer.reduce(
                poolDirectory: poolDir,
                tableArtifactURL: tableFile,
                now: fixtureNow
            )

            #expect(result.consumed == 1, "single file consumed")
            #expect(result.nounsAdded == 1, "quasar added exactly once, as a noun (first occurrence wins)")
            #expect(result.verbsAdded == 0, "second (VERB) occurrence does not expand the verb set")
            #expect(result.skipped == 1, "second occurrence of quasar within the file is a skipped duplicate")

            let table = try readTable(at: tableFile)
            #expect(table.nouns.contains("quasar"), "quasar must be in the noun set (first NOUN occurrence wins)")
            #expect(!table.verbs.contains("quasar"), "quasar must NOT be in the verb set")
            let quasarCount = table.nouns.filter { $0 == "quasar" }.count
            #expect(quasarCount == 1, "quasar appears exactly once — no duplicate table entry")
        }
    }

    // MARK: - 12. Older file wins over newer file (filename-chronological-first)

    @Test("conflict: same token in older-named vs newer-named file → older file wins")
    func olderFileWinsOverNewerFile() throws {
        // Same token with DIFFERENT tags in an older-named and a newer-named
        // file, so the winner is observable. Pool file names carry a
        // chronological prefix; the lexicographically smaller name is the older
        // observation and wins. "ripple" is NOUN in the older file (2026-06-10)
        // and VERB in the newer file (2026-06-11); the older NOUN wins.
        try withTempDir("older_vs_newer") { poolDir, tableFile in
            let older = PoolSubmission(
                tableVersion: "1.0.0",
                platform: "apple",
                taggerVersion: "15.0.0",
                entries: [PoolEntry(token: "ripple", tag: "NOUN")]
            )
            let newer = PoolSubmission(
                tableVersion: "1.0.0",
                platform: "apple",
                taggerVersion: "15.0.0",
                entries: [PoolEntry(token: "ripple", tag: "VERB")]
            )
            try writeSubmission(older, to: poolDir, name: "pool_2026-06-10_001.json")
            try writeSubmission(newer, to: poolDir, name: "pool_2026-06-11_001.json")

            let result = try PoolReducer.reduce(
                poolDirectory: poolDir,
                tableArtifactURL: tableFile,
                now: fixtureNow
            )

            #expect(result.consumed == 2, "both files consumed")
            #expect(result.nounsAdded == 1, "ripple added once, as a noun (older file wins)")
            #expect(result.verbsAdded == 0, "newer-file VERB occurrence loses")
            #expect(result.skipped == 1, "newer occurrence is a skipped duplicate")

            let table = try readTable(at: tableFile)
            #expect(table.nouns.contains("ripple"), "ripple must be in the noun set (older file's NOUN wins)")
            #expect(!table.verbs.contains("ripple"), "ripple must NOT be in the verb set (newer file's VERB loses)")
        }
    }

    // MARK: - 13. Table-resident token cannot be reclassified

    @Test("conflict: bundled-table token submitted with a different tag is not reclassified")
    func tableResidentTokenCannotBeReclassified() throws {
        // "dog" is already a NOUN in the seed table. A submission tags it VERB.
        // The table-resident classification wins: "dog" is NOT reclassified into
        // the verb set and is NOT duplicated.
        try withTempDir("no_reclassify") { poolDir, tableFile in
            let submission = PoolSubmission(
                tableVersion: "1.0.0",
                platform: "apple",
                taggerVersion: "15.0.0",
                entries: [
                    PoolEntry(token: "dog", tag: "VERB"),     // resident noun; must not reclassify
                    PoolEntry(token: "meteor", tag: "NOUN"),  // genuinely novel
                ]
            )
            try writeSubmission(submission, to: poolDir, name: "pool_reclassify.json")

            let result = try PoolReducer.reduce(
                poolDirectory: poolDir,
                tableArtifactURL: tableFile,
                now: fixtureNow
            )

            #expect(result.nounsAdded == 1, "only meteor added")
            #expect(result.verbsAdded == 0, "dog is table-resident; not reclassified into the verb set")
            #expect(result.skipped >= 1, "dog counted as a skipped (resident) entry")

            let table = try readTable(at: tableFile)
            #expect(table.nouns.contains("dog"), "dog remains in the noun set")
            #expect(!table.verbs.contains("dog"), "dog must NOT be reclassified into the verb set")
            let dogCount = table.nouns.filter { $0 == "dog" }.count
            #expect(dogCount == 1, "dog appears exactly once — not duplicated")
        }
    }

    // MARK: - 9. Pool directory absent (edge case, no-op)

    @Test("absent pool directory returns no-op result without throwing")
    func absentPoolDirectoryIsNoop() throws {
        // Use a real temp dir for the table file but a non-existent pool dir.
        let base = FileManager.default.temporaryDirectory
        let poolDir = base.appendingPathComponent("pool_reducer_absent_\(Int(Date().timeIntervalSince1970 * 1_000_000))")
        let tableFile = base.appendingPathComponent("WordClassTable_absent_test.json")
        defer {
            try? FileManager.default.removeItem(at: tableFile)
            // poolDir does not exist, nothing to remove
        }

        try fixtureTableJSON.write(to: tableFile, options: .atomic)

        // poolDir does not exist — should not throw, should return no-op.
        let result = try PoolReducer.reduce(
            poolDirectory: poolDir,
            tableArtifactURL: tableFile,
            now: fixtureNow
        )
        #expect(result.isNoop, "absent pool dir must be a no-op")
    }
}
