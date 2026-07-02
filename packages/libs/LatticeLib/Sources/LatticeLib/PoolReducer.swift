// PoolReducer.swift
//
// The pool reducer: consumes PoolSubmission JSON files from the pool directory
// and merges qualifying novel tokens into the WordClassTable artifact
// (cookbook §10 "Pool reducer").
//
// DESIGN CHOICES (cookbook §2.3 and §1.3 specify the producer and table schema;
// the reducer merge semantics are not explicitly specified, so the following
// minimal-faithful design is derived from those sections and documented here):
//
//   1. Version gate: A submission whose `table_version` does not match the
//      current table's `table_version` is quarantined (not crashed). Cookbook
//      §2.3: "The server validates table_version against the current shipping
//      table. Submissions against a stale table version are discarded."
//      Quarantine (not silently delete) preserves forensic value.
//
//   2. Dedup within the reducer run: Among all qualifying entries across all
//      valid submissions, first-occurrence wins for each lowercased token. A
//      token that appears multiple times with conflicting tags resolves to the
//      tag on its first occurrence (first-submission-file order, then entry
//      order within the file).
//
//   3. Table-resident tokens are skipped: a token already in the noun or verb
//      set is not re-added (it is already classified; adding it again is a
//      no-op but skipping is explicit and cheaper).
//
//   4. Only NOUN and VERB tags are merged into the table. OTHER tags are
//      valid pool entries (they were tagged and recorded correctly) but they do
//      not expand the noun or verb set — they are already represented by the
//      absent-from-table condition.
//
//   5. Frequency threshold is 1: any single qualified observation merges. The
//      static table was produced from a large corpus with high-confidence
//      NLTagger calls; pool entries come from individual device observations
//      which are individually weaker. However, dedup across submissions ensures
//      each token appears at most once even if it was observed many times across
//      multiple drain cycles. Future quality improvement could raise the
//      threshold, but 1 is the correct minimal-faithful floor.
//
//   6. Merge target: the table artifact JSON file (the same file that
//      WordClassTable.loadBundled reads, or a writable copy for offline use).
//      The reducer writes a new JSON artifact in the same schema so
//      WordClassTable.loadBundled can parse it. The snapshot_date is advanced
//      to `now`; min_os_version is preserved from the existing table.
//
//   7. Archive / drain: consumed (valid, processed) submission files are
//      moved to `poolDirectory/archive/` so re-running the reducer is
//      idempotent. Quarantined files are moved to `poolDirectory/quarantine/`.
//      A re-run on a drained pool is a no-op (zero files → zero mutations).
//
// Public entry point (for the autonomic governor or an operator command):
//
//   PoolReducer.reduce(poolDirectory:tableArtifactURL:now:maxFiles:) throws -> PoolReduceResult
//
// Current trigger host: `NeuronKit.AutonomicGovernor` invokes this after
// a configurable idle window, passing the novel-pool directory and table-
// artifact URL. An operator CLI in ARIA_MCP or ARIA_MacOS can also call
// it on demand. Do NOT wire this directly into the hot wordClass path —
// reduction is a batch operation, not a per-token side effect.

import Foundation
import OSLog

private let log = Logger(subsystem: "com.mootx01.kit", category: "LatticeLib")

// ─── Result type ──────────────────────────────────────────────────────────────

/// Summary of a pool reduction run.
public struct PoolReduceResult: Equatable, Sendable {

    /// Number of submission files successfully consumed and archived.
    public let consumed: Int

    /// Number of submission files quarantined (malformed JSON or version
    /// mismatch).
    public let quarantined: Int

    /// Number of novel tokens newly merged into the noun set.
    public let nounsAdded: Int

    /// Number of novel tokens newly merged into the verb set.
    public let verbsAdded: Int

    /// Number of entries skipped because the token was already table-resident,
    /// had an OTHER tag, or was a duplicate within this run.
    public let skipped: Int

    public init(
        consumed: Int,
        quarantined: Int,
        nounsAdded: Int,
        verbsAdded: Int,
        skipped: Int
    ) {
        self.consumed = consumed
        self.quarantined = quarantined
        self.nounsAdded = nounsAdded
        self.verbsAdded = verbsAdded
        self.skipped = skipped
    }

    /// True when the pool was empty and no state changed.
    public var isNoop: Bool {
        consumed == 0 && quarantined == 0
    }
}

// ─── PoolReducerError ─────────────────────────────────────────────────────────

/// Errors raised by `PoolReducer.reduce`.
public enum PoolReducerError: Error, Equatable, Sendable {

    /// The table artifact file could not be read or decoded.
    case tableReadFailed(String)

    /// The updated table artifact could not be written.
    case tableWriteFailed(String)

    /// The pool directory could not be read.
    case poolDirectoryUnreadable(String)
}

// ─── PoolReducer ──────────────────────────────────────────────────────────────

/// Merges pooled novel-token observations into the WordClassTable artifact.
///
/// `reduce(poolDirectory:tableArtifactURL:now:maxFiles:)` is the public entry point.
/// It is idempotent: re-running after the pool is drained is a documented
/// no-op.
///
/// **Trigger host recommendation:** the autonomic governor (GeniusLocusKit's
/// scheduling layer) or an operator CLI in ARIA_MCP / ARIA_MacOS. Do not invoke
/// from the hot wordClass classification path.
public enum PoolReducer {

    // MARK: - Public entry point

    /// Reduces the pool: reads all `pool_*.json` files from `poolDirectory`,
    /// validates each against `tableArtifactURL`, merges qualifying novel
    /// tokens, writes the updated artifact, and archives/quarantines each
    /// submission file.
    ///
    /// - Parameters:
    ///   - poolDirectory: the directory containing `pool_*.json` submission
    ///     files (the same directory configured via `LATTICE_POOL_DIR` or the
    ///     platform default in `NovelPoolSubmitter`).
    ///   - tableArtifactURL: the `WordClassTable.json` artifact to update. Must
    ///     be readable and writable. For the bundled read-only resource, callers
    ///     should copy it to a writable location first. The file is overwritten
    ///     in place.
    ///   - now: the current date, injected for determinism. Used as the new
    ///     `snapshot_date` in the updated artifact.
    ///   - maxFiles: caps how many submission files this run drains — the OLDEST
    ///     `maxFiles` by filename (chronological). A backlog larger than the cap
    ///     drains over successive runs (bounded near-realtime drain: the governor
    ///     calls this synchronously on its tick, so an unbounded pass would stall
    ///     the tick). Pass `Int.max` to drain the whole pool in one pass
    ///     (operator/CLI/test use).
    /// - Returns: a `PoolReduceResult` summarising the run.
    /// - Throws: `PoolReducerError` if the artifact cannot be read or written,
    ///   or if the pool directory is unreadable.
    public static func reduce(
        poolDirectory: URL,
        tableArtifactURL: URL,
        now: Date,
        maxFiles: Int
    ) throws -> PoolReduceResult {

        // Step 1: Ensure the writable artifact exists. When the reducer is
        // called for the first time, no artifact has been written yet — the
        // PoolReducer cannot write INTO the read-only app bundle. Seed the
        // writable location by copying the bundled pristine table so that
        // loadTable has a real target and the loop does not log tableReadFailed.
        //
        // The seed is idempotent: if the file already exists from a previous
        // run (with merged novel tokens), it is left untouched. The reducer
        // then merges on top of whatever is already there.
        try seedWritableArtifactIfAbsent(at: tableArtifactURL)

        // Step 2: Load the existing table artifact (seeded or previously merged).
        let existingTable = try loadTable(at: tableArtifactURL)

        // Build mutable working sets from the existing table. Lowercase for
        // O(1) membership and consistency with the encoding fast path.
        var nounSet = Set(existingTable.nouns.map { $0.lowercased() })
        var verbSet = Set(existingTable.verbs.map { $0.lowercased() })

        // Step 3: Enumerate pool files.
        let poolFiles: [URL]
        do {
            poolFiles = try enumeratePoolFiles(in: poolDirectory)
        } catch {
            throw PoolReducerError.poolDirectoryUnreadable(error.localizedDescription)
        }

        // If there are no pool files, this is a no-op: return immediately
        // without touching the artifact (idempotent contract).
        guard !poolFiles.isEmpty else {
            return PoolReduceResult(
                consumed: 0, quarantined: 0, nounsAdded: 0, verbsAdded: 0, skipped: 0
            )
        }

        // Ensure archive and quarantine subdirectories exist.
        let archiveDir = poolDirectory.appendingPathComponent("archive", isDirectory: true)
        let quarantineDir = poolDirectory.appendingPathComponent("quarantine", isDirectory: true)
        try FileManager.default.createDirectory(
            at: archiveDir, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: quarantineDir, withIntermediateDirectories: true
        )

        // Step 4: Process each pool file.
        // Dedup across the entire run: first-occurrence wins per lowercased token.
        var seenTokens = Set<String>()
        var nounsAdded = 0
        var verbsAdded = 0
        var skipped = 0
        var consumed = 0
        var quarantined = 0

        // Sort pool files by name (which is chronologically ordered by the
        // submitter's ISO8601 timestamp prefix) to make first-occurrence
        // deterministic — the oldest observation wins in a tie.
        let sortedFiles = poolFiles.sorted { $0.lastPathComponent < $1.lastPathComponent }

        // Bounded drain: process at most `maxFiles` of the OLDEST submissions
        // this run. A larger backlog drains over successive runs, so a burst that
        // pushed the pool past the cap can never wedge the drainer (the prior
        // "defer when over cap" behaviour deadlocked — over cap, the reduce that
        // would shrink the pool was skipped, so it grew without bound). Files
        // beyond the cap stay on disk, untouched, for the next run.
        let batch = sortedFiles.prefix(maxFiles)

        for fileURL in batch {
            // Decode the submission.
            let submission: PoolSubmission
            do {
                let data = try Data(contentsOf: fileURL)
                submission = try JSONDecoder().decode(PoolSubmission.self, from: data)
            } catch {
                // Malformed JSON or unexpected schema: quarantine, not crash.
                log.error(
                    "pool reducer: malformed submission \(fileURL.lastPathComponent, privacy: .public) — quarantined: \(error.localizedDescription, privacy: .public)"
                )
                moveFile(fileURL, to: quarantineDir)
                quarantined += 1
                continue
            }

            // Version gate: discard submissions for a different table version.
            // Cookbook §2.3: "The server discards submissions whose table_version
            // does not match the current shipping table."
            guard submission.tableVersion == existingTable.tableVersion else {
                log.info(
                    "pool reducer: version mismatch in \(fileURL.lastPathComponent, privacy: .public) (submission: \(submission.tableVersion, privacy: .public), table: \(existingTable.tableVersion, privacy: .public)) — quarantined"
                )
                moveFile(fileURL, to: quarantineDir)
                quarantined += 1
                continue
            }

            // Merge qualifying entries.
            for entry in submission.entries {
                let token = entry.token.lowercased()

                // Skip duplicates within this reducer run (first-occurrence wins).
                guard !seenTokens.contains(token) else {
                    skipped += 1
                    continue
                }
                seenTokens.insert(token)

                // Skip tokens already in the table.
                if verbSet.contains(token) || nounSet.contains(token) {
                    skipped += 1
                    continue
                }

                // Only NOUN and VERB tags expand the table (see design note 4).
                switch entry.tag {
                case "NOUN":
                    nounSet.insert(token)
                    nounsAdded += 1
                case "VERB":
                    verbSet.insert(token)
                    verbsAdded += 1
                default:
                    // OTHER (or any unknown tag): does not expand the table.
                    skipped += 1
                }
            }

            // Archive the consumed file.
            moveFile(fileURL, to: archiveDir)
            consumed += 1
        }

        // Step 5: Write the updated artifact if any tokens were added.
        // Always write when there were consumed files so the snapshot_date
        // advances and the file reflects the final merged state.
        if consumed > 0 {
            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
            let snapshotDate = dateFormatter.string(from: now)

            let updatedTable = WordClassTable(
                tableVersion: existingTable.tableVersion,
                minOSVersion: existingTable.minOSVersion,
                snapshotDate: snapshotDate,
                nouns: nounSet.sorted(),
                verbs: verbSet.sorted()
            )

            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(updatedTable)
                try data.write(to: tableArtifactURL, options: .atomic)
                log.info(
                    "pool reducer: merged \(nounsAdded) nouns + \(verbsAdded) verbs; consumed \(consumed) files; quarantined \(quarantined)"
                )
            } catch {
                throw PoolReducerError.tableWriteFailed(error.localizedDescription)
            }
        }

        return PoolReduceResult(
            consumed: consumed,
            quarantined: quarantined,
            nounsAdded: nounsAdded,
            verbsAdded: verbsAdded,
            skipped: skipped
        )
    }

    // MARK: - Internal helpers

    /// Seeds the writable artifact at `url` by copying the bundled pristine
    /// table if the file does not yet exist. Idempotent: a pre-existing file
    /// (from a prior reduce run, possibly with merged novel tokens) is left
    /// untouched so accumulated learning is preserved.
    ///
    /// The bundled read-only resource lives in the app bundle and cannot be
    /// written to. The reducer must work on a writable copy. This method
    /// creates that copy the first time the reducer runs, eliminating the
    /// `tableReadFailed` error that would otherwise occur when no prior
    /// reduce run has taken place.
    ///
    /// Parent directories are created with `withIntermediateDirectories: true`
    /// so the full `…/lattice/` path is created on the first run.
    ///
    /// Throws `PoolReducerError.tableReadFailed` if the bundled resource is
    /// missing (build-time invariant violation) or `tableWriteFailed` if the
    /// seed write fails (e.g., disk full or permissions error).
    private static func seedWritableArtifactIfAbsent(at url: URL) throws {
        // If the writable artifact already exists, nothing to do.
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        // The parent directory (…/lattice/) may not exist yet.
        let parentDir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parentDir,
                withIntermediateDirectories: true
            )
        } catch {
            throw PoolReducerError.tableWriteFailed(
                "cannot create lattice directory at \(parentDir.path): \(error.localizedDescription)"
            )
        }

        // Load the bundled pristine table bytes.
        guard let bundledURL = Bundle.module.url(
            forResource: "WordClassTable",
            withExtension: "json"
        ) else {
            throw PoolReducerError.tableReadFailed(
                "bundled WordClassTable.json resource not found — build error"
            )
        }
        let bundledData: Data
        do {
            bundledData = try Data(contentsOf: bundledURL)
        } catch {
            throw PoolReducerError.tableReadFailed(
                "cannot read bundled WordClassTable.json: \(error.localizedDescription)"
            )
        }

        // Write the pristine copy to the writable path.
        do {
            try bundledData.write(to: url, options: .atomic)
            log.info(
                "pool reducer: seeded writable artifact at \(url.path, privacy: .public) from bundled table"
            )
        } catch {
            throw PoolReducerError.tableWriteFailed(
                "cannot seed writable artifact at \(url.path): \(error.localizedDescription)"
            )
        }
    }

    /// Loads and decodes the WordClassTable artifact from `url`.
    private static func loadTable(at url: URL) throws -> WordClassTable {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PoolReducerError.tableReadFailed(error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(WordClassTable.self, from: data)
        } catch {
            throw PoolReducerError.tableReadFailed("JSON decode error: \(error.localizedDescription)")
        }
    }

    /// Returns all `pool_*.json` files in `directory` (non-recursive).
    /// Returns an empty array if the directory does not exist (the pool has
    /// never been written to, so this is a valid no-op case).
    private static func enumeratePoolFiles(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsSubdirectoryDescendants
        )
        return contents.filter {
            $0.lastPathComponent.hasPrefix("pool_") && $0.pathExtension == "json"
        }
    }

    /// Moves `file` into `targetDir`. On failure, logs at error level and
    /// leaves the file in place (never crashes; the pool remains safe).
    private static func moveFile(_ file: URL, to targetDir: URL) {
        let dest = targetDir.appendingPathComponent(file.lastPathComponent)
        do {
            // If a file with the same name exists in the target (e.g. from a
            // previous partial run), remove it first so the move succeeds.
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: file, to: dest)
        } catch {
            log.error(
                "pool reducer: could not move \(file.lastPathComponent, privacy: .public) to \(targetDir.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
