import Foundation
import OSLog
import LocusKit
import GeniusLocusKit

// JsonImportBridge — the fourth import lane (seed-file JSON, schema v1).
//
// Sits beside the three shipping lanes (Obsidian/Markdown via VaultBridge,
// MemPalace via PalaceBridge, GKF via the exchange adapter) and follows their
// common bulk-import topology with three deliberate mutations:
//
//   1. TOTAL PRE-WRITE VALIDATION replaces count-and-skip guards. The seed
//      file is machine-generated interchange, not human vault content: any
//      schema violation means the producer is broken, so the import performs
//      ZERO writes and returns one error naming the FIRST offending element.
//      Never a partial estate.
//   2. FILE ORDER IS INGESTION ORDER. `records` array order is semantic
//      (supersession chains, timelines); the importer never sorts.
//   3. THE IMPORTER ENDS AT ENCODE ENQUEUE. Drain barrier and dream are
//      caller protocol steps (the seed-run protocol), not import steps.
//
// The canonical schema definition ships with this code at
// `packages/kits/VaultKit/docs/JSON_IMPORT_FORMAT.md`. The Rust twin is
// `rust/src/json_import_bridge.rs`; validator error messages are pinned
// byte-identical across ports so the determinism verification script can
// compare failure output as well as estate inventories.

// MARK: - Limits

/// Ceilings enforced on an untrusted seed file — the `MemPalaceImportLimits`
/// pattern applied to the JSON lane. ONE budget covers the whole import:
/// the byte ceiling is charged from the filesystem size BEFORE the file is
/// read into memory, and the row ceiling is the total across records, facts,
/// and tunnels (not a fresh allowance per section).
public struct JsonImportLimits: Sendable, Equatable {

    /// Maximum seed-file size in bytes. Checked against the on-disk size
    /// before the file is opened, so an oversized file is never read.
    /// Default 512 MiB: comfortably above the largest benchmark seed
    /// (~100 MB) while still refusing a runaway or hostile file.
    public var maxSeedFileBytes: Int

    /// Maximum total element count (records + facts + tunnels). Default
    /// 2,000,000 — an order of magnitude above the largest benchmark seed,
    /// same "totals for the import" intent as `MemPalaceImportLimits.maxRows`.
    public var maxRows: Int

    public init(
        maxSeedFileBytes: Int = 512 * 1024 * 1024,
        maxRows: Int = 2_000_000
    ) {
        self.maxSeedFileBytes = maxSeedFileBytes
        self.maxRows = maxRows
    }

    /// The shipping ceilings.
    public static let `default` = JsonImportLimits()
}

// MARK: - Schema types (seed-file schema v1)

/// One validated record from the seed file's `records` array.
public struct JsonSeedRecord: Sendable, Equatable {
    /// File-unique stable id; the lineage anchor
    /// (`DrawerMapping.lineageID(forStableSourceKey:)` over this string).
    public var id: String
    /// Non-empty drawer content (I-5).
    public var content: String
    /// Event time — schema v1 pins UTC ISO8601 with a trailing "Z"
    /// (offset forms are rejected for cross-port parser parity).
    public var eventTime: Date
    /// Optional wing; nil files under the import's default wing.
    public var wing: String?
    /// Non-empty room path.
    public var room: String
    /// Content kind; schema default `prose`.
    public var kind: ContentKind
    /// Sensitivity adjective; schema default `normal`.
    public var sensitivity: AdjectiveSensitivity
    /// Exportability adjective; schema default `private`.
    public var exportability: AdjectiveExportability
}

/// One validated fact from the seed file's `facts` array. `recordID` is
/// guaranteed by the validator to resolve to a record id in the same file.
public struct JsonSeedFact: Sendable, Equatable {
    public var subject: String
    public var predicate: String
    public var object: String
    public var recordID: String
}

/// One validated tunnel from the seed file's `tunnels` array. `from`/`to`
/// are guaranteed by the validator to resolve to record ids in the same
/// file; `kind` is a member of the closed `TunnelKind` vocabulary.
public struct JsonSeedTunnel: Sendable, Equatable {
    public var from: String
    public var to: String
    public var kind: TunnelKind
    /// Optional label; nil gets the same "source -> target" fill-in the
    /// palace lane applies (I-5: non-empty body), resolved at import time
    /// when endpoint locations are known.
    public var label: String?
}

/// A fully validated seed file. Constructing one via `parse(data:limits:)`
/// IS phases 1–2 of the import: after it returns, every schema rule holds
/// and the import may proceed to estate work knowing the file cannot fail
/// validation mid-write.
public struct JsonSeedFile: Sendable, Equatable {

    /// The only version this parser accepts.
    public static let supportedFormatVersion = 1

    public var formatVersion: Int
    /// Non-empty seed name (carried into the receipt for traceability).
    public var name: String
    /// Records in FILE ORDER — the validator never reorders them.
    public var records: [JsonSeedRecord]
    public var facts: [JsonSeedFact]
    public var tunnels: [JsonSeedTunnel]

    // Closed key vocabularies (rigid schema: unknown keys are hard errors,
    // because a misspelled optional key silently changing an estate is
    // exactly the partial-damage class this lane exists to eliminate).
    private static let topLevelKeys: Set<String> =
        ["format_version", "name", "records", "facts", "tunnels"]
    private static let recordKeys: Set<String> =
        ["id", "content", "event_time", "wing", "room", "kind",
         "sensitivity", "exportability"]
    private static let factKeys: Set<String> =
        ["subject", "predicate", "object", "record_id"]
    private static let tunnelKeys: Set<String> =
        ["from", "to", "kind", "label"]

    /// Record kinds admitted at this boundary — the same six content kinds
    /// the `moot_file_memory` surface accepts. The internal kinds
    /// (`fingerprintOnly`, `dataset`) are deliberately NOT importable: they
    /// are system-managed representations, not seedable content.
    private static let kindLabels: [String: ContentKind] = [
        "prose": .prose, "code": .code, "transcript": .transcript,
        "list": .list, "structuredJSON": .structuredJSON,
        "imageCaption": .imageCaption,
    ]

    /// Tunnel kind labels — the full closed `TunnelKind` vocabulary, spelled
    /// as the Swift case names (the canonical spelling in schema v1).
    private static let tunnelKindLabels: [String: TunnelKind] = [
        "supersedes": .supersedes, "references": .references,
        "blocks": .blocks, "validates": .validates,
        "contradicts": .contradicts, "derivesFrom": .derivesFrom,
        "covers": .covers, "elaborates": .elaborates,
        "respondsTo": .respondsTo, "parent": .parent,
    ]
    private static let tunnelKindVocabulary =
        "supersedes, references, blocks, validates, contradicts, "
        + "derivesFrom, covers, elaborates, respondsTo, parent"

    // MARK: Parse + total validation (phases 1–2)

    /// Parse and validate a whole seed file BEFORE any estate work.
    ///
    /// Any violation throws `VaultKitError.adapterError` with ONE message
    /// naming the first offending element (record index + id where
    /// applicable). Messages are pinned byte-identical to the Rust twin.
    public static func parse(data: Data, limits: JsonImportLimits) throws -> JsonSeedFile {
        // Byte ceiling on the in-memory document. `importSeed` additionally
        // charges the on-disk size before reading (palace pattern); this
        // check keeps the parser safe for callers that hand it raw bytes.
        guard data.count <= limits.maxSeedFileBytes else {
            throw err("seed file exceeds byte ceiling: \(data.count) bytes > limit \(limits.maxSeedFileBytes)")
        }

        // Phase 1 — parse. Library error detail is deliberately NOT included:
        // Foundation and serde_json phrase failures differently, and the
        // determinism script compares error output across ports.
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
            throw err("seed file is malformed JSON")
        }
        guard let root = parsed as? [String: Any] else {
            throw err("seed file top level must be a JSON object")
        }

        // Rigid schema: unknown top-level keys are hard errors. Sorted so
        // the "first" offender is deterministic across map orderings.
        if let unknown = root.keys.filter({ !topLevelKeys.contains($0) }).sorted().first {
            throw err("unknown top-level key \"\(unknown)\" — schema v1 keys are format_version, name, records, facts, tunnels")
        }

        // format_version gate runs FIRST among field checks: a future-version
        // file must fail on the version, not on whatever field changed.
        guard let versionValue = root["format_version"] else {
            throw err("format_version is missing (expected 1)")
        }
        guard let version = intValue(versionValue) else {
            throw err("format_version must be an integer (expected 1)")
        }
        guard version == supportedFormatVersion else {
            throw err("unsupported format_version: found \(version), expected 1")
        }

        guard let name = root["name"] as? String, !name.isEmpty else {
            throw err("name is missing or empty")
        }

        guard let recordsRaw = root["records"] as? [Any] else {
            throw err("records is missing (expected an array)")
        }
        let factsRaw = try optionalArray(root, "facts")
        let tunnelsRaw = try optionalArray(root, "tunnels")

        // Row ceiling — ONE total across all three sections.
        let totalRows = recordsRaw.count + factsRaw.count + tunnelsRaw.count
        guard totalRows <= limits.maxRows else {
            throw err("seed file exceeds row ceiling: \(totalRows) elements > limit \(limits.maxRows)")
        }

        // Phase 2 — total validation, in file order, first offender wins.
        var records: [JsonSeedRecord] = []
        records.reserveCapacity(recordsRaw.count)
        var seenIDs: Set<String> = []
        for (index, element) in recordsRaw.enumerated() {
            let record = try parseRecord(element, index: index, seenIDs: &seenIDs)
            records.append(record)
        }
        let recordIDs = seenIDs

        var facts: [JsonSeedFact] = []
        facts.reserveCapacity(factsRaw.count)
        for (index, element) in factsRaw.enumerated() {
            facts.append(try parseFact(element, index: index, recordIDs: recordIDs))
        }

        var tunnels: [JsonSeedTunnel] = []
        tunnels.reserveCapacity(tunnelsRaw.count)
        for (index, element) in tunnelsRaw.enumerated() {
            tunnels.append(try parseTunnel(element, index: index, recordIDs: recordIDs))
        }

        return JsonSeedFile(
            formatVersion: version, name: name,
            records: records, facts: facts, tunnels: tunnels)
    }

    // MARK: Element parsers

    private static func parseRecord(
        _ element: Any, index: Int, seenIDs: inout Set<String>
    ) throws -> JsonSeedRecord {
        guard let object = element as? [String: Any] else {
            throw err("record[\(index)]: must be a JSON object")
        }
        // id first so every later error can name it.
        guard let id = object["id"] as? String, !id.isEmpty else {
            throw err("record[\(index)]: id is missing or empty")
        }
        let at = "record[\(index)] (id \"\(id)\")"

        if let unknown = object.keys.filter({ !recordKeys.contains($0) }).sorted().first {
            throw err("\(at): unknown key \"\(unknown)\" — schema v1 record keys are id, content, event_time, wing, room, kind, sensitivity, exportability")
        }
        guard !seenIDs.contains(id) else {
            throw err("\(at): duplicate id — ids must be unique within the seed file")
        }
        seenIDs.insert(id)

        guard let content = object["content"] as? String, !content.isEmpty else {
            throw err("\(at): content is missing or empty (I-5: content must be non-empty)")
        }
        guard let eventTimeRaw = object["event_time"] as? String else {
            throw err("\(at): event_time is missing (expected UTC ISO8601, e.g. 2026-01-03T09:00:00Z)")
        }
        guard let eventTime = parseUTCISO8601(eventTimeRaw) else {
            throw err("\(at): event_time is not UTC ISO8601 (\"\(eventTimeRaw)\" — expected the form 2026-01-03T09:00:00Z; offset forms are not accepted)")
        }
        guard let room = object["room"] as? String, !room.isEmpty else {
            throw err("\(at): room is missing or empty")
        }

        var wing: String?
        if object.keys.contains("wing") {
            guard let wingValue = object["wing"] as? String, !wingValue.isEmpty else {
                throw err("\(at): wing is empty (omit it to use the default wing)")
            }
            wing = wingValue
        }

        var kind: ContentKind = .prose
        if object.keys.contains("kind") {
            guard let label = object["kind"] as? String, let parsed = kindLabels[label] else {
                throw err("\(at): unknown kind \"\(stringOrType(object["kind"]))\" (valid: prose, code, transcript, list, structuredJSON, imageCaption)")
            }
            kind = parsed
        }

        var sensitivity: AdjectiveSensitivity = .normal
        if object.keys.contains("sensitivity") {
            guard let label = object["sensitivity"] as? String,
                  let parsed = DrawerMapping.sensitivity(fromLabel: label) else {
                throw err("\(at): unknown sensitivity \"\(stringOrType(object["sensitivity"]))\" (valid: normal, elevated, restricted, secret)")
            }
            sensitivity = parsed
        }

        var exportability: AdjectiveExportability = .private_
        if object.keys.contains("exportability") {
            guard let label = object["exportability"] as? String,
                  let parsed = DrawerMapping.exportability(fromLabel: label) else {
                throw err("\(at): unknown exportability \"\(stringOrType(object["exportability"]))\" (valid: private, public)")
            }
            exportability = parsed
        }

        return JsonSeedRecord(
            id: id, content: content, eventTime: eventTime, wing: wing,
            room: room, kind: kind, sensitivity: sensitivity,
            exportability: exportability)
    }

    private static func parseFact(
        _ element: Any, index: Int, recordIDs: Set<String>
    ) throws -> JsonSeedFact {
        guard let object = element as? [String: Any] else {
            throw err("fact[\(index)]: must be a JSON object")
        }
        let at = "fact[\(index)]"
        if let unknown = object.keys.filter({ !factKeys.contains($0) }).sorted().first {
            throw err("\(at): unknown key \"\(unknown)\" — schema v1 fact keys are subject, predicate, object, record_id")
        }
        // Required-and-non-empty, in a fixed field order so the first
        // offender is deterministic.
        var fields: [String: String] = [:]
        for key in ["subject", "predicate", "object", "record_id"] {
            guard let value = object[key] as? String, !value.isEmpty else {
                throw err("\(at): \(key) is missing or empty")
            }
            fields[key] = value
        }
        let recordID = fields["record_id"]!
        guard recordIDs.contains(recordID) else {
            throw err("\(at): record_id \"\(recordID)\" does not resolve to a record id in this file")
        }
        return JsonSeedFact(
            subject: fields["subject"]!, predicate: fields["predicate"]!,
            object: fields["object"]!, recordID: recordID)
    }

    private static func parseTunnel(
        _ element: Any, index: Int, recordIDs: Set<String>
    ) throws -> JsonSeedTunnel {
        guard let object = element as? [String: Any] else {
            throw err("tunnel[\(index)]: must be a JSON object")
        }
        let at = "tunnel[\(index)]"
        if let unknown = object.keys.filter({ !tunnelKeys.contains($0) }).sorted().first {
            throw err("\(at): unknown key \"\(unknown)\" — schema v1 tunnel keys are from, to, kind, label")
        }
        guard let from = object["from"] as? String, !from.isEmpty else {
            throw err("\(at): from is missing or empty")
        }
        guard recordIDs.contains(from) else {
            throw err("\(at): from \"\(from)\" does not resolve to a record id in this file")
        }
        guard let to = object["to"] as? String, !to.isEmpty else {
            throw err("\(at): to is missing or empty")
        }
        guard recordIDs.contains(to) else {
            throw err("\(at): to \"\(to)\" does not resolve to a record id in this file")
        }
        guard let kindLabel = object["kind"] as? String, let kind = tunnelKindLabels[kindLabel] else {
            throw err("\(at): unknown kind \"\(stringOrType(object["kind"]))\" (valid: \(tunnelKindVocabulary))")
        }
        var label: String?
        if object.keys.contains("label") {
            guard let labelValue = object["label"] as? String, !labelValue.isEmpty else {
                throw err("\(at): label is empty (omit it to use the generated default)")
            }
            label = labelValue
        }
        return JsonSeedTunnel(from: from, to: to, kind: kind, label: label)
    }

    // MARK: Small helpers

    private static func err(_ message: String) -> VaultKitError {
        .adapterError(message)
    }

    /// `facts` / `tunnels` are optional sections; when present they must be
    /// arrays (a non-array value is a schema violation, not an empty default).
    private static func optionalArray(_ root: [String: Any], _ key: String) throws -> [Any] {
        guard let value = root[key] else { return [] }
        guard let array = value as? [Any] else {
            throw err("\(key) must be an array when present")
        }
        return array
    }

    /// Strict integer extraction: JSONSerialization surfaces numbers as
    /// NSNumber; a fractional value (1.5) must NOT truncate to a valid
    /// version, so the double round-trip is checked.
    private static func intValue(_ value: Any) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        // Reject booleans (NSNumber bridges true/false) and fractionals.
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let int = number.intValue
        guard Double(int) == number.doubleValue else { return nil }
        return int
    }

    /// Render an unknown-value diagnostic: the string itself when the value
    /// is a string (the common case — a bad label), else its JSON type name.
    private static func stringOrType(_ value: Any?) -> String {
        if let s = value as? String { return s }
        switch value {
        case is NSNumber: return "<number>"
        case is [Any]: return "<array>"
        case is [String: Any]: return "<object>"
        case nil, is NSNull: return "<null>"
        default: return "<unknown>"
        }
    }

    /// Schema v1 event_time parser: UTC ISO8601 with a REQUIRED trailing
    /// "Z". Exactly two shapes are accepted — `YYYY-MM-DDTHH:MM:SSZ` and
    /// `YYYY-MM-DDTHH:MM:SS.fffZ` (milliseconds, exactly 3 fraction
    /// digits). Offset forms ("+02:00") and other fraction widths are
    /// rejected even though Foundation could parse some of them, because
    /// the Rust twin's dependency-free parser must accept the byte-
    /// identical input set — the two shapes above are the pinned contract.
    private static func parseUTCISO8601(_ s: String) -> Date? {
        // Shape pin: 20 chars plain, or 24 chars with ".fff" at index 19.
        guard s.hasSuffix("Z") else { return nil }
        let chars = Array(s)
        switch s.count {
        case 20:
            break
        case 24:
            guard chars[19] == "." else { return nil }
            guard chars[20...22].allSatisfy(\.isNumber) else { return nil }
        default:
            return nil
        }
        // Component + calendar validation is EXPLICIT rather than delegated
        // to ISO8601DateFormatter, which leniently rolls invalid dates over
        // (2026-02-30 parses as March 2). A rigid schema rejects them, and
        // the Rust twin's dependency-free parser applies these exact checks.
        guard chars[4] == "-", chars[7] == "-", chars[10] == "T",
              chars[13] == ":", chars[16] == ":" else { return nil }
        let digitIndexes = [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]
        guard digitIndexes.allSatisfy({ chars[$0].isNumber }) else { return nil }
        func field(_ range: ClosedRange<Int>) -> Int {
            Int(String(chars[range]))!
        }
        let year = field(0...3), month = field(5...6), day = field(8...9)
        let hour = field(11...12), minute = field(14...15), second = field(17...18)
        guard (1...12).contains(month), hour <= 23, minute <= 59, second <= 59 else {
            return nil
        }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let daysInMonth = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...daysInMonth[month - 1]).contains(day) else { return nil }

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = s.count == 24
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return fmt.date(from: s)
    }
}
