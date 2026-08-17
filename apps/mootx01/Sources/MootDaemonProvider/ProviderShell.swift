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

    /// The contract elements the module digest covers, canonically encoded
    /// with `CanonicalEncoder` in this fixed order:
    /// provider id, service id, endpoint, auth protocol, auth key id,
    /// descriptor schema, contract revision, MCP version, Keychain service,
    /// Keychain account, generation format + wire encoding, the twelve
    /// arbiter wire encodings, the handover step count and lease transcript
    /// field list, and the lease domain. Two shells that agree on this digest
    /// agree on every encoding a peer can observe.
    public static func digestInput() -> [UInt8] {
        [] // RED placeholder.
    }

    /// SHA-256 hex of `digestInput()` — the "shared-provider module digest"
    /// the mission's identity assertion compares across shells.
    public static func moduleDigest() -> String {
        "" // RED placeholder.
    }

    /// The full self-report as canonical sorted-key JSON (one line, UTF-8):
    /// module digest, identifiers, schema/revision/protocol constants,
    /// generation encoding, arbiter encodings, handover/lease format, and the
    /// lease domain. Deterministic byte-for-byte — the live proof diffs the
    /// two shells' outputs directly.
    public static func canonicalReport() -> String {
        "" // RED placeholder.
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
        (ExitCode.usage.rawValue, "") // RED placeholder.
    }
}
