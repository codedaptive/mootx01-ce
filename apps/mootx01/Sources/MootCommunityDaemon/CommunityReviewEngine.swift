// CommunityReviewEngine.swift
//
// Pure, deterministic review session generator (Wave B1: CORE-05).
//
// DETERMINISM CONTRACT
// ────────────────────────────────────────────────────────────────────────
// Given the same (kind, drawers, now) inputs, generateSession() always
// produces a byte-identical ReviewSession. No random(), no Date(), no
// UUIDs from UUID(). All IDs are derived via SHA-256 keyed by a fixed
// review namespace.
//
// This determinism is the foundation for Swift/Rust parity: the shared
// canonical vector files (testdata/review-vectors/*.json) contain exact
// expected sessions that BOTH the Swift and Rust implementations must
// produce from the same input. If either deviates, the vector test fails.
//
// ID DERIVATION
// ────────────────────────────────────────────────────────────────────────
// All IDs use reviewDerivedID(): SHA-256(namespaceBytes + inputUTF8),
// first 16 bytes, with UUID version 5 (0x50) and variant 0x80 bits set.
// The namespace is the fixed UUID 4c6f7257-5265-7669-6577-000000000001
// (encodes "LocuRevi" + zeros). Component inputs are joined with "\0"
// (NULL byte) to prevent prefix collisions.
//
// SOURCEESTATESTATE
// ────────────────────────────────────────────────────────────────────────
// Format: "sha256:{32hexchars}:{activeCount}"
// Hash input: active drawer IDs sorted alphabetically, joined by "\n".
// This gives a compact, stable fingerprint for staleness detection.
// An empty estate produces "sha256:{sha256ofempty}:0".
//
// SECTION GENERATION (per kind)
// ────────────────────────────────────────────────────────────────────────
// morning:   ONE section "First priorities" — active drawers sorted by
//            filedAt DESC, then by id ASC for equal timestamps.
//            Limit: min(activeCount, 20) — cap to keep sessions bounded.
//
// endOfDay:  ONE section "Today's items" — same drawers, same ordering.
//
// weekly:    ONE section "This week's items" — same drawers, same ordering.
//
// This keeps section generation simple and deterministic. Future waves may
// add kind-specific filtering (today's drawers vs. all-time, etc.).
//
// ACTIONS
// ────────────────────────────────────────────────────────────────────────
// One action per active drawer (across all sections, deduplicated by
// drawer id). Actions are sorted by drawer id for stable ordering.
// expectedEffect: "Mark '{drawerSubjectOrID}' as reviewed."
// isReversible: true (all review mark actions are reversible).
// reversalAvailable: injected by the coordinator from durable state
//                    (false at initial generation time).
//
// DUPLICATE DETECTION
// ────────────────────────────────────────────────────────────────────────
// Same-subject detection: drawers whose normalised subject (lowercased,
// whitespace-collapsed, NFC) is identical. Groups of 2+.
// Reason: "Records share the same canonical subject."
// Choices: two daemon-owned choices:
//   1. "Keep the newer record and archive the older one."
//   2. "Merge content into the newer record and archive the older one."
//
// Content-identity detection: drawers whose content (trimmed) is byte-identical.
// Reason: "Records have identical content."
// Same two choices as above.
//
// A drawer may appear in at most one duplicate group (first match wins).

import Foundation
import CryptoKit
import LocusKit

// MARK: - CommunityReviewEngine

/// Pure, deterministic review session generator.
///
/// This type has no stored state. All methods are static. The only inputs
/// are the estate drawers and the explicit `now` timestamp — no Date(),
/// no randomness inside the engine.
public enum CommunityReviewEngine {

    // MARK: - Fixed namespace UUID (do not change — changing breaks B2 Rust parity)

    /// Fixed namespace for review-family ID derivation.
    ///
    /// Bytes: 4c 6f 72 57 52 65 76 69 65 77 00 00 00 00 00 01
    /// ("LocuRevi" + "ew" + zeros). Changing this value breaks all
    /// existing canonical vectors and the Rust parity contract.
    private static let reviewNamespaceBytes: [UInt8] = [
        0x4c, 0x6f, 0x72, 0x57, 0x52, 0x65, 0x76, 0x69,
        0x65, 0x77, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    ]

    // MARK: - Public entry point

    /// Generate a deterministic review session from estate drawers and a now timestamp.
    ///
    /// - Parameters:
    ///   - kind: The review kind (morning / endOfDay / weekly).
    ///   - drawers: ALL drawers from the estate (tombstoned drawers are filtered here).
    ///   - now: The explicit current timestamp. NEVER pass Date() internally.
    ///   - appliedActionIDs: Set of action IDs already applied (from durable state).
    ///                       Used to set reversalAvailable on actions.
    ///   - reversedActionIDs: Set of action IDs that were applied then reversed.
    ///                        If an ID is in reversedActionIDs, reversalAvailable = false.
    ///   - completionStatus: The current completion status from durable state.
    /// - Returns: A ReviewSession with deterministic IDs and content.
    public static func generateSession(
        kind: ReviewKind,
        drawers: [Drawer],
        now: Date,
        appliedActionIDs: Set<String> = [],
        reversedActionIDs: Set<String> = [],
        completionStatus: ReviewCompletionStatus = .inProgress
    ) -> ReviewSession {

        // Filter to active drawers: non-tombstoned AND not system-origin.
        //
        // System-origin drawers (addedBy prefixed "system:") are implementation
        // artifacts — e.g. the "personal/capture" sentinel seeded by
        // CommunityCaptureCoordinator when the estate has no rooms. They must
        // not appear in review sessions, appear as review actions, or form
        // duplicate groups. The "system:" prefix is the canonical marker for
        // drawers that must remain invisible to users (F11 fix).
        let activeDrawers = drawers
            .filter { $0.tombstonedAt == nil && !$0.addedBy.hasPrefix("system:") }

        // Compute the estate fingerprint from active drawers.
        let sourceEstateState = estateFingerprint(activeDrawers: activeDrawers)

        // Derive the session ID deterministically.
        // Components: kind + ISO8601(now) + sourceEstateState
        let nowISO = iso8601Encode(now)
        let sessionID = deriveID(
            "session",
            kind.rawValue,
            nowISO,
            sourceEstateState
        )

        // Build sections based on kind (same algorithm, different titles).
        let sectionTitle = sectionTitleFor(kind: kind)

        // Sort drawers for deterministic item ordering:
        // primary: filedAt descending (newest first), secondary: id ascending.
        let sortedDrawers = activeDrawers
            .sorted { lhs, rhs in
                if lhs.filedAt != rhs.filedAt { return lhs.filedAt > rhs.filedAt }
                return lhs.id < rhs.id
            }
            // Cap to 20 items per session to keep sessions bounded.
            .prefix(20)

        // Build items from sorted drawers.
        // CANONICAL UUID FORMAT: all UUID-to-string conversions in derivations use
        // lowercased() for Rust parity (Python's str(uuid) and Rust's uuid::to_string()
        // both produce lowercase). Using uppercase (Swift's default .uuidString) would
        // produce different SHA-256 hashes and break the canonical vector files.
        let sectionUUID = deriveID("section", sessionID.uuidString.lowercased(), sectionTitle)
        let items: [ReviewItem] = sortedDrawers.enumerated().map { (idx, drawer) in
            let itemID = deriveID("item", sectionUUID.uuidString.lowercased(), drawer.id, String(idx))
            // Subject: use the drawer's subject field if non-empty, else content prefix.
            let subject = drawerSubject(drawer)
            // Detail: content preview (first 120 chars, trimmed).
            let detail = String(drawer.content.prefix(120)).trimmingCharacters(in: .whitespaces)
            return ReviewItem(id: itemID, subject: subject, detail: detail)
        }

        let section = ReviewSection(id: sectionUUID, title: sectionTitle, items: Array(items))
        let sections = items.isEmpty ? [] : [section]

        // Build one action per active drawer (sorted by drawer id for stability).
        let actionDrawers = activeDrawers.sorted { $0.id < $1.id }.prefix(20)
        let actions: [ReviewAction] = actionDrawers.map { drawer in
            // Use lowercase session ID string — see canonical UUID format comment above.
            let actionID = deriveID("action", sessionID.uuidString.lowercased(), drawer.id)
            let actionIDStr = actionID.uuidString.lowercased()
            let subject = drawerSubject(drawer)
            // reversalAvailable = true iff the action is in appliedActionIDs
            //                     AND not in reversedActionIDs.
            let isApplied = appliedActionIDs.contains(actionIDStr)
            let isReversed = reversedActionIDs.contains(actionIDStr)
            let reversalAvailable = isApplied && !isReversed
            return ReviewAction(
                id: actionID,
                expectedEffect: "Mark '\(subject)' as reviewed.",
                isReversible: true,
                reversalAvailable: reversalAvailable
            )
        }

        // Detect duplicate groups.
        let duplicateGroups = detectDuplicates(
            activeDrawers: activeDrawers,
            sessionID: sessionID
        )

        return ReviewSession(
            id: sessionID,
            kind: kind,
            generatedAt: now,
            sourceEstateState: sourceEstateState,
            sections: sections,
            actions: Array(actions),
            duplicateGroups: duplicateGroups,
            completionStatus: completionStatus
        )
    }

    // MARK: - Estate fingerprint

    /// Compute a stable fingerprint of the active estate drawers.
    ///
    /// Input: active drawer IDs sorted alphabetically, joined by "\n".
    /// Output: "sha256:{32hexchars}:{activeCount}"
    ///
    /// An empty estate produces "sha256:{hash_of_empty_string}:0".
    /// Changing just one drawer ID produces a completely different fingerprint,
    /// so staleness detection is precise.
    public static func estateFingerprint(activeDrawers: [Drawer]) -> String {
        let sortedIDs = activeDrawers.map(\.id).sorted()
        let joined = sortedIDs.joined(separator: "\n")
        let hash = SHA256.hash(data: Data(joined.utf8))
        // Use the full 32-byte (64 hex-char) SHA-256 digest for collision resistance.
        // Only the first 32 hex chars (16 bytes) to keep the string compact.
        let hexStr = hash.map { String(format: "%02x", $0) }.joined().prefix(32)
        return "sha256:\(hexStr):\(activeDrawers.count)"
    }

    // MARK: - Deterministic UUID derivation

    /// Derive a deterministic UUID from variadic string components.
    ///
    /// Algorithm: SHA-256(namespaceBytes + inputUTF8) where input is
    /// components joined by "\0". First 16 bytes form the UUID body;
    /// version bits 4-7 of byte 6 = 0x50 (version 5); variant bits 6-7
    /// of byte 8 = 0x80 (RFC 4122).
    ///
    /// This is a UUID v5-like derivation using SHA-256 instead of SHA-1,
    /// for consistency with the Rust implementation (ring/sha2).
    public static func deriveID(_ components: String...) -> UUID {
        let input = components.joined(separator: "\0")
        var hasher = SHA256()
        hasher.update(data: reviewNamespaceBytes)
        hasher.update(data: Data(input.utf8))
        let digest = hasher.finalize()
        var bytes = Array(digest.prefix(16))
        // Set UUID version 5 marker: high nibble of byte 6 = 0x5
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        // Set UUID variant RFC 4122: high two bits of byte 8 = 0b10
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Private helpers

    /// Return the section title for a given review kind.
    private static func sectionTitleFor(kind: ReviewKind) -> String {
        switch kind {
        case .morning:   return "First priorities"
        case .endOfDay:  return "Today's items"
        case .weekly:    return "This week's items"
        }
    }

    /// Extract a display subject from a Drawer.
    ///
    /// Uses the drawer's subject field if non-empty; falls back to the
    /// first 60 characters of content (trimmed). This provides a
    /// consistent, human-readable label for review items and actions.
    static func drawerSubject(_ drawer: Drawer) -> String {
        if let subject = drawer.subject, !subject.isEmpty {
            return subject
        }
        // Fallback: content prefix (trimmed to 60 chars).
        let preview = String(drawer.content.prefix(60)).trimmingCharacters(in: .whitespaces)
        return preview.isEmpty ? drawer.id : preview
    }

    // MARK: - Duplicate detection

    /// Detect duplicate groups among active drawers.
    ///
    /// Two detection strategies, applied in order:
    ///   1. Same-subject: drawers with the same normalised subject string.
    ///      Reason: "Records share the same canonical subject."
    ///   2. Content-identity: drawers with byte-identical trimmed content.
    ///      Reason: "Records have identical content."
    ///
    /// A drawer may appear in at most one group (first match wins — same-subject
    /// is checked before content-identity). Groups with < 2 members are discarded.
    ///
    /// Two resolution choices are emitted for every group:
    ///   • "Keep the newer record and archive the older one."
    ///   • "Merge content into the newer record and archive the older one."
    private static func detectDuplicates(
        activeDrawers: [Drawer],
        sessionID: UUID
    ) -> [DuplicateGroup] {

        var usedIDs = Set<String>()
        var groups: [DuplicateGroup] = []

        // Strategy 1: same normalised subject.
        var subjectBuckets: [String: [Drawer]] = [:]
        for drawer in activeDrawers {
            let sub = drawerSubject(drawer)
            let key = normalizeSubject(sub)
            if !key.isEmpty {
                subjectBuckets[key, default: []].append(drawer)
            }
        }
        for (_, bucket) in subjectBuckets.sorted(by: { $0.key < $1.key }) {
            guard bucket.count >= 2 else { continue }
            // Only include drawers not already in a group.
            let candidates = bucket.filter { !usedIDs.contains($0.id) }
            guard candidates.count >= 2 else { continue }
            let group = makeGroup(
                drawers: candidates,
                reason: "Records share the same canonical subject.",
                sessionID: sessionID
            )
            candidates.forEach { usedIDs.insert($0.id) }
            groups.append(group)
        }

        // Strategy 2: identical content (trimmed).
        var contentBuckets: [String: [Drawer]] = [:]
        for drawer in activeDrawers {
            guard !usedIDs.contains(drawer.id) else { continue }
            let key = drawer.content.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                contentBuckets[key, default: []].append(drawer)
            }
        }
        for (_, bucket) in contentBuckets.sorted(by: { $0.key < $1.key }) {
            guard bucket.count >= 2 else { continue }
            let group = makeGroup(
                drawers: bucket,
                reason: "Records have identical content.",
                sessionID: sessionID
            )
            bucket.forEach { usedIDs.insert($0.id) }
            groups.append(group)
        }

        // Sort groups by their id for deterministic ordering.
        return groups.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Build a DuplicateGroup from a set of candidate drawers.
    ///
    /// Group id is derived from session id + sorted drawer ids.
    /// Drawers are sorted by filedAt desc (newest first) within the group;
    /// ties broken by id asc.
    private static func makeGroup(
        drawers: [Drawer],
        reason: String,
        sessionID: UUID
    ) -> DuplicateGroup {
        // Sort for deterministic recordIDs ordering: newest first.
        let sorted = drawers.sorted {
            if $0.filedAt != $1.filedAt { return $0.filedAt > $1.filedAt }
            return $0.id < $1.id
        }
        let recordIDs = sorted.compactMap { UUID(uuidString: $0.id) }

        // Group id derived from session + sorted drawer ids.
        // Use lowercase sessionID.uuidString — see canonical UUID format note in generateSession.
        let idInput = ["group", sessionID.uuidString.lowercased()] + sorted.map(\.id)
        let groupID = deriveID(idInput.joined(separator: "\0"))

        // Two daemon-owned resolution choices.
        // Use lowercase groupID.uuidString for the same reason.
        let choice1Desc = "Keep the newer record and archive the older one."
        let choice2Desc = "Merge content into the newer record and archive the older one."
        let choice1 = DuplicateResolutionChoice(
            id: deriveID("choice", groupID.uuidString.lowercased(), choice1Desc),
            description: choice1Desc
        )
        let choice2 = DuplicateResolutionChoice(
            id: deriveID("choice", groupID.uuidString.lowercased(), choice2Desc),
            description: choice2Desc
        )

        return DuplicateGroup(
            id: groupID,
            reason: reason,
            recordIDs: recordIDs,
            choices: [choice1, choice2]
        )
    }

    /// Normalise a subject string for duplicate-detection comparison.
    ///
    /// NFC + lowercase + whitespace-collapse. Mirrors LocusKit's
    /// Node.normalizeLookupName but applied to subject strings.
    private static func normalizeSubject(_ subject: String) -> String {
        subject
            .precomposedStringWithCanonicalMapping  // NFC
            .lowercased()
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Overloaded deriveID for array input (internal use only)

    /// Derive an ID from a pre-joined input string (avoids variadic overhead).
    private static func deriveID(_ joined: String) -> UUID {
        var hasher = SHA256()
        hasher.update(data: reviewNamespaceBytes)
        hasher.update(data: Data(joined.utf8))
        let digest = hasher.finalize()
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
