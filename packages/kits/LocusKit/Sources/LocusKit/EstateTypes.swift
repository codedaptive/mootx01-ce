import Foundation
import SubstrateTypes

// MARK: - RowID

/// Stable row identifier — the string id stored on every noun row
/// (drawer, tunnel, kg fact, diary entry). Opaque to callers; Estate
/// verbs accept and return `RowID` values rather than raw `String` so
/// the type signature documents intent.
///
/// Declared as a typealias rather than a wrapping struct because every
/// noun's row id column is already `TEXT PRIMARY KEY` and round-trips
/// through SQLite as `String`; a wrapping type would require a String
/// dance on every bind/column without semantic gain.
public typealias RowID = String

// MARK: - FrameFilteredDrawers

/// Result of `Estate.getDrawers(ids:matchingFrame:hydrationLevel:)`: the
/// frame-admissible drawers plus the set of ids whose rows physically loaded.
///
/// `loadedIDs` is reported independently of the frame filter so a caller can
/// gate a drop on load success: an id that loaded (`loadedIDs.contains(id)`)
/// but is absent from `admissible` failed the frame's state/structured/content
/// filter and may be dropped; an id absent from `loadedIDs` did not load (a
/// transient/partial read) and must be DEGRADED gracefully, never dropped.
public struct FrameFilteredDrawers: Sendable {
    /// Drawers from the requested ids that passed the frame's filter chain
    /// (tombstone exclusion always enforced). Ordered per the frame's ordering.
    public let admissible: [Drawer]
    /// Every id whose row was returned by storage, regardless of frame filter.
    public let loadedIDs: Set<String>

    public init(admissible: [Drawer], loadedIDs: Set<String>) {
        self.admissible = admissible
        self.loadedIDs = loadedIDs
    }
}

// MARK: - OwnerCredentials

/// Credentials identifying the owner of an estate. The substrate layer
/// validates only that `ownerIdentifier` is non-empty on open/create;
/// full credential validation (iCloud account matching, key escrow,
/// etc.) is out of scope for LocusKit and lives in ARIA_MCP's outer
/// envelope.
///
/// Per spec § 7.8.1: `Estate.open(path:owner:)` takes an
/// `OwnerCredentials` so the kit can stamp the manifest's
/// `owner_identifier` row at create time.
public struct OwnerCredentials: Sendable, Equatable {
    /// The owner's identifier — typically an iCloud account string.
    /// Must be non-empty; Estate.open and Estate.create throw
    /// `EstateError.emptyOwnerIdentifier` if it is empty.
    public let ownerIdentifier: String

    public init(ownerIdentifier: String) {
        self.ownerIdentifier = ownerIdentifier
    }
}

// MARK: - LatticeAnchor

/// The lattice anchor for a drawer — a UDC classification code plus
/// optional Wikidata and facet enrichment. Every drawer carries one
/// per spec I-5 and § 5.8.
///
/// The four fields are already stored on `Drawer` directly. This type
/// promotes them into a single named value so `CaptureFrame` can pass
/// an anchor as a unit rather than as four parallel parameters.
///
/// `udcCode` is required at storage; the substrate enforces TEXT NOT
/// NULL DEFAULT ''. Non-emptiness at capture time is enforced by the
/// verb layer in mission 14, not here. Optional fields are populated
/// by the enrichment daemon when absent; callers may supply them at
/// capture time.
public struct LatticeAnchor: Sendable, Equatable, Codable {
    /// Primary UDC classification code (e.g. "547" for organic chemistry).
    public let udcCode: String
    /// Additional UDC codes for secondary topics, comma-separated.
    public let udcFacets: String?
    /// Wikidata Q-ID for the primary concept (e.g. "Q11351").
    public let wikidataQID: String?
    /// Additional Wikidata Q-IDs, comma-separated.
    public let wikidataQidsSecondary: String?

    public init(
        udcCode: String,
        udcFacets: String? = nil,
        wikidataQID: String? = nil,
        wikidataQidsSecondary: String? = nil
    ) {
        self.udcCode = udcCode
        self.udcFacets = udcFacets
        self.wikidataQID = wikidataQID
        self.wikidataQidsSecondary = wikidataQidsSecondary
    }

    /// Convenience initialiser for a bare UDC code with no enrichment —
    /// the common shape for content captured before the enrichment
    /// daemon has run.
    public static func udc(_ code: String) -> LatticeAnchor {
        LatticeAnchor(udcCode: code)
    }
}

// MARK: - EstateError

/// Errors thrown by `Estate` lifecycle methods. Distinct from
/// `LocusKitError` (substrate-layer SQLite and migration faults) —
/// `EstateError` covers the estate-level contract per spec § 8.1
/// (`ManifestMismatch`, `SubstrateUnavailable`).
///
/// `emptyOwnerIdentifier` is the third case — neither
/// `ManifestMismatch` nor `SubstrateUnavailable` fits an empty
/// credential, so it is broken out for caller clarity and
/// surfaced before any SQLite call is made.
public enum EstateError: Error, Sendable, Equatable {
    /// The backing SQLite store could not be opened or created.
    /// Includes the underlying diagnostic message so callers can log
    /// the substrate failure without re-wrapping LocusKitError.
    case substrateUnavailable(String)

    /// A manifest key does not match the expected value. `key` names
    /// the manifest key (e.g. "bitmap_layout_version"); `found` and
    /// `expected` are the string values compared. Per spec § 8.1:
    /// "ManifestMismatch — operation requires a manifest value not
    /// present (or incompatible)."
    case manifestMismatch(key: String, found: String, expected: String)

    /// `OwnerCredentials.ownerIdentifier` was empty. Raised before
    /// any database call is made so callers receive a structurally
    /// distinct error rather than a generic substrate failure.
    case emptyOwnerIdentifier

    /// A Keychain `SecItem` call returned a non-success status code.
    /// Thrown by `KeychainEstateIdentityKeyStore` when `SecItemAdd`,
    /// `SecItemUpdate`, `SecItemCopyMatching`, or `SecItemDelete` fail.
    /// `status` is the raw `OSStatus` value (Int32) from the failing call,
    /// readable as a human-readable string via `SecCopyErrorMessageString`.
    case keychainError(status: Int32)

    /// `FileEstateIdentityKeyStore.init(appSupportSubdirectory:)` (DEBUG
    /// builds only) received a subdirectory name that is empty, contains a
    /// path separator, or is a `.`/`..` traversal segment. The associated
    /// string is the rejected value, verbatim, for caller diagnostics.
    ///
    /// Rejected at construction, before any `FileManager` call, because
    /// the subdirectory is joined onto the Application Support root via
    /// `URL.appendingPathComponent` — a value like `".."` or
    /// `"../../Library"` resolves at the filesystem layer and would let a
    /// caller-supplied string steer key-material reads/writes outside
    /// Application Support entirely. The original fulcrum-local
    /// implementation this type was upstreamed from made this
    /// structurally unreachable by hardcoding the subdirectory literal;
    /// generalizing it to a caller-supplied parameter for multi-consumer
    /// use (see `FileEstateIdentityKeyStore`'s doc comment) reopened that
    /// path unless validated here.
    case invalidIdentityKeyStoreSubdirectory(String)
}
