import Foundation

// EstateProvision.swift — Types for GLK composition-aware estate provisioning.
//
// The provision path is the GLK-owned creation route introduced by the Manager
// P6 enabler (GLK_PROVISION_001). Where `open(storage:owner:)` admits an
// already-created estate, `provision(...)` creates and opens a new estate,
// wires all sub-stores the chosen kind requires, and registers the estate with
// the kit in one atomic call.
//
// Three concerns live here:
//   1. EstateKind        — which sub-stores the estate requires
//   2. EstateProvisionParams — the creation parameters the GUI collects
//   3. EstateMountState  — the per-estate mount lifecycle state

// MARK: - EstateKind

/// The composition kind of a provisioned estate.
///
/// Kind governs which sub-stores are provisioned and wired when an estate
/// is created through `GeniusLocusKit.provision(...)`. The kind is written
/// to the manifest's `framework_profile` prefix so it survives process
/// restarts and can be read back by `GeniusLocusKit.open` to reconstruct
/// the wiring without the caller re-specifying it.
///
/// Per §1.8 of ARIA_MCP_DESKTOP_APP_CONCEPTS.md:
///   - `.glk`         — full composition (LocusKit + VectorKit + CorpusKit)
///   - `.corpusOnly`  — LocusKit core + CorpusKit (no standalone VectorStore)
///   - `.locusOnly`   — LocusKit only (no Corpus, no VectorStore)
///
/// The kind determines the minimum viable storage the caller must supply.
/// A `.locusOnly` estate requires only one storage backend; a `.glk` estate
/// may share one backend (vectors + corpus in the same SQLite file via
/// multi-schema `migrate`) or use separate backends — the caller decides.
public enum EstateKind: String, Sendable, Equatable, CaseIterable {

    /// Full composition: LocusKit + VectorKit + CorpusKit.
    ///
    /// The write-gate, audit trail, vector index, and BM25 recall are all
    /// wired at provision time. The estate supports all nine ARIA verbs and
    /// the hybrid recall lanes.
    case glk = "GLK"

    /// LocusKit core + CorpusKit. No standalone VectorStore registration.
    ///
    /// Corpus is wired (BM25 + vector inside Corpus) but no VectorStore is
    /// separately registered for vector-only recall. Hybrid and CorpusOnly
    /// lanes are available; the standalone vector lane (registered
    /// VectorStore) is absent.
    case corpusOnly = "CorpusOnly"

    /// LocusKit only.
    ///
    /// No Corpus, no VectorStore registered. All nine verbs are available;
    /// recall is bitmap-filter only (locusOnly lane). Lightweight estates
    /// for structured-memory-only use cases.
    case locusOnly = "LocusOnly"
}

// MARK: - EstateLifetime

/// Declares how long the estate's identity and encryption-key material should
/// live.
///
/// ## .durable (default)
///
/// The identity key (Ed25519 signing key) is written to the Apple Keychain and
/// survives process restarts. The whole-file database key (SQLCipher) is minted
/// by `EstateKeyProvider` and stored in the Keychain keyed to the estate file
/// path. This is the correct posture for user-owned estates that must survive
/// device restarts.
///
/// ## .ephemeral
///
/// The estate uses durable storage mechanics — a real SQLite file on disk, full
/// schema migration, SQLite persistence semantics — but with THROWAWAY identity
/// material. The identity key store is in-memory (`InMemoryEstateIdentityKeyStore`):
/// the Ed25519 signing key is generated at open time, lives only in process
/// memory, and leaves zero Keychain residue at process exit.
///
/// The whole-file database key, when used with an `.ephemeral` estate, must be
/// supplied by the caller WITHOUT minting a Keychain item — either as an
/// in-memory random key (for tests that care about SQLCipher semantics), or by
/// using `.plaintext` encryption (for tests that only care about persistence
/// without encryption overhead).
///
/// **Use case:** automated test loops and agent-driven test harnesses that need
/// to exercise SQLite persistence semantics without accumulating Keychain items.
/// Provision N ephemeral estates, run tests, tear down — zero keychain residue
/// by construction. This is the fix for the production incident where ~200 k
/// test estates left one identity-key Keychain item each.
///
/// **Security note:** ephemeral-with-encryption works — an ephemeral estate can
/// still use a SQLCipher-encrypted file. The key simply lives in-memory and is
/// not recoverable after the process exits (the file becomes unreadable, which
/// is the correct posture for a throwaway test estate).
///
/// ## Declaration over inference
///
/// The choice of `.ephemeral` vs `.durable` is made explicitly by the caller at
/// provision time. GLK never infers ephemeral status from the storage backend or
/// from heuristics — declaration is the only mechanism.
public enum EstateLifetime: String, Sendable, Equatable, CaseIterable {
    /// Identity and db-key material are durable (Keychain-backed). Default.
    /// Correct for all user-owned production estates.
    case durable = "durable"
    /// Identity material lives only in process memory. SQLite storage mechanics
    /// are fully operational; the key store is in-memory. No Keychain writes at
    /// any point during the estate's life.
    case ephemeral = "ephemeral"
}

// MARK: - EstateProvisionParams

/// Parameters that fully describe a new estate being provisioned through GLK.
///
/// Collected by the moot-mgr admin plane GUI (§5.3, ARIA_MCP_MANAGEMENT_GUI_SPEC)
/// and passed verbatim to `GeniusLocusKit.provision(...)`. The caller owns
/// backend construction (storage instances); GLK owns manifest population and
/// sub-store wiring.
///
/// All fields correspond directly to existing manifest keys in `ManifestKey`
/// and `ManifestValues` — no new manifest schema is introduced. The `kind`
/// field maps to a prefix on `frameworkProfile` so it round-trips through the
/// manifest on re-open.
public struct EstateProvisionParams: Sendable {

    /// The human-readable name for the new estate. Written to the manifest's
    /// `estate_name` row. Non-empty; the caller must validate before passing.
    public let estateName: String

    /// Composition kind. Determines which sub-stores GLK provisions and wires.
    public let kind: EstateKind

    /// Zoom-window lower bound (UDC lattice address). Written to
    /// `zoom_window_low`. Must be <= `zoomWindowHigh`.
    public let zoomWindowLow: Int

    /// Zoom-window upper bound. Written to `zoom_window_high`.
    public let zoomWindowHigh: Int

    /// Framework profile name (taxonomy Layer 3: e.g. "PersonalLifeMgmt",
    /// "KnowledgeWork", "CreativeWork"). Written to `framework_profile` as
    /// a kind-prefixed composite so the profile and kind round-trip together.
    ///
    /// The stored value is `"<kind.rawValue>:<frameworkProfile>"`, e.g.
    /// `"GLK:KnowledgeWork"`. The prefix encodes kind so re-opens can
    /// reconstruct the wiring without a separate manifest key.
    public let frameworkProfile: String

    /// Sync mode for ConvergenceKit. Recorded in manifest's `active_storage_mode`
    /// bitmap field via the existing mode encoding.
    public let syncMode: SyncMode

    /// Key-material lifetime for this estate. Defaults to `.durable` so all
    /// existing callers are unchanged. Pass `.ephemeral` for test loops and
    /// agent-driven test harnesses that need SQLite persistence semantics with
    /// zero Keychain residue (see `EstateLifetime` for the full contract).
    public let lifetime: EstateLifetime

    /// Memberwise initialiser.
    ///
    /// - Parameters:
    ///   - estateName: Non-empty display name.
    ///   - kind: Composition kind (`.glk`, `.corpusOnly`, `.locusOnly`).
    ///   - zoomWindowLow: UDC lattice lower bound. Must be <= zoomWindowHigh.
    ///   - zoomWindowHigh: UDC lattice upper bound.
    ///   - frameworkProfile: Framework profile name (unqualified; GLK adds the kind prefix when writing).
    ///   - syncMode: ConvergenceKit sync mode.
    ///   - lifetime: Key-material lifetime — `.durable` (default, Keychain-backed identity)
    ///     or `.ephemeral` (in-memory identity, no Keychain writes). See `EstateLifetime`.
    public init(
        estateName: String,
        kind: EstateKind,
        zoomWindowLow: Int,
        zoomWindowHigh: Int,
        frameworkProfile: String,
        syncMode: SyncMode,
        lifetime: EstateLifetime = .durable
    ) {
        self.estateName = estateName
        self.kind = kind
        self.zoomWindowLow = zoomWindowLow
        self.zoomWindowHigh = zoomWindowHigh
        self.frameworkProfile = frameworkProfile
        self.syncMode = syncMode
        self.lifetime = lifetime
    }
}

// MARK: - SyncMode

/// Sync mode for a provisioned estate.
///
/// Maps to the ConvergenceKit backend selection. Mirrors the three options
/// from §1.8 of ARIA_MCP_DESKTOP_APP_CONCEPTS.md.
///
/// The mode is recorded in the manifest for informational purposes. Actual
/// sync backend construction remains the caller's responsibility via
/// ConvergenceKit — GLK records the declared intent, not the live wiring.
public enum SyncMode: String, Sendable, Equatable, CaseIterable {
    /// No sync. Local-only estate.
    case none = "None"
    /// CloudKit sync.
    case cloudKit = "CloudKit"
    /// Peer-to-peer federation via ConvergenceKit.
    case federation = "Federation"
}

// MARK: - EstateMountState

/// The lifecycle state of a provisioned estate as visible through GLK.
///
/// The admin plane reads this state to drive the Estates view in the
/// moot-mgr GUI (§5.3). GLK tracks this state per handle in the
/// `mountStates` registry on the actor.
///
/// State transitions:
///   mounted  ─── quiesce() ──→  quiesced
///   quiesced ─── drain()   ──→  draining
///   draining  (auto-transitions to quiesced once in-flight work is done)
///   quiesced ─── close()   ──→  unmounted  (registry entry removed)
///   mounted  ─── close()   ──→  unmounted  (registry entry removed)
///   any open ─── destroy() ──→  (estate closed and backing stores torn down)
///
/// `unmounted` is a terminal state tracked only for a brief window — the
/// handle is invalid and will not resolve in the registry. Callers that
/// hold a stale handle see `GeniusLocusKitError.estateNotOpen`.
public enum EstateMountState: String, Sendable, Equatable {
    /// The estate is open and accepting new work. This is the state after
    /// a successful `open` or `provision` call.
    case mounted = "mounted"
    /// The estate is open but no new work is accepted. In-flight work already
    /// dispatched continues to completion. Calling verb methods on a quiesced
    /// estate raises `GeniusLocusKitError.estateQuiesced`.
    case quiesced = "quiesced"
    /// The estate is completing in-flight work after a `drain` request.
    /// GLK transitions to `.quiesced` automatically once the queue drains.
    /// Currently synchronous in this implementation (drain waits for the
    /// scheduler's queue to empty if one exists, then transitions to quiesced).
    case draining = "draining"
    /// The estate has been closed. This state is set momentarily during
    /// `close` / `destroy` teardown and is not observable from the registry
    /// (the registry entry is removed atomically with setting this state).
    case unmounted = "unmounted"
}
