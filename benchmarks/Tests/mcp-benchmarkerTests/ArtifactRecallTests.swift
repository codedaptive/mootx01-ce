import Testing
import Foundation
import SQLite3
@testable import mcp_benchmarker

// ArtifactRecallTests — pure-logic coverage for the artifact-recall lane
// (two-form benchmark artifacts, LoCoMo lane). No live serve: these tests
// exercise the id-map loader, the scoring math, and the question
// loading/filtering — the three seams the live runner composes.
//
// The scoring vectors here are LITERAL twins of the Rust unit test in
// benchmarks/rust/src/artifact_recall.rs (dual-port conformance: same inputs,
// same expected hit@k / MRR values, asserted in both ports).

@Suite("Artifact recall")
struct ArtifactRecallTests {

    // ── id-map load ─────────────────────────────────────────────────────────

    @Test func idMapLoadsAndReverses() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-recall-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let json = """
        {"conv-26/S1": "AAAAAAAA-0000-0000-0000-000000000001",
         "conv-26/S2": "AAAAAAAA-0000-0000-0000-000000000002"}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("id-map.json"))

        let map = try loadArtifactIDMap(estateDir: dir)
        #expect(map.count == 2)
        #expect(map["conv-26/S1"] == "AAAAAAAA-0000-0000-0000-000000000001")

        // Reverse map keys are lowercased so serve-returned UUIDs match
        // regardless of case.
        let reverse = artifactReverseIDMap(map)
        #expect(reverse["aaaaaaaa-0000-0000-0000-000000000002"] == "conv-26/S2")
    }

    @Test func idMapMissingErrorsClearly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-recall-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: MCPError.self) {
            _ = try loadArtifactIDMap(estateDir: dir)
        }
    }

    // ── Scoring math (literal twin of the Rust scoring_math_parity test) ────

    @Test func scoringMath() {
        // Vector 1: expected id at rank 1 → hit, RR 1.0.
        let s1 = scoreArtifactQuestion(
            rankedSeedIDs: ["conv-26/S1", "conv-26/S2", "conv-26/S3"],
            expected: ["conv-26/S1"], k: 3)
        #expect(s1.hitAtK == true)
        #expect(s1.reciprocalRank == 1.0)

        // Vector 2: expected id at rank 3 → hit@3, RR 1/3.
        let s2 = scoreArtifactQuestion(
            rankedSeedIDs: ["conv-26/S9", "conv-26/S8", "conv-26/S2"],
            expected: ["conv-26/S2", "conv-26/S4"], k: 3)
        #expect(s2.hitAtK == true)
        #expect(abs(s2.reciprocalRank - 1.0 / 3.0) < 1e-12)

        // Vector 3: expected id at rank 4, k=3 → NO hit@3, but RR still 1/4
        // (MRR is computed over the full returned list, hit@k over the top k).
        let s3 = scoreArtifactQuestion(
            rankedSeedIDs: ["a", "b", "c", "conv-26/S5"],
            expected: ["conv-26/S5"], k: 3)
        #expect(s3.hitAtK == false)
        #expect(abs(s3.reciprocalRank - 0.25) < 1e-12)

        // Vector 4: no expected id anywhere → miss, RR 0.
        let s4 = scoreArtifactQuestion(
            rankedSeedIDs: ["a", "b"], expected: ["conv-26/S1"], k: 3)
        #expect(s4.hitAtK == false)
        #expect(s4.reciprocalRank == 0.0)
    }

    @Test func rankedUUIDMappingDedupes() {
        let reverse = [
            "aaaaaaaa-0000-0000-0000-000000000001": "conv-26/S1",
            "aaaaaaaa-0000-0000-0000-000000000002": "conv-26/S2",
        ]
        // Two UUIDs mapping to the same seed id keep only the FIRST rank;
        // an unmapped UUID keeps its rank slot (it is a real result that is
        // not the answer) under an "unmapped:" sentinel.
        let ranked = artifactMapRankedUUIDs(
            ["AAAAAAAA-0000-0000-0000-000000000001",
             "BBBBBBBB-0000-0000-0000-000000000009",
             "aaaaaaaa-0000-0000-0000-000000000001",
             "AAAAAAAA-0000-0000-0000-000000000002"],
            reverse: reverse)
        #expect(ranked == ["conv-26/S1",
                           "unmapped:bbbbbbbb-0000-0000-0000-000000000009",
                           "conv-26/S2"])
    }

    // ── Question loading / filtering ────────────────────────────────────────

    @Test func questionLoadingAndFiltering() throws {
        let jsonl = """
        {"sample_id": "conv-26", "wing": "Caroline & Melanie", "question": "When did Caroline go?", "answer": "7 May 2023", "category": 2, "evidence_dia_ids": ["D1:3"], "answer_session_ids": ["conv-26/S1"]}
        {"sample_id": "conv-26", "wing": "Caroline & Melanie", "question": "", "question_3p": "What did Melanie paint?", "answer": 2022, "category": 2, "evidence_dia_ids": ["D1:12"], "answer_session_ids": ["conv-26/S2"]}
        {"sample_id": "conv-26", "wing": "Caroline & Melanie", "question": "Adversarial: unanswerable", "answer": "n/a", "category": 5, "evidence_dia_ids": [], "answer_session_ids": []}
        """
        let all = try loadArtifactRecallQuestions(jsonl: jsonl, dataset: .locomo)
        #expect(all.count == 3)
        // question_3p wins when non-empty; "question" is the fallback
        // (priority reversed from the LoCoMo-only code — aggregate estates
        // measure third-person text everywhere it exists).
        #expect(all[1].question == "What did Melanie paint?")
        // Non-string answers (2022) must not break the loader — answer is not
        // used for scoring, so the loader ignores its type entirely.
        #expect(all[0].label == "2")
        // LoCoMo unit stem = sample_id (units/<sample_id>.json).
        #expect(all[0].unitStem == "conv-26")

        // Empty answer_session_ids → excluded from scoring, counted separately.
        let split = partitionArtifactQuestions(all)
        #expect(split.scored.count == 2)
        #expect(split.noEvidence == 1)

        // --limit 1 keeps the first scored question only; limit 0 = all.
        #expect(applyArtifactLimit(split.scored, limit: 1).count == 1)
        #expect(applyArtifactLimit(split.scored, limit: 0).count == 2)
    }

    // ── Per-dataset question adapters (#94) ─────────────────────────────────
    // One literal row per dataset, mirrored verbatim in the Rust twin
    // (question_adapter_parity in artifact_recall.rs).

    @Test func convomemAdapter() throws {
        let jsonl = """
        {"set": "user_evidence", "query_id": "scene_0_q_0", "persona": "Alex Calder", "wing": "Alex Calder", "question": "What furniture?", "question_3p": "Alex asks what furniture?", "answer_session_ids": ["user_evidence/scene_0_session_1"], "candidate_session_ids": ["user_evidence/scene_0_session_1"]}
        """
        let q = try #require(try loadArtifactRecallQuestions(
            jsonl: jsonl, dataset: .convomem).first)
        // Third-person text wins when present.
        #expect(q.question == "Alex asks what furniture?")
        #expect(q.sampleID == "user_evidence/scene_0_q_0")
        // Unit stem = units/<set>__scene_<n>.json.
        #expect(q.unitStem == "user_evidence__scene_0")
        #expect(q.wing == "Alex Calder")
        #expect(q.label == "user_evidence")
        #expect(q.answerSessionIDs == ["user_evidence/scene_0_session_1"])
    }

    @Test func membenchAdapter() throws {
        let jsonl = """
        {"family": "FirstAgent", "category": "aggregative", "section": "roles", "tid": "0", "persona": "Alex Calder", "wing": "Alex Calder", "question": "How many people?", "question_3p": "How many people?", "answer": "2 people", "choices": {"A": "2 people"}, "answer_drawer_ids": ["FirstAgent/aggregative/roles/0/brother-0"]}
        """
        let q = try #require(try loadArtifactRecallQuestions(
            jsonl: jsonl, dataset: .membench).first)
        #expect(q.sampleID == "FirstAgent/aggregative/roles/0")
        // Unit stem = units/<family>__<category>__<section>__<tid>.json.
        #expect(q.unitStem == "FirstAgent__aggregative__roles__0")
        #expect(q.wing == "Alex Calder")
        #expect(q.label == "FirstAgent/aggregative")
        // MemBench ground truth is drawer-level (Rule-2 topical drawers).
        #expect(q.answerSessionIDs == ["FirstAgent/aggregative/roles/0/brother-0"])
    }

    @Test func lmeSAdapter() throws {
        let jsonl = """
        {"question_id": "q-123", "question_type": "multi-session", "persona": "Priya Calder", "question": "Where did I go?", "question_3p": "Where did Priya go?", "question_date": "2023-05-30", "answer": "Paris", "answer_session_ids": ["s-9"]}
        """
        let q = try #require(try loadArtifactRecallQuestions(
            jsonl: jsonl, dataset: .lmeS).first)
        #expect(q.sampleID == "q-123")
        #expect(q.unitStem == "q-123")
        // The deduped lme estate has no instance wings — always unscoped.
        #expect(q.wing.isEmpty)
        #expect(q.question == "Where did Priya go?")
        #expect(q.label == "multi-session")
        #expect(q.answerSessionIDs == ["s-9"])
    }

    /// qrels turn-id → artifact session-key fold — the literal vector is
    /// pinned identically in the Rust twin (lmeb_artifact_session_key test).
    @Test func lmebSessionKeyFold() {
        #expect(lmebArtifactSessionKey("user_evidence__scene_0_session_1_turn_9")
                == "user_evidence/scene_0_session_1")
        #expect(lmebArtifactSessionKey("changing_evidence__scene_12_session_3")
                == "changing_evidence/scene_12_session_3")
        #expect(lmebArtifactSessionKey("no-separator") == "no-separator")
    }

    @Test func missingDatasetFieldsFailLoud() {
        // A convomem row without its set/query_id is a hard error, not a
        // silently skipped line (a truncated corpus must not score short).
        let jsonl = """
        {"wing": "Alex Calder", "question": "orphan row"}
        """
        #expect(throws: MCPError.self) {
            _ = try loadArtifactRecallQuestions(jsonl: jsonl, dataset: .convomem)
        }
    }

    // ── Unit stem validation (literal twin of Rust unit_stem_validation) ────

    /// A stem becomes one path component under --catalog and one token in
    /// the whitespace-split serve launch command. These vectors are pinned
    /// identically in the Rust twin and in the seeders.
    @Test func unitStemValidation() {
        #expect(isValidUnitStem("conv-26"))
        #expect(isValidUnitStem("user_evidence__scene_0"))
        #expect(isValidUnitStem(String(repeating: "a", count: 128)))
        #expect(!isValidUnitStem("foo sh -c x"))
        #expect(!isValidUnitStem("../x"))
        #expect(!isValidUnitStem(".hidden"))
        #expect(!isValidUnitStem(""))
        #expect(!isValidUnitStem(String(repeating: "a", count: 129)))
        #expect(!isValidUnitStem("."))
        #expect(!isValidUnitStem(".."))
    }

    @Test func corpusIDWithWhitespaceFailsLoud() {
        // A question id carrying launch-command tokens must stop the run at
        // load time, naming the id, never be skipped or reach the launcher.
        let jsonl = """
        {"question_id": "foo sh -c x", "question_type": "single-session", "question": "Where?", "answer_session_ids": ["s-1"]}
        """
        #expect(throws: MCPError.self) {
            _ = try loadArtifactRecallQuestions(jsonl: jsonl, dataset: .lmeS)
        }
        do {
            _ = try loadArtifactRecallQuestions(jsonl: jsonl, dataset: .lmeS)
        } catch let error as MCPError {
            #expect(error.description.contains("foo sh -c x"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func unitEstateDirStaysUnderSetDirectory() throws {
        // Build a real temp fixture: one set row, one unit with estate.sqlite.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog_unit_test_\(UUID().uuidString)")
        let setDir = tmp.appendingPathComponent("set1")
        let unitDir = setDir.appendingPathComponent("conv-26")
        try FileManager.default.createDirectory(at: unitDir, withIntermediateDirectories: true)
        try Data().write(to: unitDir.appendingPathComponent("estate.sqlite"))
        let catalog: [String: Any] = [
            "sets": [["base": tmp.path, "path": "set1"]]
        ]
        let catalogPath = tmp.appendingPathComponent("catalog.json")
        try JSONSerialization.data(withJSONObject: catalog)
            .write(to: catalogPath)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dir = try artifactUnitEstateDir(catalogPath: catalogPath, id: "conv-26")
        #expect(dir.path.hasSuffix("/set1/conv-26"))

        // Trailing slash on the catalog base value must resolve to the same estate.
        // The Rust twin asserts this via artifact_unit_estate_dir(Path::new(".../units/"), "conv-26")
        // == artifact_unit_estate_dir(Path::new(".../units"), "conv-26"). Swift's
        // URL.standardizedFileURL normalises the trailing slash at set-directory
        // construction time, so the containment guard and the returned path are
        // identical to the slash-free case.
        let catalogWithSlash: [String: Any] = [
            "sets": [["base": tmp.path + "/", "path": "set1"]]
        ]
        let catalogWithSlashPath = tmp.appendingPathComponent("catalog_slash.json")
        try JSONSerialization.data(withJSONObject: catalogWithSlash)
            .write(to: catalogWithSlashPath)
        let dir2 = try artifactUnitEstateDir(catalogPath: catalogWithSlashPath, id: "conv-26")
        // Assert equality against the first resolution, not a hand-written path, so
        // a refactor that changes the absolute layout still proves the two catalogs
        // agree rather than proving they agree with a stale literal.
        #expect(dir2.path == dir.path)

        // Defense in depth: the join site rejects what the loader rejects.
        #expect(throws: MCPError.self) {
            _ = try artifactUnitEstateDir(catalogPath: catalogPath, id: "../x")
        }
        #expect(throws: MCPError.self) {
            _ = try artifactUnitEstateDir(catalogPath: catalogPath, id: "foo sh -c x")
        }
    }

    @Test func unitResolvesFromSecondaryBase() throws {
        // Fixture: two set rows with two different bases.
        // The target unit exists ONLY in the second row.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog_secondary_\(UUID().uuidString)")

        // Primary base: has a different unit but NOT the target.
        let primarySet = tmp.appendingPathComponent("primary").appendingPathComponent("estates")
        let otherUnit = primarySet.appendingPathComponent("other-unit")
        try FileManager.default.createDirectory(at: otherUnit, withIntermediateDirectories: true)
        try Data().write(to: otherUnit.appendingPathComponent("estate.sqlite"))

        // Secondary base: has the target unit with the schema-19 nested database path
        // (databases/default/estate.sqlite) so the nested branch of hasEstateDatabase
        // is exercised. Mirrors the Rust twin: unit_resolves_from_secondary_base uses
        // the same nested layout. The bare estate.sqlite branch is covered by
        // unitEstateDirStaysUnderSetDirectory, which resolves a unit whose
        // database is a bare estate.sqlite.
        let secondaryBase = tmp.appendingPathComponent("secondary")
        let secondarySet = secondaryBase.appendingPathComponent("estates")
        let targetUnit = secondarySet.appendingPathComponent("target-unit")
        let nestedDbDir = targetUnit.appendingPathComponent("databases/default")
        try FileManager.default.createDirectory(at: nestedDbDir, withIntermediateDirectories: true)
        try Data().write(to: nestedDbDir.appendingPathComponent("estate.sqlite"))

        let catalog: [String: Any] = [
            "sets": [
                ["base": tmp.appendingPathComponent("primary").path, "path": "estates"],
                ["base": secondaryBase.path, "path": "estates"]
            ]
        ]
        let catalogPath = tmp.appendingPathComponent("catalog.json")
        try JSONSerialization.data(withJSONObject: catalog).write(to: catalogPath)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 1. A unit present only in the second set row resolves correctly;
        //    the containment guard passes.
        let dir = try artifactUnitEstateDir(catalogPath: catalogPath, id: "target-unit")
        #expect(dir.path.hasSuffix("/secondary/estates/target-unit"))

        // 2. A unit absent from every set row throws with the exact catalog error text
        //    (byte-identical with the Rust port).
        do {
            _ = try artifactUnitEstateDir(catalogPath: catalogPath, id: "absent-unit")
            Issue.record("expected throw for absent-unit")
        } catch let e as MCPError {
            #expect(e.description ==
                "unit 'absent-unit' is not in the catalog at \(catalogPath.path)")
        } catch {
            Issue.record("unexpected error type: \(error)")
        }

        // 3. The stem ../x is refused before catalog lookup (stem validation fires first).
        #expect(throws: MCPError.self) {
            _ = try artifactUnitEstateDir(catalogPath: catalogPath, id: "../x")
        }
    }

    /// A bounded fleet build (`make fleet-<ds> LIMIT=N` / `UNITS=...`) writes
    /// a catalog holding fewer units than the dataset's questions.jsonl has.
    /// `partitionQuestionsByCatalog` must keep every question whose unit the
    /// catalog carries, count the rest as "outside the catalog" rather than
    /// erroring, and preserve file order. A fixture catalog holds 2 of 3
    /// units; the 3-question file must split 2 in / 1 outside. Twin of Rust
    /// `partition_questions_by_catalog_splits_absent_units`.
    @Test func partitionQuestionsByCatalogSplitsAbsentUnits() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog_bounded_\(UUID().uuidString)")
        let setDir = root.appendingPathComponent("estates")
        // Catalog holds ONLY unit-a and unit-b; unit-c is absent — the
        // bounded fleet build stopped before reaching it.
        for unit in ["unit-a", "unit-b"] {
            let unitDir = setDir.appendingPathComponent(unit)
            try FileManager.default.createDirectory(at: unitDir, withIntermediateDirectories: true)
            try Data().write(to: unitDir.appendingPathComponent("estate.sqlite"))
        }
        let catalog: [String: Any] = ["sets": [["base": root.path, "path": "estates"]]]
        let catalogPath = root.appendingPathComponent("catalog.json")
        try JSONSerialization.data(withJSONObject: catalog).write(to: catalogPath)
        defer { try? FileManager.default.removeItem(at: root) }

        func question(_ id: String) -> ArtifactRecallQuestion {
            ArtifactRecallQuestion(
                sampleID: id, unitStem: id, wing: "", question: "about \(id)",
                label: "1", answerSessionIDs: ["\(id)/S1"])
        }
        // File order: unit-a, unit-b (both built), unit-c (not built).
        let questions = [question("unit-a"), question("unit-b"), question("unit-c")]

        let (inCatalog, outside) = try partitionQuestionsByCatalog(
            questions, catalogPath: catalogPath)
        #expect(outside == 1)
        #expect(inCatalog.map(\.unitStem) == ["unit-a", "unit-b"])

        // A genuine defect — an invalid stem — must propagate rather than
        // being swallowed as "outside the catalog".
        do {
            _ = try partitionQuestionsByCatalog([question("../x")], catalogPath: catalogPath)
            Issue.record("expected throw for an invalid unit stem")
        } catch let e as MCPError {
            #expect(e.description.contains("not a valid unit stem"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - loadOrReconstructIDMap (item 5)

    @Test("id-map present: loadOrReconstructIDMap returns it unchanged")
    func reconstructIDMapFallsThroughToJSONWhenPresent() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recon_idmap_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let idMap: [String: String] = ["seed-1": "uuid-aaa", "seed-2": "uuid-bbb"]
        let data = try JSONSerialization.data(withJSONObject: idMap)
        try data.write(to: tmpDir.appendingPathComponent("id-map.json"))

        let result = try loadOrReconstructIDMap(estateDir: tmpDir)
        #expect(result["seed-1"] == "uuid-aaa")
        #expect(result["seed-2"] == "uuid-bbb")
    }

    @Test("id-map absent, no SQLite: loadOrReconstructIDMap throws descriptive error")
    func reconstructIDMapNoSQLiteReturnsError() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recon_nosqlite_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        do {
            _ = try loadOrReconstructIDMap(estateDir: tmpDir)
            Issue.record("expected an error")
        } catch let error as MCPError {
            #expect(error.description.contains("no estate.sqlite found") ||
                    error.description.contains("id-map.json not found"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - FNV-1a 128-bit lineage hash (fnv1a128LineageID)

    /// Verified vector from the mission spec.
    /// "ThirdAgent/noisy/places/331/lives-here" → "6DBBCF02-F3DE-3DA9-F66D-AB95699D4ABE"
    /// Twin of Rust fnv1a128_lineage_id_verified_vector in artifact_recall.rs.
    @Test func fnv1a128VerifiedVector() {
        #expect(fnv1a128LineageID(for: "ThirdAgent/noisy/places/331/lives-here")
                == "6DBBCF02-F3DE-3DA9-F66D-AB95699D4ABE")
    }

    /// Second vector: empty string → FNV-1a 128-bit offset basis as UUID.
    /// Identical in both ports.
    @Test func fnv1a128EmptyString() {
        // The empty string produces the offset basis unchanged.
        // offset basis: (0x6c62272e07bb0142, 0x62b821756295c58d)
        // → bytes: 6C 62 27 2E 07 BB 01 42 62 B8 21 75 62 95 C5 8D
        // → UUID:  6C62272E-07BB-0142-62B8-217562 95C58D
        #expect(fnv1a128LineageID(for: "")
                == "6C62272E-07BB-0142-62B8-217562 95C58D".replacingOccurrences(of: " ", with: ""))
    }

    // MARK: - Lineage derivation path in loadOrReconstructIDMap

    /// Creates a minimal estate.sqlite with the drawers table containing one
    /// row that has lineageID set and sourceFile/chunkIndex NULL. Verifies that
    /// the lineage derivation path returns the correct seedID → drawerUUID map.
    @Test("lineage derivation: produces exact map when id-map.json and sourceFile both absent")
    func lineageDerivationProducesExactMap() throws {
        let tmpEstate = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineage_estate_\(UUID().uuidString)")
        let tmpSeeds  = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineage_seeds_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpEstate, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmpSeeds,  withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tmpEstate)
            try? FileManager.default.removeItem(at: tmpSeeds)
        }

        let estateName = tmpEstate.lastPathComponent
        // Choose a seed record id and compute its expected lineageID.
        let seedRecordID  = "FirstAgent/simple/roles/0/hello-world-0"
        let expectedLineageID = fnv1a128LineageID(for: seedRecordID)
        // The drawer UUID stored in the estate.
        let drawerUUID = "CAFEBABE-0000-0000-0000-000000000001"

        // Write estate.sqlite with one drawer row.
        let dbURL = tmpEstate.appendingPathComponent("estate.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            Issue.record("could not open test db")
            return
        }
        defer { sqlite3_close(db) }

        let createSQL = """
            CREATE TABLE drawers (
                id TEXT NOT NULL,
                lineageID TEXT,
                sourceFile TEXT,
                chunkIndex INTEGER,
                tombstonedAt TEXT
            )
            """
        sqlite3_exec(db, createSQL, nil, nil, nil)

        // Insert one drawer: lineageID set, sourceFile/chunkIndex NULL.
        let insertSQL = "INSERT INTO drawers (id, lineageID, sourceFile, chunkIndex, tombstonedAt) VALUES (?, ?, NULL, NULL, NULL)"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, (drawerUUID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (expectedLineageID as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        // Write seed unit JSON at <seedsDir>/<estateName>.json.
        let seedJSON: [String: Any] = [
            "format_version": "1",
            "name": estateName,
            "records": [
                ["id": seedRecordID, "content": "hello", "wing": "Test",
                 "room": "simple", "subject": "S", "event_time": "2024-01-01T00:00:00Z"]
            ]
        ]
        let seedData = try JSONSerialization.data(withJSONObject: seedJSON)
        try seedData.write(to: tmpSeeds.appendingPathComponent("\(estateName).json"))

        // Lineage derivation should return seedRecordID → drawerUUID.
        let result = try loadOrReconstructIDMap(estateDir: tmpEstate, seedUnitsDir: tmpSeeds)
        #expect(result[seedRecordID] == drawerUUID)
        #expect(result.count == 1)
    }

    /// Verifies that the refusal fires with a message naming all three sources
    /// when id-map.json is absent, sourceFile yields no rows, and
    /// --seed-units-dir is not provided.
    @Test("refusal: all three sources absent and no seedUnitsDir")
    func lineageDerivationRefusalNamingAllSources() throws {
        let tmpEstate = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineage_refusal_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpEstate, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpEstate) }

        // Write estate.sqlite with no useful rows.
        let dbURL = tmpEstate.appendingPathComponent("estate.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            Issue.record("could not open test db")
            return
        }
        defer { sqlite3_close(db) }
        let createSQL = """
            CREATE TABLE drawers (
                id TEXT NOT NULL,
                lineageID TEXT,
                sourceFile TEXT,
                chunkIndex INTEGER,
                tombstonedAt TEXT
            )
            """
        sqlite3_exec(db, createSQL, nil, nil, nil)
        // No rows inserted — all three sources will fail.
        sqlite3_close(db)

        // seedUnitsDir is nil — lineage path not available.
        do {
            _ = try loadOrReconstructIDMap(estateDir: tmpEstate, seedUnitsDir: nil)
            Issue.record("expected an error when all three sources fail")
        } catch let error as MCPError {
            // Error must name the estate.
            let estateName = tmpEstate.lastPathComponent
            #expect(error.description.contains(estateName) ||
                    error.description.contains("id-map.json"))
            // Error must mention all three sources.
            #expect(error.description.contains("id-map.json") ||
                    error.description.contains("sourceFile") ||
                    error.description.contains("lineage"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    /// Verifies that id-map.json wins over lineage derivation when both are available.
    @Test("id-map.json wins over lineage when present")
    func idMapJSONWinsOverLineage() throws {
        let tmpEstate = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineage_json_wins_\(UUID().uuidString)")
        let tmpSeeds  = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineage_json_seeds_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpEstate, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmpSeeds,  withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tmpEstate)
            try? FileManager.default.removeItem(at: tmpSeeds)
        }

        // Write id-map.json.
        let idMap: [String: String] = ["seed-from-json": "UUID-FROM-JSON"]
        let data = try JSONSerialization.data(withJSONObject: idMap)
        try data.write(to: tmpEstate.appendingPathComponent("id-map.json"))

        // seedUnitsDir provided but should NOT be consulted.
        let result = try loadOrReconstructIDMap(estateDir: tmpEstate, seedUnitsDir: tmpSeeds)
        #expect(result["seed-from-json"] == "UUID-FROM-JSON")
        #expect(result.count == 1)
    }
}
