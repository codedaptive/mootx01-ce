// FeatureExtractors.swift
//
// Per-stream feature extractors per cookbook § 3.9.
//
// Each ambient stream produces stream-specific samples. The
// substrate's job is to encode each sample as an AmbientSampleRow
// whose Fingerprint256 is computed under the estate's hyperplane
// family and whose LatticeAnchor places it in the Universal
// Decimal Classification.
//
// Five streams are first-class in v0.36:
//
//   HealthKit          biometric measurements (steps, heart rate,
//                      active energy, etc.)
//   CoreLocation       device location samples (lat/lon/alt with
//                      speed, course, accuracy)
//   EventKit           calendar events (title, dates, attendees,
//                      location, calendar)
//   ScreenTime         app usage windows (bundle, category,
//                      seconds, pickups, notifications)
//   SystemTelemetry    OS-level signals (CPU, memory, disk,
//                      network, battery, thermal)
//
// The OS-bound capture loop lives in ARIA_iOS and ARIA_MacOS;
// only the substrate-side encoding logic lives here. Each
// extractor is pure: given a (Sample, HLC, RowId), it computes
// a deterministic AmbientSampleRow.
//
// Subhash composition: each stream packs its sample fields into
// four 64-bit subhashes that feed the four-block fingerprint
// (§ 5.4). Subhash choices are stream-specific but consistent
// across estate versions (§ I-17 invariant).
//
// Used by:
//   § 3.9    Ambient stream taxonomy (this file)
//   § 5.4    Four-block fingerprint composition
//   § 11.3   recall_by_lattice over ambient rows
//   § 15     Dreaming daemon rule 7 (anomaly scan over streams)

import Foundation
import SubstrateTypes

// MARK: - Shared types

public enum StreamSourceFlag: UInt8, Sendable {
    case healthkit       = 0b0000_0001
    case corelocation    = 0b0000_0010
    case eventkit        = 0b0000_0100
    case screentime      = 0b0000_1000
    case systemTelemetry = 0b0001_0000
    case latticeLookup   = 0b0010_0000
}

public struct AmbientSampleRow: Sendable {
    public let rowId: RowId
    public let captureHLC: HLC
    public let streamSource: UInt8        // bitmap field p06
    public let fingerprint: Fingerprint256
    public let lattice: LatticeAnchor
    public let payload: Data              // stream-specific encoded data

    public init(rowId: RowId,
                captureHLC: HLC,
                streamSource: UInt8,
                fingerprint: Fingerprint256,
                lattice: LatticeAnchor,
                payload: Data) {
        self.rowId = rowId
        self.captureHLC = captureHLC
        self.streamSource = streamSource
        self.fingerprint = fingerprint
        self.lattice = lattice
        self.payload = payload
    }
}

// FNV-1a is now a public SubstrateLib atomic (see FNV.swift); the
// local `fnv64` helper that used to live here was removed under I-25
// when F5b promoted the family to public. Callers below use
// `FNV.hash64` directly. The bare prime `0x100000001B3` retained in
// the attendee combiner below is the FNV-1a 64-bit prime, used here
// as a custom mixing constant rather than as part of a string hash.

// MARK: - HealthKit

public struct HealthKitSample: Sendable {
    public let quantityType: String   // "stepCount", "heartRate", ...
    public let value: Double
    public let unit: String
    public let startDate: TimeInterval
    public let endDate: TimeInterval
    public let sourceDevice: String

    public init(quantityType: String, value: Double, unit: String,
                startDate: TimeInterval, endDate: TimeInterval,
                sourceDevice: String) {
        self.quantityType = quantityType
        self.value = value
        self.unit = unit
        self.startDate = startDate
        self.endDate = endDate
        self.sourceDevice = sourceDevice
    }
}

public struct HealthKitExtractor {
    let hyperplanes: [HyperplaneFamily]

    public init(hyperplanes: [HyperplaneFamily]) {
        self.hyperplanes = hyperplanes
    }

    public func extract(_ s: HealthKitSample,
                        hlc: HLC,
                        rowId: RowId) -> AmbientSampleRow {
        var subhashes = Array<UInt64>(repeating: 0, count: 4)
        subhashes[0] = FNV.hash64(s.quantityType)
        subhashes[1] = UInt64(bitPattern: Int64(s.value * 1_000_000))
        subhashes[2] = UInt64(bitPattern: Int64(s.endDate * 1000))
        subhashes[3] = FNV.hash64(s.sourceDevice)
        let fp = SimHash.fingerprint(fromSubhashes: subhashes, hyperplanes: hyperplanes)
        let lattice = LatticeAnchor.udc("613.71")     // health, body care
        let payload = encodePayload([
            "type": s.quantityType,
            "value": String(s.value),
            "unit": s.unit,
            "src": s.sourceDevice
        ])
        return AmbientSampleRow(rowId: rowId,
                                captureHLC: hlc,
                                streamSource: StreamSourceFlag.healthkit.rawValue,
                                fingerprint: fp,
                                lattice: lattice,
                                payload: payload)
    }
}

// MARK: - CoreLocation

public struct CoreLocationSample: Sendable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double
    public let speed: Double
    public let course: Double
    public let timestamp: TimeInterval
    public let horizontalAccuracy: Double

    public init(latitude: Double, longitude: Double, altitude: Double,
                speed: Double, course: Double, timestamp: TimeInterval,
                horizontalAccuracy: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speed = speed
        self.course = course
        self.timestamp = timestamp
        self.horizontalAccuracy = horizontalAccuracy
    }
}

public struct CoreLocationExtractor {
    let hyperplanes: [HyperplaneFamily]

    public init(hyperplanes: [HyperplaneFamily]) {
        self.hyperplanes = hyperplanes
    }

    public func extract(_ s: CoreLocationSample,
                        hlc: HLC,
                        rowId: RowId) -> AmbientSampleRow {
        let latQ = Int64(s.latitude * 1_000_000)
        let lonQ = Int64(s.longitude * 1_000_000)
        let altQ = Int64(s.altitude)
        let geohash = Self.quantizeGeohash(lat: s.latitude,
                                           lon: s.longitude,
                                           precision: 6)
        var subhashes = Array<UInt64>(repeating: 0, count: 4)
        subhashes[0] = UInt64(bitPattern: latQ) &* 0x100000001B3
        subhashes[1] = UInt64(bitPattern: lonQ) &* 0x100000001B3
        subhashes[2] = UInt64(bitPattern: altQ)
        subhashes[3] = FNV.hash64(geohash)
        let fp = SimHash.fingerprint(fromSubhashes: subhashes, hyperplanes: hyperplanes)
        return AmbientSampleRow(rowId: rowId,
                                captureHLC: hlc,
                                streamSource: StreamSourceFlag.corelocation.rawValue,
                                fingerprint: fp,
                                lattice: .udc("914"),
                                payload: Data())
    }

    static func quantizeGeohash(lat: Double, lon: Double, precision: Int) -> String {
        let scale = pow(10.0, Double(precision))
        let latBucket = Int((lat * scale).rounded(.down))
        let lonBucket = Int((lon * scale).rounded(.down))
        return "\(latBucket),\(lonBucket)"
    }
}

// MARK: - EventKit

public struct EventKitSample: Sendable {
    public let eventIdentifier: String
    public let title: String
    public let startDate: TimeInterval
    public let endDate: TimeInterval
    public let calendarIdentifier: String
    public let attendees: [String]
    public let location: String

    public init(eventIdentifier: String, title: String,
                startDate: TimeInterval, endDate: TimeInterval,
                calendarIdentifier: String, attendees: [String],
                location: String) {
        self.eventIdentifier = eventIdentifier
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.calendarIdentifier = calendarIdentifier
        self.attendees = attendees
        self.location = location
    }
}

public struct EventKitExtractor {
    let hyperplanes: [HyperplaneFamily]

    public init(hyperplanes: [HyperplaneFamily]) {
        self.hyperplanes = hyperplanes
    }

    public func extract(_ s: EventKitSample,
                        hlc: HLC,
                        rowId: RowId) -> AmbientSampleRow {
        var subhashes = Array<UInt64>(repeating: 0, count: 4)
        subhashes[0] = FNV.hash64(s.title)
        subhashes[1] = UInt64(bitPattern: Int64(s.startDate * 1000))
        subhashes[2] = FNV.hash64(s.calendarIdentifier)
        // Attendee set order-independent (sort before hash)
        var attHash: UInt64 = 0xCBF29CE484222325
        for a in s.attendees.sorted() {
            attHash = (attHash ^ FNV.hash64(a)) &* 0x100000001B3
        }
        subhashes[3] = attHash
        let fp = SimHash.fingerprint(fromSubhashes: subhashes, hyperplanes: hyperplanes)
        return AmbientSampleRow(rowId: rowId,
                                captureHLC: hlc,
                                streamSource: StreamSourceFlag.eventkit.rawValue,
                                fingerprint: fp,
                                lattice: .udc("65.012.4"),
                                payload: Data())
    }
}

// MARK: - ScreenTime

public struct ScreenTimeSample: Sendable {
    public let appBundleId: String
    public let categoryIdentifier: String
    public let usageSeconds: Int
    public let pickups: Int
    public let notifications: Int
    public let windowStart: TimeInterval
    public let windowEnd: TimeInterval

    public init(appBundleId: String, categoryIdentifier: String,
                usageSeconds: Int, pickups: Int, notifications: Int,
                windowStart: TimeInterval, windowEnd: TimeInterval) {
        self.appBundleId = appBundleId
        self.categoryIdentifier = categoryIdentifier
        self.usageSeconds = usageSeconds
        self.pickups = pickups
        self.notifications = notifications
        self.windowStart = windowStart
        self.windowEnd = windowEnd
    }
}

public struct ScreenTimeExtractor {
    let hyperplanes: [HyperplaneFamily]

    public init(hyperplanes: [HyperplaneFamily]) {
        self.hyperplanes = hyperplanes
    }

    public func extract(_ s: ScreenTimeSample,
                        hlc: HLC,
                        rowId: RowId) -> AmbientSampleRow {
        var subhashes = Array<UInt64>(repeating: 0, count: 4)
        subhashes[0] = FNV.hash64(s.appBundleId)
        subhashes[1] = FNV.hash64(s.categoryIdentifier)
        subhashes[2] = UInt64(s.usageSeconds)
        subhashes[3] = UInt64(s.pickups) &* 0x100 &+ UInt64(s.notifications)
        let fp = SimHash.fingerprint(fromSubhashes: subhashes, hyperplanes: hyperplanes)
        return AmbientSampleRow(rowId: rowId,
                                captureHLC: hlc,
                                streamSource: StreamSourceFlag.screentime.rawValue,
                                fingerprint: fp,
                                lattice: .udc("004.5"),
                                payload: Data())
    }
}

// MARK: - SystemTelemetry

public struct SystemTelemetrySample: Sendable {
    public let cpuPercent: Float
    public let memoryUsedBytes: UInt64
    public let diskFreeBytes: UInt64
    public let networkUpBytes: UInt64
    public let networkDownBytes: UInt64
    public let batteryLevel: Float
    public let thermalState: Int    // 0 nominal, 1 fair, 2 serious, 3 critical
    public let captureTime: TimeInterval

    public init(cpuPercent: Float, memoryUsedBytes: UInt64,
                diskFreeBytes: UInt64, networkUpBytes: UInt64,
                networkDownBytes: UInt64, batteryLevel: Float,
                thermalState: Int, captureTime: TimeInterval) {
        self.cpuPercent = cpuPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.diskFreeBytes = diskFreeBytes
        self.networkUpBytes = networkUpBytes
        self.networkDownBytes = networkDownBytes
        self.batteryLevel = batteryLevel
        self.thermalState = thermalState
        self.captureTime = captureTime
    }
}

public struct SystemTelemetryExtractor {
    let hyperplanes: [HyperplaneFamily]

    public init(hyperplanes: [HyperplaneFamily]) {
        self.hyperplanes = hyperplanes
    }

    public func extract(_ s: SystemTelemetrySample,
                        hlc: HLC,
                        rowId: RowId) -> AmbientSampleRow {
        var subhashes = Array<UInt64>(repeating: 0, count: 4)
        subhashes[0] = UInt64(s.cpuPercent * 100) &* 0x100000001B3
        subhashes[1] = s.memoryUsedBytes
        subhashes[2] = s.networkUpBytes &+ s.networkDownBytes
        subhashes[3] = UInt64(s.thermalState) &* 0x10000
                     &+ UInt64(s.batteryLevel * 1000)
        let fp = SimHash.fingerprint(fromSubhashes: subhashes, hyperplanes: hyperplanes)
        return AmbientSampleRow(rowId: rowId,
                                captureHLC: hlc,
                                streamSource: StreamSourceFlag.systemTelemetry.rawValue,
                                fingerprint: fp,
                                lattice: .udc("004.2"),
                                payload: Data())
    }
}

// MARK: - Payload helper

internal func encodePayload(_ dict: [String: String]) -> Data {
    // Canonical key-sorted, length-prefixed binary encoding so
    // payload bytes are deterministic across runs.
    var out = Data()
    let sortedKeys = dict.keys.sorted()
    for k in sortedKeys {
        let kBytes = Array(k.utf8)
        let vBytes = Array(dict[k]!.utf8)
        var kLen = UInt32(kBytes.count).bigEndian
        var vLen = UInt32(vBytes.count).bigEndian
        out.append(Data(bytes: &kLen, count: 4))
        out.append(contentsOf: kBytes)
        out.append(Data(bytes: &vLen, count: 4))
        out.append(contentsOf: vBytes)
    }
    return out
}
