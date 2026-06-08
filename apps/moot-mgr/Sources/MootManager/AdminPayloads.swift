// AdminPayloads.swift
//
// Codable wire shapes for the moot-mgr ADMIN PLANE (P6, MANAGER_1.0_PLAN.md §4 P6).
//
// ========================== ADMIN = PRIVILEGED WRITES =======================
// The admin plane PROVISIONS and tears down estates — it creates real MOOTs
// through the GLK substrate and destroys their backing stores. These are the
// most privileged operations the resident host performs. EVERY admin verb is
// reached ONLY through the gated control surface (HTTPReadAPI.applyControl),
// which both the UDS channel (0600, owner-only) and the token+Origin HTTP
// control path dispatch through. There is NO admin path on the unauthenticated
// read surface — the GET routes serve metadata only and never touch this engine.
//
// The request bodies below are the JSON a privileged client sends after the
// gate has admitted it; the result/payload shapes are what flows back. Like the
// read payloads, everything here is metadata only (names, kinds, enums, counts,
// ISO-8601 timestamps) — no rung/memory content ever crosses an admin response.
// ===========================================================================

import Foundation
import GeniusLocusKit

// MARK: - EstateBackendKind

/// The storage backend an admin client requests for a new estate.
///
/// Maps to a PersistenceKit `BackendConfiguration` the admin engine constructs.
/// `inMemory` is volatile — the GUI flags it loudly (GUI SPEC §4.2) — and is the
/// safe default for tests and scratch estates. `sqlite` is the durable default
/// for real estates (MANAGER_1.0_PLAN.md §5 item 2). PostgreSQL is intentionally
/// absent from this prototype cut: it needs Keychain-held credentials (concepts
/// §1.6), which is a separate P6 item, so the admin engine does not offer it yet.
public enum EstateBackendKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// Volatile in-memory backend — data is lost on process exit.
    case inMemory = "InMemory"
    /// Durable SQLite file backend.
    case sqlite = "SQLite"
}

// MARK: - EstateAdminRequest (POST /api/control/estate/provision)

/// The provisioning request an admin client sends to create a new estate.
///
/// Collected by the provisioning wizard (GUI SPEC §5.3 / concepts §1.8) and sent
/// as the JSON body of the gated `/api/control/estate/provision` verb. The fields
/// mirror `EstateProvisionParams` (the GLK creation params) plus the backend
/// choice and the owner identifier the host stamps on the new MOOT's manifest.
///
/// The admin engine validates these before touching storage; an invalid request
/// (empty name, low > high zoom, unknown kind) is rejected with `ok:false` and
/// never provisions a partial estate.
public struct EstateAdminRequest: Codable, Sendable, Equatable {
    /// Human-readable estate name (non-empty). Written to the manifest.
    public let estateName: String
    /// Composition kind: "GLK" | "CorpusOnly" | "LocusOnly" (EstateKind raw value).
    public let kind: String
    /// Storage backend: "InMemory" | "SQLite" (EstateBackendKind raw value).
    public let backend: String
    /// Zoom-window lower bound (UDC lattice). Must be <= zoomWindowHigh.
    public let zoomWindowLow: Int
    /// Zoom-window upper bound.
    public let zoomWindowHigh: Int
    /// Framework profile name (unqualified; GLK adds the kind prefix on write).
    public let frameworkProfile: String
    /// Sync mode: "None" | "CloudKit" | "Federation" (SyncMode raw value).
    public let syncMode: String
    /// Owner identifier stamped on the new estate's manifest (non-empty).
    public let owner: String

    public init(
        estateName: String,
        kind: String,
        backend: String,
        zoomWindowLow: Int,
        zoomWindowHigh: Int,
        frameworkProfile: String,
        syncMode: String,
        owner: String
    ) {
        self.estateName = estateName
        self.kind = kind
        self.backend = backend
        self.zoomWindowLow = zoomWindowLow
        self.zoomWindowHigh = zoomWindowHigh
        self.frameworkProfile = frameworkProfile
        self.syncMode = syncMode
        self.owner = owner
    }
}

// MARK: - EstateLifecycleRequest (quiesce / drain / destroy)

/// The body of a lifecycle verb (`/api/control/estate/quiesce|drain|destroy`):
/// the estate UUID the action targets. `destroy` additionally requires the
/// confirm-name to match the estate's name — the double-confirm guard (concepts
/// §1.8: "destroying a MOOT … type-the-estate-name-to-confirm").
public struct EstateLifecycleRequest: Codable, Sendable, Equatable {
    /// Target estate UUID (string form of `EstateHandle.estateUUID`).
    public let estateUUID: String
    /// For `destroy` only: the estate name the operator re-typed to confirm.
    /// Must equal the estate's stored name or the destroy is refused. Ignored
    /// by quiesce/drain. Optional so quiesce/drain bodies need not carry it.
    public let confirmName: String?

    public init(estateUUID: String, confirmName: String? = nil) {
        self.estateUUID = estateUUID
        self.confirmName = confirmName
    }
}

// MARK: - EstateAdminResult (verb response)

/// The result of an admin verb. Carries the gate-style `ok`/`detail` plus, on a
/// successful provision, the new estate's identity so the wizard can show it and
/// the management view can pick it up.
public struct EstateAdminResult: Codable, Sendable, Equatable {
    /// Whether the verb succeeded.
    public let ok: Bool
    /// Human-readable detail ("provisioned GLK estate …", "quiesced", an error).
    public let detail: String
    /// The affected estate's UUID (string), when known. nil on a request that
    /// failed before an estate could be identified (e.g. a malformed body).
    public let estateUUID: String?
    /// The affected estate's current mount state after the verb, when known.
    public let mountState: String?

    public init(ok: Bool, detail: String, estateUUID: String? = nil, mountState: String? = nil) {
        self.ok = ok
        self.detail = detail
        self.estateUUID = estateUUID
        self.mountState = mountState
    }
}

// MARK: - EstateAdminEntry / EstateAdminPayload (admin read reflection)

/// One admin-hosted estate as reflected back into the read plane: identity, kind,
/// backend, and current mount state. The Estates view (GUI SPEC §4.2) renders the
/// kind/backend badges and the mount-state badge from this. Metadata only.
public struct EstateAdminEntry: Codable, Sendable, Equatable {
    /// Estate UUID (string).
    public let estateUUID: String
    /// Display name from the manifest.
    public let estateName: String
    /// Composition kind raw value ("GLK" | "CorpusOnly" | "LocusOnly").
    public let kind: String
    /// Backend raw value ("InMemory" | "SQLite"). InMemory is flagged volatile
    /// by the renderer.
    public let backend: String
    /// Current mount-state raw value ("mounted" | "quiesced" | "draining").
    public let mountState: String

    public init(estateUUID: String, estateName: String, kind: String, backend: String, mountState: String) {
        self.estateUUID = estateUUID
        self.estateName = estateName
        self.kind = kind
        self.backend = backend
        self.mountState = mountState
    }
}

/// The admin section merged into the `GET /api/estates` payload: the estates the
/// resident host itself provisions and mounts (distinct from the externally
/// self-reporting estates seen only in the event stream). Empty when the host
/// has no admin engine wired or has provisioned nothing.
public struct EstateAdminPayload: Codable, Sendable, Equatable {
    /// Admin-hosted estates, sorted by UUID for byte-stable output.
    public let hosted: [EstateAdminEntry]

    public init(hosted: [EstateAdminEntry]) {
        self.hosted = hosted
    }
}
