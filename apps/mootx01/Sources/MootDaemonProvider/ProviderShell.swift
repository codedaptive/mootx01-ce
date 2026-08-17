import Foundation
import AriaMCP

// MARK: - MACD-2c1 — the shared shell entry and the canonical self-report
//
// Kong K2: the direct Developer-ID shell and the sandboxed bundled helper are
// THIN MAINS over this one module. Everything a shell does lives here, so the
// two targets compile identical substance and their self-reports are
// structurally identical — "parallel copies fail" enforced by there being
// nothing in a shell to diverge.
//
// c1 shell modes are run-to-completion; the resident service mode is
// MACD-2c2's deliverable and no run loop starts here.

/// The canonical self-report both shells must emit IDENTICALLY.
public enum ProviderSelfReport {

    /// The generation wire-encoding identifier reported and digested.
    /// Generations travel as decimal strings everywhere (spec 1.40.0).
    public static let generationEncoding = "uint64-decimal-string"

    /// The contract elements the module digest covers, canonically encoded
    /// with `CanonicalEncoder` in this fixed order:
    /// provider id, service id, endpoint, auth protocol, auth key id,
    /// descriptor schema, contract revision, MCP version, Keychain service,
    /// Keychain account, generation format + wire encoding, the twelve
    /// arbiter wire encodings, the handover step count, the lease transcript
    /// field list, and the lease domain. Two shells that agree on this digest
    /// agree on every encoding a peer can observe.
    public static func digestInput() -> [UInt8] {
        var encoder = CanonicalEncoder()
        encoder.appendString("mootx01-daemon-provider-module-v1")
        encoder.appendString(FirstPartyAuthProtocol.providerIdentifier)
        encoder.appendString(FirstPartyAuthProtocol.serviceIdentifier)
        encoder.appendString(FirstPartyAuthProtocol.endpoint)
        encoder.appendString(FirstPartyAuthProtocol.authProtocolIdentifier)
        encoder.appendString(FirstPartyAuthProtocol.authKeyIdentifier)
        encoder.appendUInt64(UInt64(bitPattern: Int64(FirstPartyAuthProtocol.descriptorSchemaVersion)))
        encoder.appendUInt64(UInt64(bitPattern: Int64(FirstPartyAuthProtocol.contractRevision)))
        encoder.appendString(FirstPartyAuthProtocol.mcpProtocolVersion)
        encoder.appendString(FirstPartyAuthProtocol.keychainService)
        encoder.appendString(FirstPartyAuthProtocol.keychainAccount)
        encoder.appendString(GenerationStore.formatIdentifier)
        encoder.appendString(generationEncoding)
        for state in ProviderArbiterState.allWireEncodings {
            encoder.appendString(state)
        }
        encoder.appendUInt64(UInt64(HandoverStep.allCases.count))
        for field in HandoverLease.transcriptFields {
            encoder.appendString(field)
        }
        encoder.appendString(HandoverLease.leaseDomain)
        return encoder.bytes
    }

    /// SHA-256 hex of `digestInput()` — the "shared-provider module digest"
    /// the mission's identity assertion compares across shells.
    public static func moduleDigest() -> String {
        FirstPartyAuthProtocol.sha256(digestInput())
            .map { String(format: "%02x", $0) }.joined()
    }

    /// The full self-report as canonical sorted-key JSON (one line, UTF-8):
    /// module digest, identifiers, schema/revision/protocol constants,
    /// generation encoding, arbiter encodings, handover/lease format, and the
    /// lease domain. Deterministic byte-for-byte — the live proof diffs the
    /// two shells' outputs directly.
    public static func canonicalReport() -> String {
        let object: [String: Any] = [
            "arbiterStates": ProviderArbiterState.allWireEncodings,
            "authKeyIdentifier": FirstPartyAuthProtocol.authKeyIdentifier,
            "authProtocol": FirstPartyAuthProtocol.authProtocolIdentifier,
            "contractRevision": FirstPartyAuthProtocol.contractRevision,
            "descriptorSchemaVersion": FirstPartyAuthProtocol.descriptorSchemaVersion,
            "endpoint": FirstPartyAuthProtocol.endpoint,
            "generationEncoding": generationEncoding,
            "generationFormat": GenerationStore.formatIdentifier,
            "handoverStepCount": HandoverStep.allCases.count,
            "keychainAccount": FirstPartyAuthProtocol.keychainAccount,
            "keychainService": FirstPartyAuthProtocol.keychainService,
            "leaseDomain": HandoverLease.leaseDomain,
            "leaseTranscriptFields": HandoverLease.transcriptFields,
            "mcpProtocolVersion": FirstPartyAuthProtocol.mcpProtocolVersion,
            "moduleDigest": moduleDigest(),
            "providerIdentifier": FirstPartyAuthProtocol.providerIdentifier,
            "serviceIdentifier": FirstPartyAuthProtocol.serviceIdentifier,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            // Unreachable for a literal dictionary of strings and arrays;
            // an empty report would fail the identity assertion loudly.
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The shared thin-shell entry point.
public enum DaemonShellMain {

    /// Exit codes, fixed and documented for the proof drivers.
    public enum ExitCode: Int32, Sendable {
        /// Success (self-report emitted; or race won and completed).
        case success = 0
        /// Unknown or malformed arguments.
        case usage = 64
        /// Ineligible — refused before the lock, zero side effects.
        case ineligible = 2
        /// Race lost — lock unavailable, zero side-effect callbacks.
        case lockLost = 3
        /// Any other refusal.
        case failure = 1
    }

    /// Run one shell invocation.
    ///
    /// Modes:
    /// - `self-report` — print `ProviderSelfReport.canonicalReport()` and exit.
    /// - `race --context <uuid> [--hold-ms <n>]` — proof mode: judge REAL
    ///   eligibility (reported honestly, never overridden), resolve the REAL
    ///   App Group root, then race for the provider lock inside the named
    ///   proof context with JOURNALING FAKE authorities (file-backed Keychain
    ///   fake, counting estate/bind/session fakes). The production
    ///   data-protection Keychain is NEVER touched in proof mode — minting
    ///   the production credential from a proof would be a real installation
    ///   act, which is c2's, behind the real pipeline only.
    ///
    /// The context argument is a UUID NAME nested under the resolver-derived
    /// root — argv never supplies a path (Perkins P2), and no mode deletes
    /// any one-use record (Perkins P10/F3: cleanup belongs to the driver that
    /// owns the context, not to a shell flag).
    ///
    /// - Returns: The process exit code; the caller passes it to `exit(2)`.
    public static func run(arguments: [String]) async -> Int32 {
        let (code, output) = await runCollecting(arguments: arguments)
        if !output.isEmpty { print(output) }
        return code
    }

    /// `run(arguments:)` with the output returned instead of printed, so the
    /// tests judge exact bytes and the shells stay printable-only wrappers.
    public static func runCollecting(arguments: [String]) async -> (code: Int32, output: String) {
        guard let mode = arguments.first else {
            return (ExitCode.usage.rawValue, usageText)
        }
        switch mode {
        case "self-report":
            guard arguments.count == 1 else { return (ExitCode.usage.rawValue, usageText) }
            return (ExitCode.success.rawValue, ProviderSelfReport.canonicalReport())
        case "race":
            guard let options = RaceOptions(arguments: Array(arguments.dropFirst())) else {
                return (ExitCode.usage.rawValue, usageText)
            }
            return await runRace(options)
        default:
            return (ExitCode.usage.rawValue, usageText)
        }
    }

    private static let usageText = """
    usage: mootx01-daemon self-report
           mootx01-daemon race --context <uuid> [--hold-ms <milliseconds>]
    """

    /// Parsed race-mode options. Failable parse: anything not exactly the
    /// grammar above is a usage error before any side effect.
    private struct RaceOptions {
        let context: String
        let holdMilliseconds: UInt64

        init?(arguments: [String]) {
            var context: String?
            var hold: UInt64 = 0
            var index = 0
            while index < arguments.count {
                switch arguments[index] {
                case "--context":
                    guard index + 1 < arguments.count,
                          UUID(uuidString: arguments[index + 1]) != nil else { return nil }
                    context = arguments[index + 1]
                    index += 2
                case "--hold-ms":
                    guard index + 1 < arguments.count,
                          let parsed = UInt64(arguments[index + 1]), parsed <= 60_000 else { return nil }
                    hold = parsed
                    index += 2
                default:
                    return nil
                }
            }
            guard let context else { return nil }
            self.context = context
            holdMilliseconds = hold
        }
    }

    /// The proof race: real eligibility, real resolver, fake authorities.
    private static func runRace(_ options: RaceOptions) async -> (code: Int32, output: String) {
        #if canImport(Security)
        let readback: any EntitlementReadback = SecCodeEntitlementReadback()
        #else
        // Non-Darwin builds of this module have no signature to read back;
        // the race mode honestly reports itself unsupported.
        return (ExitCode.failure.rawValue, #"{"mode":"race","outcome":"unsupported-platform"}"#)
        #endif

        // Honest eligibility first: proof mode never overrides the judgment.
        let identity: SignedProcessIdentity
        do {
            identity = try readback.processIdentity()
        } catch {
            return (ExitCode.failure.rawValue, raceReport(outcome: "readback-failed", identity: nil, recorder: nil))
        }
        let eligibility: ProviderEligibility
        do {
            eligibility = try ProviderEligibilityJudge.judge(identity)
        } catch let DaemonProviderError.ineligible(reason) {
            return (
                ExitCode.ineligible.rawValue,
                raceReport(outcome: "ineligible-\(reason.rawValue)", identity: identity, recorder: nil)
            )
        } catch {
            return (ExitCode.failure.rawValue, raceReport(outcome: "judgment-failed", identity: identity, recorder: nil))
        }

        // Eligible: race inside the proof context with journaling fakes.
        let recorder = ProofCallRecorder()
        let provider = DaemonProvider(
            configuration: DaemonProviderConfiguration(
                instanceIdentifier: UUID(),
                binaryVersion: "0.0.0-proof",
                capabilities: [
                    DescriptorPublisher.authenticatedFirstPartyCapability,
                    "resident-estate", "tool-surface",
                ],
                proofContext: options.context
            ),
            readback: readback,
            resolver: AppGroupRootResolver(),
            keychain: ProofFileKeychain(
                recorder: recorder, context: options.context,
                // The SAME signed group spelling the provider will resolve
                // with, so both racing shells' fake "keychain" is one file.
                appGroupIdentifier: eligibility.appGroupIdentifier
            ),
            estate: ProofEstate(recorder: recorder),
            bind: ProofBind(recorder: recorder),
            sessions: ProofSessions(recorder: recorder),
            // The shell is the COMPOSITION ROOT: this is the one place the
            // real wall clock and real randomness are allowed to be read,
            // because this is where they are injected FROM. Engines below
            // only ever see the closures.
            clock: { UInt64(Date().timeIntervalSince1970) },
            randomBytes: { count in
                var bytes = [UInt8](repeating: 0, count: count)
                for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
                return bytes
            }
        )
        do {
            _ = try await provider.activate()
            if options.holdMilliseconds > 0 {
                try? await Task.sleep(nanoseconds: options.holdMilliseconds * 1_000_000)
            }
            _ = try? await provider.shutdown()
            return (ExitCode.success.rawValue, raceReport(outcome: "lock-owner", identity: identity, recorder: recorder))
        } catch DaemonProviderError.lockUnavailable {
            return (ExitCode.lockLost.rawValue, raceReport(outcome: "lock-lost", identity: identity, recorder: recorder))
        } catch {
            return (ExitCode.failure.rawValue, raceReport(outcome: "activation-failed", identity: identity, recorder: recorder))
        }
    }

    /// One-line JSON race report. Counts, classifications, and the module
    /// digest — never a path, key, or account value.
    private static func raceReport(
        outcome: String, identity: SignedProcessIdentity?, recorder: ProofCallRecorder?
    ) -> String {
        var object: [String: Any] = [
            "mode": "race",
            "moduleDigest": ProviderSelfReport.moduleDigest(),
            "outcome": outcome,
        ]
        if let identity {
            object["signingClass"] = identity.signingClass.rawValue
            object["team"] = identity.teamIdentifier ?? ""
        }
        object["callbacks"] = [
            "bind": recorder?.count(prefix: "bind") ?? 0,
            "estate": recorder?.count(prefix: "estate") ?? 0,
            "keychain": recorder?.count(prefix: "keychain") ?? 0,
            "sessions": recorder?.count(prefix: "sessions") ?? 0,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return #"{"mode":"race","outcome":"report-encoding-failed"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Proof-mode fakes (shell only, journaling, never production)

/// A lock-guarded event counter for the proof shell's fakes.
final class ProofCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    func count(prefix: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { $0.hasPrefix(prefix) }.count
    }
}

/// A file-backed Keychain FAKE for the proof race: the "root" lives in a file
/// inside the proof context, so two racing shells share it while the real
/// data-protection Keychain is never touched (production darkness — the real
/// credential mint is a real installation act and belongs to c2's pipeline).
struct ProofFileKeychain: KeychainItemAuthority {
    let recorder: ProofCallRecorder
    let context: String
    /// The signed App Group spelling from the judged eligibility — the same
    /// identifier the provider resolves with.
    let appGroupIdentifier: String

    /// The fake item's location: inside the proof context, resolved through
    /// the SAME resolver-derived layout the provider uses — never argv.
    private func itemURL() -> URL? {
        guard let layout = try? ProviderRootLayout.resolve(
            resolver: AppGroupRootResolver(),
            groupIdentifier: appGroupIdentifier,
            proofContext: context
        ) else { return nil }
        return layout.providerDirectory.appendingPathComponent("proof-root.bin")
    }

    func copyItem(service: String, account: String, accessGroup: String) -> KeychainReadResult {
        recorder.record("keychain.copy")
        guard let url = itemURL() else { return .unavailable }
        guard let data = try? Data(contentsOf: url) else { return .notFound }
        return .found(Array(data))
    }

    func addItem(service: String, account: String, accessGroup: String, data: [UInt8]) -> KeychainWriteStatus {
        recorder.record("keychain.add")
        guard let url = itemURL() else { return .unavailable }
        if FileManager.default.fileExists(atPath: url.path) { return .duplicate }
        do {
            try Data(data).write(to: url, options: [.withoutOverwriting])
            return .added
        } catch {
            return FileManager.default.fileExists(atPath: url.path) ? .duplicate : .unavailable
        }
    }
}

/// Proof estate authority: counts, returns a fixed proof identity.
struct ProofEstate: EstateLifecycleAuthority {
    let recorder: ProofCallRecorder

    /// A fixed, documented proof-estate identity — obviously synthetic.
    static let proofEstate = UUID(uuidString: "F00FF00F-0000-4000-8000-000000000001")!

    func stopWrites() async throws { recorder.record("estate.stopWrites") }
    func drain() async throws { recorder.record("estate.drain") }
    func checkpoint() async throws { recorder.record("estate.checkpoint") }
    func closeEstate() async throws { recorder.record("estate.close") }
    func openEstate() async throws -> EstateReadyProof {
        recorder.record("estate.open")
        return EstateReadyProof(estateIdentifier: Self.proofEstate, schemaVersion: 1)
    }
}

/// Proof bind authority: counts and reports the contracted readback WITHOUT
/// binding — the race proof is about the LOCK; a real bind belongs to the
/// resident service (c2), and a proof that bound port 4242 would collide
/// with any genuinely running daemon on the machine.
struct ProofBind: BindAuthority {
    let recorder: ProofCallRecorder
    func bindLoopback() async throws -> BindProof {
        recorder.record("bind.loopback")
        return BindProof(host: "127.0.0.1", port: 4242)
    }
}

/// Proof session authority: counts.
struct ProofSessions: SessionRevocationAuthority {
    let recorder: ProofCallRecorder
    func revokeAllSessions() async { recorder.record("sessions.revokeAll") }
}
