import Foundation

// MARK: - Resident daemon contract
//
// Both macOS applications are clients of ONE resident, daemon-owned estate.
// Neither macOS GUI creates or opens SQLite; iOS and iPadOS keep their
// embedded estate. Before a client may speak to a daemon it must agree with
// that daemon on a contract, and this file is the whole of that agreement:
//
//   - who published the daemon (provider) and which service it is,
//   - which revision of the client/daemon contract it implements,
//   - which MCP protocol version its dispatcher negotiates,
//   - where it listens (loopback only, never a route off this machine),
//   - what it can do (capabilities).
//
// Two properties of this file are load-bearing.
//
// First, it is EDITION-NEUTRAL. The descriptor names identifiers and a
// revision, not a product tier. Community, Pro, and Enterprise clients
// evaluate the identical contract against the identical daemon, so a daemon
// never has to know which application is asking before it can be judged
// compatible.
//
// Second, it carries NO ESTATE PATH AND NO ESTATE KEY. A descriptor is a
// routing and compatibility record. The moment a descriptor could hand a
// client a file path or a SQLCipher key, "the GUI never owns SQLite" would
// stop being a structural guarantee and become a convention. The daemon owns
// the estate; a client is told how to *ask*, never how to *open*.
//
// Nothing in this file authorizes anything. Compatibility is necessary and
// never sufficient — `DaemonReadiness` requires an authenticated session and a
// completed MCP handshake on top of a compatible descriptor before a caller
// exists at all.

/// The fixed identifiers and versions a client requires of a resident daemon.
///
/// These are constants rather than configuration on purpose: a client that can
/// be pointed at an arbitrary provider over an arbitrary endpoint is a client
/// that can be pointed at an impostor.
public enum DaemonContract {

    /// The installer-owned provider that arbitrates the resident daemon. This
    /// is the `com.mootx01.mgr` LaunchAgent label the installer registers
    /// (`MootInstallerCore.Paths.launchAgentLabel`) — the one component
    /// permitted to publish a descriptor a client will act on.
    public static let providerIdentifier = "com.mootx01.mgr"

    /// The resident daemon service itself: the `com.mootx01.daemon` LaunchAgent
    /// label (`MootInstallerCore.Paths.daemonLabel`) that owns the estate and
    /// serves the ARIA tool surface.
    public static let serviceIdentifier = "com.mootx01.daemon"

    /// The `serverInfo.name` the daemon's dispatcher reports at `initialize`.
    /// The resident daemon runs the `aria-mcp` dispatcher, which advertises
    /// "ARIA_MCP" (see `AriaMCPMain`). A handshake that reports any other name
    /// is not the daemon this client contracted with.
    public static let serverName = "ARIA_MCP"

    /// The descriptor wire-schema this client can parse. Bumped only when the
    /// descriptor's own field set changes, independently of `contractRevision`.
    ///
    /// Schema 2 adds the authentication envelope: `authProtocol`,
    /// `authKeyIdentifier`, `publishedAt`, the two generations, and
    /// `descriptorMAC`. Schema 1 descriptors are refused rather than upgraded —
    /// a schema-1 record carries no MAC, so there is nothing to verify it with.
    public static let schemaVersion = 2

    /// The client/daemon contract revision this client implements. A daemon on
    /// a different revision is refused rather than negotiated down: a partially
    /// understood contract is the failure mode this whole file exists to
    /// prevent.
    public static let supportedContractRevision = 2

    /// The authentication scheme this client speaks. Never negotiated: security
    /// properties do not downgrade, so a descriptor naming any other scheme is
    /// refused outright rather than falling back to an unauthenticated path.
    public static let authProtocol = "hmac-sha256-hkdf-v1"

    /// Which root credential the descriptor must be authenticated under.
    public static let authKeyIdentifier = "installation-root-v1"

    /// The one endpoint the first-party lane will dial, compared in full.
    ///
    /// Whole-string comparison rather than component checks: a descriptor that
    /// satisfies scheme, host, and port individually can still carry a query,
    /// a fragment, userinfo, or a different path, and each of those is a way to
    /// reach something other than the contracted endpoint.
    public static let firstPartyEndpoint = "http://127.0.0.1:4242/mcp/first-party"

    /// The daemon binary versions this client will speak to: `[1.0.0, 2.0.0)`.
    ///
    /// Inclusive lower bound, exclusive upper. Below it the daemon is too old
    /// and the user is asked to update the daemon; at or above it the daemon is
    /// newer than this client understands and the user is asked to update the
    /// app. The client never stops, downgrades, or works around a daemon
    /// outside this range.
    public static let minimumDaemonVersion = SemanticVersion(major: 1, minor: 0, patch: 0)

    /// Exclusive upper bound of the supported daemon range.
    public static let maximumDaemonVersionExclusive = SemanticVersion(major: 2, minor: 0, patch: 0)

    /// The MCP protocol version this client requires the daemon to negotiate.
    /// Matches `ARIA_MCPDispatcher.latestSupportedProtocolVersion`; the daemon
    /// echoes a version it supports back at `initialize`, and readiness
    /// compares the echo against the descriptor.
    public static let mcpProtocolVersion = "2025-11-25"

    /// The capabilities a daemon must advertise before a client will proceed.
    ///
    /// Only authenticated first-party access is gated in this stage, and that
    /// is deliberate: it is the one capability whose absence would let a client
    /// reach an estate without proving who it is. The remaining capabilities
    /// are advertised by the daemon and recorded on the descriptor, but nothing
    /// routes through them yet, so gating on them would assert a requirement
    /// this stage does not actually impose.
    public static let requiredCapabilities: Set<DaemonCapability> = [.authenticatedFirstParty]

    /// The literal loopback addresses a daemon endpoint may use.
    ///
    /// Literal addresses only — "localhost" is NOT accepted. A hostname is
    /// resolved through `/etc/hosts` and the resolver, so "localhost" is a name
    /// an attacker with write access to either can repoint at another machine.
    /// A literal 127.0.0.1 or ::1 cannot be repointed, which is exactly the
    /// property "the daemon is on this machine" needs.
    public static let loopbackHosts: Set<String> = ["127.0.0.1", "::1"]

    /// The only endpoint scheme a client will dial. Loopback traffic never
    /// leaves the host, so there is no TLS to terminate; an `https` endpoint
    /// would imply a remote peer, which this contract forbids outright.
    public static let endpointScheme = "http"
}

// MARK: - Capabilities

/// What a resident daemon says it can do.
///
/// Raw values are the stable wire spelling — the daemon publishes these
/// strings, so they are hyphenated rather than camel-cased and must not change
/// without a `DaemonContract.schemaVersion` bump.
public enum DaemonCapability: String, CaseIterable, Sendable, Codable, Comparable {

    /// The daemon authenticates first-party clients and refuses unauthenticated
    /// callers. Required: without it a client cannot prove who it is, and the
    /// daemon cannot prove it would care.
    case authenticatedFirstParty = "authenticated-first-party"

    /// The daemon serves the ARIA `moot_*` tool surface over MCP.
    case toolSurface = "tool-surface"

    /// The daemon owns a resident estate and is the single writer for it.
    case residentEstate = "resident-estate"

    /// Ordered by wire spelling so any diagnostic listing capabilities — most
    /// visibly `DaemonCompatibility.missingCapabilities` — is deterministic
    /// rather than dependent on `Set` iteration order.
    public static func < (lhs: DaemonCapability, rhs: DaemonCapability) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Descriptor

/// What a resident daemon publishes about itself.
///
/// A descriptor is a claim, not a credential. Every field here is attacker-
/// controlled input until `DaemonCompatibilityPolicy` has judged it and
/// `DaemonReadiness` has completed an authenticated handshake against it.
///
/// The fields are `var` because a client legitimately rewrites a descriptor
/// while testing and while re-reading a republished record; they are not `var`
/// to invite mutation of a descriptor already judged compatible.
public struct DaemonDescriptor: Sendable, Equatable, Codable {

    /// Wire-schema of this record. Compared against
    /// `DaemonContract.schemaVersion` before any other field is trusted.
    public var schemaVersion: Int

    /// The provider that published this descriptor.
    public var providerIdentifier: String

    /// The daemon service this descriptor describes.
    public var serviceIdentifier: String

    /// Identifies this particular running daemon process. Lets a client notice
    /// that the daemon it is talking to is not the one it handshook with.
    public var instanceIdentifier: UUID

    /// Identifies the estate the daemon owns. An identifier only — never a
    /// path, never a key. A client uses it to confirm continuity, not to open
    /// anything.
    public var estateIdentifier: UUID

    /// The daemon binary's marketing version, echoed back as `serverInfo.version`
    /// at `initialize` so a client can detect a descriptor that describes a
    /// different build than the one answering.
    public var binaryVersion: String

    /// The client/daemon contract revision the daemon implements.
    public var contractRevision: Int

    /// The MCP protocol version the daemon expects to negotiate.
    public var mcpProtocolVersion: String

    /// Where the daemon listens. Loopback only — see `DaemonContract.loopbackHosts`.
    public var endpoint: URL

    /// What the daemon advertises it can do.
    public var capabilities: Set<DaemonCapability>

    /// The authentication scheme the daemon implements.
    public var authProtocol: String

    /// Which root credential authenticated this descriptor.
    public var authKeyIdentifier: String

    /// Publication time, seconds since the Unix epoch.
    ///
    /// **Authenticated but deliberately not judged.** `publishedAt` is covered
    /// by `descriptorMAC`, so it cannot be forged or altered — but this client
    /// does not compare it against its own clock, and no gate rejects a
    /// descriptor for being old or future-dated.
    ///
    /// That is a decision, not an omission. The publisher and the reader share
    /// no trusted time source: a wall-clock comparison would reject a genuine
    /// descriptor whenever the two disagreed, and would still accept a replayed
    /// one from an attacker who simply waited. Freshness is enforced instead by
    /// `credentialGeneration` and `descriptorGeneration`, which are monotonic
    /// counters the daemon controls and `DaemonReadiness` tracks a high-water
    /// for — a comparison that needs no clock and cannot be waited out.
    ///
    /// The field is carried and MACed so that a later mission can use it for
    /// diagnostics or for an explicit staleness policy without a schema change.
    public var publishedAt: UInt64

    /// Monotonic; bumped by an explicit root rotation.
    public var credentialGeneration: UInt64

    /// Monotonic; bumped whenever the descriptor is republished, so a stale
    /// record cannot be replayed as current.
    public var descriptorGeneration: UInt64

    /// The MAC over the canonical descriptor bytes. A descriptor is a claim
    /// until this verifies under a key derived from the installation root.
    public var descriptorMAC: [UInt8]

    /// Create a descriptor. Callers are normally decoders reading a published
    /// record; the memberwise form is spelled out so the field list is a
    /// documented public surface rather than a synthesized accident.
    ///
    /// The v2 fields carry no defaults on purpose: a missing authentication
    /// field must be a compile-time break at every construction site, never a
    /// silent zero that would make an unauthenticated descriptor look complete.
    public init(
        schemaVersion: Int,
        providerIdentifier: String,
        serviceIdentifier: String,
        instanceIdentifier: UUID,
        estateIdentifier: UUID,
        binaryVersion: String,
        contractRevision: Int,
        mcpProtocolVersion: String,
        endpoint: URL,
        capabilities: Set<DaemonCapability>,
        authProtocol: String,
        authKeyIdentifier: String,
        publishedAt: UInt64,
        credentialGeneration: UInt64,
        descriptorGeneration: UInt64,
        descriptorMAC: [UInt8]
    ) {
        self.schemaVersion = schemaVersion
        self.providerIdentifier = providerIdentifier
        self.serviceIdentifier = serviceIdentifier
        self.instanceIdentifier = instanceIdentifier
        self.estateIdentifier = estateIdentifier
        self.binaryVersion = binaryVersion
        self.contractRevision = contractRevision
        self.mcpProtocolVersion = mcpProtocolVersion
        self.endpoint = endpoint
        self.capabilities = capabilities
        self.authProtocol = authProtocol
        self.authKeyIdentifier = authKeyIdentifier
        self.publishedAt = publishedAt
        self.credentialGeneration = credentialGeneration
        self.descriptorGeneration = descriptorGeneration
        self.descriptorMAC = descriptorMAC
    }
}

// MARK: - Semantic version

/// A `MAJOR.MINOR.PATCH` version, compared numerically.
///
/// Spelled out rather than compared as strings: string ordering puts "10.0.0"
/// before "9.0.0", which would silently invert the compatibility range at
/// exactly the moment the daemon crosses a version-number digit boundary.
public struct SemanticVersion: Sendable, Equatable, Comparable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parse `MAJOR.MINOR.PATCH`, strictly.
    ///
    /// Exactly three non-negative decimal components, no pre-release or build
    /// metadata, no leading zeroes, no leading `v`. A version this client cannot
    /// parse exactly is one it cannot bound, so it is refused rather than
    /// guessed at.
    public init?(_ raw: String) {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            if part.count > 1 && part.first == "0" { return nil }
            guard let value = Int(part) else { return nil }
            values.append(value)
        }
        self.init(major: values[0], minor: values[1], patch: values[2])
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

// MARK: - Compatibility

/// The single structural reason a descriptor was refused.
///
/// One named case per check so a refusal is diagnosable without re-running the
/// policy: "which gate closed" is the first question every daemon-connection
/// bug asks.
public enum DaemonDescriptorDefect: String, Sendable, Equatable, CaseIterable {

    /// The record uses a descriptor schema this client cannot parse.
    case unsupportedSchemaVersion

    /// The descriptor was published by a provider this client does not contract with.
    case unknownProvider

    /// The descriptor names a service other than the resident daemon.
    case unknownService

    /// The endpoint is not a literal loopback address, or not the loopback
    /// scheme, or carries no port. Any of the three means the client would be
    /// dialing something other than a daemon on this machine.
    case nonLoopbackEndpoint

    /// The daemon implements a different client/daemon contract revision.
    case unsupportedContractRevision

    /// The daemon expects an MCP protocol version this client does not speak.
    case unsupportedProtocolVersion

    /// The descriptor carries no binary version, so the handshake would have
    /// nothing to compare `serverInfo.version` against.
    case emptyBinaryVersion

    /// The daemon implements a different authentication scheme. Refused rather
    /// than negotiated: there is no weaker scheme this client will accept.
    case unsupportedAuthProtocol

    /// The descriptor names a root credential this client does not contract
    /// with.
    case unknownAuthKeyIdentifier

    /// The endpoint is not the exact contracted first-party endpoint.
    case wrongEndpoint

    /// `binaryVersion` is not a parseable `MAJOR.MINOR.PATCH`, so the
    /// compatibility range cannot be evaluated against it.
    case unparseableBinaryVersion

    /// The descriptor carries no MAC, or one of the wrong length. Structural:
    /// whether it VERIFIES is a separate question answered after this gate.
    case malformedDescriptorMAC

    /// A generation is older than one this client has already seen, so the
    /// descriptor is a stale record being presented as current.
    case staleGeneration
}

/// The verdict on one descriptor.
public enum DaemonCompatibility: Sendable, Equatable {

    /// Every structural gate passed. Necessary, never sufficient: the caller
    /// still has to authenticate and complete the MCP handshake.
    case compatible

    /// A structural field of the descriptor is wrong.
    case invalidDescriptor(DaemonDescriptorDefect)

    /// The descriptor is structurally sound but does not advertise every
    /// required capability. Sorted by wire spelling for a stable diagnostic.
    case missingCapabilities([DaemonCapability])

    /// The daemon is older than this client's supported range. The user is
    /// asked to update the DAEMON; the client does not route and does not fall
    /// back to an unauthenticated path.
    case updateDaemonRequired(found: SemanticVersion, minimum: SemanticVersion)

    /// The daemon is newer than this client understands. The user is asked to
    /// update the APP. The client never stops or downgrades the daemon — a
    /// newer daemon is presumed correct and this client presumed stale.
    case updateAppRequired(found: SemanticVersion, maximumExclusive: SemanticVersion)
}

/// Judges a published descriptor against the contract this client implements.
///
/// Every gate fails closed. There is no "best effort" path and no negotiation:
/// a client that proceeds against a daemon it only partially agrees with is a
/// client that will discover the disagreement at the worst possible moment.
public struct DaemonCompatibilityPolicy: Sendable, Equatable {

    /// The provider whose descriptors this policy accepts.
    public let providerIdentifier: String

    /// The service this policy accepts.
    public let serviceIdentifier: String

    /// The descriptor schema this policy can parse.
    public let schemaVersion: Int

    /// The client/daemon contract revision this policy implements.
    public let contractRevision: Int

    /// The MCP protocol version this policy requires.
    public let mcpProtocolVersion: String

    /// The capabilities a daemon must advertise.
    public let requiredCapabilities: Set<DaemonCapability>

    /// Build a policy. Production uses `.current`; the explicit initializer
    /// exists so a test can express "a client on the next revision" without
    /// mutating global constants.
    public init(
        providerIdentifier: String,
        serviceIdentifier: String,
        schemaVersion: Int,
        contractRevision: Int,
        mcpProtocolVersion: String,
        requiredCapabilities: Set<DaemonCapability>
    ) {
        self.providerIdentifier = providerIdentifier
        self.serviceIdentifier = serviceIdentifier
        self.schemaVersion = schemaVersion
        self.contractRevision = contractRevision
        self.mcpProtocolVersion = mcpProtocolVersion
        self.requiredCapabilities = requiredCapabilities
    }

    /// The policy every client in this build uses, read straight off
    /// `DaemonContract` so the constants have exactly one home.
    public static let current = DaemonCompatibilityPolicy(
        providerIdentifier: DaemonContract.providerIdentifier,
        serviceIdentifier: DaemonContract.serviceIdentifier,
        schemaVersion: DaemonContract.schemaVersion,
        contractRevision: DaemonContract.supportedContractRevision,
        mcpProtocolVersion: DaemonContract.mcpProtocolVersion,
        requiredCapabilities: DaemonContract.requiredCapabilities
    )

    /// Judge one descriptor.
    ///
    /// Gate order is deliberate: the schema is checked first because every
    /// later field's meaning depends on it, identity next because a descriptor
    /// from the wrong publisher should be refused before its contents are given
    /// any weight, the endpoint next because it is the field that decides
    /// whether traffic leaves this machine, and capabilities last because they
    /// are the only check whose answer is a list rather than a single defect.
    ///
    /// - Parameter descriptor: The published record to judge.
    /// - Returns: `.compatible`, or the first gate that closed.
    public func evaluate(_ descriptor: DaemonDescriptor) -> DaemonCompatibility {
        guard descriptor.schemaVersion == schemaVersion else {
            return .invalidDescriptor(.unsupportedSchemaVersion)
        }
        guard descriptor.providerIdentifier == providerIdentifier else {
            return .invalidDescriptor(.unknownProvider)
        }
        guard descriptor.serviceIdentifier == serviceIdentifier else {
            return .invalidDescriptor(.unknownService)
        }
        guard Self.isLoopbackEndpoint(descriptor.endpoint) else {
            return .invalidDescriptor(.nonLoopbackEndpoint)
        }
        // Loopback is necessary but not sufficient. The first-party lane has
        // exactly one endpoint, compared whole — a loopback URL carrying a
        // query, a fragment, userinfo, or a different path is still not it.
        guard descriptor.endpoint.absoluteString == DaemonContract.firstPartyEndpoint else {
            return .invalidDescriptor(.wrongEndpoint)
        }
        guard descriptor.authProtocol == DaemonContract.authProtocol else {
            return .invalidDescriptor(.unsupportedAuthProtocol)
        }
        guard descriptor.authKeyIdentifier == DaemonContract.authKeyIdentifier else {
            return .invalidDescriptor(.unknownAuthKeyIdentifier)
        }
        guard descriptor.contractRevision == contractRevision else {
            return .invalidDescriptor(.unsupportedContractRevision)
        }
        guard descriptor.mcpProtocolVersion == mcpProtocolVersion else {
            return .invalidDescriptor(.unsupportedProtocolVersion)
        }
        guard !descriptor.binaryVersion.isEmpty else {
            return .invalidDescriptor(.emptyBinaryVersion)
        }
        // Structural MAC check only. Whether it VERIFIES needs the installation
        // root and happens in the authenticator; a descriptor whose MAC is the
        // wrong shape is refused here so the authenticator never sees one.
        guard descriptor.descriptorMAC.count == 32 else {
            return .invalidDescriptor(.malformedDescriptorMAC)
        }
        let missing = requiredCapabilities.subtracting(descriptor.capabilities)
        guard missing.isEmpty else {
            return .missingCapabilities(missing.sorted())
        }
        // Version range last, because it is the only gate whose answer is an
        // ACTION for the user rather than a refusal. A descriptor that fails any
        // gate above is malformed or hostile; one that reaches here is
        // well-formed and merely on the wrong side of a supported range.
        guard let found = SemanticVersion(descriptor.binaryVersion) else {
            return .invalidDescriptor(.unparseableBinaryVersion)
        }
        if found < DaemonContract.minimumDaemonVersion {
            return .updateDaemonRequired(found: found, minimum: DaemonContract.minimumDaemonVersion)
        }
        if found >= DaemonContract.maximumDaemonVersionExclusive {
            return .updateAppRequired(
                found: found, maximumExclusive: DaemonContract.maximumDaemonVersionExclusive
            )
        }
        return .compatible
    }

    /// Judge a descriptor against a generation pair this client has already
    /// seen, refusing a record that moves either generation backwards.
    ///
    /// Separate from `evaluate` because it needs history: monotonicity is a
    /// property of a SEQUENCE of descriptors, not of any one of them. A daemon
    /// that republishes with a lower generation is either stale or replayed, and
    /// neither is a record to act on.
    ///
    /// - Parameters:
    ///   - descriptor: The record to judge.
    ///   - lastCredentialGeneration: Highest credential generation seen, if any.
    ///   - lastDescriptorGeneration: Highest descriptor generation seen, if any.
    public func evaluate(
        _ descriptor: DaemonDescriptor,
        lastCredentialGeneration: UInt64?,
        lastDescriptorGeneration: UInt64?
    ) -> DaemonCompatibility {
        if let last = lastCredentialGeneration, descriptor.credentialGeneration < last {
            return .invalidDescriptor(.staleGeneration)
        }
        if let last = lastDescriptorGeneration, descriptor.descriptorGeneration < last {
            return .invalidDescriptor(.staleGeneration)
        }
        return evaluate(descriptor)
    }

    /// Whether a URL addresses a daemon on this machine.
    ///
    /// Requires all three of scheme, literal loopback host, and an explicit
    /// port. The port requirement is not pedantry: without it a descriptor
    /// could name `http://127.0.0.1` and URLSession would silently dial port
    /// 80, which is not a port this daemon ever binds.
    ///
    /// - Parameter endpoint: The endpoint from a descriptor.
    /// - Returns: `true` when the endpoint is a loopback daemon address.
    public static func isLoopbackEndpoint(_ endpoint: URL) -> Bool {
        guard endpoint.scheme?.lowercased() == DaemonContract.endpointScheme else { return false }
        // URL strips the brackets from a literal IPv6 host, so `http://[::1]:4242`
        // reports "::1" here and compares directly against the literal set.
        guard let host = endpoint.host?.lowercased(),
              DaemonContract.loopbackHosts.contains(host) else { return false }
        guard let port = endpoint.port, port > 0 else { return false }
        return true
    }
}
