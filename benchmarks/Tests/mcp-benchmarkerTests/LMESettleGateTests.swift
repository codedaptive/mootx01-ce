import Testing
import Foundation
@testable import mcp_benchmarker

// LMESettleGateTests.swift — mock-driven end-to-end tests for the settle-gate
// invariant across three benchmark lanes: LME, MemBench, and LMEB.
//
// Invariant under test (all lanes): the settle calls (moot_dream and
// moot_reindex) are uncaught `try await` expressions inside an `async throws`
// function. A failure from either call throws BEFORE saveEstateCacheEntry is
// reached, so an unsettled estate can never reach the artifact cache. Each test
// drives a complete per-unit run through a mock MCP binary that returns a
// JSON-RPC error for moot_dream, then asserts that (a) the entry-point function
// throws and (b) no cache artifact is written to the cache directory.
//
// Each lane minimises MCP traffic before moot_dream:
//   LME:      encodeBarrier: .none, seedPath: .live, haystackSessions: []
//   MemBench: encodeBarrier: .none, seedPath: .live, sessions: []
//   LMEB:     encodeBarrier: .none, seedPath: .live, candidateDocIDs: [] (empty corpus)
//
// The mock binary is a Python 3 script written to /tmp at test time and
// removed in a defer block. All three suites share writeSettleGateMock() —
// a module-level helper — to ensure the mock logic stays consistent.
//
// The mock handles:
//   --version            prints a version string (called by mootBinaryVersion)
//   initialize           returns a valid MCP capability response
//   moot_dream           returns a JSON-RPC error (settle failure under test)
//   moot_drain_status    returns "drains: none" (Shape A), so waitForEncodeDrain
//                        can converge during the non-vacuity probe without
//                        calling exit(1). In the normal (dream-fails) path,
//                        this handler is never reached.
//   all other tools      return a minimal success response

// MARK: - Shared mock helper

/// Writes an executable Python MCP mock server to a unique /tmp path.
///
/// The mock injects a JSON-RPC error for `moot_dream`, returns the Shape A
/// drain-status response ("drains: none") for `moot_drain_status`, and
/// returns minimal success for every other tool call.
///
/// Called by all three settle-gate test suites. The unique path avoids
/// collisions when the test suite runs under Swift Testing's parallel executor.
private func writeSettleGateMock() throws -> URL {
    let path = "/tmp/moot-mock-settle-gate-\(UUID().uuidString)"
    let script = """
        #!/usr/bin/env python3
        import sys, json

        # Version probe from mootBinaryVersion() — not an MCP call.
        if "--version" in sys.argv:
            print("0.0.0-settle-gate-mock")
            sys.exit(0)

        # MCP server mode: read newline-delimited JSON-RPC from stdin,
        # write responses to stdout, flush after each line.
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except Exception:
                continue
            req_id = req.get("id")
            method = req.get("method", "")
            if method == "initialize":
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "protocolVersion": "2024-11-05",
                        "capabilities": {},
                        "serverInfo": {"name": "settle-gate-mock", "version": "0.0.0"}
                    }
                }
            elif method == "tools/call":
                tool_name = req.get("params", {}).get("name", "")
                if tool_name == "moot_dream":
                    # Inject a settle failure — this is the error the test
                    # expects to propagate and abort the run before the cache save.
                    resp = {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "error": {
                            "code": -32000,
                            "message": "settle-gate-mock: moot_dream failure (injected by test)"
                        }
                    }
                elif tool_name == "moot_drain_status":
                    # Shape A drain response: "drains: none". waitForEncodeDrain
                    # treats this as ambiguous and accepts it after the grace
                    # window (minConsecutiveNoLanes polls + minSeconds elapsed).
                    # This handler is never reached in the normal (dream-fails)
                    # path; it is present so the non-vacuity probe completes
                    # instead of calling exit(1) on an unparseable response.
                    resp = {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {"content": [{"type": "text", "text": "drains: none"}]}
                    }
                else:
                    # All other tools succeed with a minimal payload.
                    resp = {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {"content": [{"type": "text", "text": "ok"}]}
                    }
            else:
                resp = {"jsonrpc": "2.0", "id": req_id, "result": {}}
            sys.stdout.write(json.dumps(resp) + "\\n")
            sys.stdout.flush()
        """
    let url = URL(fileURLWithPath: path)
    try script.write(to: url, atomically: true, encoding: .utf8)
    // chmod +x so the runner can launch it directly.
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755 as NSNumber],
        ofItemAtPath: path
    )
    return url
}

// MARK: - LME lane

@Suite("LME settle-gate — mock-binary end-to-end")
struct LMESettleGateTests {

    /// Pins the settle-gate invariant for the LongMemEval lane: a moot_dream
    /// failure throws before saveEstateCacheEntry is reached, so no artifact is
    /// written to the cache directory.
    ///
    /// Breaking this invariant (e.g. by wrapping moot_dream in a do/catch that
    /// swallows the error) would allow an unsettled estate to reach the artifact
    /// cache. A future run restoring that artifact would then measure a broken
    /// baseline silently.
    @Test("moot_dream failure in LME lane throws before writing cache artifact")
    func dreamFailureThrowsBeforeCacheSave() async throws {
        let mockBinary = try writeSettleGateMock()
        defer { try? FileManager.default.removeItem(at: mockBinary) }

        // Dedicated cache dir. Must be empty before the run; if saveEstateCacheEntry
        // were ever called it would create subdirectories and a manifest.json here.
        let cacheDirPath = "/tmp/lme-settle-gate-cache-\(UUID().uuidString)"
        let cacheDir = URL(fileURLWithPath: cacheDirPath)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        // Build config:
        //   estateCache: .reuse  — on a cache miss sets cacheEntryForSnapshot,
        //                          so saveEstateCacheEntry WOULD be called if
        //                          the settle gate were absent.
        //   encodeBarrier: .none — no moot_drain_status polling before settle.
        var config = LMERunConfig(
            mootBinaryPath: mockBinary.path,
            datasetPath: URL(fileURLWithPath: "/tmp/does-not-exist.json"),
            variant: "s",
            limit: 1,
            offset: 0,
            seed: 42,
            outDir: nil,
            runLabel: "settle-gate-test",
            arm: .exact,
            judgeCmd: nil,
            judgeGrading: .substring,
            judgeHydrationDepth: 1,
            recallShape: nil,
            encodeBarrier: .none,
            estateCache: .reuse,
            cacheDir: cacheDir,
            scratchPosture: .plaintextTransient,
            exactStrategy: .search,
            settle: false,
            rerankCmd: nil,
            synthesizeArm: false,
            synthesizeLimit: nil,
            dumpJudgeInputsPath: nil,
            slice: nil
        )
        // Live seed path: no moot_json_import call. Combined with an empty
        // haystackSessions below, the only MCP calls the runner issues are
        // the initialize handshake (via connect()) and moot_dream.
        config.seedPath = .live

        // Minimal question with empty haystack: no ingest, no moot_file_memory.
        let question = LMEQuestion(
            questionID: "settle-gate-q-001",
            questionType: "single_hop",
            question: "What is the settle invariant?",
            answer: "Settle failures throw before save.",
            questionDate: "2023/01/01 (Sun) 00:00",
            haystackDates: [],
            haystackSessionIDs: [],
            haystackSessions: [],
            answerSessionIDs: []
        )

        // The runner must throw because moot_dream returns a JSON-RPC error.
        // The throw propagates via the uncaught `try await` on callTool through
        // runFreshQuestion → runLMEQuestions — no do/catch swallows it.
        var threwAsExpected = false
        do {
            _ = try await runLMEQuestions(questions: [question], config: config)
        } catch {
            threwAsExpected = true
        }
        #expect(threwAsExpected,
                "runLMEQuestions should throw when moot_dream returns a JSON-RPC error")

        // No cache artifact should exist. saveEstateCacheEntry creates files
        // inside a subdirectory of cacheDir on success. If the settle gate
        // holds, the save is never reached and cacheDir stays empty.
        let cacheContents = (try? FileManager.default.contentsOfDirectory(
            atPath: cacheDirPath
        )) ?? []
        #expect(
            cacheContents.isEmpty,
            "cache dir must be empty after a moot_dream failure (settle-gate broken if non-empty)"
        )
    }
}

// MARK: - MemBench lane

@Suite("MemBench settle-gate — mock-binary end-to-end")
struct MemBenchSettleGateTests {

    /// Pins the settle-gate invariant for the MemBench lane: a moot_dream
    /// failure inside runOneMemBenchItem throws before saveEstateCacheEntry is
    /// reached, so no artifact is written to the cache directory.
    ///
    /// The settle calls (moot_dream, moot_reindex) are uncaught `try await`
    /// expressions inside the !skipIngest block of runOneMemBenchItem. Any
    /// caller that wraps them in a do/catch swallowing the error reopens the
    /// hole: an unsettled estate would reach the cache, and future runs
    /// restoring it would silently measure a broken baseline.
    @Test("moot_dream failure in MemBench lane throws before writing cache artifact")
    func dreamFailureThrowsBeforeCacheSave() async throws {
        let mockBinary = try writeSettleGateMock()
        defer { try? FileManager.default.removeItem(at: mockBinary) }

        // Dedicated cache dir. Must be empty before the run; saveEstateCacheEntry
        // creates subdirectories here on success.
        let cacheDirPath = "/tmp/membench-settle-gate-cache-\(UUID().uuidString)"
        let cacheDir = URL(fileURLWithPath: cacheDirPath)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        // Build config:
        //   estateCache: .reuse  — cache miss sets cacheEntryForSnapshot so
        //                          saveEstateCacheEntry WOULD be called if the
        //                          settle gate were absent.
        //   encodeBarrier: .none — no pre-settle moot_drain_status polling.
        //   seedPath: .live      — live per-turn writes; with sessions: [] below,
        //                          zero moot_file_memory calls are issued.
        //   limit: 1             — process exactly one item.
        let config = MemBenchRunConfig(
            mootBinaryPath: mockBinary.path,
            dataDir: URL(fileURLWithPath: "/tmp/does-not-exist"),
            agent: "FirstAgent",
            categories: nil,
            limit: 1,
            offset: 0,
            seed: 42,
            outDir: nil,
            runLabel: "settle-gate-membench",
            encodeBarrier: .none,
            scratchPosture: .plaintextTransient,
            categoryFilter: nil,
            seedPath: .live,
            guardSamplingPolicy: .oncePerLeg,
            estateCache: .reuse,
            cacheDir: cacheDir,
            corpusDigest: "unknown",
            shape: .disk,
            parallelUnits: 1,
            estateGrouping: .perItem,
            capacityTier: .baseline
        )

        // Minimal item with empty sessions: the live ingest path iterates over
        // sessions (empty here) so no moot_file_memory calls are issued. The
        // runner proceeds directly to the settle block (moot_dream) after ingest.
        let item = MemBenchItem(
            itemID: "FirstAgent/simple/settle-gate/0",
            category: "simple",
            agent: "FirstAgent",
            topicKey: "settle-gate",
            tid: 0,
            sessions: [],
            qa: MemBenchQA(
                qid: 0,
                question: "What is the settle invariant?",
                answer: "Settle failures throw before save.",
                targetStepID: [],
                choices: ["A": "correct", "B": "wrong"],
                groundTruth: "A",
                time: "2023/01/01 00:00"
            )
        )

        // The runner must throw: moot_dream returns a JSON-RPC error, propagated
        // via the uncaught `try await` through runOneMemBenchItem →
        // runMemBenchItems — no do/catch swallows it.
        var threwAsExpected = false
        do {
            _ = try await runMemBenchItems(items: [item], config: config)
        } catch {
            threwAsExpected = true
        }
        #expect(threwAsExpected,
                "runMemBenchItems should throw when moot_dream returns a JSON-RPC error")

        // No cache artifact should exist. saveEstateCacheEntry creates files
        // inside a subdirectory of cacheDir on success. The settle gate holds
        // when cacheDir is still empty after the run.
        let cacheContents = (try? FileManager.default.contentsOfDirectory(
            atPath: cacheDirPath
        )) ?? []
        #expect(
            cacheContents.isEmpty,
            "cache dir must be empty after a moot_dream failure (settle-gate broken if non-empty)"
        )
    }
}

// MARK: - LMEB lane

@Suite("LMEB settle-gate — mock-binary end-to-end")
struct LMEBSettleGateTests {

    /// Pins the settle-gate invariant for the LMEB lane: a moot_dream failure
    /// inside runOneLMEBQuery throws before saveEstateCacheEntry is reached, so
    /// no artifact is written to the cache directory.
    ///
    /// The settle calls (moot_dream, moot_reindex) are uncaught `try await`
    /// expressions inside the !skipIngest block of runOneLMEBQuery. Any caller
    /// that wraps them in a do/catch swallowing the error reopens the hole: an
    /// unsettled estate would reach the cache, and future runs restoring it
    /// would silently measure a broken baseline.
    @Test("moot_dream failure in LMEB lane throws before writing cache artifact")
    func dreamFailureThrowsBeforeCacheSave() async throws {
        let mockBinary = try writeSettleGateMock()
        defer { try? FileManager.default.removeItem(at: mockBinary) }

        // Dedicated cache dir. Must be empty before the run; saveEstateCacheEntry
        // creates subdirectories here on success.
        let cacheDirPath = "/tmp/lmeb-settle-gate-cache-\(UUID().uuidString)"
        let cacheDir = URL(fileURLWithPath: cacheDirPath)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        // Build config:
        //   estateCache: .reuse  — cache miss sets cacheEntryForSnapshot so
        //                          saveEstateCacheEntry WOULD be called if the
        //                          settle gate were absent.
        //   encodeBarrier: .none — no pre-settle moot_drain_status polling.
        //   seedPath: .live      — live per-doc writes; with an empty corpus
        //                          candidatesBySceneID below, zero moot_file_memory
        //                          calls are issued.
        //   limit: 1             — process exactly one query.
        var config = LMEBRunConfig(
            mootBinaryPath: mockBinary.path,
            dataDir: URL(fileURLWithPath: "/tmp/does-not-exist"),
            evidenceTypes: [],
            limit: 1,
            offset: 0,
            seed: 42,
            outDir: nil,
            runLabel: "settle-gate-lmeb",
            encodeBarrier: .none,
            estateCache: .reuse,
            cacheDir: cacheDir,
            scratchPosture: .plaintextTransient,
            judgeCmd: nil,
            judgeGrading: .substring,
            judgeHydrationDepth: 1,
            dumpJudgeInputsPath: nil
        )
        // Live seed path: no moot_json_import call. With an empty candidatesBySceneID
        // in the corpus below, the live ingest loop iterates over zero candidate
        // docs and issues no moot_file_memory calls. The runner proceeds directly
        // to the settle block (moot_dream) after the empty ingest.
        config.seedPath = .live

        // Minimal query. The scene_0 prefix lets candidateDocs(forQuery:) derive
        // scene_0 as the scene ID; the corpus has no entry for that scene, so
        // candidateDocIDs is empty.
        let query = LMEBQuery(
            id: "scene_0_q_0",
            text: "What is the settle invariant?",
            answer: nil
        )

        // Empty corpus: candidatesBySceneID has no entry for "scene_0", so
        // candidateDocs(forQuery:) returns [] — zero ingest calls before settle.
        let corpus = LMEBCorpus(
            docsByID: [:],
            queriesByID: [:],
            candidatesBySceneID: [:],
            relevantDocsByQueryID: [:]
        )

        // The runner must throw: moot_dream returns a JSON-RPC error, propagated
        // via the uncaught `try await` through runOneLMEBQuery →
        // runLMEBQueries — no do/catch swallows it.
        var threwAsExpected = false
        do {
            _ = try await runLMEBQueries(queries: [query], corpus: corpus, config: config)
        } catch {
            threwAsExpected = true
        }
        #expect(threwAsExpected,
                "runLMEBQueries should throw when moot_dream returns a JSON-RPC error")

        // No cache artifact should exist. saveEstateCacheEntry creates files
        // inside a subdirectory of cacheDir on success. The settle gate holds
        // when cacheDir is still empty after the run.
        let cacheContents = (try? FileManager.default.contentsOfDirectory(
            atPath: cacheDirPath
        )) ?? []
        #expect(
            cacheContents.isEmpty,
            "cache dir must be empty after a moot_dream failure (settle-gate broken if non-empty)"
        )
    }
}
