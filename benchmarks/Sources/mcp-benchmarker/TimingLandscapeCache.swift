// TimingLandscapeCache.swift — the landscape as a prebuilt artifact.
//
// WHY THIS EXISTS
// The timing benchmark measures single-row writes against a database that
// already holds S rows. Those S rows are unmeasured background: they may be
// bulk-loaded on a machine under load, and only the measured window requires an
// idle machine.
//
// Before this file the lane ingested them inside the run, which put a
// 100,000-row ingest inside the window that has to be quiet, and made every
// repeat of the measurement pay for a landscape that is identical each time.
//
// The landscape is now built once, ahead of time, and restored per checkpoint.
// That matches the artifact model the accuracy lanes already use: build on a
// busy machine, measure from a restored copy on a quiet one. It also gives the
// per-measurement fresh copy the definition calls for — each checkpoint starts
// from the stored landscape at exactly S rows rather than from the previous
// checkpoint's database carrying the previous checkpoint's measured writes.
//
// A cache entry is keyed by its RECIPE, not just its size. A landscape built
// from LongMemEval and one templated from a seed are different landscapes at
// the same row count, and measuring one while the report names the other would
// be a false provenance claim. The key is a pure function so both ports agree
// on which entry answers which recipe.

import Foundation

// MARK: - Cache key

/// Directory name for one stored landscape.
///
/// Every field that changes the rows is in the name: a corpus landscape and a
/// synthetic one never collide, nor do two variants, two seeds, or two sizes.
/// Reading a landscape built under a different recipe would silently measure
/// different content than the report describes.
///
/// The seed appears for both sources even though a corpus landscape's ROWS do
/// not depend on it, because the seed still selects the measured writes made on
/// top of the landscape.
///
/// Twin of Rust `timing_landscape_cache_key`.
func timingLandscapeCacheKey(
    source: TimingLandscapeSource,
    corpus: TimingLandscapeCorpus,
    variant: String,
    seed: UInt64,
    size: Int
) -> String {
    switch source {
    case .synthetic:
        return "synthetic-seed\(seed)-rows\(size)"
    case .corpus:
        return "\(corpus.rawValue)-\(variant)-seed\(seed)-rows\(size)"
    }
}

/// Location of one stored landscape inside the cache directory.
func timingLandscapeCacheEntryURL(
    cacheDir: URL,
    source: TimingLandscapeSource,
    corpus: TimingLandscapeCorpus,
    variant: String,
    seed: UInt64,
    size: Int
) -> URL {
    cacheDir.appendingPathComponent(timingLandscapeCacheKey(
        source: source, corpus: corpus, variant: variant, seed: seed, size: size))
}

/// The estate directory inside a stored landscape entry.
func timingLandscapeEstateURL(inEntry entry: URL) -> URL {
    entry.appendingPathComponent("estate")
}

/// The recipe file inside a stored landscape entry.
func timingLandscapeRecipeURL(inEntry entry: URL) -> URL {
    entry.appendingPathComponent("recipe.json")
}

// MARK: - Build

/// `mcp-benchmarker landscape-build`
///
/// Builds the landscape at every requested size and stores each one, so a later
/// timing run restores instead of ingesting. Intended to run on a busy machine:
/// nothing here is measured, and the output is bytes on disk rather than
/// figures.
///
/// Sizes are built MONOTONICALLY in one pass — the 10,000-row landscape is the
/// 2,000-row landscape plus 8,000 more rows, which is what makes a scaling
/// curve one curve rather than three unrelated samples. Each size is snapshotted
/// as it is reached, so one ingest produces every entry.
///
/// Options:
///   --cache-dir <dir>            where to store the landscapes (required)
///   --sizes 2000,10000,100000    ascending checkpoints (default)
///   --seed S                     seed (default 20260813)
///   --landscape synthetic|corpus source of the background rows
///   --landscape-corpus <name>    corpus name when --landscape corpus
///   --landscape-variant <v>      corpus variant when --landscape corpus
///   --landscape-data-dir <dir>   fetched data set when --landscape corpus
///   --mootx01-binary <path>      binary to build with (auto-discovered)
///   --estate-mode <mode>         at-rest posture of the stored landscape
func runLandscapeBuild(_ args: [String]) async throws {
    guard let cacheDirRaw = optionValue("--cache-dir", in: args) else {
        throw MCPError(description: "landscape-build requires --cache-dir")
    }
    let cacheDir = URL(fileURLWithPath: cacheDirRaw)
    try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

    guard let mootBinary = optionValue("--mootx01-binary", in: args)
                        ?? optionValue("--binary", in: args)
                        ?? discoverMootBinary() else {
        throw MCPError(description:
            "landscape-build: could not find mootx01 binary; pass --binary <path> "
            + "or set $MOOTX01_BINARY")
    }
    let posture = try parseEstateMode(in: args)
    let seed = UInt64(optionValue("--seed", in: args) ?? "") ?? 20_260_813
    let sizes = try validatedAscendingSizes(
        "--sizes", in: args, default: [2_000, 10_000, 100_000])

    let (source, corpus, variant, corpusRows) = try resolveLandscapeSource(args)

    // A corpus landscape cycles its rows when the requested size exceeds the
    // corpus, and each reuse is a distinct row with a distinct id. Say so up
    // front rather than letting a reader infer 100,000 unique source turns.
    if let rows = corpusRows, let largest = sizes.last, largest > rows.count {
        FileHandle.standardOutput.write(Data(
            ("[landscape] corpus holds \(rows.count) rows; sizes above that cycle, "
            + "each reuse a distinct row\n").utf8))
    }

    // Resume from the largest landscape already stored under this recipe.
    // Sizes are built monotonically, so a stored 10,000 is a valid starting
    // point for 100,000 — restoring it saves re-ingesting rows that are
    // already on disk, which on a 100,000-row landscape is most of the work.
    // A stored size is not rebuilt.
    let alreadyStored = sizes.filter { size in
        FileManager.default.fileExists(atPath: timingLandscapeEstateURL(
            inEntry: timingLandscapeCacheEntryURL(
                cacheDir: cacheDir, source: source, corpus: corpus,
                variant: variant, seed: seed, size: size)).path)
    }
    // Remaining = every requested size with NO stored entry. The previous
    // form (`> alreadyStored.max()`) skipped missing SMALLER sizes whenever
    // the largest size was already stored, reporting "every requested size
    // is already stored" while the cache had holes (codex finding
    // 2026-08-26). The resume base is the largest stored size strictly
    // below the smallest missing one — the biggest prefix the incremental
    // grow can legitimately start from.
    let remaining = sizes.filter { !alreadyStored.contains($0) }.sorted()
    let resumeFrom = remaining.first.map { smallest in
        alreadyStored.filter { $0 < smallest }.max() ?? 0
    } ?? 0
    guard !remaining.isEmpty else {
        FileHandle.standardOutput.write(Data(
            ("[landscape] every requested size is already stored in "
            + "\(cacheDir.path); nothing to build\n").utf8))
        return
    }

    var scratchDir: URL
    var activeClient: MCPClient
    if resumeFrom > 0 {
        FileHandle.standardOutput.write(Data(
            "[landscape] resuming from the stored \(resumeFrom)-row landscape\n".utf8))
        let entry = timingLandscapeCacheEntryURL(
            cacheDir: cacheDir, source: source, corpus: corpus,
            variant: variant, seed: seed, size: resumeFrom)
        scratchDir = try lmeScratchDir(posture: posture)
        try? FileManager.default.removeItem(at: scratchDir)
        try cloneOrCopyItem(at: timingLandscapeEstateURL(inEntry: entry), to: scratchDir)
        let endpoint = try lmeEndpointConfig(
            scratchDir: scratchDir, mootBinaryPath: mootBinary,
            posture: posture, shape: .disk)
        // A landscape estate can hold 100,000 rows, and opening one loads its
        // resident arrays into memory before the server answers anything. The
        // client-wide default of 120s is a ceiling on that open; this raises it
        // to the handshake tier so the size of the landscape, not the clock,
        // decides whether the lane runs.
        activeClient = MCPClient(endpoint: endpoint, responseDeadline: MCPDeadline.unbounded)
        try await activeClient.connect()
    } else {
        (activeClient, scratchDir) = try await provisionTimingEstate(
            mootBinaryPath: mootBinary, posture: posture)
    }
    var connected = true
    let workingDir = scratchDir
    // The working estate is torn down ONLY on a clean finish.
    //
    // This teardown used to be unconditional. On 2026-08-17 a 100,000-row
    // landscape finished ingesting and finished encoding, the import call was
    // slow to return, the client's deadline expired, and this defer deleted a
    // complete estate — 100 minutes of finished work, destroyed because the
    // last call was late. A failed build now leaves its estate on disk and says
    // where it is, so the work can be salvaged or removed by hand. Disk is
    // cheap and the rebuild is not.
    var completedCleanly = false
    defer {
        if connected { let c = activeClient; Task { await c.disconnect() } }
        if completedCleanly {
            try? lmeGuardedTeardown(workingDir)
        } else {
            FileHandle.standardError.write(Data(
                ("[landscape] build did not finish cleanly — the working estate is KEPT at "
                 + "\(workingDir.path)\n"
                 + "[landscape] it holds everything built up to the failure; "
                 + "remove it by hand when you are done with it\n").utf8))
        }
    }
    FileHandle.standardOutput.write(Data(
        "[landscape] building in \(scratchDir.path)\n".utf8))

    var built = resumeFrom
    for size in remaining {
        let delta = size - built
        FileHandle.standardOutput.write(Data(
            "[landscape] building to \(size) rows (adding \(delta))...\n".utf8))
        try await buildLandscapeSegment(
            client: activeClient,
            scratchDir: scratchDir,
            from: built,
            count: delta,
            seed: seed,
            label: "\(size)",
            corpusRows: corpusRows)
        built = size

        // Disconnect before copying. A server holding the database open has
        // WAL content that has not reached the main file, and a copy taken
        // underneath it restores as a database missing its most recent rows.
        await activeClient.disconnect()
        connected = false

        let entry = timingLandscapeCacheEntryURL(
            cacheDir: cacheDir, source: source, corpus: corpus,
            variant: variant, seed: seed, size: size)
        try? FileManager.default.removeItem(at: entry)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try cloneOrCopyItem(at: scratchDir, to: timingLandscapeEstateURL(inEntry: entry))

        let recipe = source == .corpus
            ? TimingLandscapeRecipe.corpus(corpus, variant: variant, rows: size, seed: seed)
            : TimingLandscapeRecipe.synthetic(rows: size, seed: seed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recipe).write(to: timingLandscapeRecipeURL(inEntry: entry))

        FileHandle.standardOutput.write(Data(
            "[landscape] stored \(entry.lastPathComponent)\n".utf8))

        // Reconnect for the next segment unless this was the last size.
        if size != remaining.last {
            let endpoint = try lmeEndpointConfig(
                scratchDir: scratchDir, mootBinaryPath: mootBinary,
                posture: posture, shape: .disk)
            // A landscape estate can hold 100,000 rows, and opening one loads its
        // resident arrays into memory before the server answers anything. The
        // client-wide default of 120s is a ceiling on that open; this raises it
        // to the handshake tier so the size of the landscape, not the clock,
        // decides whether the lane runs.
        activeClient = MCPClient(endpoint: endpoint, responseDeadline: MCPDeadline.unbounded)
            try await activeClient.connect()
            connected = true
        }
    }

    completedCleanly = true
    FileHandle.standardOutput.write(Data(
        ("[landscape] complete: \(remaining.count) landscape(s) built in \(cacheDir.path)\n").utf8))
}

/// Resolves the landscape source options shared by `landscape-build` and the
/// timing lane, so the two cannot drift on what a recipe means.
func resolveLandscapeSource(
    _ args: [String]
) throws -> (TimingLandscapeSource, TimingLandscapeCorpus, String, [TimingLandscapeRow]?) {
    let sourceRaw = optionValue("--landscape", in: args) ?? "synthetic"
    guard let source = TimingLandscapeSource(rawValue: sourceRaw) else {
        throw MCPError(description:
            "--landscape must be one of: "
            + TimingLandscapeSource.allCases.map(\.rawValue).joined(separator: ", "))
    }
    let corpusRaw = optionValue("--landscape-corpus", in: args) ?? "longmemeval"
    guard let corpus = TimingLandscapeCorpus(rawValue: corpusRaw) else {
        throw MCPError(description:
            "--landscape-corpus must be one of: "
            + TimingLandscapeCorpus.allCases.map(\.rawValue).joined(separator: ", "))
    }
    let variant = optionValue("--landscape-variant", in: args) ?? "s"

    guard source == .corpus else { return (source, corpus, variant, nil) }

    guard let dataDir = optionValue("--landscape-data-dir", in: args) else {
        throw MCPError(description:
            "--landscape corpus requires --landscape-data-dir (the fetched data set)")
    }
    switch corpus {
    case .longmemeval:
        let file = URL(fileURLWithPath: dataDir)
            .appendingPathComponent("longmemeval_\(variant)_cleaned.json")
        let loaded = try loadLMECorpus(from: file)
        let rows = longMemEvalLandscapeRows(corpus: loaded)
        guard !rows.isEmpty else {
            throw MCPError(description: "landscape corpus produced no rows")
        }
        let banner = "[landscape] \(corpus.rawValue) variant \(variant), "
            + "\(rows.count) rows available (\(corpus.licence))\n"
        FileHandle.standardOutput.write(Data(banner.utf8))
        return (source, corpus, variant, rows)
    case .lmeb:
        throw MCPError(description:
            "--landscape-corpus lmeb is declared but its row extraction is not "
            + "implemented; use longmemeval")
    }
}
