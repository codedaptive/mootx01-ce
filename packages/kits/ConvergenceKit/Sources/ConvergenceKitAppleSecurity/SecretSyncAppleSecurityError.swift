/// Fail-closed errors emitted by the AppleSecurity SecretSync leaf.
///
/// Cases deliberately carry no rejected input, provider error, or other
/// associated value that could retain security-sensitive material.
public enum SecretSyncAppleSecurityError: Error, Sendable, Equatable {
    case unsupportedSuite
    case suiteUnavailable
}
