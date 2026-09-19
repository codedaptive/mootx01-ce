import Foundation

// SeedExport.swift — the shared schema-v1.2 seed-file emitter
// (MXE-JI-2, subject field MXE-JI-4, capture_date field P2a).
//
// EMITTER. Every converted runner's batch seed path and every `--dump-seed`
// goes through `emitSeedJSON` — one seam, never parallel paths (ruling
// 8D5B8053's enforcement note). The output is the seed-file schema v1 the
// `moot_json_import` lane consumes, canonically defined in
// `packages/kits/VaultKit/docs/JSON_IMPORT_FORMAT.md`: dump output ==
// importer input == the third-party interchange artifact.
//
// The writer is hand-rolled rather than JSONEncoder-driven because the dump
// contract is BYTE determinism across BOTH harness ports: seed_export.rs
// implements the identical algorithm and the shared vector file
// `benchmarks/conformance/seed_export_vectors.json` pins the bytes. Format:
//   - 2-space indentation, "key": value, LF line endings, no trailing newline
//   - object keys in ASCII-sorted order ("sorted keys" dump contract)
//   - records array in CALLER order (file order is ingestion order — the
//     importer never sorts, so the emitter must not either)
//   - optional keys omitted when absent (schema v1 is rigid: omission means
//     "apply the default"; null is a schema violation)
//   - the importer's facts[]/tunnels[] sections are authored by the Python
//     seeders (benchmarks/seeding/); this emitter writes records only
//   - string escaping: \" \\ \n \r \t \b \f, any other control char as
//     \u00xx (lowercase hex) — everything else UTF-8 verbatim
//
// ATTRIBUTION PASS. The import receipt reports counts + seedSha256 only —
// no record-id → drawer-UUID map — while several lanes attribute reply-
// surface UUIDs (hunt reports, ranked dense rows) back to corpus records.
// Live seeding got the map for free from each write's "filed memory <UUID>"
// response; the batch path rebuilds it READ-ONLY after the import + drain
// barrier: one `moot_memory_list` per seeded (wing, room) yields dense rows
// (uuid · subject · bestSpan · sscFacts · eventTime), rows are matched to records by
// second-precision event time, and any same-instant collision is settled by
// a `moot_memory_get` whose verbatim content block is compared exactly.
// Drawer UUIDs cannot be derived client-side: the FNV-1a-128 lineage id in
// the schema doc is the drawer's LINEAGE, not its id — `captureBatch` mints
// the drawer id fresh at insert and no MCP surface addresses by lineage.

// MARK: - Seed-file element types

/// One `records[]` element of seed-file schema v1. Field rules (required
/// vs optional, value vocabularies) are the importer's; this type carries
/// exactly what the emitter writes.
struct SeedFileRecord: Sendable, Equatable {
    var id: String
    var content: String
    /// UTC ISO8601 with trailing Z, second or millisecond precision — the
    /// two shapes schema v1 accepts.
    var eventTime: String
    var room: String
    /// nil = omit → the import's default wing ("Agentic Memory", matching
    /// where the live `moot_file_memory` path files when no wing is given).
    var wing: String? = nil
    /// nil = omit → `prose`.
    var kind: String? = nil
    /// nil = omit → `normal`.
    var sensitivity: String? = nil
    /// nil = omit → `private`.
    var exportability: String? = nil
    /// Schema v1.2 capture timestamp. UTC ISO8601 with trailing Z (same two
    /// accepted shapes as `eventTime`). When present, the importer stamps
    /// the drawer's `filedAt` to this instant rather than the batch
    /// wall-clock — the seam the capture-spread benchmark needs to build
    /// estates with spread-out HLC capture times. nil = omit → batch
    /// wall-clock (byte-identical v1.1 behavior). Emitted before `content`
    /// in the ASCII-sorted key order: "capture_date" < "content".
    var captureDate: String? = nil
}

/// How a converted lane loads its seed: `batch` (default) emits schema v1 +
/// one `moot_json_import`; `live` is the retained slow lane (per-record
/// `moot_file_memory`) kept for periodic equivalence re-proving.
///
/// ANY PAYLOAD ABOVE ROUGHLY 25 RECORDS BELONGS ON `batch`, with the import
/// called in background encode speed (`"mode": "background"`). One import
/// carries up to `ImportPolicy.bulkWindow` — 125,000 rows — in a single
/// transaction, and it returns once the rows are written and the encode work
/// is enqueued; the corpus drain worker then fans that encode across the
/// machine. The live lane writes one record per call and waits for each, so it
/// costs N round trips where batch costs one. It exists to prove the two paths
/// agree, not to load anything sizeable.
///
/// The same rule governs how a batch is shaped: one import for the payload and
/// one drain at the end. Splitting a payload into chunks with a drain barrier
/// between them serializes exactly what the product parallelizes, and
/// republishes the resident vector index once per barrier. The timing lane's
/// landscape build did that and took six hours for 100,000 rows; as one
/// background import it takes minutes.
public enum SeedPathMode: String, Sendable {
    case live
    case batch

    /// Parses a `--seed-path` CLI value; nil input = default (`batch`).
    /// Fail-closed on unknown values.
    static func parse(_ raw: String?) throws -> SeedPathMode {
        guard let raw else { return .batch }
        guard let mode = SeedPathMode(rawValue: raw) else {
            throw MCPError(description:
                "--seed-path must be \"live\" or \"batch\"; got '\(raw)'")
        }
        return mode
    }
}

// MARK: - Emitter

/// Serializes one seed file (schema v1.2) deterministically. See the file
/// header for the byte-level format contract; the Rust twin is
/// `seed_export.rs::emit_seed_json` and the shared conformance vectors pin
/// both to the same bytes.
///
/// Schema v1.1: every record always carries a `"subject"` key computed from
/// `deterministicSubject(record.content)`. The emitter is the single seam —
/// no caller or struct change needed.
///
/// Schema v1.2: `captureDate` is emitted as `"capture_date"` before
/// `"content"` when non-nil (ASCII order: "capture_date" < "content").
/// When nil the key is omitted — byte-identical to pre-v1.2 output.
/// Key order: capture_date? < content < event_time < exportability? < id <
/// kind? < room < sensitivity? < subject < wing?.
func emitSeedJSON(
    name: String,
    records: [SeedFileRecord]
) -> Data {
    var out = String()
    out.reserveCapacity(records.count * 180 + 256)

    // Key emission order is the ASCII sort of the keys actually present.
    // Top level: format_version < name < records. The importer's facts[] and
    // tunnels[] sections are authored by the Python seeders
    // (benchmarks/seeding/); this emitter writes records only.
    out += "{\n"
    out += "  \"format_version\": 1,\n"
    out += "  \"name\": \(jsonString(name)),\n"
    if records.isEmpty {
        out += "  \"records\": []"
    } else {
        out += "  \"records\": [\n"
        for (i, r) in records.enumerated() {
            out += "    {\n"
            var lines: [String] = []
            // Schema v1.2: capture_date emitted before content (ASCII order).
            if let v = r.captureDate {
                lines.append("      \"capture_date\": \(jsonString(v))")
            }
            lines.append("      \"content\": \(jsonString(r.content))")
            lines.append("      \"event_time\": \(jsonString(r.eventTime))")
            if let v = r.exportability {
                lines.append("      \"exportability\": \(jsonString(v))")
            }
            lines.append("      \"id\": \(jsonString(r.id))")
            if let v = r.kind {
                lines.append("      \"kind\": \(jsonString(v))")
            }
            lines.append("      \"room\": \(jsonString(r.room))")
            if let v = r.sensitivity {
                lines.append("      \"sensitivity\": \(jsonString(v))")
            }
            // Schema v1.1: subject always emitted (never optional). Computed
            // from content via deterministicSubject — identical to the live
            // arm's moot_file_memory `subject:` argument. Trimmed defensively
            // because prefix(120) can produce a trailing space when the cut
            // lands on whitespace; moot_json_import rejects subjects with
            // leading or trailing whitespace. Key order:
            // sensitivity < subject < wing (ASCII).
            let subject = deterministicSubject(r.content)
                .components(separatedBy: .newlines)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("      \"subject\": \(jsonString(subject))")
            if let v = r.wing {
                lines.append("      \"wing\": \(jsonString(v))")
            }
            out += lines.joined(separator: ",\n") + "\n"
            out += i == records.count - 1 ? "    }\n" : "    },\n"
        }
        out += "  ]"
    }
    out += "\n}"
    return Data(out.utf8)
}

/// JSON string literal with the cross-port escaping contract (file header).
func jsonString(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        case let c where c.value < 0x20:
            out += String(format: "\\u%04x", c.value)
        default:
            out.unicodeScalars.append(scalar)
        }
    }
    return out + "\""
}

/// Writes emitted seed bytes beside the scratch estate and returns the URL
/// handed to `moot_json_import` (which reads the file server-side; the
/// serve process shares the harness filesystem).
///
/// Permissions are set to owner-only (0o600) at creation time so the seed
/// data is never world-readable during the import window.
func writeSeedFile(_ data: Data, in scratchDir: URL, name: String) throws -> URL {
    let url = scratchDir.appendingPathComponent("\(name).seed.json")
    let ok = FileManager.default.createFile(
        atPath: url.path,
        contents: data,
        attributes: [.posixPermissions: 0o600])
    guard ok else {
        throw MCPError(description: "seed export: could not write \(url.path)")
    }
    return url
}

// MARK: - Import id map

/// Reads the `{"id_map":{…}}` block `moot_json_import` returns when called with
/// `return_id_map: true`, and checks it names a drawer for every seeded record.
///
/// This replaces post-hoc attribution. Attribution had to re-discover each
/// drawer by searching for its own content, which cannot be made exact: a room
/// of near-identical records can bury the row at any search limit, and a room
/// above the 200-row listing cap cannot be enumerated at all. The importer
/// already knows the answer — it mints the ids — so it is the only source that
/// can be both exact and total.
///
/// - Parameters:
///   - blocks: The reply's text blocks. The map is its own block; the prose
///     receipt is ignored.
///   - expecting: Number of records seeded. A short map is a hard error, not a
///     partial manifest — scoring against one silently misreports rank.
///   - label: Run identifier for the error message.
/// - Returns: record id → drawer id.
/// - Throws: `MCPError` when no block parses as an id map, or the map is short.
func seedIDMap(
    fromImportBlocks blocks: [String],
    expecting: Int,
    label: String
) throws -> [String: String] {
    for block in blocks {
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { continue }
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(JSONValue.self, from: data),
              let idMapValue = parsed["id_map"],
              case let .object(raw) = idMapValue
        else { continue }
        var map: [String: String] = Dictionary(minimumCapacity: raw.count)
        for (recordID, value) in raw {
            guard let uuid = value.stringValue else {
                throw MCPError(description:
                    "\(label): import id map entry \"\(recordID)\" is not a string")
            }
            map[recordID] = uuid
        }
        guard map.count == expecting else {
            throw MCPError(description:
                "\(label): import id map names \(map.count) drawer(s) for "
                + "\(expecting) seeded record(s) — refusing to score with an "
                + "incomplete manifest")
        }
        return map
    }
    throw MCPError(description:
        "\(label): moot_json_import returned no id_map block — the run asked for "
        + "return_id_map; a server that does not send it cannot be scored")
}


// MARK: - Deterministic event-time synthesis

/// Synthesizes a deterministic ISO8601 UTC event time at `offsetSeconds`
/// seconds after 2026-01-01T00:00:00Z.
///
/// Batch seed builders use this to assign unique, reproducible event times
/// to each record. The live `moot_file_memory` path relies on server-assigned
/// capture times; the batch importer must receive explicit event_time values so
/// records in the same room have distinct, matchable timestamps. Fixed base +
/// monotone per-record increment guarantees uniqueness within one import and
/// reproducibility across re-runs with the same corpus order.
///
/// - Parameter offsetSeconds: 0-based ingest order index → seconds after base.
/// - Returns: A "YYYY-MM-DDTHH:MM:SSZ" string in the Gregorian UTC calendar.
func syntheticEventTime(offsetSeconds: Int) -> String {
    // Decompose the offset into calendar units starting from 2026-01-01T00:00:00Z.
    var rem = offsetSeconds
    let s = rem % 60; rem /= 60
    let m = rem % 60; rem /= 60
    let h = rem % 24; rem /= 24
    // `rem` is now extra days beyond 2026-01-01. Walk the Gregorian calendar.
    // 2026 is not a leap year (not divisible by 4 without remainder for this century).
    let daysInMonth = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    var year = 2026; var month = 1; var day = 1 + rem
    // isLeap: divisible by 4, but not 100, unless also 400.
    func isLeap(_ y: Int) -> Bool { y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) }
    while true {
        let dim = month == 2 && isLeap(year) ? 29 : daysInMonth[month]
        if day <= dim { break }
        day -= dim; month += 1
        if month > 12 { month = 1; year += 1 }
    }
    return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", year, month, day, h, m, s)
}
