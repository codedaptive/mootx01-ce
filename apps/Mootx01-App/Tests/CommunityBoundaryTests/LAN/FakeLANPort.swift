import Foundation
import MootCommunityUI

// MARK: - FakeLANPort  (APP-07 boundary tests)
//
// Contract-compatible fake daemon conformer for LANControlPort.
// Lives in the test tree; production code never imports or instantiates this.
//
// The real gateway adapter (INTEGRATION-02) substitutes at the same
// LANControlPort abstraction in production.
//
// CRITICAL: this fake does NOT import or reference MootGateway's MootLANServer.
// It is a pure protocol conformer exercising the LANControlPort boundary only.
//
// Design: actor so Swift 6 strict concurrency is satisfied without
// @unchecked Sendable. Tests configure via setters; call-log reads are
// awaited after model operations.
//
// UUID provenance: no real estate UUIDs appear here. Synthetic endpoints use
// the reserved 192.0.2.x documentation range (RFC 5737).

actor FakeLANPort: LANControlPort {

    // MARK: - Configurable results (set per test via setters)

    private var _servingStatus: LANServingStatus
    private var _servingPolicyOutcome: LANServingPolicyLoadOutcome
    private var _startOutcome: LANStartOutcome
    private var _stopOutcome: LANStopOutcome
    private var _eligibilityOutcome: LANEligibilityUpdateOutcome

    // MARK: - Call log

    private(set) var callLog: [String] = []

    // MARK: - Init

    init(
        servingStatus: LANServingStatus = .stopped,
        servingPolicy: LANServingPolicy = LANFakes.defaultPolicy(),
        startOutcome: LANStartOutcome = .started(
            endpoint: LANFakes.defaultEndpoint,
            authState: .valid
        ),
        stopOutcome: LANStopOutcome = .stopped,
        eligibilityOutcome: LANEligibilityUpdateOutcome = .updated(
            newEligibleCount: 10,
            newIneligibleCount: 2
        )
    ) {
        _servingStatus = servingStatus
        _servingPolicyOutcome = .loaded(servingPolicy)
        _startOutcome = startOutcome
        _stopOutcome = stopOutcome
        _eligibilityOutcome = eligibilityOutcome
    }

    // MARK: - Setters (awaitable from @MainActor tests)

    func setServingStatus(_ s: LANServingStatus) { _servingStatus = s }
    func setServingPolicy(_ p: LANServingPolicy) { _servingPolicyOutcome = .loaded(p) }
    func setServingPolicyOutcome(_ outcome: LANServingPolicyLoadOutcome) {
        _servingPolicyOutcome = outcome
    }
    func setStartOutcome(_ o: LANStartOutcome) { _startOutcome = o }
    func setStopOutcome(_ o: LANStopOutcome) { _stopOutcome = o }
    func setEligibilityOutcome(_ o: LANEligibilityUpdateOutcome) { _eligibilityOutcome = o }

    // MARK: - LANControlPort

    func loadServingStatus() async -> LANServingStatus {
        callLog.append("loadServingStatus")
        return _servingStatus
    }

    func loadServingPolicy() async -> LANServingPolicyLoadOutcome {
        callLog.append("loadServingPolicy")
        return _servingPolicyOutcome
    }

    func startServing() async -> LANStartOutcome {
        callLog.append("startServing")
        let outcome = _startOutcome
        // Simulate daemon state change on successful start, so subsequent
        // loadServingStatus() calls from the model return .active.
        if case .started(let ep, let auth) = outcome {
            _servingStatus = .active(endpoint: ep, authState: auth)
        }
        return outcome
    }

    func stopServing() async -> LANStopOutcome {
        callLog.append("stopServing")
        let outcome = _stopOutcome
        // Simulate daemon state change on confirmed stop.
        if case .stopped = outcome {
            _servingStatus = .stopped
        }
        return outcome
    }

    func refreshEligibility() async -> LANEligibilityUpdateOutcome {
        callLog.append("refreshEligibility")
        return _eligibilityOutcome
    }
}

// MARK: - LANFakes — synthetic test data factory
//
// Endpoints use the RFC 5737 documentation range (192.0.2.x) so they cannot
// be confused with real network addresses.

enum LANFakes {

    /// RFC 5737 documentation address — never a real endpoint.
    static let defaultEndpoint = "http://192.0.2.1:4242"
    /// Secondary documentation address for multi-endpoint tests.
    static let altEndpoint = "http://192.0.2.2:4242"

    static func defaultPolicy(
        eligible: Int = 20,
        ineligible: Int = 5,
        description: String = "Synthetic policy: local-only, public records only"
    ) -> LANServingPolicy {
        LANServingPolicy(
            eligibleCount: eligible,
            ineligibleCount: ineligible,
            policyDescription: description
        )
    }
}
