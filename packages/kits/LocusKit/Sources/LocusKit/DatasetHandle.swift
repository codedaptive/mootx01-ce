// DatasetHandle.swift
// LocusKit
//
// Dataset handle as first-class drawer (MX-TAB-4).
//
// The handle is an ordinary drawer with contentKind == .dataset.
// Its content field stores DatasetHandleContent JSON.
// The creation seam (captureDatasetHandle) is the ONLY authorised
// path — the FDC classifier (moot_n_fdc / runReclassifyFDC) is barred
// from emitting contentKind .dataset; dataset handles are always skipped
// during reclassification.
//
// Sensitivity floor invariant (v1): rows appended to the backing dataset
// table are expected to carry sensitivity at or below the handle drawer's
// sensitivity tier. This is an operator convention in v1 — no per-row
// enforcement exists yet. MX-TAB-5 will add column-level sensitivity gating.

import Foundation
import SubstrateTypes
import SubstrateKernel
import SubstrateLib

// MARK: - DatasetColumnSummary

/// Schema summary for one column in a dataset handle.
///
/// Stored inside `DatasetHandleContent.columns`. The `dataType` string
/// matches the backend DDL type supplied at `DatasetStore.createDataset`
/// time (e.g. "TEXT", "INTEGER", "REAL"). Case and whitespace are
/// preserved verbatim; no normalisation is applied by the handle layer.
///
/// Mirrors Rust `DatasetColumnSummary` in `dataset_handle.rs` (serde
/// `rename_all = "camelCase"` — keys match Swift Codable defaults).
public struct DatasetColumnSummary: Codable, Sendable, Equatable {
    /// Column name. Validated via `validateDatasetColumnIdentifier` at
    /// dataset creation time; this value is already clean when stored here.
    public let name: String

    /// Backend DDL type string (e.g. "TEXT", "INTEGER", "REAL"). Case
    /// and whitespace are preserved verbatim from the schema declaration.
    public let dataType: String

    public init(name: String, dataType: String) {
        self.name = name
        self.dataType = dataType
    }
}

// MARK: - DatasetHandleContent

/// JSON payload stored in `Drawer.content` for drawers with
/// `contentKind == .dataset`.
///
/// Serialised as camelCase JSON to match the Rust serde
/// `rename_all = "camelCase"` attribute in `dataset_handle.rs`.
/// Foundation's `JSONEncoder` / `JSONDecoder` use camelCase struct
/// property names by default, so no custom key strategy is required.
///
/// Reserved fields (MX-TAB-5): `tableSignature` and `columnSignatures`
/// are present in the schema now so MX-TAB-5 can populate them without
/// a content-field schema migration. In v1 (MX-TAB-4) they are always nil.
public struct DatasetHandleContent: Codable, Sendable, Equatable {

    /// UUID of the backing dataset table in the `DatasetStore`.
    /// Used by the erase cascade in `VerbSurface.expunge` to call
    /// `DatasetStore.dropDataset(id:)` when the handle is erased.
    public let datasetId: UUID

    /// Column schema summary at handle-creation time. Informational —
    /// the authoritative schema lives in the `DatasetStore` itself.
    public let columns: [DatasetColumnSummary]

    /// Row count at handle-creation time. Informational; may drift as
    /// rows are appended via `DatasetStore.appendRows`.
    public let rowCount: Int

    /// Human-readable description of the dataset's origin (e.g. CSV
    /// filename, API endpoint, tool invocation summary).
    public let sourceDescription: String

    // MARK: MX-TAB-5 reserved signature fields

    /// Reserved for MX-TAB-5: dataset-level Merkle signature string.
    /// Always nil in v1 (MX-TAB-4). The field exists in the JSON schema
    /// now so MX-TAB-5 can populate it without a migration.
    public let tableSignature: String?

    /// Reserved for MX-TAB-5: per-column content signatures.
    /// Keyed by column name. Always nil in v1 (MX-TAB-4). The field
    /// exists in the JSON schema now so MX-TAB-5 can populate it without
    /// a migration.
    public let columnSignatures: [String: String]?

    public init(
        datasetId: UUID,
        columns: [DatasetColumnSummary],
        rowCount: Int,
        sourceDescription: String,
        tableSignature: String? = nil,
        columnSignatures: [String: String]? = nil
    ) {
        self.datasetId = datasetId
        self.columns = columns
        self.rowCount = rowCount
        self.sourceDescription = sourceDescription
        self.tableSignature = tableSignature
        self.columnSignatures = columnSignatures
    }

    // MARK: - JSON round-trip

    /// Encode to a JSON string for storage in `Drawer.content`.
    ///
    /// Throws `LocusKitError.invalidContent` when JSON encoding fails or
    /// the output is not valid UTF-8 (both are programmer errors in
    /// practice; documented here for completeness).
    public func encode() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw LocusKitError.invalidContent(
                "DatasetHandleContent: JSON encoding produced non-UTF-8 output"
            )
        }
        return string
    }

    /// Decode from the JSON string stored in `Drawer.content`.
    ///
    /// Throws `LocusKitError.invalidContent` when the string is not valid
    /// UTF-8 or when JSON decoding fails, embedding the underlying error
    /// message so callers can log the cause without re-wrapping.
    public static func decode(from json: String) throws -> DatasetHandleContent {
        guard let data = json.data(using: .utf8) else {
            throw LocusKitError.invalidContent(
                "DatasetHandleContent: content is not valid UTF-8"
            )
        }
        do {
            return try JSONDecoder().decode(DatasetHandleContent.self, from: data)
        } catch {
            throw LocusKitError.invalidContent(
                "DatasetHandleContent: JSON decode failed: \(error)"
            )
        }
    }
}

// MARK: - Embedding model sentinel for dataset handles

/// Sentinel embeddingModelID for dataset handle drawers.
///
/// Dataset handles carry no vector embedding — there is no content blob
/// to embed. The sentinel satisfies `DrawerStore.addDrawer`'s non-empty
/// validation while making the intent explicit at the storage layer.
/// The VectorKit encode pipeline skips drawers whose embeddingModelID
/// does not match a registered model, so no embedding is generated.
///
/// Mirrors the Rust constant `DATASET_HANDLE_EMBEDDING_MODEL_ID` in
/// `dataset_handle.rs`.
public let datasetHandleEmbeddingModelID = "dataset-handle"

/// Embedding model ID stamped on all drawers created via the VaultKit
/// import path (JsonImportBridge, PalaceBridge, DrawerMapping). Drawers
/// with this ID carry no vector embedding — the import path does not run
/// the encode pipeline. Single source of truth for all import writers in
/// both Swift and Rust.
///
/// Mirrors the Rust constant `IMPORT_EMBEDDING_MODEL_ID` in
/// `dataset_handle.rs`.
public let importEmbeddingModelID = "vaultkit-noembed-v1"

// MARK: - Estate + Dataset handle verbs

public extension Estate {

    // MARK: captureDatasetHandle

    /// Create a dataset handle drawer — the only authorised path for
    /// `contentKind == .dataset` drawers.
    ///
    /// ## Why a dedicated creation seam
    ///
    /// The FDC classifier (`moot_n_fdc` / `runReclassifyFDC`) is explicitly
    /// barred from emitting `contentKind .dataset` and skips dataset-kind
    /// drawers during reclassification. The ordinary `capture(_:CaptureFrame)`
    /// verb does not set `contentKind` to `.dataset` because `CaptureFrame`
    /// was designed before the dataset kind existed and has no `contentKind`
    /// parameter. This seam assembles the correct operational bitmap and
    /// structures the `DatasetHandleContent` JSON payload.
    ///
    /// ## Sensitivity floor invariant (v1)
    ///
    /// Rows appended to the backing dataset table are expected to carry
    /// sensitivity at or below the handle's `sensitivity` tier. This is
    /// an operator convention in v1 — no per-row enforcement exists yet.
    /// MX-TAB-5 will add column-level row sensitivity gating.
    ///
    /// ## Parameters
    ///
    /// - datasetId: UUID of the already-created dataset in `DatasetStore`.
    ///   The handle does NOT create the table; it records a reference to
    ///   an existing one. Callers create the dataset via
    ///   `DatasetStore.createDataset` first, then file the handle here.
    /// - columns: Column schema summary at creation time. Informational.
    /// - rowCount: Row count at creation time. May drift after appends.
    /// - sourceDescription: Human-readable provenance (CSV name, endpoint, etc.).
    /// - wing: Wing name. Nil resolves to the estate default wing.
    /// - room: Room name. Must be non-empty.
    /// - addedBy: Actor identifier. Must be non-empty.
    /// - sensitivity: Adjective sensitivity tier for the handle and its rows.
    /// - latticeAnchor: UDC classification anchor. `udcCode` must be
    ///   non-empty (invariant I-5).
    ///
    /// - Returns: The stored `Drawer` with generated id and all bitmap
    ///   fields populated.
    func captureDatasetHandle(
        datasetId: UUID,
        columns: [DatasetColumnSummary],
        rowCount: Int,
        sourceDescription: String,
        wing: String? = nil,
        room: String,
        addedBy: String,
        sensitivity: AdjectiveSensitivity = .normal,
        latticeAnchor: LatticeAnchor
    ) async throws -> Drawer {
        guard !room.isEmpty else {
            throw LocusKitError.invalidContent(
                "captureDatasetHandle: room must not be empty"
            )
        }
        guard !addedBy.isEmpty else {
            throw LocusKitError.invalidContent(
                "captureDatasetHandle: addedBy must not be empty"
            )
        }
        guard !latticeAnchor.udcCode.isEmpty else {
            throw LocusKitError.invalidContent(
                "captureDatasetHandle: latticeAnchor.udcCode must not be empty (spec I-5)"
            )
        }

        // Encode the handle payload as JSON for Drawer.content.
        // The JSON field keys are camelCase (Swift Codable default) matching
        // the Rust serde rename_all = "camelCase" in dataset_handle.rs.
        let handleContent = DatasetHandleContent(
            datasetId: datasetId,
            columns: columns,
            rowCount: rowCount,
            sourceDescription: sourceDescription
        )
        let contentJSON = try handleContent.encode()

        // Operational bitmap assembly (cookbook §2.4 v0.6):
        //   bits 0–5   capture_channel — .typed (raw 0, default)
        //   bits 6–11  content_kind    — .dataset (raw 7)
        //   bits 12–23 feature_flags   — none for dataset handles in v1
        let opBitmap = BitField.writeField(
            Int64(ContentKind.dataset.rawValue),
            into: BitField.writeField(
                Int64(CaptureChannel.typed.rawValue),
                into: 0, shift: 0, width: 6
            ),
            shift: 6, width: 6
        )

        // Adjective bitmap assembly (cookbook §2.3 v0.6):
        //   bits 0–5   state            — .active (raw 0, default)
        //   bits 6–11  sensitivity      — caller-supplied, scale-gapped raw
        //   bits 12–17 exportability    — .private_ (raw 0, default)
        //   bits 18–23 trust            — .verbatim (raw 0, default)
        let adjBitmap = BitField.writeField(
            Int64(sensitivity.rawValue),
            into: 0, shift: 6, width: 6
        )

        // Provenance bitmap assembly (cookbook §2.5):
        //   bits 0–5   source_type — .user (raw 0, operator/agent actor)
        //   all other fields default to 0
        let provenanceBitmap = BitField.writeField(
            Int64(SourceType.user.rawValue),
            into: 0, shift: 0, width: 6
        )

        let now = Date()
        // Use the caller-supplied wing or the estate default.
        // `defaultWingName` is a module-level public constant in DefaultWings.swift;
        // `defaultWing()` (the same value) is private to EstateVerbs.swift and is
        // not accessible from this extension file.
        let wingName = wing ?? defaultWingName
        guard let root = try await nodeStore.rootNode() else {
            throw LocusKitError.databaseUnavailable(
                "captureDatasetHandle: estate root node not found — estate not provisioned"
            )
        }
        let wingNode = try await nodeStore.createNode(
            displayName: wingName, parentId: root.id, now: now)
        let roomNode = try await nodeStore.createNode(
            displayName: room, parentId: wingNode.id, now: now)

        let drawer = Drawer(
            content: contentJSON,
            parentNodeId: roomNode.id.uuidString,
            addedBy: addedBy,
            filedAt: now,
            eventTime: now,
            // Dataset handles carry no vector embedding. The sentinel
            // satisfies DrawerStore's non-empty validation; the VectorKit
            // encode pipeline skips drawers whose model ID is unregistered.
            embeddingModelID: datasetHandleEmbeddingModelID,
            provenance: provenanceBitmap,
            adjectiveBitmap: adjBitmap,
            operationalBitmap: opBitmap,
            lineageID: UUID(),
            udcCode: latticeAnchor.udcCode,
            udcFacets: latticeAnchor.udcFacets,
            wikidataQID: latticeAnchor.wikidataQID,
            wikidataQidsSecondary: latticeAnchor.wikidataQidsSecondary
        )
        try await addDrawerCovered(drawer, now: now)
        return drawer
    }

    // MARK: drawerById

    /// Return the drawer for `rowID`, or nil when no row exists.
    ///
    /// Tombstoned and content-zeroed rows are returned unfiltered so the
    /// caller can inspect state after an expunge. Used by GLK's
    /// `VerbSurface.expunge` to read the drawer content BEFORE the storage
    /// expunge zeroes the blob, enabling the dataset-erase cascade to
    /// extract `datasetId` from a `.dataset`-kind handle.
    ///
    /// Mirrors Rust `Estate::drawer_by_id` in `estate_verbs.rs`.
    func drawerById(rowID: String) async throws -> Drawer? {
        try await store.getDrawer(id: rowID)
    }

    // MARK: appendAuditEvent

    /// Append an arbitrary audit event to this estate's audit log.
    ///
    /// The underlying storage operation is identical to `sealExpungeAudit` —
    /// both call `storage.auditLog.append`. The distinct name signals the
    /// different semantic intent at the call site: `sealExpungeAudit` closes
    /// a deferred expunge event; `appendAuditEvent` records supplementary
    /// events such as the dataset table-drop that accompanies an erase
    /// of a `.dataset`-kind handle.
    ///
    /// Mirrors Rust `Estate::append_audit_event` in `estate_verbs.rs`.
    func appendAuditEvent(_ event: AuditEvent) async throws {
        // Delegates to DrawerStore.appendAuditEvent, which appends to
        // storage.auditLog. The semantic distinction from sealExpungeAudit
        // lives in the verb string inside the AuditEvent, not in the storage path.
        try await store.appendAuditEvent(event)
    }

    // MARK: findDatasetHandles

    /// All drawers with `contentKind == .dataset` that reference `datasetId`,
    /// ordered by `filedAt` ascending.
    ///
    /// Performs a full-corpus scan in v1 because dataset handles are rare
    /// (O(datasets), not O(drawers)). A targeted index is deferred to a
    /// future mission if the corpus grows large enough to require it.
    ///
    /// Mirrors Rust `Estate::find_dataset_handles` in `estate_verbs.rs`.
    func findDatasetHandles(datasetId: UUID) async throws -> [Drawer] {
        let all = try await store.allDrawers()
        return all.compactMap { drawer -> Drawer? in
            guard drawer.contentKind == .dataset else { return nil }
            guard let content = try? DatasetHandleContent.decode(from: drawer.content) else {
                return nil
            }
            return content.datasetId == datasetId ? drawer : nil
        }
    }

    // MARK: patchDatasetHandleSignatures (MX-TAB-5)

    /// Write computed table and column signatures into an existing dataset
    /// handle drawer without re-running `captureDatasetHandle`.
    ///
    /// Decodes the current `DatasetHandleContent` from `rowID`, replaces the
    /// `tableSignature` and `columnSignatures` fields with the supplied values,
    /// re-encodes to JSON, and writes the updated JSON back via
    /// `DrawerStore.updateDatasetContent`. The update is a direct column write
    /// — no audit event is appended and no supersession cascade fires.
    ///
    /// Signature computation is a deterministic annotation: the same
    /// schema, stats, and sampled rows always produce the same hex strings,
    /// so writing the signatures twice is idempotent.
    ///
    /// Dreaming / matrix safety: the handle drawer remains an ordinary drawer
    /// in the estate's bitmap index. Updating `content` does not feed the
    /// association matrix or trigger distillation / dreaming — the matrix tier
    /// reads adjective and operational bitmaps, not the JSON content blob.
    ///
    /// Called by `GeniusLocusKit.computeDatasetSignatures` (MX-TAB-5); the
    /// MX-TAB-7 tool layer calls that function.
    ///
    /// Mirrors Rust `Estate::patch_dataset_handle_signatures` in
    /// `locus_kit::dataset_handle`.
    ///
    /// - Parameters:
    ///   - rowID: The drawer id of the existing dataset handle (`Drawer.id`).
    ///   - tableSignature: Hex-encoded SHA-256 over the schema + sampled
    ///     content preimage (domain tag 0x10).
    ///   - columnSignatures: Map from column name to hex-encoded SHA-256 over
    ///     the column sketch preimage (domain tag 0x11). Empty dict is valid
    ///     when the dataset has no declared columns.
    ///   - now: Caller-supplied timestamp (deterministic-engine rule — callers
    ///     must not call `Date()` inside engine or store methods).
    /// - Returns: The updated `Drawer` read back from storage, reflecting
    ///   the new content JSON with signature fields populated.
    /// - Throws:
    ///   - `LocusKitError.drawerNotFound` when `rowID` does not exist in
    ///     storage or when the update affects zero rows.
    ///   - `LocusKitError.invalidContent` when the stored content JSON fails
    ///     to decode as `DatasetHandleContent`.
    func patchDatasetHandleSignatures(
        rowID: String,
        tableSignature: String,
        columnSignatures: [String: String],
        now: Date
    ) async throws -> Drawer {
        // Read the current drawer to confirm existence and preserve other fields.
        guard let existing = try await store.getDrawer(id: rowID) else {
            throw LocusKitError.drawerNotFound(id: rowID)
        }
        let current = try DatasetHandleContent.decode(from: existing.content)

        // Build the updated payload with signatures populated.
        // All other fields (datasetId, columns, rowCount, sourceDescription)
        // are preserved verbatim — this patch touches only the signature fields.
        let updated = DatasetHandleContent(
            datasetId: current.datasetId,
            columns: current.columns,
            rowCount: current.rowCount,
            sourceDescription: current.sourceDescription,
            tableSignature: tableSignature,
            columnSignatures: columnSignatures
        )
        let newJSON = try updated.encode()

        // Write the updated content to the drawers table.
        // A zero count means the row disappeared between the read and the
        // update (concurrent expunge); treat as DrawerNotFound.
        let updatedCount = try await store.updateDatasetContent(
            drawerId: rowID,
            content: newJSON
        )
        guard updatedCount > 0 else {
            throw LocusKitError.drawerNotFound(id: rowID)
        }

        // Read back the drawer so the caller has the current storage state.
        guard let refreshed = try await store.getDrawer(id: rowID) else {
            throw LocusKitError.drawerNotFound(id: rowID)
        }

        // AND-in the cleared operational bitmap to lower the room/wing
        // operationalAND aggregate. updateDatasetContent clears bit 19
        // (hasCurrentRepresentation) on a live (non-tombstoned) drawer;
        // if the room AND previously showed bit 19 = 1 (all drawers
        // distilled), the sweep would otherwise falsely skip the room.
        // Lowering is always safe (under-approximation). Tombstone/expunge
        // paths need no AND-in — the sweep only visits active drawers.
        let nodeNames = try await store.resolveNodeNames(parentNodeIds: [refreshed.parentNodeId])
        let resolved = nodeNames[refreshed.parentNodeId] ?? (wing: "", room: "")
        try await containerFP.andInOperational(
            wing: resolved.wing, room: resolved.room,
            operational: refreshed.operationalBitmap,
            now: now)

        return refreshed
    }

    // MARK: resolveActiveDatasetHandle

    /// Return the active dataset handle for `datasetId`, or throw.
    ///
    /// - If no handle exists for the id: throws
    ///   `LocusKitError.drawerNotFound(id:)`.
    /// - If a handle exists but is withdrawn (state in cluster B):
    ///   throws `LocusKitError.withdrawnDatasetHandle(datasetId:)`.
    /// - If a handle exists and is active (state in cluster A): returns
    ///   the handle drawer.
    ///
    /// Withdrawal is a belief-state change, NOT a destructive erase.
    /// The backing dataset table is NOT dropped by this call. Use GLK's
    /// `VerbSurface.expunge` to erase both the handle and the table.
    ///
    /// Mirrors Rust `Estate::resolve_active_dataset_handle` in
    /// `estate_verbs.rs`.
    func resolveActiveDatasetHandle(datasetId: UUID) async throws -> Drawer {
        let handles = try await findDatasetHandles(datasetId: datasetId)
        guard !handles.isEmpty else {
            throw LocusKitError.drawerNotFound(id: datasetId.uuidString)
        }
        // Search for a cluster-A (currently believed) non-tombstoned handle.
        if let active = handles.first(where: { drawer in
            guard drawer.tombstonedAt == nil else { return false }
            // Bits 0–5 of adjectiveBitmap encode the State raw value (cookbook §2.3).
            let stateRaw = Int(BitField.extractField(drawer.adjectiveBitmap, shift: 0, width: 6))
            let state = State(rawValue: stateRaw) ?? .active
            return state.isClusterA
        }) {
            return active
        }
        // All handles are withdrawn, superseded, expired, or tombstoned.
        throw LocusKitError.withdrawnDatasetHandle(datasetId: datasetId)
    }
}
