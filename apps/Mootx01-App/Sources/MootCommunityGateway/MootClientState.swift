import Foundation

// MARK: - Client state
//
// What a macOS surface may honestly say about its connection to the estate.
//
// The states below are a PROJECTION of two observations that already exist —
// the provider's registration status and `DaemonReadinessState` — into the
// vocabulary a view can render. The projection is a pure, total function so the
// mapping can be exhaustively tested without a daemon, a login item, or a port.
//
// TWO DISTINCTIONS ARE DELIBERATELY PRESERVED rather than collapsed, because
// collapsing them would destroy the only thing a user could act on:
//
//   - `updateDaemonRequired` vs `updateAppRequired`. Both are "a version does
//     not match", but one is fixed by updating the daemon and the other by
//     updating the app, and the client must never resolve the second by
//     stopping or downgrading the daemon. A single "update required" state
//     would leave the user guessing which.
//
//   - `authenticationFailed` vs `handshakeFailed`. The first means the session
//     never authenticated. The second means it authenticated and then the
//     daemon disagreed with its own descriptor — a much more serious condition,
//     since something authenticated is misreporting which estate it holds.
//
// `providerUnavailable` is likewise distinct from `notInstalled`: launchd being
// unable to find the bundle at all is a broken installation, not an
// un-run installation, and the remedies differ.
//
// NOTHING HERE IS DERIVED FROM A LISTENING PORT. Readiness already refuses that
// definition, and this projection inherits the refusal: no input it accepts can
// report `.ready` without a descriptor that passed every readiness gate.

/// What the resident provider's registration looks like.
///
/// Mirrors the cases of `SMAppService.Status` as a platform-independent value
/// so the projection below can be exercised on any platform.
public enum ProviderRegistrationObservation: String, Sendable, Equatable, CaseIterable {

    /// The provider has never been registered.
    case notRegistered

    /// Registered, and waiting on the user to approve it in System Settings.
    case requiresApproval

    /// Registered and approved.
    case enabled

    /// launchd cannot resolve the provider bundle — a broken installation.
    case notFound
}

/// What a surface may say about its connection to the estate.
public enum MootClientState: Sendable, Equatable {

    /// The user must approve the provider before anything else can proceed.
    case approvalRequired

    /// A registration request is in flight.
    case installing

    /// The provider has never been registered.
    case notInstalled

    /// launchd cannot find the provider bundle.
    case providerUnavailable

    /// Registered and approved; no descriptor has passed every gate yet.
    case starting

    /// Every readiness gate passed. Carries the estate that was agreed to.
    case ready(EstateIdentity)

    /// The daemon is older than this client supports; the DAEMON must update.
    case updateDaemonRequired(found: SemanticVersion, minimum: SemanticVersion)

    /// The daemon is newer than this client understands; the APP must update.
    /// The client never stops or downgrades the daemon to resolve this.
    case updateAppRequired(found: SemanticVersion, maximumExclusive: SemanticVersion)

    /// A descriptor was read but this client does not contract with it.
    case incompatible

    /// No authenticated session could be established.
    case authenticationFailed

    /// The session authenticated and the daemon then disagreed with its own
    /// descriptor, or its dispatcher did not answer.
    case handshakeFailed
}

/// Projects registration and readiness observations into a client state.
public enum MootClientStateProjection {

    /// The state a surface should show.
    ///
    /// Order matters and is load-bearing. Approval is checked first because it
    /// is the one condition only the user can clear, and reporting anything
    /// else while it is outstanding would send them somewhere useless. A broken
    /// bundle is checked next because no amount of waiting fixes it.
    ///
    /// - Parameters:
    ///   - registration: The provider's registration status.
    ///   - registrationInFlight: Whether a registration request is running.
    ///     Known by the caller that issued it; not observable from status.
    ///   - readiness: The last readiness outcome, or nil if none has completed.
    /// - Returns: The state to render.
    public static func state(
        registration: ProviderRegistrationObservation,
        registrationInFlight: Bool,
        readiness: DaemonReadinessState?
    ) -> MootClientState {
        switch registration {
        case .requiresApproval:
            return .approvalRequired
        case .notFound:
            return .providerUnavailable
        case .notRegistered:
            return registrationInFlight ? .installing : .notInstalled
        case .enabled:
            break
        }

        guard let readiness else { return .starting }

        switch readiness {
        case .ready(let descriptor):
            return .ready(
                .daemon(
                    estate: descriptor.estateIdentifier,
                    service: descriptor.serviceIdentifier
                )
            )
        case .unavailable:
            // Approved and running, but nothing has published a descriptor yet.
            // That is the normal shape of a daemon still coming up.
            return .starting
        case .superseded:
            // A newer attempt is already running; this one's outcome is not the
            // surface's answer.
            return .starting
        case .incompatible:
            return .incompatible
        case .authenticationFailed:
            return .authenticationFailed
        case .handshakeFailed:
            return .handshakeFailed
        case .updateDaemonRequired(let found, let minimum):
            return .updateDaemonRequired(found: found, minimum: minimum)
        case .updateAppRequired(let found, let maximumExclusive):
            return .updateAppRequired(found: found, maximumExclusive: maximumExclusive)
        }
    }
}
