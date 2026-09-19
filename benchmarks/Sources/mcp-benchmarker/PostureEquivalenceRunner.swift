// PostureEquivalenceRunner.swift
// Posture-equivalence loop for the timing lane.
//
// After the timing measurement completes, this loop provisions a small
// independent scratch estate (postureEquivDefaultRows rows,
// postureEquivDefaultProbes probes), converts it to an encrypted twin using
// the same conversion helpers the matrix lane uses, and compares ranked recall
// results exactly across both postures. A storage posture that changes ranked
// output is a retrieval regression, not just an encryption cost.
//
// The loop runs serially after the timing checkpoints complete, adding only
// seconds to the overall run. It provisions its own estate and does NOT share
// the timing measurement estate.
//
// Artifact: posture-equivalence-disk-<serial>.json — identity block only
// (mootx01_binary_sha256, mootx01_version, protocol_version). No timing
// metrics, no machine state, no machine load; those belong exclusively to the
// timing report. The arm is "disk" because both postures always use the disk
// backend; the arm names the scope, not which posture won the comparison.
//
// Under a non-keyfile harness build (no MOOTX01_HARNESS_KEYFILE) the
// encrypted estate cannot be served — the server generates its own key and
// cannot open a database this harness converted. The loop prints a notice and
// returns without writing an artifact; the timing report is unaffected.
//
// Twin: posture_equivalence_runner.rs

import EstateEncryption
import Foundation

// ─── Constants ───────────────────────────────────────────────────────────────

/// Number of rows to ingest into the posture-equivalence scratch estate.
///
/// 200 rows give recall a real haystack: a 10-row estate might never reorder
/// between postures even if the encode path changed semantics, because
/// uniform-score ties are broken arbitrarily. 200 rows make rank sensitivity
/// non-trivial — divergence shows up when it is real.
let postureEquivDefaultRows = 200

/// Number of probe queries to run against each posture.
///
/// 50 probes across 200 rows is a meaningful sample. Each probe queries with
/// the row's own first-sentence content, and the top-k ranked result ID lists
/// are compared exactly. A divergence in any of the 50 probes is a detectable
/// retrieval regression.
let postureEquivDefaultProbes = 50

// ─── Report types ────────────────────────────────────────────────────────────

/// Per-probe divergence record: the two postures' ranked result ID lists for
/// one probe where the lists differed.
///
/// Present only for divergent probes; the `divergences` array is empty when
/// all probes agree — the expected result on a correctly-operating estate.
struct PostureEquivDivergence: Codable, Sendable {
    /// 0-based index of this probe in the run's probe list.
    let probeIndex: Int
    /// Top-k ranked result IDs returned by the plaintext estate.
    let plaintextRanks: [String]
    /// Top-k ranked result IDs returned by the encrypted estate.
    let encryptedRanks: [String]

    enum CodingKeys: String, CodingKey {
        case probeIndex      = "probe_index"
        case plaintextRanks  = "plaintext_ranks"
        case encryptedRanks  = "encrypted_ranks"
    }
}

/// Top-level posture-equivalence artifact.
///
/// Identity block only — no timing numbers, no machine state. This report
/// answers "did the two postures return identical top-k ranked lists?" not
/// "how fast did they do it?" The timing lane report carries the latency
/// figures; mixing them into an equivalence artifact would make the artifact
/// machine-dependent, which is exactly what the identity-only contract
/// prevents.
struct PostureEquivalenceReport: Codable, Sendable {
    /// Binary identity and protocol version. No machine metrics or load state.
    let runEnvironment: IdentityEnvironment
    /// RNG seed governing corpus generation. The first `rowsIngested` records
    /// of `timingLaneRecords(from:0 to:rowsIngested seed:seed)` form the estate.
    let seed: UInt64
    /// Rows ingested into the scratch estate before probing.
    let rowsIngested: Int
    /// Probe queries run against each posture (identical set for both).
    let probesCompared: Int
    /// Probes whose top-k ranked result lists were identical across postures.
    let identicalCount: Int
    /// Probes whose top-k ranked result lists differed between postures.
    let divergentCount: Int
    /// Full detail for each divergent probe. Empty when `divergentCount == 0`.
    let divergences: [PostureEquivDivergence]

    enum CodingKeys: String, CodingKey {
        case runEnvironment = "run_environment"
        case seed
        case rowsIngested   = "rows_ingested"
        case probesCompared = "probes_compared"
        case identicalCount = "identical_count"
        case divergentCount = "divergent_count"
        case divergences
    }
}

// ─── Top-k depth ─────────────────────────────────────────────────────────────

/// Ranked result depth per probe.
///
/// k = 10 matches the matrix lane's default and limits the per-divergence
/// payload in the artifact. The comparison is exact list equality at this
/// depth: two postures whose top-10 lists agree are equivalent at the
/// measured depth.
private let postureEquivTopK = 10

// ─── Probe pass ──────────────────────────────────────────────────────────────

/// Runs `probeCount` recall queries against one served estate and returns the
/// ranked result ID lists in probe order.
///
/// Query text is the first sentence of each row's content — the same strategy
/// the timing lane uses for its READ metric. This exercises the same recall
/// path without cherry-picking an exact substring. No additional estate
/// lookups are needed because the content is derivable from the row index and
/// the corpus seed, not from a UUID map.
///
/// - Parameters:
///   - client: Connected MCPClient for the estate under test.
///   - records: Ingested rows; the first `probeCount` entries provide queries.
///   - probeCount: Number of probes to run.
/// - Returns: One top-k ranked-ID list per probe, in probe order.
private func runPostureProbePass(
    client: MCPClient,
    records: [TimingSeedRecord],
    probeCount: Int
) async -> [[String]] {
    var resultLists: [[String]] = []
    for record in records.prefix(probeCount) {
        // First sentence of content: same extraction the timing READ metric uses.
        let query = String(record.content.split(separator: ".").first ?? "timing benchmark")
        let result = try? await client.callTool(
            AriaV2Surface.memorySearch,
            // v2: scope key for moot_memory_search is `wing` (v1 used `location`).
            arguments: [
                "query": .string(query),
                "wing":  .string(record.room),
            ],
            format: .mootV2,
            // Interactive tier: recall over a 200-row estate responds in
            // milliseconds; an unbounded deadline is not appropriate here.
            deadline: MCPDeadline.interactive)
        resultLists.append(Array((result?.orderedIDs ?? []).prefix(postureEquivTopK)))
    }
    return resultLists
}

// ─── Main entry point ─────────────────────────────────────────────────────────

/// Runs the posture-equivalence loop and writes a unique artifact.
///
/// Provisions a small scratch estate independent of the timing measurement
/// estate, ingests a seeded synthetic corpus, optionally converts it to an
/// encrypted twin, runs identical probe queries against both postures serially,
/// and compares ranked results exactly. A divergence in any probe's top-k list
/// indicates that at-rest encryption affected retrieval ordering.
///
/// A failure inside this loop does NOT abort the timing run — the timing report
/// was already written before this function is called. Callers should catch
/// errors and log them.
///
/// Under a non-keyfile build (`MOOTX01_HARNESS_KEYFILE` not defined) the
/// encrypted estate cannot be served because the server generates its own key
/// on startup and cannot open a database this harness converted. The loop
/// prints a notice and returns without writing an artifact.
///
/// - Parameters:
///   - mootBinary: Absolute path to the mootx01 binary.
///   - seed: RNG seed for the synthetic corpus.
///   - rowCount: Number of rows to ingest (default `postureEquivDefaultRows`).
///   - probeCount: Number of probe queries per posture (default
///     `postureEquivDefaultProbes`).
///   - args: Raw CLI argument list — used only to resolve the run serial via
///     `resolveRunSerial`. Passing the timing lane's own args keeps the serial
///     consistent across all artifacts of one pass.
///   - outDir: Optional output directory. When nil, writes to the current
///     working directory. Should match the timing lane's `--out`.
func runPostureEquivalenceLoop(
    mootBinary: String,
    seed: UInt64,
    rowCount: Int,
    probeCount: Int,
    args: [String],
    outDir: URL?
) async throws {
    FileHandle.standardOutput.write(Data((
        "[posture-equivalence] starting (\(rowCount) rows, \(probeCount) probes)...\n"
    ).utf8))

    // ── Provision plaintext estate ─────────────────────────────────────────
    let plainScratch = try lmeScratchDir(posture: .plaintextTransient)
    // loopCompleted gates teardown vs. keep-on-failure for the plaintext
    // estate. Both defer paths are synchronous; `await disconnect()` calls
    // happen before the defer fires.
    var loopCompleted = false
    defer {
        let scratch = plainScratch
        if loopCompleted { try? lmeGuardedTeardown(scratch) }
        else { keepScratchEstateOnFailure(scratch, lane: "posture-equiv-plain") }
    }

    let plainEndpoint = try lmeEndpointConfig(
        scratchDir: plainScratch,
        mootBinaryPath: mootBinary,
        posture: .plaintextTransient,
        shape: .disk)
    let plainClient = MCPClient(endpoint: plainEndpoint)
    try await plainClient.connect()

    // ── Ingest corpus ─────────────────────────────────────────────────────
    // Reuse the timing lane's deterministic corpus generator so the equivalence
    // estate is reproducible from the same seed as the timing run.
    let records = timingLaneRecords(from: 0, to: rowCount, seed: seed)
    let seedRecords = records.map { r in
        SeedFileRecord(id: r.id, content: r.content, eventTime: r.eventTime, room: r.room)
    }
    let seedData = emitSeedJSON(name: "posture-equiv", records: seedRecords)
    let seedURL = try writeSeedFile(seedData, in: plainScratch, name: "posture-equiv")

    let importResult = try await plainClient.callTool(
        AriaV2Surface.jsonImport,
        arguments: [
            "path": .string(seedURL.path),
            // v2: `mode` arg removed from moot_json_import; encode scheduling
            // is managed internally by the server. Requires vault capability.
        ],
        format: .mootV2,
        deadline: MCPDeadline.unbounded)
    // v2 surface: drawer count is in structuredContent.data.drawers_written.
    guard let written = importResult.drawersWritten, written == records.count else {
        throw MCPError(description:
            "posture-equivalence: moot_json_import did not confirm \(records.count) drawers "
            + "— got: "
            + (importResult.drawersWritten.map(String.init) ?? "(no structured data)"))
    }

    // Drain: all rows must be encoded before probing so ranked recall is stable.
    _ = await waitForEncodeDrain(client: plainClient, label: "posture-equiv-plain")

    // ── Plaintext probe pass ──────────────────────────────────────────────
    let plainResults = await runPostureProbePass(
        client: plainClient, records: records, probeCount: probeCount)

    // Disconnect plaintext server before creating the encrypted clone. The
    // estate directory must not be open by a running server while we copy it.
    await plainClient.disconnect()

#if MOOTX01_HARNESS_KEYFILE
    // ── Clone plaintext estate → encrypted scratch dir ────────────────────
    let encScratch: URL
    do {
        encScratch = try lmeScratchDir(posture: .encryptedEphemeral)
    } catch {
        throw MCPError(description:
            "posture-equivalence: could not create encrypted scratch dir: \(error)")
    }
    // encScratchCompleted gates teardown vs. keep-on-failure for the encrypted
    // estate, independently of loopCompleted. An error between these two defers
    // should keep the encrypted scratch for diagnosis while still marking the
    // plaintext scratch for teardown (set via loopCompleted at the very end).
    var encScratchCompleted = false
    defer {
        let scratch = encScratch
        if encScratchCompleted { try? lmeGuardedTeardown(scratch) }
        else { keepScratchEstateOnFailure(scratch, lane: "posture-equiv-enc") }
    }

    // Copy each item from the plaintext estate directory into the encrypted
    // scratch dir. `lmeScratchDir` already created encScratch; copy contents
    // into it rather than the directory itself.
    let fm = FileManager.default
    let plainContents = (try? fm.contentsOfDirectory(atPath: plainScratch.path)) ?? []
    for name in plainContents {
        let src = plainScratch.appendingPathComponent(name)
        let dst = encScratch.appendingPathComponent(name)
        // Remove a stale copy when present (should not occur for a fresh dir).
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.copyItem(at: src, to: dst)
    }

    // Convert every SQLite file in the cloned directory to encrypted in place.
    // The deterministic key means both this harness and the served binary agree
    // on which key to use (via writeInstallKey below).
    let key = matrixKey(seed: seed)
    _ = try convertScratchDirectoryToEncrypted(scratchDir: encScratch, key: key)

    // Write the key file so the server can open the converted database. Without
    // this the binary generates its own fresh key, tries to open a database
    // encrypted with a DIFFERENT key, and fails. This is the only place in the
    // posture-equivalence loop where MOOTX01_HARNESS_KEYFILE matters.
    try EstateEncryptionMigrator.writeInstallKey(key, inDirectory: encScratch)

    let encEndpoint = try lmeEndpointConfig(
        scratchDir: encScratch,
        mootBinaryPath: mootBinary,
        posture: .encryptedEphemeral,
        shape: .disk)
    let encClient = MCPClient(endpoint: encEndpoint)
    try await encClient.connect()

    // ── Encrypted probe pass ──────────────────────────────────────────────
    let encResults = await runPostureProbePass(
        client: encClient, records: records, probeCount: probeCount)

    await encClient.disconnect()
    encScratchCompleted = true

    // ── Compare ranked results ────────────────────────────────────────────
    // Compare pairwise: the same probe index must return the same top-k list
    // from both postures. A list mismatch is recorded as a divergence.
    let compared = min(plainResults.count, encResults.count)
    var identicalCount = 0
    var divergences: [PostureEquivDivergence] = []
    for i in 0..<compared {
        if plainResults[i] == encResults[i] {
            identicalCount += 1
        } else {
            divergences.append(PostureEquivDivergence(
                probeIndex: i,
                plaintextRanks: plainResults[i],
                encryptedRanks: encResults[i]))
        }
    }
    let divergentCount = compared - identicalCount

    // ── Write artifact ────────────────────────────────────────────────────
    // Pre-compute the serial so the filename and the stamped run_environment
    // block carry identical values (testname-arm-serial discipline, D1 fix).
    let postureEquivSerial = resolveRunSerial(args)
    var identity = IdentityEnvironment.collect(mootx01BinaryPath: mootBinary)
    stampTestIdentity(&identity,
                      test: "posture-equivalence",
                      arm: "disk",
                      serial: postureEquivSerial)
    let report = PostureEquivalenceReport(
        runEnvironment: identity,
        seed: seed,
        rowsIngested: rowCount,
        probesCompared: compared,
        identicalCount: identicalCount,
        divergentCount: divergentCount,
        divergences: divergences)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let jsonData = try encoder.encode(report)

    // Arm is "disk": both postures always use the disk backend. The arm names
    // the scope (disk-backed comparison), not which posture the comparison
    // favoured or whether they agreed.
    let filename = recordFilename(
        test: "posture-equivalence",
        arm: "disk",
        serial: postureEquivSerial)
    let reportURL: URL
    if let outDir {
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        reportURL = outDir.appendingPathComponent(filename)
    } else {
        reportURL = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent(filename)
    }
    try writeRecordNeverOverwrite(jsonData, to: reportURL)

    FileHandle.standardOutput.write(Data((
        "[posture-equivalence] \(compared) probes: "
        + "\(identicalCount) identical, \(divergentCount) divergent\n"
        + "[posture-equivalence] artifact: \(reportURL.path)\n"
    ).utf8))

    // Mark both estates for teardown.
    loopCompleted = true

#else
    // Without MOOTX01_HARNESS_KEYFILE the encrypted estate cannot be served.
    // The server generates its own key on startup and cannot open a database
    // this harness converted with a different key, so the encrypted probe pass
    // is not runnable.
    //
    // Print a notice so the timing run remains auditable about what ran, then
    // return without writing an artifact. The timing report is unaffected.
    FileHandle.standardOutput.write(Data((
        "[posture-equivalence] skipped: harness built without "
        + "MOOTX01_HARNESS_KEYFILE — encrypted estate cannot be served.\n"
        + "Rebuild with -Xswiftc -DMOOTX01_HARNESS_KEYFILE "
        + "(see Makefile target swift-harness) to enable the equivalence check.\n"
    ).utf8))
    loopCompleted = true
#endif
}
