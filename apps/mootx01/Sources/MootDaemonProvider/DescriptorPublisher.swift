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
// elects a winner).

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

    private let descriptorFile: URL
    private let clock: ProviderClock

    /// - Parameters:
    ///   - descriptorFile: `ProviderRootLayout.descriptorFile`.
    ///   - clock: Injected epoch-seconds clock (Perkins P13) — stamps
    ///     `publishedAt` at publication.
    public init(descriptorFile: URL, clock: @escaping ProviderClock) {
        self.descriptorFile = descriptorFile
        self.clock = clock
    }

    /// The canonical JSON encoding of a descriptor for file publication.
    ///
    /// Sorted keys, camelCase field names matching the schema-2 field list,
    /// `descriptorMAC` as base64url-no-padding, capabilities sorted. The
    /// encoding is deterministic: one descriptor, one byte string. It carries
    /// no estate path, root, key, lease secret, environment value, or
    /// Keychain account (Perkins P11) — a property the tests assert against
    /// the serialized bytes, not this comment.
    public static func encode(_ descriptor: FirstPartyDescriptor) -> Data {
        Data() // RED placeholder.
    }

    /// Decode a published record. `nil` for anything malformed.
    public static func decode(_ data: Data) -> FirstPartyDescriptor? {
        nil // RED placeholder.
    }

    /// Publish `descriptor`, judging every precondition (Perkins P8).
    ///
    /// - Parameters:
    ///   - descriptor: The record to publish. Its MAC must already be
    ///     computed; schema, endpoint, and identifier fields are re-judged
    ///     here against `FirstPartyAuthProtocol` constants.
    ///   - lockProof: The held exclusive lock.
    ///   - estateReady: Injected estate-ready proof; must name the
    ///     descriptor's estate.
    ///   - bind: The getsockname(2) readback; must equal the exact
    ///     contracted endpoint host and port.
    ///   - authenticator: Complete authenticator readiness; capabilities must
    ///     equal the descriptor's, and must include the authenticated
    ///     first-party capability.
    /// - Throws: `DaemonProviderError.publishPreconditionFailed`.
    public func publish(
        _ descriptor: FirstPartyDescriptor,
        lockProof: ProviderLockProof,
        estateReady: EstateReadyProof,
        bind: BindProof,
        authenticator: AuthenticatorReadiness
    ) throws {
        throw DaemonProviderError.unimplemented("DescriptorPublisher.publish")
    }

    /// Remove the published record ONLY when it is this provider's own:
    /// same instance UUID AND same descriptor generation.
    ///
    /// A mismatching, undecodable, or foreign record is LEFT IN PLACE and
    /// reported — never unlinked (Perkins P8: shutdown removes only its own
    /// matching instance/generation descriptor, never blind unlink).
    public func removeOwnDescriptor(
        instanceIdentifier: UUID,
        descriptorGeneration: UInt64
    ) throws -> DescriptorRemovalOutcome {
        throw DaemonProviderError.unimplemented("DescriptorPublisher.removeOwnDescriptor")
    }
}
