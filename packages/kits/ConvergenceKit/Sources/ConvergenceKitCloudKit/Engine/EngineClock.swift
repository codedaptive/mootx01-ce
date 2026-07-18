// EngineClock.swift
//
// Wall-clock helper for CloudKitStateActor. The HLCGenerator lives on
// the actor (CloudKitStateActor.swift); nowMillis() feeds it a
// concrete wall time so the push path stays deterministic and testable.

import Foundation

extension CloudKitStateActor {

    /// Current wall-clock in milliseconds, passed explicitly into
    /// the HLC generator. Note: the engine also reads Date() when
    /// assigning lastPushAt and lastPullAt on receipts.
    func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
