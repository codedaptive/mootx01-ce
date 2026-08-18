import Foundation
import AriaMCP

// MARK: - MACD-2c1 — atomic descriptor publication (Perkins P8)
//
// A descriptor on disk is a CLAIM other processes will read, so the publisher
// refuses to write one until every claim in it is proven: the lock is held,
// the injected estate authority has produced a ready proof for the SAME
// estate the descriptor names, the loopback bind has been read back from
// getsockname(2) and equals the exact contracted endpoint, and a complete
// authenticator advertises exactly the descriptor's capabilities. Publication
// is fsync + atomic rename; shutdown removes only the provider's OWN
// instance/generation match — never a blind unlink, because the file may by
// then belong to a successor (or an attacker may have substituted one, and
// deleting a foreign descriptor is a denial-of-service primitive).
//
// Port-squatter defense is the descriptor MAC plus the authenticated
// handshake — NEVER port liveness (Kong decision 3: port liveness never
// elects a winner). Nothing in this file consults who holds the port.
//
// MACD-3B1 — schema 3 (Wave 1, DARK):
//   fieldNames expands from 16 to 23 (7 new wire fields from ProviderVersionVector).
//   encode and decode carry a ProviderVersionVector companion alongside the
//   FirstPartyDescriptor.  The schema-3 MAC covers both (see ProviderVersionVector).
//   A schema-2 record now returns nil from decode (exact-set check fails for 23 keys);
//   the legacy classification path lives in ProviderVersionVector.isLegacyDescriptor,
//   not here (R4 — fail-closed dark behaviour).

/// Outcome of a shutdown descriptor removal.
public enum DescriptorRemovalOutcome: String, Sendable, Equatable {
    /// The published record matched this provider's instance and generation
    /// and was removed.
    case removedOwn = "removed-own"
    /// A record exists but is NOT this provider's — left untouched.
    case leftForeign = "left-foreign"
    /// No record exists.
    case absent
}

/// Publishes and removes the on-disk first-party descriptor.
public struct DescriptorPublisher: Sendable {

    /// The wire spelling of the authenticated first-party capability. The
    /// spelling is fixed by ARIA_MCP_SPEC §first-party and emitted by
    /// AriaMCP `Server.initialize` (which carries it as a literal — there is
    /// no public constant to import, so the spelling is pinned here WITH its
    /// provenance rather than duplicated silently).
    public static let authenticatedFirstPartyCapability = "authenticated-first-party"

    /// The twenty-three schema-3 field names, sorted — the exact key set of a
    /// published record. Publication and decoding both enforce it.
    ///
    /// The 7 new fields added by MACD-3B1 (over the schema-2 base of 16) are:
    ///   providerReleaseGeneration, managementRevisionMinimum, managementRevisionMaximum,
    ///   dataPlaneRevisionMinimum, dataPlaneRevisionMaximum,
    ///   estateSchemaMinimum, estateSchemaMaximum.
    ///
    /// A schema-2 record's 16-key set NO LONGER passes the exact-set check — it
    /// decodes as nil (fail-closed dark behaviour).  Legacy classification of such
    /// a record is provided by ProviderVersionVector.isLegacyDescriptor (R4).
    public static let fieldNames: Set<String> = [
        // Schema-2 fields (16)
        "schemaVersion", "providerIdentifier", "serviceIdentifier", "endpoint",
        "authProtocol", "authKeyIdentifier", "publishedAt", "instanceIdentifier",
        "estateIdentifier", "binaryVersion", "contractRevision", "mcpProtocolVersion",
        "capabilities", "credentialGeneration", "descriptorGeneration", "descriptorMAC",
        // Schema-3 additions (7) — ProviderVersionVector wire fields
        "providerReleaseGeneration",
        "managementRevisionMinimum", "managementRevisionMaximum",
        "dataPlaneRevisionMinimum", "dataPlaneRevisionMaximum",
        "estateSchemaMinimum", "estateSchemaMaximum",
    ]

    private let descriptorFile: URL

    /// - Parameter descriptorFile: `ProviderRootLayout.descriptorFile`.
    ///
    /// No clock: `publishedAt` is stamped by the PROVIDER when it seals the
    /// descriptor (the field is inside the MAC, so the publisher could not
    /// restamp it without invalidating the record it was handed).
    public init(descriptorFile: URL) {
        self.descriptorFile = descriptorFile
    }

    /// The canonical JSON encoding of a schema-3 descriptor pair for file publication.
    ///
    /// Sorted keys, camelCase field names matching the schema-3 field list (23 keys),
    /// `descriptorMAC` as base64url-no-padding, generations and `providerReleaseGeneration`
    /// as DECIMAL STRINGS (spec 1.40.0 — a JSON number cannot carry UInt64 exactly),
    /// revision-range fields as integers (bounded, fit in JSON number precision),
    /// capabilities sorted, UUIDs in canonical string form.  Deterministic: one
    /// descriptor + vector pair, one byte string.
    ///
    /// It carries no estate path, root, key, lease secret, environment value, or
    /// Keychain account beyond the schema's own `authKeyIdentifier` constant
    /// (Perkins P11) — a property the tests assert against the serialized bytes.
    public static func encode(_ descriptor: FirstPartyDescriptor, vector: ProviderVersionVector) -> Data {
        let object: [String: Any] = [
            // Schema-2 fields (16)
            "schemaVersion": descriptor.schemaVersion,
            "providerIdentifier": descriptor.providerIdentifier,
            "serviceIdentifier": descriptor.serviceIdentifier,
            "endpoint": descriptor.endpoint,
            "authProtocol": descriptor.authProtocol,
            "authKeyIdentifier": descriptor.authKeyIdentifier,
            "publishedAt": NSNumber(value: descriptor.publishedAt),
            "instanceIdentifier": descriptor.instanceIdentifier.uuidString,
            "estateIdentifier": descriptor.estateIdentifier.uuidString,
            "binaryVersion": descriptor.binaryVersion,
            "contractRevision": descriptor.contractRevision,
            "mcpProtocolVersion": descriptor.mcpProtocolVersion,
            "capabilities": descriptor.capabilities.sorted(),
            "credentialGeneration": ProviderGenerations.wireEncode(descriptor.credentialGeneration),
            "descriptorGeneration": ProviderGenerations.wireEncode(descriptor.descriptorGeneration),
            "descriptorMAC": FirstPartyAuthProtocol.base64URLEncode(descriptor.descriptorMAC),
            // Schema-3 fields (7) — ProviderVersionVector wire fields.
            // providerReleaseGeneration as decimal string: UInt64, same spec as
            // credentialGeneration and descriptorGeneration (exact representation).
            "providerReleaseGeneration": ProviderGenerations.wireEncode(vector.providerReleaseGeneration),
            // Revision ranges are bounded integers that fit in JSON number precision
            // (< 2^53) for the foreseeable future, but are encoded via NSNumber so
            // they round-trip through JSONSerialization without loss.
            "managementRevisionMinimum": NSNumber(value: vector.managementRevisionMinimum),
            "managementRevisionMaximum": NSNumber(value: vector.managementRevisionMaximum),
            "dataPlaneRevisionMinimum": NSNumber(value: vector.dataPlaneRevisionMinimum),
            "dataPlaneRevisionMaximum": NSNumber(value: vector.dataPlaneRevisionMaximum),
            "estateSchemaMinimum": NSNumber(value: vector.estateSchemaMinimum),
            "estateSchemaMaximum": NSNumber(value: vector.estateSchemaMaximum),
        ]
        // .sortedKeys makes the byte string a total function of the values.
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// Decode a published schema-3 record into a `(FirstPartyDescriptor, ProviderVersionVector)` pair.
    ///
    /// Returns `nil` for anything malformed: wrong key set (including a schema-2
    /// 16-key record — fail-closed per D1/R4), wrong types, non-canonical generation
    /// spellings, or an undecodable MAC.  A record this reader cannot represent
    /// EXACTLY is a record it refuses.
    ///
    /// Schema-2 legacy records are NOT decoded through this path; use
    /// `ProviderVersionVector.isLegacyDescriptor` to classify them.
    public static func decode(_ data: Data) -> (descriptor: FirstPartyDescriptor, vector: ProviderVersionVector)? {
        guard let object = FirstPartyAuthProtocol.strictJSONObject(
            data, expected: fieldNames, maxBytes: 64 * 1024
        ) else { return nil }
        guard
            let schemaVersion = object["schemaVersion"] as? Int,
            let providerIdentifier = object["providerIdentifier"] as? String,
            let serviceIdentifier = object["serviceIdentifier"] as? String,
            let endpoint = object["endpoint"] as? String,
            let authProtocol = object["authProtocol"] as? String,
            let authKeyIdentifier = object["authKeyIdentifier"] as? String,
            let publishedAt = FirstPartyAuthProtocol.exactUInt64(object["publishedAt"]),
            let instanceRaw = object["instanceIdentifier"] as? String,
            let instanceIdentifier = UUID(uuidString: instanceRaw),
            let estateRaw = object["estateIdentifier"] as? String,
            let estateIdentifier = UUID(uuidString: estateRaw),
            let binaryVersion = object["binaryVersion"] as? String,
            let contractRevision = object["contractRevision"] as? Int,
            let mcpProtocolVersion = object["mcpProtocolVersion"] as? String,
            let capabilities = object["capabilities"] as? [String],
            let credentialRaw = object["credentialGeneration"] as? String,
            let credentialGeneration = ProviderGenerations.wireDecode(credentialRaw),
            let descriptorRaw = object["descriptorGeneration"] as? String,
            let descriptorGeneration = ProviderGenerations.wireDecode(descriptorRaw),
            let macRaw = object["descriptorMAC"] as? String,
            let descriptorMAC = FirstPartyAuthProtocol.base64URLDecode(macRaw)
        else { return nil }
        // Schema-3 vector fields.  providerReleaseGeneration is a decimal string
        // (same wire convention as generations).  Revision ranges are integers.
        guard
            let releaseGenRaw = object["providerReleaseGeneration"] as? String,
            let providerReleaseGeneration = ProviderGenerations.wireDecode(releaseGenRaw),
            let mgmtMin = FirstPartyAuthProtocol.exactUInt64(object["managementRevisionMinimum"]),
            let mgmtMax = FirstPartyAuthProtocol.exactUInt64(object["managementRevisionMaximum"]),
            let dpMin = FirstPartyAuthProtocol.exactUInt64(object["dataPlaneRevisionMinimum"]),
            let dpMax = FirstPartyAuthProtocol.exactUInt64(object["dataPlaneRevisionMaximum"]),
            let esMin = FirstPartyAuthProtocol.exactUInt64(object["estateSchemaMinimum"]),
            let esMax = FirstPartyAuthProtocol.exactUInt64(object["estateSchemaMaximum"])
        else { return nil }

        let descriptor = FirstPartyDescriptor(
            schemaVersion: schemaVersion,
            providerIdentifier: providerIdentifier,
            serviceIdentifier: serviceIdentifier,
            endpoint: endpoint,
            authProtocol: authProtocol,
            authKeyIdentifier: authKeyIdentifier,
            publishedAt: publishedAt,
            instanceIdentifier: instanceIdentifier,
            estateIdentifier: estateIdentifier,
            binaryVersion: binaryVersion,
            contractRevision: contractRevision,
            mcpProtocolVersion: mcpProtocolVersion,
            capabilities: capabilities,
            credentialGeneration: credentialGeneration,
            descriptorGeneration: descriptorGeneration,
            descriptorMAC: descriptorMAC
        )
        let vector = ProviderVersionVector(
            providerReleaseGeneration: providerReleaseGeneration,
            managementRevisionMinimum: mgmtMin,
            managementRevisionMaximum: mgmtMax,
            dataPlaneRevisionMinimum: dpMin,
            dataPlaneRevisionMaximum: dpMax,
            estateSchemaMinimum: esMin,
            estateSchemaMaximum: esMax,
            // migrationTargetSchema and capabilityRevisions are not in the Wave 1
            // wire format; they default to nil / empty on decode.
            migrationTargetSchema: nil,
            capabilityRevisions: [:]
        )
        return (descriptor, vector)
    }

    /// Publish `descriptor` + `vector`, judging every precondition (Perkins P8).
    ///
    /// - Parameters:
    ///   - descriptor: The record to publish. Its MAC must already be computed
    ///     as a schema-3 MAC (ProviderVersionVector.schema3MAC); schema, endpoint,
    ///     and identifier fields are re-judged here against `FirstPartyAuthProtocol`
    ///     constants.
    ///   - vector: The ProviderVersionVector companion. Its `hasEncodableFieldWidths`
    ///     must be true.
    ///   - lockProof: The held exclusive lock.
    ///   - estateReady: Injected estate-ready proof; must name the descriptor's estate.
    ///   - bind: The getsockname(2) readback; must equal the exact contracted endpoint.
    ///   - authenticator: Complete authenticator readiness; capabilities must equal
    ///     the descriptor's, and must include the authenticated first-party capability.
    /// - Throws: `DaemonProviderError.publishPreconditionFailed`.
    public func publish(
        _ descriptor: FirstPartyDescriptor,
        vector: ProviderVersionVector,
        lockProof: ProviderLockProof,
        estateReady: EstateReadyProof,
        bind: BindProof,
        authenticator: AuthenticatorReadiness
    ) throws {
        // A stale proof (its handle released) must never serialize anything.
        try lockProof.validate()
        // 1. The descriptor itself must be exactly the frozen contract.
        guard descriptor.schemaVersion == FirstPartyAuthProtocol.descriptorSchemaVersion,
              descriptor.providerIdentifier == FirstPartyAuthProtocol.providerIdentifier,
              descriptor.serviceIdentifier == FirstPartyAuthProtocol.serviceIdentifier,
              descriptor.endpoint == FirstPartyAuthProtocol.endpoint,
              descriptor.authProtocol == FirstPartyAuthProtocol.authProtocolIdentifier,
              descriptor.authKeyIdentifier == FirstPartyAuthProtocol.authKeyIdentifier,
              descriptor.contractRevision == FirstPartyAuthProtocol.contractRevision,
              descriptor.mcpProtocolVersion == FirstPartyAuthProtocol.mcpProtocolVersion,
              descriptor.descriptorMAC.count == FirstPartyAuthProtocol.macByteCount,
              descriptor.hasEncodableFieldWidths,
              vector.hasEncodableFieldWidths
        else {
            throw DaemonProviderError.publishPreconditionFailed(.descriptorMalformed)
        }
        // 2. The bind READBACK — not the intent — must be the exact endpoint.
        //    Host and port come from the contract constant, not literals, so
        //    the comparison can never drift from the endpoint it guards.
        guard let contracted = URL(string: FirstPartyAuthProtocol.endpoint),
              bind.host == contracted.host,
              Int(bind.port) == contracted.port
        else {
            throw DaemonProviderError.publishPreconditionFailed(.bindMismatch)
        }
        // 3. The estate proof must name the estate the descriptor claims.
        guard estateReady.estateIdentifier == descriptor.estateIdentifier else {
            throw DaemonProviderError.publishPreconditionFailed(.estateNotReady)
        }
        // 4. The authenticator must be complete and advertise EXACTLY the
        //    descriptor's capabilities — an over- or under-claiming record
        //    would tell clients something the lane will not honor.
        guard authenticator.capabilities == descriptor.capabilities.sorted(),
              authenticator.capabilities.contains(Self.authenticatedFirstPartyCapability)
        else {
            throw DaemonProviderError.publishPreconditionFailed(.authenticatorIncomplete)
        }
        // A serialization failure yields empty bytes; publishing an empty
        // record would be a self-inflicted substitution. Refuse instead.
        let encoded = Self.encode(descriptor, vector: vector)
        guard !encoded.isEmpty else {
            throw DaemonProviderError.publishPreconditionFailed(.descriptorMalformed)
        }
        try SecureFiles.atomicReplace(encoded, at: descriptorFile)
    }

    /// Remove the published record ONLY when it is this provider's own:
    /// same instance UUID AND same descriptor generation.
    ///
    /// A mismatching, undecodable, or foreign record is LEFT IN PLACE and
    /// reported — never unlinked (Perkins P8: shutdown removes only its own
    /// matching instance/generation descriptor, never blind unlink).
    ///
    /// Schema-2 records cannot be decoded by the schema-3 decoder, so they are
    /// treated as foreign (leftForeign) — correct DARK behaviour: the schema-2
    /// descriptor is left in place and a new schema-3 provider cannot remove it.
    public func removeOwnDescriptor(
        instanceIdentifier: UUID,
        descriptorGeneration: UInt64
    ) throws -> DescriptorRemovalOutcome {
        // Read through a validated O_NOFOLLOW descriptor, never a path-based
        // convenience read: a symlinked or aliased record must not be READ as
        // if it were the published descriptor — and anything the hygiene
        // matrix refuses is by definition not this provider's own record, so
        // it is left in place.
        let data: Data
        do {
            guard let fd = try SecureFiles.openValidatedIfExists(descriptorFile, flags: O_RDONLY) else {
                return .absent
            }
            defer { close(fd) }
            data = Data(try SecureFiles.readAll(fd: fd))
        } catch DaemonProviderError.hygieneViolation {
            return .leftForeign
        }
        // decode returns a tuple (descriptor, vector); only the descriptor's
        // instanceIdentifier and descriptorGeneration are checked for ownership.
        guard let (current, _) = Self.decode(data),
              current.instanceIdentifier == instanceIdentifier,
              current.descriptorGeneration == descriptorGeneration
        else {
            return .leftForeign
        }
        guard unlink(descriptorFile.path) == 0 else {
            throw DaemonProviderError.hygieneViolation(.unopenable)
        }
        return .removedOwn
    }
}
