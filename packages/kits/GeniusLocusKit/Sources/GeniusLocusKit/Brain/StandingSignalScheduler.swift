import Foundation
import OSLog
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory
import QueueKit
import LocusKit

/// The standing-signals scheduler — one per estate.
///
/// Architecture: the scheduler owns a single QueueKit instance backed
/// by `PersistenceKitBackend` over `InMemoryStorage`. The RAM-backed
/// queue is the serial dispatch substrate decided in
/// `docs/decisions/DECISION_STANDING_SIGNAL_SCHEDULER_2026-05-21.md`:
/// QueueKit's `drainAvailable()` claim runs at `.serializable`
/// isolation behind a status guard, so exactly one drainer ever
/// claims a job. That is the single-serial-lane guarantee — no
/// per-signal queues, no parallel signal execution against one
/// estate.
///
/// Responsibilities scoped to GLK-04:
///
/// - Hold the registered signals and their schedules.
/// - On `tick(now:)`, find every signal whose schedule is due,
///   invoke its `emit(context)` closure, enqueue each returned
///   emission as a `Job` on the per-estate queue, then drain the
///   queue serially.
/// - For each drained job, route the emission through the
///   appropriate verb (`propose` / `associate`) on the GLK boundary
///   or surface a diagnostic; record the outcome on the signal's
///   report; notify subscribers.
/// - Maintain status, subscription, and emission count state
///   accessible through the `SignalAPI` extension on `GeniusLocusKit`.
///
/// Out of scope here:
///
/// - The six concrete v1 standing signals (architecture spec §11.2)
///   are GLK-05.
/// - The matrix tier is GLK-06.
/// - The training daemon is GLK-07.
/// - Resource budgeting against `ResourceCostEstimate` is later
///   sub-mission work. The estimate is carried in `SignalReport` so
///   downstream agents have the slot already wired.
///
/// Determinism: the scheduler accepts `now: Date` on every tick call;
/// no `Date()` is read inside the scheduler. The conformance gate
/// against the Rust mirror requires this — same inputs in, same
/// emission ordering out, regardless of wall-clock.
public actor StandingSignalScheduler {

    /// Fleet-standard logger.
    private static let logger = Logger(
        subsystem: "com.mootx01.kit",
        category: "StandingSignalScheduler")

    /// The estate this scheduler serves. One scheduler per estate so
    /// the single-serial-lane decision applies per-estate, never
    /// across estates.
    public let handle: EstateHandle

    /// QueueKit instance backing the serial lane. Mounted on a
    /// dedicated InMemoryStorage so scheduler state does not collide
    /// with estate substrate writes — the queue is a transient
    /// dispatch surface, not durable history.
    private let queue: QueueKit

    /// HLC generator used to stamp jobs. The scheduler does not need
    /// the HLC for ordering (jobs are drained in FIFO order from
    /// QueueKit per spec §10), but every QueueKit `Job` carries an
    /// HLC, so the scheduler holds a generator and feeds it.
    /// `var` because `HLCGenerator.send(now:)` is `mutating`; the
    /// actor isolation serialises every mutation.
    private var hlcGenerator: HLCGenerator

    /// Stream identifier used on every job the scheduler enqueues. A
    /// single stream so all signals share one drainer per estate per
    /// the serial-lane decision.
    private let streamID: StreamID

    /// Registered signals, keyed by SignalID. Holds the spec including
    /// the `emit` closure.
    private var signals: [SignalID: SignalSpec] = [:]

    /// When each signal last completed an emit run. Used by interval
    /// triggers to compute next-due, and surfaced in `SignalReport.lastRunAt`.
    private var lastRunAt: [SignalID: Date] = [:]

    /// When each signal last produced at least one emission. Distinct
    /// from `lastRunAt`: a signal that runs but returns no emissions
    /// still updates `lastRunAt` but not `lastEmittedAt`.
    private var lastEmittedAt: [SignalID: Date] = [:]

    /// Current state machine position per signal.
    private var states: [SignalID: SignalState] = [:]

    /// Total emissions produced per signal over the kit's lifetime.
    private var emissionCount: [SignalID: Int] = [:]

    /// Up to N most-recent diagnostic reports per signal, surfaced via
    /// `signalStatus`. Bounded so the report does not grow without
    /// limit; later sub-missions persist diagnostics.
    private var recentDiagnostics: [SignalID: [DiagnosticReport]] = [:]

    /// Up to N most-recent route outcomes per signal, surfaced via
    /// `signalStatus` so the application can audit dispatch decisions.
    private var recentOutcomes: [SignalID: [SignalRouteOutcome]] = [:]

    /// Per-signal subscriber callbacks, keyed by SubscriptionID.
    private var subscribers: [SignalID: [SubscriptionID: @Sendable (SignalEmission) -> Void]] = [:]

    /// Audit trail of every emission the scheduler has drained, in
    /// order. Used by the serial-ordering test and surfaced via
    /// `drainHistory` for diagnostics. Bounded by the same retention
    /// policy as `recentOutcomes` so memory growth stays bounded
    /// during long-running estates.
    private var drainOrderLog: [(signalID: SignalID, classTag: String)] = []

    /// Bound for `recentDiagnostics`, `recentOutcomes`, and
    /// `drainOrderLog`. Sized to the same value used by GLK-03's
    /// projection cache for consistency. Earlier entries are dropped
    /// when the bound is exceeded.
    private static let retention = 64

    /// Routing closure for the `propose` and `associate` verbs. The
    /// scheduler receives this from `GeniusLocusKit.SignalAPI` so it
    /// can call back into the actor without re-entering its
    /// isolation directly. The closure returns `nil` on success and a
    /// non-nil error on a routing failure.
    private let dispatcher: SignalDispatcher

    /// Construct a scheduler for one estate. The QueueKit instance is
    /// freshly minted on an `InMemoryStorage` with the QueueKit
    /// schema applied. Async because schema declaration is async.
    public init(
        handle: EstateHandle,
        hlcGenerator: HLCGenerator,
        dispatcher: SignalDispatcher
    ) async throws {
        self.handle = handle
        self.hlcGenerator = hlcGenerator
        self.streamID = StreamID(
            rawValue: "glk_scheduler_\(handle.estateUUID.uuidString.lowercased())")
        self.dispatcher = dispatcher
        // The scheduler's queue is a transient dispatch substrate, so
        // the PersistenceKitInMemory backend is appropriate — no
        // persistence, no cross-estate sharing. We mint a fresh
        // configuration whose estateID matches the scheduler's
        // EstateHandle so diagnostics correlate cleanly.
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: handle.estateUUID,
            backend: .inMemory))
        try await PersistenceKitBackend.openSchema(on: storage)
        let backend = PersistenceKitBackend(storage: storage)
        self.queue = QueueKit(backend: backend)
        Self.logger.debug("StandingSignalScheduler opened for estate \(handle.estateUUID, privacy: .public)")
    }

    // MARK: - Registration

    /// Register a signal. Returns the SignalID the application uses
    /// for every subsequent call. The signal starts in `.idle`; the
    /// next `tick(now:)` call evaluates whether it is due.
    public func register(_ spec: SignalSpec, registeredAt now: Date) -> SignalID {
        let id = SignalID.generate()
        signals[id] = spec
        states[id] = .idle
        emissionCount[id] = 0
        recentDiagnostics[id] = []
        recentOutcomes[id] = []
        subscribers[id] = [:]
        // Interval triggers schedule first run at `now + interval`.
        // Event and condition triggers do not have a wall-clock next-due.
        if case .interval = spec.trigger {
            lastRunAt[id] = now
        }
        Self.logger.debug("Registered signal \(spec.name, privacy: .public) as \(id.rawValue, privacy: .public)")
        return id
    }

    /// Unregister a signal. Idempotent — unregistering an unknown
    /// SignalID is a no-op. Returns whether the signal was present.
    @discardableResult
    public func unregister(_ id: SignalID) -> Bool {
        let present = signals.removeValue(forKey: id) != nil
        states.removeValue(forKey: id)
        lastRunAt.removeValue(forKey: id)
        lastEmittedAt.removeValue(forKey: id)
        emissionCount.removeValue(forKey: id)
        recentDiagnostics.removeValue(forKey: id)
        recentOutcomes.removeValue(forKey: id)
        subscribers.removeValue(forKey: id)
        return present
    }

    /// Snapshot of the registered signals' current status. Architecture
    /// spec §7.8.5: `signalStatus() -> [SignalReport]`.
    public func report() -> [SignalReport] {
        signals.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { id in
            guard let spec = signals[id] else { return nil }
            return SignalReport(
                signalID: id,
                name: spec.name,
                triggerTag: triggerTag(spec.trigger),
                state: states[id] ?? .idle,
                lastRunAt: lastRunAt[id],
                lastEmittedAt: lastEmittedAt[id],
                emissionCount: emissionCount[id] ?? 0,
                recentDiagnostics: recentDiagnostics[id] ?? [],
                recentOutcomes: recentOutcomes[id] ?? [],
                concurrencyPolicy: spec.concurrencyPolicy)
        }
    }

    // MARK: - Subscription

    /// Register a callback for emissions of `signalID`. Returns a
    /// SubscriptionID the caller passes to `unsubscribe` to detach.
    /// Throws `GeniusLocusKitError.signalNotRegistered` if the signal
    /// is not known.
    public func subscribe(
        _ signalID: SignalID,
        callback: @escaping @Sendable (SignalEmission) -> Void
    ) throws -> SubscriptionID {
        guard signals[signalID] != nil else {
            throw GeniusLocusKitError.schedulerSignalNotRegistered(signalID)
        }
        let sub = SubscriptionID.generate()
        var bucket = subscribers[signalID] ?? [:]
        bucket[sub] = callback
        subscribers[signalID] = bucket
        return sub
    }

    /// Detach a callback. Idempotent — detaching an unknown
    /// SubscriptionID, or detaching from an unregistered signal, is
    /// a no-op.
    public func unsubscribe(_ signalID: SignalID, _ subscription: SubscriptionID) {
        guard var bucket = subscribers[signalID] else { return }
        bucket.removeValue(forKey: subscription)
        subscribers[signalID] = bucket
    }

    // MARK: - Tick and dispatch

    /// Advance the scheduler at `now`. Every signal whose trigger is
    /// due has its `emit` closure invoked; emissions are enqueued on
    /// the serial QueueKit lane; the queue is then drained
    /// synchronously in submission order.
    ///
    /// Determinism: emissions from a single tick share a tick ordinal
    /// so the order in which signals were evaluated is preserved
    /// through the queue's HLC monotonicity (the HLC generator's
    /// logical counter increments per call). The drain processes them
    /// FIFO via QueueKit's `.serializable` claim.
    public func tick(now: Date) async throws {
        // Phase 1: evaluate due signals and enqueue their emissions.
        for id in signals.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let spec = signals[id] else { continue }
            let due = await isDue(spec: spec, signalID: id, now: now)
            guard due else { continue }
            states[id] = .queued
            let context = SignalContext(
                signalID: id, handle: handle, now: now,
                lastRunAt: lastRunAt[id])
            let emissions = await spec.emit(context)
            for emission in emissions {
                try await enqueue(emission, for: id, now: now)
            }
            lastRunAt[id] = now
            if emissions.isEmpty {
                states[id] = .lastRan
            }
            // Else state becomes .running while drain executes; the
            // drain loop transitions to .lastRan after applying.
        }
        // Phase 2: drain the serial lane. Single-drainer policy: one
        // job at a time, FIFO. QueueKit's `.serializable` guard
        // ensures we never double-claim.
        try await drainAll(now: now)
    }

    /// Fire an event-trigger signal explicitly. Architecture spec §11.3
    /// allows event-driven and condition-driven triggers; this is the
    /// scheduler-side entry point the application uses to notify of
    /// an external event. The signal's `emit` closure runs, emissions
    /// are enqueued, and the lane is drained.
    public func requestFire(_ signalID: SignalID, now: Date) async throws {
        guard let spec = signals[signalID] else {
            throw GeniusLocusKitError.schedulerSignalNotRegistered(signalID)
        }
        states[signalID] = .queued
        let context = SignalContext(
            signalID: signalID, handle: handle, now: now,
            lastRunAt: lastRunAt[signalID])
        let emissions = await spec.emit(context)
        for emission in emissions {
            try await enqueue(emission, for: signalID, now: now)
        }
        lastRunAt[signalID] = now
        if emissions.isEmpty {
            states[signalID] = .lastRan
        }
        try await drainAll(now: now)
    }

    /// Test/inspection accessor: ordered list of (signalID, classTag)
    /// pairs the drainer has applied since opening. Used by the
    /// serial-ordering test to assert two signals' emissions never
    /// interleave at job-grain.
    public func drainHistory() -> [(signalID: SignalID, classTag: String)] {
        drainOrderLog
    }

    // MARK: - Internals

    private func isDue(spec: SignalSpec, signalID: SignalID, now: Date) async -> Bool {
        switch spec.trigger {
        case .interval(let seconds):
            guard let last = lastRunAt[signalID] else { return true }
            return now.timeIntervalSince(last) >= seconds
        case .event:
            // Event triggers do not fire from tick; they require
            // explicit `requestFire`. Tick treats them as never-due.
            return false
        case .condition(let predicate):
            // Condition predicates are async; the scheduler awaits the
            // closure inline. The actor's isolation serialises every
            // tick, so the predicate observes a consistent context
            // snapshot.
            let signalContext = SignalContext(
                signalID: signalID, handle: handle, now: now,
                lastRunAt: lastRunAt[signalID])
            return await predicate.evaluate(signalContext)
        }
    }

    private func enqueue(
        _ emission: SignalEmission,
        for signalID: SignalID,
        now: Date
    ) async throws {
        let envelope = SignalJobEnvelope(signalID: signalID, emission: emission)
        let payload = try envelope.encode()
        // QueueKit drains FIFO via the (physical, logical, node) sort
        // declared in PersistenceKitBackend §10; we feed monotonic HLCs
        // so within-tick enqueue order is preserved through the lane.
        // Physical time is the milliseconds-since-epoch convention the
        // HLC generator expects; `now` flows from the caller per the
        // determinism rule in CLAUDE.md (no Date() inside the engine).
        let physMillis = Int64(now.timeIntervalSince1970 * 1000)
        let stamp = hlcGenerator.send(now: physMillis)
        let job = Job(
            id: JobID.generate(),
            streamID: streamID,
            submittedAt: stamp,
            priority: 50,
            payload: payload,
            extensions: [
                "signal_id": .string(signalID.rawValue),
                "class_tag": .string(emission.classTag),
            ])
        try await queue.send(job)
    }

    private func drainAll(now: Date) async throws {
        // The serial-lane decision: a single drainer claims jobs at
        // `.serializable` isolation. We drain until empty so a tick
        // returns once all enqueued work has been applied — there is
        // no background drainer task in GLK-04; the kit's actor model
        // already serialises across callers.
        while true {
            let batch = try await queue.drain()
            if batch.isEmpty { break }
            for entry in batch {
                let (jobID, signalID, emission) = try Self.decodeJob(entry.job)
                states[signalID] = .running
                let outcome = await applyEmission(emission, for: signalID)
                record(outcome: outcome, for: signalID)
                drainOrderLog.append((signalID: signalID, classTag: emission.classTag))
                trimRetention(&drainOrderLog)
                emissionCount[signalID] = (emissionCount[signalID] ?? 0) + 1
                // `lastEmittedAt` records the tick's wall-clock now,
                // not the job's HLC — the HLC is for QueueKit ordering;
                // the report surface speaks Date.
                lastEmittedAt[signalID] = now
                // Subscribers fire after recording so signalStatus
                // observed from inside a callback reflects the update.
                for cb in (subscribers[signalID] ?? [:]).values {
                    cb(emission)
                }
                states[signalID] = .lastRan
                // Mark the queue row complete so QueueKit accounting
                // matches drain history. We surface scheduler-level
                // outcomes through `recentOutcomes`; QueueKit's
                // signal_status is set to `.done` to close the row.
                try await queue.reply(
                    to: jobID,
                    status: .done,
                    artifacts: [])
            }
        }
    }

    private func applyEmission(
        _ emission: SignalEmission,
        for signalID: SignalID
    ) async -> SignalRouteOutcome {
        switch emission {
        case .propose(let frame):
            return await dispatchPropose(frame: frame)
        case .associate(let frame):
            return await dispatchAssociate(frame: frame)
        case .mutateCandidate(let rowID, let kind):
            // §11.1: routed through `propose` for confirmation. We
            // translate to a ProposalFrame with the typed .mutateCandidate
            // kind so downstream consumers can pattern-match exhaustively.
            let frame = ProposalFrame(
                target: rowID,
                kind: .mutateCandidate,
                justification: "kind=\(String(describing: kind))")
            return await dispatchPropose(frame: frame)
        case .diagnostic(let report):
            recordDiagnostic(report, for: signalID)
            return .diagnosticRecorded
        }
    }

    private func dispatchPropose(frame: ProposalFrame) async -> SignalRouteOutcome {
        // Both ProposalFrame (Brain layer) and ProposeFrame (verb surface)
        // carry the typed ProposalKind; the scheduler passes the kind
        // through unchanged so the substrate boundary sees the same typed
        // vocabulary the Brain layer emits.
        let substrateFrame = ProposeFrame(
            target: frame.target,
            kind: frame.kind,
            justification: frame.justification)
        do {
            try await dispatcher.dispatchPropose(handle: handle, frame: substrateFrame)
            return .routed(verb: "propose")
        } catch let verbError as VerbError {
            if case .notSupportedByEstate = verbError {
                return .routedButVerbStubbed(verb: "propose")
            }
            return .routeFailed(verb: "propose", reason: "\(verbError)")
        } catch {
            return .routeFailed(verb: "propose", reason: "\(error)")
        }
    }

    private func dispatchAssociate(frame: AssociationFrame) async -> SignalRouteOutcome {
        let substrateFrame = AssociateFrame(a: frame.a, b: frame.b, weight: frame.weight)
        do {
            try await dispatcher.dispatchAssociate(handle: handle, frame: substrateFrame)
            return .routed(verb: "associate")
        } catch let verbError as VerbError {
            if case .notSupportedByEstate = verbError {
                return .routedButVerbStubbed(verb: "associate")
            }
            return .routeFailed(verb: "associate", reason: "\(verbError)")
        } catch {
            return .routeFailed(verb: "associate", reason: "\(error)")
        }
    }

    private func record(outcome: SignalRouteOutcome, for signalID: SignalID) {
        var bucket = recentOutcomes[signalID] ?? []
        bucket.append(outcome)
        trimRetention(&bucket)
        recentOutcomes[signalID] = bucket
    }

    private func recordDiagnostic(_ report: DiagnosticReport, for signalID: SignalID) {
        var bucket = recentDiagnostics[signalID] ?? []
        bucket.append(report)
        trimRetention(&bucket)
        recentDiagnostics[signalID] = bucket
    }

    private func trimRetention<T>(_ array: inout [T]) {
        if array.count > Self.retention {
            array.removeFirst(array.count - Self.retention)
        }
    }

    private static func decodeJob(_ job: Job) throws -> (JobID, SignalID, SignalEmission) {
        let envelope = try SignalJobEnvelope.decode(from: job.payload)
        return (job.id, envelope.signalID, envelope.emission)
    }
}

// MARK: - Dispatcher contract

/// Routing surface the scheduler calls back into. Implemented by
/// `GeniusLocusKit` in `SignalAPI.swift`. The indirection keeps the
/// scheduler unit-testable against a mock dispatcher and keeps the
/// dependency direction "scheduler → GLK actor" through a value
/// instead of a back-reference, which lets the scheduler exist as a
/// standalone actor.
public protocol SignalDispatcher: Sendable {
    func dispatchPropose(handle: EstateHandle, frame: ProposeFrame) async throws
    func dispatchAssociate(handle: EstateHandle, frame: AssociateFrame) async throws
}

// MARK: - Job envelope

/// On-wire shape of a queued emission. Encoded into the QueueKit
/// `Job.payload` so the drainer can recover the original
/// `SignalEmission` and the signal that produced it. Codable because
/// the same shape is what the Rust mirror compares against in the
/// conformance gate.
internal struct SignalJobEnvelope: Sendable, Codable {
    let signalID: SignalID
    let classTag: String
    let propose: ProposalFrame?
    let associate: AssociationFrame?
    let mutateCandidate: MutateCandidatePayload?
    let diagnostic: DiagnosticReport?

    var emission: SignalEmission {
        switch classTag {
        case "propose":
            if let f = propose { return .propose(f) }
        case "associate":
            if let f = associate { return .associate(f) }
        case "mutate_candidate":
            if let mc = mutateCandidate {
                return .mutateCandidate(rowID: mc.rowID, kind: mc.kind.materialise())
            }
        case "diagnostic":
            if let d = diagnostic { return .diagnostic(d) }
        default: break
        }
        // Default to a diagnostic with the malformed tag so the
        // drainer still observes a routable emission rather than
        // crashing. The error is surfaced via the signal's
        // diagnostics list.
        return .diagnostic(DiagnosticReport(
            title: "scheduler.envelope.invalid",
            detail: "Unknown class tag \(classTag)",
            observedAt: Date(timeIntervalSince1970: 0)))
    }

    init(signalID: SignalID, emission: SignalEmission) {
        self.signalID = signalID
        self.classTag = emission.classTag
        switch emission {
        case .propose(let f):
            self.propose = f
            self.associate = nil
            self.mutateCandidate = nil
            self.diagnostic = nil
        case .associate(let f):
            self.propose = nil
            self.associate = f
            self.mutateCandidate = nil
            self.diagnostic = nil
        case .mutateCandidate(let row, let kind):
            self.propose = nil
            self.associate = nil
            self.mutateCandidate = MutateCandidatePayload(
                rowID: row, kind: MutationKindPayload.encode(kind))
            self.diagnostic = nil
        case .diagnostic(let d):
            self.propose = nil
            self.associate = nil
            self.mutateCandidate = nil
            self.diagnostic = d
        }
    }

    func encode() throws -> Data {
        try WireFormat.encoder.encode(self)
    }

    static func decode(from data: Data) throws -> SignalJobEnvelope {
        try WireFormat.decoder.decode(SignalJobEnvelope.self, from: data)
    }
}

/// Wire shape for `mutateCandidate` emissions. `MutationKind` is not
/// Codable today (associated values for sensitivity and trust
/// corrections); this struct carries the case tag and any associated
/// payload so the drainer can rebuild the kind.
internal struct MutateCandidatePayload: Sendable, Codable {
    let rowID: RowID
    let kind: MutationKindPayload
}

internal struct MutationKindPayload: Sendable, Codable {
    let tag: String
    let sensitivity: String?
    let trust: String?

    static func encode(_ kind: MutationKind) -> MutationKindPayload {
        switch kind {
        case .confirm: return MutationKindPayload(tag: "confirm", sensitivity: nil, trust: nil)
        case .reject: return MutationKindPayload(tag: "reject", sensitivity: nil, trust: nil)
        case .contest: return MutationKindPayload(tag: "contest", sensitivity: nil, trust: nil)
        case .resolve: return MutationKindPayload(tag: "resolve", sensitivity: nil, trust: nil)
        case .supersede: return MutationKindPayload(tag: "supersede", sensitivity: nil, trust: nil)
        case .revive: return MutationKindPayload(tag: "revive", sensitivity: nil, trust: nil)
        case .accept: return MutationKindPayload(tag: "accept", sensitivity: nil, trust: nil)
        case .correctSensitivity(let s):
            return MutationKindPayload(
                tag: "correct_sensitivity",
                sensitivity: "\(s)", trust: nil)
        case .correctTrust(let t):
            return MutationKindPayload(
                tag: "correct_trust",
                sensitivity: nil, trust: "\(t)")
        }
    }

    /// Reconstruct a `MutationKind` from the wire shape. For the two
    /// associated-value cases the wire-decoded form rebuilds the
    /// default value because the substrate-level mutation today is
    /// stubbed; the wire-encoded string is preserved in the outcome
    /// log for diagnostic visibility. When the Brain layer's verb
    /// bodies land they will tighten this round-trip.
    func materialise() -> MutationKind {
        switch tag {
        case "confirm": return .confirm
        case "reject": return .reject
        case "contest": return .contest
        case "resolve": return .resolve
        case "supersede": return .supersede
        case "revive": return .revive
        case "accept": return .accept
        case "correct_sensitivity":
            return .correctSensitivity(.normal)
        case "correct_trust":
            return .correctTrust(.proposed)
        default:
            return .confirm
        }
    }
}

