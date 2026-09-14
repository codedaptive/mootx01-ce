import AriaMCPWire

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
//   isDatasetTool(), dispatch(), and tools().
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

    // MARK: - Tool schema projection

    /// The three dataset tools added to the tool list.
    ///
    /// Schemas are wrapped with withEstateID() so the estate-addressing contract
    /// matches all other interface tools.
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

    // MARK: - Typed v2 lowers

    /// Typed production snapshots for the v2 data-mobility lower. These call
    /// the same store and estate seams as the v1 tools, but never construct or
    /// interpret a rendered `ToolResult`.
    enum DirectFailure: Error, Sendable { case datasetUnavailable }

    static func directFileDataset(
        arguments: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle,
        now: Date
    ) async throws -> JSONValue {
        let name = try requireString(arguments, "name")
        let location = try requireString(arguments, "location")
        let wing = arguments["wing"]?.stringValue
        let sensitivity = try decodeSensitivity(arguments["sensitivity"])
        let columnSpecs = try parseColumnSpecs(arguments["columns"])
        let hasCSV = arguments["csv_path"] != nil
        let hasRows = arguments["rows"] != nil
        guard !(hasCSV && hasRows) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams, message: "moot_file_dataset: supply either rows or csv_path, not both")
        }
        for column in columnSpecs {
            try validateDatasetColumnIdentifier(column.name)
        }

        let schema: DatasetSchema
        let rows: [[String: TypedValue]]
        let source: String
        if let csv = arguments["csv_path"]?.stringValue {
            let resolved = try resolveCSVPath(csv)
            let parsed = try parseCSV(at: resolved, columnHints: columnSpecs)
            schema = parsed.schema
            rows = parsed.rows
            source = "csv:\(URL(fileURLWithPath: resolved).lastPathComponent)"
        } else if let inline = arguments["rows"] {
            guard !columnSpecs.isEmpty else {
                throw JSONRPCError(code: JSONRPCErrorCode.invalidParams, message: "moot_file_dataset: columns is required when using inline rows")
            }
            let parsed = try parseInlineRows(inline, columnSpecs: columnSpecs)
            schema = parsed.schema
            rows = parsed.rows
            source = "inline_rows:\(name)"
        } else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams, message: "moot_file_dataset: either rows or csv_path is required")
        }

        let datasetID = UUID()
        let columnSummaries = schema.columns.map {
            DatasetColumnSummary(name: $0.name, dataType: $0.type.rawValue.uppercased())
        }
        let drawer = try await kit.fileDataset(handle, DatasetFilingFrame(
            datasetID: datasetID,
            schema: schema,
            rows: rows,
            columns: columnSummaries,
            sourceDescription: source,
            wing: wing,
            room: location,
            addedBy: "aria-v2",
            sensitivity: sensitivity,
            udcCode: "000"))

        let store = try await kit.datasetStore(for: handle)

        var signatures = "computed"
        do {
            let sampled = try await store.queryRows(
                id: datasetID, predicate: nil, orderBy: [],
                limit: datasetSignatureSampleSize, offset: nil, columns: nil)
            var statistics: [String: ColumnStats] = [:]
            for column in schema.columns {
                statistics[column.name] = try await store.columnStats(id: datasetID, column: column.name)
            }
            _ = try await kit.computeDatasetSignatures(
                handle: handle, drawerId: drawer.id, columns: columnSummaries,
                columnStats: statistics, sampledRows: sampled, now: now)
        } catch {
            signatures = "pending (\(error.localizedDescription))"
        }
        var data: [String: JSONValue] = [
            "dataset_id": .string(datasetID.uuidString.lowercased()),
            "handle_memory_id": .string(drawer.id),
            "name": .string(name),
            "location": .string(location),
            "columns": .integer(Int64(schema.columns.count)),
            "rows": .integer(Int64(rows.count)),
            "source": .string(source),
            "sensitivity": .string(String(describing: sensitivity)),
            "signatures": .string(signatures),
        ]
        if let wing { data["wing"] = .string(wing) }
        return .object(data)
    }

    static func directDatasetQuery(
        arguments: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let datasetID = try directDatasetID(arguments, tool: "moot_dataset_query")
        let estate = try await kit.estate(for: handle)
        let drawer: Drawer
        do {
            drawer = try await estate.resolveActiveDatasetHandle(datasetId: datasetID)
        } catch {
            throw DirectFailure.datasetUnavailable
        }
        guard let content = try? DatasetHandleContent.decode(from: drawer.content),
              content.datasetId == datasetID else {
            throw DirectFailure.datasetUnavailable
        }
        let schema = try directDatasetSchema(content)
        let tableName = datasetTableName(datasetID)
        let predicate = try strictDirectPredicate(
            arguments["where"], tableName: tableName, schema: schema)
        let order = try strictDirectOrderBy(
            arguments["order_by"], tableName: tableName, schema: schema)
        let limit = Int(arguments["limit"]?.integerValue ?? 100)
        guard (1...1_000).contains(limit) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams, message: "moot_dataset_query: limit must be between 1 and 1000")
        }
        let columns = try strictDirectColumns(arguments["columns"], schema: schema)
        let store = try await kit.datasetStore(for: handle)
        let rows = try await store.queryRows(
            id: datasetID, predicate: predicate, orderBy: order, limit: limit, offset: nil, columns: columns)
        var data: [String: JSONValue] = [
            "dataset_id": .string(datasetID.uuidString.lowercased()),
            "handle_memory_id": .string(drawer.id),
            "state": .string(String(describing: drawer.state)),
            "sensitivity": .string(String(describing: drawer.adjectiveSensitivity)),
            "rows_returned": .integer(Int64(rows.count)),
            "limit": .integer(Int64(limit)),
            "rows": .array(rows.map { row in .object(row.values.mapValues(Self.directJSONValue)) }),
        ]
        data["columns"] = .array(content.columns.map { .string($0.name) })
        data["handle_row_count"] = .integer(Int64(content.rowCount))
        return .object(data)
    }

    static func directDatasetStats(
        arguments: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let datasetID = try directDatasetID(arguments, tool: "moot_dataset_stats")
        let estate = try await kit.estate(for: handle)
        let drawer: Drawer
        do {
            drawer = try await estate.resolveActiveDatasetHandle(datasetId: datasetID)
        } catch {
            throw DirectFailure.datasetUnavailable
        }
        let requested = arguments["column"]?.stringValue
        if let requested { try validateDatasetColumnIdentifier(requested) }
        let columns: [String]
        if let requested {
            columns = [requested]
        } else {
            columns = (try? DatasetHandleContent.decode(from: drawer.content))?.columns.map(\.name) ?? []
        }
        let store = try await kit.datasetStore(for: handle)
        var stats: [String: JSONValue] = [:]
        for column in columns {
            let value = try await store.columnStats(id: datasetID, column: column)
            stats[column] = .object([
                "count": .integer(value.count),
                "distinct_count": .integer(value.distinctCount),
                "null_count": .integer(value.nullCount),
                "min": directJSONValue(value.min),
                "max": directJSONValue(value.max),
            ])
        }
        return .object([
            "dataset_id": .string(datasetID.uuidString.lowercased()),
            "handle_memory_id": .string(drawer.id),
            "stats": .object(stats),
        ])
    }

    private static func directDatasetID(_ arguments: [String: JSONValue], tool: String) throws -> UUID {
        let value = try requireString(arguments, "id")
        guard let id = UUID(uuidString: value) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams, message: "\(tool): id must be a valid UUID")
        }
        return id
    }

    private enum DirectDatasetColumnKind {
        case text
        case integer
        case float
        case bool
    }

    /// Interpret the schema captured with the authorized dataset handle. The
    /// selected v2 query path validates every referenced column and comparison
    /// type against this schema before constructing a storage predicate. The
    /// legacy v1 parser remains unchanged below.
    private static func directDatasetSchema(
        _ content: DatasetHandleContent
    ) throws -> [String: DirectDatasetColumnKind] {
        var schema: [String: DirectDatasetColumnKind] = [:]
        for column in content.columns {
            try validateDatasetColumnIdentifier(column.name)
            guard schema[column.name] == nil else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "moot_dataset_query: dataset schema contains duplicate column '\(column.name)'")
            }
            switch column.dataType.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
            case "BOOL", "BOOLEAN": schema[column.name] = .bool
            case "INT", "INTEGER": schema[column.name] = .integer
            case "FLOAT", "REAL", "DOUBLE": schema[column.name] = .float
            default: schema[column.name] = .text
            }
        }
        guard !schema.isEmpty else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "moot_dataset_query: dataset schema is unavailable")
        }
        return schema
    }

    private static func strictDirectPredicate(
        _ value: JSONValue?,
        tableName: String,
        schema: [String: DirectDatasetColumnKind]
    ) throws -> StoragePredicate? {
        guard let value else { return nil }
        var nodes = 0
        return try strictDirectPredicate(
            value, tableName: tableName, schema: schema, depth: 1, nodes: &nodes)
    }

    private static func strictDirectPredicate(
        _ value: JSONValue,
        tableName: String,
        schema: [String: DirectDatasetColumnKind],
        depth: Int,
        nodes: inout Int
    ) throws -> StoragePredicate {
        guard depth <= 8 else { throw datasetQueryInvalid("predicate exceeds maximum depth") }
        nodes += 1
        guard nodes <= 128 else { throw datasetQueryInvalid("predicate exceeds maximum node count") }
        guard let object = value.objectValue else {
            throw datasetQueryInvalid("predicate values must be objects")
        }

        if object.count == 1, let children = object["and"]?.arrayValue {
            guard !children.isEmpty else { throw datasetQueryInvalid("predicate compound must not be empty") }
            return .and(try children.map {
                try strictDirectPredicate(
                    $0, tableName: tableName, schema: schema, depth: depth + 1, nodes: &nodes)
            })
        }
        if object.count == 1, let children = object["or"]?.arrayValue {
            guard !children.isEmpty else { throw datasetQueryInvalid("predicate compound must not be empty") }
            return .or(try children.map {
                try strictDirectPredicate(
                    $0, tableName: tableName, schema: schema, depth: depth + 1, nodes: &nodes)
            })
        }

        guard let columnName = object["col"]?.stringValue else {
            throw datasetQueryInvalid("comparison requires a column")
        }
        do { try validateDatasetColumnIdentifier(columnName) } catch {
            throw datasetQueryInvalid("invalid predicate column")
        }
        guard let columnKind = schema[columnName] else {
            throw datasetQueryInvalid("unknown predicate column")
        }
        guard let operation = object["op"]?.stringValue else {
            throw datasetQueryInvalid("comparison requires an operator")
        }
        let column = Column(table: tableName, name: columnName)
        if operation == "is_null" || operation == "is_not_null" {
            guard object.count == 2, object["val"] == nil else {
                throw datasetQueryInvalid("null predicate must contain only col and op")
            }
            return operation == "is_null" ? .isNull(column) : .isNotNull(column)
        }

        guard ["eq", "neq", "lt", "lte", "gt", "gte"].contains(operation),
              object.count == 3, let raw = object["val"] else {
            throw datasetQueryInvalid("comparison must contain only col, op, and val")
        }
        let typed = try strictDirectPredicateValue(raw, kind: columnKind, operation: operation)
        switch operation {
        case "eq": return .eq(column, typed)
        case "neq": return .neq(column, typed)
        case "lt": return .lt(column, typed)
        case "lte": return .lte(column, typed)
        case "gt": return .gt(column, typed)
        case "gte": return .gte(column, typed)
        default: preconditionFailure("operation was validated above")
        }
    }

    private static func strictDirectPredicateValue(
        _ value: JSONValue,
        kind: DirectDatasetColumnKind,
        operation: String
    ) throws -> TypedValue {
        switch (kind, value) {
        case (.bool, .bool(let value)) where operation == "eq" || operation == "neq":
            return .bool(value)
        case (.integer, .integer(let value)):
            return .int(value)
        case (.float, .integer(let value)):
            return .float(Double(value))
        case (.float, .double(let value)):
            return .float(value)
        case (.text, .string(let value)):
            return .text(value)
        case (.bool, _):
            throw datasetQueryInvalid("boolean columns permit only boolean eq or neq predicates")
        case (.integer, _):
            throw datasetQueryInvalid("integer columns require an integer comparison value")
        case (.float, _):
            throw datasetQueryInvalid("numeric columns require a numeric comparison value")
        case (.text, _):
            throw datasetQueryInvalid("text columns require a string comparison value")
        }
    }

    private static func strictDirectOrderBy(
        _ value: JSONValue?,
        tableName: String,
        schema: [String: DirectDatasetColumnKind]
    ) throws -> [OrderClause] {
        guard let value else { return [] }
        guard let values = value.arrayValue else {
            throw datasetQueryInvalid("order_by must be an array")
        }
        return try values.map { value in
            guard let object = value.objectValue,
                  Set(object.keys).isSubset(of: ["col", "dir"]),
                  let columnName = object["col"]?.stringValue else {
                throw datasetQueryInvalid("order_by entries require col and optional dir")
            }
            do { try validateDatasetColumnIdentifier(columnName) } catch {
                throw datasetQueryInvalid("invalid order_by column")
            }
            guard schema[columnName] != nil else {
                throw datasetQueryInvalid("unknown order_by column")
            }
            let direction: OrderDirection
            switch object["dir"] {
            case nil, .some(.string("asc")): direction = .ascending
            case .some(.string("desc")): direction = .descending
            default: throw datasetQueryInvalid("order_by dir must be asc or desc")
            }
            return OrderClause(column: Column(table: tableName, name: columnName), direction: direction)
        }
    }

    private static func strictDirectColumns(
        _ value: JSONValue?,
        schema: [String: DirectDatasetColumnKind]
    ) throws -> [String]? {
        guard let value else { return nil }
        guard let values = value.arrayValue else {
            throw datasetQueryInvalid("projection columns must be an array")
        }
        if values.isEmpty { return nil }
        return try values.map { value in
            guard let columnName = value.stringValue, !columnName.isEmpty else {
                throw datasetQueryInvalid("projection columns must be non-empty strings")
            }
            do { try validateDatasetColumnIdentifier(columnName) } catch {
                throw datasetQueryInvalid("invalid projection column")
            }
            guard schema[columnName] != nil else {
                throw datasetQueryInvalid("unknown projection column")
            }
            return columnName
        }
    }

    private static func datasetQueryInvalid(_ reason: String) -> JSONRPCError {
        JSONRPCError(
            code: JSONRPCErrorCode.invalidParams,
            message: "moot_dataset_query: \(reason)")
    }

    private static func directJSONValue(_ value: TypedValue) -> JSONValue {
        switch value {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .int(let value), .bitmap(let value): return .integer(value)
        case .float(let value): return .double(value)
        case .text(let value): return .string(value)
        case .uuid(let value): return .string(value.uuidString.lowercased())
        case .timestamp(let value): return .string(ISO8601DateFormatter().string(from: value))
        default: return .string(typedValueToString(value))
        }
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
        // Root resolution (D11): the current user's home directory is the default
        // root. `NSHomeDirectory()` is used rather than
        // `FileManager.homeDirectoryForCurrentUser` because the latter is
        // unavailable on iOS; `NSHomeDirectory()` is cross-platform and returns
        // the same path on the (non-sandboxed) macOS server while returning the
        // app's sandbox container on iOS — the correct import root per platform.
        // The comparison is component-safe: the root has a "/" appended before the
        // hasPrefix check so that "/vault-evil/file" cannot match a "/vault" root.
        //
        // Future: make the root configurable via estate configuration if a per-estate
        // config surface is added; see MX-TAB-SEC-1 D11.
        let rawImportRoot = NSHomeDirectory()
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
