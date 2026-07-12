// DatasetTools.swift
// AriaMcpKit
//
// MCP tool surface for user-defined tabular datasets (MX-TAB-7, spec §5).
//
// Three tools:
//   moot_file_dataset   — create a dataset handle plus backend table, bulk-load rows
//   moot_dataset_query  — predicate query over a dataset's rows
//   moot_dataset_stats  — per-column aggregate statistics passthrough
//
// Design decisions documented here so future agents do not re-derive them:
//
//   DISPATCH SHAPE: Follows VaultTools/LensTools pattern — static enum with
//   isDatasetTool(), dispatch(), and tools(). Inserted in ToolDispatch.dispatch()
//   after VaultTools and before InterfaceTools so dataset tools do not interfere
//   with the existing tier structure.
//
//   PROVENANCE: .interface — dataset tools are user-facing CRUD operations that
//   target a specific estate (they carry an optional estateID like all interface
//   tools). withEstateID() is applied in the tool schema here, consistent with
//   how coreMemoryTools() applies it in ToolProjection.
//
//   CSV SIZE CAP: csvPathSizeCapBytes = 100 MiB. Rationale: generous for
//   substantial real-world datasets while bounding peak parse memory.
//   A 100 MiB CSV with 50 columns averages ~2 MiB/column value array at parse
//   time; peak memory during inline build is O(fileSize). Larger files should
//   be pre-split or streamed (v2 Parquet/streaming path).
//
//   PATH SECURITY: csv_path is canonicalized (resolving symlinks) to the REAL
//   path, checked to be a regular file, and confined to the import root
//   (home directory) by component-wise prefix match — a canonicalized path
//   outside the root is rejected (MX-TAB-SEC-1 A1; a prompt-injected client
//   must not read arbitrary files). Only the basename is written to the
//   handle's sourceDescription ("csv:<basename>", A2); the canonical path
//   goes to the server-side audit log only, never to the client-visible
//   handle field, so filesystem layout is not disclosed in tool responses.
//
//   TYPE INFERENCE: try Int64 → try Double → text. Applies to both CSV cells
//   and JSON-lines scalar values. Empty string → null (TypedValue.null).
//   Both legs use the identical algorithm for parity.
//
//   REJECTION SEMANTICS: an invalid column name fails the whole import with a
//   clear error before any DDL is emitted. There is no sanitize-and-continue
//   path. If handle creation fails after the table is created, the table is
//   dropped (atomic intent: either both succeed or neither persists).
//
//   WITHDRAWN HANDLE: moot_dataset_query and moot_dataset_stats call
//   resolveActiveDatasetHandle() which throws LocusKitError.withdrawnDatasetHandle
//   on any id whose most recent cluster-A state is withdrawn. Both tools map
//   this to a clear refusal rather than an opaque error.
//
//   FLOAT WIRE DISCIPLINE: all Double (f64) values in tool output use
//   Swift's String(d) representation which is the shortest decimal roundtrip.
//   Never Float32 intermediates. This matches the Rust twin exactly and
//   satisfies the MX-TABULAR parity law §Float discipline.
//
//   LAYERED SIGNATURES (MX-TAB-5): moot_file_dataset computes tier-1 (table)
//   and tier-2 (column) signatures AFTER the handle is captured — sample the
//   first datasetSignatureSampleSize rows, gather columnStats per column, and
//   call kit.computeDatasetSignatures, which patches the handle drawer's
//   reserved fields. Signature failure is NON-FATAL: the dataset and handle
//   are already committed, so the tool reports "signatures: pending" rather
//   than dropping a loaded table.

import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit

/// Namespace for the dataset tool surface. No instances.
enum DatasetTools {

    // MARK: - Constants

    /// Maximum CSV file size accepted by moot_file_dataset.
    ///
    /// 100 MiB (104,857,600 bytes). Rationale: generous for substantial real-world
    /// datasets while bounding peak parse memory. A 100 MiB CSV with 50 columns
    /// averages ~2 MiB/column value array during inline parse; peak memory is
    /// O(fileSize). Larger files should be pre-split or use a streaming import
    /// path (v2 Parquet). The Rust twin uses the identical constant: CSV_SIZE_CAP_BYTES.
    static let csvPathSizeCapBytes: Int64 = 100 * 1_048_576  // 100 MiB

    // MARK: - Tool name membership

    static let datasetToolNames: Set<String> = [
        "moot_file_dataset",
        "moot_dataset_query",
        "moot_dataset_stats",
    ]

    /// True when `name` is a dataset tool dispatched before the interface tier.
    static func isDatasetTool(_ name: String) -> Bool {
        datasetToolNames.contains(name)
    }

    // MARK: - Dispatch

    /// Run the named dataset tool. Follows the same contract as LensTools.dispatch
    /// and VaultTools.dispatch: out-of-band faults throw JSONRPCError; substrate
    /// refusals return an errorResult (isError: true).
    ///
    /// `serverIdentity` is the host's identity string, used as the `addedBy`
    /// parameter on captureDatasetHandle (parity with other capture calls).
    static func dispatch(
        name: String,
        args: [String: JSONValue],
        kit: GeniusLocusKit,
        resolveHandle: ([String: JSONValue]) throws -> EstateHandle,
        serverIdentity: String
    ) async throws -> JSONValue {
        switch name {
        case "moot_file_dataset":
            return try await runFileDataset(
                args: args, kit: kit,
                handle: try resolveHandle(args),
                serverIdentity: serverIdentity)

        case "moot_dataset_query":
            return try await runDatasetQuery(
                args: args, kit: kit,
                handle: try resolveHandle(args))

        case "moot_dataset_stats":
            return try await runDatasetStats(
                args: args, kit: kit,
                handle: try resolveHandle(args))

        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.methodNotFound,
                message: "Unknown dataset tool: \(name)")
        }
    }

    // MARK: - Tool schema projection

    /// The three dataset tools added to the tool list.
    ///
    /// Schemas are wrapped with withEstateID() so the estate-addressing contract
    /// matches all other interface tools. withTeachme() is applied globally by
    /// ToolProjection.tools(environment:).
    static func tools() -> [ProjectedTool] {
        [
            ProjectedTool(
                name: "moot_file_dataset",
                description: """
                Import a tabular dataset into the estate as a first-class handle. \
                Provide columns (array of name+type pairs), either inline rows \
                (array of objects) or a local csv_path, and a location for the \
                handle. Column names must match [A-Za-z_][A-Za-z0-9_]*. \
                Returns the dataset id and handle info. \
                Use moot_dataset_query to read back rows.
                """,
                inputSchema: ToolProjection.withEstateID(ToolProjection.objectSchema(
                    properties: [
                        "name": ToolProjection.stringSchema(
                            "Dataset name — stored as the handle's room label."),
                        "columns": .object([
                            "type": .string("array"),
                            "description": .string(
                                "Column schema pairs. Each element: " +
                                "{\"name\": \"[A-Za-z_][A-Za-z0-9_]*\", \"type\": \"text|int|float|bool\"}. " +
                                "Required when using inline rows; optional for csv_path (type inferred from values)."),
                            "items": ToolProjection.objectSchema(
                                properties: [
                                    "name": ToolProjection.stringSchema(
                                        "Column identifier: [A-Za-z_][A-Za-z0-9_]*"),
                                    "type": ToolProjection.stringSchema(
                                        "Column type: text, int, float, bool. " +
                                        "Optional when csv_path is used (type inferred)."),
                                ],
                                required: ["name"]),
                        ]),
                        "rows": .object([
                            "type": .string("array"),
                            "description": .string(
                                "Inline rows as JSON objects. Keys must be column names. " +
                                "Mutually exclusive with csv_path."),
                            "items": .object(["type": .string("object")]),
                        ]),
                        "csv_path": ToolProjection.stringSchema(
                            "Absolute filesystem path to a CSV file to import. " +
                            "Path is canonicalized and must resolve to a regular file. " +
                            "Size cap: 100 MiB. Mutually exclusive with rows."),
                        "location": ToolProjection.stringSchema(
                            "Room location for the dataset handle in the estate."),
                        "wing": ToolProjection.stringSchema(
                            "Optional wing name. Omit for the default wing."),
                        "sensitivity": ToolProjection.stringSchema(
                            "Optional sensitivity: normal (default), elevated, restricted, secret."),
                    ],
                    required: ["name", "location"]
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_dataset_query",
                description: """
                Query rows from a dataset. Refuses withdrawn handles. \
                Supply the dataset id from moot_file_dataset. \
                Predicates use JSON: {\"col\":\"name\",\"op\":\"eq|neq|lt|lte|gt|gte\",\"val\":value} \
                or {\"and\":[...]} / {\"or\":[...]} for compound conditions. \
                order_by: array of {\"col\":\"name\",\"dir\":\"asc|desc\"} objects. \
                Returns rows plus handle metadata (belief state, sensitivity).
                """,
                inputSchema: ToolProjection.withEstateID(ToolProjection.objectSchema(
                    properties: [
                        "id": ToolProjection.stringSchema(
                            "Dataset UUID from moot_file_dataset."),
                        "where": ToolProjection.stringSchema(
                            "Optional predicate JSON: " +
                            "{\"col\":\"name\",\"op\":\"eq\",\"val\":value} " +
                            "or {\"and\":[...]} / {\"or\":[...]}. Omit for full scan."),
                        "order_by": .object([
                            "type": .string("array"),
                            "description": .string(
                                "Optional sort order. Each element: {\"col\":\"name\",\"dir\":\"asc|desc\"}."),
                            "items": ToolProjection.objectSchema(
                                properties: [
                                    "col": ToolProjection.stringSchema("Column name."),
                                    "dir": ToolProjection.stringSchema(
                                        "Sort direction: asc or desc (default asc)."),
                                ],
                                required: ["col"]),
                        ]),
                        "limit": ToolProjection.integerSchema(
                            "Maximum rows to return (default 100, max 1000)."),
                        "columns": .object([
                            "type": .string("array"),
                            "description": .string(
                                "Optional column projection. " +
                                "Array of column name strings to return. Omit for all columns."),
                            "items": .object(["type": .string("string")]),
                        ]),
                    ],
                    required: ["id"]
                )),
                provenance: .interface
            ),
            ProjectedTool(
                name: "moot_dataset_stats",
                description: """
                Return per-column aggregate statistics for a dataset. Refuses withdrawn handles. \
                Supply the dataset id from moot_file_dataset. Omit column to get stats for all \
                columns. Float values use f64 shortest-roundtrip format.
                """,
                inputSchema: ToolProjection.withEstateID(ToolProjection.objectSchema(
                    properties: [
                        "id": ToolProjection.stringSchema(
                            "Dataset UUID from moot_file_dataset."),
                        "column": ToolProjection.stringSchema(
                            "Optional column name. Omit for stats on all columns."),
                    ],
                    required: ["id"]
                )),
                provenance: .interface
            ),
        ]
    }

    // MARK: - moot_file_dataset

    private static func runFileDataset(
        args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle,
        serverIdentity: String
    ) async throws -> JSONValue {
        // --- Parse parameters ---

        let name = try requireString(args, "name")
        let location = try requireString(args, "location")
        let wing = args["wing"]?.stringValue
        let sensitivity = try decodeSensitivity(args["sensitivity"])

        // columns: array of {name, type?} objects.
        // Required when using inline rows; optional for csv_path (inferred from header).
        let columnSpecs = try parseColumnSpecs(args["columns"])

        // Source: exactly one of `rows` or `csv_path` (or neither → error).
        let hasCsvPath = args["csv_path"] != nil
        let hasRows = args["rows"] != nil

        if hasCsvPath && hasRows {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "moot_file_dataset: supply either rows or csv_path, not both")
        }

        // --- Validate all column identifiers BEFORE any DDL ---
        // Rejection fails the whole import — no sanitize-and-continue path.
        let colNames = columnSpecs.map(\.name)
        for colName in colNames {
            do {
                try validateDatasetColumnIdentifier(colName)
            } catch {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "moot_file_dataset: invalid column identifier \"\(colName)\". " +
                    "Column names must match [A-Za-z_][A-Za-z0-9_]*.")
            }
        }

        // --- Parse rows and build schema ---
        let schema: DatasetSchema
        let typedRows: [[String: TypedValue]]
        let sourceDescription: String

        if let csvPathValue = args["csv_path"]?.stringValue {
            // csv_path path: canonicalize → security-check → size-check → parse.
            let resolved = try resolveCSVPath(csvPathValue)
            let result = try parseCSV(at: resolved, columnHints: columnSpecs)
            schema = result.schema
            typedRows = result.rows
            // A2: Provenance path redaction (MX-TAB-SEC-1 A2).
            //
            // sourceDescription is stored in the handle drawer and visible to the
            // client. To avoid leaking the full canonical filesystem path (which can
            // reveal personal directory layout to a prompt-injected client),
            // sourceDescription carries only the basename.
            //
            // The full resolved path goes to the server-side audit channel (OSLog)
            // ONLY — never to the client-facing response body or stored drawer content.
            Logging.osLog.info("csv_import: audit resolved=\(resolved, privacy: .public)")
            sourceDescription = "csv:\(URL(fileURLWithPath: resolved).lastPathComponent)"
        } else if let rowsValue = args["rows"] {
            guard !colNames.isEmpty else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "moot_file_dataset: columns is required when using inline rows")
            }
            let result = try parseInlineRows(rowsValue, columnSpecs: columnSpecs)
            schema = result.schema
            typedRows = result.rows
            sourceDescription = "inline_rows:\(name)"
        } else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "moot_file_dataset: either rows or csv_path is required")
        }

        // --- Obtain the DatasetStore ---
        let datasetId = UUID()
        let datasetStore: any DatasetStore
        do {
            datasetStore = try await kit.datasetStore(for: handle)
        } catch {
            return ToolDispatcher.errorResult(
                "moot_file_dataset: estate storage does not support datasets: " +
                error.localizedDescription)
        }

        // --- Create the backend table ---
        // On failure nothing has been committed yet; no cleanup needed.
        do {
            try await datasetStore.createDataset(id: datasetId, schema: schema, indexes: [])
        } catch {
            return ToolDispatcher.errorResult(
                "moot_file_dataset: failed to create dataset table: " +
                error.localizedDescription)
        }

        // --- Append rows in one transaction ---
        // On failure, drop the table so no orphaned backend table persists without
        // a matching handle (atomic intent: either both succeed or neither persists).
        if !typedRows.isEmpty {
            do {
                try await datasetStore.appendRows(id: datasetId, rows: typedRows)
            } catch {
                // Drop the orphaned table before returning the error.
                try? await datasetStore.dropDataset(id: datasetId)
                return ToolDispatcher.errorResult(
                    "moot_file_dataset: failed to append rows (table dropped): " +
                    error.localizedDescription)
            }
        }

        // --- Capture the dataset handle drawer ---
        // captureDatasetHandle is the ONLY authorised creation path for .dataset drawers.
        let columnSummaries = schema.columns.map {
            DatasetColumnSummary(name: $0.name, dataType: $0.type.rawValue.uppercased())
        }
        let estate: LocusKit.Estate
        do {
            estate = try await kit.estate(for: handle)
        } catch {
            // Drop the table if we cannot obtain the estate for the handle call.
            try? await datasetStore.dropDataset(id: datasetId)
            return ToolDispatcher.errorResult(
                "moot_file_dataset: estate not accessible: " +
                error.localizedDescription)
        }

        let drawer: Drawer
        do {
            drawer = try await estate.captureDatasetHandle(
                datasetId: datasetId,
                columns: columnSummaries,
                rowCount: typedRows.count,
                sourceDescription: sourceDescription,
                wing: wing,
                room: location,
                addedBy: serverIdentity.isEmpty ? "aria-mcp-server" : serverIdentity,
                sensitivity: sensitivity,
                // Dataset handles get UDC "000" (fallback/unclassified). The dataset
                // table itself is a raw backend artefact below the belief layer; its
                // FDC classification is deferred to VaultKit integration (MX-TAB-7 §6).
                latticeAnchor: LatticeAnchor.udc("000")
            )
        } catch {
            // Drop the orphaned table if handle creation fails.
            try? await datasetStore.dropDataset(id: datasetId)
            return ToolDispatcher.errorResult(
                "moot_file_dataset: handle creation failed (table dropped): " +
                error.localizedDescription)
        }

        // --- Layered signatures (MX-TAB-5) ---
        // Tier 1 (table) + tier 2 (column) signatures computed at import per
        // spec §3: sample the first datasetSignatureSampleSize rows in backend
        // order, gather per-column stats, and patch the handle drawer.
        // NON-FATAL on failure: the dataset and handle are already committed —
        // a filed dataset without signatures is recoverable (recompute later);
        // dropping a loaded table over a signature error is not.
        var signatureStatus = "computed"
        do {
            let sampledRows = try await datasetStore.queryRows(
                id: datasetId, predicate: nil, orderBy: [],
                limit: datasetSignatureSampleSize, offset: nil, columns: nil)
            var stats: [String: ColumnStats] = [:]
            for column in schema.columns {
                stats[column.name] = try await datasetStore.columnStats(
                    id: datasetId, column: column.name)
            }
            _ = try await kit.computeDatasetSignatures(
                handle: handle,
                drawerId: drawer.id,
                columns: columnSummaries,
                columnStats: stats,
                sampledRows: sampledRows,
                now: Date())
        } catch {
            signatureStatus = "pending (\(error.localizedDescription))"
        }

        return ToolDispatcher.textResult("""
        dataset_filed:
          id: \(datasetId.uuidString)
          handle_id: \(drawer.id)
          name: \(name)
          location: \(location)\(wing.map { "\n  wing: \($0)" } ?? "")
          columns: \(schema.columns.count)
          rows: \(typedRows.count)
          source: \(sourceDescription)
          sensitivity: \(sensitivity)
          signatures: \(signatureStatus)
        """)
    }

    // MARK: - moot_dataset_query

    private static func runDatasetQuery(
        args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let idStr = try requireString(args, "id")
        guard let datasetId = UUID(uuidString: idStr) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "moot_dataset_query: id must be a valid UUID")
        }

        // Resolve estate for handle lifecycle operations.
        let estate: LocusKit.Estate
        do {
            estate = try await kit.estate(for: handle)
        } catch {
            return ToolDispatcher.errorResult(
                "moot_dataset_query: estate not accessible: " +
                error.localizedDescription)
        }

        // resolveActiveDatasetHandle refuses withdrawn handles with a clear error.
        let handleDrawer: Drawer
        do {
            handleDrawer = try await estate.resolveActiveDatasetHandle(datasetId: datasetId)
        } catch let lke as LocusKitError {
            // Map withdrawnDatasetHandle to a user-facing refusal, not an opaque error.
            return ToolDispatcher.errorResult(
                "moot_dataset_query: \(describeLocusKitError(lke))")
        } catch {
            return ToolDispatcher.errorResult(
                "moot_dataset_query: handle not found: " + error.localizedDescription)
        }

        // Parse query parameters.
        let tableName = datasetTableName(datasetId)
        let predicate = try parseWherePredicate(args["where"], tableName: tableName)
        let orderBy = try parseOrderBy(args["order_by"], tableName: tableName)
        // Limit: default 100, cap 1000 (prevents scan exhaustion on large datasets).
        // JSONValue.integerValue returns Int64? (the integer case of the JSON number).
        let rawLimit: Int
        if let limitVal = args["limit"]?.integerValue {
            rawLimit = Int(limitVal)
        } else {
            rawLimit = 100
        }
        let limit = min(max(1, rawLimit), 1000)
        let projectedColumns: [String]? = args["columns"].flatMap {
            $0.arrayValue?.compactMap { $0.stringValue }
        }

        // Obtain the DatasetStore and issue the query.
        let datasetStore: any DatasetStore
        do {
            datasetStore = try await kit.datasetStore(for: handle)
        } catch {
            return ToolDispatcher.errorResult(
                "moot_dataset_query: estate storage does not support datasets: " +
                error.localizedDescription)
        }

        let rows: [StorageRow]
        do {
            rows = try await datasetStore.queryRows(
                id: datasetId,
                predicate: predicate,
                orderBy: orderBy,
                limit: limit,
                offset: nil,
                columns: projectedColumns)
        } catch {
            return ToolDispatcher.errorResult(
                "moot_dataset_query: query failed: " + error.localizedDescription)
        }

        // Format output: handle metadata first, then rows.
        let handleContent = try? DatasetHandleContent.decode(from: handleDrawer.content)
        var lines: [String] = []
        lines.append("dataset_query:")
        lines.append("  id: \(datasetId.uuidString)")
        lines.append("  handle_id: \(handleDrawer.id)")
        if let hc = handleContent {
            lines.append("  columns: \(hc.columns.map { $0.name }.joined(separator: ", "))")
            lines.append("  handle_row_count: \(hc.rowCount)")
        }
        // Drawer.state is bits 0–5 of adjectiveBitmap (cookbook §2.3).
        lines.append("  state: \(handleDrawer.state)")
        // Drawer.adjectiveSensitivity is bits 6–11 of adjectiveBitmap (cookbook §2.3).
        lines.append("  sensitivity: \(handleDrawer.adjectiveSensitivity)")
        lines.append("  rows_returned: \(rows.count)")
        lines.append("  limit: \(limit)")
        if rows.isEmpty {
            lines.append("  (no rows)")
        } else {
            lines.append("rows:")
            for row in rows {
                // Sort keys alphabetically for deterministic output across Swift/Rust legs.
                let cols = row.values.keys.sorted()
                let fields = cols.map { col in
                    "\(col):\(typedValueToString(row.values[col] ?? .null))"
                }
                lines.append("  {\(fields.joined(separator: ", "))}")
            }
        }
        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    // MARK: - moot_dataset_stats

    private static func runDatasetStats(
        args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let idStr = try requireString(args, "id")
        guard let datasetId = UUID(uuidString: idStr) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "moot_dataset_stats: id must be a valid UUID")
        }

        // Resolve estate for handle lifecycle operations.
        let estate: LocusKit.Estate
        do {
            estate = try await kit.estate(for: handle)
        } catch {
            return ToolDispatcher.errorResult(
                "moot_dataset_stats: estate not accessible: " +
                error.localizedDescription)
        }

        // resolveActiveDatasetHandle refuses withdrawn handles.
        let handleDrawer: Drawer
        do {
            handleDrawer = try await estate.resolveActiveDatasetHandle(datasetId: datasetId)
        } catch let lke as LocusKitError {
            return ToolDispatcher.errorResult(
                "moot_dataset_stats: \(describeLocusKitError(lke))")
        } catch {
            return ToolDispatcher.errorResult(
                "moot_dataset_stats: handle not found: " + error.localizedDescription)
        }

        let requestedColumn = args["column"]?.stringValue
        let handleContent = try? DatasetHandleContent.decode(from: handleDrawer.content)

        let datasetStore: any DatasetStore
        do {
            datasetStore = try await kit.datasetStore(for: handle)
        } catch {
            return ToolDispatcher.errorResult(
                "moot_dataset_stats: estate storage does not support datasets: " +
                error.localizedDescription)
        }

        var lines: [String] = [
            "dataset_stats:",
            "  id: \(datasetId.uuidString)",
            "  handle_id: \(handleDrawer.id)",
        ]

        let columnsToStat: [String]
        if let col = requestedColumn {
            // Single-column mode: validate identifier before issuing the query.
            do {
                try validateDatasetColumnIdentifier(col)
            } catch {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "moot_dataset_stats: invalid column identifier \"\(col)\"")
            }
            columnsToStat = [col]
        } else {
            // All-columns mode: use schema summary from handle content.
            columnsToStat = handleContent?.columns.map(\.name) ?? []
            if columnsToStat.isEmpty {
                return ToolDispatcher.textResult(
                    lines.joined(separator: "\n") + "\n  (no column schema in handle)")
            }
        }

        lines.append("stats:")
        for col in columnsToStat {
            do {
                let s = try await datasetStore.columnStats(id: datasetId, column: col)
                // Float values: f64 shortest roundtrip to satisfy the MX-TABULAR parity law.
                // TypedValue.float carries Double (f64 only); TypedValue.int carries Int64.
                lines.append("  \(col):")
                lines.append("    count: \(s.count)")
                lines.append("    distinct_count: \(s.distinctCount)")
                lines.append("    null_count: \(s.nullCount)")
                lines.append("    min: \(typedValueToString(s.min))")
                lines.append("    max: \(typedValueToString(s.max))")
            } catch {
                lines.append("  \(col): error: \(error.localizedDescription)")
            }
        }
        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    // MARK: - CSV parsing

    /// Resolve, security-check, and size-check a caller-supplied csv_path.
    ///
    /// Security rules (MX-TAB-7 §Security review gate):
    ///   1. Canonicalize: `URL.resolvingSymlinksInPath()` follows all symlinks
    ///      to get the real path. The RESOLVED path is what we check and record —
    ///      symlinks to regular files are accepted; symlinks to directories or
    ///      devices are rejected.
    ///   2. Regular file: must be a regular file (not a directory, device, pipe,
    ///      or broken symlink). Checked via FileManager.attributesOfItem.
    ///   3. Size cap: file size must be ≤ csvPathSizeCapBytes (100 MiB). Checked
    ///      before reading to avoid loading an unexpectedly large file into memory.
    ///
    /// Returns the resolved (canonical) absolute path string.
    private static func resolveCSVPath(_ raw: String) throws -> String {
        // 1. Canonicalize to resolve all symlink chains.
        let url = URL(fileURLWithPath: raw).resolvingSymlinksInPath()
        let resolvedPath = url.path

        // 1.5. Import-root confinement (MX-TAB-SEC-1 A1).
        //
        // After canonicalization (symlinks resolved, relative components collapsed),
        // the path MUST lie inside the allowed import root. This prevents a
        // prompt-injected client from reading arbitrary filesystem locations such
        // as /etc/passwd by supplying a relative path or a symlink that escapes
        // the intended directory.
        //
        // Root resolution (D11): the user's home directory is the default root.
        // The comparison is component-safe: the root has a "/" appended before the
        // hasPrefix check so that "/vault-evil/file" cannot match a "/vault" root.
        //
        // Future: make the root configurable via estate configuration if a per-estate
        // config surface is added; see MX-TAB-SEC-1 D11.
        let rawImportRoot = FileManager.default.homeDirectoryForCurrentUser.path
        let importRoot = URL(fileURLWithPath: rawImportRoot).resolvingSymlinksInPath().path
        let rootWithSep = importRoot.hasSuffix("/") ? importRoot : importRoot + "/"
        guard resolvedPath.hasPrefix(rootWithSep) || resolvedPath == importRoot else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "moot_file_dataset: csv_path must be inside the allowed import " +
                "root (\(importRoot)): \(resolvedPath)")
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: resolvedPath) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "moot_file_dataset: csv_path does not exist: \(resolvedPath)")
        }

        // 2. Check that the resolved path is a regular file.
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fm.attributesOfItem(atPath: resolvedPath)
        } catch {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "moot_file_dataset: cannot read csv_path attributes: " +
                error.localizedDescription)
        }
        guard let fileType = attrs[.type] as? FileAttributeType,
              fileType == .typeRegular else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "moot_file_dataset: csv_path must be a regular file " +
                "(not a directory, device, or non-file symlink target): \(resolvedPath)")
        }

        // 3. Size cap: reject before reading to avoid loading a very large file.
        // FileAttributeKey.size returns Int on 64-bit platforms; cast to Int64 safely.
        let fileSize = (attrs[.size] as? Int64) ?? Int64((attrs[.size] as? Int) ?? 0)
        if fileSize > csvPathSizeCapBytes {
            let capMiB = csvPathSizeCapBytes / 1_048_576
            let fileMiB = Double(fileSize) / 1_048_576.0
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "moot_file_dataset: csv_path exceeds size cap " +
                "(\(String(format: "%.1f", fileMiB)) MiB > \(capMiB) MiB limit): " +
                resolvedPath)
        }

        return resolvedPath
    }

    /// Intermediate result from CSV or inline-rows import.
    private struct ParseResult {
        let schema: DatasetSchema
        let rows: [[String: TypedValue]]
    }

    /// Parse a CSV file into a DatasetSchema and typed rows.
    ///
    /// Header row required (first line). Type inference per column: try Int64,
    /// then Double, else TEXT. Empty cells → null. One transaction per call.
    ///
    /// RFC-4180 CSV handling:
    ///   - Fields may be quoted (double-quote wrapper, double-double-quote escape).
    ///   - Bare (unquoted) fields are trimmed of leading/trailing whitespace.
    ///   - CRLF and LF line endings are both accepted.
    ///   - Empty string in an unquoted cell → TypedValue.null.
    ///
    /// When `columnHints` is non-empty and the hint carries a type, the declared
    /// type overrides inference for that column.
    private static func parseCSV(
        at path: String,
        columnHints: [ColumnSpec]
    ) throws -> ParseResult {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "moot_file_dataset: cannot read csv_path: " +
                error.localizedDescription)
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "moot_file_dataset: csv_path is not valid UTF-8")
        }

        let csvLines = splitCSVLines(content)
        guard !csvLines.isEmpty else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "moot_file_dataset: csv_path is empty (header row required)")
        }

        // Parse header row to get column names.
        let headers = parseCSVRecord(csvLines[0])
        guard !headers.isEmpty else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "moot_file_dataset: CSV header row is empty")
        }

        // Validate all header-derived column names.
        for h in headers {
            do { try validateDatasetColumnIdentifier(h) } catch {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "moot_file_dataset: CSV header \"\(h)\" is not a valid " +
                    "column identifier. Column names must match [A-Za-z_][A-Za-z0-9_]*.")
            }
        }

        // Build hint lookup for type overrides (column-name → ColumnType).
        let hintMap = Dictionary(
            uniqueKeysWithValues: columnHints.compactMap { spec -> (String, ColumnType)? in
                guard let t = spec.columnType else { return nil }
                return (spec.name, t)
            }
        )

        // Accumulate raw cell values per column for type inference.
        let dataLines = Array(csvLines.dropFirst())
        var rawRowsByCol: [String: [String?]] = [:]
        for h in headers { rawRowsByCol[h] = [] }

        for line in dataLines {
            let fields = parseCSVRecord(line)
            for (i, h) in headers.enumerated() {
                // Empty string → nil (converts to TypedValue.null during build phase).
                let val: String? = i < fields.count && !fields[i].isEmpty ? fields[i] : nil
                rawRowsByCol[h, default: []].append(val)
            }
        }

        // Infer column types from values, or use the caller-supplied hint.
        var columnDecls: [ColumnDeclaration] = []
        var columnTypes: [String: ColumnType] = [:]
        for h in headers {
            let colType: ColumnType
            if let ht = hintMap[h] {
                colType = ht
            } else {
                let nonNilValues = rawRowsByCol[h]?.compactMap { $0 } ?? []
                colType = inferColumnType(from: nonNilValues)
            }
            columnDecls.append(ColumnDeclaration(name: h, type: colType))
            columnTypes[h] = colType
        }

        let schema = DatasetSchema(columns: columnDecls, primaryKeyColumn: nil)

        // Build typed rows.
        let rowCount = rawRowsByCol.values.first?.count ?? 0
        var typedRows: [[String: TypedValue]] = []
        typedRows.reserveCapacity(rowCount)
        for i in 0..<rowCount {
            var row: [String: TypedValue] = [:]
            for h in headers {
                let raw = rawRowsByCol[h]?[i] ?? nil
                let colType = columnTypes[h] ?? .text
                row[h] = parseTypedValue(raw, as: colType)
            }
            typedRows.append(row)
        }

        return ParseResult(schema: schema, rows: typedRows)
    }

    /// Parse inline rows from a JSONValue array into a DatasetSchema and typed rows.
    ///
    /// Each array element must be a JSON object. Column schema is derived from the
    /// provided columnSpecs (all names already validated by the caller).
    private static func parseInlineRows(
        _ value: JSONValue,
        columnSpecs: [ColumnSpec]
    ) throws -> ParseResult {
        guard let arr = value.arrayValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "moot_file_dataset: rows must be a JSON array")
        }

        // Build column declarations from provided specs (names already validated).
        let columnDecls = columnSpecs.map { spec in
            ColumnDeclaration(name: spec.name, type: spec.columnType ?? .text)
        }
        let schema = DatasetSchema(columns: columnDecls, primaryKeyColumn: nil)

        var typedRows: [[String: TypedValue]] = []
        typedRows.reserveCapacity(arr.count)
        for element in arr {
            guard let obj = element.objectValue else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "moot_file_dataset: each row must be a JSON object")
            }
            var row: [String: TypedValue] = [:]
            for spec in columnSpecs {
                if let jv = obj[spec.name] {
                    row[spec.name] = jsonValueToTyped(jv, hint: spec.columnType)
                } else {
                    row[spec.name] = .null
                }
            }
            // Keys not in the column spec are silently dropped (no unknown-column path).
            typedRows.append(row)
        }

        return ParseResult(schema: schema, rows: typedRows)
    }

    // MARK: - Type inference and conversion

    /// Infer the column type from a sample of non-nil string values.
    ///
    /// Strategy: if every sample parses as Int64 → .int;
    /// if every sample parses as Double → .float; else .text.
    /// Empty samples default to .text.
    private static func inferColumnType(from values: [String]) -> ColumnType {
        guard !values.isEmpty else { return .text }
        if values.allSatisfy({ Int64($0) != nil }) { return .int }
        if values.allSatisfy({ Double($0) != nil }) { return .float }
        return .text
    }

    /// Convert a raw string cell (or nil for empty/missing) to a TypedValue.
    private static func parseTypedValue(_ raw: String?, as type_: ColumnType) -> TypedValue {
        guard let s = raw else { return .null }
        switch type_ {
        case .int:
            if let i = Int64(s) { return .int(i) }
            return s.isEmpty ? .null : .text(s)
        case .float:
            if let d = Double(s) { return .float(d) }
            return s.isEmpty ? .null : .text(s)
        case .bool:
            switch s.lowercased() {
            case "true", "1", "yes": return .bool(true)
            case "false", "0", "no": return .bool(false)
            default: return .text(s)
            }
        case .text:
            return .text(s)
        default:
            // uuid, timestamp, blob, etc. — stored as text in v1.
            return .text(s)
        }
    }

    /// Convert a JSONValue to TypedValue, optionally using a column type hint.
    ///
    /// Note: JSONValue uses `.integer(Int64)` for JSON integer numbers (not `.int`).
    /// `.integer` is the integer case of the JSONValue enum in AriaMcpKit; TypedValue
    /// uses `.int(Int64)` for integer storage. These are distinct enum types.
    private static func jsonValueToTyped(_ jv: JSONValue, hint: ColumnType?) -> TypedValue {
        switch jv {
        case .null:
            return .null
        case .bool(let b):
            return .bool(b)
        // JSONValue.integer is the JSON integer number case (Int64).
        case .integer(let i):
            return .int(i)
        case .double(let d):
            // Promote to int if hint demands it and the value is losslessly representable.
            if let h = hint, h == .int, let i = Int64(exactly: d) { return .int(i) }
            return .float(d)
        case .string(let s):
            if let h = hint {
                return parseTypedValue(s, as: h)
            }
            // Type inference on string values: try Int64, then Double, else text.
            if let i = Int64(s) { return .int(i) }
            if let d = Double(s) { return .float(d) }
            return .text(s)
        case .object, .array:
            // Nested structures stored as text in v1 (no nested-document storage).
            return .text("\(jv)")
        }
    }

    // MARK: - Predicate parsing

    /// Parse a `where` argument to a StoragePredicate.
    ///
    /// Supported format (JSONValue object or string-encoded JSON):
    ///   Single condition: {"col":"name","op":"eq|neq|lt|lte|gt|gte|is_null|is_not_null","val":value}
    ///   Compound: {"and":[...]} or {"or":[...]}
    ///   Absent/null: full table scan (nil predicate).
    private static func parseWherePredicate(
        _ value: JSONValue?,
        tableName: String
    ) throws -> StoragePredicate? {
        guard let jv = value else { return nil }

        // Direct object: parse immediately.
        if case .object(let obj) = jv {
            return try parsePredicate(from: obj, tableName: tableName)
        }

        // String: caller may have sent a JSON-encoded predicate.
        // JSONValue.parse(Data) decodes the JSON without requiring Codable.
        if let strVal = jv.stringValue,
           let data = strVal.data(using: .utf8),
           let parsed = try? JSONValue.parse(data),
           case .object(let obj) = parsed {
            return try parsePredicate(from: obj, tableName: tableName)
        }

        // null / bool / integer / double / array: absent predicate.
        return nil
    }

    private static func parsePredicate(
        from obj: [String: JSONValue],
        tableName: String
    ) throws -> StoragePredicate {
        if let andArr = obj["and"]?.arrayValue {
            let children = try andArr.map { element -> StoragePredicate in
                guard let childObj = element.objectValue else {
                    throw JSONRPCError(
                        code: JSONRPCErrorCode.invalidParams,
                        message: "moot_dataset_query: 'and' elements must be JSON objects")
                }
                return try parsePredicate(from: childObj, tableName: tableName)
            }
            return .and(children)
        }

        if let orArr = obj["or"]?.arrayValue {
            let children = try orArr.map { element -> StoragePredicate in
                guard let childObj = element.objectValue else {
                    throw JSONRPCError(
                        code: JSONRPCErrorCode.invalidParams,
                        message: "moot_dataset_query: 'or' elements must be JSON objects")
                }
                return try parsePredicate(from: childObj, tableName: tableName)
            }
            return .or(children)
        }

        guard let colStr = obj["col"]?.stringValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "moot_dataset_query: where condition must have a 'col' string")
        }
        guard let opStr = obj["op"]?.stringValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "moot_dataset_query: where condition must have an 'op' string")
        }

        // A3: MCP-layer identifier validation (MX-TAB-SEC-1 A3).
        //
        // Validate the column name at parse time before it reaches the backend.
        // This is an independent first gate against prompt injection — a hostile
        // client supplying col: "name; DROP TABLE x" is rejected here with a
        // clean invalidParams error rather than reaching SQL generation.
        //
        // The backend guard at query execution is the second independent layer;
        // two checks exist by design (belt-and-suspenders — comment this intent
        // on the backend side too per the security review spec).
        do {
            try validateDatasetColumnIdentifier(colStr)
        } catch {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "moot_dataset_query: invalid column identifier in where " +
                "condition 'col': \"\(colStr)\". " +
                "Column names must match [A-Za-z_][A-Za-z0-9_]*.")
        }

        let column = Column(table: tableName, name: colStr)

        // Null checks (no value needed).
        if opStr == "is_null" { return .isNull(column) }
        if opStr == "is_not_null" { return .isNotNull(column) }

        // Comparison ops require a value.
        guard let valJV = obj["val"] else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "moot_dataset_query: op '\(opStr)' requires a 'val' field")
        }
        let typedVal = jsonValueToTyped(valJV, hint: nil)

        switch opStr {
        case "eq": return .eq(column, typedVal)
        case "neq": return .neq(column, typedVal)
        case "lt": return .lt(column, typedVal)
        case "lte": return .lte(column, typedVal)
        case "gt": return .gt(column, typedVal)
        case "gte": return .gte(column, typedVal)
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "moot_dataset_query: unknown op '\(opStr)'. " +
                "Supported: eq, neq, lt, lte, gt, gte, is_null, is_not_null, and, or")
        }
    }

    /// Parse an `order_by` argument to an OrderClause array.
    ///
    /// Accepts: array of {"col":"name","dir":"asc|desc"} objects.
    /// Absent or null → [] (no ordering).
    private static func parseOrderBy(
        _ value: JSONValue?,
        tableName: String
    ) throws -> [OrderClause] {
        guard let arr = value?.arrayValue, !arr.isEmpty else { return [] }
        return try arr.map { element in
            guard let obj = element.objectValue,
                  let colStr = obj["col"]?.stringValue else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "moot_dataset_query: each order_by element must have a 'col' string")
            }
            // A3: MCP-layer identifier validation in order_by (MX-TAB-SEC-1 A3).
            //
            // Same two-layer intent as the where-predicate guard: reject hostile
            // column names at the MCP parse boundary before they reach the backend.
            // The backend guard is the second independent layer.
            do {
                try validateDatasetColumnIdentifier(colStr)
            } catch {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "moot_dataset_query: invalid column identifier in order_by " +
                    "'col': \"\(colStr)\". " +
                    "Column names must match [A-Za-z_][A-Za-z0-9_]*.")
            }
            let dir: OrderDirection
            switch (obj["dir"]?.stringValue ?? "asc").lowercased() {
            case "asc", "ascending": dir = .ascending
            case "desc", "descending": dir = .descending
            default:
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "moot_dataset_query: order_by 'dir' must be 'asc' or 'desc'")
            }
            return OrderClause(column: Column(table: tableName, name: colStr), direction: dir)
        }
    }

    // MARK: - Column spec parsing

    /// A partially-parsed column specification from the `columns` argument.
    private struct ColumnSpec {
        let name: String
        let columnType: ColumnType?
    }

    private static func parseColumnSpecs(_ value: JSONValue?) throws -> [ColumnSpec] {
        guard let arr = value?.arrayValue else { return [] }
        return try arr.map { element in
            guard let obj = element.objectValue,
                  let name = obj["name"]?.stringValue else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "moot_file_dataset: each column must be an object with 'name'")
            }
            let colType: ColumnType?
            if let typeStr = obj["type"]?.stringValue {
                switch typeStr.lowercased() {
                case "text", "string": colType = .text
                case "int", "integer": colType = .int
                case "float", "real", "double": colType = .float
                case "bool", "boolean": colType = .bool
                default:
                    throw JSONRPCError(
                        code: JSONRPCErrorCode.invalidParams,
                        message: "moot_file_dataset: unknown column type '\(typeStr)'. " +
                        "Supported: text, int, float, bool")
                }
            } else {
                colType = nil  // Will be inferred from values.
            }
            return ColumnSpec(name: name, columnType: colType)
        }
    }

    // MARK: - TypedValue → string (f64 wire discipline)

    /// Serialize a TypedValue to its human-readable text form for tool output.
    ///
    /// Float discipline: Double uses Swift's String(d) which is the shortest
    /// decimal roundtrip representation (f64 shortest roundtrip, matching the
    /// Rust twin's format!("{}", f64_val) via the `ryu` crate).
    /// Never Float32: no narrowing cast at any point in this file.
    static func typedValueToString(_ v: TypedValue) -> String {
        switch v {
        case .null:        return "null"
        case .bool(let b): return b ? "true" : "false"
        // TypedValue.int carries Int64 (exact, no float rounding).
        case .int(let i):  return "\(i)"
        case .bitmap(let i): return "\(i)"
        // f64 shortest roundtrip: String(d) uses Double's CustomStringConvertible
        // which in Swift 5.9+ produces the shortest roundtrip decimal string.
        case .float(let d): return String(d)
        case .text(let s):
            let escaped = s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        case .uuid(let u): return "\"\(u.uuidString)\""
        case .timestamp(let date):
            let fmt = ISO8601DateFormatter()
            return "\"\(fmt.string(from: date))\""
        default:
            return "<\(v.typeDescription)>"
        }
    }

    // MARK: - CSV record parsing

    /// Split CSV content into non-empty logical lines (normalising CRLF and CR).
    private static func splitCSVLines(_ content: String) -> [String] {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // Filter blank lines only; non-blank interior lines carry row data.
        return normalized.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Parse one CSV record (line) into an array of field strings.
    ///
    /// Handles RFC-4180 quoting: a field wrapped in double-quotes may contain
    /// commas, newlines, and escaped double-quotes (two consecutive double-quotes
    /// represent one literal double-quote). Bare (unquoted) fields are trimmed.
    private static func parseCSVRecord(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0

        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    // Double double-quote → one literal double-quote.
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        current.append("\"")
                        i += 2
                        continue
                    } else {
                        inQuotes = false
                        i += 1
                        continue
                    }
                } else {
                    current.append(ch)
                    i += 1
                }
            } else {
                if ch == "\"" {
                    inQuotes = true
                    i += 1
                } else if ch == "," {
                    fields.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                    i += 1
                } else {
                    current.append(ch)
                    i += 1
                }
            }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    // MARK: - Argument helpers

    private static func requireString(
        _ args: [String: JSONValue], _ key: String
    ) throws -> String {
        guard let val = args[key]?.stringValue, !val.isEmpty else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Missing required string argument: \(key)")
        }
        return val
    }

    private static func decodeSensitivity(
        _ value: JSONValue?
    ) throws -> AdjectiveSensitivity {
        guard let str = value?.stringValue else { return .normal }
        switch str.lowercased() {
        case "normal": return .normal
        case "elevated": return .elevated
        case "restricted": return .restricted
        case "secret": return .secret
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "sensitivity must be normal, elevated, restricted, or secret; " +
                "got '\(str)'")
        }
    }

    // MARK: - Error description helpers

    /// Describe a LocusKitError at the ARIA boundary.
    ///
    /// `withdrawnDatasetHandle` maps to a user-facing refusal message so
    /// the AI client receives actionable guidance rather than an opaque error.
    private static func describeLocusKitError(_ error: LocusKitError) -> String {
        switch error {
        case .withdrawnDatasetHandle(let datasetId):
            return "dataset is withdrawn (id: \(datasetId.uuidString)). " +
                "Restore it first with moot_update_memory mutation=revive before querying."
        default:
            return error.localizedDescription
        }
    }
}
