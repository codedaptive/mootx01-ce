import Foundation
import SQLite3

// ArtifactRecallRunner — THE measure lane for the rebuilt benchmark
// artifacts, all four datasets at all three target scales (#94 measure
// seam: one runner, per-dataset question adapters, scoring identical
// everywhere; only which estate gets opened changes).
//
// Unlike every other lane in this package, artifact-recall does NOT provision
// a scratch estate: the estate IS the artifact, pre-built by the seeding
// pipeline (make seeds/fleets/wing-estates/twins) and passed in via
// --estate-dir (aggregate scales) or --catalog (unit scale, catalog.json
// maps unit stems to estate directories, questions grouped by unit stem). The lane is strictly READ-ONLY against that estate — the
// only tool it ever calls is moot_memory_search — which is why it does not
// (and must not) route through assertScratchBackend: that guard exists to
// keep WRITE lanes off durable stores, and this lane's whole point is to
// measure a durable store in place.
//
// Inputs:
//   --estate-dir  a --db-style dir (estate.sqlite, attached as a transient
//                 record) that MUST also contain id-map.json: a flat JSON
//                 object mapping seed record id (e.g. "conv-26/S1") to the
//                 drawer UUID the importer minted for it.
//   --questions   questions.jsonl (one JSON object per line; see
//                 ArtifactRecallQuestion for the fields consumed).
//
// Per question: moot_memory_search (wing-scoped when --scope wing), returned
// drawer UUIDs are mapped back to seed ids via id-map.json, and hit@k / MRR
// are scored against the question's answer_session_ids.

// MARK: - Question model + loading

/// One question from the artifact questions.jsonl.
///
/// Only the fields the recall slice consumes are modelled. The `answer` field
/// is deliberately ABSENT: it can be a string OR a bare number in the corpus
/// (e.g. `"answer": 2022`), and recall scoring never reads it, so decoding it
/// would only add a type-tolerance burden with no consumer.
struct ArtifactRecallQuestion: Sendable, Equatable {
    /// Question identity for the misses report — the dataset's own id field
    /// (locomo sample_id, convomem query_id, membench tid path, lme-s
    /// question_id).
    let sampleID: String
    /// Form-1 unit-estate stem this question belongs to — the filename stem
    /// of its unit seed under out-<ds>/units/. Derived per dataset from the
    /// question's own fields; used only at unit target-scale to group
    /// questions by the estate that answers them.
    let unitStem: String
    /// Wing the material was seeded under in the Form-2 estate. Empty for
    /// lme-s (the deduped estate has no instance wings — questions run
    /// unscoped by design).
    let wing: String
    /// The question text sent to moot_memory_search. Third person: the
    /// pre-rewritten "question_3p" wins when present and non-empty
    /// (aggregate estates are provenance-blind, so first-person text would
    /// leak nothing but scores worse); "question" is the fallback.
    let question: String
    /// Per-dataset breakdown label (locomo category number, convomem set,
    /// membench family/section, lme-s question_type).
    let label: String
    /// Ground-truth seed record ids. Empty for adversarial / abstention
    /// questions, which are excluded from scoring (the no_evidence bucket).
    let answerSessionIDs: [String]
}

/// The four rebuilt-artifact datasets the measure lane understands. Each
/// case knows how to project its own questions.jsonl row into the
/// normalized `ArtifactRecallQuestion` (the #94 measure-side seam: one
/// runner, per-dataset question adapters, scoring identical everywhere).
enum ArtifactDataset: String, Sendable, CaseIterable {
    case locomo
    case convomem
    case membench
    case lmeS = "lme-s"

    /// Decodes one questions.jsonl row. Throws (via the caller) by
    /// returning nil with the missing-field description filled in.
    func question(from obj: [String: Any]) -> ArtifactRecallQuestion? {
        // Third-person text wins; fall back to the primary field.
        let threeP = (obj["question_3p"] as? String) ?? ""
        let primary = (obj["question"] as? String) ?? ""
        let text = threeP.isEmpty ? primary : threeP
        guard !text.isEmpty else { return nil }
        switch self {
        case .locomo:
            guard let sampleID = obj["sample_id"] as? String,
                  let wing = obj["wing"] as? String else { return nil }
            return ArtifactRecallQuestion(
                sampleID: sampleID,
                unitStem: sampleID,
                wing: wing,
                question: text,
                label: String((obj["category"] as? Int) ?? 0),
                answerSessionIDs: (obj["answer_session_ids"] as? [String]) ?? [])
        case .convomem:
            guard let queryID = obj["query_id"] as? String,
                  let set = obj["set"] as? String,
                  let wing = obj["wing"] as? String else { return nil }
            // query_id "scene_0_q_0" → unit "user_evidence__scene_0"
            // (units/<set>__<scene>.json). The scene prefix is the first two
            // underscore-joined components.
            let comps = queryID.split(separator: "_")
            guard comps.count >= 2, comps[0] == "scene" else { return nil }
            return ArtifactRecallQuestion(
                sampleID: "\(set)/\(queryID)",
                unitStem: "\(set)__scene_\(comps[1])",
                wing: wing,
                question: text,
                label: set,
                answerSessionIDs: (obj["answer_session_ids"] as? [String]) ?? [])
        case .membench:
            guard let family = obj["family"] as? String,
                  let category = obj["category"] as? String,
                  let section = obj["section"] as? String,
                  let wing = obj["wing"] as? String else { return nil }
            // tid is an Int or a String in the corpus; normalize to text.
            let tid = (obj["tid"] as? String) ?? (obj["tid"] as? Int).map(String.init) ?? ""
            guard !tid.isEmpty else { return nil }
            return ArtifactRecallQuestion(
                sampleID: "\(family)/\(category)/\(section)/\(tid)",
                unitStem: "\(family)__\(category)__\(section)__\(tid)",
                wing: wing,
                question: text,
                label: "\(family)/\(category)",
                // MemBench Rule-2 ground truth is drawer-level: the topical
                // drawers its facts hang from.
                answerSessionIDs: (obj["answer_drawer_ids"] as? [String]) ?? [])
        case .lmeS:
            guard let qid = obj["question_id"] as? String else { return nil }
            return ArtifactRecallQuestion(
                sampleID: qid,
                unitStem: qid,
                // The deduped lme estate carries no instance wings; questions
                // run unscoped (two-form ruling).
                wing: "",
                question: text,
                label: (obj["question_type"] as? String) ?? "",
                answerSessionIDs: (obj["answer_session_ids"] as? [String]) ?? [])
        }
    }
}

// MARK: - Unit stem validation

/// Longest unit stem accepted, in bytes. A stem names a unit seed file
/// (units/<stem>.json) and a unit estate directory; 128 keeps both well
/// inside every filesystem's name limit with room for the suffix.
let artifactUnitStemMaxLength = 128

/// True iff `stem` may name a unit seed file or a unit estate directory.
///
/// Stems are corpus-derived (sample_id, question_id, tid path …), and at
/// unit scale a stem is joined under its set directory and interpolated into the
/// serve launch command, which the stdio launcher splits on whitespace. The
/// rule is therefore deliberately narrow: non-empty, at most
/// `artifactUnitStemMaxLength` bytes, first character an ASCII letter or
/// digit, every later character an ASCII letter, digit, `.`, `_` or `-`,
/// and never "." or "..". A valid stem is exactly one plain path component
/// and exactly one launch-command token. Only ASCII passes, so the byte
/// count equals the character count. The seeders apply the same rule before
/// writing a unit file; the Rust twin is `is_valid_unit_stem`, and both ports
/// pin the same literal vectors in their tests.
func isValidUnitStem(_ stem: String) -> Bool {
    let bytes = Array(stem.utf8)
    guard !bytes.isEmpty, bytes.count <= artifactUnitStemMaxLength else { return false }
    guard stem != ".", stem != ".." else { return false }
    func isASCIIAlphanumeric(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b)
    }
    guard isASCIIAlphanumeric(bytes[0]) else { return false }
    for b in bytes.dropFirst() {
        // 0x2E '.', 0x5F '_', 0x2D '-'.
        guard isASCIIAlphanumeric(b) || b == 0x2E || b == 0x5F || b == 0x2D else { return false }
    }
    return true
}

/// The one-line statement of the stem rule, shared by every rejection
/// message so an operator reading a failed run sees what a stem must be.
let artifactUnitStemRule = "a unit stem must be non-empty, at most 128 characters, "
    + "start with an ASCII letter or digit, and contain only ASCII letters, "
    + "digits, '.', '_' or '-'"

/// True iff `dir` contains an estate database at one of the two known locations.
///
/// Mirrors the Python `estate_db` helper in `artifact_layout.py`: bare
/// `estate.sqlite` at the root (schema <18) or the nested
/// `databases/default/estate.sqlite` path introduced in schema 19.
func hasEstateDatabase(at dir: URL) -> Bool {
    let fm = FileManager.default
    return fm.fileExists(atPath: dir.appendingPathComponent("estate.sqlite").path)
        || fm.fileExists(atPath: dir
            .appendingPathComponent("databases/default/estate.sqlite").path)
}

/// Resolves the unit estate directory for `id` from the catalog at `catalogPath`.
///
/// Reads `catalog.json`, walks its `sets` rows in order, and returns the first
/// row whose `<base>/<path>/<id>` directory exists and carries an estate database.
/// Row order is the tie-break when an id appears in two sets: the earlier row wins.
///
/// Defense in depth: the id is validated as a unit stem, and the joined path must
/// sit DIRECTLY under its resolved set directory — the parent must equal the set
/// directory and the last component must equal the id — so no id can address an
/// estate outside the set. Twin of the Rust `artifact_unit_estate_dir`.
func artifactUnitEstateDir(catalogPath: URL, id: String) throws -> URL {
    guard isValidUnitStem(id) else {
        throw MCPError(description:
            "unit stem '\(id)' is not a valid unit stem: \(artifactUnitStemRule)")
    }
    guard let data = try? Data(contentsOf: catalogPath),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sets = obj["sets"] as? [[String: Any]] else {
        throw MCPError(description: "catalog not readable at \(catalogPath.path)")
    }
    // Walk sets in catalog row order; the first row whose unit directory exists
    // and carries an estate database wins. Row order is the tie-break when an id
    // appears in two sets (a unit promoted to a secondary base still appears in
    // both; the earlier row takes precedence so behaviour is deterministic).
    for setRow in sets {
        guard let base = setRow["base"] as? String,
              let path = setRow["path"] as? String else { continue }
        let setDir = URL(fileURLWithPath: base)
            .appendingPathComponent(path)
            .standardizedFileURL
        let unitDir = setDir.appendingPathComponent(id).standardizedFileURL
        guard hasEstateDatabase(at: unitDir) else { continue }
        // Containment guard: the unit directory must sit DIRECTLY under its
        // resolved set directory. This prevents any id from escaping the set,
        // even after URL standardization collapses ".." components.
        guard unitDir.deletingLastPathComponent().path == setDir.path,
              unitDir.lastPathComponent == id else {
            throw MCPError(description:
                "unit estate for '\(id)' resolved to \(unitDir.path), "
                + "which is not directly under its set directory \(setDir.path)")
        }
        return unitDir
    }
    throw MCPError(description:
        "unit '\(id)' is not in the catalog at \(catalogPath.path)")
}

/// Parses questions.jsonl content into questions. Lines that are blank are
/// skipped; a line that is not a JSON object, or that is missing the
/// dataset's required fields, is a hard error (a truncated corpus should
/// fail loud, not score as a short run). A row whose derived unit stem
/// fails `isValidUnitStem` is likewise a hard error naming the offending
/// id: the stem becomes a path and a launch-command token at unit scale,
/// and a corpus that smuggles anything else in must stop the run, never be
/// skipped.
func loadArtifactRecallQuestions(jsonl: String, dataset: ArtifactDataset) throws
    -> [ArtifactRecallQuestion] {
    var questions: [ArtifactRecallQuestion] = []
    for (index, rawLine) in jsonl.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw MCPError(description:
                "questions.jsonl line \(index + 1) is not a JSON object: \(line.prefix(120))")
        }
        guard let question = dataset.question(from: obj) else {
            throw MCPError(description:
                "questions.jsonl line \(index + 1) missing required "
                + "\(dataset.rawValue) fields: \(line.prefix(120))")
        }
        guard isValidUnitStem(question.unitStem) else {
            throw MCPError(description:
                "questions.jsonl line \(index + 1): unit stem '\(question.unitStem)' "
                + "derived from id '\(question.sampleID)' is not a valid unit stem: "
                + artifactUnitStemRule)
        }
        questions.append(question)
    }
    return questions
}

/// Splits questions into (scored, noEvidence): questions with empty
/// answer_session_ids cannot be recall-scored and are counted separately as
/// "no_evidence" rather than polluting hit@k/MRR with guaranteed zeros.
func partitionArtifactQuestions(_ questions: [ArtifactRecallQuestion])
    -> (scored: [ArtifactRecallQuestion], noEvidence: Int) {
    let scored = questions.filter { !$0.answerSessionIDs.isEmpty }
    return (scored, questions.count - scored.count)
}

/// Applies --limit: 0 means all questions, N > 0 keeps the first N (file
/// order — the slice is a smoke/measurement tool, so determinism beats
/// sampling breadth).
func applyArtifactLimit(_ questions: [ArtifactRecallQuestion], limit: Int) -> [ArtifactRecallQuestion] {
    limit <= 0 ? questions : Array(questions.prefix(limit))
}

/// At unit target-scale, a bounded fleet build (`make fleet-<ds> LIMIT=N` /
/// `UNITS=...`) writes a catalog holding fewer units than the dataset's
/// questions.jsonl has, and it is not an error for a question to name a unit
/// the catalog does not carry — it is simply out of the measured slice.
/// Splits `questions` into (inCatalog, outsideCatalog): a question is
/// "outside the catalog" iff `artifactUnitEstateDir` refuses its unit stem
/// specifically with the "is not in the catalog" refusal. Any OTHER
/// resolution failure — an invalid stem, a containment violation, an
/// unreadable catalog.json — is a real defect and propagates rather than
/// being swallowed as absence.
///
/// Distinct unit stems are resolved once and cached, so a corpus with many
/// questions per unit costs one catalog walk per unit, not one per question.
/// Order is preserved (file order in, file order out) so the caller can
/// apply --limit afterward and get a deterministic prefix of real,
/// catalog-backed questions. Twin of Rust `partition_questions_by_catalog`.
func partitionQuestionsByCatalog(
    _ questions: [ArtifactRecallQuestion], catalogPath: URL
) throws -> (inCatalog: [ArtifactRecallQuestion], outsideCatalog: Int) {
    let notInCatalogSuffix = "is not in the catalog at \(catalogPath.path)"
    var resolvedStems: [String: Bool] = [:]  // unit stem -> present in catalog
    var inCatalog: [ArtifactRecallQuestion] = []
    var outsideCount = 0
    for question in questions {
        let stem = question.unitStem
        if let present = resolvedStems[stem] {
            if present { inCatalog.append(question) } else { outsideCount += 1 }
            continue
        }
        do {
            _ = try artifactUnitEstateDir(catalogPath: catalogPath, id: stem)
            resolvedStems[stem] = true
            inCatalog.append(question)
        } catch let error as MCPError where error.description.hasSuffix(notInCatalogSuffix) {
            resolvedStems[stem] = false
            outsideCount += 1
        }
        // Any other error (invalid stem, containment violation, unreadable
        // catalog) is not caught above and propagates out of this `throws`
        // function unchanged.
    }
    return (inCatalog, outsideCount)
}

// MARK: - id-map

/// Loads `<estateDir>/id-map.json`: a flat JSON object mapping seed record id
/// ("conv-26/S1") → drawer UUID string. The file is REQUIRED — without it
/// returned UUIDs cannot be mapped back to ground truth, so its absence is a
/// clear hard error naming the expected path. The seeding pipeline writes it;
/// pre-id-map estates must be repaired before measurement.
func loadArtifactIDMap(estateDir: URL) throws -> [String: String] {
    let url = estateDir.appendingPathComponent("id-map.json")
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw MCPError(description:
            "id-map.json not found at \(url.path) — the artifact-recall lane "
            + "requires the seed-id → drawer-UUID map written by the seeding "
            + "pipeline; repair pre-id-map estates before measuring them")
    }
    let data = try Data(contentsOf: url)
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
        throw MCPError(description:
            "id-map.json at \(url.path) is not a flat {seed-id: uuid} object")
    }
    return obj
}

// MARK: - FNV-1a 128-bit lineage hash

/// FNV-1a 128-bit hash of a UTF-8 string, returned as an uppercase UUID string.
///
/// Algorithm: FNV-1a 128-bit per the reference specification.
///   offset basis (high, low): (0x6c62272e07bb0142, 0x62b821756295c58d)
///   prime        (high, low): (0x0000000001000000, 0x000000000000013B)
///   per byte: hash XOR= byte, then hash *= prime (128-bit arithmetic mod 2^128)
///   result packed big-endian as 16 bytes, formatted as UUID (4-2-2-2-6 groups).
///
/// Verified vector: "ThirdAgent/noisy/places/331/lives-here"
///   → "6DBBCF02-F3DE-3DA9-F66D-AB95699D4ABE"
///
/// Identical algorithm to VaultKit's `DrawerMapping.lineageID(forStableSourceKey:)`.
/// Reimplemented here so the harness does not depend on VaultKit.
/// Twin of Rust `fnv1a128_lineage_id` in artifact_recall.rs.
func fnv1a128LineageID(for string: String) -> String {
    // FNV-1a 128-bit offset basis.
    var high: UInt64 = 0x6c62272e07bb0142
    var low:  UInt64 = 0x62b821756295c58d
    // FNV-1a 128-bit prime: 0x0000000001000000_000000000000013B.
    let primeHigh: UInt64 = 0x0000000001000000
    let primeLow:  UInt64 = 0x000000000000013B

    for byte in string.utf8 {
        // Step 1: XOR the byte into the low 64-bit word (FNV-1a order: XOR first).
        low ^= UInt64(byte)
        // Step 2: multiply the 128-bit value by the 128-bit prime (mod 2^128).
        // multipliedFullWidth returns (high:, low:) — the upper and lower 64 bits
        // of the full 128-bit product.  `carry` feeds into the new high word.
        let product = low.multipliedFullWidth(by: primeLow)
        let carry  = product.high  // upper 64 bits of (old_low * primeLow)
        let newLow = product.low   // lower 64 bits of (old_low * primeLow) → new low word
        // new_high = (old_high * primeLow + old_low * primeHigh + carry) mod 2^64.
        // `low` still holds old_low here; newLow holds the updated low word.
        high = high &* primeLow &+ low &* primeHigh &+ carry
        low  = newLow
    }

    // Pack the 128-bit result big-endian as a UUID string.
    return String(format:
        "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
        UInt8((high >> 56) & 0xFF), UInt8((high >> 48) & 0xFF),
        UInt8((high >> 40) & 0xFF), UInt8((high >> 32) & 0xFF),
        UInt8((high >> 24) & 0xFF), UInt8((high >> 16) & 0xFF),
        UInt8((high >>  8) & 0xFF), UInt8( high        & 0xFF),
        UInt8((low  >> 56) & 0xFF), UInt8((low  >> 48) & 0xFF),
        UInt8((low  >> 40) & 0xFF), UInt8((low  >> 32) & 0xFF),
        UInt8((low  >> 24) & 0xFF), UInt8((low  >> 16) & 0xFF),
        UInt8((low  >>  8) & 0xFF), UInt8( low         & 0xFF))
}

// MARK: - ID-map load / reconstruct / derive

/// Loads the seed-id → drawer-UUID map from `id-map.json`, or reconstructs it
/// from the `drawers` table when the file is absent.
///
/// Three sources are tried in priority order:
///
/// 1. **id-map.json** — wins when present; returned verbatim.
///
/// 2. **sourceFile + chunkIndex** — when the drawers table carries non-NULL
///    `sourceFile` and `chunkIndex` columns (standard membench seeding), the
///    seed ID is `"\(sourceFile)/\(chunkIndex)"`.
///
/// 3. **Lineage derivation** — when `seedUnitsDir` is provided, loads the unit
///    seed JSON at `<seedUnitsDir>/<estateName>.json`, computes
///    `fnv1a128LineageID(for: recordID)` for every record, and matches each
///    result against the `lineageID` column in the `drawers` table to produce
///    the seedID → drawerUUID map. Used for JSON-import-lane membench estates
///    where `sourceFile`/`chunkIndex` are NULL but `lineageID` carries the
///    FNV-1a-128 hash of the original record id.
///
/// If all three sources yield no rows, the function throws an error naming the
/// estate and each source that was tried.
///
/// Twin of Rust `load_or_reconstruct_id_map`.
func loadOrReconstructIDMap(estateDir: URL, seedUnitsDir: URL? = nil) throws -> [String: String] {
    let mapURL  = estateDir.appendingPathComponent("id-map.json")
    let estateName = estateDir.lastPathComponent

    // Source 1: id-map.json wins when present.
    if FileManager.default.fileExists(atPath: mapURL.path) {
        return try loadArtifactIDMap(estateDir: estateDir)
    }

    // Sources 2 and 3 both require the estate SQLite.
    guard let dbPath = estateDatabasePath(in: estateDir) else {
        throw MCPError(description:
            "id-map derivation failed for estate '\(estateName)' — "
            + "tried: (1) id-map.json not found; "
            + "(2) sourceFile/chunkIndex: no estate.sqlite; "
            + "(3) lineage: no estate.sqlite")
    }
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
        sqlite3_close(db)
        throw MCPError(description:
            "id-map.json not found at \(mapURL.path) and cannot open estate.sqlite: \(msg)")
    }
    defer { sqlite3_close(db) }

    // Source 2: sourceFile + chunkIndex reconstruction.
    // Query only non-tombstoned drawers that carry both columns.
    let sourceSQL = """
        SELECT id, sourceFile, chunkIndex FROM drawers
        WHERE tombstonedAt IS NULL AND sourceFile IS NOT NULL AND chunkIndex IS NOT NULL
        """
    var sourceStmt: OpaquePointer?
    if sqlite3_prepare_v2(db, sourceSQL, -1, &sourceStmt, nil) == SQLITE_OK {
        defer { sqlite3_finalize(sourceStmt) }
        var idMap: [String: String] = [:]
        while sqlite3_step(sourceStmt) == SQLITE_ROW {
            guard let uuidCStr   = sqlite3_column_text(sourceStmt, 0),
                  let sourceCStr = sqlite3_column_text(sourceStmt, 1) else { continue }
            let uuid       = String(cString: uuidCStr)
            let sourceFile = String(cString: sourceCStr)
            let chunkIndex = sqlite3_column_int(sourceStmt, 2)
            // Seed ID format: "<sourceFile>/<chunkIndex>"
            // e.g. "FirstAgent/simple/roles/0/3"
            let seedID = "\(sourceFile)/\(chunkIndex)"
            idMap[seedID] = uuid
        }
        if !idMap.isEmpty { return idMap }
    }

    // Source 3: lineage derivation via FNV-1a-128.
    if let seedDir = seedUnitsDir {
        return try deriveIDMapFromLineage(
            db: db!, estateName: estateName, mapURL: mapURL, seedUnitsDir: seedDir)
    }

    // All three sources exhausted.
    throw MCPError(description:
        "id-map derivation failed for estate '\(estateName)' — "
        + "tried: (1) id-map.json not found at \(mapURL.path); "
        + "(2) sourceFile/chunkIndex: no rows in drawers; "
        + "(3) lineage: --seed-units-dir not provided")
}

/// Derives the seedID → drawerUUID map by matching each drawer's `lineageID`
/// against the FNV-1a-128 hashes of the seed record ids in the unit JSON file.
///
/// The seed file format is `{"records": [{"id": "<seedRecordID>", ...}, ...]}`.
/// For each record, `fnv1a128LineageID(for: recordID)` gives the lineageID UUID
/// that the JSON-import lane stores in `drawers.lineageID`. Matching a drawer's
/// lineageID against that set yields the seedID → drawerUUID pair.
///
/// Called only when sourceFile/chunkIndex reconstruction yields no rows.
private func deriveIDMapFromLineage(
    db: OpaquePointer,
    estateName: String,
    mapURL: URL,
    seedUnitsDir: URL
) throws -> [String: String] {
    let seedFile = seedUnitsDir.appendingPathComponent("\(estateName).json")
    guard FileManager.default.fileExists(atPath: seedFile.path) else {
        throw MCPError(description:
            "id-map derivation failed for estate '\(estateName)' — "
            + "tried: (1) id-map.json not found at \(mapURL.path); "
            + "(2) sourceFile/chunkIndex: no rows in drawers; "
            + "(3) lineage: seed file not found at \(seedFile.path)")
    }
    let seedData = try Data(contentsOf: seedFile)
    guard let root = try? JSONSerialization.jsonObject(with: seedData) as? [String: Any],
          let records = root["records"] as? [[String: Any]] else {
        throw MCPError(description:
            "lineage derivation: seed file at \(seedFile.path) is not a "
            + "{\"records\": [...]} JSON object")
    }

    // Build lookup: lineageUUID (uppercase) → seedRecordID.
    var lineageToSeedID: [String: String] = [:]
    for record in records {
        guard let seedID = record["id"] as? String else { continue }
        let lineageUUID = fnv1a128LineageID(for: seedID)
        lineageToSeedID[lineageUUID] = seedID
    }
    guard !lineageToSeedID.isEmpty else {
        throw MCPError(description:
            "lineage derivation: seed file at \(seedFile.path) has no records with an 'id' field")
    }

    // Query non-tombstoned drawers for (drawerUUID, lineageID).
    let sql = """
        SELECT id, lineageID FROM drawers WHERE tombstonedAt IS NULL AND lineageID IS NOT NULL
        """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        let msg = String(cString: sqlite3_errmsg(db))
        throw MCPError(description:
            "lineage derivation: drawers query prepare failed: \(msg)")
    }
    defer { sqlite3_finalize(stmt) }

    var idMap: [String: String] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
        guard let drawerUUIDCStr = sqlite3_column_text(stmt, 0),
              let lineageIDCStr  = sqlite3_column_text(stmt, 1) else { continue }
        let drawerUUID = String(cString: drawerUUIDCStr)
        // lineageID is stored uppercase in the DB; our lookup is also uppercase.
        let lineageID  = String(cString: lineageIDCStr).uppercased()
        if let seedID = lineageToSeedID[lineageID] {
            idMap[seedID] = drawerUUID
        }
    }

    guard !idMap.isEmpty else {
        throw MCPError(description:
            "id-map derivation failed for estate '\(estateName)' — "
            + "tried: (1) id-map.json not found at \(mapURL.path); "
            + "(2) sourceFile/chunkIndex: no rows; "
            + "(3) lineage: drawers.lineageID matched no seed record ids from \(seedFile.path)")
    }
    return idMap
}

/// Builds the UUID → seed-id reverse map. Keys are lowercased because the
/// serve dense-row/text formats have historically varied UUID casing and the
/// map lookup must not be case-sensitive.
func artifactReverseIDMap(_ idMap: [String: String]) -> [String: String] {
    var reverse: [String: String] = [:]
    for (seedID, uuid) in idMap {
        reverse[uuid.lowercased()] = seedID
    }
    return reverse
}

/// Maps ranked result UUIDs to seed ids, deduplicating repeated seed ids
/// (first rank wins — matches the locomo-spec ranked-dia-id discipline).
/// A UUID absent from the map keeps its rank slot as "unmapped:<uuid>":
/// it is a real returned result that is not the answer, so collapsing it
/// would inflate the ranks of everything below it.
func artifactMapRankedUUIDs(_ uuids: [String], reverse: [String: String]) -> [String] {
    var seen = Set<String>()
    var ranked: [String] = []
    for uuid in uuids {
        let key = uuid.lowercased()
        let seedID = reverse[key] ?? "unmapped:\(key)"
        if seen.insert(seedID).inserted { ranked.append(seedID) }
    }
    return ranked
}

// MARK: - Scoring

/// Per-question score: hit@k over the top k ranked seed ids, reciprocal rank
/// over the FULL ranked list (with --top-k as the search limit the two windows
/// coincide; they diverge only if the server returns more rows than k).
///
/// Twin of Rust `score_artifact_question` (artifact_recall.rs) — the literal
/// test vectors are asserted identically in both ports.
func scoreArtifactQuestion(rankedSeedIDs: [String], expected: [String], k: Int)
    -> (hitAtK: Bool, reciprocalRank: Double) {
    let expectedSet = Set(expected)
    var hit = false
    var rr = 0.0
    for (index, id) in rankedSeedIDs.enumerated() where expectedSet.contains(id) {
        rr = 1.0 / Double(index + 1)
        hit = index < k
        break
    }
    return (hit, rr)
}

// MARK: - Run configuration

/// Whether the moot_memory_search call carries the question's wing.
enum ArtifactRecallScope: String, Sendable {
    /// Pass the question's "wing" as the search's wing argument. A question
    /// whose wing is empty (lme-s) searches unscoped even in this mode.
    case wing
    /// Omit the wing argument — search the whole estate (hard mode on the
    /// wing-per-instance estates; the ONLY mode for lme-s and complete).
    case estate
}

/// Which artifact scale the run measures — the measure-side counterpart of
/// the seeding pipeline's three artifact scales (2026-08-27 changeover
/// design). Questions and scoring are identical at every scale; only which
/// estate gets opened changes.
enum ArtifactTargetScale: String, Sendable {
    /// Form-1 estate-per-instance: questions are grouped by unit stem and
    /// each group runs against its own estate, resolved through the catalog.
    case unit
    /// Form-2 one-estate-per-benchmark (--estate-dir).
    case benchAggregate = "bench-aggregate"
    /// The complete one-database estate (--estate-dir); expected seed ids
    /// gain the dataset's build-plumbing prefix ("<dataset>/").
    case completeAggregate = "complete-aggregate"
}

/// Configuration for one artifact-recall run.
struct ArtifactRecallConfig: Sendable {
    /// Which dataset's questions.jsonl shape to decode.
    let dataset: ArtifactDataset
    /// Which artifact scale is being measured.
    let targetScale: ArtifactTargetScale
    /// The pre-built artifact estate (--db-style dir). Set for
    /// the two aggregate scales; nil at unit scale.
    let estateDir: URL?
    /// The catalog.json path for the dataset (maps unit stems to estate directories).
    /// Set at unit scale; nil otherwise.
    let catalogPath: URL?
    /// questions.jsonl path.
    let questionsPath: URL
    /// Search scoping mode. Forced to .estate at unit scale (each unit
    /// estate IS the official per-instance scope).
    let scope: ArtifactRecallScope
    /// Prefix applied to expected seed ids before id-map lookup — the
    /// complete estate's record ids carry "<dataset>/" from build plumbing.
    let idPrefix: String
    /// Question cap (0 = all).
    let limit: Int
    /// Search result limit AND the k of hit@k.
    let topK: Int
    /// Report output path.
    let outPath: URL
    /// mootx01 binary path.
    let mootBinaryPath: String
}

// MARK: - Live runner

/// Per-question outcome retained for the misses list.
struct ArtifactQuestionOutcome {
    let question: ArtifactRecallQuestion
    let hitAtK: Bool
    let reciprocalRank: Double
    let rankedSeedIDs: [String]
}

/// Asks one batch of questions against one estate: spawns a READ-ONLY serve
/// on `estateDir`, runs every question through moot_memory_search, maps and
/// scores the results. Both target scales share this loop — the aggregate
/// scales call it once, unit scale calls it once per unit estate.
func askArtifactQuestions(
    estateDir: URL,
    questions: [ArtifactRecallQuestion],
    config: ArtifactRecallConfig
) async throws -> [ArtifactQuestionOutcome] {
    // Fail-fast input validation, cheapest first: the id-map requirement is
    // checked before serve is ever spawned.
    guard estateDatabasePath(in: estateDir) != nil else {
        throw MCPError(description:
            "no estate.sqlite in \(estateDir.path) — the target-scale/dir "
            + "arguments must point at a built artifact estate")
    }
    let idMap = try loadArtifactIDMap(estateDir: estateDir)
    let reverse = artifactReverseIDMap(idMap)

    // READ-ONLY endpoint on the artifact estate. The estate carries its
    // transient record (plaintext by rule); the ephemeral-lifetime env token keeps the
    // serve's identity keys in memory (zero Keychain contact — same posture
    // rationale as every measurement lane). Deliberately NOT routed through
    // assertScratchBackend: that guard pins WRITE lanes to /tmp scratch, and
    // this lane reads a durable artifact in place.
    let command = try mootServeCommand(binary: config.mootBinaryPath, scratchDir: estateDir, environment: ["MOOTX01_FROZEN=1", "MOOTX01_SUBJECT_RIDER=0"])
    let endpoint = EndpointConfig(
        name: "mootx01-artifact-recall",
        transport: .stdio(command: command),
        auth: nil,
        // Bare search verb map: NO constant location arg — artifact estates
        // are wing-structured, so scoping is the wing argument (or nothing).
        verbMap: EndpointConfig.VerbMap(
            write: AriaV2Surface.fileMemory,
            query: AriaV2Surface.memorySearch,
            list: nil,
            constantArgs: [:],
            resultFormat: .mootV2),
        role: .target)
    let client = MCPClient(endpoint: endpoint)
    try await client.connect()
    defer { Task { await client.disconnect() } }

    var outcomes: [ArtifactQuestionOutcome] = []
    for question in questions {
        var args: [String: JSONValue] = [
            "query": .string(question.question),
            "limit": .number(Double(config.topK)),
        ]
        // Unit scale never wing-scopes: the unit estate IS the official
        // per-instance scope. A question with no wing (lme-s) searches
        // unscoped in every mode.
        if config.targetScale != .unit, config.scope == .wing, !question.wing.isEmpty {
            args["wing"] = .string(question.wing)
        }
        let result = try await client.callTool(
            AriaV2Surface.memorySearch, arguments: args, format: .mootV2,
            deadline: MCPDeadline.interactive)
        if result.isError {
            throw MCPError(description:
                "moot_memory_search returned a tool-level error for "
                + "'\(question.question.prefix(80))': "
                + result.textBlocks.joined(separator: " ").prefix(200))
        }
        let ranked = artifactMapRankedUUIDs(result.orderedIDs, reverse: reverse)
        // The complete estate's record ids carry the dataset prefix from
        // build plumbing; expected ids are prefixed to match its id-map.
        let expected = question.answerSessionIDs.map { config.idPrefix + $0 }
        let score = scoreArtifactQuestion(
            rankedSeedIDs: ranked, expected: expected, k: config.topK)
        outcomes.append(ArtifactQuestionOutcome(
            question: question, hitAtK: score.hitAtK,
            reciprocalRank: score.reciprocalRank, rankedSeedIDs: ranked))
    }
    return outcomes
}

/// Runs the artifact-recall slice at the configured target scale and writes
/// the report. Scoring is identical at every scale; only which estate(s)
/// get opened changes (the #94 measure-side contract).
func runArtifactRecallLane(config: ArtifactRecallConfig) async throws {
    let jsonl = try String(contentsOf: config.questionsPath, encoding: .utf8)
    let all = try loadArtifactRecallQuestions(jsonl: jsonl, dataset: config.dataset)
    let (scoredPool, noEvidence) = partitionArtifactQuestions(all)

    // At unit scale, a bounded fleet build can hold fewer units than the
    // dataset has: drop every question whose unit the catalog does not
    // carry BEFORE applying --limit, so a smoke of N questions on a bounded
    // set measures N real questions instead of refusing on the first
    // absent unit. Every other scale has no catalog, so nothing is outside
    // it.
    let scoredInCatalog: [ArtifactRecallQuestion]
    let questionsOutsideCatalog: Int
    if config.targetScale == .unit, let catalogPath = config.catalogPath {
        (scoredInCatalog, questionsOutsideCatalog) = try partitionQuestionsByCatalog(
            scoredPool, catalogPath: catalogPath)
    } else {
        scoredInCatalog = scoredPool
        questionsOutsideCatalog = 0
    }

    let questions = applyArtifactLimit(scoredInCatalog, limit: config.limit)
    guard !questions.isEmpty else {
        throw MCPError(description:
            "no scorable questions (loaded \(all.count), no_evidence \(noEvidence), "
            + "outside_catalog \(questionsOutsideCatalog))")
    }

    FileHandle.standardError.write(Data(
        ("[artifact-recall] dataset=\(config.dataset.rawValue) "
         + "scale=\(config.targetScale.rawValue) "
         + "questions=\(questions.count) scope=\(config.scope.rawValue) "
         + "top-k=\(config.topK) no_evidence=\(noEvidence)\n").utf8))

    var outcomes: [ArtifactQuestionOutcome] = []
    var unitCount = 1
    switch config.targetScale {
    case .benchAggregate, .completeAggregate:
        guard let estateDir = config.estateDir else {
            throw MCPError(description:
                "\(config.targetScale.rawValue) requires --estate-dir")
        }
        outcomes = try await askArtifactQuestions(
            estateDir: estateDir, questions: questions, config: config)
    case .unit:
        guard let catalogPath = config.catalogPath else {
            throw MCPError(description: "unit scale requires --catalog")
        }
        // Group by unit stem in first-appearance order so runs are
        // deterministic and each unit estate is opened exactly once.
        var order: [String] = []
        var groups: [String: [ArtifactRecallQuestion]] = [:]
        for q in questions {
            if groups[q.unitStem] == nil { order.append(q.unitStem) }
            groups[q.unitStem, default: []].append(q)
        }
        unitCount = order.count
        for (index, stem) in order.enumerated() {
            let unitDir = try artifactUnitEstateDir(catalogPath: catalogPath, id: stem)
            FileHandle.standardError.write(Data(
                ("[artifact-recall] unit \(index + 1)/\(order.count): "
                 + "\(stem) (\(groups[stem]!.count) questions)\n").utf8))
            outcomes += try await askArtifactQuestions(
                estateDir: unitDir, questions: groups[stem]!, config: config)
        }
    }

    let report = artifactRecallReport(
        config: config, outcomes: outcomes, noEvidence: noEvidence,
        unitCount: unitCount, questionsInFile: all.count,
        questionsOutsideCatalog: questionsOutsideCatalog)
    let data = try JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: config.outPath)
    let hits = outcomes.filter(\.hitAtK).count
    FileHandle.standardError.write(Data(
        ("[artifact-recall] hit@\(config.topK)="
         + String(format: "%.4f", Double(hits) / Double(outcomes.count))
         + " mrr=" + String(format: "%.4f",
             outcomes.map(\.reciprocalRank).reduce(0, +) / Double(outcomes.count))
         + " → \(config.outPath.path)\n").utf8))
}

/// Builds the report JSON object (JSONSerialization-compatible).
///
/// `questionsInFile` is the total row count of questions.jsonl (before the
/// no_evidence split or any catalog/limit filtering) — "how many questions
/// the file held". `questionsOutsideCatalog` is how many scored questions
/// named a unit stem the catalog does not carry (unit scale with a bounded
/// fleet build only; 0 at every other scale). `n_questions` remains the
/// count actually measured (== `outcomes.count`); `questions_measured` is
/// the same value under the name the bounded-catalog contract names it by.
private func artifactRecallReport(
    config: ArtifactRecallConfig,
    outcomes: [ArtifactQuestionOutcome],
    noEvidence: Int,
    unitCount: Int,
    questionsInFile: Int,
    questionsOutsideCatalog: Int
) -> [String: Any] {
    let n = outcomes.count
    let hitAtK = Double(outcomes.filter(\.hitAtK).count) / Double(n)
    let mrr = outcomes.map(\.reciprocalRank).reduce(0, +) / Double(n)

    // Per-label breakdown (locomo category, convomem set, membench
    // family/category, lme-s question_type).
    var perCategory: [String: Any] = [:]
    for (label, group) in Dictionary(grouping: outcomes, by: { $0.question.label }) {
        perCategory[label] = [
            "n": group.count,
            "hit_at_k": Double(group.filter(\.hitAtK).count) / Double(group.count),
            "mrr": group.map(\.reciprocalRank).reduce(0, +) / Double(group.count),
        ]
    }

    // Misses capped at 50 (file order) so a bad run stays inspectable without
    // the report ballooning to corpus size.
    let misses: [[String: Any]] = outcomes.filter { !$0.hitAtK }.prefix(50).map {
        [
            "sample_id": $0.question.sampleID,
            "question": $0.question.question,
            "expected": $0.question.answerSessionIDs,
            "got_top3": Array($0.rankedSeedIDs.prefix(3)),
        ]
    }

    return [
        "config": [
            "dataset": config.dataset.rawValue,
            "target_scale": config.targetScale.rawValue,
            "estate_dir": config.estateDir?.path ?? "",
            "catalog": config.catalogPath?.path ?? "",
            "questions": config.questionsPath.path,
            "scope": config.scope.rawValue,
            "id_prefix": config.idPrefix,
            "limit": config.limit,
            "top_k": config.topK,
            "binary": config.mootBinaryPath,
        ],
        "n_questions": n,
        "n_units": unitCount,
        "no_evidence": noEvidence,
        "questions_in_file": questionsInFile,
        "questions_measured": n,
        "questions_outside_catalog": questionsOutsideCatalog,
        "hit_at_k": hitAtK,
        "mrr": mrr,
        "per_category": perCategory,
        "misses": misses,
    ]
}

// MARK: - CLI entry

/// The `artifact-recall` subcommand: parses flags and runs the lane.
func runArtifactRecall(_ args: [String]) async throws {
    guard let datasetStr = optionValue("--dataset", in: args),
          let dataset = ArtifactDataset(rawValue: datasetStr) else {
        throw MCPError(description:
            "artifact-recall requires --dataset "
            + ArtifactDataset.allCases.map(\.rawValue).joined(separator: "|"))
    }
    let scaleStr = optionValue("--target-scale", in: args) ?? "bench-aggregate"
    guard let targetScale = ArtifactTargetScale(rawValue: scaleStr) else {
        throw MCPError(description:
            "--target-scale must be unit|bench-aggregate|complete-aggregate; "
            + "got '\(scaleStr)'")
    }
    let estateDirStr = optionValue("--estate-dir", in: args)
    let catalogStr = optionValue("--catalog", in: args)
    switch targetScale {
    case .unit:
        guard catalogStr != nil else {
            throw MCPError(description: "--target-scale unit requires --catalog <path to catalog.json>")
        }
    case .benchAggregate, .completeAggregate:
        guard estateDirStr != nil else {
            throw MCPError(description:
                "--target-scale \(targetScale.rawValue) requires --estate-dir <path>")
        }
    }
    guard let questionsStr = optionValue("--questions", in: args) else {
        throw MCPError(description: "artifact-recall requires --questions <jsonl path>")
    }
    let scopeStr = optionValue("--scope", in: args) ?? "wing"
    guard let scope = ArtifactRecallScope(rawValue: scopeStr) else {
        throw MCPError(description: "--scope must be 'wing' or 'estate'; got '\(scopeStr)'")
    }
    // Complete-aggregate expected ids carry the dataset prefix minted by
    // build_complete.py ("<dataset>/"); overridable for future layouts.
    let idPrefix = optionValue("--id-prefix", in: args)
        ?? (targetScale == .completeAggregate ? "\(dataset.rawValue)/" : "")
    let limit = (try parseLimitOption(in: args)) ?? 0
    let topK = optionValue("--top-k", in: args).flatMap(Int.init) ?? 10
    guard topK > 0 else {
        throw MCPError(description: "--top-k must be positive; got \(topK)")
    }
    let outPath = optionValue("--out", in: args) ?? "artifact-recall-report.json"

    // Same binary resolution as every other lane: --mootx01-binary (Swift
    // spelling) / --binary (Rust twin's spelling) / tree-build discovery.
    let mootBinary: String
    if let explicit = optionValue("--mootx01-binary", in: args) ?? optionValue("--binary", in: args) {
        mootBinary = explicit
    } else if let discovered = discoverMootBinary() {
        mootBinary = discovered
        FileHandle.standardError.write(Data(
            "[artifact-recall] auto-discovered mootx01 at: \(discovered)\n".utf8))
    } else {
        throw MCPError(description:
            "mootx01 binary not found. Build with `swift build --package-path apps/mootx01` "
            + "or pass --mootx01-binary <path>.")
    }
    guard FileManager.default.isExecutableFile(atPath: mootBinary) else {
        throw MCPError(description: "mootx01 binary not executable at '\(mootBinary)'")
    }

    try await runArtifactRecallLane(config: ArtifactRecallConfig(
        dataset: dataset,
        targetScale: targetScale,
        estateDir: estateDirStr.map(URL.init(fileURLWithPath:)),
        catalogPath: catalogStr.map(URL.init(fileURLWithPath:)),
        questionsPath: URL(fileURLWithPath: questionsStr),
        scope: scope,
        idPrefix: idPrefix,
        limit: limit,
        topK: topK,
        outPath: URL(fileURLWithPath: outPath),
        mootBinaryPath: mootBinary))
}
