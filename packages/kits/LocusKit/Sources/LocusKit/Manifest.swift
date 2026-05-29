import Foundation

/// Typed key constants for the v1 manifest key-value table.
/// Raw value is the exact string stored in `manifest.key`.
/// Per GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md § 5.9.
public enum ManifestKey: String, Sendable, CaseIterable {

    // MARK: Required keys (18)
    case manifestVersion         = "manifest_version"
    case schemaVersion           = "schema_version"
    case estateUUID              = "estate_uuid"
    case estateName              = "estate_name"
    case ownerIdentifier         = "owner_identifier"
    case latticeCitation         = "lattice_citation"
    case frameworkProfile        = "framework_profile"
    case frameworkProfileDefinition = "framework_profile_definition"
    case zoomWindowLow           = "zoom_window_low"
    case zoomWindowHigh          = "zoom_window_high"
    case accessPosture           = "access_posture"
    case provenanceDefaults      = "provenance_defaults"
    case activeStorageMode       = "active_storage_mode"
    case tablesPresent           = "tables_present"
    case createdAt               = "created_at"
    case lastModified            = "last_modified"
    case bitmapLayoutVersion     = "bitmap_layout_version"
    case provenanceBitmapVersion = "provenance_bitmap_version"

    // MARK: Optional keys (7)
    case federationGroupID           = "federation_group_id"
    case miningPatternsHash          = "mining_patterns_hash"
    case tinyModelID                 = "tiny_model_id"
    case tinyModelTrainingCorpusSize = "tiny_model_training_corpus_size"
    case operationalBitmapLayouts    = "operational_bitmap_layouts"

    /// The estate's Ed25519 (Curve25519 signing) public key, base64 of
    /// the raw 32-byte representation. Generated on first open (see
    /// `Estate.open`) and used as the estate's federation identity:
    /// grants are signed by the matching private key so a paired estate
    /// can verify provenance. Per DECISION_SYNCKIT_DESIGN_2026-05-19 §8.
    case ed25519PublicKey            = "ed25519_public_key"

    /// The estate's Ed25519 private key. Base64 of the raw 32-byte
    /// representation.
    ///
    /// At-rest protection note: at the LocusKit layer this stores the
    /// raw private-key bytes — there is no Keychain/Secure Enclave in a
    /// cross-platform, zero-dependency kit. Hardware wrapping (Secure
    /// Enclave / TPM) is a follow-on; at-rest confidentiality of the
    /// manifest is the storage-encryption tier's responsibility per the
    /// encryption-modes architecture and the ENC-01 `keys`-registry
    /// scope note (LocusKitSchema). The "Wrapped" name marks the seam
    /// where that hardware wrapping lands; today the wrap is the
    /// identity transform.
    case ed25519PrivateKeyWrapped    = "ed25519_private_key_wrapped"

    /// The 18 required keys that every conforming estate must populate.
    public static let required: [ManifestKey] = [
        .manifestVersion, .schemaVersion, .estateUUID, .estateName,
        .ownerIdentifier, .latticeCitation, .frameworkProfile,
        .frameworkProfileDefinition, .zoomWindowLow, .zoomWindowHigh,
        .accessPosture, .provenanceDefaults, .activeStorageMode,
        .tablesPresent, .createdAt, .lastModified,
        .bitmapLayoutVersion, .provenanceBitmapVersion
    ]

    /// The 7 optional keys. Absent means "not configured".
    public static let optional: [ManifestKey] = [
        .federationGroupID, .miningPatternsHash, .tinyModelID,
        .tinyModelTrainingCorpusSize, .operationalBitmapLayouts,
        .ed25519PublicKey, .ed25519PrivateKeyWrapped
    ]
}

/// A typed, read-only snapshot of the estate manifest.
/// Obtained via `DrawerStore.readManifest()`.
/// Consumed by `Estate.manifest` in LOCI_V035_13.
/// Per spec § 5.9 and § 7.8.1.
public struct ManifestValues: Sendable {

    // MARK: Required fields

    public let manifestVersion: String
    public let schemaVersion: String
    public let estateUUID: String
    public let estateName: String
    public let ownerIdentifier: String
    public let latticeCitation: String
    public let frameworkProfile: String
    public let frameworkProfileDefinition: String  // raw JSON string
    public let zoomWindowLow: Int
    public let zoomWindowHigh: Int
    public let accessPosture: Int64        // bitmap
    public let provenanceDefaults: Int64   // bitmap
    public let activeStorageMode: Int64    // bitmap
    public let tablesPresent: String       // comma-separated
    public let createdAt: Date
    public let lastModified: Date
    public let bitmapLayoutVersion: String
    public let provenanceBitmapVersion: String

    // MARK: Optional fields (nil = absent / not configured)

    public let federationGroupID: String?
    public let miningPatternsHash: String?
    public let tinyModelID: String?
    public let tinyModelTrainingCorpusSize: Int?
    public let operationalBitmapLayouts: String?   // raw JSON string or nil

    /// The estate's Ed25519 public key as raw 32-byte data (decoded
    /// from the manifest's base64 TEXT), or nil on an estate opened
    /// before the identity keypair was generated.
    public let ed25519PublicKey: Data?

    /// The estate's Ed25519 private key as raw 32-byte data. See
    /// `ManifestKey.ed25519PrivateKeyWrapped` for the at-rest note.
    public let ed25519PrivateKeyWrapped: Data?

    /// Memberwise initializer. The two Ed25519 fields default to nil so
    /// callers that seed a manifest without an identity keypair (e.g.
    /// `Estate.create` seeding tests) compile unchanged; the keypair is
    /// generated lazily at open.
    public init(
        manifestVersion: String,
        schemaVersion: String,
        estateUUID: String,
        estateName: String,
        ownerIdentifier: String,
        latticeCitation: String,
        frameworkProfile: String,
        frameworkProfileDefinition: String,
        zoomWindowLow: Int,
        zoomWindowHigh: Int,
        accessPosture: Int64,
        provenanceDefaults: Int64,
        activeStorageMode: Int64,
        tablesPresent: String,
        createdAt: Date,
        lastModified: Date,
        bitmapLayoutVersion: String,
        provenanceBitmapVersion: String,
        federationGroupID: String?,
        miningPatternsHash: String?,
        tinyModelID: String?,
        tinyModelTrainingCorpusSize: Int?,
        operationalBitmapLayouts: String?,
        ed25519PublicKey: Data? = nil,
        ed25519PrivateKeyWrapped: Data? = nil
    ) {
        self.manifestVersion = manifestVersion
        self.schemaVersion = schemaVersion
        self.estateUUID = estateUUID
        self.estateName = estateName
        self.ownerIdentifier = ownerIdentifier
        self.latticeCitation = latticeCitation
        self.frameworkProfile = frameworkProfile
        self.frameworkProfileDefinition = frameworkProfileDefinition
        self.zoomWindowLow = zoomWindowLow
        self.zoomWindowHigh = zoomWindowHigh
        self.accessPosture = accessPosture
        self.provenanceDefaults = provenanceDefaults
        self.activeStorageMode = activeStorageMode
        self.tablesPresent = tablesPresent
        self.createdAt = createdAt
        self.lastModified = lastModified
        self.bitmapLayoutVersion = bitmapLayoutVersion
        self.provenanceBitmapVersion = provenanceBitmapVersion
        self.federationGroupID = federationGroupID
        self.miningPatternsHash = miningPatternsHash
        self.tinyModelID = tinyModelID
        self.tinyModelTrainingCorpusSize = tinyModelTrainingCorpusSize
        self.operationalBitmapLayouts = operationalBitmapLayouts
        self.ed25519PublicKey = ed25519PublicKey
        self.ed25519PrivateKeyWrapped = ed25519PrivateKeyWrapped
    }
}
