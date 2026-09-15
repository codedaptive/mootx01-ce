import AriaMCPWire
import Foundation
import EideticLib
import GeniusLocusKit
import LatticeLib
import LocusKit
import VaultKit

/// The data-mobility operations remain unregistered until their selected
/// surface supplies one lower-kit authority. This enum is the only value that
/// crosses that boundary; neither legacy dispatch text nor legacy JSON does.
public enum AriaV2DataMobilityRequest: Sendable {
    case reindex(estateID: UUID?)
    case reclassifyFDC(estateID: UUID?, apply: Bool, mode: String, limit: Int?)
    case palaceImport(path: String, mode: ImportMode, estateID: UUID?)
    case jsonImport(path: String, estateID: UUID?, returnIDMap: Bool)
    case fileDataset(name: String, location: String, columns: [JSONValue]?, rows: [JSONValue]?, csvPath: String?, wing: String?, sensitivity: String?, estateID: UUID?)
    case datasetQuery(datasetID: UUID, whereClause: JSONValue?, orderBy: [JSONValue]?, limit: Int?, columns: [JSONValue]?, estateID: UUID?)
    case datasetStats(datasetID: UUID, column: String?, estateID: UUID?)
    case vaultExport(path: String, scope: String?, estateID: UUID?)
    case vaultImport(path: String, mode: String?, estateID: UUID?)
    case vaultStatus(path: String)
    case vaultReconcile(path: String, apply: Bool, estateID: UUID?)
    case vaultJob(jobID: UUID)

    public enum ImportMode: String, Sendable, CaseIterable { case foreground, background }

    public static func decode(tool: String, arguments: JSONValue) throws -> Self {
        switch tool {
        case "moot_reindex":
            let d = try decoder(arguments, ["estate_id"]); return .reindex(estateID: try d.optionalUUID("estate_id"))
        case "moot_reclassify_fdc":
            let d = try decoder(arguments, ["estate_id", "apply", "mode", "limit"])
            let apply = try d.optionalBoolean("apply") ?? false
            // mode: "suspectOnly" or "all" accepted case-insensitively; v1
            // trimmed whitespace then lowercased before comparing, and v2
            // matches that so callers are not punished for leading/trailing
            // spaces or capitalisation differences. Unrecognised value is a
            // refusal, not a silent fallback. Canonical form is preserved:
            // "all" or "suspectOnly".
            let modeStr: String
            if let raw = try d.optionalString("mode") {
                switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "all": modeStr = "all"
                case "suspectonly": modeStr = "suspectOnly"
                default:
                    throw invalid("mode", "mode must be \"suspectOnly\" or \"all\".")
                }
            } else {
                modeStr = "suspectOnly"
            }
            // limit: 1...50000. Compare as Int64 to avoid unguarded narrowing trap.
            let limit: Int?
            if let rawLimit = try d.optionalInteger("limit") {
                guard rawLimit >= 1 && rawLimit <= 50_000 else {
                    throw invalid("limit", "limit must be between 1 and 50000.")
                }
                limit = Int(rawLimit)
            } else {
                limit = nil
            }
            return .reclassifyFDC(
                estateID: try d.optionalUUID("estate_id"),
                apply: apply,
                mode: modeStr,
                limit: limit)
        case "moot_palace_import":
            let d = try decoder(arguments, ["palace_path", "mode", "estate_id"])
            // Case-insensitive and whitespace-tolerant: "FOREGROUND ", "Background", etc.
            // resolve like v1. v1 trimmed whitespace then lowercased before comparing.
            // ImportMode.rawValue is already lowercase, so trim + lowercase before
            // init(rawValue:) handles any capitalisation or surrounding whitespace.
            let raw = (try d.optionalString("mode") ?? ImportMode.foreground.rawValue)
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let mode = ImportMode(rawValue: raw) else { throw invalid("mode", "mode must be foreground or background.") }
            return .palaceImport(path: try text(d, "palace_path"), mode: mode, estateID: try d.optionalUUID("estate_id"))
        case "moot_json_import":
            // return_id_map: when true the reply carries a second text block holding
            // {"id_map":{"<record id>":"<drawer id>"}}. Off by default — the ordinary
            // caller wants the one-line receipt. Matches v1 ToolDispatch.swift:4408 and
            // the catalog advertisement in AriaV2SelectedCatalog.swift:966.
            let d = try decoder(arguments, ["path", "estate_id", "return_id_map"])
            let returnIDMap = try d.optionalBoolean("return_id_map") ?? false
            return .jsonImport(path: try text(d, "path"), estateID: try d.optionalUUID("estate_id"), returnIDMap: returnIDMap)
        case "moot_file_dataset":
            let d = try decoder(arguments, ["name", "location", "columns", "rows", "csv_path", "wing", "sensitivity", "estate_id"])
            let columns = try optionalArray(d, "columns"); let rows = try optionalArray(d, "rows")
            let csv = try d.optionalString("csv_path")
            guard rows != nil || csv != nil else { throw invalid("rows|csv_path", "Provide inline rows or csv_path.") }
            guard !(rows != nil && csv != nil) else { throw invalid("rows|csv_path", "Provide exactly one of rows or csv_path.") }
            let sensitivity = try d.optionalString("sensitivity")
            if let sensitivity, !["normal", "elevated", "restricted", "secret"].contains(sensitivity) {
                throw invalid("sensitivity", "sensitivity must be normal, elevated, restricted, or secret.")
            }
            return .fileDataset(name: try text(d, "name"), location: try text(d, "location"), columns: columns, rows: rows, csvPath: csv, wing: try d.optionalString("wing"), sensitivity: sensitivity, estateID: try d.optionalUUID("estate_id"))
        case "moot_dataset_query":
            let d = try decoder(arguments, ["dataset_id", "where", "order_by", "limit", "columns", "estate_id"])
            let limit = try d.optionalInteger("limit").map(Int.init)
            if let limit, limit < 1 || limit > 1_000 { throw invalid("limit", "limit must be between 1 and 1000.") }
            let whereClause = try optionalObject(d, "where")
            if let whereClause {
                var nodeCount = 0
                try validateDatasetPredicate(whereClause, depth: 1, nodeCount: &nodeCount, path: "where")
            }
            let orderBy = try optionalArray(d, "order_by")
            if let orderBy { try validateDatasetOrder(orderBy) }
            let columns = try optionalStringArray(d, "columns")
            return .datasetQuery(datasetID: try d.requireUUID("dataset_id"), whereClause: whereClause, orderBy: orderBy, limit: limit, columns: columns?.map(JSONValue.string), estateID: try d.optionalUUID("estate_id"))
        case "moot_dataset_stats":
            let d = try decoder(arguments, ["dataset_id", "column", "estate_id"]); return .datasetStats(datasetID: try d.requireUUID("dataset_id"), column: try d.optionalString("column"), estateID: try d.optionalUUID("estate_id"))
        case "moot_vault_export":
            let d = try decoder(arguments, ["vaultPath", "scope", "estate_id"]); return .vaultExport(path: try text(d, "vaultPath"), scope: try d.optionalString("scope"), estateID: try d.optionalUUID("estate_id"))
        case "moot_vault_import":
            let d = try decoder(arguments, ["vaultPath", "mode", "estate_id"]); return .vaultImport(path: try text(d, "vaultPath"), mode: try d.optionalString("mode"), estateID: try d.optionalUUID("estate_id"))
        case "moot_vault_status":
            let d = try decoder(arguments, ["vaultPath"]); return .vaultStatus(path: try text(d, "vaultPath"))
        case "moot_vault_reconcile":
            let d = try decoder(arguments, ["vaultPath", "apply", "estate_id"]); return .vaultReconcile(path: try text(d, "vaultPath"), apply: try d.optionalBoolean("apply") ?? false, estateID: try d.optionalUUID("estate_id"))
        case "moot_vault_job":
            let d = try decoder(arguments, ["job_id"]); return .vaultJob(jobID: try d.requireUUID("job_id"))
        default: throw invalid("tool", "Unsupported data-mobility tool '\(tool)'.")
        }
    }

    public var tool: String {
        switch self {
        case .reindex: return "moot_reindex"
        case .reclassifyFDC: return "moot_reclassify_fdc"
        case .palaceImport: return "moot_palace_import"
        case .jsonImport: return "moot_json_import"
        case .fileDataset: return "moot_file_dataset"
        case .datasetQuery: return "moot_dataset_query"
        case .datasetStats: return "moot_dataset_stats"
        case .vaultExport: return "moot_vault_export"
        case .vaultImport: return "moot_vault_import"
        case .vaultStatus: return "moot_vault_status"
        case .vaultReconcile: return "moot_vault_reconcile"
        case .vaultJob: return "moot_vault_job"
        }
    }

    public var effect: AriaV2OperationEffect {
        switch self {
        case .datasetQuery, .datasetStats, .vaultExport, .vaultStatus, .vaultJob: return .read
        default: return .write
        }
    }

    private static func decoder(_ arguments: JSONValue, _ keys: Set<String>) throws -> AriaV2ArgumentDecoder { try .init(arguments, allowedKeys: keys) }
    private static func text(_ decoder: AriaV2ArgumentDecoder, _ key: String) throws -> String {
        let value = try decoder.requireString(key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw invalid(key, "Argument '\(key)' must not be empty.") }
        return value
    }
    private static func optionalArray(_ decoder: AriaV2ArgumentDecoder, _ key: String) throws -> [JSONValue]? {
        guard let value = decoder.arguments[key] else { return nil }
        guard let array = value.arrayValue else { throw invalid(key, "Argument '\(key)' must be an array.") }
        return array
    }
    private static func optionalObject(_ decoder: AriaV2ArgumentDecoder, _ key: String) throws -> JSONValue? {
        guard let value = decoder.arguments[key] else { return nil }
        guard value.objectValue != nil else { throw invalid(key, "Argument '\(key)' must be an object.") }
        return value
    }
    private static func optionalStringArray(_ decoder: AriaV2ArgumentDecoder, _ key: String) throws -> [String]? {
        guard let values = try optionalArray(decoder, key) else { return nil }
        return try values.map { value in
            guard let string = value.stringValue, !string.isEmpty else {
                throw invalid(key, "Argument '\(key)' entries must be non-empty strings.")
            }
            return string
        }
    }

    private static func validateDatasetPredicate(
        _ value: JSONValue,
        depth: Int,
        nodeCount: inout Int,
        path: String
    ) throws {
        guard depth <= 8 else { throw invalid(path, "Dataset predicates may be at most 8 levels deep.") }
        nodeCount += 1
        guard nodeCount <= 128 else { throw invalid(path, "Dataset predicates may contain at most 128 nodes.") }
        guard let object = value.objectValue else { throw invalid(path, "Dataset predicates must be objects.") }
        let keys = Set(object.keys)

        for compound in ["and", "or"] where object[compound] != nil {
            guard keys == [compound], let children = object[compound]?.arrayValue, !children.isEmpty else {
                throw invalid(path, "Compound predicates must contain only one non-empty '\(compound)' array.")
            }
            for (index, child) in children.enumerated() {
                try validateDatasetPredicate(
                    child, depth: depth + 1, nodeCount: &nodeCount,
                    path: "\(path).\(compound)[\(index)]")
            }
            return
        }

        guard let column = object["col"]?.stringValue, !column.isEmpty,
              let operation = object["op"]?.stringValue else {
            throw invalid(path, "Leaf predicates require non-empty col and op strings.")
        }
        if ["is_null", "is_not_null"].contains(operation) {
            guard keys == ["col", "op"] else {
                throw invalid(path, "Null predicates accept col and op only.")
            }
            return
        }
        guard ["eq", "neq", "lt", "lte", "gt", "gte"].contains(operation),
              keys == ["col", "op", "val"], let scalar = object["val"] else {
            throw invalid(path, "Comparison predicates require exactly col, op, and val.")
        }
        switch scalar {
        case .string, .integer, .double:
            break
        case .bool where operation == "eq" || operation == "neq":
            break
        default:
            throw invalid(path + ".val", "Comparison values must be non-null scalars; booleans support eq or neq only.")
        }
    }

    private static func validateDatasetOrder(_ values: [JSONValue]) throws {
        for (index, value) in values.enumerated() {
            let path = "order_by[\(index)]"
            guard let object = value.objectValue,
                  Set(object.keys).isSubset(of: ["col", "dir"]),
                  let column = object["col"]?.stringValue, !column.isEmpty else {
                throw invalid(path, "Sort entries require a non-empty col and optional dir.")
            }
            if let direction = object["dir"] {
                guard let direction = direction.stringValue, ["asc", "desc"].contains(direction) else {
                    throw invalid(path + ".dir", "Sort direction must be asc or desc.")
                }
            }
        }
    }
    private static func invalid(_ path: String, _ message: String) -> JSONRPCError { AriaV2InvalidArgument(path: path, message: message).jsonRPCError }
}

/// Typed outcome supplied by a lower-kit adapter. `data` is constructed from
/// typed lower results, never extracted from rendered text or a v1 response.
public struct AriaV2DataMobilityOutcome: Sendable {
    public let data: JSONValue
    public let compactText: String
    public init(data: JSONValue, compactText: String) { self.data = data; self.compactText = compactText }
}

/// The public receipt for an asynchronous reindex launch.  A reindex has no
/// completed-count at dispatch time; it is either newly running or already
/// owned by the process-wide in-flight guard.
enum AriaV2ReindexReceipt: String, Sendable, Equatable {
    case running
    case alreadyRunning = "already_running"
}

/// Adapter seam for public lower-kit APIs such as GLK deferred reindex,
/// VaultBridge import/export/reconcile, JsonImportBridge, and DatasetStore.
/// A selected surface injects one authority for its opened estate.
public protocol AriaV2DataMobilityAuthority: Sendable {
    func execute(_ request: AriaV2DataMobilityRequest) async throws -> AriaV2DataMobilityOutcome
}

/// Direct lower bindings that are already public, typed production APIs.
/// Admission remains owned by the selected surface; this type deliberately
/// does not revive the v1 dispatcher or interpret one of its rendered results.
public enum AriaV2DataMobilityLower {
    public static let supported: Set<String> = [
        "moot_reindex", "moot_reclassify_fdc", "moot_palace_import", "moot_json_import",
        "moot_file_dataset", "moot_dataset_query", "moot_dataset_stats",
        "moot_vault_status", "moot_vault_reconcile",
    ]

    public enum Failure: Error, Sendable {
        case refusal(AriaV2OperationalRefusal)
    }

    static func unavailable(_ tool: String) -> Failure {
        .refusal(.init(
            code: "mobility_lower_unavailable",
            message: "\(tool) has no typed production lower authority for the selected estate.",
            retryable: false
        ))
    }
}

/// Source-faithful direct adapter for the public GLK and VaultKit mobility
/// seams. The adapter projects their typed reports into v2 data without
/// constructing or reparsing a legacy ToolResult.
public struct AriaV2GeniusLocusDataMobilityAuthority: AriaV2DataMobilityAuthority {
    public let kit: GeniusLocusKit
    public let handle: EstateHandle
    public let selectedEstateID: UUID
    public let now: Date
    /// Server identity threaded from the dispatcher; stamped in the audit trail
    /// of every `reanchorAnchor` write so automated FDC repairs are attributed
    /// to the MCP server, not to the estate owner.
    public let serverIdentity: String

    public init(kit: GeniusLocusKit, handle: EstateHandle, selectedEstateID: UUID, now: Date, serverIdentity: String) {
        self.kit = kit
        self.handle = handle
        self.selectedEstateID = selectedEstateID
        self.now = now
        self.serverIdentity = serverIdentity
    }

    public func execute(_ request: AriaV2DataMobilityRequest) async throws -> AriaV2DataMobilityOutcome {
        guard request.estateID == nil || request.estateID == selectedEstateID,
              handle.estateUUID == selectedEstateID else {
            throw AriaV2DataMobilityLower.Failure.refusal(.init(
                code: "estate_unavailable",
                message: "The requested estate is not available to this caller.",
                retryable: false
            ))
        }

        switch request {
        case .reindex:
            let receipt = await ToolDispatcher.startReindex(
                kit: kit,
                handle: handle,
                now: now)
            return .init(
                data: .object(["state": .string(receipt.rawValue)]),
                compactText: receipt == .running
                    ? "Reindexing is running in the background."
                    : "Reindexing is already running."
            )

        case .reclassifyFDC(_, let apply, let mode, let limit):
            return try await reclassifyFDC(apply: apply, mode: mode, limit: limit)

        case .fileDataset, .datasetQuery, .datasetStats:
            return try await datasetOutcome(request)

        case .palaceImport(let path, let mode, _):
            let report = try await PalaceBridge(kit: kit).importPalace(
                at: URL(fileURLWithPath: path, isDirectory: true),
                into: handle,
                now: now,
                mode: encodeSpeed(mode)
            )
            return palaceOutcome(report)

        case .jsonImport(let path, _, _):
            let report = try await JsonImportBridge(kit: kit).importSeed(
                at: URL(fileURLWithPath: path),
                into: handle,
                now: now,
                mode: .foreground
            )
            return jsonOutcome(report)

        case .vaultStatus(let path):
            return vaultStatusOutcome(try VaultTools.statusSnapshot(
                vaultURL: URL(fileURLWithPath: path, isDirectory: true)))

        case .vaultReconcile(let path, let apply, _):
            guard let snapshot = try await VaultTools.reconcileSnapshot(
                kit: kit,
                handle: handle,
                vaultURL: URL(fileURLWithPath: path, isDirectory: true),
                apply: apply,
                now: now
            ) else {
                throw AriaV2DataMobilityLower.Failure.refusal(.init(
                    code: "vault_manifest_missing",
                    message: "No export manifest is available; run moot_vault_export first.",
                    retryable: false
                ))
            }
            return vaultReconcileOutcome(snapshot)

        default:
            throw AriaV2DataMobilityLower.unavailable(request.tool)
        }
    }

    private func encodeSpeed(_ mode: AriaV2DataMobilityRequest.ImportMode) -> EncodeSpeed {
        switch mode {
        case .foreground: return .foreground
        case .background: return .background
        }
    }

    private func datasetOutcome(_ request: AriaV2DataMobilityRequest) async throws -> AriaV2DataMobilityOutcome {
        switch request {
        case .fileDataset(let name, let location, let columns, let rows, let csvPath, let wing, let sensitivity, _):
            var arguments: [String: JSONValue] = ["name": .string(name), "location": .string(location)]
            if let columns { arguments["columns"] = .array(columns) }
            if let rows { arguments["rows"] = .array(rows) }
            if let csvPath { arguments["csv_path"] = .string(csvPath) }
            if let wing { arguments["wing"] = .string(wing) }
            if let sensitivity { arguments["sensitivity"] = .string(sensitivity) }
            return .init(
                data: try await DatasetTools.directFileDataset(
                    arguments: arguments, kit: kit, handle: handle, now: now),
                compactText: "Dataset filed.")

        case .datasetQuery(let datasetID, let whereClause, let orderBy, let limit, let columns, _):
            var arguments: [String: JSONValue] = ["id": .string(AriaV2ArgumentDecoder.canonicalUUID(datasetID))]
            if let whereClause { arguments["where"] = whereClause }
            if let orderBy { arguments["order_by"] = .array(orderBy) }
            if let limit { arguments["limit"] = .integer(Int64(limit)) }
            if let columns { arguments["columns"] = .array(columns) }
            do {
                return .init(
                    data: try await DatasetTools.directDatasetQuery(arguments: arguments, kit: kit, handle: handle),
                    compactText: "Dataset query complete.")
            } catch is DatasetTools.DirectFailure {
                throw AriaV2DataMobilityLower.Failure.refusal(.init(
                    code: "dataset_unavailable",
                    message: "The requested dataset is not available to this caller.",
                    retryable: false))
            }

        case .datasetStats(let datasetID, let column, _):
            var arguments: [String: JSONValue] = ["id": .string(AriaV2ArgumentDecoder.canonicalUUID(datasetID))]
            if let column { arguments["column"] = .string(column) }
            do {
                return .init(
                    data: try await DatasetTools.directDatasetStats(arguments: arguments, kit: kit, handle: handle),
                    compactText: "Dataset statistics are available.")
            } catch is DatasetTools.DirectFailure {
                throw AriaV2DataMobilityLower.Failure.refusal(.init(
                    code: "dataset_unavailable",
                    message: "The requested dataset is not available to this caller.",
                    retryable: false))
            }

        default:
            throw AriaV2DataMobilityLower.unavailable(request.tool)
        }
    }

    // MARK: - FDC reclassification

    /// Full scan-and-apply reclassification. Phase A runs the expensive
    /// classify pass in parallel across active processors; Phase B applies
    /// repairs serially in scan order so the audit trail is deterministic.
    ///
    /// Apply repairs ONLY the primary udcCode + wikidataQID. udcFacets and
    /// wikidataQidsSecondary are carried forward unchanged — FDC re-lookup
    /// has no opinion on secondary classification, and a reclassify that
    /// wiped facets/secondary QIDs a human or the enrichment daemon attached
    /// would be a silent data loss. See contract §6.
    private func reclassifyFDC(apply: Bool, mode: String, limit: Int?) async throws -> AriaV2DataMobilityOutcome {
        let fdcMode = mode == "all" ? FDCReclassifyMode.all : FDCReclassifyMode.suspectOnly
        let currentFDCDataVersion = FDC.dataVersion
        let currentFDCRecalculationVersion = FDC.recalculationVersion

        let priorFloor = try await kit.meta(in: handle, key: Self.fdcRecalcedDataVersionMetaKey)
        let drawers = try await kit.allDrawers(in: handle)
        let active = drawers.filter {
            // Dataset handles (contentKind == .dataset) carry structured JSON,
            // not classifiable free text. The FDC classifier must never reclassify
            // them — doing so would corrupt the DatasetHandleContent payload.
            // MX-TAB-4 locked decision: FDC classifier boundary.
            $0.tombstonedAt == nil && !$0.isKnewPast && !$0.isTerminal
                && $0.contentKind != .dataset
        }
        let scannedDrawers = limit.map { Array(active.prefix($0)) } ?? active

        // Phase A — PARALLEL classify. Each drawer's content anchor is a pure
        // function of its content and stored kind over the pinned FDC artifacts:
        // the `recordNovel: false` seam skips the shared-mutable novel-token
        // pool write, and every other artifact on the path is read-only after
        // init or lock-guarded. Results are indexed parallel to `scannedDrawers`
        // to preserve scan order for the serial audited write in Phase B.
        let anchors = await Self.classifyContentsInParallel(
            scannedDrawers.map {
                FDCReclassifyInput(
                    content: $0.content,
                    contentKind: $0.contentKind == .code ? .code : .text)
            })

        // Phase B — SERIAL, ORDERED apply. All counting, candidate selection,
        // example capture, and the audited `reanchorAnchor` write run in scan
        // order exactly as before the parallel classify was introduced, so
        // output (counters, ordered changes list, audit sequence) is
        // byte-identical to the serial version.
        var scanned = 0
        var emptyContent = 0
        var unchanged = 0
        var candidateCount = 0
        var applied = 0
        var skippedNonCandidateChanges = 0
        var unclassifiedAfter = 0
        var examples: [FDCReclassifyChange] = []

        for (index, drawer) in scannedDrawers.enumerated() {
            scanned += 1
            if drawer.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyContent += 1
            }

            let oldCode = Self.normalizedFDCCode(drawer.udcCode)
            let oldQID = Self.normalizedQID(drawer.wikidataQID)
            let anchor = anchors[index]
            let newCode = Self.normalizedFDCCode(anchor.code)
            let newQID = Self.normalizedQID(anchor.wikidataQID)

            if oldCode == newCode && oldQID == newQID {
                unchanged += 1
                continue
            }

            let candidate = Self.shouldRepairFDCAnchor(
                mode: fdcMode, oldCode: oldCode, oldQID: oldQID,
                newCode: newCode, newQID: newQID)
            guard candidate else {
                skippedNonCandidateChanges += 1
                continue
            }

            candidateCount += 1
            if newCode == Self.fdcSentinelCode { unclassifiedAfter += 1 }

            let change = FDCReclassifyChange(
                id: drawer.id, oldCode: oldCode, oldQID: oldQID,
                newCode: newCode, newQID: newQID)
            if examples.count < 25 { examples.append(change) }

            if apply {
                // Repair only the primary udcCode + wikidataQID that FDC re-lookup
                // produced. udcFacets and wikidataQidsSecondary are carried forward
                // from the existing drawer anchor — FDC re-lookup has no opinion on
                // secondary classification, so a reclassify apply must not silently
                // wipe facets/secondary QIDs a human or the enrichment daemon
                // previously attached. `changedBy: serverIdentity` attributes this
                // automated repair correctly in the audit trail.
                try await kit.reanchorAnchor(
                    handle,
                    rowID: drawer.id,
                    toLattice: LatticeAnchor(
                        udcCode: newCode,
                        udcFacets: drawer.udcFacets,
                        wikidataQID: newQID,
                        wikidataQidsSecondary: drawer.wikidataQidsSecondary),
                    changedBy: serverIdentity,
                    reason: "FDC reclassified via moot_reclassify_fdc",
                    now: now)
                applied += 1
            }
        }

        // Floor stamp: write estate-wide floor only on a complete full-mode
        // no-limit apply with no non-candidate changes left over. Every other
        // combination leaves the stored floor untouched. See contract §4.
        var floorAfter = priorFloor
        let floorStampStatus: String
        if apply && fdcMode == .all && limit == nil && skippedNonCandidateChanges == 0 {
            try await kit.stampFDCRecalculationFloor(
                handle,
                value: currentFDCRecalculationVersion)
            floorAfter = currentFDCRecalculationVersion
            floorStampStatus = "stamped"
        } else if !apply {
            floorStampStatus = "dry-run"
        } else if limit != nil {
            floorStampStatus = "skipped: limited run cannot update estate-wide floor"
        } else if fdcMode != .all {
            floorStampStatus = "skipped: mode=all is required for an estate-wide floor"
        } else {
            floorStampStatus = "skipped: changed non-suspect anchors remain"
        }

        // Build structured data (contract §3: 18 fields, 4 optional).
        let estateIDStr = AriaV2ArgumentDecoder.canonicalUUID(selectedEstateID)
        var data: [String: JSONValue] = [
            "applied": .bool(apply),
            "mode": .string(mode),
            "estate_id": .string(estateIDStr),
            "fdc_data_version": .string(currentFDCDataVersion),
            "fdc_recalculation_version": .string(currentFDCRecalculationVersion),
            "scanned": .integer(Int64(scanned)),
            "unchanged": .integer(Int64(unchanged)),
            "empty_content": .integer(Int64(emptyContent)),
            "candidates": .integer(Int64(candidateCount)),
            "updated": .integer(Int64(apply ? applied : 0)),
            "would_update": .integer(Int64(apply ? 0 : candidateCount)),
            "unclassified_after": .integer(Int64(unclassifiedAfter)),
            "skipped_non_candidate_changes": .integer(Int64(skippedNonCandidateChanges)),
            "floor_stamp": .string(floorStampStatus),
            "changes": .array(examples.map { change -> JSONValue in
                var entry: [String: JSONValue] = [
                    "id": .string(change.id),
                    "old_code": .string(change.oldCode),
                    "new_code": .string(change.newCode),
                ]
                if let oldQID = change.oldQID { entry["old_qid"] = .string(oldQID) }
                if let newQID = change.newQID { entry["new_qid"] = .string(newQID) }
                return .object(entry)
            }),
            "changes_omitted": .integer(Int64(max(0, candidateCount - examples.count))),
        ]
        // Optional fields: omit the key entirely when there is no value.
        if let before = priorFloor { data["estate_recalced_data_version_before"] = .string(before) }
        if let after = floorAfter { data["estate_recalced_data_version_after"] = .string(after) }

        // Compact text report mirrors the v1 text output; content[0].text is
        // truncated at 512 Unicode scalars by the v2 envelope — the full report
        // lives in structuredContent.data and is the correct assertion surface.
        let limitSuffix = limit.map { " (limit \($0))" } ?? ""
        var lines = [
            "fdc_reclassify: \(apply ? "applied" : "dry-run")",
            "mode: \(mode)",
            "estate: \(handle.estateName) [\(handle.estateUUID)]",
            "fdc_data_version: \(currentFDCDataVersion)",
            "fdc_recalculation_version: \(currentFDCRecalculationVersion)",
            "estate_recalced_data_version_before: \(priorFloor ?? "none")",
            "scanned: \(scanned) active drawer(s)\(limitSuffix)",
            "unchanged: \(unchanged)",
            "empty_content: \(emptyContent)",
            "candidates: \(candidateCount)",
            apply ? "updated: \(applied)" : "would_update: \(candidateCount)",
            "unclassified_after: \(unclassifiedAfter)",
            "skipped_non_candidate_changes: \(skippedNonCandidateChanges)",
            "estate_recalced_data_version_after: \(floorAfter ?? "none")",
            "floor_stamp: \(floorStampStatus)",
        ]
        if !apply {
            lines.append("dry_run: pass apply=true to write candidate anchor changes")
        }
        if fdcMode == .suspectOnly && skippedNonCandidateChanges > 0 {
            lines.append("note: mode=suspectOnly left \(skippedNonCandidateChanges) changed non-suspect anchor(s) untouched; rerun with mode=all to reset every changed active drawer from content")
        }
        if !examples.isEmpty {
            lines.append("changes:")
            for example in examples {
                lines.append("  \(example.id): \(example.oldAnchorLabel) -> \(example.newAnchorLabel)")
            }
            if candidateCount > examples.count {
                lines.append("  ... \(candidateCount - examples.count) more")
            }
        }

        return .init(data: .object(data), compactText: lines.joined(separator: "\n"))
    }

    // MARK: - FDC reclassification helpers

    /// The `000` sentinel code that the FDC classifier emits when content
    /// cannot be mapped to a subject category. Mirrors ToolDispatcher's
    /// `defaultLatticeAnchor.udcCode`.
    private static let fdcSentinelCode = "000"

    /// Estate-wide floor meta key: after a successful full-mode no-limit apply
    /// with no non-candidate changes, this records the composite
    /// classifier/artifact version against which all active stored anchors have
    /// been checked or repaired. Also read by `moot_estate_status` to report
    /// `fdc_recalculation` state.
    static let fdcRecalcedDataVersionMetaKey = "aria.fdc.recalced_data_version"

    private static func normalizedFDCCode(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fdcSentinelCode : trimmed
    }

    private static func normalizedQID(_ qid: String?) -> String? {
        guard let qid else { return nil }
        let trimmed = qid.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func shouldRepairFDCAnchor(
        mode: FDCReclassifyMode,
        oldCode: String,
        oldQID: String?,
        newCode: String,
        newQID: String?
    ) -> Bool {
        switch mode {
        case .all:
            return true
        case .suspectOnly:
            return newCode == fdcSentinelCode
                || oldCode == fdcSentinelCode
                || (oldCode == newCode && oldQID != newQID)
        }
    }

    /// Classify each content/kind pair to its FDC anchor across a bounded
    /// worker pool, returning anchors in the SAME order as `inputs`.
    ///
    /// `EideticLib.lookup(_:recordNovel: false)` is a pure function of its
    /// argument over the pinned artifacts and is thread-safe for concurrent
    /// calls — the no-record seam skips the shared novel-token cache write,
    /// and the reference tables / ranker / Q-ID-closure memo are read-only
    /// after init or lock-guarded — so classifying in parallel yields the
    /// exact anchor each content would produce serially, regardless of
    /// scheduling. Concurrency is bounded to the active core count via a
    /// sliding TaskGroup window so a large estate does not spawn one task
    /// per drawer. Order is preserved by scattering results into an
    /// index-keyed buffer, so the serial audited-write phase sees scan order.
    private static func classifyContentsInParallel(
        _ inputs: [FDCReclassifyInput]
    ) async -> [Anchor] {
        let count = inputs.count
        if count == 0 { return [] }
        let maxConcurrency = max(1, ProcessInfo.processInfo.activeProcessorCount)

        var results = [Anchor?](repeating: nil, count: count)
        await withTaskGroup(of: (Int, Anchor).self) { group in
            var next = 0
            let window = min(maxConcurrency, count)
            while next < window {
                let i = next
                let input = inputs[i]
                group.addTask {
                    (i, EideticLib.lookup(
                        input.content, contentKind: input.contentKind, recordNovel: false))
                }
                next += 1
            }
            while let (i, anchor) = await group.next() {
                results[i] = anchor
                if next < count {
                    let j = next
                    let input = inputs[j]
                    group.addTask {
                        (j, EideticLib.lookup(
                            input.content, contentKind: input.contentKind, recordNovel: false))
                    }
                    next += 1
                }
            }
        }
        return results.map { $0! }
    }

    // MARK: - Palace / JSON / Vault outcomes

    private func palaceOutcome(_ report: ImportReport) -> AriaV2DataMobilityOutcome {
        .init(data: .object([
            "drawers_written": .integer(Int64(report.drawersWritten)),
            "drawers_updated": .integer(Int64(report.drawersUpdated)),
            "drawers_skipped_unchanged": .integer(Int64(report.drawersSkippedUnchanged)),
            "drawers_skipped_tombstoned": .integer(Int64(report.drawersSkippedTombstoned)),
            "drawers_skipped_partial_write": .integer(Int64(report.drawersSkippedPartialWrite)),
            "tunnels_created": .integer(Int64(report.tunnelsCreated)),
            "items_skipped": .integer(Int64(report.itemsSkipped)),
            "fdc_classified": .integer(Int64(report.fdcClassified)),
            "fdc_unclassified": .integer(Int64(report.fdcUnclassified)),
            "enqueued_for_encode": .integer(Int64(report.enqueuedForEncode)),
            "fields_dropped": .object(report.fieldsDropped.mapValues { .integer(Int64($0)) }),
        ]), compactText: "Palace import complete; background indexing has started.")
    }

    private func jsonOutcome(_ report: JsonImportReport) -> AriaV2DataMobilityOutcome {
        let idMap = report.drawerIDByRecordID.mapValues { rawID in
            guard let id = UUID(uuidString: rawID) else { return JSONValue.string(rawID) }
            return .string(AriaV2ArgumentDecoder.canonicalUUID(id))
        }
        return .init(data: .object([
            "seed_name": .string(report.seedName),
            "drawers_written": .integer(Int64(report.drawersWritten)),
            "facts_written": .integer(Int64(report.factsWritten)),
            "tunnels_created": .integer(Int64(report.tunnelsCreated)),
            "enqueued_for_encode": .integer(Int64(report.enqueuedForEncode)),
            "subjects_provided": .integer(Int64(report.subjectsProvided)),
            "subjects_debt": .integer(Int64(report.subjectsDebt)),
            "seed_sha256": .string(report.seedSha256),
            "id_map": .object(idMap),
        ]), compactText: "JSON seed import complete.")
    }

    private func vaultStatusOutcome(_ snapshot: VaultTools.VaultStatusSnapshot) -> AriaV2DataMobilityOutcome {
        var data: [String: JSONValue] = [
            "manifest_present": .bool(snapshot.manifest != nil),
            "path": .string(snapshot.path),
        ]
        if let manifest = snapshot.manifest {
            data["note_count"] = .integer(Int64(manifest.noteCount))
            data["last_export"] = .string(manifest.exportedAt)
        }
        return .init(data: .object(data), compactText: "Vault manifest status is available.")
    }

    private func vaultReconcileOutcome(_ snapshot: VaultTools.VaultReconcileSnapshot) -> AriaV2DataMobilityOutcome {
        var data: [String: JSONValue] = [
            "added": .array(snapshot.added.map(JSONValue.string)),
            "modified": .array(snapshot.modified.map(JSONValue.string)),
            "deleted": .array(snapshot.deleted.map(JSONValue.string)),
            "candidates": .array(snapshot.candidates.map { candidate in
                .object([
                    "stable_source_key": .string(candidate.stableSourceKey),
                    "vault_path": .string(candidate.vaultPath),
                    "sha256": .string(candidate.sha256),
                ])
            }),
            "missing": .array(snapshot.missing.map(JSONValue.string)),
            "import_set_count": .integer(Int64(snapshot.importSetCount)),
            "candidate_count": .integer(Int64(snapshot.candidateCount)),
            "missing_count": .integer(Int64(snapshot.missing.count)),
            "applied": .bool(snapshot.applied),
        ]
        if let report = snapshot.importReport {
            data["import_report"] = .object([
                "drawers_written": .integer(Int64(report.drawersWritten)),
                "drawers_updated": .integer(Int64(report.drawersUpdated)),
                "items_skipped": .integer(Int64(report.itemsSkipped)),
                "tunnels_created": .integer(Int64(report.tunnelsCreated)),
                "fdc_classified": .integer(Int64(report.fdcClassified)),
                "fdc_unclassified": .integer(Int64(report.fdcUnclassified)),
                "drawers_skipped_unchanged": .integer(Int64(report.drawersSkippedUnchanged)),
                "drawers_skipped_tombstoned": .integer(Int64(report.drawersSkippedTombstoned)),
            ])
        }
        return .init(
            data: .object(data),
            compactText: snapshot.applied ? "Vault reconciliation applied." : "Vault reconciliation is ready for review."
        )
    }
}

/// Routes the selected v2 mobility operations to the authority that owns
/// their typed lower seam. Vault lifecycle custody remains with its job
/// registry; the direct GLK/VaultKit authority owns the five selected lowers.
struct AriaV2SelectedDataMobilityAuthority: AriaV2DataMobilityAuthority {
    let lifecycle: AriaV2VaultLifecycleAuthority
    let direct: AriaV2GeniusLocusDataMobilityAuthority

    func execute(_ request: AriaV2DataMobilityRequest) async throws -> AriaV2DataMobilityOutcome {
        if AriaV2DataMobilityLower.supported.contains(request.tool) {
            return try await direct.execute(request)
        }
        return try await lifecycle.execute(request)
    }
}

/// Direct adapter for the three vault paths whose lifecycle is already owned
/// by `VaultJobRegistry`: launch export, launch import, and poll a locally
/// minted job UUID.  It calls the same typed launch/snapshot functions as v1;
/// no text response is parsed back into v2 data.
struct AriaV2VaultLifecycleAuthority: AriaV2DataMobilityAuthority {
    private let kit: GeniusLocusKit?
    private let handle: EstateHandle?
    private let selectedEstateID: UUID?
    private let jobs: VaultJobRegistry

    init(
        jobRegistry: VaultJobRegistry,
        kit: GeniusLocusKit? = nil,
        handle: EstateHandle? = nil,
        selectedEstateID: UUID? = nil
    ) {
        self.jobs = jobRegistry
        self.kit = kit
        self.handle = handle
        self.selectedEstateID = selectedEstateID
    }

    func execute(_ request: AriaV2DataMobilityRequest) async throws -> AriaV2DataMobilityOutcome {
        try validateSelectedEstate(request.estateID)
        switch request {
        case .vaultExport(let path, let scope, _):
            let launch = try await VaultTools.launchExport(
                kit: try requiredKit(), handle: try requiredHandle(),
                vaultURL: URL(fileURLWithPath: path, isDirectory: true),
                scopeName: scope, jobRegistry: jobs)
            return launchOutcome(launch)
        case .vaultImport(let path, let mode, _):
            let launch = try await VaultTools.launchImport(
                kit: try requiredKit(), handle: try requiredHandle(),
                vaultURL: URL(fileURLWithPath: path, isDirectory: true),
                modeName: mode, jobRegistry: jobs)
            return launchOutcome(launch)
        case .vaultJob(let jobID):
            guard let snapshot = await jobs.snapshot(for: jobID) else {
                throw AriaV2VaultLifecycleError.unknownJob
            }
            return snapshotOutcome(snapshot)
        default:
            throw AriaV2VaultLifecycleError.unsupportedOperation
        }
    }

    private func validateSelectedEstate(_ requested: UUID?) throws {
        guard requested == nil || selectedEstateID == nil || requested == selectedEstateID else {
            throw AriaV2VaultLifecycleError.estateUnavailable
        }
    }

    private func requiredKit() throws -> GeniusLocusKit {
        guard let kit else { throw AriaV2VaultLifecycleError.unsupportedOperation }
        return kit
    }

    private func requiredHandle() throws -> EstateHandle {
        guard let handle else { throw AriaV2VaultLifecycleError.unsupportedOperation }
        return handle
    }

    private func launchOutcome(_ launch: VaultJobLaunch) -> AriaV2DataMobilityOutcome {
        var data: [String: JSONValue] = [
            "job_id": .string(AriaV2ArgumentDecoder.canonicalUUID(launch.jobID)),
            "kind": .string(launch.kind.rawValue),
            "vault_path": .string(launch.vaultPath),
            "status": .string("running"),
        ]
        if let noteCount = launch.noteCount { data["note_count"] = .integer(Int64(noteCount)) }
        if let scope = launch.scope { data["scope"] = .string(scope) }
        return .init(data: .object(data), compactText: "Vault \(launch.kind.rawValue) job \(launch.jobID.uuidString.lowercased()) is running.")
    }

    private func snapshotOutcome(_ snapshot: VaultJobSnapshot) -> AriaV2DataMobilityOutcome {
        var data: [String: JSONValue] = [
            "job_id": .string(AriaV2ArgumentDecoder.canonicalUUID(snapshot.jobID)),
            "kind": .string(snapshot.kind.rawValue),
            "vault_path": .string(snapshot.vaultPath),
            "elapsed_ms": .integer(Int64(max(0, snapshot.elapsedSeconds * 1_000))),
        ]
        switch snapshot.state {
        case .running(let progress):
            data["status"] = .string("running")
            if let progress {
                data["progress"] = .object([
                    "processed": .integer(Int64(progress.processed)),
                    "total": .integer(Int64(progress.total)),
                ])
            }
        case .imported(let result):
            data["status"] = .string("complete")
            data["import"] = .object([
                "drawers_written": .integer(Int64(result.drawersWritten)),
                "drawers_updated": .integer(Int64(result.drawersUpdated)),
                "items_skipped": .integer(Int64(result.itemsSkipped)),
                "tunnels_created": .integer(Int64(result.tunnelsCreated)),
                "fdc_classified": .integer(Int64(result.fdcClassified)),
                "fdc_unclassified": .integer(Int64(result.fdcUnclassified)),
                "drawers_skipped_unchanged": .integer(Int64(result.drawersSkippedUnchanged)),
                "drawers_skipped_tombstoned": .integer(Int64(result.drawersSkippedTombstoned)),
            ])
        case .exported(let result):
            data["status"] = .string("complete")
            data["export"] = .object([
                "note_count": .integer(Int64(result.noteCount)),
                "exported_at": .string(result.exportedAt),
            ])
        case .failed(let message):
            data["status"] = .string("failed")
            data["error"] = .string(message)
        }
        return .init(data: .object(data), compactText: "Vault job \(snapshot.jobID.uuidString.lowercased()) status is available.")
    }
}

private enum AriaV2VaultLifecycleError: Error {
    case estateUnavailable
    case unknownJob
    case unsupportedOperation
}

// MARK: - FDC reclassification types

/// Whether the scan examines only suspect anchors or all active drawers.
private enum FDCReclassifyMode: Equatable {
    case suspectOnly
    case all
}

/// One candidate change identified during the classify scan.
private struct FDCReclassifyChange {
    let id: String
    let oldCode: String
    let oldQID: String?
    let newCode: String
    let newQID: String?

    var oldAnchorLabel: String { Self.label(code: oldCode, qid: oldQID) }
    var newAnchorLabel: String { Self.label(code: newCode, qid: newQID) }

    private static func label(code: String, qid: String?) -> String {
        if let qid { return "\(code) [\(qid)]" }
        return code
    }
}

/// Input to the parallel classify pass — content and kind only, no mutable state.
private struct FDCReclassifyInput: Sendable {
    let content: String
    let contentKind: EideticContentKind
}

private extension AriaV2DataMobilityRequest {
    var estateID: UUID? {
        switch self {
        case .reindex(let estateID): return estateID
        case .reclassifyFDC(let estateID, _, _, _): return estateID
        case .palaceImport(_, _, let estateID), .jsonImport(_, let estateID, _): return estateID
        case .fileDataset(_, _, _, _, _, _, _, let estateID): return estateID
        case .datasetQuery(_, _, _, _, _, let estateID), .datasetStats(_, _, let estateID): return estateID
        case .vaultExport(_, _, let estateID), .vaultImport(_, _, let estateID): return estateID
        case .vaultReconcile(_, _, let estateID): return estateID
        case .vaultStatus(_), .vaultJob(_): return nil
        }
    }
}

public struct AriaV2DataMobility: Sendable {
    public let authority: any AriaV2DataMobilityAuthority
    public init(authority: any AriaV2DataMobilityAuthority) { self.authority = authority }

    public func execute(tool: String, arguments: JSONValue) async throws -> JSONValue {
        let request = try AriaV2DataMobilityRequest.decode(tool: tool, arguments: arguments)
        return try await execute(request)
    }

    public func execute(_ request: AriaV2DataMobilityRequest) async throws -> JSONValue {
        do {
            let outcome = try await authority.execute(request)
            var result = AriaV2Envelope.success(tool: request.tool, effect: request.effect, data: outcome.data, meta: ["completeness": .string("incomplete")], compactText: outcome.compactText)
            // return_id_map: append a second text block holding the id_map JSON when the
            // caller asked for it. The structured data already carries id_map always;
            // this second block serves text-only callers that cannot read structuredContent.
            // Block shape matches v1: {"id_map":{"<record id>":"<drawer id>",…}}.
            if case .jsonImport(_, _, let returnIDMap) = request, returnIDMap {
                result = Self.appendIDMapBlock(result, from: outcome.data)
            }
            return result
        } catch let failure as AriaV2DataMobilityLower.Failure {
            switch failure {
            case .refusal(let refusal):
                return AriaV2Envelope.refusal(tool: request.tool, error: refusal)
            }
        } catch {
            return AriaV2Envelope.refusal(tool: request.tool, error: .init(code: "mobility_unavailable", message: "The requested data-mobility operation is unavailable in the selected estate.", retryable: false))
        }
    }

    /// Append a second content text block carrying `{"id_map":{…}}` to a v2 envelope
    /// result.  Used by `moot_json_import` when `return_id_map=true`.
    ///
    /// The envelope already carries `data.id_map` in `structuredContent`; this second
    /// block serves text-only callers that cannot read structuredContent.  Its shape
    /// is wire-identical to v1 `ToolDispatcher.textResultBlocks(_:)` call at line 4461.
    ///
    /// Returns the original result unchanged when the id_map cannot be extracted or
    /// serialized; both conditions signal a programmer error (data contract violation)
    /// so the receipt is still delivered without the second block rather than failing.
    private static func appendIDMapBlock(_ result: JSONValue, from data: JSONValue) -> JSONValue {
        guard case .object(var responseObj) = result,
              case .array(var content) = responseObj["content"],
              case .object(let dataObj) = data,
              let idMapValue = dataObj["id_map"] else { return result }

        let mapObject = JSONValue.object(["id_map": idMapValue])
        guard let rawData = try? JSONSerialization.data(
                withJSONObject: mapObject.foundationObject,
                options: [.sortedKeys, .withoutEscapingSlashes]),
              let mapJSON = String(data: rawData, encoding: .utf8) else { return result }

        content.append(.object(["type": .string("text"), "text": .string(mapJSON)]))
        responseObj["content"] = .array(content)
        return .object(responseObj)
    }
}
