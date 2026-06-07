// EstateAdmin.swift
//
// The ADMIN-PLANE engine for moot-mgr (P6, MANAGER_1.0_PLAN.md §4 P6):
// estate provisioning and lifecycle, driven through GeniusLocusKit.
//
// ========================== SECURITY BOUNDARY (ADMIN) ========================
// This engine performs the resident host's PRIVILEGED writes: it creates real
// MOOTs through the GLK substrate (manifest + write-gate + audit + clock — never
// a side-door SQLite file, concepts §1.8) and tears their backing stores down.
//
// It is NEVER reachable from the unauthenticated read surface. The only paths in
// are the admin verb cases in `HTTPReadAPI.applyControl`, which BOTH gated
// surfaces dispatch through:
//   * the UDS control channel (ControlChannel, socket 0600 — OS authenticates by
//     the connecting process's uid via the file-permission bits), and
//   * the token+Origin HTTP control path (`handleControl`: constant-time Bearer
//     token AND a loopback/absent Origin check before any verb runs).
// `applyControl` reaches this engine only AFTER that gate has admitted the
// caller. There is no GET route, no static asset, and no read payload that
// touches `EstateAdmin`. (See HTTPReadAPI.swift's SECURITY BOUNDARY block.)
//
// `destroy` carries a second guard at this layer: the operator must re-type the
// estate's exact name (concepts §1.8 — "destroying a MOOT … type-the-estate-name
// -to-confirm"). A name mismatch refuses the destroy even for an authenticated
// caller. The GLK destroy then tears down every sub-store the kind wired.
// ===========================================================================
//
// Determinism: provisioning carries no time-dependent computation, so no `now`
// parameter is threaded here — DrawerStore mints the manifest timestamps at
// schema-creation time (see EstateLifecycle.provision). The engine holds no
// clock. The GLK telemetry emitters stamp their own ts inside the kit.

import Foundation
import OSLog
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitSQLite
import PersistenceKitInMemory

// MARK: - AdminError

/// Errors raised by the admin engine before it reaches GLK. Structured per the
/// project error rule (no optionals-plus-logging).
public enum AdminError: Error, Sendable, Equatable {
    /// A request field failed validation (empty name, bad zoom window, unknown
    /// enum). `detail` names the offending field.
    case invalidRequest(detail: String)
    /// A lifecycle verb named an estate UUID the engine is not hosting.
    case unknownEstate(uuid: String)
    /// A destroy request's confirm-name did not match the estate's stored name.
    case destroyConfirmMismatch
}

// MARK: - EstateAdmin

/// The admin-plane engine: owns a `GeniusLocusKit`, provisions and tears down
/// estates, and reflects their mount state back for the read plane.
///
/// One instance per resident host, owned by `ResidentHost` and reached only via
/// the gated control surface. Actor-isolated so the GLK registry and the per-
/// estate provenance map are serialized.
public actor EstateAdmin {

    /// The composition layer the engine drives. Each provisioned estate is one
    /// open estate in this kit's registry.
    private let kit: GeniusLocusKit

    /// Per-estate provenance the engine must remember to drive lifecycle and the
    /// read reflection: the GLK handle, the backing storage instance (needed by
    /// `destroy`, which clears the store), and the requested backend kind (for
    /// the read badge). Keyed by estate UUID string so a lifecycle verb can
    /// resolve a request by id.
    private struct Provenance {
        let handle: EstateHandle
        let storage: any Storage
        let backend: EstateBackendKind
        /// The composition kind requested at provision time, retained for the read
        /// badge. GLK persists the kind in the manifest's kind-prefixed framework
        /// profile, but `estate(for:)` is package-internal, so the engine keeps the
        /// kind here rather than reading it back across the kit boundary.
        let kind: EstateKind
    }
    private var hosted: [String: Provenance] = [:]

    /// Directory under which SQLite-backed admin estates are created (one
    /// subdirectory per estate). InMemory estates ignore this. The host points
    /// it at a data dir beside the stats store; tests point it at a scratch dir.
    private let estatesDirectory: URL

    private let logger = Logger(subsystem: "com.mootx01.kit", category: "EstateAdmin")

    /// Create an admin engine.
    ///
    /// - Parameter estatesDirectory: Filesystem directory for SQLite-backed
    ///   estate stores. Created on demand at provision time. InMemory estates
    ///   do not touch it.
    public init(estatesDirectory: URL) {
        self.kit = GeniusLocusKit()
        self.estatesDirectory = estatesDirectory
    }

    // MARK: - Provision

    /// Provision a new estate from a validated admin request.
    ///
    /// Validates the request, constructs the backing `Storage` for the chosen
    /// backend, maps the request to `EstateProvisionParams`, and calls GLK's
    /// `provision(...)` — the substrate creation path that wires the manifest,
    /// write-gate, audit, clock, and the sub-stores the kind requires. On
    /// success the estate is mounted and recorded in the provenance map.
    ///
    /// - Parameter request: The provisioning request (wizard / control body).
    /// - Returns: An `EstateAdminResult` with the new estate's UUID and mount state.
    /// - Throws: `AdminError.invalidRequest` for a malformed request; a
    ///   `StorageError`/`GeniusLocusKitError` if backend construction or GLK
    ///   provisioning fails.
    public func provision(_ request: EstateAdminRequest) async throws -> EstateAdminResult {
        // Validate enums and scalar fields BEFORE creating any storage so a bad
        // request never leaves an orphan store on disk.
        guard !request.estateName.isEmpty else {
            throw AdminError.invalidRequest(detail: "estateName must not be empty")
        }
        guard !request.owner.isEmpty else {
            throw AdminError.invalidRequest(detail: "owner must not be empty")
        }
        guard let kind = EstateKind(rawValue: request.kind) else {
            throw AdminError.invalidRequest(detail: "unknown kind '\(request.kind)'")
        }
        guard let backend = EstateBackendKind(rawValue: request.backend) else {
            throw AdminError.invalidRequest(detail: "unknown backend '\(request.backend)'")
        }
        guard let syncMode = SyncMode(rawValue: request.syncMode) else {
            throw AdminError.invalidRequest(detail: "unknown syncMode '\(request.syncMode)'")
        }
        guard request.zoomWindowLow <= request.zoomWindowHigh else {
            throw AdminError.invalidRequest(
                detail: "zoomWindowLow (\(request.zoomWindowLow)) must be <= zoomWindowHigh (\(request.zoomWindowHigh))"
            )
        }

        let storage = try makeStorage(backend: backend)
        let owner = OwnerCredentials(ownerIdentifier: request.owner)
        let params = EstateProvisionParams(
            estateName: request.estateName,
            kind: kind,
            zoomWindowLow: request.zoomWindowLow,
            zoomWindowHigh: request.zoomWindowHigh,
            frameworkProfile: request.frameworkProfile,
            syncMode: syncMode
        )

        // GLK provision is the substrate creation path (concepts §1.8): create →
        // open → wire sub-stores, atomic with rollback-on-failure inside the kit.
        let handle = try await kit.provision(storage: storage, owner: owner, params: params)

        let uuid = handle.estateUUID.uuidString
        hosted[uuid] = Provenance(handle: handle, storage: storage, backend: backend, kind: kind)
        let state = await kit.mountState(for: handle) ?? .mounted
        logger.info("provisioned \(kind.rawValue, privacy: .public) estate \(uuid, privacy: .public) (\(backend.rawValue, privacy: .public))")

        return EstateAdminResult(
            ok: true,
            detail: "provisioned \(kind.rawValue) estate '\(request.estateName)'",
            estateUUID: uuid,
            mountState: state.rawValue
        )
    }

    // MARK: - Lifecycle

    /// Quiesce a hosted estate — stop accepting new work, keep it mounted.
    ///
    /// - Parameter request: The lifecycle request naming the target estate UUID.
    /// - Returns: The result with the post-verb mount state (`quiesced`).
    /// - Throws: `AdminError.unknownEstate` if the UUID is not hosted; a
    ///   `GeniusLocusKitError` if the GLK quiesce fails.
    public func quiesce(_ request: EstateLifecycleRequest) async throws -> EstateAdminResult {
        let prov = try provenance(for: request.estateUUID)
        try await kit.quiesce(prov.handle)
        let state = await kit.mountState(for: prov.handle) ?? .quiesced
        logger.info("quiesced estate \(request.estateUUID, privacy: .public)")
        return EstateAdminResult(ok: true, detail: "quiesced", estateUUID: request.estateUUID, mountState: state.rawValue)
    }

    /// Drain a hosted estate — wait for in-flight work, then quiesce.
    ///
    /// - Parameter request: The lifecycle request naming the target estate UUID.
    /// - Returns: The result with the post-verb mount state (`quiesced`).
    /// - Throws: `AdminError.unknownEstate`; a `GeniusLocusKitError` on failure.
    public func drain(_ request: EstateLifecycleRequest) async throws -> EstateAdminResult {
        let prov = try provenance(for: request.estateUUID)
        try await kit.drain(prov.handle)
        let state = await kit.mountState(for: prov.handle) ?? .quiesced
        logger.info("drained estate \(request.estateUUID, privacy: .public)")
        return EstateAdminResult(ok: true, detail: "drained", estateUUID: request.estateUUID, mountState: state.rawValue)
    }

    /// Destroy a hosted estate — DOUBLE-CONFIRMED, then torn down through GLK.
    ///
    /// The operator must re-type the estate's exact name in `request.confirmName`
    /// (concepts §1.8). A mismatch refuses the destroy with `AdminError.destroyConfirmMismatch`
    /// — no data is touched. On a match, GLK `destroy(...)` closes the estate and
    /// tears down every sub-store the kind wired, then the estate is dropped from
    /// the provenance map (so its handle and storage are released).
    ///
    /// - Parameter request: The lifecycle request (UUID + confirmName).
    /// - Returns: The result; mount state is nil (the estate no longer exists).
    /// - Throws: `AdminError.unknownEstate`, `AdminError.destroyConfirmMismatch`,
    ///   or a `GeniusLocusKitError` if the GLK teardown fails.
    public func destroy(_ request: EstateLifecycleRequest) async throws -> EstateAdminResult {
        let prov = try provenance(for: request.estateUUID)
        // Double-confirm: the re-typed name must equal the estate's stored name.
        guard request.confirmName == prov.handle.estateName else {
            throw AdminError.destroyConfirmMismatch
        }
        try await kit.destroy(storage: prov.storage, handle: prov.handle)
        hosted[request.estateUUID] = nil
        logger.info("destroyed estate \(request.estateUUID, privacy: .public)")
        return EstateAdminResult(ok: true, detail: "destroyed '\(prov.handle.estateName)'", estateUUID: request.estateUUID, mountState: nil)
    }

    // MARK: - Read reflection

    /// Snapshot the hosted estates for the read plane's Estates view.
    ///
    /// One entry per hosted estate with its identity, kind, backend, and current
    /// GLK mount state. Sorted by UUID so the wire output is byte-stable.
    ///
    /// - Returns: The admin read payload (empty when nothing is hosted).
    public func payload() async -> EstateAdminPayload {
        var entries: [EstateAdminEntry] = []
        for (uuid, prov) in hosted {
            let state = await kit.mountState(for: prov.handle) ?? .mounted
            entries.append(EstateAdminEntry(
                estateUUID: uuid,
                estateName: prov.handle.estateName,
                kind: prov.kind.rawValue,
                backend: prov.backend.rawValue,
                mountState: state.rawValue
            ))
        }
        entries.sort { $0.estateUUID < $1.estateUUID }
        return EstateAdminPayload(hosted: entries)
    }

    // MARK: - Internals

    /// Resolve a hosted estate's provenance by UUID string, or throw.
    private func provenance(for uuid: String) throws -> Provenance {
        guard let prov = hosted[uuid] else { throw AdminError.unknownEstate(uuid: uuid) }
        return prov
    }

    /// Construct the backing `Storage` for the requested backend.
    ///
    /// - SQLite: a file at `<estatesDirectory>/<uuid>.sqlite`. The directory is
    ///   created on demand. A fresh UUID names the file so two provisions never
    ///   collide on disk.
    /// - InMemory: a volatile store; nothing touches the filesystem.
    private func makeStorage(backend: EstateBackendKind) throws -> any Storage {
        let estateID = UUID()
        switch backend {
        case .inMemory:
            return InMemoryStorage(configuration: EstateConfiguration(
                estateID: estateID,
                backend: .inMemory
            ))
        case .sqlite:
            try FileManager.default.createDirectory(
                at: estatesDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let url = estatesDirectory.appendingPathComponent("\(estateID.uuidString).sqlite", isDirectory: false)
            return try SQLiteStorage(configuration: EstateConfiguration(
                estateID: estateID,
                backend: .sqlite(url: url)
            ))
        }
    }
}
