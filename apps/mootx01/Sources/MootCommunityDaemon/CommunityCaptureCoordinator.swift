// CommunityCaptureCoordinator.swift
//
// Implementation of the two capture-family endpoints (Wave A2b: CORE-04).
//
// ARCHITECTURE
// ─────────────────────────────────────────────────────────────────────
// This actor implements the business logic for:
//   • moot_community_capture_choices  — enumerate destinations + default policy
//   • moot_community_capture          — validate, persist, and return outcome
//
// The coordinator opens its own estate connection (same pattern as
// CommunityEstateLifecycleCoordinator) and manages:
//
//   1. Estate access:   CommunityEstateHost opens the estate.sqlite in the
//                       layout directory. The Estate is held open for the
//                       lifetime of the coordinator (not re-opened on each
//                       call) to avoid connection-per-call overhead.
//
//   2. Capture records: Successful captures are stored as LocusKit Drawers
//                       in the destination room (wing derived from the
//                       destinationID "wing/room" format). The drawer id
//                       becomes the recordID returned to the caller.
//
//   3. Request ledger:  CORE-04 requires durable idempotency — an exact
//                       requestID retry must return the original receipt
//                       even across daemon restarts. The ledger is persisted
//                       as capture-ledger.json in the layout directory.
//                       Format: { "<requestID>": { "recordID": "...", "policy": {...} } }
//                       Written atomically (write to .tmp, then rename) so a
//                       crash mid-write never corrupts the ledger.
//
// FAIL-CLOSED RULES (CORE-04)
// ─────────────────────────────────────────────────────────────────────
// • Unknown/stale destination → refused(destination, destination-stale or destination-forbidden)
// • sensitivity unknown value → refused(sensitivity, capture-content-invalid) [already caught at parse]
// • lanEligible=true with exportEligible=false → refused(lan-eligibility, privacy-escalation)
// • export/LAN flags cannot weaken a sensitivity restriction (secret→no export/LAN)
// • Empty content → refused(content, capture-content-invalid)
// • Estate open failure → failed(unexpected-failure) without raw error details
//
// DESTINATION ID FORMAT
// ─────────────────────────────────────────────────────────────────────
// Destination ids are "wing/room" using the NORMALIZED lookup names
// (Node.normalizeLookupName: NFC + casefold + whitespace-collapse).
// The display names (for title/detail) come from the node display_name column.
//
// Example: wing displayName="Personal", room displayName="capture"
//   → id = "personal/capture"
//   → title = "Personal capture"  (wing title-cased + " " + room displayName)
//   → detail = "Personal"          (wing displayName, context for the room)

import Foundation
import MootProductIdentity
import OSLog
import AriaMCP
import LocusKit

private let log = Logger(subsystem: MootProductIdentity.Logging.subsystem, category: "MootCommunityDaemon.Capture")

private enum CaptureLedgerError: Error {
    case encodingFailed
    case migrationVerificationFailed
}

/// MARK: - Request ledger entry (persisted in capture-ledger.json)

/// A single entry in the durable request ledger.
///
/// Stored as a Codable value so the ledger file survives restarts and round-trips
/// through JSON without losing type information. The `policy` is the full
/// CapturePolicy (including lanEligible which is NOT stored in the Drawer bitmap).
private struct LedgerEntry: Codable, Sendable {
    /// The UUID of the Drawer row written for this request.
    let recordID: String
    /// The resolved effective policy at the time of capture.
    /// Persisted verbatim so retry can return the original policy without
    /// re-querying the estate (which may have mutated the drawer since).
    let destinationID: String
    let sensitivity: String
    let exportEligible: Bool
    let lanEligible: Bool
}

// MARK: - CommunityCaptureCoordinator

/// Implements the capture-family endpoints for the community 1.1 contract.
///
/// Inject one instance into `CommunityContractDispatch` after constructing it
/// with the layout directory and key provider. In production the layout URL is
/// `~/Library/Application Support/MOOTx01/`; in tests it is a per-test temp
/// directory.
///
/// The actor is safe to share across concurrent tool calls — actor isolation
/// serializes all mutable state (estate connection, ledger file).
public actor CommunityCaptureCoordinator: Sendable {

    // MARK: - Properties

    /// The daemon's shared estate host: the catalog record it names and the
    /// one open every coordinator shares.
    private let host: CommunityEstateHost

    /// The daemon's state directory — parent of the ledger sidecar.
    public let layoutURL: URL

    // Derived paths (computed lazily, never stored — paths are not state).
    private var estateURL: URL { host.record.databaseURL }
    private var ledgerURL: URL { layoutURL.appendingPathComponent("capture-ledger.json") }

    // MARK: - Init

    /// Construct a coordinator over the daemon's shared estate host.
    ///
    /// - Parameters:
    ///   - host: The estate host; its record names the estate and its open is
    ///     the one every coordinator shares.
    ///   - layoutURL: The daemon's state directory, which contains (or will
    ///     contain) `capture-ledger.json`. Must already exist.
    public init(host: CommunityEstateHost, layoutURL: URL) {
        self.host = host
        self.layoutURL = layoutURL
    }

    // MARK: - Endpoint: moot_community_capture_choices

    /// Return available capture destinations and the default policy.
    ///
    /// Destinations are derived from the CURRENT canonical estate state:
    /// all non-tombstoned rooms across all wings, ordered alphabetically by
    /// destination id ("wing/room"). Each room → one CaptureDestination.
    ///
    /// The defaultPolicy is private-leaning (CORE-04: never silently widen):
    ///   - destinationID: first destination (alphabetical by id)
    ///   - sensitivity: .restricted
    ///   - exportEligible: false
    ///   - lanEligible: false
    ///
    /// EMPTY-ESTATE SEEDING
    /// ────────────────────
    /// When the estate has no rooms at all, this method seeds the private
    /// default capture inbox ("personal/capture") exactly once before building
    /// the destinations list. Seeding is done here — not in estate_create —
    /// because this seam handles BOTH fresh estates (created via the daemon's
    /// moot_community_estate_create) AND pre-existing empty estates (estates
    /// created via raw LocusKit, migrations, or daemon versions that pre-date
    /// this fix). Seeding is idempotent: subsequent calls find the room in
    /// listRooms() and skip the write path entirely.
    ///
    /// If the estate cannot be opened, returns an empty destinations array
    /// and a sentinel defaultPolicy with destinationID="" — the choices
    /// endpoint is read-only and must not propagate estate errors to callers.
    public func captureChoices() async -> JSONValue {
        let destinations: [CaptureDestination]
        do {
            let estate = try await requireEstate()
            var rooms = try await estate.listRooms()

            // If the estate has no rooms, seed the private default capture inbox
            // ("personal/capture") to guarantee a valid default destination.
            //
            // WHY HERE: seeding in captureChoices() is the ONLY seam that handles
            // both fresh estates (just created via moot_community_estate_create)
            // and pre-existing empty estates (estates from earlier daemon versions
            // or raw LocusKit opens that never seeded). The estate_create path
            // would miss pre-existing empties; a lazy seed here catches all cases.
            //
            // WHY IDEMPOTENT: once the sentinel drawer exists, listRooms() returns
            // "personal/capture" and the `rooms.isEmpty` guard is false. Subsequent
            // calls take the normal read-only path — no duplicate writes possible.
            // Across coordinator restarts, the room persists in estate SQLite.
            if rooms.isEmpty {
                try await seedDefaultCaptureInbox(in: estate)
                // Re-read rooms so the newly-created room appears in the list.
                rooms = try await estate.listRooms()
                log.info("capture_choices: seeded default inbox — estate now has \(rooms.count, privacy: .public) room(s)")
            }

            // Map each (wing, room) pair to a CaptureDestination.
            destinations = rooms
                .map { room in destinationFrom(wing: room.wing, room: room.name) }
                .sorted { $0.id < $1.id }
        } catch {
            log.error("capture_choices: estate access failed: \(error, privacy: .public)")
            // Fail open on choices (read-only endpoint) — return empty destinations
            // rather than an error. The capture endpoint will fail closed if called.
            destinations = []
        }

        // Sensitivities: all four contract-defined levels, in escalating order.
        let sensitivities: [CaptureSensitivity] = [.normal, .elevated, .restricted, .secret]

        // Private-leaning default policy: restricted, no export, no LAN, first destination.
        let defaultDestID = destinations.first?.id ?? ""
        let defaultPolicy = CaptureDefaultPolicy(
            destinationID: defaultDestID,
            sensitivity: .restricted,
            exportEligible: false,
            lanEligible: false
        )

        return CaptureChoices(
            destinations: destinations,
            sensitivities: sensitivities,
            defaultPolicy: defaultPolicy
        ).toJSONValue()
    }

    // MARK: - Endpoint: moot_community_capture

    /// Validate arguments, persist the capture record, and return the outcome.
    ///
    /// CORE-04 validation order (each validated independently, STOP at first refusal):
    ///   1. content must not be empty.
    ///   2. destinationID must exist in the current estate state.
    ///   3. lanEligible=true with exportEligible=false → privacy-escalation refusal.
    ///   4. sensitivity "secret" with exportEligible=true → privacy-escalation refusal.
    ///   5. sensitivity "secret" with lanEligible=true  → privacy-escalation refusal.
    ///
    /// Idempotency: if requestID is already in the ledger AND the payload matches,
    /// the original receipt is returned without writing a new record. If the payload
    /// DIFFERS from the original, request-conflict is returned.
    ///
    /// Persistence: a successful capture writes a Drawer in the destination room
    /// and updates the durable ledger file.
    public func capture(arguments: CaptureArguments) async -> JSONValue {
        let requestKey = arguments.requestID.uuidString.lowercased()

        // ── Idempotency check ────────────────────────────────────────────────
        // The ledger deliberately contains policy metadata only. Exact-retry
        // comparison reads the canonical content from the encrypted estate;
        // no content-derived oracle is persisted in this plaintext sidecar.
        let ledger: [String: LedgerEntry]
        do {
            ledger = try readLedger()
        } catch {
            log.error("capture: ledger migration failed closed: \(error, privacy: .public)")
            return CaptureOutcome.failed(reason: "unexpected-failure").toJSONValue()
        }
        if let existing = ledger[requestKey] {
            guard let recordID = UUID(uuidString: existing.recordID),
                  let sensitivity = CaptureSensitivity(rawValue: existing.sensitivity) else {
                log.error("capture: corrupt ledger entry for requestID \(requestKey, privacy: .public)")
                return CaptureOutcome.failed(reason: "unexpected-failure").toJSONValue()
            }

            do {
                let estate = try await requireEstate()
                guard let storedDrawer = try await estate.allDrawers()
                    .first(where: { $0.id == existing.recordID }) else {
                    log.error("capture: ledger record missing from estate for requestID \(requestKey, privacy: .public)")
                    return CaptureOutcome.failed(reason: "unexpected-failure").toJSONValue()
                }
                guard existingMatchesArguments(existing, drawer: storedDrawer, arguments: arguments) else {
                    return CaptureOutcome.refused(
                        field: .destination,
                        reason: "request-conflict"
                    ).toJSONValue()
                }

                let rooms = try await estate.listRooms()
                let destination = destinations(from: rooms)
                    .first(where: { $0.id == existing.destinationID })
                    ?? destinationFromID(existing.destinationID)
                let policy = CapturePolicy(
                    destination: destination,
                    sensitivity: sensitivity,
                    exportEligible: existing.exportEligible,
                    lanEligible: existing.lanEligible
                )
                return CaptureOutcome.applied(recordID: recordID, effectivePolicy: policy).toJSONValue()
            } catch {
                log.error("capture: exact-retry verification failed: \(error, privacy: .public)")
                return CaptureOutcome.failed(reason: "unexpected-failure").toJSONValue()
            }
        }

        // ── Validation ───────────────────────────────────────────────────────

        // 1. content must not be empty.
        guard !arguments.content.isEmpty else {
            return CaptureOutcome.refused(
                field: .content,
                reason: "capture-content-invalid"
            ).toJSONValue()
        }

        // 2. destination must exist in the current estate.
        let allDestinations: [CaptureDestination]
        let estate: Estate
        do {
            estate = try await requireEstate()
            let rooms = try await estate.listRooms()
            allDestinations = destinations(from: rooms)
        } catch {
            log.error("capture: estate access failed: \(error, privacy: .public)")
            return CaptureOutcome.failed(reason: "unexpected-failure").toJSONValue()
        }

        guard let resolvedDestination = allDestinations.first(where: { $0.id == arguments.destinationID }) else {
            // Destination not found — classify as stale (was known, now gone) vs
            // forbidden (never known). Since we can't distinguish at this phase
            // (no history of known destinations), we use destination-stale for any
            // non-empty id that doesn't resolve, and destination-forbidden for
            // structurally invalid ids (empty or obviously garbage).
            let reason = arguments.destinationID.isEmpty ? "destination-forbidden" : "destination-stale"
            return CaptureOutcome.refused(field: .destination, reason: reason).toJSONValue()
        }

        // 3. lanEligible=true requires exportEligible=true (contract invariant).
        //    LAN eligibility implies the record can leave the local machine via the
        //    LAN sync channel, which is a superset of export eligibility. A record
        //    that cannot be exported cannot be LAN-synced either.
        if arguments.lanEligible && !arguments.exportEligible {
            return CaptureOutcome.refused(
                field: .lanEligibility,
                reason: "privacy-escalation"
            ).toJSONValue()
        }

        // 4. Secret sensitivity prevents export — export would widen privacy.
        if arguments.sensitivity == .secret && arguments.exportEligible {
            return CaptureOutcome.refused(
                field: .exportEligibility,
                reason: "privacy-escalation"
            ).toJSONValue()
        }

        // 5. Secret sensitivity prevents LAN sync — same reasoning as export.
        if arguments.sensitivity == .secret && arguments.lanEligible {
            return CaptureOutcome.refused(
                field: .lanEligibility,
                reason: "privacy-escalation"
            ).toJSONValue()
        }

        // ── Ledger-miss recovery (F10) ───────────────────────────────────────
        //
        // The crash window: estate.capture() succeeds but writeLedger() never
        // runs (process killed, power loss). On retry the ledger has no entry
        // for this requestID, so the idempotency check above already missed.
        //
        // Recovery: before writing a new drawer we query the estate for a
        // drawer stamped with the versioned request binding under
        // "moot_community_capture/{requestKey}/v2/".
        // If found, the previous attempt committed to the estate; we rebuild
        // the ledger entry and return the original receipt without re-capturing.
        //
        // This works because addedBy encodes the requestKey (see CaptureFrame
        // construction below — "moot_community_capture/{requestKey}"). The
        // requestKey is the deterministic lowercase UUID string of requestID,
        // so the query is both stable and unique.
        let addedByPrefix = "moot_community_capture/\(requestKey)"
        let addedByMarker = recoveryMarker(requestKey: requestKey, arguments: arguments)
        do {
            let allDrawers = try await estate.allDrawers()
            if let recovered = allDrawers.first(where: {
                $0.addedBy == addedByPrefix || $0.addedBy.hasPrefix(addedByPrefix + "/v2/")
            }) {
                guard recovered.addedBy == addedByMarker,
                      recovered.content == arguments.content,
                      (recovered.subject ?? "") == arguments.subject,
                      recovered.adjectiveSensitivity == arguments.sensitivity.adjectiveSensitivity,
                      recovered.exportability == (arguments.exportEligible ? .public_ : .private_)
                else {
                    return CaptureOutcome.refused(
                        field: .destination,
                        reason: "request-conflict"
                    ).toJSONValue()
                }
                // The previous attempt committed to the estate. Rebuild the ledger
                // entry so future retries take the fast path, then return the receipt.
                let recoveredEntry = LedgerEntry(
                    recordID: recovered.id,
                    destinationID: arguments.destinationID,
                    sensitivity: arguments.sensitivity.rawValue,
                    exportEligible: arguments.exportEligible,
                    lanEligible: arguments.lanEligible
                )
                var updatedLedger = ledger
                updatedLedger[requestKey] = recoveredEntry
                do {
                    try writeLedger(updatedLedger)
                } catch {
                    log.error("capture: recovered ledger write failed: \(error, privacy: .public)")
                    return CaptureOutcome.failed(reason: "unexpected-failure").toJSONValue()
                }
                let recoveredRecordID = UUID(uuidString: recovered.id) ?? UUID()
                let policy = CapturePolicy(
                    destination: resolvedDestination,
                    sensitivity: arguments.sensitivity,
                    exportEligible: arguments.exportEligible,
                    lanEligible: arguments.lanEligible
                )
                log.info("capture: recovered from ledger-miss, requestID=\(requestKey, privacy: .public) recordID=\(recovered.id, privacy: .public)")
                return CaptureOutcome.applied(recordID: recoveredRecordID, effectivePolicy: policy).toJSONValue()
            }
        } catch {
            // Recovery query failed — proceed with normal capture. If the estate
            // already has the drawer we will write a duplicate, but that is
            // preferable to returning an error for what might be a first attempt.
            log.warning("capture: ledger-miss recovery query failed: \(error, privacy: .public) — proceeding with capture")
        }

        // ── Persist capture record ───────────────────────────────────────────

        // Parse wing and room from the destination id.
        let (wing, room) = parseDestinationID(arguments.destinationID)

        // Build the capture frame. The content is the caller-supplied content;
        // the subject is stored as the LocusKit subject field (progressive recall).
        // exportEligible maps to AdjectiveExportability; lanEligible is ledger-only.
        //
        // addedBy encodes the requestKey so a subsequent ledger-miss recovery
        // can locate this drawer by querying estate.allDrawers() (F10 fix).
        let frame = CaptureFrame(
            content: arguments.content,
            channel: .actuator,   // MCP-driven capture uses the actuator channel
            room: room,
            latticeAnchor: .udc("007"),  // UDC 007 = "Media. Books. Recreation" — general capture
            addedBy: addedByMarker,      // versioned request binding enables exact F10 recovery
            embeddingModelID: "community-capture-v1",
            sensitivity: arguments.sensitivity.adjectiveSensitivity,
            exportability: arguments.exportEligible ? .public_ : .private_,
            wing: wing,
            subject: arguments.subject.isEmpty ? nil : arguments.subject
        )

        let drawer: Drawer
        do {
            // ORDERING (F10): estate.capture() commits BEFORE writeLedger().
            // A crash between these two calls is survivable via ledger-miss
            // recovery (the addedByMarker query above finds the drawer on retry).
            drawer = try await estate.capture(frame)
        } catch {
            log.error("capture: drawer write failed: \(error, privacy: .public)")
            return CaptureOutcome.failed(reason: "unexpected-failure").toJSONValue()
        }

        let recordID = UUID(uuidString: drawer.id) ?? UUID()

        // ── Write ledger entry ────────────────────────────────────────────────

        let policy = CapturePolicy(
            destination: resolvedDestination,
            sensitivity: arguments.sensitivity,
            exportEligible: arguments.exportEligible,
            lanEligible: arguments.lanEligible
        )
        let entry = LedgerEntry(
            recordID: drawer.id,
            destinationID: arguments.destinationID,
            sensitivity: arguments.sensitivity.rawValue,
            exportEligible: arguments.exportEligible,
            lanEligible: arguments.lanEligible
        )
        var updatedLedger = ledger
        updatedLedger[requestKey] = entry
        do {
            try writeLedger(updatedLedger)
        } catch {
            log.error("capture: ledger write failed after estate commit: \(error, privacy: .public)")
            return CaptureOutcome.failed(reason: "unexpected-failure").toJSONValue()
        }

        log.debug("capture: applied requestID=\(requestKey, privacy: .public) recordID=\(drawer.id, privacy: .public)")
        return CaptureOutcome.applied(recordID: recordID, effectivePolicy: policy).toJSONValue()
    }

    // MARK: - Estate access

    /// The shared estate, opened by the host on first use.
    ///
    /// Fail-closed: throws `CommunityDaemonError.estateAbsent` if the record's
    /// database does not exist. The host would create it, and creating the
    /// estate here would bypass the lifecycle `needsCreation` gate (F11 fix):
    /// only the lifecycle `estate_create` endpoint creates.
    ///
    /// Any error from the posture, the storage backend or GeniusLocusKit
    /// propagates to the caller without wrapping — no silent fallback.
    private func requireEstate() async throws -> Estate {
        guard host.databaseExists else {
            log.error("capture requireEstate: estate database not found at \(self.estateURL.path, privacy: .public)")
            throw CommunityDaemonError.estateAbsent(estateURL)
        }
        return try await host.estate()
    }

    // MARK: - Default inbox seeding

    /// Seed the private default capture inbox into a brand-new (empty) estate.
    ///
    /// Called by `captureChoices()` when `estate.listRooms()` returns empty.
    /// Captures a single system-initialization sentinel drawer into the
    /// "personal/capture" wing/room. LocusKit's capture path creates wing
    /// and room nodes on demand (EstateVerbs.captureBatch's createNode calls),
    /// so no explicit node-creation step is needed.
    ///
    /// The sentinel drawer is:
    ///   - wing: "personal"  (normalized: "personal")
    ///   - room: "capture"   (normalized: "capture")
    ///   - sensitivity: .restricted  (private-leaning; matches defaultPolicy)
    ///   - exportability: .private_  (non-exportable; private-leaning)
    ///   - channel: .actuator        (MCP-agent-driven origin)
    ///
    /// This is NOT a user-visible note — it is an implementation artifact that
    /// establishes the room so `listRooms()` has something to enumerate.
    /// The sentinel content marks it as system-origin so diagnostic tools
    /// can distinguish it from user captures.
    ///
    /// Errors propagate to the caller (`captureChoices`), which logs them and
    /// falls back to the empty-destinations path (fail-open for the read-only
    /// choices endpoint).
    private func seedDefaultCaptureInbox(in estate: Estate) async throws {
        // The sentinel frame uses the same defaults as a private user capture:
        //   - UDC 007 = "Media. Books. Recreation" — the general capture anchor
        //     used throughout CommunityCaptureCoordinator for user captures.
        //   - embeddingModelID matches the capture coordinator's standard value
        //     so future indexing passes treat the sentinel like any other drawer.
        //   - addedBy is prefixed "system:" to distinguish it from user captures
        //     in audit logs and diagnostic scans.
        let frame = CaptureFrame(
            content: "system: default capture inbox — initialized by moot_community_capture_choices",
            channel: .actuator,
            room: "capture",
            latticeAnchor: .udc("007"),
            addedBy: "system:capture_choices",
            embeddingModelID: "community-capture-v1",
            sensitivity: .restricted,
            exportability: .private_,
            wing: "personal"
        )
        _ = try await estate.capture(frame)
    }

    // MARK: - Destination helpers

    /// Convert a `RoomSummary` (wing, name) to a `CaptureDestination`.
    ///
    /// id:     "{wing_lookup}/{room_lookup}" — normalized names, lowercase.
    /// title:  "{wing_display} {room_display}" — title-cased combination.
    /// detail: "{wing_display}" — the wing name provides context.
    private func destinationFrom(wing wingName: String, room roomName: String) -> CaptureDestination {
        let wingLookup = Node.normalizeLookupName(wingName)
        let roomLookup = Node.normalizeLookupName(roomName)
        let id = "\(wingLookup)/\(roomLookup)"
        // Title: capitalize first letter of each word in "wing room".
        let title = titleCase("\(wingName) \(roomName)")
        let detail = titleCase(wingName)
        return CaptureDestination(id: id, title: title, detail: detail)
    }

    /// Build a destinations array from a list of room summaries.
    private func destinations(from rooms: [RoomSummary]) -> [CaptureDestination] {
        rooms
            .map { destinationFrom(wing: $0.wing, room: $0.name) }
            .sorted { $0.id < $1.id }
    }

    /// Reconstruct a minimal CaptureDestination from a stored id alone.
    /// Used when a ledger entry references a destination that no longer exists.
    private func destinationFromID(_ id: String) -> CaptureDestination {
        CaptureDestination(id: id, title: id, detail: "")
    }

    /// Parse a destination id of the form "wing/room" into its components.
    /// Returns ("", "") for ids that don't contain "/".
    private func parseDestinationID(_ id: String) -> (wing: String, room: String) {
        let parts = id.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return ("", "") }
        return (String(parts[0]), String(parts[1]))
    }

    /// Title-case a string: capitalize the first letter of each whitespace-separated word.
    private func titleCase(_ s: String) -> String {
        s.split(separator: " ")
            .map { word -> String in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    // MARK: - Ledger persistence

    /// Read the current ledger from disk. Returns an empty dict if the file
    /// doesn't exist or is unparseable (fail-open on read, fail-closed on write).
    private func readLedger() throws -> [String: LedgerEntry] {
        guard let data = try? Data(contentsOf: ledgerURL) else { return [:] }
        guard let decoded = try? JSONDecoder().decode([String: LedgerEntry].self, from: data) else {
            log.warning("capture: ledger parse failed — treating as empty")
            return [:]
        }
        // Older builds persisted a raw SHA-256 content verifier here. Swift's
        // decoder ignores that now-unknown field; rewrite once so an upgraded
        // installation removes the offline content oracle from the sidecar.
        if data.range(of: Data("\"contentHash\"".utf8)) != nil {
            try writeLedger(decoded)
            let migrated = try Data(contentsOf: ledgerURL)
            guard migrated.range(of: Data("\"contentHash\"".utf8)) == nil else {
                throw CaptureLedgerError.migrationVerificationFailed
            }
        }
        return decoded
    }

    /// Write the updated ledger to disk atomically (write to .tmp, then rename).
    ///
    /// Atomic write ensures a crash mid-write never leaves a corrupt ledger.
    /// If the write fails, the existing ledger is preserved (fail-closed for
    /// future retries — the current capture succeeded at the estate level).
    private func writeLedger(_ ledger: [String: LedgerEntry]) throws {
        guard let data = try? JSONEncoder().encode(ledger) else {
            throw CaptureLedgerError.encodingFailed
        }
        let tmpURL = ledgerURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmpURL, options: .atomic)
            // Atomic rename: replaces ledgerURL if it exists, otherwise creates it.
            // Using FileManager.replaceItem for atomicity on macOS.
            _ = try FileManager.default.replaceItemAt(ledgerURL, withItemAt: tmpURL)
        } catch {
            // If replaceItemAt fails (first write, destination doesn't exist yet),
            // fall back to a direct write.
            try data.write(to: ledgerURL, options: .atomic)
            try? FileManager.default.removeItem(at: tmpURL)
        }
    }

    // MARK: - Idempotency helpers

    /// True iff the stored ledger entry matches the given arguments exactly.
    /// Used to distinguish exact retry from request-conflict.
    ///
    /// Policy fields are checked against the ledger; content and subject are
    /// checked against the canonical Drawer inside the encrypted estate.
    private func existingMatchesArguments(
        _ existing: LedgerEntry,
        drawer: Drawer,
        arguments: CaptureArguments
    ) -> Bool {
        existing.destinationID == arguments.destinationID
            && existing.sensitivity == arguments.sensitivity.rawValue
            && existing.exportEligible == arguments.exportEligible
            && existing.lanEligible == arguments.lanEligible
            && drawer.content == arguments.content
            && (drawer.subject ?? "") == arguments.subject
    }

    /// Versioned crash-recovery binding stored inside the encrypted estate.
    /// Content and subject are already present on the Drawer; this marker binds
    /// every remaining request field, including LAN eligibility, that cannot
    /// otherwise be reconstructed after an estate-commit/ledger-write crash.
    private func recoveryMarker(requestKey: String, arguments: CaptureArguments) -> String {
        let binding = [
            arguments.destinationID,
            arguments.sensitivity.rawValue,
            arguments.exportEligible ? "1" : "0",
            arguments.lanEligible ? "1" : "0",
        ].joined(separator: "\0")
        return "moot_community_capture/\(requestKey)/v2/\(Data(binding.utf8).base64EncodedString())"
    }
}
