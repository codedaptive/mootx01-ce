// MaintenanceDecision.swift
//
// The DETERMINISTIC DECISION CORE of the maintenance daemon's cycle
// (NEURONKIT_SPEC § 3.2 + § 3.5 steps 0–5), factored out of
// `MaintenanceDaemon` so it is a pure function of pre-gathered, identity-
// free inputs — no actor, no seam I/O, no clock, no substrate value type.
// This is the Swift side of NeuronKit's Rust-parity Bucket A; the Rust
// version at `NeuronKit/rust/src/maintenance_decision.rs` implements the same
// logic and both gate on shared fixtures.
//
// What stays in the actor: the async seam reads, the I-3 forbidden-combo
// bitmap read on `Drawer` (a substrate type), the GLK-owned
// `AuditChainVerifier.verify` call, the `now`-relative age subtractions,
// the proposal emission, the per-scan `ProposeFrame` + justification
// construction (the kind/justification text is Swift-side, not part of the
// portable contract — same boundary the dreaming port drew), and the
// across-cycle state.
//
// What moves here is every DECISION that does not need a substrate type:
// the six scan-category KEY FORMATS, the SCAN ORDERING into one emission
// list, the threshold predicates (decay/tombstone strict `>`; fingerprint/
// byReference `>=`), the crosser COUNTS, and the B-4 idempotency dedup
// (a key proposed in a prior cycle — or earlier this cycle — is suppressed,
// not re-emitted). Splitting decision from I/O is what makes the daemon's
// behaviour portable and conformance-gateable while the seam-bound actor
// stays Swift-only.

import Foundation

/// Pure maintenance-cycle decision logic shared by the Swift
/// `MaintenanceDaemon` and the Rust version. No substrate types appear in the
/// signatures; ids and scope keys are plain `String`.
public enum MaintenanceDecision {

    /// The scan category a decision came from, so the actor can map it to
    /// the right `ProposalKind` and justification. Order of declaration is
    /// the emission order within a cycle.
    public enum Category: String, Sendable, Equatable {
        case auditIntegrity
        case disciplineViolation
        case decay
        case tombstone
        case fingerprintDrift
        case byReferenceDrift
    }

    /// One emit decision: the idempotency `key`, the proposal `target`
    /// RowID, the `category`, and an optional raw `detailValue` — the drift
    /// fraction for the two drift categories, `nil` otherwise. The actor
    /// turns each into a `ProposeFrame` with the category's kind and a
    /// justification built from `target` + `detailValue` (audit's
    /// entry-count comes from the actor's in-scope `auditReport`).
    /// `detailValue` is a raw number, not formatted text, so the Rust version
    /// carries the identical value through the portable contract.
    public struct Decision: Sendable, Equatable {
        public let key: String
        public let target: String
        public let category: Category
        public let detailValue: Float?
        public init(key: String, target: String, category: Category, detailValue: Float? = nil) {
            self.key = key
            self.target = target
            self.category = category
            self.detailValue = detailValue
        }
    }

    /// The audit-chain monitor's pre-computed verdict for this cycle
    /// (step 0). The actor runs `AuditChainVerifier.verify` (GLK-owned
    /// math) and passes the result in; `nil` means the audit-check cadence
    /// had not elapsed this cycle, so no audit decision is made.
    public struct AuditVerdict: Sendable, Equatable {
        public let valid: Bool
        /// Epoch milliseconds of the first broken entry, when the verifier
        /// supplied one. `nil` falls back to the `"unknown"` stable tag so
        /// a break is never lost and re-detects to the same key.
        public let firstBrokenAtMillis: Int64?
        public init(valid: Bool, firstBrokenAtMillis: Int64?) {
            self.valid = valid
            self.firstBrokenAtMillis = firstBrokenAtMillis
        }
    }

    /// An id paired with an age in seconds (the actor computes the age as
    /// `now - filedAt` / `now - tombstonedAt`), the input to the decay and
    /// tombstone threshold scans.
    public struct AgedRow: Sendable, Equatable {
        public let id: String
        public let ageSeconds: Double
        public init(id: String, ageSeconds: Double) {
            self.id = id
            self.ageSeconds = ageSeconds
        }
    }

    /// A scope/reference key paired with a drift fraction in `[0, 1]`, the
    /// input to the fingerprint-drift and byReference-validity scans.
    public struct DriftRow: Sendable, Equatable {
        public let key: String
        public let driftFraction: Float
        public init(key: String, driftFraction: Float) {
            self.key = key
            self.driftFraction = driftFraction
        }
    }

    /// The cycle's decisions. `emitted` is in scan order (audit, forbidden,
    /// decay, tombstone, fingerprint, byReference); the `*Candidates`
    /// counts are threshold-crossers (counted whether or not the B-4
    /// dedup suppressed them — matching the daemon's report semantics).
    public struct Outcome: Sendable, Equatable {
        public let emitted: [Decision]
        public let suppressedDuplicates: Int
        public let forbiddenCombinations: Int
        public let decayCandidates: Int
        public let tombstoneCandidates: Int
        public let fingerprintDrifts: Int
        public let byReferenceDrifts: Int
        public let updatedProposedKeys: Set<String>
    }

    /// The stable broken-entry tag used in the audit-integrity key and
    /// target: the first-broken epoch-milliseconds string, or `"unknown"`.
    public static func brokenTag(_ firstBrokenAtMillis: Int64?) -> String {
        firstBrokenAtMillis.map(String.init) ?? "unknown"
    }

    /// Decide one maintenance cycle over pre-gathered inputs (steps 0–5).
    ///
    /// - `audit`: the audit verdict when the chain was checked this cycle,
    ///   else `nil`. An invalid chain emits one audit-integrity decision.
    /// - `forbiddenDrawerIDs`: ids of active drawers failing invariant I-3
    ///   (the actor computed the secret-AND-public bitmap predicate), in
    ///   scan order.
    /// - `agedActive`: `(id, ageSeconds)` for active drawers; a row emits a
    ///   decay decision when `ageSeconds > decayWindowSeconds` (strict).
    /// - `agedTombstoned`: `(id, tombstoneAgeSeconds)` for tombstoned rows;
    ///   emits an expunge decision when `> tombstoneGraceSeconds` (strict).
    /// - `fingerprintDrift` / `referenceDrift`: `(key, driftFraction)`;
    ///   emits when `driftFraction >= threshold` (inclusive).
    /// - `alreadyProposedKeys`: keys proposed in a prior cycle (B-4).
    ///
    /// A crosser whose key is already proposed (in a prior cycle, or
    /// earlier this cycle) is suppressed and counted in
    /// `suppressedDuplicates` but still counted as a crosser in its
    /// category total — mirroring the actor's count-then-register order.
    public static func decide(
        audit: AuditVerdict?,
        forbiddenDrawerIDs: [String],
        agedActive: [AgedRow],
        decayWindowSeconds: Double,
        agedTombstoned: [AgedRow],
        tombstoneGraceSeconds: Double,
        fingerprintDrift: [DriftRow],
        fingerprintDriftThreshold: Float,
        referenceDrift: [DriftRow],
        byReferenceDriftThreshold: Float,
        alreadyProposedKeys: Set<String>
    ) -> Outcome {
        var emitted: [Decision] = []
        var suppressed = 0
        var proposed = alreadyProposedKeys

        // register(key:) — insert and report whether it was new. A key
        // already seen (prior cycle or earlier this cycle) is suppressed.
        func register(_ key: String) -> Bool {
            if proposed.contains(key) { return false }
            proposed.insert(key)
            return true
        }

        func consider(key: String, target: String, category: Category, detailValue: Float? = nil) {
            if register(key) {
                emitted.append(Decision(
                    key: key, target: target, category: category, detailValue: detailValue))
            } else {
                suppressed += 1
            }
        }

        // ── Step 0: audit-chain integrity ──────────────────────────────
        if let audit, !audit.valid {
            let tag = brokenTag(audit.firstBrokenAtMillis)
            consider(
                key: "audit_integrity|\(tag)",
                target: "audit-break-\(tag)",
                category: .auditIntegrity)
        }

        // ── Step 1: forbidden-combination scan (invariant I-3) ─────────
        let forbiddenCombinations = forbiddenDrawerIDs.count
        for id in forbiddenDrawerIDs {
            consider(key: "discipline|\(id)", target: id, category: .disciplineViolation)
        }

        // ── Step 2: decay-candidate scan (strict age > window) ─────────
        var decayCandidates = 0
        for row in agedActive where row.ageSeconds > decayWindowSeconds {
            decayCandidates += 1
            consider(key: "decay|\(row.id)", target: row.id, category: .decay)
        }

        // ── Step 3: tombstone/expunge scan (strict age > grace) ────────
        var tombstoneCandidates = 0
        for row in agedTombstoned where row.ageSeconds > tombstoneGraceSeconds {
            tombstoneCandidates += 1
            consider(key: "tombstone|\(row.id)", target: row.id, category: .tombstone)
        }

        // ── Step 4: fingerprint-drift scan (inclusive drift >= thresh) ─
        var fingerprintDrifts = 0
        for row in fingerprintDrift where row.driftFraction >= fingerprintDriftThreshold {
            fingerprintDrifts += 1
            consider(
                key: "fingerprint_drift|\(row.key)", target: row.key,
                category: .fingerprintDrift, detailValue: row.driftFraction)
        }

        // ── Step 5: byReference-validity scan (inclusive drift >= thresh)
        var byReferenceDrifts = 0
        for row in referenceDrift where row.driftFraction >= byReferenceDriftThreshold {
            byReferenceDrifts += 1
            consider(
                key: "byref|\(row.key)", target: row.key,
                category: .byReferenceDrift, detailValue: row.driftFraction)
        }

        return Outcome(
            emitted: emitted,
            suppressedDuplicates: suppressed,
            forbiddenCombinations: forbiddenCombinations,
            decayCandidates: decayCandidates,
            tombstoneCandidates: tombstoneCandidates,
            fingerprintDrifts: fingerprintDrifts,
            byReferenceDrifts: byReferenceDrifts,
            updatedProposedKeys: proposed)
    }
}
