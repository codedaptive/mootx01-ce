import Foundation
import LocusKit

// MARK: - Identifiers

/// Identifier minted when a signal is registered. Returned from
/// `registerStandingSignal` and used as the handle for every other
/// `signal*` call.
///
/// Stable across the lifetime of a kit instance; not persisted by
/// GLK-04. Persistence is a later sub-mission (the training daemon
/// keeps long-running state) and is intentionally out of scope here.
public struct SignalID: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Fresh identifier as a lowercase UUID string. Matches the
    /// shape used by QueueKit's `JobID.generate` for legibility in
    /// joined diagnostics.
    public static func generate() -> SignalID {
        SignalID(rawValue: UUID().uuidString.lowercased())
    }
}

/// Identifier minted when `signalSubscribe` registers a callback;
/// returned to the caller so they can later call `signalUnsubscribe`
/// with the same handle.
public struct SubscriptionID: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func generate() -> SubscriptionID {
        SubscriptionID(rawValue: UUID().uuidString.lowercased())
    }
}

// MARK: - SignalSpec building blocks

/// How a signal becomes due. Architecture spec §11.3 enumerates the
/// three trigger families: event-driven, interval-driven, and
/// condition-driven.
///
/// `event` and `condition` are accepted by the schedule layer in
/// GLK-04 but only `interval` fires automatically from the scheduler's
/// tick. Event and condition triggers are surfaced through
/// `requestFire(_:in:now:)` so the application or a sibling daemon
/// can notify the scheduler; this keeps the scheduler deterministic
/// for the conformance gate without committing to a specific event
/// bus.
public enum SignalTrigger: Sendable {
    /// External event by name. The application notifies the scheduler
    /// when the event occurs.
    case event(name: String)
    /// Periodic, fires every `seconds` interval starting from the
    /// signal's registration time.
    case interval(seconds: TimeInterval)
    /// Condition predicate evaluated on every tick.
    case condition(ConditionPredicate)
}

/// Named predicate carried inside `SignalTrigger.condition`. The name
/// is surfaced in `SignalReport` so diagnostics can identify the
/// condition without exposing the closure.
public struct ConditionPredicate: Sendable {
    public let name: String
    public let evaluate: @Sendable (SignalContext) async -> Bool

    public init(
        name: String,
        evaluate: @escaping @Sendable (SignalContext) async -> Bool
    ) {
        self.name = name
        self.evaluate = evaluate
    }
}

/// Per-signal estimate from architecture spec §11.3. Carried as
/// metadata; the GLK-04 scheduler exposes it in `SignalReport` but
/// does not yet budget against it. Budgeting is later sub-mission
/// territory.
public struct ResourceCostEstimate: Sendable, Equatable, Codable {
    public let cpu: Double
    public let memoryBytes: Int64
    public let ioOps: Int64

    public init(cpu: Double, memoryBytes: Int64, ioOps: Int64) {
        self.cpu = cpu
        self.memoryBytes = memoryBytes
        self.ioOps = ioOps
    }

    public static let zero = ResourceCostEstimate(
        cpu: 0, memoryBytes: 0, ioOps: 0)
}

/// Concurrency policy from architecture spec §7.8.5. GLK-04 dispatches
/// a single serial lane per estate (per DECISION_STANDING_SIGNAL_SCHEDULER
/// _2026-05-21), so the only behavioural difference today is whether
/// repeated fires of the same signal coalesce. `single` is the
/// production default; `bounded` is accepted but treated as `single`
/// at this serialization tier and surfaced as such in diagnostics.
public enum ConcurrencyPolicy: Sendable, Equatable, Codable {
    case single
    case bounded(maxInstances: Int)
}

/// Caller-supplied signal description from architecture spec §7.8.5.
///
/// `emit` is the only execution-bearing field: when the trigger fires,
/// the scheduler invokes `emit(context)` and feeds the returned
/// emissions through the single serial lane. The closure is
/// `@Sendable` so the scheduler can hop actor isolations when needed.
public struct SignalSpec: Sendable {
    public let name: String
    public let trigger: SignalTrigger
    public let resourceCost: ResourceCostEstimate
    public let freshnessTarget: TimeInterval
    public let concurrencyPolicy: ConcurrencyPolicy
    public let emit: @Sendable (SignalContext) async -> [SignalEmission]

    public init(
        name: String,
        trigger: SignalTrigger,
        resourceCost: ResourceCostEstimate = .zero,
        freshnessTarget: TimeInterval = 60,
        concurrencyPolicy: ConcurrencyPolicy = .single,
        emit: @escaping @Sendable (SignalContext) async -> [SignalEmission]
    ) {
        self.name = name
        self.trigger = trigger
        self.resourceCost = resourceCost
        self.freshnessTarget = freshnessTarget
        self.concurrencyPolicy = concurrencyPolicy
        self.emit = emit
    }
}

/// Context handed to `SignalSpec.emit`. Carries the addressing slot
/// (`handle`), the deterministic clock (`now`), and provenance
/// metadata so the closure can build emissions without reaching back
/// into the scheduler's internals.
public struct SignalContext: Sendable {
    public let signalID: SignalID
    public let handle: EstateHandle
    public let now: Date
    public let lastRunAt: Date?

    public init(
        signalID: SignalID,
        handle: EstateHandle,
        now: Date,
        lastRunAt: Date?
    ) {
        self.signalID = signalID
        self.handle = handle
        self.now = now
        self.lastRunAt = lastRunAt
    }
}

// MARK: - The four emission classes (architecture spec §11.1)

/// One unit of work a standing signal asks the substrate to do.
/// Architecture spec §11.1 enumerates exactly four classes; this
/// surface mirrors the contract.
///
/// `mutateCandidate` is routed through the `propose` verb per
/// §11.1 ("routed through `propose` for confirmation"); the scheduler
/// translates it into a `ProposalFrame` with `kind = "mutate_candidate"`
/// before dispatching, so callers do not need to perform that
/// rewrite themselves.
public enum SignalEmission: Sendable {
    case propose(ProposalFrame)
    case associate(AssociationFrame)
    case mutateCandidate(rowID: RowID, kind: MutationKind)
    case diagnostic(DiagnosticReport)

    /// Coarse identifier for the emission class. Used by the scheduler
    /// to wire each case to its routing arm and surfaced in
    /// diagnostics. Stable string values so a Rust mirror can compare
    /// against the same vocabulary in the conformance gate.
    public var classTag: String {
        switch self {
        case .propose: return "propose"
        case .associate: return "associate"
        case .mutateCandidate: return "mutate_candidate"
        case .diagnostic: return "diagnostic"
        }
    }
}

/// Brain-layer proposal frame for the `propose` verb. GLK-02's
/// `Verbs/Frames.swift` defines a separate `ProposeFrame` for the
/// substrate boundary; the Brain layer's emission carries the same
/// three fields and is converted to a `ProposeFrame` by the
/// scheduler before dispatch. Two types coexist because the Brain
/// layer's vocabulary is `ProposalFrame` (architecture spec §7.8.5
/// `SignalEmission`) and the substrate verb's vocabulary is
/// `ProposeFrame` (architecture spec §7.8.3 frames). Keeping the
/// names aligned to the spec avoids ambiguity for downstream agents.
public struct ProposalFrame: Sendable, Equatable, Codable {
    public let target: RowID
    /// Typed proposal taxonomy. See `ProposalKind` for the full
    /// vocabulary including production labels and test cases.
    public let kind: ProposalKind
    public let justification: String?

    public init(target: RowID, kind: ProposalKind, justification: String? = nil) {
        self.target = target
        self.kind = kind
        self.justification = justification
    }
}

/// Brain-layer association frame for the `associate` verb. Mirrors
/// the substrate-side `AssociateFrame` (`Verbs/Frames.swift`) with
/// the same three fields. The scheduler converts to `AssociateFrame`
/// before dispatch.
public struct AssociationFrame: Sendable, Equatable, Codable {
    public let a: RowID
    public let b: RowID
    public let weight: Double

    public init(a: RowID, b: RowID, weight: Double) {
        self.a = a
        self.b = b
        self.weight = weight
    }
}

/// Diagnostic emission. Architecture spec §11.1 specifies this class
/// is "not a verb call; surfaced via `signal_status()`." The
/// scheduler retains the report on the signal's record and exposes it
/// through `SignalReport.recentDiagnostics`.
public struct DiagnosticReport: Sendable, Equatable, Codable {
    public let title: String
    public let detail: String
    public let observedAt: Date

    public init(title: String, detail: String, observedAt: Date) {
        self.title = title
        self.detail = detail
        self.observedAt = observedAt
    }
}

// MARK: - Schedule state

/// Operational state of a registered signal. Surfaced in
/// `SignalReport`. The values are stable strings on the Codable
/// boundary so a Rust mirror can compare against the same vocabulary
/// in the conformance gate.
public enum SignalState: Sendable, Equatable, Codable {
    case idle
    case queued
    case running
    case lastRan
    case errored(reason: String)

    public var tag: String {
        switch self {
        case .idle: return "idle"
        case .queued: return "queued"
        case .running: return "running"
        case .lastRan: return "last_ran"
        case .errored: return "errored"
        }
    }
}

/// Outcome of routing one `SignalEmission`. Recorded per emission in
/// `SignalReport.recentOutcomes` so the application can audit what
/// the scheduler did with each unit of work.
public enum SignalRouteOutcome: Sendable, Equatable, Codable {
    /// Routed through the named verb successfully — the verb is fully
    /// live in the estate and returned without error.
    case routed(verb: String)
    /// Verb call returned `notSupportedByEstate`. The route was
    /// attempted at the GLK boundary; the estate declined. All nine
    /// verbs — including `mutate` with all five state-axis kinds
    /// (`confirm`, `reject`, `contest`, `resolve`, `revive`) — are
    /// fully wired in LocusKit both ports (B2-1).
    case routedButVerbStubbed(verb: String)
    /// Diagnostic emission; surfaced through `signalStatus` instead
    /// of a verb call.
    case diagnosticRecorded
    /// Verb call failed for a reason other than the documented stub.
    case routeFailed(verb: String, reason: String)
}

/// Snapshot of one signal's status. Returned in the array from
/// `signalStatus`. Equatable so tests can assert against expected
/// reports; Codable so the Rust mirror can compare against the same
/// JSON-shape vector when the conformance harness wires through.
public struct SignalReport: Sendable, Equatable, Codable {
    public let signalID: SignalID
    public let name: String
    public let triggerTag: String
    public let state: SignalState
    public let lastRunAt: Date?
    public let lastEmittedAt: Date?
    public let emissionCount: Int
    public let recentDiagnostics: [DiagnosticReport]
    public let recentOutcomes: [SignalRouteOutcome]
    public let concurrencyPolicy: ConcurrencyPolicy

    public init(
        signalID: SignalID,
        name: String,
        triggerTag: String,
        state: SignalState,
        lastRunAt: Date?,
        lastEmittedAt: Date?,
        emissionCount: Int,
        recentDiagnostics: [DiagnosticReport],
        recentOutcomes: [SignalRouteOutcome],
        concurrencyPolicy: ConcurrencyPolicy
    ) {
        self.signalID = signalID
        self.name = name
        self.triggerTag = triggerTag
        self.state = state
        self.lastRunAt = lastRunAt
        self.lastEmittedAt = lastEmittedAt
        self.emissionCount = emissionCount
        self.recentDiagnostics = recentDiagnostics
        self.recentOutcomes = recentOutcomes
        self.concurrencyPolicy = concurrencyPolicy
    }
}

/// Stable string for a trigger's kind, surfaced in `SignalReport.triggerTag`
/// so reports stay Codable without leaking the closure-bearing
/// `SignalTrigger` shape itself.
internal func triggerTag(_ trigger: SignalTrigger) -> String {
    switch trigger {
    case .event: return "event"
    case .interval: return "interval"
    case .condition: return "condition"
    }
}
