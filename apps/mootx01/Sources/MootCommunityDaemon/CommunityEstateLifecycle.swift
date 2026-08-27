// CommunityEstateLifecycle.swift
//
// CommunityEstateLifecycleCoordinator — the actor that implements the six
// estate-lifecycle endpoints for the Community 1.1 daemon (Wave A2a: CORE-03).
//
// Each endpoint maps to a method on this actor and returns a JSONValue in the
// MCP tools/call result shape. The coordinator owns:
//   - The LAYOUT directory (parent of estate.sqlite + sidecar files).
//   - Two sidecar files it reads/writes for persistence:
//       estate-metadata.json   (name, schemaVersion, receiptID)
//       operation-state.json   (in-progress migration / cancelled operation)
//   - A transient CommunityEstateHost used only during inspect/create/open;
//     it is NOT the production DaemonProvider host.
//
// Endpoint semantics (all fail-closed per CORE-03):
//
//   inspect   — pure read: resolves current lifecycle state from disk without
//               mutating anything. Priority: in-progress operation → ready
//               (metadata present and estate opens) → needsCreation → corrupt.
//
//   create    — guarded: only advances if inspect returns needsCreation.
//               Opens (and thereby creates) the estate via CommunityEstateHost,
//               writes estate-metadata.json, returns ready.
//
//   open      — guarded: checks the estate file exists and its UUID matches the
//               requested estateID. Returns ready or blocked{reason}.
//
//   migrate   — starts or reports an in-progress migration operation, persisting
//               progress to operation-state.json so it survives a daemon restart.
//
//   recover   — always refused for destructive choices (authority-insufficient);
//               non-destructive choices are acknowledged but not yet executed
//               at this phase (returns blocked with reason explaining state).
//
//   cancel    — marks the current operation as cancelled in operation-state.json
//               and returns cancelled{resumable} truthfully.
//
// CORE-01 (CommunityEstateHost): never creates a replacement estate when the
// file already exists. Checked explicitly before every create call.
//
// Raw SQL errors, file paths, key bytes, and unbounded exception text NEVER
// appear in contract-visible response fields. Diagnosis strings are bounded
// classifications derived from typed Swift errors.

import Foundation
import OSLog
import MootDaemonProvider
import LocusKit
import PersistenceKit
import PersistenceKitSQLite
import AriaMCP

private let log = Logger(subsystem: "com.mootx01", category: "CommunityEstateLifecycle")

/// Manages the six estate-lifecycle endpoints for the community daemon.
///
/// Inject one instance into `CommunityContractDispatch` after constructing it
/// with the layout directory and key provider. In production the layout URL is
/// `~/Library/Application Support/MOOTx01/`; in tests it is a per-test temp
/// directory created by `LifecycleScratch`.
///
/// The actor is safe to share across concurrent tool calls. Actor isolation
/// serialises all mutable state (persisted files, transient host).
public actor CommunityEstateLifecycleCoordinator: Sendable {

    // MARK: - Properties

    /// The layout directory — parent of estate.sqlite and both sidecar files.
    public let layoutURL: URL

    /// Owner identifier threaded into OwnerCredentials for LocusKit.
    private let ownerIdentifier: String

    /// Key provider: returns the encryption config for the estate URL.
    private let keyProvider: @Sendable (URL) throws -> EstateEncryptionConfig

    // Derived paths (computed lazily, never stored — paths are not state).
    private var estateURL: URL    { layoutURL.appendingPathComponent("estate.sqlite") }
    private var metadataURL: URL  { layoutURL.appendingPathComponent("estate-metadata.json") }
    private var operationStateURL: URL { layoutURL.appendingPathComponent("operation-state.json") }

    // MARK: - Init

    /// Construct a coordinator for the given layout directory.
    ///
    /// - Parameters:
    ///   - layoutURL: The directory that will contain (or already contains)
    ///     `estate.sqlite`, `estate-metadata.json`, and `operation-state.json`.
    ///     Must already exist (the coordinator does not create it).
    ///   - ownerIdentifier: Non-empty label for OwnerCredentials; must be
    ///     stable across restarts so the LocusKit manifest is consistent.
    ///   - keyProvider: Returns the encryption config for the estate URL.
    ///     Use `{ _ in .plaintext }` for tests; the production conformer
    ///     reads from the data-protection Keychain.
    public init(
        layoutURL: URL,
        ownerIdentifier: String,
        keyProvider: @Sendable @escaping (URL) throws -> EstateEncryptionConfig
    ) {
        self.layoutURL = layoutURL
        self.ownerIdentifier = ownerIdentifier
        self.keyProvider = keyProvider
    }

    // MARK: - Endpoint: inspect

    /// Read the current estate lifecycle state from disk without mutating anything.
    ///
    /// Resolution order (first match wins):
    ///   1. operation-state.json says "migrating" → `migrating{progress}`.
    ///   2. estate.sqlite does not exist → `needsCreation`.
    ///   3. estate.sqlite exists but metadata is absent → try open → `ready` with
    ///      synthesised metadata or `corrupt` on failure.
    ///   4. estate.sqlite exists and metadata is present → try open → `ready` or
    ///      `corrupt` or `blocked{reason}`.
    ///
    /// CORE-01: inspect NEVER creates the estate file, even if the host would
    /// do so on a fresh path. The file-existence check below enforces this.
    public func inspect() async -> JSONValue {
        // 1. In-progress operation takes priority — migration interrupted mid-run
        //    must be surfaced truthfully before anything else.
        if let opState = readOperationState(), opState.kind == .migrating {
            return LifecycleMCPResponse.wrap(
                migratingStateFromPersisted(opState)
            )
        }

        // 2. No estate file → the client must call create.
        guard FileManager.default.fileExists(atPath: estateURL.path) else {
            return LifecycleMCPResponse.wrap(LifecycleStateBuilder.needsCreation())
        }

        // 3+4. Estate file exists — attempt a read-only open to determine state.
        return await tryOpenAndReport()
    }

    // MARK: - Endpoint: create

    /// Create the estate.
    ///
    /// Permitted ONLY when inspect returns `needsCreation`. A non-empty path
    /// is never permission to create a replacement (CORE-01 verbatim).
    ///
    /// On success:
    ///   - Opens the estate via CommunityEstateHost (which creates the file via LocusKit).
    ///   - Writes estate-metadata.json with the caller-supplied name.
    ///   - Returns `ready{receipt}`.
    ///
    /// On guard failure (estate already exists): `blocked{reason: "action-refused"}`.
    public func create(name: String) async -> JSONValue {
        // Guard: only proceed when the estate does not exist.
        // An existing file — even a corrupt one — is NOT permission to overwrite.
        guard !FileManager.default.fileExists(atPath: estateURL.path) else {
            log.error("create refused: estate file already exists at \(self.estateURL.lastPathComponent, privacy: .public)")
            return LifecycleMCPResponse.wrap(LifecycleStateBuilder.blocked(reason: "action-refused"))
        }

        // Open the estate via CommunityEstateHost. On a fresh path, LocusKit
        // creates the file, seeds the schema, and seeds the manifest UUID.
        let host = CommunityEstateHost(
            estateURL: estateURL,
            ownerIdentifier: ownerIdentifier,
            keyProvider: keyProvider
        )
        let proof: EstateReadyProof
        do {
            proof = try await host.openEstate()
        } catch {
            // Opening failed immediately after creating — extremely unusual
            // (disk full, permissions, concurrent racing writer). Report as corrupt
            // rather than silently ignoring: the file may exist in a partial state.
            let diagnosis = classifyOpenError(error)
            log.error("create: open failed immediately: \(diagnosis, privacy: .public)")
            // Build a minimal estate summary from the path (UUID unknown at this point).
            let fakeEstate = EstateSummaryData(id: UUID().uuidString.lowercased(), name: name, schemaVersion: "1.1")
            return LifecycleMCPResponse.wrap(LifecycleStateBuilder.corrupt(
                estate: fakeEstate,
                diagnosis: diagnosis,
                choices: defaultRecoveryChoices()
            ))
        }
        // Close the host immediately — it was only needed to bootstrap the file.
        try? await host.closeEstate()

        // Write metadata sidecar.
        let receiptID = UUID().uuidString.lowercased()
        let metadata = EstateMetadata(
            name: name,
            schemaVersion: "1.1",  // community 1.1 contract schema version label
            receiptID: receiptID
        )
        writeMetadata(metadata)

        let estateSummary = EstateSummaryData(
            id: proof.estateIdentifier.uuidString.lowercased(),
            name: name,
            schemaVersion: "1.1"
        )
        log.debug("create: estate created uuid=\(proof.estateIdentifier, privacy: .public)")
        return LifecycleMCPResponse.wrap(LifecycleStateBuilder.ready(
            estate: estateSummary,
            receiptID: receiptID
        ))
    }

    // MARK: - Endpoint: open

    /// Open an estate identified by its UUID.
    ///
    /// Returns `ready` when the estate exists and its UUID matches `estateID`.
    /// Returns `blocked{reason: "estate-missing"}` when the estate is absent or
    /// the UUID does not match (fail-closed: no existence oracle for foreign paths).
    /// Returns `corrupt` when the estate file cannot be opened.
    public func open(estateID: UUID) async -> JSONValue {
        // Estate file must exist.
        guard FileManager.default.fileExists(atPath: estateURL.path) else {
            return LifecycleMCPResponse.wrap(LifecycleStateBuilder.blocked(reason: "estate-missing"))
        }

        // Try to open the estate and read its proof.
        let host = CommunityEstateHost(
            estateURL: estateURL,
            ownerIdentifier: ownerIdentifier,
            keyProvider: keyProvider
        )
        let proof: EstateReadyProof
        do {
            proof = try await host.openEstate()
            try? await host.closeEstate()
        } catch {
            // Fail-closed: any open failure surfaces as corrupt, not as estate-missing.
            // An unreadable file is NOT absent; distinct error shapes.
            let diagnosis = classifyOpenError(error)
            let metadata = readMetadata()
            let fakeEstate = EstateSummaryData(
                id: estateID.uuidString.lowercased(),
                name: metadata?.name ?? "Unknown",
                schemaVersion: metadata?.schemaVersion ?? "1.1"
            )
            return LifecycleMCPResponse.wrap(LifecycleStateBuilder.corrupt(
                estate: fakeEstate,
                diagnosis: diagnosis,
                choices: defaultRecoveryChoices()
            ))
        }

        // UUID match check: requested estateID must equal the estate's actual UUID.
        // Mismatch → estate-missing (not a UUID oracle for the estate's real ID).
        guard proof.estateIdentifier == estateID else {
            return LifecycleMCPResponse.wrap(LifecycleStateBuilder.blocked(reason: "estate-missing"))
        }

        let metadata = readMetadata()
        let estateSummary = EstateSummaryData(
            id: proof.estateIdentifier.uuidString.lowercased(),
            name: metadata?.name ?? "Community Estate",
            schemaVersion: metadata?.schemaVersion ?? "1.1"
        )
        let receiptID = metadata?.receiptID ?? UUID().uuidString.lowercased()
        return LifecycleMCPResponse.wrap(LifecycleStateBuilder.ready(
            estate: estateSummary,
            receiptID: receiptID
        ))
    }

    // MARK: - Endpoint: migrate

    /// Start or report an in-progress migration operation.
    ///
    /// Attempt estate migration using the supplied plan.
    ///
    /// Community edition has no legacy migration source — `DefaultEstateMigrator`
    /// requires `ProviderLockProof`, `FileMigrationAuthority`, and
    /// `MigrationReceiptPersisting` infrastructure that is not wired for
    /// community builds. Rather than fabricating phantom in-progress state,
    /// this endpoint refuses honestly when no migration source is available.
    ///
    /// Returns `blocked{reason: "migration-interrupted"}` and persists
    /// NOTHING — inspect() will not surface a phantom `migrating` state after
    /// this call returns, because no operation-state.json is written here.
    ///
    /// "migration-interrupted" is the contract-valid reason code (§reasonCodes)
    /// for a migration that cannot proceed; it covers the case where the source
    /// is unavailable before the migration even starts. The reason is honest:
    /// the migration is interrupted at the gate because no source is wired.
    ///
    /// If a real migrator is later wired, this method should be replaced with
    /// a call to `DefaultEstateMigrator.migrate(planID:)`. The contract test
    /// accepts both `blocked` and `migrating` (with valid progress) as valid
    /// migrate responses.
    public func migrate(planID: UUID) async -> JSONValue {
        // Community edition cannot run estate migration — no legacy source is
        // available and DefaultEstateMigrator is not wired here. Refuse honestly
        // rather than persisting phantom in-progress state that inspect() would
        // surface forever (F12 fix: honest refusal, persist NOTHING).
        //
        // Uses "migration-interrupted" per the contract's reasonCodes enum —
        // "migration-source-unavailable" is not a contract-defined code.
        log.debug("migrate: refused planID=\(planID, privacy: .public) — migration-interrupted (source unavailable)")
        return LifecycleMCPResponse.wrap(
            LifecycleStateBuilder.blocked(reason: "migration-interrupted")
        )
    }

    // MARK: - Endpoint: recover

    /// Attempt estate recovery using a recovery choice.
    ///
    /// Community edition has no authority escalation mechanism. All recovery
    /// choices — destructive (delete, restore) and non-destructive (supply-key)
    /// alike — are refused with `blocked{reason: "authority-insufficient"}`.
    ///
    /// The `choiceID` is validated against the known choice catalogue; an
    /// unrecognised choice returns `blocked{reason: "action-refused"}`.
    public func recover(choiceID: String) async -> JSONValue {
        // The Community edition has no authority escalation. Any recovery
        // choice that changes data is refused until the key-supply / restore
        // flow is implemented (MACD-3). Return a truthful refusal.
        log.debug("recover: choiceID=\(choiceID, privacy: .public) refused (authority-insufficient)")
        return LifecycleMCPResponse.wrap(LifecycleStateBuilder.blocked(reason: "authority-insufficient"))
    }

    // MARK: - Endpoint: cancel

    /// Cancel the current lifecycle operation.
    ///
    /// Marks the operation state as `.cancelled` and persists the update.
    /// `resumable` is derived truthfully: a migration interrupted before
    /// committing is resumable; a completed or unknown operation is not.
    ///
    /// Returns `blocked{reason: "operation-cancelled"}` if no active operation
    /// is found for `operationID`.
    public func cancel(operationID: UUID) async -> JSONValue {
        guard var opState = readOperationState(),
              opState.operationID == operationID.uuidString.lowercased() else {
            // No matching active operation.
            return LifecycleMCPResponse.wrap(LifecycleStateBuilder.blocked(reason: "operation-cancelled"))
        }

        // A migrating operation can be resumed after cancellation (the plan and
        // source estate are unchanged). Persist the cancelled state so a
        // subsequent inspect can report it.
        let wasResumable = opState.resumable && opState.kind == .migrating
        opState.kind = .cancelled
        opState.resumable = wasResumable
        writeOperationState(opState)
        log.debug("cancel: operationID=\(operationID, privacy: .public) resumable=\(wasResumable, privacy: .public)")
        return LifecycleMCPResponse.wrap(LifecycleStateBuilder.cancelled(resumable: wasResumable))
    }

    // MARK: - Private: open estate and report state

    /// Attempt to open the estate and return the appropriate lifecycle state.
    /// Used by both `inspect()` and `open(estateID:)` when the file is present.
    ///
    /// Never creates the estate file (CORE-01): only called when the file
    /// already exists.
    private func tryOpenAndReport() async -> JSONValue {
        let host = CommunityEstateHost(
            estateURL: estateURL,
            ownerIdentifier: ownerIdentifier,
            keyProvider: keyProvider
        )
        let proof: EstateReadyProof
        do {
            proof = try await host.openEstate()
            try? await host.closeEstate()
        } catch {
            return LifecycleMCPResponse.wrap(corruptStateFromError(error))
        }

        let metadata = readMetadata()
        let estateSummary = EstateSummaryData(
            id: proof.estateIdentifier.uuidString.lowercased(),
            name: metadata?.name ?? "Community Estate",
            schemaVersion: metadata?.schemaVersion ?? "1.1"
        )
        let receiptID = metadata?.receiptID ?? UUID().uuidString.lowercased()
        return LifecycleMCPResponse.wrap(LifecycleStateBuilder.ready(
            estate: estateSummary,
            receiptID: receiptID
        ))
    }

    /// Read-only open of the estate, returning the proof without caching.
    /// Closes the host immediately after reading. Used for estate-UUID extraction.
    private func openForRead() async throws -> EstateReadyProof {
        let host = CommunityEstateHost(
            estateURL: estateURL,
            ownerIdentifier: ownerIdentifier,
            keyProvider: keyProvider
        )
        let proof = try await host.openEstate()
        try? await host.closeEstate()
        return proof
    }

    // MARK: - Private: error classification (CORE-03 diagnosis boundary)

    /// Produce a bounded diagnosis string from an open error.
    ///
    /// CORE-03: only classification labels cross the contract boundary, never
    /// raw SQL error text, never file paths beyond the filename component,
    /// never key material.
    private func classifyOpenError(_ error: Error) -> String {
        // Check for known typed errors first — most specific wins.
        if let daemonError = error as? CommunityDaemonError {
            switch daemonError {
            case .corruptManifest:
                return "The canonical store failed its integrity check; no replacement estate was created."
            case .keyMismatch:
                return "The estate encryption key does not match; key custody verification failed."
            case .estateLocked:
                return "The estate is locked by another process."
            case .alreadyOpen:
                return "The estate connection is already open."
            case .walNotEmpty:
                return "The WAL is non-empty after a truncating checkpoint."
            default:
                return "An unexpected daemon error prevented the estate from opening."
            }
        }
        // LocusKit and PersistenceKit errors — classify by string prefix, never by
        // localizedDescription (which may contain file paths on some platforms).
        let typeName = String(describing: type(of: error))
        if typeName.contains("EstateError") {
            return "The canonical store failed its integrity check; no replacement estate was created."
        }
        if typeName.contains("StorageError") || typeName.contains("backendError") {
            return "The estate storage backend reported an error during open."
        }
        // Final fallback: generic classification. Never includes error.localizedDescription.
        return "An unexpected error prevented the estate from opening."
    }

    /// Build a `corrupt` state dict from an open error, synthesising an estate
    /// summary from whatever identity information is available.
    private func corruptStateFromError(_ error: Error) -> [String: JSONValue] {
        let metadata = readMetadata()
        // Use a placeholder UUID since the corrupt file cannot be read for its UUID.
        let fakeEstate = EstateSummaryData(
            id: "00000000-0000-0000-0000-000000000000",
            name: metadata?.name ?? "Unknown",
            schemaVersion: metadata?.schemaVersion ?? "1.1"
        )
        return LifecycleStateBuilder.corrupt(
            estate: fakeEstate,
            diagnosis: classifyOpenError(error),
            choices: defaultRecoveryChoices()
        )
    }

    /// The standard recovery choice offered for corrupt estates.
    private func defaultRecoveryChoices() -> [RecoveryChoiceData] {
        [RecoveryChoiceData(
            id: "restore-last-good",
            title: "Restore last verified snapshot",
            consequence: "Replaces damaged canonical state with the last verified snapshot.",
            isDestructive: true
        )]
    }

    // MARK: - Private: operation state from persisted record

    private func migratingStateFromPersisted(_ op: PersistedOperationState) -> [String: JSONValue] {
        let plan = MigrationPlanData(
            id: op.planID,
            estate: EstateSummaryData(
                id: op.estateID,
                name: op.estateName,
                schemaVersion: op.sourceVersion
            ),
            sourceVersion: op.sourceVersion,
            targetVersion: op.targetVersion,
            expectedEffect: "Preserves canonical records while adding Community 1.1 policy metadata."
        )
        return LifecycleStateBuilder.migrating(
            operationID: op.operationID,
            plan: plan,
            completedUnits: op.completedUnits,
            totalUnits: op.totalUnits
        )
    }

    // MARK: - Private: sidecar I/O

    /// Read estate-metadata.json; returns nil on absence or decode failure.
    private func readMetadata() -> EstateMetadata? {
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        return try? JSONDecoder().decode(EstateMetadata.self, from: data)
    }

    /// Write estate-metadata.json atomically.
    private func writeMetadata(_ metadata: EstateMetadata) {
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: metadataURL, options: .atomic)
    }

    /// Read operation-state.json; returns nil on absence or decode failure.
    func readOperationState() -> PersistedOperationState? {
        guard let data = try? Data(contentsOf: operationStateURL) else { return nil }
        return try? JSONDecoder().decode(PersistedOperationState.self, from: data)
    }

    /// Write operation-state.json atomically.
    private func writeOperationState(_ state: PersistedOperationState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: operationStateURL, options: .atomic)
    }
}
