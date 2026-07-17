import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(IOKit.ps)
import IOKit.ps
#endif

// MARK: - PowerState  (the "on power" gate)
//
// Bob's rule: the portable LAN server serves only while the device is running
// ON POWER (charging or full). This file is the testable seam for that gate —
// a protocol plus platform sources plus a mock — so MootLANServer's lifecycle
// logic is exercised without a real battery.
//
// Honest platform truth: on iOS the app must be alive (foreground, or a brief
// background window) for the listener to exist at all — "on power" narrows
// WHEN it serves, it does not grant background longevity. The UI states this.

/// Whether the device is currently drawing external power.
public enum PowerCondition: String, Sendable, Equatable {
    case onPower      // charging or full — serving allowed
    case onBattery    // discharging — serving gated off
    case unknown      // state not yet determined — treated as onBattery (fail-closed)

    /// The gate: serving is allowed only when explicitly on power. Unknown is
    /// fail-closed so a server never serves on battery by ambiguity.
    public var allowsServing: Bool { self == .onPower }
}

/// A source of the current power condition. Implementations poll or observe
/// the platform; the mock returns a fixed value for tests.
public protocol PowerConditionSource: Sendable {
    func current() -> PowerCondition
}

/// Deterministic test double.
public struct FixedPowerSource: PowerConditionSource {
    public let condition: PowerCondition
    public init(_ condition: PowerCondition) { self.condition = condition }
    public func current() -> PowerCondition { condition }
}

// MARK: - Platform source

/// The real platform power source. iOS reads UIDevice.batteryState; macOS
/// reads the IOKit power-sources snapshot. Both map onto PowerCondition.
public struct PlatformPowerSource: PowerConditionSource {

    public init() {
        #if canImport(UIKit) && !os(macOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
    }

    public func current() -> PowerCondition {
        #if canImport(UIKit) && !os(macOS)
        switch UIDevice.current.batteryState {
        case .charging, .full: return .onPower
        case .unplugged: return .onBattery
        case .unknown: return .unknown
        @unknown default: return .unknown
        }
        #elseif canImport(IOKit.ps)
        return Self.macPowerCondition()
        #else
        return .unknown
        #endif
    }

    #if canImport(IOKit.ps)
    /// macOS: "on power" means an AC source is present and providing power.
    /// A desktop Mac with no battery reports AC power → onPower, which is
    /// correct (it is literally always on power).
    static func macPowerCondition() -> PowerCondition {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return .unknown
        }
        // No battery entries at all → a Mac on wall power.
        if sources.isEmpty { return .onPower }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let state = desc[kIOPSPowerSourceStateKey] as? String,
               state == kIOPSACPowerValue {
                return .onPower
            }
        }
        return .onBattery
    }
    #endif
}
