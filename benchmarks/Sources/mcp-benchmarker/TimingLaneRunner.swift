// TimingLaneRunner.swift
// C2 (benchmark reset 2026-08-13): the timing lane.
//
// Measures write/ingest timing against a single growing estate:
//   - Builds a synthetic corpus monotonically: 2k → 10k → 100k rows.
//   - At each checkpoint, takes k measured single-row writes per column
//     (background + impatient).
//   - Reports four metrics per write: ACCEPT (client stopwatch), INGEST
//     (audit-derived via moot_timing_report), CYCLE (four tiers, audit-derived),
//     READ (client stopwatch for moot_memory_search).
//   - Uses since_ms watermarks so per-write timing signals are not polluted
//     by landscape ingest events.
//
// Shape: "disk" only (Shape 2 in BENCHMARK_BUILD_ARCHITECTURE.md). Timing
// numbers on an in-memory estate cannot be compared to disk ones; the
// lane enforces this by hardcoding .disk.
//
// k-row drift: the same estate is reused across k repeats within a
// checkpoint. Each measured write adds one row to the haystack (S+1,
// S+2, …, S+k for background; then S+k+1, …, S+2k for impatient).
// This drift is acceptable for timing research: the per-write timing
// signal is dominated by encoding overhead, not haystack size at these
// scales. The report documents the drift as `haystack_drift_per_repeat`.
// An APFS clone of a running serve process would require stop→clone→
// restart→measure for each repeat — more complex, slower, and no more
// accurate for encode-time measurement.
//
// C4 seam: `fetchTimingReportSince(client:sinceMs:)` passes the
// since_ms watermark to `moot_timing_report` so per-write signals
// exclude landscape ingest events.
//
// Twin: `timing_lane_runner.rs`.

import EstateEncryption
import Foundation

/// Refuses unless the estate database in `scratch` is encrypted.
///
/// A posture is a claim about bytes, so it is checked against the bytes. A
/// plaintext SQLite file opens with the 16-byte magic "SQLite format 3\0";
/// an encrypted one does not. The timing lane asserted nothing until
/// 2026-08-18 and published an "encrypted" record measured on plaintext.
func assertEstateIsEncrypted(inScratch scratch: URL) throws {
    let db = estateDatabaseURL(inScratch: scratch)
    guard EstateEncryptionMigrator.detectEstateFileState(at: db) != .plaintext else {
        throw MCPError(description:
            "timing lane: \(db.path) is still PLAINTEXT after conversion — refusing to "
            + "measure it as an encrypted posture")
    }
}

// MARK: - Report structs

/// A p50/p95 pair for one timing metric, in milliseconds.
///
/// Field names are snake_case (CodingKeys) so the JSON output is
/// byte-compatible with the Rust twin.
struct TimingStatPair: Codable, Sendable {
    /// 50th-percentile latency in milliseconds (nearest-rank method).
    var p50Ms: Double
    /// 95th-percentile latency in milliseconds (nearest-rank method).
    var p95Ms: Double

    enum CodingKeys: String, CodingKey {
        case p50Ms = "p50_ms"
        case p95Ms = "p95_ms"
    }
}

/// Results for one measurement column (background or impatient) at one
/// haystack size.
/// Audit-derived fields are OPTIONAL and absent from the JSON when no sample
/// was collected. Zero is a legitimate measured latency, so it must never
/// double as "not measured" — a reader cannot tell the two apart, and the
/// four audit-derived metrics all read 0 when the product binary lacks
/// `moot_timing_report`. Absent says what happened; 0 lies about it.
struct TimingColumnResult: Codable, Sendable {
    /// Client-stopwatch time from before `moot_file_memory` call to after.
    var acceptMs: TimingStatPair?
    /// Audit-derived encode time from moot_timing_report ingest_exact.
    var ingestMs: TimingStatPair?
    /// Audit-derived encode cycle — vector tier (encode fingerprint + vector).
    var cycleVectorMs: TimingStatPair?
    /// Audit-derived encode cycle — novel-token tier (novel token scan).
    var cycleNovelMs: TimingStatPair?
    /// Audit-derived encode cycle — dreamt tier (dream daemon association).
    var cycleDreamtMs: TimingStatPair?
    /// Client-stopwatch time for one `moot_memory_search` recall query.
    var readMs: TimingStatPair?
    /// Raw moot_timing_report texts from each repeat, for post-hoc diagnosis.
    var rawTimingReports: [String]

    enum CodingKeys: String, CodingKey {
        case acceptMs       = "accept_ms"
        case ingestMs       = "ingest_ms"
        case cycleVectorMs  = "cycle_vector_ms"
        case cycleNovelMs   = "cycle_novel_ms"
        case cycleDreamtMs  = "cycle_dreamt_ms"
        case readMs         = "read_ms"
        case rawTimingReports = "raw_timing_reports"
    }
}

/// Results at one haystack size (both measurement columns).
struct TimingLaneSizeResult: Codable, Sendable {
    /// Number of rows in the estate when the checkpoint was reached (BEFORE
    /// the k measured writes). For the 2k checkpoint this is 2000, etc.
    var haystackSize: Int
    /// How many rows the haystack grows across k repeats (always 2 * repeats:
    /// k background + k impatient writes added during measurement).
    var haystackDriftPerRepeat: Int
    /// Background writes: default queue posture (no `impatient: true`).
    var background: TimingColumnResult
    /// Impatient writes: `impatient: true` inline encoding.
    var impatient: TimingColumnResult

    enum CodingKeys: String, CodingKey {
        case haystackSize            = "haystack_size"
        case haystackDriftPerRepeat  = "haystack_drift_per_repeat"
        case background              = "background"
        case impatient               = "impatient"
    }
}

/// Top-level timing lane report. Written to `<out>/timing-report-seed<S>.json`.
struct TimingLaneReport: Codable, Sendable {
    /// The estate schema the harness was built against, stamped into every
    /// report so the results record can carry the column without anyone typing
    /// it (BENCHMARK_PROTOCOL §9). Constant rather than a parameter: a report
    /// describes the run that produced it, and that run's artifacts were
    /// validated against this exact value on open, so a mismatch fails the run
    /// rather than reaching a report.
    ///
    /// Declared with its value, so it is always encoded and never decoded: an
    /// older report that predates the field still reads.
    let estateSchemaVersion: String = currentEstateSchemaVersion

    var benchmarkProtocolVersion: String
    var runEnvironment: RunEnvironment
    /// RNG seed used for synthetic corpus generation.
    var seed: UInt64
    /// Number of measured writes per column per checkpoint.
    var repeats: Int
    /// Estate shape — always "disk" for this lane.
    var shape: String
    /// At-rest encryption posture of the scratch estate.
    var estateEncryption: String
    /// The landscape recipe. Corpus name, variant, licence, row count and
    /// seed — enough for another team to build the same landscape and run
    /// this benchmark against their own system.
    var landscape: TimingLandscapeRecipe
    /// Per-checkpoint results: three entries (2k, 10k, 100k).
    var results: [TimingLaneSizeResult]

    enum CodingKeys: String, CodingKey {
        case estateSchemaVersion     = "estate_schema_version"
        case benchmarkProtocolVersion = "benchmark_protocol_version"
        case runEnvironment           = "run_environment"
        case seed                     = "seed"
        case repeats                  = "repeats"
        case landscape                = "landscape"
        case shape                    = "shape"
        case estateEncryption         = "estate_encryption"
        case results                  = "results"
    }
}

// MARK: - Timing report fetch (C4 seam, since_ms variant)

/// Calls `moot_timing_report` with a `since_ms` watermark and returns the
/// rendered report text. Errors swallowed into nil — timing capture is
/// observability that must not abort a measurement run.
///
/// The `since_ms` watermark isolates the audit window so that landscape ingest
/// events (built before measurement began) do not pollute the per-write
/// INGEST/CYCLE numbers. The watermark advances after each measured write so
/// consecutive writes do not bleed into each other.
///
/// Twin of Rust `fetch_timing_report_since`.
func fetchTimingReportSince(client: MCPClient, sinceMs: Int64) async -> String? {
    guard let result = try? await client.callTool(
        AriaV2Surface.timingReport,
        arguments: ["since_ms": .number(Double(sinceMs))],
        format: .mootV2,
        // Interactive tier: a bounded read over the audit window (the window
        // itself is capped server-side by AT-01), not whole-corpus work.
        deadline: MCPDeadline.interactive
    ) else { return nil }
    let text = result.textBlocks.joined(separator: "\n")
    return text.isEmpty ? nil : text
}

/// Preflight: the product binary must actually expose `moot_timing_report`.
///
/// Why this is a hard failure and not a warning. INGEST and the three CYCLE
/// tiers are derived ENTIRELY from that tool. When it is absent — an older
/// installed binary is the ordinary case, since the tool shipped 2026-08-13 —
/// every fetch returns nil, no samples accumulate, and the lane emits 0 for
/// four of its six metrics. Zero is a legitimate measured value, so those
/// zeros are indistinguishable from a fast estate in the report JSON, sitting
/// beside real READ and ACCEPT numbers in identical shape.
///
/// A landscape run costs an hour. Discovering the metrics were unmeasurable
/// afterwards costs the hour twice, and quoting them costs more than that.
func assertTimingToolAvailable(client: MCPClient, mootBinaryPath: String) async throws {
    if await fetchTimingReportSince(client: client, sinceMs: 0) != nil { return }
    throw MCPError(description:
        "timing: the product binary does not expose moot_timing_report, so "
        + "INGEST and all three CYCLE tiers cannot be measured.\n"
        + "  binary: \(mootBinaryPath)\n"
        + "The tool shipped 2026-08-13; an installed binary older than that "
        + "predates it. Build the current binary and pass it with "
        + "--mootx01-binary <path>, or install it, then re-run.")
}

// MARK: - Timing report parsers

/// Extracts the `watermark_ms: N` value from a moot_timing_report text.
/// Returns 0 when the line is absent (safe fallback: the next since_ms call
/// covers the full history, which over-counts but never under-counts).
func parseWatermarkMs(from text: String) -> Int64 {
    // Expected line format: "  watermark_ms: N"
    for line in text.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("watermark_ms:") else { continue }
        let rest = trimmed.dropFirst("watermark_ms:".count)
            .trimmingCharacters(in: .whitespaces)
        if let value = Int64(rest) { return value }
    }
    return 0
}

/// Extracts the p50 value (in milliseconds) for `ingest_exact` from a
/// moot_timing_report text.
///
/// Expected line format: "  ingest_exact: n=N, p50=Xms, p95=Yms"
/// Returns nil when the line is absent or unparseable (one or zero events
/// in the window — not an error).
func parseIngestExactP50Ms(from text: String) -> Double? {
    parseTimingP50Ms(prefix: "ingest_exact:", from: text)
}

/// Extracts the p50 value (ms) for a CYCLE tier line from a timing report text.
///
/// Expected formats:
///   "  cycle_vector: n=N, p50=Xms, p95=Yms"
///   "  cycle_novel: n=N, p50=Xms, p95=Yms, unbounded=N"
///   "  cycle_dreamt: n=N, p50=Xms, p95=Yms, unbounded=N"
///
/// `linePrefix` is the expected start of the trimmed line, e.g. "cycle_vector:".
func parseCycleP50Ms(linePrefix: String, from text: String) -> Double? {
    parseTimingP50Ms(prefix: linePrefix, from: text)
}

/// Common p50 parser: finds the first trimmed line starting with `prefix`
/// and extracts the value after `p50=`. Strips trailing "ms" suffix.
private func parseTimingP50Ms(prefix: String, from text: String) -> Double? {
    for line in text.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(prefix) else { continue }
        // Find "p50=" in the remainder of the line.
        guard let p50Range = trimmed.range(of: "p50=") else { continue }
        let afterP50 = trimmed[p50Range.upperBound...]
        // Value ends at first comma or whitespace.
        let rawValue = afterP50.prefix(while: { !$0.isWhitespace && $0 != "," })
        // Strip trailing "ms" and parse.
        let stripped = rawValue.hasSuffix("ms")
            ? String(rawValue.dropLast(2))
            : String(rawValue)
        return Double(stripped)
    }
    return nil
}

// MARK: - Synthetic corpus

/// A generated timing record for one row index.
struct TimingSeedRecord {
    let id: String        // UUIDv4-format, deterministic via seed + index
    let content: String   // Synthetic prose, deterministic
    let eventTime: String // ISO8601, sequential from 2026-01-01T00:00:00Z
    let room: String      // "timing/bench"
}

/// Generates a deterministic batch of synthetic records for the timing lane.
///
/// Records are seeded so the same `seed` + index range always produces the
/// same content. Room is fixed as "timing/bench" — matches the read query
/// location so READ timing probes the correct recall context.
///
/// The content is a sentence that encodes the index and seed — long enough
/// (~180 chars) to exercise the embedding encoder path without becoming
/// pathologically large.
///
/// - Parameters:
///   - from: Index of the first record (inclusive).
///   - to: Index past the last record (exclusive).
///   - seed: Deterministic RNG seed.
/// - Returns: Records in index order.
func timingLaneRecords(from: Int, to: Int, seed: UInt64) -> [TimingSeedRecord] {
    var rng = SplitMix64(seed: seed &+ UInt64(from) &* 6_364_136_223_846_793_005)
    var records: [TimingSeedRecord] = []
    records.reserveCapacity(to - from)
    for i in from..<to {
        // UUID-format id: encode seed and index deterministically.
        // Format: 8-4-4-4-12 hex from two UInt64 draws.
        let a = rng.next()
        let b = rng.next()
        // truncatingIfNeeded matches the Rust twin's `as u32`/`as u16`
        // truncating casts exactly — a checked UInt16(a >> 16) conversion
        // traps whenever the high bits are set, which is nearly always.
        let idStr = String(format: "%08x-%04x-%04x-%04x-%012llx",
                           UInt32(truncatingIfNeeded: a >> 32),
                           UInt16(truncatingIfNeeded: a >> 16),
                           (UInt16(truncatingIfNeeded: a) & 0x0FFF) | 0x4000,  // version 4
                           (UInt16(truncatingIfNeeded: b >> 48) & 0x3FFF) | 0x8000,  // variant bits
                           b & 0x0000_FFFF_FFFF_FFFF)
        // Synthetic prose: encodes seed + index so content is unique per row.
        let content =
            "Timing benchmark entry index=\(i) seed=\(seed). " +
            "This synthetic memory record measures write latency on a growing " +
            "estate of \(i) prior rows. Content length targets realistic encode " +
            "overhead including the embedding path. Entry checksum: \(a ^ b)."
        let record = TimingSeedRecord(
            id: idStr,
            content: content,
            eventTime: syntheticEventTime(offsetSeconds: i),
            room: "timing/bench"
        )
        records.append(record)
    }
    return records
}

// MARK: - Percentile helpers

/// Computes p50 and p95 from a sample array using the nearest-rank method.
///
/// Returns nil when samples is empty — never (0, 0) — so "not measured"
/// stays distinguishable from "measured at zero": the (0, 0) shape lets a
/// run with no `moot_timing_report` publish four fabricated zero metrics
/// beside real ones. The caller serialises nil as an absent field.
/// Internal (not private) so the unit tests can pin the nearest-rank math
/// against the Rust twin's vectors.
func computeStatPair(samples: [Double]) -> TimingStatPair? {
    guard !samples.isEmpty else { return nil }
    let sorted = samples.sorted()
    let p50Index = min(max(Int((0.5  * Double(sorted.count)).rounded(.up)), 1) - 1, sorted.count - 1)
    let p95Index = min(max(Int((0.95 * Double(sorted.count)).rounded(.up)), 1) - 1, sorted.count - 1)
    return TimingStatPair(p50Ms: sorted[p50Index], p95Ms: sorted[p95Index])
}

// MARK: - Column runner

/// Runs k measured single-row writes for one column (background or impatient).
///
/// Per-write measurement sequence:
///   1. ACCEPT: wall-clock stopwatch around `moot_file_memory`.
///   2. Drain barrier (background only): `waitForEncodeDrain` — ensures the
///      audit log for this write is committed before the timing report is pulled.
///      For impatient mode, encoding is inline so no drain is needed.
///   3. INGEST + CYCLE: `moot_timing_report(since_ms: watermark)` — extracts
///      ingest_exact and all four cycle tiers for this write only.
///      Watermark advances to the `watermark_ms` value from each report so
///      the next write's report excludes this one.
///   4. READ: wall-clock stopwatch around `moot_memory_search`.
///
/// k-row drift: the estate grows by one row per write. The caller tracks the
/// global row index so content is deterministic across background and impatient
/// passes. The drift is documented in the report as `haystack_drift_per_repeat`.
///
/// - Parameters:
///   - client: Connected MCPClient pointing at the estate.
///   - repeats: k — number of measured writes.
///   - useImpatient: true → `impatient: true` writes (inline encoding, no drain);
///                   false → background writes (default queue, drain barrier).
///   - watermarkMs: Initial watermark. Updated in-place as each write completes.
///   - nextRecordIndex: Index of the next synthetic record. Updated in-place.
///   - seed: Corpus seed (forwarded to `timingLaneRecords`).
/// - Returns: A `TimingColumnResult` with k samples aggregated to p50/p95.
private func runTimingColumn(
    client: MCPClient,
    repeats: Int,
    useImpatient: Bool,
    watermarkMs: inout Int64,
    nextRecordIndex: inout Int,
    seed: UInt64
) async -> TimingColumnResult {
    var acceptSamples:      [Double] = []
    var ingestSamples:      [Double] = []
    var cycleVectorSamples: [Double] = []
    var cycleNovelSamples:  [Double] = []
    var cycleDreamtSamples: [Double] = []
    var readSamples:        [Double] = []
    var rawReports:         [String] = []

    for _ in 0..<repeats {
        let recordIndex = nextRecordIndex
        nextRecordIndex += 1
        let records = timingLaneRecords(from: recordIndex, to: recordIndex + 1, seed: seed)
        guard let record = records.first else { continue }

        // ── ACCEPT: client stopwatch around the write ──────────────────────
        var writeArgs: [String: JSONValue] = [
            "content": .string(record.content),
            "subject": .string(deterministicSubject(record.content)),
            "location": .string(record.room),
        ]
        if useImpatient {
            // impatient: true — inline encoding; the encoding completes before
            // the call returns. No drain barrier needed for the timing report.
            writeArgs["impatient"] = .bool(true)
        }
        let acceptStart = Date()
        _ = try? await client.callTool(AriaV2Surface.fileMemory, arguments: writeArgs, format: .mootV2)
        let acceptMs = Date().timeIntervalSince(acceptStart) * 1000
        acceptSamples.append(acceptMs)

        // ── Drain barrier (background only) ────────────────────────────────
        // For background writes the encode queue processes the write
        // asynchronously. Wait until it drains so the audit log entry
        // covering this write is committed before we pull the timing report.
        // For impatient writes, encoding is synchronous; drain is a no-op.
        if !useImpatient {
            _ = await waitForEncodeDrain(
                client: client,
                label: "timing-lane-\(useImpatient ? "impatient" : "background")-\(recordIndex)")
        }

        // ── INGEST + CYCLE: timing report since watermark ──────────────────
        // The since_ms watermark isolates this write's audit events so we
        // see exactly the encode overhead for this one row.
        let timingText = await fetchTimingReportSince(client: client, sinceMs: watermarkMs)

        if let text = timingText {
            rawReports.append(text)
            // Advance watermark for the next write. If the parse fails, keep
            // the previous watermark (next report covers both this and next
            // write — a double-count, documented as a raw_timing_reports miss).
            let newWatermark = parseWatermarkMs(from: text)
            if newWatermark > watermarkMs { watermarkMs = newWatermark }

            // INGEST: ingest_exact p50 (milliseconds).
            if let ms = parseIngestExactP50Ms(from: text) { ingestSamples.append(ms) }
            // CYCLE tiers.
            if let ms = parseCycleP50Ms(linePrefix: "cycle_vector:", from: text) { cycleVectorSamples.append(ms) }
            if let ms = parseCycleP50Ms(linePrefix: "cycle_novel:", from: text)  { cycleNovelSamples.append(ms) }
            if let ms = parseCycleP50Ms(linePrefix: "cycle_dreamt:", from: text) { cycleDreamtSamples.append(ms) }
        }

        // ── READ: client stopwatch around recall query ─────────────────────
        // Query text is the first sentence of the written content — guarantees
        // the entry is relevant without cherry-picking an exact substring.
        let queryText = String(record.content.split(separator: ".").first ?? "timing benchmark")
        let readStart = Date()
        // v2: scope key for moot_memory_search is `wing` (v1 used `location`).
        _ = try? await client.callTool(
            AriaV2Surface.memorySearch,
            arguments: [
                "query": .string(queryText),
                "wing": .string(record.room),
            ],
            format: .mootV2)
        let readMs = Date().timeIntervalSince(readStart) * 1000
        readSamples.append(readMs)
    }

    return TimingColumnResult(
        acceptMs:       computeStatPair(samples: acceptSamples),
        ingestMs:       computeStatPair(samples: ingestSamples),
        cycleVectorMs:  computeStatPair(samples: cycleVectorSamples),
        cycleNovelMs:   computeStatPair(samples: cycleNovelSamples),
        cycleDreamtMs:  computeStatPair(samples: cycleDreamtSamples),
        readMs:         computeStatPair(samples: readSamples),
        rawTimingReports: rawReports
    )
}

// MARK: - Estate provisioner

/// Builds a scratch mootx01 estate for the timing lane, using the lme-bench-
/// scratch-dir machinery. The timing lane always uses .plaintextTransient and
/// the disk shape — the lane measures write/encode timing, not encryption
/// overhead (that is supersession's --estate-mode both cell).
///
/// Uses `lmeScratchDir` and `lmeEndpointConfig` from LongMemEvalRunner.swift
/// (same scratchDir conventions, same `/tmp/lme-bench-*` prefix).
func provisionTimingEstate(mootBinaryPath: String, posture: ScratchEstatePosture) async throws
    -> (client: MCPClient, scratchDir: URL) {
    let scratchDir = try lmeScratchDir(posture: posture)
    let endpointCfg = try lmeEndpointConfig(
        scratchDir: scratchDir,
        mootBinaryPath: mootBinaryPath,
        posture: posture,
        shape: .disk)
    // Opening a restored landscape loads its resident arrays into memory,
    // which scales with the landscape. The client-wide 120s default capped the
    // handshake below that on 2026-08-18 and the 100,000-row checkpoint never
    // started.
    let client = MCPClient(endpoint: endpointCfg, responseDeadline: MCPDeadline.unbounded)
    try await client.connect()
    return (client, scratchDir)
}

// MARK: - Landscape builder

/// Ingests `count` synthetic rows into the estate using the batch seed path
/// (moot_json_import) and waits for the encode drain to settle.
///
/// Records start at index `startIndex`, deterministic from `seed`. The
/// function does not return the drain outcome — drain failure is non-fatal
/// for the landscape build (the next checkpoint will drain again).
func buildLandscapeSegment(
    client: MCPClient,
    scratchDir: URL,
    from startIndex: Int,
    count: Int,
    seed: UInt64,
    label: String,
    corpusRows: [TimingLandscapeRow]? = nil
) async throws {
    guard count > 0 else { return }
    // Corpus rows when a corpus landscape was selected, templated rows
    // otherwise. Both are deterministic over the same index range, so the two
    // sources are interchangeable here and the recipe in the report says which
    // one produced the landscape.
    let records: [TimingSeedRecord]
    if let corpusRows, !corpusRows.isEmpty {
        records = corpusLandscapeRecords(
            rows: corpusRows, from: startIndex, to: startIndex + count)
    } else {
        records = timingLaneRecords(from: startIndex, to: startIndex + count, seed: seed)
    }
    // ONE import for the whole segment, then ONE drain.
    //
    // The importer writes a bulk seed in a single transaction up to
    // ImportPolicy.bulkWindow (125,000 rows), and it does not wait for encoding
    // — captureBatch enqueues the encode work and the corpus drain worker fans
    // it across every core. A segment is at most 25,000 rows, so the whole
    // segment is one window, one transaction, one hand-off.
    //
    // This lane used to import in 2,000-row chunks with a drain barrier after
    // each one. That serialized what the product parallelizes: fifty
    // load-and-settle cycles for a 100,000-row landscape, no overlap between
    // one chunk's encode and the next chunk's writes, and a resident vector
    // index republished at the end of every burst — fifty rebuilds over a store
    // growing to 100,000 vectors. The build took about six hours.
    //
    // Chunk boundaries never changed the data: records are addressed by index
    // range, so row N carries the same id and event time however it arrived.
    let seedRecords = records.map { r in
        SeedFileRecord(id: r.id, content: r.content, eventTime: r.eventTime, room: r.room)
    }
    let seedName = "timing-landscape-\(label)"
    let seedData = emitSeedJSON(name: seedName, records: seedRecords)
    let seedURL = try writeSeedFile(seedData, in: scratchDir, name: seedName)

    let importResult = try await client.callTool(
        AriaV2Surface.jsonImport,
        arguments: [
            "path": .string(seedURL.path),
            // v2: `mode` arg removed from moot_json_import; the tool now manages
            // encode scheduling internally. Requires vault capability on the estate.
        ],
        format: .mootV2,
        // NO CEILING. How long this takes is a property of the machine —
        // disk speed, core count, what else is running — not of the protocol,
        // so any number here is a guess about hardware. On 2026-08-17 a guess
        // of 1800s and then 7200s both fired on an import whose rows were
        // already written and whose encode had already finished. Liveness is
        // watched from outside; the lane prints its progress as it goes.
        deadline: MCPDeadline.unbounded)
    // v2 surface: drawer count is in structuredContent.data.drawers_written.
    guard let written = importResult.drawersWritten, written == records.count else {
        throw MCPError(description:
            "timing lane: moot_json_import did not confirm \(records.count) drawers "
            + "for segment \(label) — got: "
            + (importResult.drawersWritten.map(String.init) ?? "(no structured data)"))
    }

    // One drain barrier, at the end of the segment. Encoding and the
    // dream-association cycles run on after the import call returns, and the
    // checkpoint is only meaningful once they have settled.
    _ = await waitForEncodeDrain(client: client, label: "timing-landscape-\(label)")
}


// MARK: - Main entry point (called from CLI.swift)

/// The `timing` subcommand: provision one estate, build the landscape in three
/// monotonic steps, and take k measurements at each checkpoint.
///
/// Options:
///   --binary / --mootx01-binary  path to the mootx01 binary (auto-discovered)
///   --seed S                     corpus seed (default 20260813)
///   --repeats k                  measured writes per column per checkpoint (default 5)
///   --out <dir>                  report output directory (default: current dir)
///   --run-mode quiet|contended   machine posture for the report (default: unspecified)
func runTiming(_ args: [String]) async throws {
    // At-rest encryption for the measured database. The two settings are
    // measured in separate runs and the difference between them is a reported
    // figure.
    let timingPosture = try parseEstateMode(in: args)
    // ── Option parsing ─────────────────────────────────────────────────────
    // Accept both Swift-style (--mootx01-binary) and Rust-style (--binary) flag.
    guard let mootBinary = optionValue("--mootx01-binary", in: args)
                        ?? optionValue("--binary", in: args)
                        ?? discoverMootBinary() else {
        throw MCPError(description:
            "timing: could not find mootx01 binary; pass --binary <path> "
            + "or set $MOOTX01_BINARY")
    }
    let seed = UInt64(optionValue("--seed", in: args) ?? "") ?? 20_260_813
    let repeats = try validatedCount("--repeats", in: args, default: 5, minimum: 1)
    let outDir = optionValue("--out", in: args).map { URL(fileURLWithPath: $0) }
    let runMode = optionValue("--run-mode", in: args) ?? "unspecified"

    // ── Landscape source ───────────────────────────────────────────────────
    // --landscape corpus draws the unmeasured background rows from a published
    // data set, so the landscape is reproducible by anyone holding that data
    // set. --landscape synthetic (the default) templates them from the seed,
    // which needs no corpus but exists only inside this harness.
    //
    // --landscape-cache restores a landscape built earlier by `landscape-build`
    // rather than ingesting one here. The landscape is unmeasured background,
    // so building it inside this run puts a 100,000-row ingest inside the
    // window that has to be idle. With a cache the corpus data set is not read:
    // the rows are already in the stored database, and its recipe travels with
    // it.
    let landscapeCache = optionValue("--landscape-cache", in: args)
        .map { URL(fileURLWithPath: $0) }

    let landscapeSource: TimingLandscapeSource
    let landscapeCorpus: TimingLandscapeCorpus
    let landscapeVariant: String
    var corpusRows: [TimingLandscapeRow]? = nil
    if landscapeCache != nil {
        // Naming the recipe still matters — it selects WHICH stored landscape
        // to restore — but the data set behind it is not opened again.
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
        landscapeSource = source
        landscapeCorpus = corpus
        landscapeVariant = optionValue("--landscape-variant", in: args) ?? "s"
    } else {
        (landscapeSource, landscapeCorpus, landscapeVariant, corpusRows) =
            try resolveLandscapeSource(args)
    }
    // --sizes: override the landscape checkpoints. The published landscape is
    // 2k/10k/100k, and a run at that scale ingests 100,000 rows — too heavy to
    // prove the lane mechanically works. `--sizes 100,200` exercises every code
    // path (segment build, checkpoint, k-repeat columns, report shape) in
    // seconds. Sizes must ASCEND: each segment starts where the previous ended,
    // so a descending list would ask for a negative delta.
    let sizes = try validatedAscendingSizes("--sizes", in: args, default: [2_000, 10_000, 100_000])

    // Pre-compute the record serial here so the same value goes into both the
    // filename and the stamped run_environment block (testname-arm-serial discipline).
    let timingSerial = resolveRunSerial(args)
    var runEnv = RunEnvironment.collect(mootx01BinaryPath: mootBinary, runMode: runMode)
    stampTestIdentity(&runEnv, test: "timing", arm: "\(timingPosture)", serial: timingSerial)
    FileHandle.standardOutput.write(Data(
        ("[timing] mootx01: \(mootBinary)\n"
        + "[timing] seed: \(seed)  repeats: \(repeats)  run-mode: \(runMode)\n").utf8))

    // ── Estate provisioning ────────────────────────────────────────────────
    // Mutable: a cached run replaces both per checkpoint, because each
    // checkpoint restores its own stored landscape rather than growing the
    // previous one. That is also what gives each checkpoint a database at
    // exactly S rows instead of S plus the previous checkpoint's measured
    // writes.
    var (client, scratchDir) = try await provisionTimingEstate(
        mootBinaryPath: mootBinary, posture: timingPosture)
    // Retired only when the lane finished. A throw keeps the estate and says
    // where (see keepScratchEstateOnFailure).
    var timingCompleted = false
    defer {
        let finalClient = client
        let finalScratch = scratchDir
        let finished = timingCompleted
        Task { await finalClient.disconnect() }
        if !finished { keepScratchEstateOnFailure(finalScratch, lane: "timing") }
        else { try? lmeGuardedTeardown(finalScratch) }
    }
    FileHandle.standardOutput.write(Data(
        "[timing] estate: \(scratchDir.path)\n".utf8))

    // Preflight BEFORE the landscape build — an unmeasurable run must cost
    // seconds, not the hour a full 2k/10k/100k landscape takes.
    try await assertTimingToolAvailable(client: client, mootBinaryPath: mootBinary)

    // With a cache, every requested size must be present BEFORE any
    // measurement. Discovering a missing 100k landscape after measuring 2k and
    // 10k would spend the idle window and still not produce a curve.
    if let cache = landscapeCache {
        let missing = sizes.filter { size in
            !FileManager.default.fileExists(atPath: timingLandscapeEstateURL(
                inEntry: timingLandscapeCacheEntryURL(
                    cacheDir: cache, source: landscapeSource, corpus: landscapeCorpus,
                    variant: landscapeVariant, seed: seed, size: size)).path)
        }
        guard missing.isEmpty else {
            throw MCPError(description:
                "landscape cache \(cache.path) has no entry for size(s) "
                + missing.map(String.init).joined(separator: ", ")
                + " under this recipe. Build them first: mcp-benchmarker "
                + "landscape-build --cache-dir \(cache.path) --sizes "
                + sizes.map(String.init).joined(separator: ","))
        }
    }

    // ── Landscape checkpoints (default 2k → 10k → 100k, --sizes overrides) ──
    // Build monotonically: each segment starts where the previous ended, so a
    // checkpoint's delta is its size minus the size before it.
    // Checkpoints: [(target_size, rows_in_this_segment)]
    var checkpoints: [(size: Int, delta: Int)] = []
    var previousSize = 0
    for size in sizes {
        checkpoints.append((size: size, delta: size - previousSize))
        previousSize = size
    }

    var sizeResults: [TimingLaneSizeResult] = []
    // Row-index cursor. It advances past the landscape as measured writes are
    // made, so it is NOT the landscape size once measurement starts.
    var landscapeRowsBuilt = 0
    // The landscape size itself, which is what the recipe records: another
    // team building this landscape ingests this many rows, not this many plus
    // however many writes we measured on top.
    var landscapeRowCount = 0

    for checkpoint in checkpoints {
        let targetSize = checkpoint.size
        let segmentCount = checkpoint.delta

        if let cache = landscapeCache {
            // Restore this checkpoint's stored landscape. The previous
            // checkpoint's estate is retired first: it carries that
            // checkpoint's measured writes and is no longer at its own S.
            FileHandle.standardOutput.write(Data(
                "[timing] restoring landscape at \(targetSize) rows...\n".utf8))
            await client.disconnect()
            try? lmeGuardedTeardown(scratchDir)

            let entry = timingLandscapeCacheEntryURL(
                cacheDir: cache, source: landscapeSource, corpus: landscapeCorpus,
                variant: landscapeVariant, seed: seed, size: targetSize)
            let restored = try lmeScratchDir(posture: timingPosture)
            try? FileManager.default.removeItem(at: restored)
            try cloneOrCopyItem(at: timingLandscapeEstateURL(inEntry: entry), to: restored)

            // The stored landscape is PLAINTEXT. Restoring it under the
            // encrypted posture does not encrypt anything — the posture is not
            // a property of the directory; the bytes stay plaintext and the
            // report carries a posture it does not have. On 2026-08-18 both
            // postures produced figures within noise of each other because
            // they were the same measurement twice.
            //
            // Convert it, hand the server the key that conversion used, and
            // then PROVE the file is no longer plaintext before measuring.
            if timingPosture == .encryptedEphemeral {
                let key = matrixKey(seed: seed)
                _ = try convertScratchDirectoryToEncrypted(scratchDir: restored, key: key)
                try writeHarnessInstallKey(key, inDirectory: restored, lane: "the encrypted timing posture")
                try assertEstateIsEncrypted(inScratch: restored)
            }
            scratchDir = restored

            let endpoint = try lmeEndpointConfig(
                scratchDir: scratchDir, mootBinaryPath: mootBinary,
                posture: timingPosture, shape: .disk)
            client = MCPClient(endpoint: endpoint, responseDeadline: MCPDeadline.unbounded)
            try await client.connect()

            landscapeRowsBuilt = targetSize
            landscapeRowCount = targetSize
        } else {
            FileHandle.standardOutput.write(Data(
                ("[timing] building landscape to \(targetSize) rows "
                + "(adding \(segmentCount))...\n").utf8))

            try await buildLandscapeSegment(
                client: client,
                scratchDir: scratchDir,
                from: landscapeRowsBuilt,
                count: segmentCount,
                seed: seed,
                label: "\(targetSize)",
                corpusRows: corpusRows)
            landscapeRowsBuilt += segmentCount
            landscapeRowCount += segmentCount
        }

        // ── Watermark: baseline after landscape drain ──────────────────────
        // Fetch the timing report with no since_ms to get the current
        // watermark_ms. All per-write measurements pass this watermark so
        // landscape ingest events are excluded from their INGEST/CYCLE numbers.
        let baselineReport = await fetchTimingReportSince(client: client, sinceMs: 0)
        var watermarkMs: Int64 = baselineReport.map(parseWatermarkMs) ?? 0

        FileHandle.standardOutput.write(Data(
            "[timing] checkpoint \(targetSize): watermark=\(watermarkMs)ms\n".utf8))

        // ── Background column: k writes, default queue posture ─────────────
        FileHandle.standardOutput.write(Data(
            "[timing] measuring \(repeats) background writes at \(targetSize)...\n".utf8))
        var nextRecordIndex = landscapeRowsBuilt
        let backgroundResult = await runTimingColumn(
            client: client,
            repeats: repeats,
            useImpatient: false,
            watermarkMs: &watermarkMs,
            nextRecordIndex: &nextRecordIndex,
            seed: seed)
        landscapeRowsBuilt = nextRecordIndex

        // ── Impatient column: k writes with impatient:true ─────────────────
        FileHandle.standardOutput.write(Data(
            "[timing] measuring \(repeats) impatient writes at \(targetSize)...\n".utf8))
        let impatientResult = await runTimingColumn(
            client: client,
            repeats: repeats,
            useImpatient: true,
            watermarkMs: &watermarkMs,
            nextRecordIndex: &nextRecordIndex,
            seed: seed)
        landscapeRowsBuilt = nextRecordIndex

        // k-row drift per measurement round: 2 × repeats (background + impatient).
        let drift = 2 * repeats
        sizeResults.append(TimingLaneSizeResult(
            haystackSize: targetSize,
            haystackDriftPerRepeat: drift,
            background: backgroundResult,
            impatient: impatientResult))

        FileHandle.standardOutput.write(Data(
            ("[timing] checkpoint \(targetSize) done "
            + "(estate now ~\(landscapeRowsBuilt) rows)\n").utf8))
    }

    // ── Emit JSON report ───────────────────────────────────────────────────
    let report = TimingLaneReport(
        benchmarkProtocolVersion: benchmarkProtocolVersion,
        runEnvironment: runEnv,
        seed: seed,
        repeats: repeats,
        shape: "disk",
        estateEncryption: timingPosture.rawValue,
        landscape: landscapeSource == .corpus
            ? .corpus(landscapeCorpus, variant: landscapeVariant,
                      rows: landscapeRowCount, seed: seed)
            : .synthetic(rows: landscapeRowCount, seed: seed),
        results: sizeResults)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let jsonData = try encoder.encode(report)
    // `<test>-<arm>-<serial>`: the arm is the storage posture. The at-rest
    // difference between plaintext and encrypted is itself a reported figure,
    // so the two postures are separate records and must not share a name.
    let reportFilename = recordFilename(
        test: "timing", arm: "\(timingPosture)", serial: timingSerial)
    let reportURL: URL
    if let outDir {
        try FileManager.default.createDirectory(
            at: outDir, withIntermediateDirectories: true)
        reportURL = outDir.appendingPathComponent(reportFilename)
    } else {
        reportURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(reportFilename)
    }
    // Records are never overwritten (2026-08-17).
    try writeRecordNeverOverwrite(jsonData, to: reportURL)

    FileHandle.standardOutput.write(Data(
        "[timing] report written to \(reportURL.path)\n".utf8))

    // Quick summary to stdout.
    // A metric with no samples prints "n/a", never a number. The stdout
    // summary is what an operator reads first, so it must not imply a
    // measurement the report does not contain.
    func fmt(_ pair: TimingStatPair?) -> String {
        guard let pair else { return "n/a" }
        return String(format: "p50=%.1fms p95=%.1fms", pair.p50Ms, pair.p95Ms)
    }
    for result in sizeResults {
        let bg = result.background
        let imp = result.impatient
        FileHandle.standardOutput.write(Data(String(format:
            "[timing] size=%-6d  background accept %@  impatient accept %@\n",
            result.haystackSize,
            fmt(bg.acceptMs) as NSString,
            fmt(imp.acceptMs) as NSString).utf8))
        FileHandle.standardOutput.write(Data((
            "[timing]            background ingest \(fmt(bg.ingestMs))"
            + "  cycle_vector \(fmt(bg.cycleVectorMs))\n"
            + "[timing]            background read \(fmt(bg.readMs))\n").utf8))
    }

    // ── Posture-equivalence loop ───────────────────────────────────────────
    // Provisions a fresh small estate (postureEquivDefaultRows rows,
    // postureEquivDefaultProbes probes), converts it to an encrypted twin, and
    // compares ranked recall results exactly across both postures. A divergence
    // indicates that at-rest encryption changed retrieval ordering.
    //
    // Runs after the timing report is written and the timing summary is
    // printed. A failure here does NOT abort the timing run — the timing data
    // is already safe on disk. A non-keyfile build prints a notice and skips.
    do {
        try await runPostureEquivalenceLoop(
            mootBinary: mootBinary,
            seed: seed,
            rowCount: postureEquivDefaultRows,
            probeCount: postureEquivDefaultProbes,
            args: args,
            outDir: outDir)
    } catch {
        FileHandle.standardOutput.write(Data((
            "[posture-equivalence] loop failed (timing report is unaffected): \(error)\n"
        ).utf8))
    }

    timingCompleted = true
}
