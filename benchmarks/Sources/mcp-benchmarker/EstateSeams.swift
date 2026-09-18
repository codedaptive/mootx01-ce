import Foundation
import SQLite3

// Estate-lifecycle instrument seams (W2.5 Track R(c) closed-loop arm).
// Same environment-only seam family as MOOT_BENCH_RETRIEVAL_TOOL /
// MOOT_BENCH_UNIT_IDS (RetrievalCallSpec.swift): instrument extension
// points, not documented lane options; argv stays clean. Both hooks live
// in the SHARED estate lifecycle (restoreEstateCacheEntry /
// retireScratchEstate), so every lane gets them without per-runner wiring.
//
//   MOOT_BENCH_PROVISION_LANE_WEIGHTS
//       Path to a lane_weights JSON file (the quality-optimizer
//       `lane-weights` output, e.g. {"locus":1.4,"bm25":0.6,...}).
//       After a cache restore succeeds, the JSON is written into the
//       restored working estate's manifest under the optimizer-owned
//       `lane_weights` key — the R(b) provision seam the RecallDirector
//       reads with precedence shape-explicit > provisioned > 1.0. The
//       ORIGINAL cache artifact is never touched; only the scratch copy
//       is provisioned. A missing/unreadable file or a failed write is a
//       HARD error: a seam that silently didn't provision would measure
//       the wrong arm (same fail-loud rule as MOOT_BENCH_RETRIEVAL_ARGS).
//
//   MOOT_BENCH_PROVISION_RECALL_TUNING
//       Path to a recall_tuning JSON file (a JSON object carrying the
//       recall-tuning knobs the RecallDirector reads on the provisioned
//       estate, e.g. {"frontierK":128,...}).  After a cache restore
//       succeeds, the JSON is written into the restored working estate's
//       manifest under the `recall_tuning` key — the seam-sweepable
//       companion to MOOT_BENCH_PROVISION_LANE_WEIGHTS. The ORIGINAL
//       cache artifact is never touched; only the scratch copy is
//       provisioned. A missing/unreadable file, a non-JSON-object value,
//       or a failed write is a HARD error (same fail-loud rule as
//       MOOT_BENCH_PROVISION_LANE_WEIGHTS): a silently skipped provision
//       would measure the wrong arm. Called immediately after
//       provisionLaneWeightsSeam so both provisions happen before any
//       probe queries run.
//
//   MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER
//       Raw model-id string ("apple-nl-v1" or "neural-embed-v1"). Controls
//       which embedding-provider slot GLK wires at estate OPEN
//       (wireSubstores → applyProvisionedEmbeddingProvider). Vector
//       content for a slot is written at INDEXING time; it cannot be
//       backfilled into a fully-indexed estate by moot_reindex because
//       reindexMissing skips drawers already in indexedSourceIDs()
//       (GeniusLocusKit/Intake/EncodeIntake.swift ~line 457).
//
//       HARD-FAIL on any value outside the known-id set: GLK would
//       silently fall back to the default ensemble for an unknown id, so
//       the cell would measure defaults while labeled as the provisioned
//       arm. Currently accepted values: ["apple-nl-v1", "neural-embed-v1"].
//
//       BUILD PATH (cache miss or cache off) — two-session dance:
//         (a) preprovisionEmbeddingSlot() connects serve briefly to create
//             the estate (estate.sqlite with all schema tables incl. manifest).
//         (b) Disconnects (serve exits).
//         (c) Writes embedding_provider into the manifest via
//             provisionEmbeddingProviderSeam.
//         (d) Hard-fails if the key cannot be read back.
//         The caller then reconnects; mootx01's estate OPEN reads the
//         key and wires the NL slot before any corpus is indexed.
//         All four lane runners share this helper (not per-lane wiring).
//
//       RESTORE PATH (cache hit) — read-and-compare via
//       verifyEmbeddingProviderSeam:
//         A restored estate MUST already carry the matching key — it was
//         built with the slot wired. A restore-time write would mislabel
//         the arm (no vectors for the slot exist). The seam therefore
//         READS and COMPARES the manifest key against the env value:
//           match   → emit one provenance line, continue.
//           absent  → HARD ERROR naming the unit (estate was not built
//                     with the seam set; use build path first).
//           mismatch → HARD ERROR (wrong-provider estate in cache).
//
//       CACHE ISOLATION (assertEmbeddingProviderCacheDirIsolation):
//         When this seam is set and the cache is in use, the cache dir
//         path MUST contain the model-id string (e.g. "apple-nl-v1").
//         Provisioned and default estates must never share a cache dir —
//         a mixed cache poisons every future cross-arm comparison.
//
//       Manual smoke recipe (requires a real mootx01 binary):
//         MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER=apple-nl-v1 \
//         MOOTX01_BENCH_MIN_FREE_GB=0 \
//         benchmarker longmemeval ... --estate-cache reuse \
//           --cache-dir estate-cache-apple-nl-v1 --limit 1
//         Verify: estate.sqlite in the cache entry has
//         embedding_provider=apple-nl-v1 in its manifest table, and the
//         run log shows "[estate-seam] provisioned embedding_provider=..."
//         followed by "[estate-seam] preprovisionEmbeddingSlot: verified...".
//
//   MOOT_BENCH_KEEP_ESTATES_DIR
//       Directory to receive a copy of each working estate at retirement,
//       BEFORE teardown (named by the scratch dir's basename, which is
//       unique per unit). This is the trace-gathering half of the closed
//       loop: a traced pass runs with this set, then the optimizer's
//       `lane-weights` subcommand aggregates the kept estates'
//       recall_trace rows into the weights the next cell provisions.
//       Retirement (zero-residual-key verification) still runs on the
//       scratch itself. Copy failure is a loud stderr warning, not a run
//       failure — a lost keep-copy loses optimizer input, not measurement.
//
//   MOOT_BENCH_RUN_ANOMALY_SWEEP
//       When set to "1", after a cache restore the harness triggers the
//       anomaly sweep on the scratch estate BEFORE any probe queries run.
//       Mechanism: call moot_dream (associates=all) through the live MCP
//       client; confirm meta.status == "completed" in the v2 response —
//       the strongest available confirmation the dreaming cycle returned
//       successfully (see v2 note at the check below). A seam that
//       silently did nothing would
//       mislabel the arm (the decay matrix would reflect the pre-build
//       state, not a freshly rebuilt sweep); therefore this is a HARD
//       error when the sweep cannot be confirmed to have run.
//       Unlike MOOT_BENCH_PROVISION_LANE_WEIGHTS and
//       MOOT_BENCH_KEEP_ESTATES_DIR (which operate on the SQLite file and
//       can be called without a running serve process), this seam requires
//       a live MCP client and is called from the runner AFTER cache
//       restore and client connect, not from the shared estate-cache path.
//       The runner passes the connected MCPClient and a label string for
//       error messages. Called before the first probe query so the
//       refreshed matrix is in effect for all measurements.

/// Write the lane_weights manifest key into the restored working estate
/// when MOOT_BENCH_PROVISION_LANE_WEIGHTS is set. No-op when unset.
func provisionLaneWeightsSeam(into scratchDir: URL) throws {
    guard let file = ProcessInfo.processInfo.environment["MOOT_BENCH_PROVISION_LANE_WEIGHTS"],
          !file.isEmpty else { return }
    let json: String
    do {
        json = try String(contentsOfFile: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_LANE_WEIGHTS: cannot read \(file): \(error)")
    }
    // Validate it parses as a JSON object before writing — provisioning a
    // malformed value would make the director silently fall back to 1.0
    // and the cell would measure defaults while labeled as provisioned.
    guard let data = json.data(using: .utf8),
          (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] != nil
    else {
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_LANE_WEIGHTS: \(file) is not a JSON object")
    }

    let dbPath = scratchDir.appendingPathComponent("estate.sqlite").path
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
        sqlite3_close(db)
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_LANE_WEIGHTS: cannot open \(dbPath): \(message)")
    }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    let sql = "INSERT OR REPLACE INTO manifest(key, value) VALUES('lane_weights', ?1)"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_LANE_WEIGHTS: prepare failed on \(dbPath): "
            + String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(stmt) }
    // SQLITE_TRANSIENT: SQLite copies the bound text immediately.
    sqlite3_bind_text(stmt, 1, json, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(stmt) == SQLITE_DONE else {
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_LANE_WEIGHTS: write failed on \(dbPath): "
            + String(cString: sqlite3_errmsg(db)))
    }
    FileHandle.standardError.write(Data(
        "[estate-seam] provisioned lane_weights into \(dbPath)\n".utf8))
}

/// Write the recall_tuning manifest key into the restored working estate
/// when MOOT_BENCH_PROVISION_RECALL_TUNING is set. No-op when unset.
/// Exact mirror of provisionLaneWeightsSeam — env var path, JSON object
/// validation, SQLite INSERT OR REPLACE, stderr provenance, hard-fail on
/// any error — differing only in env var name and manifest key name.
func provisionRecallTuningSeam(into scratchDir: URL) throws {
    guard let file = ProcessInfo.processInfo.environment["MOOT_BENCH_PROVISION_RECALL_TUNING"],
          !file.isEmpty else { return }
    let json: String
    do {
        json = try String(contentsOfFile: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_RECALL_TUNING: cannot read \(file): \(error)")
    }
    // Validate it parses as a JSON object before writing — provisioning a
    // malformed value would make the director silently fall back to defaults
    // and the cell would measure defaults while labeled as provisioned.
    guard let data = json.data(using: .utf8),
          (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] != nil
    else {
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_RECALL_TUNING: \(file) is not a JSON object")
    }

    let dbPath = scratchDir.appendingPathComponent("estate.sqlite").path
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
        sqlite3_close(db)
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_RECALL_TUNING: cannot open \(dbPath): \(message)")
    }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    let sql = "INSERT OR REPLACE INTO manifest(key, value) VALUES('recall_tuning', ?1)"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_RECALL_TUNING: prepare failed on \(dbPath): "
            + String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(stmt) }
    // SQLITE_TRANSIENT: SQLite copies the bound text immediately.
    sqlite3_bind_text(stmt, 1, json, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(stmt) == SQLITE_DONE else {
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_RECALL_TUNING: write failed on \(dbPath): "
            + String(cString: sqlite3_errmsg(db)))
    }
    FileHandle.standardError.write(Data(
        "[estate-seam] provisioned recall_tuning into \(dbPath)\n".utf8))
}

/// Write the door_config manifest key into the restored working estate
/// when MOOT_BENCH_PROVISION_DOOR_CONFIG is set. No-op when unset.
/// Exact mirror of provisionRecallTuningSeam — env var path, JSON object
/// validation, SQLite INSERT OR REPLACE, stderr provenance, hard-fail on
/// any error — differing only in env var name and manifest key name.
///
/// The key is consumed by RecallDirector's front-door precedence chain as
/// the A1 per-corpus static config tier: when `door="guess"` is passed to
/// `moot_memory_search`, the director reads this key rather than defaulting
/// to `matrixAware`. The config file is operator-supplied via
/// `MOOT_BENCH_PROVISION_DOOR_CONFIG` (e.g. `{"scoring":"rrf"}`).
/// Called immediately after
/// provisionRecallTuningSeam so all three manifest provisions happen before
/// any probe queries run.
func provisionDoorConfigSeam(into scratchDir: URL) throws {
    guard let file = ProcessInfo.processInfo.environment["MOOT_BENCH_PROVISION_DOOR_CONFIG"],
          !file.isEmpty else { return }
    let json: String
    do {
        json = try String(contentsOfFile: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_DOOR_CONFIG: cannot read \(file): \(error)")
    }
    // Validate it parses as a JSON object before writing — provisioning a
    // malformed value would make the director silently fall back to matrixAware
    // and `door="guess"` would measure the default arm while labeled as the
    // provisioned arm.
    guard let data = json.data(using: .utf8),
          (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] != nil
    else {
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_DOOR_CONFIG: \(file) is not a JSON object")
    }

    let dbPath = scratchDir.appendingPathComponent("estate.sqlite").path
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
        sqlite3_close(db)
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_DOOR_CONFIG: cannot open \(dbPath): \(message)")
    }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    let sql = "INSERT OR REPLACE INTO manifest(key, value) VALUES('door_config', ?1)"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_DOOR_CONFIG: prepare failed on \(dbPath): "
            + String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(stmt) }
    // SQLITE_TRANSIENT: SQLite copies the bound text immediately.
    sqlite3_bind_text(stmt, 1, json, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(stmt) == SQLITE_DONE else {
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_DOOR_CONFIG: write failed on \(dbPath): "
            + String(cString: sqlite3_errmsg(db)))
    }
    FileHandle.standardError.write(Data(
        "[estate-seam] provisioned door_config into \(dbPath)\n".utf8))
}

/// Write the embedding_provider manifest key into the restored working estate
/// when MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER is set. No-op when unset.
///
/// The value must be a member of the known-id set (currently
/// `["apple-nl-v1", "neural-embed-v1"]`).
/// Any other value is a HARD error: GLK would silently fall back to the default
/// ensemble for an unknown id, so the cell would measure defaults while labeled
/// as the provisioned arm — exactly the mislabeled-arm hazard this seam family
/// exists to prevent.
///
/// BUILD-WINDOW USE ONLY. The embedding_provider key controls which slots are
/// wired at estate open; vector content for a slot is written at indexing
/// (ingest) time. A restored estate whose drawers were indexed without this
/// slot wired carries no vectors for it, regardless of the manifest key.
/// moot_reindex on a fully-indexed restored estate is a no-op for the new
/// slot because reindexMissing skips drawers already in indexedSourceIDs()
/// (a global BM25-indexed check; GeniusLocusKit/Intake/EncodeIntake.swift
/// ~line 457). Use this seam during the BUILD window (step 2e), not at
/// restore time.
func provisionEmbeddingProviderSeam(into scratchDir: URL) throws {
    guard let modelID = ProcessInfo.processInfo.environment["MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER"],
          !modelID.isEmpty else { return }

    // Validate against the known-id set before touching SQLite. GLK emits
    // an OSLog warning and silently falls back to defaults for unknown ids;
    // an undetected fallback would measure the default ensemble while the
    // cell is labeled as provisioned. Hard-fail here instead.
    let knownIDs: Set<String> = ["apple-nl-v1", "neural-embed-v1"]
    guard knownIDs.contains(modelID) else {
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER: '\(modelID)' is not a known "
            + "embedding provider id — known ids: \(knownIDs.sorted()). "
            + "GLK would silently fall back to defaults; hard-failing to prevent a "
            + "mislabeled arm.")
    }

    let dbPath = scratchDir.appendingPathComponent("estate.sqlite").path
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
        sqlite3_close(db)
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER: cannot open \(dbPath): \(message)")
    }
    // 5-second busy timeout: when called from the build-path two-session dance
    // (preprovisionEmbeddingSlot), serve may still hold the SQLite lock for a
    // brief window after disconnect() signals it to exit. The timeout retries
    // rather than failing immediately; a live server exits within milliseconds.
    sqlite3_busy_timeout(db, 5_000)
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    let sql = "INSERT OR REPLACE INTO manifest(key, value) VALUES('embedding_provider', ?1)"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER: prepare failed on \(dbPath): "
            + String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(stmt) }
    // SQLITE_TRANSIENT: SQLite copies the bound text immediately.
    sqlite3_bind_text(stmt, 1, modelID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(stmt) == SQLITE_DONE else {
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER: write failed on \(dbPath): "
            + String(cString: sqlite3_errmsg(db)))
    }
    FileHandle.standardError.write(Data(
        "[estate-seam] provisioned embedding_provider=\(modelID) into \(dbPath)\n".utf8))

    // Loud build-window reminder. This key only takes effect when the slot
    // is wired at estate OPEN. Vectors for the slot are computed at indexing
    // time, not at open time. A restored estate with fully-indexed content
    // gains no vectors for the provisioned slot from this key — use the
    // BUILD window (step 2e) so the slot is wired during ingest.
    FileHandle.standardError.write(Data(
        ("[estate-seam] NOTE: embedding_provider=\(modelID) takes effect when the "
        + "estate is opened. Vector content for this slot is produced at INDEXING "
        + "time. This seam is for BUILD-WINDOW use; it does NOT "
        + "backfill vectors into an already-indexed restored estate.\n").utf8))
}

/// Verify that a restored estate already carries the matching embedding_provider
/// key when MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER is set. No-op when unset.
///
/// This is the RESTORE-PATH companion to provisionEmbeddingProviderSeam.
/// A restored estate must have been built with the slot wired: vector content
/// for a slot is computed at indexing time, so a restore-time write would
/// produce an estate labeled as the provisioned arm but carrying no vectors
/// for it — a mislabeled arm. Therefore this seam READS and COMPARES instead
/// of writing.
///
/// Hard-fails when:
///   - The key is absent in the manifest (estate was not built with the seam
///     set; use the build path — set the env before ingestion, not at restore).
///   - The key is present but names a different provider (wrong-provider estate
///     is in the cache; delete it and rebuild with the correct model id).
/// A match emits one stderr provenance line and returns without writing anything.
func verifyEmbeddingProviderSeam(in scratchDir: URL) throws {
    guard let modelID = ProcessInfo.processInfo.environment["MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER"],
          !modelID.isEmpty else { return }

    let dbPath = scratchDir.appendingPathComponent("estate.sqlite").path
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
        sqlite3_close(db)
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER (restore-verify): "
            + "cannot open \(dbPath): \(message)")
    }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    let sql = "SELECT value FROM manifest WHERE key = 'embedding_provider'"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER (restore-verify): "
            + "prepare failed on \(dbPath): \(String(cString: sqlite3_errmsg(db)))")
    }
    defer { sqlite3_finalize(stmt) }

    guard sqlite3_step(stmt) == SQLITE_ROW else {
        // Key absent: estate was not built with the embedding slot wired. A
        // restore-time write would produce no vectors for the slot — hard fail
        // so the operator knows to rebuild with the seam set before ingestion.
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER=\(modelID) is set but the "
            + "restored estate at \(scratchDir.path) has no embedding_provider key "
            + "in its manifest. This estate was not built with the slot wired — "
            + "restore would produce a mislabeled arm with no vectors for the slot. "
            + "Build the artifacts with MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER set "
            + "before the ingestion window, then re-run.")
    }
    let stored = String(cString: sqlite3_column_text(stmt, 0))
    guard stored == modelID else {
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER=\(modelID) is set but the "
            + "restored estate at \(scratchDir.path) has "
            + "embedding_provider='\(stored)' — provider mismatch. "
            + "Delete the mismatched cache entry and rebuild with "
            + "MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER=\(modelID).")
    }
    FileHandle.standardError.write(Data(
        ("[estate-seam] embedding_provider=\(modelID) verified in restored estate "
        + "at \(scratchDir.path)\n").utf8))
}

/// When MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER is set and this is a fresh build
/// (cache miss or cache off), performs the two-session dance to ensure the
/// embedding_provider manifest key is present BEFORE any corpus is indexed:
///
/// (a) Creates a temporary MCPClient on `endpoint` and connects. mootx01 starts,
///     creates the full estate (estate.sqlite with all schema tables including
///     manifest). The MCP initialize handshake confirms the estate is open.
/// (b) Disconnects cleanly — serve sees stdin EOF and exits. The session Task
///     cancellation is a hard backstop. sqlite3_busy_timeout in
///     provisionEmbeddingProviderSeam handles the brief lock window.
/// (c) Writes the embedding_provider manifest key via provisionEmbeddingProviderSeam.
/// (d) Hard-fails if the key cannot be read back from the manifest — a silent write
///     failure must never produce a default-ensemble arm labeled as provisioned.
///
/// Returns so the caller can create a fresh MCPClient on the same `endpoint` and
/// connect again. On the second connect, mootx01's estate OPEN reads the manifest
/// key and wires the named embedding-provider slot before any corpus is ingested.
///
/// No-op when MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER is unset.
func preprovisionEmbeddingSlot(scratchDir: URL, endpoint: EndpointConfig) async throws {
    guard let modelID = ProcessInfo.processInfo.environment["MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER"],
          !modelID.isEmpty else { return }

    FileHandle.standardError.write(Data(
        ("[estate-seam] preprovisionEmbeddingSlot: starting initial serve connect "
        + "to create estate at \(scratchDir.path) "
        + "(will set embedding_provider=\(modelID) before reconnect)\n").utf8))

    // (a) Connect: serve starts, creates estate.sqlite with all schema tables.
    // The initialize handshake confirms the estate is open and ready.
    // MCPDeadline.handshake is unbounded — for an empty estate this returns
    // in milliseconds; the unbounded ceiling avoids a timing-based false failure.
    let initClient = MCPClient(endpoint: endpoint)
    do {
        try await initClient.connect()
    } catch {
        // Partial start cleanup: disconnect() is safe to call even if connect()
        // failed partway through (session Task cancellation is a no-op when
        // sessionTask is nil).
        await initClient.disconnect()
        throw MCPError(description:
            "preprovisionEmbeddingSlot: initial serve connect failed "
            + "(cannot create estate at \(scratchDir.path)): \(error)")
    }

    // (b) Disconnect: close stdin so serve exits gracefully. Session Task
    // cancellation is the hard backstop. sqlite3_busy_timeout in
    // provisionEmbeddingProviderSeam retries for up to 5 s if serve holds
    // the SQLite lock during its shutdown window.
    await initClient.disconnect()

    // (c) Write the embedding_provider manifest key. provisionEmbeddingProviderSeam
    // validates the model id against the known set and hard-fails on mismatch.
    try provisionEmbeddingProviderSeam(into: scratchDir)

    // (d) Read back the key to confirm the write succeeded. A silent write
    // failure must never reach the reconnect step — the reconnected serve
    // would open without the slot wired and produce a mislabeled arm.
    let dbPath = scratchDir.appendingPathComponent("estate.sqlite").path
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
        sqlite3_close(db)
        throw MCPError(description:
            "preprovisionEmbeddingSlot: cannot open \(dbPath) for verification: \(message)")
    }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    let verifySql = "SELECT value FROM manifest WHERE key = 'embedding_provider'"
    guard sqlite3_prepare_v2(db, verifySql, -1, &stmt, nil) == SQLITE_OK else {
        throw MCPError(description:
            "preprovisionEmbeddingSlot: verify-read prepare failed on \(dbPath): "
            + String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else {
        throw MCPError(description:
            "preprovisionEmbeddingSlot: embedding_provider key absent from manifest "
            + "after write at \(dbPath) — cannot reconnect with provisioned arm")
    }
    let stored = String(cString: sqlite3_column_text(stmt, 0))
    guard stored == modelID else {
        throw MCPError(description:
            "preprovisionEmbeddingSlot: manifest has embedding_provider='\(stored)' "
            + "but expected '\(modelID)' at \(dbPath) — cannot reconnect with provisioned arm")
    }

    FileHandle.standardError.write(Data(
        ("[estate-seam] preprovisionEmbeddingSlot: verified embedding_provider=\(modelID) "
        + "at \(dbPath); caller will reconnect with NL slot wired for ingestion\n").utf8))
}

/// When MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER is set and the estate cache is in
/// use, hard-fails unless the cache directory path contains the model-id string.
/// Provisioned and default estates must never share a cache dir — a mixed cache
/// poisons every future cross-arm comparison.
///
/// Example: MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER=apple-nl-v1 requires the
/// cache dir path to contain "apple-nl-v1" (e.g. "estate-cache-apple-nl-v1").
/// The check is on the path string, not on directory contents — the operator
/// chooses the name; the harness verifies it encodes the model id so a default
/// path ("estate-cache") cannot accidentally accumulate provisioned estates.
///
/// No-op when MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER is unset.
func assertEmbeddingProviderCacheDirIsolation(cacheDir: URL) throws {
    guard let modelID = ProcessInfo.processInfo.environment["MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER"],
          !modelID.isEmpty else { return }

    guard cacheDir.path.contains(modelID) else {
        throw MCPError(description:
            "MOOT_BENCH_PROVISION_EMBEDDING_PROVIDER=\(modelID) is set but the "
            + "cache directory path '\(cacheDir.path)' does not contain '\(modelID)'. "
            + "Provisioned and default estates must use separate cache directories "
            + "to prevent cross-arm contamination. "
            + "Pass --cache-dir with a path containing '\(modelID)' "
            + "(e.g. estate-cache-\(modelID)).")
    }
}

/// Trigger the anomaly sweep (moot_dream associates=all) when
/// MOOT_BENCH_RUN_ANOMALY_SWEEP=1. Called after cache restore and client
/// connect, BEFORE probe queries. Hard-fails if the sweep cannot be confirmed
/// to have run — a silently skipped sweep would mislabel the arm (the rebuild
/// matrix must be live for all measurements in the unit).
///
/// - Parameters:
///   - client: A connected MCPClient pointing at the scratch estate's serve process.
///   - label: A short run identifier used in error messages.
/// - Throws: `MCPError` when the sweep cannot be confirmed. On the v2 surface
///   this checks `result.metaStatus == "completed"`, which proves the dreaming
///   cycle returned successfully but does NOT guarantee a matrix rebuild.
func anomalySweepSeam(client: MCPClient, label: String) async throws {
    guard ProcessInfo.processInfo.environment["MOOT_BENCH_RUN_ANOMALY_SWEEP"] == "1" else {
        return
    }
    // moot_dream runs the full dreaming pass including co-occurrence rebuild
    // and association sweeps. No `now:` argument — the estate clock is what
    // the serve process sees; passing a fake `now` to an already-built estate
    // would skew the decay math. associates=all triggers the full sweep.
    let result = try await client.callTool(
        "moot_dream",
        arguments: ["associates": .string("all")],
        format: .mootV2,
        deadline: MCPDeadline.bulk)
    // v2 surface: the "matrix rebuilt" text signal was removed. The strongest
    // available confirmation is meta.status == "completed", which proves the
    // dreaming cycle returned successfully. It does NOT prove a matrix rebuild
    // occurred — that confirmation is unavailable on the v2 surface. The
    // anomaly sweep guard is weaker than it was on v1; the operator should
    // treat this as "dream completed" rather than "matrix was rebuilt".
    guard result.metaStatus == "completed" else {
        throw MCPError(description:
            "MOOT_BENCH_RUN_ANOMALY_SWEEP: moot_dream did not complete "
            + "(meta.status: \(result.metaStatus ?? "nil")) — "
            + "the anomaly sweep cannot be confirmed to have run on \(label).")
    }
    FileHandle.standardError.write(Data(
        "[estate-seam] anomaly sweep (moot_dream associates=all) confirmed on \(label)\n"
            .utf8))
}

/// Copy the working estate to MOOT_BENCH_KEEP_ESTATES_DIR before teardown
/// so a traced pass leaves per-unit estates for the optimizer's
/// `lane-weights` aggregation. No-op when unset.
func keepEstateSeam(from scratchDir: URL) {
    guard let dir = ProcessInfo.processInfo.environment["MOOT_BENCH_KEEP_ESTATES_DIR"],
          !dir.isEmpty else { return }
    let fm = FileManager.default
    let destination = URL(fileURLWithPath: dir)
        .appendingPathComponent(scratchDir.lastPathComponent)
    do {
        try fm.createDirectory(
            at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: scratchDir, to: destination)
        FileHandle.standardError.write(Data(
            "[estate-seam] kept estate copy at \(destination.path)\n".utf8))
    } catch {
        // A lost keep-copy loses optimizer INPUT, not measurement — warn
        // loudly and let retirement continue.
        FileHandle.standardError.write(Data(
            "[estate-seam] WARNING: keep-copy to \(destination.path) failed: \(error)\n".utf8))
    }
}

/// Resolves the estate database inside an estate directory. Swift-built
/// estates keep `estate.sqlite` at the root; Rust-built estates keep it at
/// `databases/default/estate.sqlite`. The root wins when both exist. nil
/// when neither exists (fixture snapshots, non-estate payloads).
func estateDatabasePath(in estateDir: URL) -> String? {
    let root = estateDir.appendingPathComponent("estate.sqlite").path
    if FileManager.default.fileExists(atPath: root) { return root }
    let nested = estateDir.appendingPathComponent("databases/default/estate.sqlite").path
    if FileManager.default.fileExists(atPath: nested) { return nested }
    return nil
}


