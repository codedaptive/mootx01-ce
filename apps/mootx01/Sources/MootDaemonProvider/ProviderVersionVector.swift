import Foundation
import AriaMCP

// MARK: - MACD-3B1 — Schema-3 provider version vector (dark Wave 1)
//
// The schema-3 descriptor extends schema-2 with a companion ProviderVersionVector
// that encodes four compatibility axes (management revision range, data-plane
// revision range, estate schema range, and capability revisions) plus a monotonic
// providerReleaseGeneration that prevents cross-distribution downgrade.
//
// Wave 1 constraint: the daemon bundle installs DISABLED and ProviderShell exits
// with code 4 (residentUnavailable) in production, so no schema-3 descriptor is
// ever published to a real on-disk path before Wave 2 authorises the routing flip.
// DaemonContract.schemaVersion remains 2 (an independent app-side literal); its
// refusal of schema-3 descriptors is correct dark behaviour.
//
// MAC architecture (R1/R2):
//   schema-3 MAC input = CanonicalEncoder.appendBytes(descriptor.macInput()) THEN
//   the 7 wire scalar fields appended via appendWire1Fields.
//   CanonicalEncoder.appendBytes prepends a 4-byte UInt32 big-endian length before
//   the payload, so the complete MAC message byte layout is:
//     [UInt32(len of macInput) BE | macInput bytes | 7×UInt64 fields]
//   NOT a raw concatenation of macInput and the scalar fields.
//   Wave-2 implementers verifying schema-3 MACs MUST reproduce this layout exactly
//   using appendBytes — feeding raw macInput() bytes without the length prefix
//   produces a different HMAC input and silent verification failure on every descriptor.
//
//   migrationTargetSchema and capabilityRevisions live in the Swift type for the
//   evaluator and Wave 2 MAC extension, but are NOT part of the Wave 1 MAC or
//   JSON wire format. Wave 2 will append them after the existing 7-field tail
//   (same additive-tail discipline as MACD-2c2).
//
// JSON wire format (schema 3):
//   The 16 schema-2 keys plus 7 new scalar keys (provisonReleaseGeneration as
//   decimal string; the six revision/schema range fields as integers).

// MARK: - Release generation constant

/// The compile-time provider release generation.
///
/// Both shells (mootx01-daemon and Mootx01-DaemonProviderHelper-macOS) link
/// MootDaemonProvider as a library product.  A `let` constant here is structurally
/// guaranteed to be identical across both binaries — parallel copies fail if this
/// diverges, which they cannot for a module-level constant (D2).
///
/// The generation is included in digestInput() as an additive tail (see ProviderShell)
/// and in the schema-3 MAC via ProviderVersionVector.appendWire1Fields.  Bumping
/// this constant is a release-train increment, never a field-specific patch.
///
/// The value `1` is the first generation of the schema-3 version-vector contract.
/// Any build that ships schema-3 capability for the first time in this release
/// train carries generation 1.  The next distinct train carries 2, and so on.
public let providerReleaseGenerationConstant: UInt64 = 1

// MARK: - ProviderVersionVector

/// The schema-3 companion value type that extends a `FirstPartyDescriptor` with
/// the four compatibility axes required for coexistence arbitration.
///
/// **Companion semantics:** this is NOT a wrapper or shim around
/// `FirstPartyDescriptor`.  It has its own field set, its own MAC contribution
/// function, its own encodability gate, and its own evaluator.  It travels
/// alongside a `FirstPartyDescriptor` through `DescriptorPublisher.encode/decode`
/// and is separately persisted in the 7 new JSON wire keys.
///
/// **Wave 1 wire fields (7):** providerReleaseGeneration, managementRevisionMinimum,
/// managementRevisionMaximum, dataPlaneRevisionMinimum, dataPlaneRevisionMaximum,
/// estateSchemaMinimum, estateSchemaMaximum.  All are required in schema-3 JSON.
///
/// **Wave 1 MAC fields:** the same 7 scalar fields, in the fixed order defined by
/// `appendWire1Fields`.  `migrationTargetSchema` and `capabilityRevisions` are
/// Swift-type fields for the evaluator and Wave 2 MAC extension but do NOT
/// participate in the Wave 1 MAC or JSON (they are always nil / empty in Wave 1).
public struct ProviderVersionVector: Sendable, Equatable {

    // MARK: Module constant

    /// The compile-time release generation for this module.  Exposed on the type
    /// so callers can reference it without knowing the module-level constant name.
    public static let releaseGeneration: UInt64 = providerReleaseGenerationConstant

    // MARK: Wire fields (schema-3 JSON + Wave 1 MAC)

    /// Cross-distribution downgrade prevention.  Two distribution forms of the
    /// same release carry the same generation.  A higher generation is NECESSARY
    /// to replace a running owner — never SUFFICIENT on its own.
    public let providerReleaseGeneration: UInt64

    /// Lowest management-protocol revision this binary can authenticate and execute.
    /// The management plane is smaller and more stable than the data plane; this
    /// range covers discovery and handover negotiation.
    public let managementRevisionMinimum: UInt64

    /// Highest management-protocol revision this binary implements.
    public let managementRevisionMaximum: UInt64

    /// Lowest first-party client/daemon (data-plane) revision this binary can serve.
    /// Seeded from `FirstPartyAuthProtocol.contractRevision` at module build time (D5).
    public let dataPlaneRevisionMinimum: UInt64

    /// Highest first-party client/daemon revision this binary implements.
    public let dataPlaneRevisionMaximum: UInt64

    /// Lowest estate-schema version this binary can safely open.
    public let estateSchemaMinimum: UInt64

    /// Highest estate-schema version this binary can safely open without a migration.
    public let estateSchemaMaximum: UInt64

    // MARK: Swift-type fields (evaluator + Wave 2 MAC extension, NOT in Wave 1 wire format)

    /// Optional one-way forward-migration target schema.  Non-nil only when this
    /// binary can produce a forward migration from the current estate schema to a
    /// newer one.  NOT part of the Wave 1 JSON wire format or MAC; Wave 2 will
    /// append it to the MAC tail after the 7 scalar fields.
    public let migrationTargetSchema: UInt64?

    /// Opaque capability-identifier to semantic-revision map.  A client checks this
    /// before relying on a capability's specific behaviour.  NOT part of the Wave 1
    /// JSON wire format or MAC; Wave 2 will append it via `CanonicalEncoder.appendSortedMap`.
    public let capabilityRevisions: [String: UInt64]

    // MARK: Memberwise initialiser

    /// Memberwise initialiser.  The explicit listing is intentional — adding a field
    /// is a compile-time break at every construction site rather than a silent default.
    public init(
        providerReleaseGeneration: UInt64,
        managementRevisionMinimum: UInt64,
        managementRevisionMaximum: UInt64,
        dataPlaneRevisionMinimum: UInt64,
        dataPlaneRevisionMaximum: UInt64,
        estateSchemaMinimum: UInt64,
        estateSchemaMaximum: UInt64,
        migrationTargetSchema: UInt64?,
        capabilityRevisions: [String: UInt64]
    ) {
        self.providerReleaseGeneration = providerReleaseGeneration
        self.managementRevisionMinimum = managementRevisionMinimum
        self.managementRevisionMaximum = managementRevisionMaximum
        self.dataPlaneRevisionMinimum = dataPlaneRevisionMinimum
        self.dataPlaneRevisionMaximum = dataPlaneRevisionMaximum
        self.estateSchemaMinimum = estateSchemaMinimum
        self.estateSchemaMaximum = estateSchemaMaximum
        self.migrationTargetSchema = migrationTargetSchema
        self.capabilityRevisions = capabilityRevisions
    }

    // MARK: Module default

    /// The version vector for the current build of MootDaemonProvider.
    ///
    /// Management range 1..1: the only management revision this Wave-1 binary
    /// implements.  Data-plane range seeded from `contractRevision` (2..2) per D5.
    /// Estate schema range 1..1: consistent with ProofEstate.schemaVersion and the
    /// current DrawerStore base (D3 discovery — discrepancy deferred to Wave 2).
    /// No forward migration yet; empty capability-revision map for Wave 1.
    public static let current = ProviderVersionVector(
        providerReleaseGeneration: releaseGeneration,
        managementRevisionMinimum: 1,
        managementRevisionMaximum: 1,
        // Seeds from FirstPartyAuthProtocol.contractRevision (= 2). Using the
        // constant value directly rather than a runtime reference so this struct
        // stays purely value-typed with no module-init dependency.
        dataPlaneRevisionMinimum: 2,
        dataPlaneRevisionMaximum: 2,
        estateSchemaMinimum: 1,
        estateSchemaMaximum: 1,
        migrationTargetSchema: nil,
        capabilityRevisions: [:]
    )

    // MARK: Encodability gate

    /// Whether every field can be canonically encoded.
    ///
    /// `capabilityRevisions.count` must fit in a `UInt32` because the map is
    /// length-prefixed with a 4-byte count in the Wave 2 MAC encoding.  Missing
    /// this check before canonicalisation is a pre-MAC denial-of-service: a count
    /// that overflows UInt32 would produce a malformed length prefix.
    ///
    /// The 7 scalar `UInt64` fields have no overflow risk — they are always
    /// representable as 8-byte big-endian integers.
    public var hasEncodableFieldWidths: Bool {
        capabilityRevisions.count <= Int(UInt32.max)
    }

    // MARK: Schema-3 MAC contribution

    /// Appends the 7 Wave-1 scalar fields to `encoder` in the FIXED, FROZEN order
    /// documented below.  This is the schema-3 MAC extension tail that follows
    /// `FirstPartyDescriptor.macInput()` in `schema3MAC`.
    ///
    /// **Fixed field order (Wave 1 — FROZEN; Wave 2 appends after):**
    /// 1. providerReleaseGeneration  (UInt64, 8 bytes big-endian)
    /// 2. managementRevisionMinimum  (UInt64, 8 bytes big-endian)
    /// 3. managementRevisionMaximum  (UInt64, 8 bytes big-endian)
    /// 4. dataPlaneRevisionMinimum   (UInt64, 8 bytes big-endian)
    /// 5. dataPlaneRevisionMaximum   (UInt64, 8 bytes big-endian)
    /// 6. estateSchemaMinimum        (UInt64, 8 bytes big-endian)
    /// 7. estateSchemaMaximum        (UInt64, 8 bytes big-endian)
    ///
    /// `migrationTargetSchema` and `capabilityRevisions` are NOT appended here —
    /// Wave 2 will extend the tail when those fields enter the wire format.
    public func appendWire1Fields(_ encoder: inout CanonicalEncoder) {
        encoder.appendUInt64(providerReleaseGeneration)  // 1
        encoder.appendUInt64(managementRevisionMinimum)  // 2
        encoder.appendUInt64(managementRevisionMaximum)  // 3
        encoder.appendUInt64(dataPlaneRevisionMinimum)   // 4
        encoder.appendUInt64(dataPlaneRevisionMaximum)   // 5
        encoder.appendUInt64(estateSchemaMinimum)        // 6
        encoder.appendUInt64(estateSchemaMaximum)        // 7
    }

    /// Compute the schema-3 descriptor MAC.
    ///
    /// Schema-3 MAC input = `descriptor.macInput()` (schema-2 fields, frozen per R1)
    /// concatenated with the 7 Wire-1 scalar fields from `vector.appendWire1Fields`.
    /// This is the only MAC computation for schema-3 descriptors.
    ///
    /// - Parameters:
    ///   - descriptor: The schema-3 `FirstPartyDescriptor` (fields already set;
    ///     `descriptorMAC` is `[]` at call time, as it is excluded from its own input).
    ///   - vector: The companion `ProviderVersionVector`.
    ///   - installationRoot: The 32-byte K_install from which K_descriptor is derived.
    /// - Returns: `HMAC-SHA256(K_descriptor, appendBytes(macInput()) || appendWire1Fields())`.
    ///   `CanonicalEncoder.appendBytes` prepends a 4-byte UInt32 big-endian length, so
    ///   the MAC message byte layout is `[UInt32(len) BE | macInput bytes | 7×UInt64 fields]`.
    ///   Wave-2 MAC verification MUST reproduce this layout via `appendBytes` —
    ///   raw-concatenating `macInput()` without the length prefix produces a different
    ///   HMAC input and silent verification failure on every schema-3 descriptor.
    public static func schema3MAC(
        descriptor: FirstPartyDescriptor,
        vector: ProviderVersionVector,
        installationRoot: [UInt8]
    ) -> [UInt8] {
        var encoder = CanonicalEncoder()
        // Schema-2 fields via CanonicalEncoder.appendBytes — which prepends a 4-byte
        // UInt32 big-endian length before the macInput payload.  The contribution to
        // the MAC message is [UInt32(len) BE | macInput_bytes], NOT the raw macInput()
        // bytes alone.  Wave-2 verification must call appendBytes here, not assign
        // macInput() bytes directly, or it will compute a different HMAC input.
        encoder.appendBytes(descriptor.macInput())
        // Schema-3 additive extension: the 7 version-vector scalar fields.
        vector.appendWire1Fields(&encoder)
        return FirstPartyAuthProtocol.hmacSHA256(
            key: FirstPartyAuthProtocol.descriptorKey(installationRoot: installationRoot),
            message: encoder.bytes
        )
    }

    // MARK: Schema-3 MAC verification

    /// Verify a schema-3 descriptor's MAC.
    ///
    /// **Always use this method — not `descriptor.verifyMAC(installationRoot:)` — for
    /// schema-3 descriptors.**  `FirstPartyDescriptor.verifyMAC` computes the HMAC
    /// over only the schema-2 `macInput()` bytes (raw, not length-prefixed).  A
    /// schema-3 descriptor's stored MAC is the schema-3 MAC, which covers the
    /// length-prefixed macInput contribution plus 7 version-vector UInt64 fields.
    /// Calling `verifyMAC` on a schema-3 descriptor therefore always returns `false`
    /// — fail-closed, but silently incorrect from the caller's perspective.
    ///
    /// This method recomputes `schema3MAC` under the same key and performs a
    /// constant-time comparison against the stored `descriptor.descriptorMAC`.
    ///
    /// - Parameters:
    ///   - descriptor: The decoded schema-3 descriptor whose MAC is to be verified.
    ///   - vector: The companion version vector decoded alongside the descriptor.
    ///   - installationRoot: The 32-byte K_install from which K_descriptor is derived.
    /// - Returns: `true` when the stored MAC matches the freshly computed schema-3
    ///   MAC.  `false` for any mismatch, malformed MAC length, or un-encodable fields
    ///   — always fail closed.
    public static func verifySchema3MAC(
        descriptor: FirstPartyDescriptor,
        vector: ProviderVersionVector,
        installationRoot: [UInt8]
    ) -> Bool {
        // Pre-checks mirror FirstPartyDescriptor.verifyMAC: fail closed when the
        // fields cannot be canonically encoded or the stored MAC is the wrong length.
        guard descriptor.hasEncodableFieldWidths else { return false }
        guard descriptor.descriptorMAC.count == FirstPartyAuthProtocol.macByteCount else { return false }
        let expected = schema3MAC(
            descriptor: descriptor,
            vector: vector,
            installationRoot: installationRoot
        )
        return FirstPartyAuthProtocol.constantTimeEquals(expected, descriptor.descriptorMAC)
    }

    // MARK: Legacy detection

    /// The exact 16-key set of a schema-2 descriptor wire record.
    ///
    /// Used by the legacy-detection path to classify on-disk records that were
    /// published before schema 3 was introduced.  This key set must not be
    /// confused with `DescriptorPublisher.fieldNames` (which is now the 23-key
    /// schema-3 set).  Per R4, the legacy detection path lives here, not inside
    /// `DescriptorPublisher.decode()`.
    static let schema2FieldNames: Set<String> = [
        "schemaVersion", "providerIdentifier", "serviceIdentifier", "endpoint",
        "authProtocol", "authKeyIdentifier", "publishedAt", "instanceIdentifier",
        "estateIdentifier", "binaryVersion", "contractRevision", "mcpProtocolVersion",
        "capabilities", "credentialGeneration", "descriptorGeneration", "descriptorMAC",
    ]

    /// Classify `data` as a schema-2 legacy descriptor.
    ///
    /// A record is legacy if and only if its JSON key set is EXACTLY the
    /// 16-field schema-2 set.  A legacy descriptor is never decoded into a
    /// `FirstPartyDescriptor` through this path — it is sufficient to classify
    /// the key set; the field values are untrusted until the MAC verifies, and
    /// MAC verification of a legacy record is outside the scope of automated
    /// takeover.
    ///
    /// Per D1/R4: the verdict `legacyNotEligibleForAutomatedTakeover` is produced
    /// by the evaluator when this returns `true` for the candidate descriptor.
    /// `DescriptorPublisher.decode()` returns `nil` for schema-2 records (the
    /// exact-set check against `fieldNames` — now 23 keys — fails), which is the
    /// correct fail-closed DARK behaviour: the publisher treats any undecoded record
    /// as `leftForeign` and leaves it in place.
    ///
    /// - Parameter data: The raw bytes from the descriptor file.
    /// - Returns: `true` when the key set exactly matches the schema-2 16-field set.
    public static func isLegacyDescriptor(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return Set(object.keys) == schema2FieldNames
    }
}

// MARK: - VersionCompatibilityVerdict

/// The verdict of a coexistence compatibility evaluation.
///
/// **Wave-1 evaluator reachability:**
/// `VersionVectorEvaluator.evaluate()` produces one of: `compatible`,
/// `generationDowngrade`, `keepOwnerNoOverlap`, `candidateCannotReadEstate`,
/// or `updateApp`.  `evaluateLegacyCandidate()` always produces
/// `legacyNotEligibleForAutomatedTakeover`.
///
/// The cases `updateCliService`, `updateCliClient`, and `repairOwnership` are
/// Wave-2 / caller-side verdicts.  The Wave-1 evaluator never produces them —
/// they are defined here so Wave-2 callers share a single verdict type (D6).
///
/// Update-direction messages in the UI and CLI are derived from the verdict plus
/// the specific owner and candidate versions observed.  These verdicts live in
/// MootDaemonProvider — NOT in `MootClientState`, `DaemonContract`, or
/// `DaemonReadiness` (those are Wave 2 / apps/Mootx01-App territory, per D6).
public enum VersionCompatibilityVerdict: String, Sendable, Equatable, CaseIterable {
    /// All compatibility gates pass.  Follow the preference policy; hand over
    /// only through the full lease sequence.
    case compatible

    /// Candidate release generation is lower than the running owner's.  A candidate
    /// that would downgrade the in-service generation is always refused.
    case generationDowngrade

    /// Owner and candidate management-revision ranges have no overlap.  The old
    /// owner must stay running; require update/repair of the old standalone provider
    /// before retrying.  Never kill the running owner.
    case keepOwnerNoOverlap

    /// Candidate cannot open the current estate schema (its estateSchemaMinimum >
    /// currentEstateSchema or estateSchemaMaximum < currentEstateSchema) and carries
    /// no authorised forward migration for it.  Refuse activation; update the target.
    case candidateCannotReadEstate

    /// The candidate descriptor is a schema-2 (legacy) record without the 7
    /// version-vector fields.  Automated takeover is not authorised for a legacy
    /// provider; it must be updated to a schema-3 binary first.
    case legacyNotEligibleForAutomatedTakeover

    /// The running provider is at a higher release generation than the candidate
    /// (same as `generationDowngrade` but specifically when the app or CLI client
    /// is the requester of a downgrade).  Named separately for distinct UI messaging.
    case updateApp

    /// The standalone CLI service provider is too old to participate in authenticated
    /// handover.  Named for the specific update-direction message.
    /// Wave-2 / caller-side verdict — not produced by the Wave-1 evaluator.
    case updateCliService

    /// The CLI client (mootx01 binary the user invokes) is too old for the running
    /// app provider.  The CLI client must be updated before it can authenticate.
    /// Wave-2 / caller-side verdict — not produced by the Wave-1 evaluator.
    case updateCliClient

    /// Provider registration, ownership lock, and descriptor are inconsistent with
    /// each other.  The ownership record requires repair — not downgrade.  This is
    /// produced by Wave-2 callers that detect a broken ownership state; it is never
    /// produced by `VersionVectorEvaluator` (which only compares two authenticated
    /// descriptors, not registry state).
    case repairOwnership
}

// MARK: - VersionVectorEvaluator

/// Deterministic 7-step coexistence compatibility evaluator.
///
/// The evaluator is a pure function — no side effects, no state.  It receives the
/// authenticated owner descriptor + vector and the candidate descriptor + vector
/// and applies the design's ordered compatibility policy exactly once, returning
/// a single `VersionCompatibilityVerdict`.
///
/// **Step order (FROZEN — must not reorder; design doc §Deterministic evaluation order):**
/// 1. Authenticate: confirm both descriptors carry valid structural fields.
///    (In Wave 1 the caller is responsible for MAC verification before calling here;
///    the evaluator trusts that the descriptors have been authenticated.)
/// 2. Reject candidate release-generation downgrade.
/// 3. Negotiate the management revision or retain the owner if no overlap exists.
/// 4. Prove the candidate can open the current estate schema.
/// 5. Evaluate the requesting client's data-plane and capability requirements.
///    (In Wave 1 the data-plane check is always satisfied when ranges overlap;
///    capability revisions are empty so no per-capability gate is applied.)
/// 6. Apply the provider preference (caller's responsibility post-verdict).
/// 7. Execute the lease-based handover (caller's responsibility post-verdict).
///
/// Steps 6 and 7 are caller responsibilities — the evaluator only covers steps 1–5.
public enum VersionVectorEvaluator {

    /// Evaluate coexistence compatibility for a schema-3 owner and schema-3 candidate.
    ///
    /// - Parameters:
    ///   - ownerDescriptor:      The authenticated descriptor of the running provider.
    ///   - ownerVector:          The version vector from the running provider's descriptor.
    ///   - candidateDescriptor:  The authenticated descriptor of the replacement candidate.
    ///   - candidateVector:      The version vector from the candidate's descriptor.
    ///   - currentEstateSchema:  The estate's current schema version (from `EstateReadyProof`).
    /// - Returns: A `VersionCompatibilityVerdict`.
    public static func evaluate(
        ownerDescriptor: FirstPartyDescriptor,
        ownerVector: ProviderVersionVector,
        candidateDescriptor: FirstPartyDescriptor,
        candidateVector: ProviderVersionVector,
        currentEstateSchema: UInt64
    ) -> VersionCompatibilityVerdict {
        // Step 2: Reject release-generation downgrade.  A higher generation is
        // NECESSARY for replacement — never sufficient.  Equality is acceptable
        // (same-generation replacement is allowed through the preference policy).
        if candidateVector.providerReleaseGeneration < ownerVector.providerReleaseGeneration {
            return .generationDowngrade
        }

        // Step 3: Negotiate management revision.  The selected revision is the
        // highest mutual revision.  No overlap ⇒ retain the running owner.
        let managementOverlap = max(ownerVector.managementRevisionMinimum, candidateVector.managementRevisionMinimum)
            <= min(ownerVector.managementRevisionMaximum, candidateVector.managementRevisionMaximum)
        if !managementOverlap {
            return .keepOwnerNoOverlap
        }

        // Step 4: Prove the candidate can open the current estate schema.
        // The candidate's supported schema range must include the currentEstateSchema.
        // A non-nil migrationTargetSchema means the candidate can perform a forward
        // migration to that schema — but only to that one target, and the caller
        // must authorise it explicitly.  In Wave 1 migrationTargetSchema is always
        // nil, so the plain range check is the sole gate.
        let candidateCanRead = candidateVector.estateSchemaMinimum <= currentEstateSchema
            && currentEstateSchema <= candidateVector.estateSchemaMaximum
        if !candidateCanRead {
            return .candidateCannotReadEstate
        }

        // Step 5: Data-plane compatibility.  Ranges must overlap for the client to
        // communicate with the candidate provider.  In Wave 1 this uses the module-
        // level contractRevision range; the candidate's own range is checked.
        // (No per-capability revision gate: capabilityRevisions is empty in Wave 1.)
        let dataPlaneOverlap = max(ownerVector.dataPlaneRevisionMinimum, candidateVector.dataPlaneRevisionMinimum)
            <= min(ownerVector.dataPlaneRevisionMaximum, candidateVector.dataPlaneRevisionMaximum)
        if !dataPlaneOverlap {
            // The running provider is still healthy for other clients; this candidate
            // is reporting update-required.  In Wave 1 the verdict is updateApp because
            // data-plane incompatibility most often means the candidate lags behind the
            // running owner's implemented revision.
            return .updateApp
        }

        // Steps 6–7: Preference and lease handover are caller responsibilities.
        // The evaluator's job is complete.
        return .compatible
    }

    /// Evaluate when the candidate is a schema-2 (legacy) descriptor.
    ///
    /// A schema-2 candidate is never eligible for automated takeover regardless of
    /// any other field value.  The caller should detect this via
    /// `ProviderVersionVector.isLegacyDescriptor` before calling `evaluate`.
    ///
    /// - Parameters:
    ///   - ownerDescriptor: The running owner's authenticated descriptor (unused in the
    ///     verdict decision, included so the caller doesn't need a separate branch).
    ///   - ownerVector:     The running owner's version vector.
    /// - Returns: `.legacyNotEligibleForAutomatedTakeover` always.
    public static func evaluateLegacyCandidate(
        ownerDescriptor: FirstPartyDescriptor,
        ownerVector: ProviderVersionVector
    ) -> VersionCompatibilityVerdict {
        // The owner fields are accepted but unused: a schema-2 candidate is never
        // eligible for automated takeover, irrespective of owner state.
        _ = ownerDescriptor
        _ = ownerVector
        return .legacyNotEligibleForAutomatedTakeover
    }
}
