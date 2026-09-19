import Foundation

// LMEBCorpus.swift — LMEB/ConvoMem retrieval corpus loader.
//
// Schema verified 2026-07-26 against KaLM-Embedding/LMEB on HuggingFace.
// The dataset is never committed; see scripts/fetch-lmeb.sh to download.
//
// LMEB uses a per-evidence-type directory structure. Each directory contains
// four files (JSONL + TSV, not exposed together by the HuggingFace datasets API):
//
//   corpus.jsonl     — { "id": str, "text": str, "title": str }
//   queries.jsonl    — { "id": str, "text": str }
//   candidates.jsonl — { "scene_id": str, "candidate_doc_ids": [str] }
//   qrels.tsv        — query_id TAB corpus_id TAB score  (no header; score always "1")
//
// ConvoMem evidence types (6 splits):
//   abstention_evidence, assistant_facts_evidence, changing_evidence,
//   implicit_connection_evidence, preference_evidence, user_evidence
//
// Key schema facts (verified 2026-07-26):
//   - corpus docs are individual conversation TURNS (id: "scene_X_session_Y_turn_Z")
//   - query IDs encode the scene: "scene_X_q_N" → scene_id = "scene_X"
//   - candidates.jsonl maps scene_id → all candidate turn IDs for that scene
//   - qrels.tsv is absent from the HuggingFace datasets API; it must be
//     downloaded directly (see LME-06_BLAST_RADIUS.md §Schema Discovery)
//   - binary relevance: all qrel scores are 1; average 2.35 relevant docs/query
//
// This loader merges all requested evidence types into a single LMEBCorpus.
// Typical usage for tests: pass just ["user_evidence"] with the sample directory.
// Production usage: pass all six evidence types with the full data directory.

// MARK: - Public types

/// One LMEB corpus document — a single conversation turn.
struct LMEBDoc: Sendable {
    /// Unique turn identifier, e.g. "scene_0_session_1_turn_9".
    let id: String
    /// Conversation turn text (e.g. "User: I love restoring chairs.").
    let text: String
    /// Human-readable label, e.g. "Session 1, Turn 9".
    let title: String
}

/// One LMEB query.
struct LMEBQuery: Sendable {
    /// Query identifier, e.g. "scene_0_q_0".
    let id: String
    /// Question text.
    let text: String
    /// Gold answer for judge grading. Optional: the LMEB retrieval benchmark
    /// does not guarantee an answer field in queries.jsonl. When nil the judge
    /// is silently skipped for this query and it contributes to judged_count
    /// only when it was actually graded. Real LMEB QA evaluations (the published
    /// QA accuracy figure) require an answer-enriched queries.jsonl.
    let answer: String?
}

/// Loader error carrying a description that names the file and line (or field)
/// where the problem was found.
struct LMEBLoadError: Error, CustomStringConvertible {
    let description: String
}

/// The fully-loaded LMEB/ConvoMem corpus, ready for evaluation.
///
/// Use `candidateDocs(forQuery:)` to retrieve the retrieval scope for a query,
/// and `relevantDocs(forQuery:)` to retrieve the ground-truth relevant set.
struct LMEBCorpus: Sendable {
    /// Corpus documents indexed by ID.
    let docsByID: [String: LMEBDoc]
    /// Queries indexed by ID.
    let queriesByID: [String: LMEBQuery]
    /// Per-scene candidate document IDs (from candidates.jsonl).
    let candidatesBySceneID: [String: [String]]
    /// Per-query set of relevant document IDs (from qrels.tsv).
    let relevantDocsByQueryID: [String: Set<String>]

    /// Total corpus document count.
    var docCount: Int { docsByID.count }
    /// Total query count.
    var queryCount: Int { queriesByID.count }
    /// Total qrel count (sum of per-query relevant-doc sets).
    var qrelCount: Int { relevantDocsByQueryID.values.reduce(0) { $0 + $1.count } }

    /// Candidate document IDs for the scene of the given query.
    ///
    /// Scene ID is derived by stripping the `_q_N` suffix:
    ///   "scene_42_q_3" → "scene_42"
    ///
    /// Returns an empty array if the scene has no registered candidate pool.
    func candidateDocs(forQuery queryID: String) -> [String] {
        let sceneID: String
        if let range = queryID.range(of: "_q_", options: .backwards) {
            sceneID = String(queryID[queryID.startIndex ..< range.lowerBound])
        } else {
            sceneID = queryID
        }
        return candidatesBySceneID[sceneID] ?? []
    }

    /// Relevant document IDs for a query (empty set if none).
    func relevantDocs(forQuery queryID: String) -> Set<String> {
        relevantDocsByQueryID[queryID] ?? []
    }
}

// MARK: - Raw Decodable types (private)

/// Raw JSONL row for corpus.jsonl.
private struct LMEBDocRaw: Decodable {
    let id: String
    let text: String
    let title: String
}

/// Raw JSONL row for queries.jsonl.
/// `answer` is optional: the base LMEB retrieval dataset may omit it;
/// QA-accuracy-enriched variants include it for judge grading.
private struct LMEBQueryRaw: Decodable {
    let id: String
    let text: String
    let answer: String?
}

/// Raw JSONL row for candidates.jsonl.
private struct LMEBCandidatesRaw: Decodable {
    let sceneID: String
    let candidateDocIDs: [String]

    enum CodingKeys: String, CodingKey {
        case sceneID         = "scene_id"
        case candidateDocIDs = "candidate_doc_ids"
    }
}

// MARK: - Internal helpers

/// Parses a JSONL file (one JSON object per line) into an array of `T`.
///
/// Empty and whitespace-only lines are skipped. Fails fast on any decode error,
/// naming the line index in the error message.
private func loadJSONL<T: Decodable>(
    _ url: URL,
    label: String
) throws -> [T] {
    let content: String
    do {
        content = try String(contentsOf: url, encoding: .utf8)
    } catch {
        throw LMEBLoadError(description: "\(label): could not read file: \(error)")
    }

    let decoder = JSONDecoder()
    var results: [T] = []
    var lineIndex = 0
    for line in content.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        guard let data = trimmed.data(using: .utf8) else {
            throw LMEBLoadError(
                description: "\(label) line \(lineIndex): cannot convert to UTF-8 data")
        }
        do {
            let item = try decoder.decode(T.self, from: data)
            results.append(item)
        } catch {
            throw LMEBLoadError(
                description: "\(label) line \(lineIndex): decode failed: \(error)")
        }
        lineIndex += 1
    }
    return results
}

/// Parses a qrels TSV file (no header) into a query_id → relevant_doc_id mapping.
///
/// Format per line: `query_id\tcorpus_id\tscore`
/// All LMEB ConvoMem qrel scores are "1" (binary relevance).
/// Lines with fewer than 2 tab-separated fields are rejected with a clear error.
private func parseQrels(
    _ url: URL,
    label: String
) throws -> [String: Set<String>] {
    let content: String
    do {
        content = try String(contentsOf: url, encoding: .utf8)
    } catch {
        throw LMEBLoadError(description: "\(label): could not read qrels file: \(error)")
    }

    var result: [String: Set<String>] = [:]
    var lineIndex = 0
    for line in content.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        let parts = trimmed.components(separatedBy: "\t")
        guard parts.count >= 2 else {
            throw LMEBLoadError(
                description: "\(label) qrels line \(lineIndex): expected at least 2 "
                + "tab-separated fields, got \(parts.count): \(trimmed.prefix(80))")
        }
        let queryID = parts[0]
        let corpusID = parts[1]
        guard !queryID.isEmpty, !corpusID.isEmpty else {
            throw LMEBLoadError(
                description: "\(label) qrels line \(lineIndex): empty query_id or corpus_id")
        }
        result[queryID, default: []].insert(corpusID)
        lineIndex += 1
    }
    return result
}

// MARK: - Public API

/// Loads the LMEB/ConvoMem corpus from a directory tree.
///
/// - Parameters:
///   - baseDir: Root directory that contains one subdirectory per evidence type
///              (e.g. `fixtures/lmeb/data/ConvoMem/`).
///   - evidenceTypes: Which evidence-type subdirectories to load. Pass all six
///     for a full production run; pass `["user_evidence"]` for test fixtures.
/// - Returns: A merged `LMEBCorpus` across all requested evidence types.
/// - Throws: `LMEBLoadError` naming the file, line, and field where loading failed.
///
/// The four required files per evidence type:
///   `{baseDir}/{evidenceType}/corpus.jsonl`
///   `{baseDir}/{evidenceType}/queries.jsonl`
///   `{baseDir}/{evidenceType}/candidates.jsonl`
///   `{baseDir}/{evidenceType}/qrels.tsv`
func loadLMEBCorpus(
    baseDir: URL,
    evidenceTypes: [String]
) throws -> LMEBCorpus {
    var docsByID: [String: LMEBDoc] = [:]
    var queriesByID: [String: LMEBQuery] = [:]
    var candidatesBySceneID: [String: [String]] = [:]
    var relevantDocsByQueryID: [String: Set<String>] = [:]

    // Ids are NAMESPACED BY EVIDENCE TYPE. ConvoMem numbers its scenes and
    // queries from zero inside every category, so `scene_0_q_0` exists in all
    // six. Keying these dictionaries by the raw id made the last category
    // loaded silently overwrite the earlier ones — a corpus that looked
    // complete and had lost five sixths of its items, with no error anywhere.
    // The same collision reached the artifact store, where units are addressed
    // by query id: six categories' units would have shared one directory name.
    //
    // Prefixing is done at the point of load so every downstream consumer —
    // corpus, candidates, qrels, unit ids, reports — sees one id space.
    // Separator is "__", not "/": these ids become FILENAMES (seed exports) and
    // artifact directory names, and a slash makes the writer try to create a
    // subdirectory that is not there — "could not write .../scene_568_q_0.seed.json".
    func namespaced(_ et: String, _ id: String) -> String { "\(et)__\(id)" }

    for et in evidenceTypes {
        let etDir = baseDir.appendingPathComponent(et)
        let label = et  // used in error messages

        // --- corpus.jsonl ---
        let corpusURL = etDir.appendingPathComponent("corpus.jsonl")
        let rawDocs: [LMEBDocRaw] = try loadJSONL(corpusURL, label: "\(label)/corpus.jsonl")
        for (i, raw) in rawDocs.enumerated() {
            guard !raw.id.isEmpty else {
                throw LMEBLoadError(
                    description: "\(label)/corpus.jsonl row \(i): empty 'id' field")
            }
            let docID = namespaced(et, raw.id)
            docsByID[docID] = LMEBDoc(id: docID, text: raw.text, title: raw.title)
        }

        // --- queries.jsonl ---
        let queriesURL = etDir.appendingPathComponent("queries.jsonl")
        let rawQueries: [LMEBQueryRaw] = try loadJSONL(queriesURL, label: "\(label)/queries.jsonl")
        for (i, raw) in rawQueries.enumerated() {
            guard !raw.id.isEmpty else {
                throw LMEBLoadError(
                    description: "\(label)/queries.jsonl row \(i): empty 'id' field")
            }
            let queryID = namespaced(et, raw.id)
            queriesByID[queryID] = LMEBQuery(id: queryID, text: raw.text, answer: raw.answer)
        }

        // --- candidates.jsonl ---
        let candidatesURL = etDir.appendingPathComponent("candidates.jsonl")
        let rawCandidates: [LMEBCandidatesRaw] = try loadJSONL(
            candidatesURL, label: "\(label)/candidates.jsonl")
        for (i, raw) in rawCandidates.enumerated() {
            guard !raw.sceneID.isEmpty else {
                throw LMEBLoadError(
                    description: "\(label)/candidates.jsonl row \(i): empty 'scene_id' field")
            }
            candidatesBySceneID[namespaced(et, raw.sceneID)] =
                raw.candidateDocIDs.map { namespaced(et, $0) }
        }

        // --- qrels.tsv ---
        let qrelsURL = etDir.appendingPathComponent("qrels.tsv")
        let qrels = try parseQrels(qrelsURL, label: label)
        for (queryID, docIDs) in qrels {
            relevantDocsByQueryID[namespaced(et, queryID), default: []]
                .formUnion(docIDs.map { namespaced(et, $0) })
        }
    }

    return LMEBCorpus(
        docsByID: docsByID,
        queriesByID: queriesByID,
        candidatesBySceneID: candidatesBySceneID,
        relevantDocsByQueryID: relevantDocsByQueryID
    )
}

/// Computes a stable content digest for an LMEB corpus directory tree.
///
/// Twin of Rust `lmeb_corpus_digest` in `lmeb_corpus.rs`. The byte layout of
/// `combined` (sort order, filename list, key format `et/name=digest;`, separator)
/// is a cross-port contract: any change here must be mirrored in the Rust twin,
/// and vice versa.
///
/// Algorithm:
/// 1. Sort evidence types ascending. Evidence-type identifiers are ASCII lowercase
///    plus underscore, so Swift `sorted()` and Rust `sort_unstable` agree on every
///    valid input — this agreement is load-bearing across ports.
/// 2. For each evidence type, hash the four required files in fixed ASCII-ascending order.
///    If any file cannot be read, return the literal `"unknown"` immediately.
/// 3. Return `sha256HexOfString` of the concatenated `combined` string.
///
/// The `"unknown"` failure mode is the point of this function: `"unknown"` never
/// validates in `ArtifactProvenance.mismatches` (`ArtifactManifest.swift:144-145`),
/// so a partially-readable corpus refuses to produce a confident-looking but
/// incorrect digest. The sentinel is returned whole and is never folded into the
/// hash: a hashed sentinel is a stable, plausible-looking value that passes the
/// never-validates check, which defeats provenance validation for the whole lane.
func lmebCorpusDigest(baseDir: URL, evidenceTypes: [String]) -> String {
    // ASCII byte-order sort: evidence-type identifiers are lowercase + underscore,
    // so Swift String sorted() and Rust's sort_unstable agree on the same inputs —
    // cross-port contract.
    let sorted = evidenceTypes.sorted()
    guard !sorted.isEmpty else { return "unknown" }
    var combined = ""
    for et in sorted {
        // Fixed filename list in ASCII-ascending order. The order is a cross-port
        // contract: changing it here requires the same change in the Rust twin in
        // lmeb_corpus.rs. Both ports concatenate identically because both iterate
        // this fixed list in this fixed order.
        for name in ["candidates.jsonl", "corpus.jsonl", "qrels.tsv", "queries.jsonl"] {
            let path = baseDir.appendingPathComponent(et).appendingPathComponent(name).path
            guard let d = fileSha256Hex(path: path) else {
                // Any unreadable required file makes the whole digest "unknown".
                // "unknown" never validates in ArtifactProvenance.mismatches
                // (ArtifactManifest.swift:144-145), which is the intended behaviour:
                // an incomplete corpus must not silently produce a stable-looking digest.
                return "unknown"
            }
            combined += "\(et)/\(name)=\(d);"
        }
    }
    return sha256HexOfString(combined)
}
