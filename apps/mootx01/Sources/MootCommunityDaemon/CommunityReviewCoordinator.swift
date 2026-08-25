// CommunityReviewCoordinator.swift
//
// Durable review session state management (Wave B1: CORE-05).
//
// ARCHITECTURE
// ────────────────────────────────────────────────────────────────────────
// This actor owns the review-state.json sidecar and mediates all review
// mutations. It opens its own estate connection (same lazy-open pattern
// as CommunityCaptureCoordinator) for reading drawers and applying
// reversible actions.
//
// SIDECAR: review-state.json
// ────────────────────────────────────────────────────────────────────────
// { "sessions": { "<sessionID>": { ... PersistedSession ... } } }
//
// PersistedSession fields:
//   kind              : string     ("morning" | "endOfDay" | "weekly")
//   generatedAt       : string     (ISO8601)
//   sourceEstateState : string     (sha256:{hex}:{count})
//   appliedActionIDs  : [string]   (UUIDs of applied actions)
//   reversedActionIDs : [string]   (UUIDs of applied-then-reversed actions)
//   resolvedGroupIDs  : [string]   (UUIDs of resolved duplicate groups)
//   completionState   : string     ("notStarted" | "inProgress" | "completed")
//   completedAt       : string?    (ISO8601, present when completionState = "completed")
//   completionSummary : string?    (present when completionState = "completed")
//
// Atomic write (write .tmp then rename) ensures a crash mid-write never
// corrupts the sidecar.
//
// FAIL-CLOSED RULES (CORE-05)
// ────────────────────────────────────────────────────────────────────────
// • apply on unknown sessionID          → staleSession
// • apply on unknown actionID           → refused(action-refused)
// • apply on already-applied actionID   → alreadyApplied (idempotent retry)
// • apply after estate changed          → staleSession (fingerprint mismatch)
// • apply when conflict exists          → conflict(action-conflict)
// • reverse on non-applied action       → refused(action-refused)
// • reverse on already-reversed action  → refused(action-refused)
// • reverse_duplicate on unknown group  → refused(action-refused)
// • complete on unknown session         → refused(action-refused)
// • complete on already-completed       → refused(action-refused)
// • zero partial mutation on any refusal — the sidecar is never written
//   if the operation is refused.
//
// STALENESS DETECTION
// ────────────────────────────────────────────────────────────────────────
// When apply/reverse/resolve is called, the coordinator re-computes the
// current estate fingerprint and compares it to the session's stored
// sourceEstateState. A mismatch means the estate changed — the session is
// stale. Only mutation operations trigger the staleness check (dashboard
// and review_session are read-only).
//
// CONFLICT DETECTION
// ────────────────────────────────────────────────────────────────────────
// A conflict is returned when applying an action that was previously applied
// AND then reversed, AND the current estate fingerprint differs from the
// session's sourceEstateState. The reasoning: the action's effect has been
// undone but the estate has changed, so re-applying would produce an
// unpredictable result.
// Exception: if the estate has NOT changed, re-applying a reversed action
// succeeds normally (the reversal is idempotent from the estate's perspective).
//
// COMPLETION RECEIPT DURABILITY
// ────────────────────────────────────────────────────────────────────────
// The receipt is stored in the sidecar at completion time. A new coordinator
// instance (fresh daemon start) reads the sidecar and reconstructs the receipt
// from persisted fields — the receipt survives restarts.

import Foundation
import OSLog
import AriaMCP
import LocusKit
import PersistenceKit
import PersistenceKitSQLite

private let log = Logger(subsystem: "com.mootx01", category: "CommunityReviewCoordinator")

// MARK: - Persisted session state

/// Codable representation of one persisted review session.
///
/// Stored inside review-state.json under the session UUID key.
private struct PersistedSession: Codable, Sendable {
    /// Review kind as raw string.
    var kind: String
    /// ISO8601 timestamp when the session was generated.
    var generatedAt: String
    /// Estate fingerprint at generation time.
    var sourceEstateState: String
    /// Action IDs that have been applied (and not yet reversed).
    var appliedActionIDs: [String]
    /// Action IDs that were applied and then reversed.
    var reversedActionIDs: [String]
    /// Duplicate group IDs that have been resolved.
    var resolvedGroupIDs: [String]
    /// "notStarted" | "inProgress" | "completed"
    var completionState: String
    /// ISO8601 completion timestamp. Present iff completionState = "completed".
    var completedAt: String?
    /// Completion summary. Present iff completionState = "completed".
    var completionSummary: String?
}

/// Top-level sidecar file shape.
private struct PersistedReviewState: Codable, Sendable {
    var sessions: [String: PersistedSession]
}

// MARK: - CommunityReviewCoordinator

/// Manages durable review session state and mediates all review mutations.
///
/// Inject one instance into `CommunityContractDispatch` after constructing it
/// with the layout directory and key provider. In production the layout URL is
/// `~/Library/Application Support/MOOTx01/`; in tests it is a per-test temp
/// directory.
///
/// The actor is safe to share across concurrent tool calls — actor isolation
/// serializes all mutable state (estate connection, sidecar file).
public actor CommunityReviewCoordinator: Sendable {

    // MARK: - Properties

    /// The layout directory — parent of estate.sqlite and review-state.json.
    public let layoutURL: URL

    /// Owner identifier threaded into OwnerCredentials for LocusKit.
    private let ownerIdentifier: String

    /// Key provider: returns the encryption config for the estate URL.
    private let keyProvider: @Sendable (URL) throws -> EstateEncryptionConfig

    // Derived paths.
    private var estateURL: URL { layoutURL.appendingPathComponent("estate.sqlite") }
    private var reviewStateURL: URL { layoutURL.appendingPathComponent("review-state.json") }

    // Lazily-opened estate (same pattern as CommunityCaptureCoordinator).
    private var openedEstate: Estate?

    // MARK: - Init

    /// Construct a coordinator for the estate in `layoutURL`.
    ///
    /// - Parameters:
    ///   - layoutURL: The layout directory containing (or that will contain)
    ///     `estate.sqlite` and `review-state.json`.
    ///   - ownerIdentifier: Non-empty stable label for OwnerCredentials.
    ///   - keyProvider: Returns the encryption config for the estate URL.
    public init(
        layoutURL: URL,
        ownerIdentifier: String,
        keyProvider: @Sendable @escaping (URL) throws -> EstateEncryptionConfig
    ) {
        self.layoutURL = layoutURL
        self.ownerIdentifier = ownerIdentifier
        self.keyProvider = keyProvider
    }

    // MARK: - Endpoint: moot_community_review_dashboard

    /// Return the current dashboard showing all three review kinds.
    ///
    /// This is read-only — never mutates the sidecar or the estate.
    /// Each kind's status is derived from the persisted state:
    ///   - No session or notStarted → "due" (review is pending)
    ///   - inProgress → "inProgress" with sessionID
    ///   - completed → "completed" with receipt
    public func dashboard() async -> JSONValue {
        let state = readState()
        let modes = ReviewKind.allCases.map { kind -> ReviewMode in
            modeFor(kind: kind, in: state)
        }
        return ReviewDashboard(modes: modes).toJSONValue()
    }

    // MARK: - Endpoint: moot_community_review_session

    /// Return (or generate) the current review session for the given kind.
    ///
    /// Behaviour:
    ///   - If an in-progress session exists for this kind → return it with
    ///     current action states (reversalAvailable updated from durable state).
    ///   - If no session exists or the prior session is completed →
    ///     generate a new session from current estate drawers and now.
    ///   - Estate open failure → blocked{daemon-blocked}.
    ///
    /// This endpoint is read-only on the estate; new sessions are persisted
    /// to the sidecar only (no estate mutation).
    public func reviewSession(kind: ReviewKind, now: Date) async -> JSONValue {
        let drawers: [Drawer]
        do {
            let estate = try await requireEstate()
            drawers = try await estate.allDrawers()
        } catch {
            log.error("review_session: estate access failed: \(error, privacy: .public)")
            return ReviewSessionOutcome.blocked(reason: "daemon-blocked").toJSONValue()
        }

        var state = readState()

        // Look for an existing in-progress session for this kind.
        let kindRaw = kind.rawValue
        let existing = state.sessions.first { $0.value.kind == kindRaw && $0.value.completionState == "inProgress" }

        if let (sessionIDStr, persisted) = existing {
            // Return the existing session with current action states injected.
            let session = buildSessionFromPersisted(
                sessionIDStr: sessionIDStr,
                persisted: persisted,
                kind: kind,
                drawers: drawers
            )
            return ReviewSessionOutcome.session(session).toJSONValue()
        }

        // Generate a new session.
        let appliedSet = Set<String>()   // fresh session: no applied actions yet
        let reversedSet = Set<String>()
        let session = CommunityReviewEngine.generateSession(
            kind: kind,
            drawers: drawers,
            now: now,
            appliedActionIDs: appliedSet,
            reversedActionIDs: reversedSet,
            completionStatus: .inProgress
        )

        // Persist the new session.
        let sessionIDStr = session.id.uuidString.lowercased()
        let newPersisted = PersistedSession(
            kind: kind.rawValue,
            generatedAt: iso8601Encode(now),
            sourceEstateState: session.sourceEstateState,
            appliedActionIDs: [],
            reversedActionIDs: [],
            resolvedGroupIDs: [],
            completionState: "inProgress",
            completedAt: nil,
            completionSummary: nil
        )
        state.sessions[sessionIDStr] = newPersisted
        writeState(state)

        return ReviewSessionOutcome.session(session).toJSONValue()
    }

    // MARK: - Endpoint: moot_community_review_apply

    /// Apply a review action.
    ///
    /// Preconditions (fail-closed, checked in order):
    ///   1. sessionID exists in durable state → else staleSession.
    ///   2. actionID is a valid action for this session → else refused.
    ///   3. actionID not already applied (excl. reversed) → else alreadyApplied.
    ///   4. actionID was applied-then-reversed AND estate changed → conflict.
    ///   5. Current estate fingerprint matches session.sourceEstateState → else staleSession.
    ///   6. Apply: add actionID to appliedActionIDs, persist.
    ///
    /// Zero partial mutation: the sidecar is only written if all checks pass.
    public func applyAction(actionID: UUID, sessionID: UUID, now: Date) async -> JSONValue {
        let actionIDStr = actionID.uuidString.lowercased()
        let sessionIDStr = sessionID.uuidString.lowercased()

        var state = readState()

        // 1. Session must exist.
        guard var persisted = state.sessions[sessionIDStr] else {
            return ReviewActionOutcome.staleSession.toJSONValue()
        }

        // 2. Validate that the actionID belongs to this session.
        let drawers: [Drawer]
        do {
            let estate = try await requireEstate()
            drawers = try await estate.allDrawers()
        } catch {
            log.error("review_apply: estate access failed: \(error, privacy: .public)")
            return ReviewActionOutcome.failed(reason: "unexpected-failure").toJSONValue()
        }

        guard isValidAction(actionID: actionID, sessionID: sessionID, drawers: drawers) else {
            return ReviewActionOutcome.refused(reason: "action-refused").toJSONValue()
        }

        // 3. Check idempotency: already applied and not reversed → alreadyApplied.
        let isApplied = persisted.appliedActionIDs.contains(actionIDStr)
        let isReversed = persisted.reversedActionIDs.contains(actionIDStr)
        if isApplied && !isReversed {
            return ReviewActionOutcome.alreadyApplied.toJSONValue()
        }

        // 4. Conflict: previously applied-then-reversed AND estate changed.
        if isApplied && isReversed {
            let currentFingerprint = CommunityReviewEngine.estateFingerprint(
                activeDrawers: drawers.filter { $0.tombstonedAt == nil }
            )
            if currentFingerprint != persisted.sourceEstateState {
                return ReviewActionOutcome.conflict(reason: "action-conflict").toJSONValue()
            }
            // Estate unchanged — re-apply the reversed action (not a conflict).
            // Remove from reversedActionIDs so it's back in applied state.
            persisted.reversedActionIDs.removeAll { $0 == actionIDStr }
            // Fall through to the apply step below.
        } else {
            // 5. Staleness check (only for first-time apply, not re-apply after reversal).
            let currentFingerprint = CommunityReviewEngine.estateFingerprint(
                activeDrawers: drawers.filter { $0.tombstonedAt == nil }
            )
            if currentFingerprint != persisted.sourceEstateState {
                return ReviewActionOutcome.staleSession.toJSONValue()
            }
        }

        // 6. Apply: mark action as applied.
        if !persisted.appliedActionIDs.contains(actionIDStr) {
            persisted.appliedActionIDs.append(actionIDStr)
        }
        state.sessions[sessionIDStr] = persisted
        writeState(state)

        log.debug("review_apply: applied actionID=\(actionIDStr, privacy: .public) sessionID=\(sessionIDStr, privacy: .public)")
        return ReviewActionOutcome.applied.toJSONValue()
    }

    // MARK: - Endpoint: moot_community_review_reverse

    /// Reverse a previously applied action.
    ///
    /// Preconditions:
    ///   1. sessionID must exist → else refused.
    ///   2. actionID must be valid for the session → else refused.
    ///   3. actionID must be in appliedActionIDs AND NOT in reversedActionIDs → else refused.
    ///   4. Move actionID from appliedActionIDs to reversedActionIDs; persist.
    ///
    /// Note: reversalAvailable on ReviewAction reflects this state. Only
    /// actions with isReversible = true support reversal — all daemon-generated
    /// actions have isReversible = true.
    public func reverseAction(actionID: UUID, sessionID: UUID) async -> JSONValue {
        let actionIDStr = actionID.uuidString.lowercased()
        let sessionIDStr = sessionID.uuidString.lowercased()

        var state = readState()

        // 1. Session must exist.
        guard var persisted = state.sessions[sessionIDStr] else {
            return ReviewActionOutcome.refused(reason: "action-refused").toJSONValue()
        }

        // 2. Validate actionID belongs to this session.
        let drawers: [Drawer]
        do {
            let estate = try await requireEstate()
            drawers = try await estate.allDrawers()
        } catch {
            log.error("review_reverse: estate access failed: \(error, privacy: .public)")
            return ReviewActionOutcome.failed(reason: "unexpected-failure").toJSONValue()
        }

        guard isValidAction(actionID: actionID, sessionID: sessionID, drawers: drawers) else {
            return ReviewActionOutcome.refused(reason: "action-refused").toJSONValue()
        }

        // 3. Action must be applied and not yet reversed.
        let isApplied = persisted.appliedActionIDs.contains(actionIDStr)
        let isReversed = persisted.reversedActionIDs.contains(actionIDStr)
        guard isApplied && !isReversed else {
            return ReviewActionOutcome.refused(reason: "action-refused").toJSONValue()
        }

        // 4. Reverse: move to reversedActionIDs.
        persisted.reversedActionIDs.append(actionIDStr)
        state.sessions[sessionIDStr] = persisted
        writeState(state)

        log.debug("review_reverse: reversed actionID=\(actionIDStr, privacy: .public) sessionID=\(sessionIDStr, privacy: .public)")
        return ReviewActionOutcome.applied.toJSONValue()
    }

    // MARK: - Endpoint: moot_community_review_resolve_duplicate

    /// Resolve a duplicate group by applying a resolution choice.
    ///
    /// Preconditions:
    ///   1. sessionID must exist → else refused.
    ///   2. groupID must be a valid duplicate group for this session → else refused.
    ///   3. choiceID must be a valid choice for this group → else refused.
    ///   4. Group must not already be resolved → alreadyApplied.
    ///   5. Current estate fingerprint must match session.sourceEstateState → else staleSession.
    ///   6. Estate effect (F4): archive older duplicate drawers in the estate.
    ///   7. Mark group as resolved in sidecar; persist.
    ///
    /// Estate write (step 6) happens BEFORE the sidecar mark (step 7). If the
    /// daemon restarts between the two writes, the estate reflects the resolution
    /// while the sidecar does not — the next session will NOT surface the now-
    /// tombstoned drawers as duplicates, so the group will not re-appear. A
    /// resuming user will see one fewer duplicate group, which is the correct
    /// outcome. The sidecar update is therefore safe to lose.
    public func resolveDuplicate(groupID: UUID, choiceID: UUID, sessionID: UUID, now: Date) async -> JSONValue {
        let groupIDStr = groupID.uuidString.lowercased()
        let sessionIDStr = sessionID.uuidString.lowercased()

        var state = readState()

        // 1. Session must exist.
        guard var persisted = state.sessions[sessionIDStr] else {
            return ReviewActionOutcome.refused(reason: "action-refused").toJSONValue()
        }

        // 4 (early). Already resolved → alreadyApplied (idempotent).
        //
        // This check is promoted BEFORE group/choice validation (step 2-3) because:
        // once a group is resolved, the older drawers are tombstoned. On a subsequent
        // call the engine regenerates the session with fewer active drawers, and the
        // group is no longer detectable — the validation would fail, returning "refused"
        // instead of the correct "alreadyApplied". Checking resolved-state first avoids
        // this false refusal.
        if persisted.resolvedGroupIDs.contains(groupIDStr) {
            return ReviewActionOutcome.alreadyApplied.toJSONValue()
        }

        // 2 & 3. Validate groupID and choiceID against the session's duplicate groups.
        // Returns the validated group (needed for step 6) and which choice was selected.
        let drawers: [Drawer]
        let estate: Estate
        do {
            estate = try await requireEstate()
            drawers = try await estate.allDrawers()
        } catch {
            log.error("review_resolve_duplicate: estate access failed: \(error, privacy: .public)")
            return ReviewActionOutcome.failed(reason: "unexpected-failure").toJSONValue()
        }

        // Regenerate the session (engine is pure) to validate group/choice IDs and
        // retrieve the group so we know which drawers to archive (step 6).
        guard let (group, choiceIndex) = findValidatedDuplicateGroup(
            groupID: groupID,
            choiceID: choiceID,
            drawers: drawers,
            persisted: persisted
        ) else {
            return ReviewActionOutcome.refused(reason: "action-refused").toJSONValue()
        }

        // 5. Staleness check.
        // Mirror the engine's activeDrawers filter: non-tombstoned AND not system-origin.
        // System-origin drawers are excluded from fingerprinting (F11 fix).
        let activeDrawers = drawers.filter { $0.tombstonedAt == nil && !$0.addedBy.hasPrefix("system:") }
        let currentFingerprint = CommunityReviewEngine.estateFingerprint(activeDrawers: activeDrawers)
        guard currentFingerprint == persisted.sourceEstateState else {
            return ReviewActionOutcome.staleSession.toJSONValue()
        }

        // 6. Estate effect (F4 fix): archive the older drawer(s) in the group.
        //
        // group.recordIDs is sorted newest-first (recordIDs[0] = newest, per the engine's
        // makeGroup() which sorts by filedAt DESC then id ASC). We archive all but the
        // newest — dropping recordIDs[0] from the archive list.
        //
        // Choice 0 ("Keep the newer record and archive the older one."): archive older only.
        // Choice 1 ("Merge content into the newer record and archive the older one."):
        //   ideally merges the older drawer's content into the newer before archiving, but
        //   Estate.mutate() is internal to LocusKit. Both choices produce the same archive
        //   effect here; content merge is deferred pending a public mutation API.
        let olderDrawerIDs = group.recordIDs.dropFirst()
        for drawerID in olderDrawerIDs {
            // Drawer IDs are stored in the estate as the raw UUID().uuidString format
            // (uppercase, e.g. "A3B4C5D6-…"). SQLite's = operator is case-sensitive
            // for text columns, so we must NOT lowercase the ID — using lowercase
            // would produce "drawer not found" from the estate query even though the
            // drawer exists. Pass the Swift UUID's .uuidString directly.
            let drawerIDStr = drawerID.uuidString  // uppercase — matches the stored format
            do {
                let outcome = try await estate.archiveDrawer(
                    id: drawerIDStr,
                    reason: "duplicate-resolution",
                    now: now
                )
                log.debug("review_resolve_duplicate: archived drawerID=\(drawerIDStr, privacy: .public) choiceIndex=\(choiceIndex, privacy: .public) outcome=\(String(describing: outcome), privacy: .public)")
            } catch {
                log.error("review_resolve_duplicate: archive failed drawerID=\(drawerIDStr, privacy: .public) error=\(error, privacy: .public)")
                return ReviewActionOutcome.failed(reason: "unexpected-failure").toJSONValue()
            }
        }

        // 7. Sidecar mark (AFTER estate write, not before).
        // If the daemon crashes between step 6 and step 7, the estate is correct
        // (older drawers tombstoned) but the sidecar is stale. On the next session
        // generation, the tombstoned drawers won't be active, so the duplicate group
        // won't appear — the user simply won't see the group in the next session.
        persisted.resolvedGroupIDs.append(groupIDStr)
        state.sessions[sessionIDStr] = persisted
        writeState(state)

        log.debug("review_resolve_duplicate: resolved groupID=\(groupIDStr, privacy: .public) sessionID=\(sessionIDStr, privacy: .public) choiceIndex=\(choiceIndex, privacy: .public)")
        return ReviewActionOutcome.applied.toJSONValue()
    }

    // MARK: - Endpoint: moot_community_review_complete

    /// Complete a review session and return a durable receipt.
    ///
    /// Preconditions:
    ///   1. sessionID must exist → else refused.
    ///   2. Session must not already be completed → refused (return stored receipt).
    ///   3. Mark session completed; persist receipt; return receipt.
    ///
    /// The receipt is stored durably so a new coordinator instance can return
    /// it without re-running the session.
    public func completeSession(sessionID: UUID, now: Date) async -> JSONValue {
        let sessionIDStr = sessionID.uuidString.lowercased()
        var state = readState()

        // 1. Session must exist.
        guard var persisted = state.sessions[sessionIDStr] else {
            return ReviewCompleteOutcome.refused(reason: "action-refused").toJSONValue()
        }

        // 2. Already completed → refused (cannot re-complete).
        if persisted.completionState == "completed" {
            return ReviewCompleteOutcome.refused(reason: "action-refused").toJSONValue()
        }

        // 3. Build receipt and mark completed.
        let appliedCount = persisted.appliedActionIDs.count
        let resolvedCount = persisted.resolvedGroupIDs.count
        let summary = buildCompletionSummary(
            kind: persisted.kind,
            appliedCount: appliedCount,
            resolvedCount: resolvedCount
        )
        let completedAt = now
        let receipt = ReviewCompletionReceipt(
            sessionID: sessionID,
            completedAt: completedAt,
            summary: summary
        )

        persisted.completionState = "completed"
        persisted.completedAt = iso8601Encode(completedAt)
        persisted.completionSummary = summary
        state.sessions[sessionIDStr] = persisted
        writeState(state)

        log.debug("review_complete: completed sessionID=\(sessionIDStr, privacy: .public)")
        return ReviewCompleteOutcome.completed(receipt: receipt).toJSONValue()
    }

    // MARK: - Estate access

    /// Open the estate on first use and cache it for subsequent calls.
    ///
    /// Fail-closed: throws `CommunityDaemonError.estateAbsent` if estate.sqlite
    /// does not exist. This prevents `SQLiteStorage(configuration:)` — which uses
    /// `SQLITE_OPEN_CREATE` — from silently creating the estate file as a side-
    /// effect of a review call. Creating the estate here would bypass the
    /// lifecycle `needsCreation` gate (F11 fix).
    ///
    /// Any further error from the key provider, storage backend, or LocusKit
    /// propagates to the caller without wrapping — no silent fallback.
    private func requireEstate() async throws -> Estate {
        if let estate = openedEstate { return estate }

        // Fail-closed gate: the estate file must already exist.
        let url = estateURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            log.error("review requireEstate: estate.sqlite not found at \(url.path, privacy: .public)")
            throw CommunityDaemonError.estateAbsent(url)
        }

        let config = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: estateURL, busyTimeout: 5.0),
            encryptionConfig: try keyProvider(estateURL)
        )
        let storage = try SQLiteStorage(configuration: config)
        let estate = try await Estate.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: ownerIdentifier),
            identityKeyStore: InMemoryEstateIdentityKeyStore()
        )
        self.openedEstate = estate
        return estate
    }

    // MARK: - Sidecar persistence

    /// Read the current review state from disk.
    ///
    /// Returns an empty state if the file doesn't exist or is unparseable.
    /// Fail-open on read (missing file is a valid empty state).
    private func readState() -> PersistedReviewState {
        guard let data = try? Data(contentsOf: reviewStateURL) else {
            return PersistedReviewState(sessions: [:])
        }
        guard let decoded = try? JSONDecoder().decode(PersistedReviewState.self, from: data) else {
            log.warning("review: state file parse failed — treating as empty")
            return PersistedReviewState(sessions: [:])
        }
        return decoded
    }

    /// Write the updated review state atomically.
    ///
    /// Atomic: write to .tmp then rename. A crash mid-write never corrupts
    /// the sidecar. If the write fails, the existing sidecar is preserved
    /// (fail-closed for subsequent reads — current mutation succeeded at the
    /// session level).
    private func writeState(_ state: PersistedReviewState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(state) else {
            log.error("review: state encode failed")
            return
        }
        let tmpURL = reviewStateURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmpURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(reviewStateURL, withItemAt: tmpURL)
        } catch {
            do {
                try data.write(to: reviewStateURL, options: .atomic)
                try? FileManager.default.removeItem(at: tmpURL)
            } catch {
                log.error("review: state write failed: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Validation helpers

    /// True if the given actionID is a valid action for the given session.
    ///
    /// Validity is checked by re-deriving the action ID for each active drawer
    /// using the SAME formula as CommunityReviewEngine: deriveID("action",
    /// sessionID.uuidString, drawer.id). The session ID here is the UUID from
    /// the API request — its .uuidString must be used as-is (uppercase,
    /// standard Swift UUID format) because the engine also uses .uuidString
    /// without lowercasing. Using lowercased() would produce a different hash
    /// and incorrectly refuse valid actions.
    private func isValidAction(actionID: UUID, sessionID: UUID, drawers: [Drawer]) -> Bool {
        let actionIDStr = actionID.uuidString.lowercased()
        // CANONICAL UUID FORMAT: use lowercase to match the engine.
        // CommunityReviewEngine uses sessionID.uuidString.lowercased() when calling deriveID,
        // maintaining parity with the Python vector toolchain (Python's str(uuid) is lowercase)
        // and the Rust implementation (uuid::to_string() is lowercase).
        let sessionIDForDerivation = sessionID.uuidString.lowercased()
        // Mirror the engine's activeDrawers filter exactly: non-tombstoned AND
        // not system-origin. System-origin drawers never generate review actions,
        // so a submitted actionID derived from one must be rejected (F11 fix).
        let activeDrawers = drawers.filter { $0.tombstonedAt == nil && !$0.addedBy.hasPrefix("system:") }

        // The engine generates one action per active drawer with ID =
        // deriveID("action", sessionID.uuidString.lowercased(), drawerID). Check each drawer.
        return activeDrawers.contains { drawer in
            let derived = CommunityReviewEngine.deriveID("action", sessionIDForDerivation, drawer.id)
            return derived.uuidString.lowercased() == actionIDStr
        }
    }

    /// True if the given groupID + choiceID is valid for the given session.
    ///
    /// Delegates to `findValidatedDuplicateGroup` and returns whether a result
    /// was found. Callers that also need the group (e.g. resolveDuplicate for
    /// the estate-effect step) should call `findValidatedDuplicateGroup` directly.
    private func isValidDuplicateChoice(
        groupID: UUID,
        choiceID: UUID,
        sessionID: UUID,
        drawers: [Drawer],
        persisted: PersistedSession
    ) -> Bool {
        findValidatedDuplicateGroup(
            groupID: groupID,
            choiceID: choiceID,
            drawers: drawers,
            persisted: persisted
        ) != nil
    }

    /// Regenerate the session and find the duplicate group + choice index matching
    /// the given groupID and choiceID.
    ///
    /// Returns `(group, choiceIndex)` on success, `nil` on any validation failure.
    ///
    /// Group IDs are derived from the session UUID + drawer IDs at generation time.
    /// To validate them we must regenerate the session using the SAME `generatedAt`
    /// timestamp stored in `persisted.generatedAt`. Using a substitute timestamp
    /// produces a different session UUID → different group IDs → incorrect refusals.
    ///
    /// `choiceIndex` is 0 for "Keep the newer record and archive the older one." and
    /// 1 for "Merge content into the newer record and archive the older one."
    private func findValidatedDuplicateGroup(
        groupID: UUID,
        choiceID: UUID,
        drawers: [Drawer],
        persisted: PersistedSession
    ) -> (group: DuplicateGroup, choiceIndex: Int)? {
        let groupIDStr = groupID.uuidString.lowercased()
        let choiceIDStr = choiceID.uuidString.lowercased()

        // Parse the stored generatedAt back to a Date. If this fails, conservatively
        // refuse — we cannot reconstruct the original session ID without the timestamp.
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let generatedAt = fmt.date(from: persisted.generatedAt),
              let kind = ReviewKind(rawValue: persisted.kind) else { return nil }

        // Regenerate the session using the original inputs.
        // The engine is deterministic: same (kind, drawers, generatedAt) → same session UUID
        // → same group IDs and choice IDs.
        let session = CommunityReviewEngine.generateSession(
            kind: kind,
            drawers: drawers,
            now: generatedAt,
            appliedActionIDs: [],
            reversedActionIDs: [],
            completionStatus: .inProgress
        )

        // Find the group.
        guard let group = session.duplicateGroups.first(where: {
            $0.id.uuidString.lowercased() == groupIDStr
        }) else { return nil }

        // Find the choice and return its index (0 = keep-newer, 1 = merge-then-archive).
        guard let choiceIdx = group.choices.firstIndex(where: {
            $0.id.uuidString.lowercased() == choiceIDStr
        }) else { return nil }

        return (group, choiceIdx)
    }

    // MARK: - Dashboard helpers

    /// Derive the ReviewMode for a given kind from the persisted state.
    private func modeFor(kind: ReviewKind, in state: PersistedReviewState) -> ReviewMode {
        let kindRaw = kind.rawValue
        // Find the most recent session for this kind.
        // Priority: inProgress > completed (show the in-progress if exists).
        let kindSessions = state.sessions.filter { $0.value.kind == kindRaw }

        if let (sessionIDStr, _) = kindSessions.first(where: { $0.value.completionState == "inProgress" }) {
            guard let sessionID = UUID(uuidString: sessionIDStr) else {
                return ReviewMode.due(kind: kind)
            }
            return ReviewMode.inProgress(kind: kind, sessionID: sessionID)
        }

        if let (sessionIDStr2, persisted) = kindSessions.first(where: { $0.value.completionState == "completed" }) {
            guard let sessionID = UUID(uuidString: sessionIDStr2),
                  let completedAtStr = persisted.completedAt,
                  let completedAt = parseISO8601(completedAtStr),
                  let summary = persisted.completionSummary
            else {
                return ReviewMode.available(kind: kind)
            }
            let receipt = ReviewCompletionReceipt(
                sessionID: sessionID,
                completedAt: completedAt,
                summary: summary
            )
            return ReviewMode.completed(kind: kind, receipt: receipt)
        }

        // No session exists — review is due.
        return ReviewMode.due(kind: kind)
    }

    // MARK: - Session reconstruction

    /// Reconstruct a ReviewSession from a persisted record.
    ///
    /// Regenerates the session using CommunityReviewEngine with the stored
    /// sourceEstateState and current drawer list, then overlays the persisted
    /// action states (reversalAvailable) and completion status.
    private func buildSessionFromPersisted(
        sessionIDStr: String,
        persisted: PersistedSession,
        kind: ReviewKind,
        drawers: [Drawer]
    ) -> ReviewSession {
        let appliedSet = Set(persisted.appliedActionIDs)
        let reversedSet = Set(persisted.reversedActionIDs)

        let completionStatus: ReviewCompletionStatus
        switch persisted.completionState {
        case "completed":
            if let sessionID = UUID(uuidString: sessionIDStr),
               let completedAtStr = persisted.completedAt,
               let completedAt = parseISO8601(completedAtStr),
               let summary = persisted.completionSummary {
                let receipt = ReviewCompletionReceipt(
                    sessionID: sessionID,
                    completedAt: completedAt,
                    summary: summary
                )
                completionStatus = .completed(receipt: receipt)
            } else {
                completionStatus = .completed(receipt: ReviewCompletionReceipt(
                    sessionID: UUID(uuidString: sessionIDStr) ?? UUID(),
                    completedAt: Date(),
                    summary: "Completed."
                ))
            }
        case "notStarted":
            completionStatus = .notStarted
        default:
            completionStatus = .inProgress
        }

        // Reconstruct "now" from the persisted generatedAt.
        // We use the stored timestamp so that the regenerated session has the
        // SAME id (deterministic: kind + generatedAt + sourceEstateState → sessionID).
        let now = parseISO8601(persisted.generatedAt) ?? Date()

        return CommunityReviewEngine.generateSession(
            kind: kind,
            drawers: drawers,
            now: now,
            appliedActionIDs: appliedSet,
            reversedActionIDs: reversedSet,
            completionStatus: completionStatus
        )
    }

    // MARK: - Completion summary

    private func buildCompletionSummary(kind: String, appliedCount: Int, resolvedCount: Int) -> String {
        var parts: [String] = ["\(kind.capitalized) review completed"]
        if appliedCount > 0 {
            parts.append("with \(appliedCount) action\(appliedCount == 1 ? "" : "s")")
        }
        if resolvedCount > 0 {
            parts.append("and \(resolvedCount) duplicate resolution\(resolvedCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " ") + "."
    }

    // MARK: - ISO8601 parse helper

    /// Parse an ISO8601 string back to a Date.
    ///
    /// Uses the same format options as iso8601Encode() (withFractionalSeconds).
    /// Returns nil if the string cannot be parsed.
    private func parseISO8601(_ str: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: str) { return d }
        // Fallback: without fractional seconds (for strings written before
        // fractional-seconds format was adopted).
        let fmt2 = ISO8601DateFormatter()
        fmt2.formatOptions = [.withInternetDateTime]
        return fmt2.date(from: str)
    }
}
