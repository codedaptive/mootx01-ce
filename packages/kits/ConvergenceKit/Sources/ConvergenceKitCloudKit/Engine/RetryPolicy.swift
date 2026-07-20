// RetryPolicy.swift
//
// Deterministic exponential backoff with cap + jitter for push retry scheduling.
// Used by the CloudKit push path (PushCycle.swift) to compute the delay before
// the next attempt after a retryable error (CVK-ICLOUD P1-M6 R6).
//
// DESIGN: all inputs come from the struct's stored properties; `delay(...)` is
// a pure function over its explicit parameters. No inline Date() calls, no
// SystemRandomNumberGenerator in the production path — both are injected so
// the function is unit-testable without mocking system clocks.
//
// JITTER: signed ±jitterFraction prevents retry storms when many entries fail
// simultaneously. A retry storm occurs when every failed entry wakes at the
// exact same backoff moment; jitter spreads the load across the interval.
//
// SERVER-SUGGESTED DELAY: when CKError.retryAfterSeconds is non-nil, the
// returned delay is at least that value. We never under-shoot the server's
// rate-limit instruction.

import Foundation

// MARK: - RetryPolicy

/// Computes the delay before the next push attempt after a retryable error.
///
/// Configuration is immutable; every call to `delay(...)` is a pure function
/// that can be tested deterministically by supplying a fixed jitter source.
public struct RetryPolicy: Sendable {

    /// Starting delay for attempt 0 (the first retry after the initial failure).
    public let baseDelay: TimeInterval

    /// Upper bound on the computed delay before jitter is applied.
    public let maxDelay: TimeInterval

    /// Fraction of the capped delay used for jitter: the result is adjusted by
    /// ±(jitterFraction × cappedDelay). Default 0.2 (±20%).
    public let jitterFraction: Double

    /// Default configuration: base 1 s, cap 60 s, ±20% jitter.
    public static let `default` = RetryPolicy(baseDelay: 1.0, maxDelay: 60.0, jitterFraction: 0.2)

    public init(
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 60.0,
        jitterFraction: Double = 0.2
    ) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitterFraction = jitterFraction
    }

    // MARK: - Delay computation

    /// Compute the delay before the next attempt.
    ///
    /// - Parameters:
    ///   - attempt: Number of retries already attempted (0-based). Attempt 0
    ///     produces `baseDelay`; each subsequent attempt doubles the delay until
    ///     `maxDelay` is reached.
    ///   - suggestedRetryAfter: Server-supplied minimum wait, if any (from
    ///     `CKError.retryAfterSeconds`). When non-nil, the returned value is at
    ///     least this large — the server's rate-limit instruction takes the floor.
    ///   - jitterSource: Returns a value in [0, 1). Pass `{ Double.random(in: 0..<1) }`
    ///     in production; pass a deterministic closure in tests.
    public func delay(
        forAttempt attempt: Int,
        suggestedRetryAfter: TimeInterval? = nil,
        jitterSource: () -> Double = { Double.random(in: 0..<1) }
    ) -> TimeInterval {
        // Exponential growth: baseDelay × 2^attempt, capped at maxDelay.
        let exponent = min(Double(attempt), 30)   // guard overflow on very high counts
        let expo = baseDelay * pow(2.0, exponent)
        let capped = min(expo, maxDelay)

        // Jitter: map the [0,1) source to (-1, +1), scale by jitterFraction × delay.
        // Signed jitter means some retries arrive slightly BEFORE the nominal schedule,
        // which smooths burst recovery without ever exceeding the cap downward by more
        // than jitterFraction.
        let jitter = capped * jitterFraction * (2.0 * jitterSource() - 1.0)
        let jittered = max(0, capped + jitter)

        // Server-suggested delay is a hard floor: if the server says wait 30 s and
        // the exponential schedule says 5 s, we wait 30 s.
        if let suggested = suggestedRetryAfter {
            return max(jittered, suggested)
        }
        return jittered
    }
}
